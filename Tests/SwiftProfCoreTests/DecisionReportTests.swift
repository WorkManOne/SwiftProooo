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

extension DecisionReportTests {

    func cause(of record: UseSiteRecord) -> UnresolvedCause? {
        if case .kept(let c, _, _) = record.outcome { return c }
        return nil
    }

    func testUseSite_unresolvedReceiver_recordsTheCause() throws {
        // `SomeExternalThing` is undeclared, so the receiver cannot be typed and the member access
        // resolves to nothing while `payloadTag`'s declaration is renamed.
        let (result, _) = try runExplain("""
        struct Box { var payloadTag: Int = 0 }
        func take(_ x: SomeExternalThing) -> Int { return x.payloadTag }
        """)
        let kept = useSites(result, named: "payloadTag").compactMap { cause(of: $0) }
        XCTAssertTrue(kept.contains(.receiverUntyped),
                      "expected a receiver-untyped record, got \(kept.map(\.rawValue))")
    }

    func testUseSite_everyProjectNameOccurrenceIsRecorded() throws {
        // The guarantee: no use-site of a project name reaches the output without a record. If the
        // resolver has an uninstrumented path, the sweep turns it into `.noDecision` rather than
        // silence, so this assertion holds either way and the CAUSE tells which happened.
        let source = """
        struct Card { var badge: Int = 0; func show() -> Int { badge } }
        func read(_ c: Card) -> Int { c.badge + c.show() }
        """
        let (result, _) = try runExplain(source)
        // `badge` is written as a use-site twice: the bare reference in show's body, and `c.badge`.
        XCTAssertEqual(useSites(result, named: "badge").count, 2,
                       "records: \(useSites(result, named: "badge").map { ($0.offset, $0.outcome) })")
        XCTAssertEqual(useSites(result, named: "show").count, 1)
    }
}

extension DecisionReportTests {

    func testUseSite_uninstrumentedPosition_isRecordedAsNoDecision() throws {
        let (result, _) = try runExplain("""
        struct Box { var value: Int = 0 }
        func read(_ o: Int?) -> Int {
            if let value = o { return value }
            return 0
        }
        """)
        let causes = useSites(result, named: "value").compactMap { rec -> UnresolvedCause? in
            if case .kept(let c, _, _) = rec.outcome { return c }
            return nil
        }
        XCTAssertTrue(causes.contains(.noDecision),
                      "the sweep must surface a position the resolver never decided about: \(causes)")
    }
}

extension DecisionReportTests {

    /// Runs the pipeline and returns the rollback result, by running the passes the way the
    /// pipeline does. Uses the public API only.
    func testRollback_unshieldedSurvivor_isReported() throws {
        let (result, _) = try runExplain("""
        struct Box { var widgetPayload: Int = 0 }
        func take(_ x: SomeExternalThing) -> Int { return x.widgetPayload }
        """)
        XCTAssertNotNil(result.rollback.revertedNames["widgetPayload"],
                        "unshielded survivor must be reported: \(result.rollback.revertedNames.keys)")
    }

    func testRollback_shieldedSurvivor_namesTheShield() throws {
        // `camera` is an Apple API name, so shield 1c blocks the revert and the desync ships.
        let (result, _) = try runExplain("""
        struct Box { var camera: Int = 0 }
        func take(_ x: SomeExternalThing) -> Int { return x.camera }
        """)
        XCTAssertNotNil(result.rollback.blockedNames["camera"],
                        "shielded survivor must be reported: \(result.rollback.blockedNames.keys)")
        XCTAssertEqual(result.rollback.shieldReasons["camera"], ["1c"])
    }
}

extension DecisionReportTests {

    func entries(_ outputDir: URL) throws -> [DecisionReport.Entry] {
        let data = try Data(contentsOf: outputDir.appendingPathComponent("decisions.json"))
        return try JSONDecoder().decode([String: [DecisionReport.Entry]].self, from: data)
            .values.flatMap { $0 }
    }

    func testDecisionReport_useSiteEntryNamesItsTarget() throws {
        let (_, outputDir) = try runExplain("""
        struct Card { var badge: Int = 0 }
        func read(_ c: Card) -> Int { c.badge }
        """)
        let all = try entries(outputDir)
        let use = all.first { $0.role == "use-site" && $0.name == "badge" }
        XCTAssertNotNil(use, "roles present: \(Set(all.map(\.role)))")
        XCTAssertEqual(use?.decision, "rewritten")
        XCTAssertEqual(use?.target, "Sample.swift:1 Card.badge")
        XCTAssertTrue(use?.line ?? 0 > 0)
    }

    func testDecisionReport_useSiteTargetRevertedAfterResolution() throws {
        // `widgetPayload` renames, its only use-site is missed, RollbackPass reverts the property
        // AFTER the edit was emitted. The entry must report the final state, not the resolution-time
        // one, which is why the report reads the final map instead of storing obf names.
        let (_, outputDir) = try runExplain("""
        struct Box { var widgetPayload: Int = 0 }
        func use(_ b: Box) -> Int { b.widgetPayload }
        func take(_ x: SomeExternalThing) -> Int { return x.widgetPayload }
        """)
        let all = try entries(outputDir)
        let use = all.first { $0.role == "use-site" && $0.name == "widgetPayload"
                              && $0.decision == "rewritten" }
        XCTAssertEqual(use?.reason, "reverted",
                       "a rewrite undone by rollback must read as reverted: \(String(describing: use))")
    }

