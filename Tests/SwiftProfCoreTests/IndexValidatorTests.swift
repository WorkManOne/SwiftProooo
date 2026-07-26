import XCTest
@testable import SwiftProfCore

/// A6 acceptance: the validator flags a rename whose edit position the compiler attributes to a
/// different module (a cross-target wrong rename — the class RollbackPass cannot catch), and leaves
/// a correct attribution untouched.
final class IndexValidatorTests: XCTestCase {

    private func buildScenario() throws
        -> (storePath: String, app: URL, lib1: URL, lib2: URL)
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("A6-\(UUID().uuidString)")
        let app = root.appendingPathComponent("App")
        let lib1 = root.appendingPathComponent("Lib1")
        let lib2 = root.appendingPathComponent("Lib2")
        let build = root.appendingPathComponent("build")
        let idx = root.appendingPathComponent("idx")
        for d in [app, lib1, lib2, build] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        try "public struct Widget {\n    public init() {}\n    public func load() -> Int { 1 }\n}\n"
            .write(to: lib1.appendingPathComponent("Widget.swift"), atomically: true, encoding: .utf8)
        try "public struct Widget {\n    public init() {}\n    public func load() -> Int { 2 }\n}\n"
            .write(to: lib2.appendingPathComponent("Widget.swift"), atomically: true, encoding: .utf8)
        try "import Lib1\nfunc use() -> Int {\n    let w = Widget()\n    return w.load()\n}\n"
            .write(to: app.appendingPathComponent("Main.swift"), atomically: true, encoding: .utf8)

