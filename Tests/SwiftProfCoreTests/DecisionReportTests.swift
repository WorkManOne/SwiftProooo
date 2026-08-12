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
        // The JSON carries the FULL path (the anonymized renderer hashes it and the legend keys on
        // it); the human rendering shortens it. The owner-qualified tail is the load-bearing part.
        XCTAssertTrue(use?.target?.hasSuffix("Sample.swift:1 Card.badge") == true,
                      "target must name the owner: \(String(describing: use?.target))")
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

    func testDecisionsText_revertedUsesite_showsRevertedAndTarget() throws {
        // Same fixture as testDecisionReport_useSiteTargetRevertedAfterResolution:
        // `widgetPayload` renames, its only use-site is missed, RollbackPass reverts the property
        // AFTER the edit was emitted. The text must show both the revert marker and the target.
        let (_, outputDir) = try runExplain("""
        struct Box { var widgetPayload: Int = 0 }
        func use(_ b: Box) -> Int { b.widgetPayload }
        func take(_ x: SomeExternalThing) -> Int { return x.widgetPayload }
        """)
        let text = try decisionsText(outputDir)
        let lines = text.split(separator: "\n").map(String.init)
        let revertedLine = lines.first { $0.contains("→ REVERTED") && $0.contains("resolved:") }
        XCTAssertNotNil(revertedLine, "expected a line with both '→ REVERTED' and 'resolved:' on the same line:\n\(text)")
    }

    func testDecisionsText_protectedDeclaration_showsProtectedVerdict() throws {
        // Operator-named callables are never renamed (they resolve as operator expressions,
        // never by declaration name). Verify the PROTECTED verdict is rendered in text.
        let (_, outputDir) = try runExplain("""
        struct Vec {
            let x: Int
            static func == (a: Vec, b: Vec) -> Bool { a.x == b.x }
        }
        """)
        let text = try decisionsText(outputDir)
        let lines = text.split(separator: "\n").map(String.init)
        let protectedLine = lines.first { !$0.hasPrefix("#") && $0.contains("decl") && $0.contains("PROTECTED:") }
        guard let line = protectedLine else {
            let declLines = lines.filter { !$0.hasPrefix("#") && $0.contains("decl") }
            XCTFail("expected a declaration line with 'PROTECTED:', found: \(declLines.joined(separator: "\n"))\n\nFull text:\n\(text)")
            return
        }
        XCTAssertTrue(line.contains("=="), "operator == should be the protected declaration: \(line)")
    }
}

extension DecisionReportTests {

