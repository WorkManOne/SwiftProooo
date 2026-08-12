import XCTest
import Foundation
@testable import SwiftProfCore

/// `CoverageReport.txt`'s "Top protection reasons" list must be byte-identical across runs of the
/// same binary on the same input. Its ordering used to depend on `Dictionary` iteration order,
/// which is hash-seeded per process, so tied reasons — and, because the list is truncated to ten,
/// the MEMBERSHIP of the tail — flipped from run to run. The fix is a total order on the
/// comparator: descending by count, ascending by reason text on a tie.
///
/// A test that ran the ranking twice in ONE process would not catch this: the seed is fixed for a
/// process's lifetime. These tests instead pin the exact order the total-order comparator must
/// produce, so any regression to a partial order is caught the moment a hostile seed reorders the
/// tied group.
final class CoverageReportTests: XCTestCase {

    func testRankedReasons_tiesBreakByReasonTextAscending() {
        // The three reasons that were MEASURED flipping in and out of the tenth slot, plus a clear
        // winner and a clear loser, all fed in an order that is not their sorted order.
        let counts = [
            "@NSManaged (runtime/IB name-sensitive)": 2,
            "conforms to unknown external 'App'": 2,
            "conforms to unknown external 'SharedProvider'": 2,
            "@objc (runtime name-sensitive)": 5,
            "raw-typed enum case": 2,
            "operator requirement": 1,
        ]

        let ranked = CoverageReport.rankedReasons(counts)

        XCTAssertEqual(ranked.map(\.reason), [
            "@objc (runtime name-sensitive)",                // 5 — highest count first
            "@NSManaged (runtime/IB name-sensitive)",        // 2 — tie: '@' < 'c' < 'r'
            "conforms to unknown external 'App'",            // 2 — tie: 'App' < 'SharedProvider'
            "conforms to unknown external 'SharedProvider'", // 2
            "raw-typed enum case",                           // 2
            "operator requirement",                          // 1 — lowest count last
        ])
        XCTAssertEqual(ranked.map(\.count), [5, 2, 2, 2, 2, 1])
    }

    func testRankedReasons_truncationBoundaryTie_membershipIsDeterministic() {
        // Eight reasons with distinct counts, then a four-way tie at the top-10 boundary. With a
        // total order the tail is fixed: exactly the two lexically-smallest of the tied group make
        // the cut, and the other two are always dropped.
        var counts: [String: Int] = [
            "count-9": 9, "count-8": 8, "count-7": 7, "count-6": 6,
            "count-5": 5, "count-4": 4, "count-3": 3, "count-2": 2,
        ]
        for tag in ["tie-d", "tie-b", "tie-a", "tie-c"] { counts[tag] = 1 }

        let ranked = CoverageReport.rankedReasons(counts)

        XCTAssertEqual(ranked.count, 10)
        XCTAssertEqual(Array(ranked.map(\.reason).suffix(2)), ["tie-a", "tie-b"])
        XCTAssertFalse(ranked.contains { $0.reason == "tie-c" || $0.reason == "tie-d" },
                       "the two larger-keyed ties must be truncated away deterministically")
    }

    /// End-to-end: a real `CoverageReport` built by the pipeline renders its reasons in a total
    /// order (non-increasing count; ascending reason text on a tie), independent of reason wording.
    func testCoverageReport_fromFixture_reasonsAreTotallyOrdered() throws {
        let coverage = try runCoverage("""
        import Foundation
        @objc class Gadget: NSObject { @objc var label: String = "" }
        struct Payload: Codable { let field: Int }
        enum Mode: String { case alpha, beta }
        func == (a: Payload, b: Payload) -> Bool { a.field == b.field }
        """)

        let reasons = coverage.topProtectionReasons
        XCTAssertFalse(reasons.isEmpty, "fixture should protect at least one declaration")
        for i in 1..<reasons.count {
            let prev = reasons[i - 1], cur = reasons[i]
            XCTAssertGreaterThanOrEqual(prev.count, cur.count, "counts must be non-increasing")
            if prev.count == cur.count {
                XCTAssertLessThan(prev.reason, cur.reason, "ties must break ascending by reason text")
            }
        }
    }

    private func runCoverage(_ source: String) throws -> CoverageReport {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftProf-\(UUID().uuidString)")
        let moduleRoot = tempRoot.appendingPathComponent("M")
        try FileManager.default.createDirectory(at: moduleRoot, withIntermediateDirectories: true)
        try source.write(to: moduleRoot.appendingPathComponent("Sample.swift"),
                         atomically: true, encoding: .utf8)
        let options = PipelineOptions(
            modules: [ModuleSpec(name: "M", root: moduleRoot, writable: true)],
            outputDirectory: tempRoot.appendingPathComponent("out"), dryRun: false,
            nameStyle: .debug, introspectSDK: false, explain: false)
        let result = try Pipeline(options: options,
                                  logger: StderrLogger(verbose: false)).run()
        return result.coverage
    }
}
