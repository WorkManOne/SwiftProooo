import Foundation
import SwiftSyntax

/// Per-position provenance: for every writable DECLARATION, exactly why it was obfuscated,
/// protected, skipped or reverted; and for every USE-SITE of a project name, what the resolver
/// bound it to or why it declined.
///
/// Declaration precedence (a symbol has exactly one outcome):
///   1. obf assigned         → `obfuscated`  (reason = the obfuscated name)
///   2. revert reason set    → `reverted`    (planned, then rolled back)
///   3. Protector reason set → `protected`
///   4. Planner skip reason  → `skipped`
///
/// Use-site outcomes are read against the FINAL `RenameMap`: `RollbackPass` and the A6 validator run
/// after `ResolutionPass`, so a rewrite recorded during resolution may have been undone since.
public struct DecisionReport {

    /// A declaration named by a use-site entry: the one it RESOLVED to, or one of the candidates the
    /// resolver could not choose between. Decomposed, not preformatted.
    ///
    /// It used to be the string `"<full path>:<line> <Owner>.<member>"`, which `DecisionRenderer`
    /// took apart again to render it — the human artifact wants the basename, the anonymized one
    /// wants the full path hashed and each component of the qualified name hashed separately. That
    /// re-parse split on the FIRST space, so a project directory containing one
    /// (`/Users/x/My Project/Foo.swift`) left a colon-less head, failed the guard and fell back to
    /// hashing the whole string as ONE token: safe, but the anonymized reader lost the line, the
    /// member name and any way to resolve the file through `Decisions-files.txt`. Re-parsing a string
    /// this same module had just formatted was the defect; the PARTS are what the renderer needs.
    public struct Target: Codable {
        /// Absolute path of the file the declaration lives in. FULL, never the basename: the
        /// anonymized legend keys on full paths, so a basename here would produce a token
        /// `Decisions-files.txt` cannot resolve, and would collapse two files sharing a basename
        /// across modules onto one token. The renderer shortens it for the human rendering.
        public let path: String
        /// 1-based line in that file's ANALYSIS text (`SourceFile.analysisLocation`).
        public let line: Int
        /// `Owner.member`, or a bare `member` for a top-level declaration.
        public let qualified: String
    }

    /// One line rendered under an entry. The two shapes that carry STRUCTURE are cases of their own,
    /// so the renderer never has to recover them from prose — it used to find them by searching the
    /// line for a `"candidate: "` / `"receiver type: "` substring, which is both a re-parse of its
    /// own output and a rule any free text containing those words could trip.
    ///
    /// `.text` is the assembler's free prose, built by interpolating real names (a Codable key, a
    /// protocol name, the surviving original in a rollback revert), and is the only shape the
    /// anonymized rendering has to scrub word by word.
    public enum Detail: Codable {
        case text(String)
        case candidate(Target)
        case receiverType(String)