    /// The lines of one `--- <TITLE> … ---` section, excluding the header line itself.
    /// Terminates at the next `---` section header or the per-file trace header (`=====`).
    func section(_ text: String, titled title: String) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: { $0.contains(title) }) else { return [] }
        let rest = lines[(start + 1)...]
        let end = rest.firstIndex(where: { $0.hasPrefix("---") || $0.hasPrefix("=====") }) ?? rest.endIndex
        return Array(rest[..<end])
    }

    func testSummary_namesTheRedBuildSet() throws {
        let (_, outputDir) = try runExplain("""
        struct Box { var camera: Int = 0 }
        func take(_ x: SomeExternalThing) -> Int { return x.camera }
        """)
        let text = try decisionsText(outputDir)
        XCTAssertTrue(text.contains("RED BUILD RISK"), "\n\(text)")
        let sectionLines = section(text, titled: "RED BUILD RISK")
        XCTAssertTrue(sectionLines.contains { $0.contains("camera") },
                      "the shielded survivor must be named:\n\(sectionLines.joined(separator: "\n"))")
        XCTAssertTrue(sectionLines.contains { $0.contains("1c") },
                      "the shield must be named:\n\(sectionLines.joined(separator: "\n"))")
    }

    func testSummary_namesTheCoverageLoss() throws {
        let (_, outputDir) = try runExplain("""
        struct Box { var widgetPayload: Int = 0 }
        func take(_ x: SomeExternalThing) -> Int { return x.widgetPayload }
        """)
        let text = try decisionsText(outputDir)
        XCTAssertTrue(text.contains("COVERAGE LOSS"), "\n\(text)")
        let sectionLines = section(text, titled: "COVERAGE LOSS")
        XCTAssertTrue(sectionLines.contains { $0.contains("widgetPayload") },
                      "\n\(sectionLines.joined(separator: "\n"))")
    }

    func testSummary_ranksCausesByOccurrence() throws {
        let (_, outputDir) = try runExplain("""
        struct Box { var payloadTag: Int = 0; var otherTag: Int = 0 }
        func a(_ x: SomeExternalThing) -> Int { return x.payloadTag }
        func b(_ x: SomeExternalThing) -> Int { return x.payloadTag }
        func c(_ x: SomeExternalThing) -> Int { return x.otherTag }
        """)
        let text = try decisionsText(outputDir)
        let sectionLines = section(text, titled: "UNRESOLVED USE-SITES by cause")
        XCTAssertFalse(sectionLines.isEmpty,
                       "section must exist and be non-empty:\n\(text)")
        XCTAssertTrue(sectionLines.contains { $0.contains("receiver-untyped") },
                      "section must contain 'receiver-untyped':\n\(sectionLines.joined(separator: "\n"))")
        // Structural assertion: section must be properly bounded, not leaking into per-file trace
        XCTAssertFalse(sectionLines.contains { $0.contains("=====") },
                       "section must not contain per-file trace header (=====):\n\(sectionLines.joined(separator: "\n"))")
        XCTAssertFalse(sectionLines.contains { $0.contains("KEPT:") },
                       "section must not contain per-file trace details (KEPT:):\n\(sectionLines.joined(separator: "\n"))")
        guard let topLine = sectionLines.first(where: { $0.trimmingCharacters(in: .whitespaces).starts(with: "top:") }) else {
            XCTFail("section must have a 'top:' line:\n\(sectionLines.joined(separator: "\n"))")
            return
        }
        let payloadTagIndex = topLine.range(of: "payloadTag")
        let otherTagIndex = topLine.range(of: "otherTag")
        guard let p = payloadTagIndex, let o = otherTagIndex else {
            XCTFail("'top:' line must name both members:\n\(topLine)")
            return
        }
        XCTAssertTrue(p.lowerBound < o.lowerBound,
                      "payloadTag (2 occurrences) must rank before otherTag (1 occurrence) in top: line:\n\(topLine)")
    }
}

extension DecisionReportTests {

    func testAnonTwin_isWrittenAndHashesConsistently() throws {
        let (_, outputDir) = try runExplain("""
        struct Card { var badge: Int = 0 }
        func read(_ c: Card) -> Int { c.badge }
        """)
        let anon = try String(contentsOf: outputDir.appendingPathComponent("Decisions-anon.txt"),
                              encoding: .utf8)
        XCTAssertFalse(anon.contains("badge"), "the anon twin must not carry real identifiers:\n\(anon)")
        XCTAssertTrue(anon.contains(Anon.of("badge")), "expected the hashed token:\n\(anon)")
        XCTAssertFalse(anon.contains("Sample.swift"), "paths must be hashed too:\n\(anon)")

        let legend = try String(contentsOf: outputDir.appendingPathComponent("Decisions-files.txt"),
                                encoding: .utf8)
        // A legend DATA line is `<hash> <real path>`, and `Anon.of` prefixes its token with `#`, so
        // a leading `#` does NOT mark a comment here — only the header's `"# "` (hash, space) does.
        let dataLines = Self.legendDataLines(legend)
        guard let entry = dataLines.first(where: { $0.path.hasSuffix("Sample.swift") }) else {
            return XCTFail("the legend must map a hash back to the real path:\n\(legend)")
        }
        // Exact, not "looks like a hash": the token must be the hash OF THAT PATH, which is what
        // makes the legend usable to resolve a token seen in Decisions-anon.txt.
        XCTAssertEqual(entry.token, Anon.of(entry.path),
                       "legend token must be Anon.of(the real path):\n\(legend)")
        XCTAssertTrue(anon.contains(entry.token),
                      "the token the legend resolves must appear in the anon report:\n\(anon)")
    }

    /// The `<hash> <real path>` rows of a `Decisions-files.txt`, header excluded.
    static func legendDataLines(_ legend: String) -> [(token: String, path: String)] {
        legend.split(separator: "\n").compactMap { line -> (token: String, path: String)? in
            guard !line.hasPrefix("# ") else { return nil }   // the header, not a row
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return (token: parts[0], path: parts[1])
        }
    }

