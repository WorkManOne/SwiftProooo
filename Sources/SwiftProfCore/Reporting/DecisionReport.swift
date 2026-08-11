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
        /// use-site only: "File.swift:12 Owner.member", the declaration the resolver chose.
        public let target: String?
        /// Extra lines rendered under the entry (cause gloss, effect, candidate list).
        public let detail: [String]?
    }

    public let byFile: [String: [Entry]]

    /// Every identifier declared by a writable module. The anonymized rendering hashes any word in a
    /// free-text reason that appears here: exact by construction, unlike parsing prose for
    /// delimiters, which shipped a real leak (a backticked `.name` beside a quoted one).
    public let projectNames: Set<String>

    /// Absolute paths of every writable file in the run. The anonymized legend keys on these, so it
    /// covers files the report itself has no entry for.
    public let writableFilePaths: [String]

    public init(table: SymbolTable, map: RenameMap, protector: Protector,
                plannerSkip: [Int: String], useSites: [UseSiteRecord],
                rollback: RollbackResult, files: [SourceFile]) {
        var grouped: [String: [Entry]] = [:]
        var convertersByPath: [String: SourceLocationConverter] = [:]

        func converter(forPath path: String, syntax: SourceFileSyntax) -> SourceLocationConverter {
            if let c = convertersByPath[path] { return c }
            let c = SourceLocationConverter(fileName: path, tree: syntax)
            convertersByPath[path] = c
            return c
        }

        var syntaxByPath: [String: SourceFileSyntax] = [:]
        for f in files where f.module.writable { syntaxByPath[f.url.path] = f.syntax }
        self.writableFilePaths = Array(syntaxByPath.keys)

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

        // 1. Declarations.
        for sym in table.symbols where sym.module.writable {
            let conv = converter(forPath: sym.file.url.path, syntax: sym.file.syntax)
            let loc = conv.location(for: AbsolutePosition(utf8Offset: sym.declOffset))
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
            guard let syntax = syntaxByPath[rec.filePath] else { continue }
            let conv = converter(forPath: rec.filePath, syntax: syntax)
            let loc = conv.location(for: AbsolutePosition(utf8Offset: rec.offset))

            let kind: String
            let decision: String
            let reason: String
            var target: String? = nil
            var detail: [String] = []

            switch rec.outcome {
            case .rewritten(let id):
                // An edit WAS emitted here. Read the FINAL map state: `RollbackPass` and the A6
                // validator run after `ResolutionPass` and may have undone it since.
                let sym = symbolById[id]
                kind = sym?.kind.rawValue ?? "unknown"
                target = sym.map { Self.describe($0, converter: converter(forPath: $0.file.url.path,
                                                                          syntax: $0.file.syntax)) }
                if let sym, let obf = map.obf(for: sym) {
                    decision = "rewritten"; reason = obf
                } else if let sym, let r = map.revertReason(sym.id) {
                    decision = "rewritten"; reason = "reverted"
                    detail.append("resolution was correct; the rename was undone afterwards")
                    detail.append("reverted: \(r)")
                } else if let sym, let r = protector.reason(for: sym) {
                    decision = "kept"; reason = UnresolvedCause.candidateHasNoObf.rawValue
                    detail.append("target is PROTECTED: \(r)")
                } else if let sym, let r = plannerSkip[sym.id] {
                    decision = "kept"; reason = UnresolvedCause.candidateHasNoObf.rawValue
                    detail.append("target is SKIPPED: \(r)")
                } else {
                    decision = "kept"; reason = UnresolvedCause.candidateHasNoObf.rawValue
                    detail.append("target is not renamed (no specific reason recorded)")
                }

            case .resolvedNotRenamed(let id):
                // No edit was EVER emitted here — resolution was correct but the target was never
                // renameable in the first place (protected, policy-skipped, or already reverted by
                // an earlier pass such as `AmbiguityRollback`/`WitnessLinker`/`OverrideLinker`).
                // Never "rewritten": nothing at this position was ever written, let alone undone.
                let sym = symbolById[id]
                kind = sym?.kind.rawValue ?? "unknown"
                target = sym.map { Self.describe($0, converter: converter(forPath: $0.file.url.path,
                                                                          syntax: $0.file.syntax)) }
                decision = "kept"
                reason = UnresolvedCause.candidateHasNoObf.rawValue
                if let sym, let r = protector.reason(for: sym) {
                    detail.append("target is PROTECTED: \(r)")
                } else if let sym, let r = plannerSkip[sym.id] {
                    detail.append("target is SKIPPED: \(r)")
                } else if let sym, let r = map.revertReason(sym.id) {
                    detail.append("target is REVERTED: \(r)")
                } else {
                    detail.append("target is not renamed (no specific reason recorded)")
                }

            case .kept(let cause, let receiver, let candidateIds):
                kind = "unknown"
                decision = "kept"
                reason = cause.rawValue
                detail.append(cause.gloss)
                if let receiver { detail.append("receiver type: \(receiver)") }
                for id in candidateIds {
                    guard let c = symbolById[id] else { continue }
                    detail.append("candidate: " + Self.describe(
                        c, converter: converter(forPath: c.file.url.path, syntax: c.file.syntax)))
                }
                if let effect = Self.effect(for: rec.name, rollback: rollback) {
                    detail.append(effect)
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
    }

    /// "File.swift:12 Owner.member", or "File.swift:12 member" for a top-level declaration.
    static func describe(_ sym: Symbol, converter: SourceLocationConverter) -> String {
        let loc = converter.location(for: AbsolutePosition(utf8Offset: sym.declOffset))
        let owner = sym.scope?.owner?.name
        let qualified = owner.map { "\($0).\(sym.name)" } ?? sym.name
        // FULL path, not the basename: `DecisionRenderer.target` hashes this value on the
        // anonymized path and the legend keys on full paths, so a basename here would produce a
        // token that `Decisions-files.txt` cannot resolve — and would collapse two files sharing a
        // basename across modules onto one token. The renderer shortens it for the human rendering.
        return "\(sym.file.url.path):\(loc.line) \(qualified)"
    }

    /// What a missed use-site cost, when the rollback pass has an opinion about the name.
    static func effect(for name: String, rollback: RollbackResult) -> String? {
        if rollback.blockedNames[name] != nil {
            let shields = (rollback.shieldReasons[name] ?? []).sorted().joined(separator: "+")
            return "effect: DESYNC SHIPS. rollback blocked by shield \(shields)"
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
