import XCTest
@testable import SwiftProfCore

/// Stage-1 index-driven resolution: when `--index-store-path` is set, a use-site the SYNTACTIC
/// resolver cannot type is still renamed, because the compiler's occurrence set (USR ground truth)
/// names the declaration it belongs to. This is the generalization of A6's read half into a write:
/// A6 validates each edit against the index; here the index EMITS the edit.
///
/// The discriminating case is a member reached through a value whose type comes from a user generic
/// function's return (`let m = pick(models, 0); m.secretField`). Substituting `T` from the argument
/// is the documented syntactic limit (B-FIX-62 residual: "a USER generic type's members reached
/// through a VALUE still need the compiler index"). So:
///   - index OFF → `m` is untyped, `m.secretField` is `receiver-untyped`, the member stays original,
///   - index ON  → the index attributes `secretField` at the use-site to `Model.secretField`,
///                 so both the declaration and the use-site are renamed.
/// A passing test therefore cannot be explained by the syntactic path alone.
final class IndexDrivenResolutionTests: XCTestCase {

    // MARK: - Shared toolchain helpers

    /// Build a real index with `swiftc -index-store-path` over `sourcePaths`, emitting a module.
    /// Skips the test (not fails) when the toolchain can't produce a store — keeps the suite green
    /// off the dev box. `extraArgs` lets a dependent module see an already-built one (`-I`).
    private func compile(_ sourcePaths: [String], moduleName: String, buildDir: URL,
                         indexDir: URL, emitModule: Bool, extraArgs: [String] = []) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        var args = ["swiftc", "-index-store-path", indexDir.path, "-index-ignore-system-modules",
                    "-module-name", moduleName]
        if emitModule {
            args += ["-emit-module",
                     "-emit-module-path", buildDir.appendingPathComponent("\(moduleName).swiftmodule").path]
        }
        args += extraArgs + ["-c"] + sourcePaths
            + ["-o", buildDir.appendingPathComponent("\(moduleName).o").path]
        p.arguments = args
        p.currentDirectoryURL = buildDir
        p.standardError = Pipe(); p.standardOutput = Pipe()
        try p.run(); p.waitUntilExit()
    }

    /// `swiftc -typecheck` the given sources as one module; returns the compiler's stderr and status.
    /// The acceptance bar: an index-driven rename that is WRONG shows up here as a type error.
    private func typecheck(_ sourcePaths: [String], moduleName: String, extraArgs: [String] = [])
        -> (ok: Bool, output: String)
    {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["swiftc", "-typecheck", "-module-name", moduleName] + extraArgs + sourcePaths
        let err = Pipe(); p.standardError = err; p.standardOutput = Pipe()
        do { try p.run() } catch { return (false, "\(error)") }
        p.waitUntilExit()
        let out = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationStatus == 0, out)
    }

    @discardableResult
    private func run(modules: [ModuleSpec], indexPath: String?, outParent: URL,
                     explain: Bool = false) throws -> URL {
        let out = outParent.appendingPathComponent("out-\(UUID().uuidString)")
        let options = PipelineOptions(modules: modules, outputDirectory: out, dryRun: false,
                                      nameStyle: .debug, introspectSDK: false,
                                      indexStorePath: indexPath, explain: explain)
        _ = try Pipeline(options: options, logger: StderrLogger(verbose: false)).run()
        return out
    }

    // MARK: - Single module: the receiver-untyped hole

    private let singleModuleSource = """
    struct Model {
        var secretField: Int = 0
    }
    func pick<T>(_ xs: [T], _ i: Int) -> T { xs[i] }
    func use(_ models: [Model]) -> Int {
        let m = pick(models, 0)
        return m.secretField
    }
    """

    private func writeSingleModule() throws -> (root: URL, file: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IndexDriven-\(UUID().uuidString)")
        let src = root.appendingPathComponent("Demo")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let file = src.appendingPathComponent("Demo.swift")
        try singleModuleSource.write(to: file, atomically: true, encoding: .utf8)
        return (src, file)
    }

    func testReceiverUntypedMember_renamedViaIndex_whenSyntaxCannotType() throws {
        // Index ON: build the store over the same module the pipeline will rewrite.
        let on = try writeSingleModule()
        let build = on.root.deletingLastPathComponent().appendingPathComponent("build")
        let idx = on.root.deletingLastPathComponent().appendingPathComponent("idx")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try compile([on.file.path], moduleName: "Demo", buildDir: build, indexDir: idx, emitModule: false)
        guard FileManager.default.fileExists(atPath: idx.appendingPathComponent("v5").path) else {
            throw XCTSkip("toolchain did not produce an index store")
        }
        let onOut = try run(modules: [ModuleSpec(name: "Demo", root: on.root, writable: true)],
                            indexPath: idx.path, outParent: on.root, explain: true)
        let onOutput = try String(contentsOf: on.file, encoding: .utf8)

        // Index OFF: a fresh copy (the ON run already rewrote its own files).
        let off = try writeSingleModule()
        try run(modules: [ModuleSpec(name: "Demo", root: off.root, writable: true)],
                indexPath: nil, outParent: off.root)
        let offOutput = try String(contentsOf: off.file, encoding: .utf8)

        // The syntactic baseline provably cannot type the receiver, so the member survives.
        XCTAssertTrue(offOutput.contains("secretField"),
            "index OFF: the receiver-untyped member must stay original (proves the case is genuinely untypeable)")
        // The index closes exactly that hole: the member is renamed everywhere.
        XCTAssertFalse(onOutput.contains("secretField"),
            "index ON: the receiver-untyped member use-site must be renamed via the compiler's occurrence set")
        // Acceptance bar: the obfuscated output still typechecks (no wrong rename).
        let tc = typecheck([on.file.path], moduleName: "Demo")
        XCTAssertTrue(tc.ok, "obfuscated output must typecheck cleanly:\n\(tc.output)")

        // Honest `--explain`: the member the resolver could not type is recorded as the rewrite the
        // index actually made, NOT as a `receiver-untyped` survivor. `m.secretField` is the only
        // member access in the fixture, so no `receiver-untyped` should remain.
        let decisions = try String(contentsOf: onOut.appendingPathComponent("Decisions.txt"), encoding: .utf8)
        XCTAssertFalse(decisions.contains("receiver-untyped"),
            "the index-renamed use-site must be reported as a rewrite, not a receiver-untyped survivor:\n\(decisions)")
    }

    // MARK: - Cross module: a member owned by another writable module (decision #3)

    /// The declaration lives in `Lib`, the use-site in `App` (both writable). The index records the
    /// use-site under Lib's USR, and the emitter filters occurrences by WRITABLE FILE, not by the
    /// declaration's module — so a rename of a Lib member reaches its use-site in App. The receiver
    /// is again untyped syntactically (generic passthrough), so only the index can close it.
    func testCrossModuleMember_renamedInUsingModule_viaIndex() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IndexDrivenXM-\(UUID().uuidString)")
        let lib = root.appendingPathComponent("Lib")
        let app = root.appendingPathComponent("App")
        let build = root.appendingPathComponent("build")
        let idx = root.appendingPathComponent("idx")
        for d in [lib, app, build] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }

        let libFile = lib.appendingPathComponent("Box.swift")
        let appFile = app.appendingPathComponent("Main.swift")
        try """
        public struct Box {
            public var slot: Int
            public init(slot: Int) { self.slot = slot }
        }
        public func unwrap<T>(_ xs: [T]) -> T { xs[0] }
        """.write(to: libFile, atomically: true, encoding: .utf8)
        try """
        import Lib
        func read(_ boxes: [Box]) -> Int {
            let b = unwrap(boxes)
            return b.slot
        }
        """.write(to: appFile, atomically: true, encoding: .utf8)

        try compile([libFile.path], moduleName: "Lib", buildDir: build, indexDir: idx, emitModule: true)
        try compile([appFile.path], moduleName: "App", buildDir: build, indexDir: idx,
                    emitModule: false, extraArgs: ["-I", build.path])
        guard FileManager.default.fileExists(atPath: idx.appendingPathComponent("v5").path) else {
            throw XCTSkip("toolchain did not produce an index store")
        }

        let modules = [ModuleSpec(name: "Lib", root: lib, writable: true),
                       ModuleSpec(name: "App", root: app, writable: true)]
        try run(modules: modules, indexPath: idx.path, outParent: root)
        let appOut = try String(contentsOf: appFile, encoding: .utf8)
        let libOut = try String(contentsOf: libFile, encoding: .utf8)

        // The Lib declaration renamed, and the cross-module use-site in App followed it.
        XCTAssertFalse(libOut.contains("var slot"), "Lib.Box.slot declaration must rename")
        XCTAssertFalse(appOut.contains(".slot"),
            "index ON: the cross-module member use-site in App must be renamed to Lib.Box.slot's obf")
    }
}