    func testAnonTwin_hasTheSameStructureAsTheRealOne() throws {
        let (_, outputDir) = try runExplain("""
        struct Card { var badge: Int = 0 }
        func read(_ c: Card) -> Int { c.badge }
        """)
        let real = try decisionsText(outputDir)
        let anon = try String(contentsOf: outputDir.appendingPathComponent("Decisions-anon.txt"),
                              encoding: .utf8)
        // The anon header carries two extra explanation lines; everything below must match 1:1.
        let realBody = real.components(separatedBy: "=== SwiftProf decisions: summary ===")[1]
        let anonBody = anon.components(separatedBy: "=== SwiftProf decisions: summary ===")[1]
        XCTAssertEqual(realBody.split(separator: "\n").count,
                       anonBody.split(separator: "\n").count,
                       "the two renderings must describe the same records")
    }

    /// The brief's fixture is too simple to exercise the free-text leak: a `reason` string the
    /// assembler built by interpolating a real name (`RollbackPass`'s
    /// "original name '<name>' still appeared in rewritten output"). This fixture reliably reverts
    /// `widgetPayload` (its only use-site is behind an untyped receiver, so RollbackPass finds the
    /// original name surviving in the rewritten output and reverts it) — the revert reason is printed
    /// BOTH on the declaration's verdict line and on the "reverted: …" detail line under the use-site
    /// that was undone, so this exercises both call sites the task asked to fix.
    func testAnonTwin_scrubsAnIdentifierEmbeddedInAFreeTextRevertReason() throws {
        let (_, outputDir) = try runExplain("""
        struct Box { var widgetPayload: Int = 0 }
        func use(_ b: Box) -> Int { b.widgetPayload }
        func take(_ x: SomeExternalThing) -> Int { return x.widgetPayload }
        """)
        let real = try decisionsText(outputDir)
        XCTAssertTrue(real.contains("widgetPayload"),
                      "sanity check: the real report must name the property:\n\(real)")

        let anon = try String(contentsOf: outputDir.appendingPathComponent("Decisions-anon.txt"),
                              encoding: .utf8)
        if let leaked = anon.split(separator: "\n").first(where: { $0.contains("widgetPayload") }) {
            XCTFail("real identifier survived into the anonymized report on this line:\n\(leaked)")
        }
        XCTAssertTrue(anon.contains(Anon.of("widgetPayload")),
                      "expected the hashed token to stand in for it:\n\(anon)")
    }
}

extension DecisionReportTests {

    /// A bare `@Name` attribute token sitting outside any delimiter.
    /// `Protector.runPropertyWrapperProtection` builds exactly this shape for a CUSTOM local
    /// `@propertyWrapper` type: `"@Wrapped property wrapper (creates _x/$x synonyms)"` — `Wrapped`
    /// is a project type name declared in the client's own module. Under the project-name scrub the
    /// `@` is a separator, so the token IS `Wrapped`, it IS in `report.projectNames`, and it hashes;
    /// nothing about the `@` has to be special-cased.
    func testAnonTwin_scrubsABareAtNameAttributeToken_customPropertyWrapper() throws {
        let (_, outputDir) = try runExplain("""
        @propertyWrapper
        struct Wrapped {
            var wrappedValue: Int
            var projectedValue: Bool { wrappedValue > 0 }
        }
        struct Holder {
            @Wrapped var counter: Int = 0
        }
        """)

        let real = try decisionsText(outputDir)
        XCTAssertTrue(real.contains("Wrapped"),
                      "sanity check: the real report must name the wrapper type:\n\(real)")

        let anon = try String(contentsOf: outputDir.appendingPathComponent("Decisions-anon.txt"),
                              encoding: .utf8)
        if let leaked = anon.split(separator: "\n").first(where: { $0.contains("Wrapped") }) {
            XCTFail("real identifier survived into the anonymized report on this line:\n\(leaked)")
        }
        XCTAssertTrue(anon.contains("@" + Anon.of("Wrapped")),
                      "expected the bare @Name token to be hashed but still keep its '@':\n\(anon)")
    }

