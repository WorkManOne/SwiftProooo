import XCTest
@testable import SwiftProfCore

/// A4 acceptance: the USR tiebreak resolves a same-named type that is ambiguous to the syntactic
/// resolver (two modules each define `Widget`) to the one the compiler actually bound at the
/// use-site. This is the cross-target wrong-rename class Part A exists to kill.
///
/// The test is made *discriminating* by registering Lib2 BEFORE Lib1: the syntactic fallback then
/// picks Lib2 (first registered), which is WRONG, while App actually imports Lib1. So:
///   - index OFF → App.Widget resolves to Lib2 (the syntactic guess),
///   - index ON  → App.Widget resolves to Lib1 (compiler ground truth, A4).
/// A passing test therefore cannot be explained by the syntactic path alone.
final class TiebreakTests: XCTestCase {

    private func writeSources(into root: URL) throws -> (app: URL, lib1: URL, lib2: URL) {
        let app = root.appendingPathComponent("App")
        let lib1 = root.appendingPathComponent("Lib1")
        let lib2 = root.appendingPathComponent("Lib2")
        for d in [app, lib1, lib2] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        try """
        public struct Widget {
            public init() {}
            public func load() -> Int { 1 }
        }
        """.write(to: lib1.appendingPathComponent("Widget.swift"), atomically: true, encoding: .utf8)
        try """
        public struct Widget {
            public init() {}
            public func load() -> Int { 2 }
        }
        """.write(to: lib2.appendingPathComponent("Widget.swift"), atomically: true, encoding: .utf8)
        try """
        import Lib1
        func use() -> Int {
            let w = Widget()
            return w.load()
        }
        """.write(to: app.appendingPathComponent("Main.swift"), atomically: true, encoding: .utf8)
        return (app, lib1, lib2)
    }

    /// Build a real index over the three modules (App imports Lib1). Returns the store path or
    /// skips if the toolchain can't produce one.
    private func buildIndex(app: URL, lib1: URL, lib2: URL) throws -> String {
        let parent = app.deletingLastPathComponent()
        let build = parent.appendingPathComponent("build")
        let idx = parent.appendingPathComponent("idx")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)

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
        return idx.path
    }

    private func firstGroup(_ pattern: String, in text: String) throws -> String? {
        let re = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    /// Run the pipeline over the three modules. Lib2 is registered BEFORE Lib1 on purpose (see
    /// class doc). Returns (appCtorObf, lib1WidgetObf, lib2WidgetObf).
    private func runAndExtract(app: URL, lib1: URL, lib2: URL, indexPath: String?)
        throws -> (appObf: String?, lib1Obf: String?, lib2Obf: String?)
    {
        let outputDir = app.deletingLastPathComponent().appendingPathComponent("out-\(UUID().uuidString)")
        let options = PipelineOptions(
            modules: [
                ModuleSpec(name: "App", root: app, writable: true),
                ModuleSpec(name: "Lib2", root: lib2, writable: true),   // registered first → syntactic guess
                ModuleSpec(name: "Lib1", root: lib1, writable: true),
            ],
            outputDirectory: outputDir, dryRun: false,
            nameStyle: .debug, introspectSDK: false,
            indexStorePath: indexPath
        )
        _ = try Pipeline(options: options, logger: StderrLogger(verbose: false)).run()
        let lib1Src = try String(contentsOf: lib1.appendingPathComponent("Widget.swift"), encoding: .utf8)
        let lib2Src = try String(contentsOf: lib2.appendingPathComponent("Widget.swift"), encoding: .utf8)
        let appSrc  = try String(contentsOf: app.appendingPathComponent("Main.swift"), encoding: .utf8)
        return (try firstGroup(#"= (T\d+)\("#, in: appSrc),
                try firstGroup(#"struct (T\d+)"#, in: lib1Src),
                try firstGroup(#"struct (T\d+)"#, in: lib2Src))
    }

    func testUSRTiebreak_flipsAmbiguousResolutionToCompilerGroundTruth() throws {
        // 1) Index ON → must resolve to Lib1 (imported / compiler-bound).
        let rootIdx = FileManager.default.temporaryDirectory
            .appendingPathComponent("Tiebreak-idx-\(UUID().uuidString)")
        let s = try writeSources(into: rootIdx)
        let storePath = try buildIndex(app: s.app, lib1: s.lib1, lib2: s.lib2)
        let withIndex = try runAndExtract(app: s.app, lib1: s.lib1, lib2: s.lib2, indexPath: storePath)

        guard let lib1Obf = withIndex.lib1Obf else { return XCTFail("Lib1.Widget not renamed") }
        guard let appObf = withIndex.appObf else { return XCTFail("App Widget() not renamed (gated?)") }
        XCTAssertEqual(appObf, lib1Obf, "index ON: App.Widget must resolve to imported Lib1")
        if let lib2Obf = withIndex.lib2Obf { XCTAssertNotEqual(appObf, lib2Obf, "must not be Lib2") }

        // 2) Index OFF, same module order → syntactic fallback picks Lib2 (first registered). This
        //    proves the scenario is genuinely ambiguous and that step 1's result came from the USR.
        let rootNo = FileManager.default.temporaryDirectory
            .appendingPathComponent("Tiebreak-noidx-\(UUID().uuidString)")
        let n = try writeSources(into: rootNo)
        let noIndex = try runAndExtract(app: n.app, lib1: n.lib1, lib2: n.lib2, indexPath: nil)
        if let appObf = noIndex.appObf, let lib2Obf = noIndex.lib2Obf {
            XCTAssertEqual(appObf, lib2Obf,
                           "index OFF: syntactic fallback resolves App.Widget to first-registered Lib2")
        }
    }
}