        private enum CodingKeys: String, CodingKey { case text, candidate, receiverType }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let s = try c.decodeIfPresent(String.self, forKey: .text) {
                self = .text(s)
            } else if let t = try c.decodeIfPresent(Target.self, forKey: .candidate) {
                self = .candidate(t)
            } else if let s = try c.decodeIfPresent(String.self, forKey: .receiverType) {
                self = .receiverType(s)
            } else {
                throw DecodingError.dataCorruptedError(
                    forKey: .text, in: c,
                    debugDescription: "a detail carries exactly one of text/candidate/receiverType")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let s):         try c.encode(s, forKey: .text)
            case .candidate(let t):    try c.encode(t, forKey: .candidate)
            case .receiverType(let s): try c.encode(s, forKey: .receiverType)
            }
        }
    }

    public struct Entry: Codable {
        public let line: Int
        public let column: Int
        public let name: String
        public let kind: String
        /// "declaration" or "use-site".
        public let role: String
        /// declaration: obfuscated | protected | skipped | reverted
        /// use-site:    rewritten | kept
        public let decision: String
        /// The obfuscated name, the human reason, or (for a rewritten use-site whose target was
        /// later reverted) the literal "reverted".
        public let reason: String
        /// use-site only: the declaration the resolver chose.
        public let target: Target?
        /// Extra lines rendered under the entry (cause gloss, effect, candidate list).
        public let detail: [Detail]?
    }

    /// Why one shielded survivor (a name in `RollbackResult.blockedNames`) is NOT reported at full
    /// volume. Two INDEPENDENT readings, either of which demotes it; neither of which is a proof.
    ///
    /// The inherent limit, and the reason this tiers rather than deletes: shield data alone cannot
    /// separate "the shield covers an Apple use-site" from "the shield covers OUR missed use-site",
    /// and the use-site cross-reference cannot either — a real miss on a `some View` chain records
    /// exactly like Apple's own modifier. Both readings are EVIDENCE, and the evidence is printed
    /// next to the name so the reader can overrule it.
    public struct SurvivorTier {
        /// `RollbackPass` found a declaration it deliberately left un-renamed that explains the
        /// surviving occurrence.
        public let namesakeExplained: Bool
        /// The causes of every use-site this report recorded as KEPT for the name, by cause. Empty
        /// when the resolver recorded no decision about the name at all, which is no evidence rather
        /// than good evidence.
        public let causes: [String: Int]
        /// At least one decision was recorded for the name and NOT ONE of them is a red-build lead
        /// (`UnresolvedCause.isRedBuildLead`). One lead is enough to keep the name loud.
        public let useSitesExplained: Bool

        public var isExplained: Bool { namesakeExplained || useSitesExplained }
    }

    public let byFile: [String: [Entry]]

    /// One entry per name in `rollback.blockedNames`. A name missing from this map has no reading at
    /// all and belongs at full volume.
    public let blockedTiers: [String: SurvivorTier]

    /// Every identifier declared by a writable module. The anonymized rendering hashes any word in a
    /// free-text reason that appears here: exact by construction, unlike parsing prose for
    /// delimiters, which shipped a real leak (a backticked `.name` beside a quoted one).
    public let projectNames: Set<String>

    /// Every absolute path the anonymized rendering can turn into a hash, so `Decisions-files.txt`
    /// has a row for each. Two sources, and the second is NOT a subset of the first:
    ///
    /// - every WRITABLE file in the run, entries or not — a layer-1 `first at <path>:<line>` line
    ///   can name a file whose per-file trace is empty;
    /// - every file a `Target` points INTO. `describe` places a declaration wherever it lives, and a
    ///   use-site in a writable file routinely resolves into a READ-ONLY module (`--readonly`,
    ///   `--auto-spm` SPM checkouts). Iterating the writable files alone left such a target rendering
    ///   as `resolved: <hash>:12 <hash>.<hash>` with no legend row for that first hash — no leak, but
    ///   an unresolvable token, which is the one thing the legend exists to prevent.
    public let legendFilePaths: [String]

    public init(table: SymbolTable, map: RenameMap, protector: Protector,
                plannerSkip: [Int: String], useSites: [UseSiteRecord],
                rollback: RollbackResult, files: [SourceFile]) {
        var grouped: [String: [Entry]] = [:]

        // Every position below is converted through `SourceFile.analysisLocation`, i.e. against the
        // text the PASSES parsed. This report is assembled after `Rewriter` and `RollbackPass` have
        // moved `file.contents` on to the obfuscated output, and a rename changes byte lengths: an
        // offset converted against the output drifts down the file and clamps at EOF, which is how
        // every entry near the end of a file collapsed onto one bogus line.
        var fileByPath: [String: SourceFile] = [:]
        var legendPaths: [String] = []
        var seenLegendPath: Set<String> = []
        // Deduped in insertion order: two modules rooted at the same directory contribute one legend
        // row, exactly as the dictionary this replaced did, and a target pointing at an
        // already-listed file adds nothing.
        func noteLegendPath(_ p: String) {
            if seenLegendPath.insert(p).inserted { legendPaths.append(p) }
        }
        /// `describe`, plus the side effect that keeps the legend complete. Every `Target` this
        /// report builds goes through here, so a target can never name a file the legend omits —
        /// the alternative, listing the writable files and hoping every target lands in one, is
        /// exactly what left read-only declarations unresolvable.
        func describeTarget(_ sym: Symbol) -> Target {
            let t = Self.describe(sym)
            noteLegendPath(t.path)
            return t
        }
        for f in files where f.module.writable {
            if fileByPath.updateValue(f, forKey: f.url.path) == nil { noteLegendPath(f.url.path) }
        }

        var symbolById: [Int: Symbol] = [:]
        for sym in table.symbols { symbolById[sym.id] = sym }

        // The scrub set for the anonymized rendering. Deliberately WIDER than the set
        // `ResolutionPass` uses to decide which use-sites are worth recording (writable declarations
        // only): the confidentiality boundary is "every identifier originating in the client's
        // source", not "every identifier a writable module declares". Free-text reasons interpolate
        // three kinds of name that a writable-only set cannot contain, each of which shipped in
        // clear before this was widened:
        //   - a READ-ONLY module's symbol names (`WitnessLinker`'s reverted-group reason names the
        //     protocol; `Protector` names a `@propertyWrapper` type collected from every module),
        //   - MODULE names themselves (`Planner`'s "read-only module (X) — never rewritten"),
        //   - names that resolve to NO symbol at all: the vendor/binary-framework protocols in
        //     `Protector`'s "conforms to unknown external '…'", which by construction matched
        //     nothing in the table, so no membership test over the table could ever catch them —
        //     the Protector hands them over explicitly.
        // Over-hashing costs readability; under-hashing costs confidentiality, and only one of the
        // two is recoverable.
        var names: Set<String> = []
        for sym in table.symbols {
            names.insert(sym.name)
            names.insert(sym.module.name)
        }
        names.formUnion(protector.unknownExternalNames)
        self.projectNames = names

        // Tier the shielded survivors BEFORE the entry loop: the `effect:` line under a use-site must
        // make the same claim the summary does, so both read one value. Built from the raw records
        // rather than from the entries, because an entry's `reason` for a resolved-but-unrenamed
        // target is already normalized to `candidate-has-no-obf` and the record is the source.
        var keptCauses: [String: [String: Int]] = [:]
        for rec in useSites {
            guard case .kept(let cause, _, _) = rec.outcome else { continue }
            guard rollback.blockedNames[rec.name] != nil else { continue }
            keptCauses[rec.name, default: [:]][cause.rawValue, default: 0] += 1
        }
        var tiers: [String: SurvivorTier] = [:]
        for name in rollback.blockedNames.keys {
            let causes = keptCauses[name] ?? [:]
            // An unknown cause string is a lead: this must not fall open if the enum gains a case
            // whose raw value this build does not know.
            let noLeads = causes.keys.allSatisfy { UnresolvedCause(rawValue: $0)?.isRedBuildLead == false }
            tiers[name] = SurvivorTier(
                namesakeExplained: rollback.shieldExplainedNames.contains(name),
                causes: causes,
                useSitesExplained: !causes.isEmpty && noLeads)
        }
        self.blockedTiers = tiers

        // 1. Declarations.
        for sym in table.symbols where sym.module.writable {
            let loc = sym.file.analysisLocation(atUTF8Offset: sym.declOffset)
            let decision: String
            let reason: String
            if let obf = map.obf(for: sym) {
                decision = "obfuscated"; reason = obf
            } else if let r = map.revertReason(sym.id) {
                decision = "reverted"; reason = r
            } else if let r = protector.reason(for: sym) {
                decision = "protected"; reason = r
            } else if let r = plannerSkip[sym.id] {
                decision = "skipped"; reason = r
            } else {
                decision = "skipped"; reason = "no rename planned (no specific reason recorded)"
            }
            grouped[sym.file.url.path, default: []].append(
                Entry(line: loc.line, column: loc.column, name: sym.name, kind: sym.kind.rawValue,
                      role: "declaration", decision: decision, reason: reason,
                      target: nil, detail: nil))
        }

        // 2. Use-sites.
        for rec in useSites {
            guard let file = fileByPath[rec.filePath] else { continue }
            let loc = file.analysisLocation(atUTF8Offset: rec.offset)

            let kind: String
            let decision: String
            let reason: String
            var target: Target? = nil
            var detail: [Detail] = []

            switch rec.outcome {
            case .rewritten(let id):
                // An edit WAS emitted here. Read the FINAL map state: `RollbackPass` and the A6
                // validator run after `ResolutionPass` and may have undone it since.
                let sym = symbolById[id]
                kind = sym?.kind.rawValue ?? "unknown"
                target = sym.map { describeTarget($0) }
                if let sym, let obf = map.obf(for: sym) {
                    decision = "rewritten"; reason = obf
                } else if let sym, let r = map.revertReason(sym.id) {
                    decision = "rewritten"; reason = "reverted"
                    detail.append(.text("resolution was correct; the rename was undone afterwards"))
                    detail.append(.text("reverted: \(r)"))
                } else if let sym, let r = protector.reason(for: sym) {
                    decision = "kept"; reason = UnresolvedCause.candidateHasNoObf.rawValue
                    detail.append(.text("target is PROTECTED: \(r)"))
                } else if let sym, let r = plannerSkip[sym.id] {
                    decision = "kept"; reason = UnresolvedCause.candidateHasNoObf.rawValue
                    detail.append(.text("target is SKIPPED: \(r)"))
                } else {
                    decision = "kept"; reason = UnresolvedCause.candidateHasNoObf.rawValue
                    detail.append(.text("target is not renamed (no specific reason recorded)"))
                }

            case .resolvedNotRenamed(let id):
                // No edit was EVER emitted here — resolution was correct but the target was never
                // renameable in the first place (protected, policy-skipped, or already reverted by
                // an earlier pass such as `AmbiguityRollback`/`WitnessLinker`/`OverrideLinker`).
                // Never "rewritten": nothing at this position was ever written, let alone undone.
                let sym = symbolById[id]
                kind = sym?.kind.rawValue ?? "unknown"
                target = sym.map { describeTarget($0) }
                decision = "kept"
                reason = UnresolvedCause.candidateHasNoObf.rawValue
                if let sym, let r = protector.reason(for: sym) {
                    detail.append(.text("target is PROTECTED: \(r)"))
                } else if let sym, let r = plannerSkip[sym.id] {
                    detail.append(.text("target is SKIPPED: \(r)"))
                } else if let sym, let r = map.revertReason(sym.id) {
                    detail.append(.text("target is REVERTED: \(r)"))
                } else {
                    detail.append(.text("target is not renamed (no specific reason recorded)"))
                }

            case .kept(let cause, let receiver, let candidateIds):
                kind = "unknown"
                decision = "kept"
                reason = cause.rawValue
                detail.append(.text(cause.gloss))
                if let receiver { detail.append(.receiverType(receiver)) }
                for id in candidateIds {
                    guard let c = symbolById[id] else { continue }
                    detail.append(.candidate(describeTarget(c)))
                }
                if let effect = Self.effect(for: rec.name, rollback: rollback,
                                            tier: tiers[rec.name]) {
                    detail.append(.text(effect))
                }
            }

            grouped[rec.filePath, default: []].append(
                Entry(line: loc.line, column: loc.column, name: rec.name, kind: kind,
                      role: "use-site", decision: decision, reason: reason,
                      target: target, detail: detail.isEmpty ? nil : detail))
        }

        // Declarations first, then use-sites; each block in source order.
        for (path, entries) in grouped {
            grouped[path] = entries.sorted {
                if $0.role != $1.role { return $0.role == "declaration" }
                if $0.line != $1.line { return $0.line < $1.line }
                return $0.column < $1.column
            }
        }
        self.byFile = grouped
        self.legendFilePaths = legendPaths
    }

    /// Where a symbol is declared, as PARTS. Never a preformatted string — see `Target`.
    ///
    /// Takes no converter: the symbol's own file is the only thing that can place its `declOffset`,
    /// and it does so against the text that offset came from. A candidate can live in a READ-ONLY
    /// module, which is never rewritten — `analysisLocation` covers both without a second path,
    /// and keeps doing so when read-only SPM modules become writable.
    ///
    /// Callers inside the initializer go through its local `describeTarget`, which also records the
    /// path for `legendFilePaths`; this is the plain half, kept separate so it stays testable.
    static func describe(_ sym: Symbol) -> Target {
        let loc = sym.file.analysisLocation(atUTF8Offset: sym.declOffset)
        let owner = sym.scope?.owner?.name
        return Target(path: sym.file.url.path, line: loc.line,
                      qualified: owner.map { "\($0).\(sym.name)" } ?? sym.name)
    }

    /// What a missed use-site cost, when the rollback pass has an opinion about the name.
    ///
    /// Tiered by the SAME value the summary heads its sections with. Saying `DESYNC SHIPS` under every
    /// blocked name is what made this claim unreadable: on the IceTrays fixture it printed under all
    /// 122 occurrences of an Apple SwiftUI modifier, in a run whose output typechecks with 0 errors.
    static func effect(for name: String, rollback: RollbackResult, tier: SurvivorTier?) -> String? {
        if rollback.blockedNames[name] != nil {
            let shields = (rollback.shieldReasons[name] ?? []).sorted().joined(separator: "+")
            guard tier?.isExplained == true else {
                return "effect: DESYNC SHIPS. rollback blocked by shield \(shields)"
            }
            return "effect: the name survives here; shield \(shields) blocked the revert, "
                 + "and the summary has a benign reading for this survivor"
        }
        if rollback.revertedNames[name] != nil {
            return "effect: reverted, the name stays readable"
        }
        return nil
    }

    public func writeJSON(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(byFile).write(to: url)
    }
}