    /// Non-project vocabulary passes through: `class Thing: NSObject { var value: Int = 0 }` taints
    /// `Thing` via `objcRootClassNames` (default `--objc-protection strict`), which the Protector
    /// reports as the STATIC reason strings `"@objc / transitive objc-class"` for the type and
    /// `"@objc class member (transitive)"` for its members — no project data in either.
    ///
    /// This test used to assert the ALLOWLIST (`knownAttributeNames`) kept `@objc` literal; that
    /// list is gone, and the guarantee it protected is now supplied by non-membership: `objc`,
    /// `class`, `member` and `transitive` are not names any writable module declares, so they are
    /// copied verbatim. The assertion is therefore STRONGER than before — the whole member reason
    /// now survives byte-for-byte, where the old delimited scrub hashed the `(transitive)`
    /// parenthetical just for being a whitespace-free word inside parens.
    func testAnonTwin_nonProjectVocabulary_passesThroughUnhashed() throws {
        let (_, outputDir) = try runExplain("""
        import Foundation
        class Thing: NSObject {
            var value: Int = 0
        }
        """)

        let real = try decisionsText(outputDir)
        XCTAssertTrue(real.contains("@objc / transitive objc-class"),
                      "sanity check: expected the transitive-objc-class reason:\n\(real)")

        let anon = try String(contentsOf: outputDir.appendingPathComponent("Decisions-anon.txt"),
                              encoding: .utf8)
        XCTAssertTrue(anon.contains("@objc / transitive objc-class"),
                      "Apple/Swift vocabulary declares no project symbol, so it must pass through "
                      + "unhashed on the anon path:\n\(anon)")
        XCTAssertTrue(anon.contains("@objc class member (transitive)"),
                      "the whole reason is non-project vocabulary and must survive byte-for-byte:\n\(anon)")
        // And the type/member NAMES around it must still be hashed — passthrough is by
        // non-membership in `projectNames`, never a blanket exemption for prose.
        if let leaked = anon.split(separator: "\n").first(where: { $0.contains("Thing") || $0.contains(" value ") }) {
            XCTFail("real identifier survived into the anonymized report on this line:\n\(leaked)")
        }
    }
}

extension DecisionReportTests {

    /// The `[A-Za-z0-9_]` words of `text` — the same token class the anonymized scrub uses.
    /// Asserting on WORDS rather than substrings is what makes "the name did not survive" provable:
    /// an unrelated hash token that happens to contain those letters cannot mask a real leak.
    func words(_ text: String) -> Set<String> {
        var out: Set<String> = []
        var token = ""
        for c in text {
            if c == "_" || c.isLetter || c.isNumber {
                token.append(c)
            } else if !token.isEmpty {
                out.insert(token); token = ""
            }
        }
        if !token.isEmpty { out.insert(token) }
        return out
    }

    /// The confirmed leak the delimiter-parsing scrub shipped. `AmbiguityRollback` builds
    /// `"ambiguous enum case 'shared' — same name in >1 enum, used at a shorthand `.shared` site"`:
    /// the old scrub hashed the QUOTED occurrence and copied the BACKTICKED one verbatim, so a real
    /// client enum-case name reached `Decisions-anon.txt`. Hashing by project-name membership has
    /// no notion of delimiters, so both occurrences are the same token and get the same treatment.
    func testAnonTwin_backtickedIdentifierInAFreeTextReason_isHashed() throws {
        let (_, outputDir) = try runExplain("""
        enum A { case shared }
        enum B { case shared }
        func use() {
            let b: B = .shared
            _ = b
        }
        """)
        let real = try decisionsText(outputDir)
        XCTAssertTrue(real.contains("shared"),
                      "sanity check: the real report must name the case:\n\(real)")

        let anon = try String(contentsOf: outputDir.appendingPathComponent("Decisions-anon.txt"),
                              encoding: .utf8)
        XCTAssertFalse(words(anon).contains("shared"),
                       "the real name must not survive as a word anywhere in the anon twin:\n\(anon)")
        XCTAssertTrue(anon.contains(Anon.of("shared")),
                      "expected the hashed token to stand in for it:\n\(anon)")
    }

    /// The same fixture, asserted per LINE: the reason string names the identifier TWICE (once
    /// quoted, once backticked), so the anonymized line must carry the hash twice and the real name
    /// zero times. A scrub that catches only the first occurrence passes the file-wide test above
    /// (the other occurrences are hashed elsewhere in the report) and fails this one.
    func testAnonTwin_freeTextReason_everyOccurrenceOfTheNameIsHashed() throws {
        let (_, outputDir) = try runExplain("""
        enum A { case shared }
        enum B { case shared }
        func use() {
            let b: B = .shared
            _ = b
        }
        """)
        let anon = try String(contentsOf: outputDir.appendingPathComponent("Decisions-anon.txt"),
                              encoding: .utf8)
        let hash = Anon.of("shared")
        let reasonLines = anon.split(separator: "\n").map(String.init)
            .filter { $0.contains("ambiguous enum case") }
        XCTAssertFalse(reasonLines.isEmpty,
                       "expected the AmbiguityRollback revert reason to be rendered:\n\(anon)")
        for line in reasonLines {
            // The reason only — a declaration line also carries the hashed name column, which is
            // `ident`'s job, not the free-text scrub's.
            let reason = String(line[line.range(of: "ambiguous enum case")!.lowerBound...])
            XCTAssertEqual(reason.components(separatedBy: hash).count - 1, 2,
                           "both the quoted and the backticked occurrence must be hashed: \(reason)")
            XCTAssertFalse(words(reason).contains("shared"),
                           "the real name survived on this line: \(reason)")
        }
    }
}

