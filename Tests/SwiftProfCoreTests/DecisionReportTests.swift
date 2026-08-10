import XCTest
import Foundation
@testable import SwiftProfCore

final class DecisionReportTests: XCTestCase {

    func testUnresolvedCause_everyCaseHasANonEmptyGloss() {
        for cause in UnresolvedCause.allCases {
            XCTAssertFalse(cause.gloss.isEmpty, "no gloss for cause '\(cause.rawValue)'")
        }
    }

    func testUnresolvedCause_noDecisionExistsAndIsHighSignal() {
        XCTAssertTrue(UnresolvedCause.allCases.contains(.noDecision))
        XCTAssertEqual(UnresolvedCause.noDecision.rawValue, "no-decision")
        XCTAssertFalse(UnresolvedCause.noDecision.isExplained,
                       "a reporter gap is a lead, not an explanation")
    }
}

extension DecisionReportTests {

    /// Runs the pipeline with `--explain` on one file and returns the result plus the output dir.
    func runExplain(_ source: String,
                    fileName: String = "Sample.swift") throws -> (result: PipelineResult, outputDir: URL) {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftProf-\(UUID().uuidString)")
        let moduleRoot = tempRoot.appendingPathComponent("M")
        try FileManager.default.createDirectory(at: moduleRoot, withIntermediateDirectories: true)
        try source.write(to: moduleRoot.appendingPathComponent(fileName),
                         atomically: true, encoding: .utf8)
        let outputDir = tempRoot.appendingPathComponent("out")
        let options = PipelineOptions(
            modules: [ModuleSpec(name: "M", root: moduleRoot, writable: true)],
            outputDirectory: outputDir, dryRun: false,
            nameStyle: .debug, introspectSDK: false, explain: true)
        let result = try Pipeline(options: options,
                                  logger: StderrLogger(verbose: false)).run()
        return (result, outputDir)
    }

    func useSites(_ result: PipelineResult, named name: String) -> [UseSiteRecord] {
        result.useSites.filter { $0.name == name }
    }

    func testUseSite_rewritten_recordsTheTargetSymbol() throws {
        let (result, _) = try runExplain("""
        struct Card { var badge: Int = 0 }
        func read(_ c: Card) -> Int { c.badge }
        """)
        let badge = useSites(result, named: "badge")
        XCTAssertEqual(badge.count, 1, "expected exactly one `badge` use-site, got \(badge.count)")
        guard case .rewritten(let targetId) = badge[0].outcome else {
            return XCTFail("expected .rewritten, got \(badge[0].outcome)")
        }
        let target = result.table.symbols.first { $0.id == targetId }
        XCTAssertEqual(target?.name, "badge")
        XCTAssertEqual(target?.kind, .property)
    }

    func testUseSite_targetNotRenamed_recordsResolvedNotRenamed() throws {
        let (result, _) = try runExplain("""
        struct Vec {
            let x: Int
            init(x: Int) { self.x = x }
        }
        """)
        let xs = useSites(result, named: "x")
        XCTAssertTrue(xs.contains { if case .resolvedNotRenamed = $0.outcome { return true }; return false },
                      "the skipped init parameter resolves but is never renamed: \(xs.map(\.outcome))")
        XCTAssertTrue(xs.contains { if case .rewritten = $0.outcome { return true }; return false },
                      "the stored property use-site is rewritten: \(xs.map(\.outcome))")
    }

    func testUseSite_sdkOnlyName_isNotRecorded() throws {
        let (result, _) = try runExplain("""
        struct Card { var badge: [Int] = [] }
        func read(_ c: Card) -> Int { c.badge.count }
        """)
        XCTAssertTrue(useSites(result, named: "count").isEmpty,
                      "`count` is declared by no writable symbol and must not be recorded")
    }
}