        func swiftc(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            p.arguments = ["swiftc"] + args
            p.currentDirectoryURL = build
            p.standardError = Pipe(); p.standardOutput = Pipe()
            try p.run(); p.waitUntilExit()
        }
        let common = ["-index-store-path", idx.path, "-index-ignore-system-modules"]
        try swiftc(common + ["-emit-module", "-module-name", "Lib1",
                             "-emit-module-path", build.appendingPathComponent("Lib1.swiftmodule").path,
                             "-c", lib1.appendingPathComponent("Widget.swift").path,
                             "-o", build.appendingPathComponent("Lib1.o").path])
        try swiftc(common + ["-emit-module", "-module-name", "Lib2",
                             "-emit-module-path", build.appendingPathComponent("Lib2.swiftmodule").path,
                             "-c", lib2.appendingPathComponent("Widget.swift").path,
                             "-o", build.appendingPathComponent("Lib2.o").path])
        try swiftc(common + ["-module-name", "App", "-I", build.path,
                             "-c", app.appendingPathComponent("Main.swift").path,
                             "-o", build.appendingPathComponent("App.o").path])
        guard FileManager.default.fileExists(atPath: idx.appendingPathComponent("v5").path) else {
            throw XCTSkip("toolchain did not produce an index store")
        }
        return (idx.path, app, lib1, lib2)
    }

    func testValidatorFlagsCrossModuleWrongRename_passesCorrectOne() throws {
        let (storePath, app, lib1, lib2) = try buildScenario()

        let logger = StderrLogger(verbose: false)
        let project = try ProjectLoader(logger: logger).load(specs: [
            ModuleSpec(name: "App", root: app, writable: true),
            ModuleSpec(name: "Lib1", root: lib1, writable: true),
            ModuleSpec(name: "Lib2", root: lib2, writable: true),
        ])
        let table = SymbolTable()
        DeclarationPass(table: table, logger: logger).run(on: project.files)

        let index = try USRIndex(storePath: storePath)
        let usrBySymbolId = index.usrBySymbol(in: table)

        func widget(inModule m: String) -> Symbol? {
            table.symbols.first { $0.name == "Widget" && $0.kind == .struct && $0.module.name == m }
        }
        guard let lib1Widget = widget(inModule: "Lib1"),
              let lib2Widget = widget(inModule: "Lib2"),
              let appFile = project.files.first(where: { $0.url.lastPathComponent == "Main.swift" })
        else { return XCTFail("scenario symbols/file not found") }

        // Byte offset of the `Widget` token in App's `let w = Widget()`.
        let appSrc = try String(contentsOf: appFile.url, encoding: .utf8)
        guard let r = appSrc.range(of: "Widget") else { return XCTFail("no Widget token") }
        let off = appSrc.utf8.distance(from: appSrc.utf8.startIndex, to: r.lowerBound)

        func rename(toSymbol sym: Symbol) -> Rename {
            Rename(file: appFile, offset: off, length: 6, original: "Widget",
                   replacement: "T9", targetSymbolId: sym.id)
        }

        let validator = IndexValidator(table: table, usrIndex: index,
                                       usrBySymbolId: usrBySymbolId, logger: logger)

        // App imports Lib1, so the compiler bound this use-site to Lib1.Widget.
        // Correct attribution (Lib1) → no desync.
        XCTAssertTrue(validator.findDesyncs(in: [rename(toSymbol: lib1Widget)]).isEmpty,
                      "a correct cross-module rename must not be flagged")

        // Wrong attribution (Lib2) → the compiler says module Lib1 here, so flag Lib2.Widget.
        let bad = validator.findDesyncs(in: [rename(toSymbol: lib2Widget)])
        XCTAssertTrue(bad.contains(lib2Widget.id),
                      "a cross-module wrong rename must be flagged for revert")

        withExtendedLifetime(project) {}
    }

    /// Regression: A6 must compare USR-derived REAL modules, never the `--module` label. With labels
    /// that don't match the compiled module names (e.g. `--module App:./Pulse` → real "Pulse"), a
    /// CORRECT rename must NOT be falsely reverted. The old label-based check flagged every rename in
    /// a mislabeled module — which on the real project reverted ~half the planned type renames.
    func testValidator_toleratesModuleLabelMismatch() throws {
        let (storePath, app, lib1, lib2) = try buildScenario()

        let logger = StderrLogger(verbose: false)
        // Deliberately label the modules with names that do NOT match swiftc's -module-name.
        let project = try ProjectLoader(logger: logger).load(specs: [
            ModuleSpec(name: "A", root: app, writable: true),
            ModuleSpec(name: "L1", root: lib1, writable: true),
            ModuleSpec(name: "L2", root: lib2, writable: true),
        ])
        let table = SymbolTable()
        DeclarationPass(table: table, logger: logger).run(on: project.files)

        let index = try USRIndex(storePath: storePath)
        let usrBySymbolId = index.usrBySymbol(in: table)

        guard let lib1Widget = table.symbols.first(where: {
                  $0.name == "Widget" && $0.kind == .struct && $0.module.name == "L1" }),
              let appFile = project.files.first(where: { $0.url.lastPathComponent == "Main.swift" })
        else { return XCTFail("scenario symbols/file not found") }

        let appSrc = try String(contentsOf: appFile.url, encoding: .utf8)
        guard let r = appSrc.range(of: "Widget") else { return XCTFail("no Widget token") }
        let off = appSrc.utf8.distance(from: appSrc.utf8.startIndex, to: r.lowerBound)

        // App imports the module compiled as "Lib1"; this use-site is correctly attributed to it
        // (labeled "L1"). Despite the label mismatch, the validator must NOT flag it.
        let correct = Rename(file: appFile, offset: off, length: 6, original: "Widget",
                             replacement: "T9", targetSymbolId: lib1Widget.id)
        let validator = IndexValidator(table: table, usrIndex: index,
                                       usrBySymbolId: usrBySymbolId, logger: logger)
        XCTAssertTrue(validator.findDesyncs(in: [correct]).isEmpty,
                      "label mismatch must not cause a false revert (compare real modules, not labels)")

        withExtendedLifetime(project) {}
    }
}