extension DecisionReportTests {

    /// Runs the pipeline with `--explain` on two files with the same basename in different modules
    /// and returns the output directory.
    func runExplainTwoModules(module1Source: String, module1FileName: String = "Helper.swift",
                              module2Source: String, module2FileName: String = "Helper.swift") throws -> URL {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftProf-\(UUID().uuidString)")
        let module1Root = tempRoot.appendingPathComponent("M1")
        let module2Root = tempRoot.appendingPathComponent("M2")
        try FileManager.default.createDirectory(at: module1Root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: module2Root, withIntermediateDirectories: true)
        try module1Source.write(to: module1Root.appendingPathComponent(module1FileName),
                                atomically: true, encoding: .utf8)
        try module2Source.write(to: module2Root.appendingPathComponent(module2FileName),
                                atomically: true, encoding: .utf8)
        let outputDir = tempRoot.appendingPathComponent("out")
        let options = PipelineOptions(
            modules: [
                ModuleSpec(name: "M1", root: module1Root, writable: true),
                ModuleSpec(name: "M2", root: module2Root, writable: true)
            ],
            outputDirectory: outputDir, dryRun: false,
            nameStyle: .debug, introspectSDK: false, explain: true)
        _ = try Pipeline(options: options,
                        logger: StderrLogger(verbose: false)).run()
        return outputDir
    }

    func testAnonFileLegend_sameFilenameDifferentModules_usesFullPathHash() throws {
        let outputDir = try runExplainTwoModules(
            module1Source: "struct M1Helper { var field1: Int = 0 }",
            module1FileName: "Helper.swift",
            module2Source: "struct M2Helper { var field2: String = \"x\" }",
            module2FileName: "Helper.swift")

        let legend = try String(contentsOf: outputDir.appendingPathComponent("Decisions-files.txt"),
                                encoding: .utf8)
        let anon = try String(contentsOf: outputDir.appendingPathComponent("Decisions-anon.txt"),
                              encoding: .utf8)

        let hashTokensAndPaths = Self.legendDataLines(legend)

        // Assert exactly two entries (one per module)
        XCTAssertEqual(hashTokensAndPaths.count, 2,
                      "expected exactly 2 legend data lines (one per module), got \(hashTokensAndPaths.count)")

        let hashTokens = hashTokensAndPaths.map { $0.token }
        let paths = hashTokensAndPaths.map { $0.path }

        // Assert two distinct hash tokens
        XCTAssertEqual(Set(hashTokens).count, 2, "expected two DISTINCT hash tokens, got \(Set(hashTokens).count). "
                      + "This indicates files with the same basename hashed to the same token: \(hashTokens)")

        // Assert real paths are distinct
        XCTAssertEqual(Set(paths).count, 2, "legend must list two different real paths")
        XCTAssertTrue(paths[0].hasSuffix("M1/Helper.swift"), "first path should end with M1/Helper.swift: \(paths[0])")
        XCTAssertTrue(paths[1].hasSuffix("M2/Helper.swift"), "second path should end with M2/Helper.swift: \(paths[1])")

        // Assert both hash tokens appear in the anonymized report
        for token in hashTokens {
            XCTAssertTrue(anon.contains(token),
                         "hash token '\(token)' from legend must appear in Decisions-anon.txt")
        }
    }
}

extension DecisionReportTests {

