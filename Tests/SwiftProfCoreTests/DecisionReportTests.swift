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
        XCTAssertTrue(legend.contains(Anon.of("Sample.swift")), "\n\(legend)")
        XCTAssertTrue(legend.contains("Sample.swift"), "the legend maps back to the real path:\n\(legend)")
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

    /// The residual left by Task 8: a bare `@Name` attribute token sitting OUTSIDE any quote/paren
    /// delimiter is not caught by the delimited-segment scrub. `Protector.runPropertyWrapperProtection`
    /// builds exactly this shape for a CUSTOM local `@propertyWrapper` type: `"@Wrapped property
    /// wrapper (creates _x/$x synonyms)"` — `Wrapped` is a project type name declared in the
    /// client's own module, and `@Wrapped` is bare text before the parenthesized (whitespace-only,
    /// already-safe) prose.
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

    /// Allowlist passthrough: `class Thing: NSObject { var value: Int = 0 }` taints `Thing` via
    /// `objcRootClassNames` (default `--objc-protection strict`), which the Protector reports as the
    /// STATIC reason string `"@objc / transitive objc-class"` for the type and
    /// `"@objc class member (transitive)"` for its members — both a bare `@objc` token with no
    /// project data behind it. `objc` is Apple/Swift vocabulary (`knownAttributeNames`), so it must
    /// print unhashed on the anonymized path too, exactly as it does on `.real`.
    func testAnonTwin_bareAtNameAllowlist_objcPassesThroughUnhashed() throws {
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
        // The type-level reason has no parens at all ("@objc / transitive objc-class"), so it is
        // pure bare-token prose end to end and must survive byte-for-byte.
        XCTAssertTrue(anon.contains("@objc / transitive objc-class"),
                      "an allowlisted Apple attribute must pass through unhashed on the anon path:\n\(anon)")
        // The member-level reason is "@objc class member (transitive)": the bare "@objc" token is
        // the allowlist case under test; the single-word parenthetical "(transitive)" that follows
        // goes through the PRE-EXISTING delimited-segment scrubber (`scrubIdentifierSegment`, not
        // touched by this fix), which hashes any whitespace-free parenthesized word regardless of
        // whether it is a real identifier — a separate, already-conservative-not-leaky quirk this
        // task does not touch. Assert only the allowlisted token itself stays literal.
        XCTAssertTrue(anon.contains("@objc class member ("),
                      "the allowlisted @objc token must pass through unhashed here too:\n\(anon)")
        // And the type/member NAMES around it must still be hashed — the allowlist covers the
        // attribute vocabulary only, never project identifiers.
        if let leaked = anon.split(separator: "\n").first(where: { $0.contains("Thing") || $0.contains(" value ") }) {
            XCTFail("real identifier survived into the anonymized report on this line:\n\(leaked)")
        }
    }
}
