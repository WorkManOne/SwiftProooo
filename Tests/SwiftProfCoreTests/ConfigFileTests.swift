import XCTest
@testable import SwiftProfCore

/// swiftprof.yaml loading / merging (see docs/superpowers/specs/2026-07-06-config-file-design.md).
/// Invariants under test: config key = flag name (CSV flags become YAML lists), CLI > config
/// per field, unknown keys fail closed with a suggestion, relative paths resolve against the
/// CONFIG FILE's directory (not CWD), discovery prefers .yaml over .yml.
final class ConfigFileTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftprof-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func write(_ text: String, name: String = "swiftprof.yaml") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Parsing

    func testLoad_fullConfig_parsesEveryKeyKind() throws {
        let url = try write("""
        # comments are the point of YAML here
        module:
          - App:/abs/App
          - Widget:/abs/Widget
        readonly:
          - Pkg:/abs/Pkg
        output: /abs/out
        dry-run: true
        debug-names: true
        sdk: macosx
        no-sdk-introspect: true
        sdk-modules: [MapKit, QuickLook]
        ignore-names:
          - AppDelegate   # Info.plist-registered
          - SceneDelegate
        ignore-files: [Generated/]
        ignore-targets: [LegacyKit]
        no-rollback: false
        kinds: [class, struct]
        raw-values: safe
        objc-protection: relaxed
        index-store-path: /abs/DataStore
        index-store-gate: false
        aggressive-rollback: true
        explain: true
        verbose: true
        """)
        let c = try ConfigFile.load(from: url)
        XCTAssertEqual(c.module, ["App:/abs/App", "Widget:/abs/Widget"])
        XCTAssertEqual(c.readonly, ["Pkg:/abs/Pkg"])
        XCTAssertEqual(c.output, "/abs/out")
        XCTAssertEqual(c.dryRun, true)
        XCTAssertEqual(c.debugNames, true)
        XCTAssertEqual(c.sdk, "macosx")
        XCTAssertEqual(c.noSdkIntrospect, true)
        XCTAssertEqual(c.sdkModules, ["MapKit", "QuickLook"])
        XCTAssertEqual(c.ignoreNames, ["AppDelegate", "SceneDelegate"])
        XCTAssertEqual(c.ignoreFiles, ["Generated/"])
        XCTAssertEqual(c.ignoreTargets, ["LegacyKit"])
        XCTAssertEqual(c.noRollback, false)
        XCTAssertEqual(c.kinds, ["class", "struct"])
        XCTAssertEqual(c.rawValues, "safe")
        XCTAssertEqual(c.objcProtection, "relaxed")
        XCTAssertEqual(c.indexStorePath, "/abs/DataStore")
        XCTAssertEqual(c.indexStoreGate, false)
        XCTAssertEqual(c.aggressiveRollback, true)
        XCTAssertEqual(c.explain, true)
        XCTAssertEqual(c.verbose, true)
        XCTAssertNil(c.autoSpm)        // untouched keys stay nil, not defaulted
        XCTAssertNil(c.skipOverloadedCallables)
    }

    func testLoad_emptyFile_isEmptyConfig() throws {
        let url = try write("")
        XCTAssertEqual(try ConfigFile.load(from: url), ConfigFile())
    }

    func testLoad_missingFile_throws() {
        let url = dir.appendingPathComponent("nope.yaml")
        XCTAssertThrowsError(try ConfigFile.load(from: url)) { error in
            guard case ConfigFileError.fileNotFound = error else {
                return XCTFail("expected fileNotFound, got \(error)")
            }
        }
    }

    // MARK: - Fail-closed on typos

    func testLoad_unknownKey_throwsWithSuggestion() throws {
        let url = try write("ignore-name: [AppDelegate]")   // missing the trailing 's'
        XCTAssertThrowsError(try ConfigFile.load(from: url)) { error in
            guard case let ConfigFileError.unknownKey(key, suggestion, _) = error else {
                return XCTFail("expected unknownKey, got \(error)")
            }
            XCTAssertEqual(key, "ignore-name")
            XCTAssertEqual(suggestion, "ignore-names")
        }
    }

    /// `diagnose-overloads` was removed when `--explain` became the only report surface. A stale
    /// `swiftprof.yaml` carrying it must FAIL, not be silently ignored: silently dropping it would
    /// leave the user believing they still get a diagnostics artifact that no longer exists.
    func testLoad_removedDiagnoseOverloadsKey_isRejected() throws {
        let url = try write("diagnose-overloads: true")
        XCTAssertThrowsError(try ConfigFile.load(from: url)) { error in
            guard case let ConfigFileError.unknownKey(key, _, _) = error else {
                return XCTFail("expected unknownKey, got \(error)")
            }
            XCTAssertEqual(key, "diagnose-overloads")
        }
    }

    func testLoad_wrongValueType_throws() throws {
        let url = try write("module: not-a-list")           // scalar where list expected
        XCTAssertThrowsError(try ConfigFile.load(from: url)) { error in
            guard case ConfigFileError.unparseable = error else {
                return XCTFail("expected unparseable, got \(error)")
            }
        }
    }

    func testLoad_topLevelList_throwsNotAMapping() throws {
        let url = try write("- just\n- a\n- list")
        XCTAssertThrowsError(try ConfigFile.load(from: url)) { error in
            guard case ConfigFileError.notAMapping = error else {
                return XCTFail("expected notAMapping, got \(error)")
            }
        }
    }

    // MARK: - Path resolution (against the config file's directory)

    func testLoad_relativePathsResolveAgainstConfigDir() throws {
        let url = try write("""
        module:
          - App:./Sources/App
        output: ./out
        index-store-path: Index/DataStore
        """)
        let c = try ConfigFile.load(from: url)
        XCTAssertEqual(c.module, ["App:\(dir.path)/Sources/App"])
        XCTAssertEqual(c.output, "\(dir.path)/out")
        XCTAssertEqual(c.indexStorePath, "\(dir.path)/Index/DataStore")
    }

    func testLoad_absolutePathsPassThrough() throws {
        let url = try write("output: /already/abs")
        XCTAssertEqual(try ConfigFile.load(from: url).output, "/already/abs")
    }

    // MARK: - Merge precedence (CLI > config)

    func testMerging_cliFieldWinsConfigFillsGaps() {
        var cli = ConfigFile()
        cli.output = "/cli/out"
        cli.noSdkIntrospect = false        // explicit CLI --sdk-introspect beats config true
        cli.ignoreNames = []               // explicitly-passed empty list beats config's list

        var file = ConfigFile()
        file.output = "/file/out"
        file.noSdkIntrospect = true
        file.ignoreNames = ["AppDelegate"]
        file.module = ["App:/file/App"]    // only in config → survives

        let merged = cli.merging(over: file)
        XCTAssertEqual(merged.output, "/cli/out")
        XCTAssertEqual(merged.noSdkIntrospect, false)
        XCTAssertEqual(merged.ignoreNames, [])
        XCTAssertEqual(merged.module, ["App:/file/App"])
        XCTAssertNil(merged.debugNames)    // set by neither → default applied downstream
    }

    /// `objc-protection` is a value-valued key like `raw-values`, so its precedence is the plain
    /// `cli ?? config` rule — a CLI `--objc-protection strict` must be able to pull a project back
    /// from a config-file `relaxed` for one run.
    func testMerging_objcProtectionCliOverridesConfig() {
        var cli = ConfigFile()
        cli.objcProtection = "strict"
        var file = ConfigFile()
        file.objcProtection = "relaxed"
        XCTAssertEqual(cli.merging(over: file).objcProtection, "strict")
        XCTAssertEqual(ConfigFile().merging(over: file).objcProtection, "relaxed")
    }

    // MARK: - Discovery

    func testDiscover_prefersYamlOverYml_noneIsNil() throws {
        XCTAssertNil(ConfigFile.discover(in: dir))
        try write("output: /yml", name: "swiftprof.yml")
        XCTAssertEqual(ConfigFile.discover(in: dir)?.lastPathComponent, "swiftprof.yml")
        try write("output: /yaml", name: "swiftprof.yaml")
        XCTAssertEqual(ConfigFile.discover(in: dir)?.lastPathComponent, "swiftprof.yaml")
    }
}