    /// An ambiguous overload names its candidates instead of printing a bare count: `cands=3` tells
    /// a reader nothing, three `File.swift:line Owner.member` lines tell them which declarations the
    /// resolver could not choose between.
    func testAmbiguousOverload_listsTheCandidates() throws {
        let (_, outputDir) = try runExplain("""
        struct Fmt {
            func render(_ v: Int) -> String { "\\(v)" }
            func render(_ v: Bool) -> String { "\\(v)" }
        }
        func go(_ f: Fmt, _ anything: SomeExternalThing) -> String { f.render(anything) }
        """)
        let text = try decisionsText(outputDir)
        XCTAssertTrue(text.contains("KEPT: ambiguous-overload"),
                      "the untypeable argument must leave the overload unresolved:\n\(text)")
        let candidateLines = text.split(separator: "\n").filter { $0.contains("candidate: ") }
        XCTAssertEqual(candidateLines.count, 2,
                       "both overloads must be listed:\n\(candidateLines.joined(separator: "\n"))")
        XCTAssertTrue(candidateLines.allSatisfy { $0.contains("Fmt.render") },
                      "each candidate must name its declaration: \(candidateLines)")
    }
}

extension DecisionReportTests {

    /// A receiver we typed fine whose type declares no such member is a DIFFERENT failure from one
    /// we could not type, and the report has to tell them apart — that distinction is the whole
    /// point of the cause field. The receiver's type is named so the record is actionable.
    ///
    /// Converted from `PatternTests.testDiagnostics_typedReceiverWithoutMember_reportedWithReceiverType`,
    /// which asserted the same two facts against hashed `UNRES` lines in the removed `Diagnostics.txt`.
    func testUseSite_typedReceiverWithoutMember_namesTheReceiverType() throws {
        let (result, _) = try runExplain("""
        struct Box { var widgetPayload: Int = 0 }
        struct Other { var q: Int = 0 }
        func take(_ o: Other) -> Int { return o.widgetPayload }
        """)
        let records = useSites(result, named: "widgetPayload")
        let kept = records.compactMap { rec -> (UnresolvedCause, String?)? in
            if case .kept(let c, let recv, _) = rec.outcome { return (c, recv) }
            return nil
        }
        guard let hit = kept.first(where: { $0.0 == .noCandidateInScope }) else {
            return XCTFail("a typed receiver missing the member is its own cause: \(kept)")
        }
        XCTAssertEqual(hit.1, "Other", "the receiver type must be named, got \(String(describing: hit.1))")
        XCTAssertEqual(records.count, 1, "one use-site, one record: \(records.map(\.outcome))")
    }
}

extension DecisionReportTests {

    /// The confidentiality boundary is "every identifier originating in the client's source", not
    /// "every identifier a WRITABLE module declares".
    ///
    /// Reaching a read-only module's name in the report takes a specific shape, and the fixture has
    /// to build it: read-only DECLARATIONS are not described at all (the report iterates writable
    /// symbols), and a use-site is only recorded when its name is a project name. So the name must
    /// be declared on BOTH sides — then `App.field`'s use-site is recorded, resolves to the
    /// READ-ONLY declaration, and its detail carries `read-only module (VendorKit)` verbatim.
    func testAnonTwin_readOnlyModuleNameIsHashed() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftProf-\(UUID().uuidString)")
        let appRoot = tempRoot.appendingPathComponent("App")
        let vendorRoot = tempRoot.appendingPathComponent("VendorKit")
        for d in [appRoot, vendorRoot] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        try "public struct VendorGadget { public var sharedField: Int = 0 }"
            .write(to: vendorRoot.appendingPathComponent("Vendor.swift"), atomically: true, encoding: .utf8)
        try """
        struct AppUser { var sharedField: Int = 0 }
        func read(_ g: VendorGadget) -> Int { g.sharedField }
        """.write(to: appRoot.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)
        let outputDir = tempRoot.appendingPathComponent("out")
        _ = try Pipeline(options: PipelineOptions(
            modules: [ModuleSpec(name: "App", root: appRoot, writable: true),
                      ModuleSpec(name: "VendorKit", root: vendorRoot, writable: false)],
            outputDirectory: outputDir, dryRun: false,
            nameStyle: .debug, introspectSDK: false, explain: true),
            logger: StderrLogger(verbose: false)).run()