    func testDecisionReport_declarationEntriesStillCarryTheirVerdict() throws {
        let (_, outputDir) = try runExplain("""
        struct Vec {
            let x: Int
            init(x: Int) { self.x = x }
            static func == (a: Vec, b: Vec) -> Bool { a.x == b.x }
            func magnitude() -> Int { x }
        }
        """)
        let decls = try entries(outputDir).filter { $0.role == "declaration" }
        XCTAssertEqual(decls.first { $0.name == "magnitude" }?.decision, "obfuscated")
        XCTAssertEqual(decls.first { $0.name == "==" }?.decision, "protected")
    }
}

extension DecisionReportTests {

    /// `.shared` resolves to `B.shared`, but `AmbiguityRollback` reverts the whole same-named
    /// group (used at a shorthand `.shared` site) BEFORE `ResolutionPass` ever runs — so no edit is
    /// ever emitted at this position. The use-site entry must read as "kept", never "rewritten":
    /// nothing here was written, let alone undone.
    func testDecisionReport_useSiteNeverEdited_reportsKeptNotRewritten() throws {
        let (_, outputDir) = try runExplain("""
        enum A { case shared }
        enum B { case shared }
        func use() {
            let b: B = .shared
            _ = b
        }
        """)
        let all = try entries(outputDir)
        let use = all.first { $0.role == "use-site" && $0.name == "shared" }
        XCTAssertEqual(use?.decision, "kept",
                       "no edit was ever emitted here, so this must never read as rewritten: \(String(describing: use))")
        XCTAssertTrue(use?.detail?.contains { $0.contains("REVERTED") } ?? false,
                      "detail should name the target as reverted: \(String(describing: use?.detail))")
    }

    /// The same position must produce exactly ONE use-site record, not two contradicting ones (the
    /// `.kept` from `reportUnresolved`'s `.candidateHasNoObf` and the `.resolvedNotRenamed` from the
    /// immediately following `emitRename`).
    func testDecisionReport_useSiteNeverEdited_recordsExactlyOneEntry() throws {
        let (_, outputDir) = try runExplain("""
        enum A { case shared }
        enum B { case shared }
        func use() {
            let b: B = .shared
            _ = b
        }
        """)
        let all = try entries(outputDir)
        let uses = all.filter { $0.role == "use-site" && $0.name == "shared" }
        guard let first = uses.first else {
            return XCTFail("expected at least one `shared` use-site entry")
        }
        let atSamePosition = uses.filter { $0.line == first.line && $0.column == first.column }
        XCTAssertEqual(atSamePosition.count, 1,
                       "expected exactly one record at \(first.line):\(first.column), got \(atSamePosition.count): \(atSamePosition)")
    }
}

extension DecisionReportTests {

    func decisionsText(_ outputDir: URL) throws -> String {
        try String(contentsOf: outputDir.appendingPathComponent("Decisions.txt"), encoding: .utf8)
    }

    func testDecisionsText_groupsByFileAndShowsResolvedTarget() throws {
        let (_, outputDir) = try runExplain("""
        struct Card { var badge: Int = 0 }
        func read(_ c: Card) -> Int { c.badge }
        """)
        let text = try decisionsText(outputDir)
        XCTAssertTrue(text.contains("===== "), "expected a file header:\n\(text)")
        XCTAssertTrue(text.contains("Sample.swift"), "expected the real file name:\n\(text)")
        let line = text.split(separator: "\n").first { $0.contains("use") && $0.contains("badge") }
        XCTAssertNotNil(line, "expected a use-site line for badge:\n\(text)")
        XCTAssertTrue(line?.contains("resolved: Sample.swift:1 Card.badge") == true,
                      "use-site must name its target: \(line ?? "")")
    }

    func testDecisionsText_keptUseSiteCarriesTheCauseGloss() throws {
        let (_, outputDir) = try runExplain("""
        struct Box { var payloadTag: Int = 0 }
        func take(_ x: SomeExternalThing) -> Int { return x.payloadTag }
        """)
        let text = try decisionsText(outputDir)
        XCTAssertTrue(text.contains("KEPT: receiver-untyped"), "\n\(text)")
        XCTAssertTrue(text.contains(UnresolvedCause.receiverUntyped.gloss),
                      "the gloss must be rendered inline:\n\(text)")
    }

    func testDecisionsText_lowSignalEntriesArePrefixed() throws {
        let (_, outputDir) = try runExplain("""
        struct Vec {
            let x: Int
            static func == (a: Vec, b: Vec) -> Bool { a.x == b.x }
        }
        """)
        let text = try decisionsText(outputDir)
        XCTAssertTrue(text.split(separator: "\n").contains { $0.hasPrefix("v ") },
                      "a use-site resolved to a protected target is the low-signal tier:\n\(text)")
    }
}