        let real = try decisionsText(outputDir)
        let anon = try String(contentsOf: outputDir.appendingPathComponent("Decisions-anon.txt"),
                              encoding: .utf8)
        XCTAssertTrue(real.contains("read-only module (VendorKit)"),
                      "the fixture must actually produce the reason this guards:\n\(real)")
        XCTAssertFalse(anon.contains("VendorKit"),
                       "a read-only MODULE name must not reach the anon report:\n\(anon)")
    }

    /// The hardest route: a vendor protocol that resolves to NO symbol at all, so no membership test
    /// over the symbol table could ever catch it. The `Protector` hands those names over explicitly.
    func testAnonTwin_unknownExternalProtocolNameIsHashed() throws {
        let (_, outputDir) = try runExplain("""
        struct Widget: AcmeSecretProtocol {
            var payload: Int = 0
        }
        """)
        let real = try decisionsText(outputDir)
        let anon = try String(contentsOf: outputDir.appendingPathComponent("Decisions-anon.txt"),
                              encoding: .utf8)
        XCTAssertTrue(real.contains("AcmeSecretProtocol"),
                      "the human report names the protocol (that is its job):\n\(real)")
        XCTAssertFalse(anon.contains("AcmeSecretProtocol"),
                       "a vendor protocol name reaches the anon report through the protection reason:\n\(anon)")
        XCTAssertTrue(anon.contains(Anon.forced("AcmeSecretProtocol")),
                      "expected the hashed token:\n\(anon)")
    }
}

// MARK: - Reported positions name the text the PASSES parsed, not the rewritten output

extension DecisionReportTests {

    /// `runExplain`, plus the rewritten file's URL and the knobs these tests need. The report is
    /// assembled AFTER the rewrite, so what is on disk at the end is the other half of the check.
    func runExplainOnDisk(_ source: String,
                          fileName: String = "Sample.swift",
                          rawValueMode: RawValueMode = .off,
                          ignoreNames: Set<String> = []) throws
        -> (result: PipelineResult, outputDir: URL, sourceURL: URL) {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftProf-\(UUID().uuidString)")
        let moduleRoot = tempRoot.appendingPathComponent("M")
        try FileManager.default.createDirectory(at: moduleRoot, withIntermediateDirectories: true)
        let sourceURL = moduleRoot.appendingPathComponent(fileName)
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)
        let outputDir = tempRoot.appendingPathComponent("out")
        let options = PipelineOptions(
            modules: [ModuleSpec(name: "M", root: moduleRoot, writable: true)],
            outputDirectory: outputDir, dryRun: false,
            nameStyle: .debug, introspectSDK: false,
            ignoreNames: ignoreNames,
            rawValueMode: rawValueMode, explain: true)
        let result = try Pipeline(options: options,
                                  logger: StderrLogger(verbose: false)).run()
        return (result, outputDir, sourceURL)
    }

    /// 1-based index of the first line containing `needle`, or nil.
    func lineNumber(of needle: String, in text: String) -> Int? {
        text.components(separatedBy: "\n").firstIndex { $0.contains(needle) }.map { $0 + 1 }
    }

    /// The line a `"<path>:<line> Owner.member"` target string points at.
    func targetLine(_ target: String?) -> Int? {
        guard let head = target?.split(separator: " ", maxSplits: 1).first,
              let colon = head.lastIndex(of: ":") else { return nil }
        return Int(head[head.index(after: colon)...])
    }

    /// The defect this guards: every offset the report converts (`Symbol.declOffset`,
    /// `UseSiteRecord.offset`) was taken from the ORIGINAL parse, while the report is built after
    /// `Rewriter` replaced `file.contents` with the obfuscated output. Renaming preserves the
    /// newline COUNT but not byte lengths, so an offset converted against the output drifts
    /// progressively further down each file and clamps at EOF once the drift exceeds the text that
    /// is left — dozens of entries at the end of a file collapsing onto one bogus position.
    ///
    /// The fixture therefore has to SHRINK: several long names above the declaration under test,
    /// each rewritten to a two-character debug obf. One whose renames happened to preserve the
    /// total length would pass with the bug in place.
    func testDecisionReport_declarationBelowShrinkingRenames_reportsItsRealSourceLine() throws {
        let source = """
        struct ConfigurationDescriptorHolder {
            var primaryDisplayCaptionText: String = ""
            var secondaryDisplayCaptionText: String = ""
            var tertiaryDisplayCaptionText: String = ""
            var quaternaryDisplayCaptionText: String = ""
        }

        func renderLeadingCaptionSummary(_ holder: ConfigurationDescriptorHolder) -> String {
            holder.primaryDisplayCaptionText + holder.secondaryDisplayCaptionText
        }

        func renderTrailingCaptionSummary(_ holder: ConfigurationDescriptorHolder) -> String {
            holder.tertiaryDisplayCaptionText + holder.quaternaryDisplayCaptionText
        }

        struct TrailingSentinelStructure {
            var trailingSentinelValue: Int = 0
        }
        """
        let (_, outputDir, sourceURL) = try runExplainOnDisk(source)

        // The premise: the run really did shorten the file, by much more than the tail below the
        // declaration under test. Without that this fixture proves nothing.
        let rewritten = try String(contentsOf: sourceURL, encoding: .utf8)
        let shrink = source.utf8.count - rewritten.utf8.count
        XCTAssertGreaterThan(shrink, 100,
                             "the fixture must shrink the text for the drift to be observable")

        let all = try entries(outputDir)
        let sourceLines = source.components(separatedBy: "\n")

        // The declaration under test sits below every one of those renames.
        let trueLine = try XCTUnwrap(lineNumber(of: "var trailingSentinelValue", in: source))
        let decl = try XCTUnwrap(all.first { $0.role == "declaration" && $0.name == "trailingSentinelValue" })
        XCTAssertEqual(decl.line, trueLine,
                       "reported at line \(decl.line), really on line \(trueLine) "
                     + "— the text shrank by \(shrink) bytes between the parse and the report")

        // And not just that one: no entry may sit on a line that does not spell its own name.
        for e in all {
            guard e.line - 1 < sourceLines.count else {
                return XCTFail("\(e.role) '\(e.name)' reported at line \(e.line), "
                             + "past the end of a \(sourceLines.count)-line file")
            }
            XCTAssertTrue(sourceLines[e.line - 1].contains(e.name),
                          "\(e.role) '\(e.name)' reported at \(e.line):\(e.column), "
                        + "which reads: \(sourceLines[e.line - 1])")
        }

        // `resolved:`/`candidate:` targets are built by a second position lookup — `describe` —
        // over a symbol that can live in another file, so it needs its own check.
        let use = try XCTUnwrap(all.first {
            $0.role == "use-site" && $0.name == "quaternaryDisplayCaptionText" && $0.target != nil
        })
        XCTAssertEqual(targetLine(use.target),
                       lineNumber(of: "var quaternaryDisplayCaptionText", in: source),
                       "the resolved target names the wrong declaration line: \(use.target ?? "?")")
    }

    /// The analysis input is not always the file as it was loaded: `RawValueObfuscationPass`
    /// rewrites the source first and the main pipeline re-parses THAT, so the baseline has to
    /// follow. The inserted `displayName` property is several LINES long, so every declaration
    /// below the enum would be off by that many if it did not.
    ///
    /// Checked against the file on disk rather than the fixture string: the rewrite changes byte
    /// lengths but never newline counts, so the output has exactly the line structure of the
    /// analysis input. `trailingSentinelValue` is ignore-listed to keep it spelled out there.
    func testDecisionReport_afterRawValuePreprocessing_reportsLinesInTheTransformedSource() throws {
        let source = """
        enum BeverageFlavorChoice: String {
            case vanillaSelection = "Vanilla Selection"
            case hazelnutSelection = "Hazelnut Selection"
            case cinnamonSelection = "Cinnamon Selection"
        }

        struct TrailingSentinelStructure {
            var trailingSentinelValue: Int = 0
        }
        """
        let (_, outputDir, sourceURL) = try runExplainOnDisk(
            source, rawValueMode: .safe, ignoreNames: ["trailingSentinelValue"])

        let rewritten = try String(contentsOf: sourceURL, encoding: .utf8)
        let all = try entries(outputDir)

        // The premise: the preprocessing ran and its inserted property is in the analysis input.
        XCTAssertTrue(all.contains { $0.role == "declaration" && $0.name == "displayName" },
                      "the raw-value pass must have inserted displayName: \(all.map(\.name))")
        XCTAssertGreaterThan(rewritten.components(separatedBy: "\n").count,
                             source.components(separatedBy: "\n").count,
                             "the insertion must add lines for this test to bite")

        let trueLine = try XCTUnwrap(lineNumber(of: "var trailingSentinelValue", in: rewritten))
        let decl = try XCTUnwrap(all.first { $0.role == "declaration" && $0.name == "trailingSentinelValue" })
        XCTAssertEqual(decl.line, trueLine,
                       "reported at line \(decl.line), really on line \(trueLine) of the "
                     + "preprocessed source the passes parsed")
    }
}
