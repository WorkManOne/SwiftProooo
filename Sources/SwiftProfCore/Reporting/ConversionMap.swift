import Foundation

public struct ConversionEntry: Codable {
    public let original: String
    public let obfuscated: String
    public let kind: String
    public let module: String
}

public struct ConversionMap: Codable {
    public let entries: [ConversionEntry]

    public init(table: SymbolTable, map: RenameMap) {
        self.entries = table.symbols.compactMap { sym in
            guard let obf = map.obf(for: sym) else { return nil }
            return ConversionEntry(
                original: sym.name,
                obfuscated: obf,
                kind: sym.kind.rawValue,
                module: sym.module.name
            )
        }
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url)
    }
}

/// Human-readable coverage report. For each declaration we record one outcome:
///   - obfuscated
///   - protected (structural — cannot be renamed in principle)
///   - protected (contextual — could be renamed with future resolvers)
///   - policy (parameter/init/extension-of-external/non-writable)
///
/// Two coverage rates are reported:
///   - **Total coverage** = obfuscated / total. Pessimistic — counts the whole project.
///   - **Obfuscatable coverage** = obfuscated / (total − structural). Realistic — excludes
///     decls that no rename-based obfuscator can touch (@objc, raw-type enum cases, View
///     conformer's body, ...). Tells you "how much of what COULD be renamed actually was".
public struct CoverageReport {
    public struct ByKind {
        public let kind: String
        public let total: Int
        public let obfuscated: Int
        public let structural: Int    // protected, can never rename
        public let contextual: Int    // protected, could rename with better resolvers
        public let policy: Int        // Planner skip (param/init/ext-of-ext/non-writable)
    }

    public let totalDeclarations: Int     // writable modules only — denominator for %
    public let externalDeclarations: Int  // read-only modules (SPM/system) — for context
    public let obfuscated: Int
    public let structuralCount: Int
    public let contextualCount: Int
    public let policySkipped: Int
    public let byKind: [ByKind]
    public let topProtectionReasons: [(reason: String, count: Int)]

    /// Convenience computed: declarations that ARE candidates for obfuscation = total minus
    /// the things no obfuscator can ever touch.
    public var obfuscatableCount: Int { totalDeclarations - structuralCount }

    public init(table: SymbolTable, map: RenameMap, protector: Protector) {
        var byKindTotals: [String: Int] = [:]
        var byKindObf:    [String: Int] = [:]
        var byKindStruct: [String: Int] = [:]
        var byKindCtx:    [String: Int] = [:]
        var byKindPolicy: [String: Int] = [:]
        var totalWritable = 0
        var totalExternal = 0
        var totalObf = 0
        var totalStruct = 0
        var totalCtx = 0
        var totalPolicy = 0
        var reasonCounts: [String: Int] = [:]

        for sym in table.symbols {
            // External (SPM/system) declarations contribute to context but not to coverage %.
            if !sym.module.writable {
                totalExternal += 1
                continue
            }
            let k = sym.kind.rawValue
            byKindTotals[k, default: 0] += 1
            totalWritable += 1
            if map.obf(for: sym) != nil {
                byKindObf[k, default: 0] += 1
                totalObf += 1
            } else if let reason = protector.reason(for: sym) {
                switch ProtectionCategory.classify(reason: reason) {
                case .structural:
                    byKindStruct[k, default: 0] += 1
                    totalStruct += 1
                case .contextual:
                    byKindCtx[k, default: 0] += 1
                    totalCtx += 1
                }
                reasonCounts[Self.bucket(reason), default: 0] += 1
            } else {
                byKindPolicy[k, default: 0] += 1
                totalPolicy += 1
            }
        }
        self.totalDeclarations = totalWritable
        self.externalDeclarations = totalExternal
        self.obfuscated = totalObf
        self.structuralCount = totalStruct
        self.contextualCount = totalCtx
        self.policySkipped = totalPolicy
        self.byKind = byKindTotals.keys.sorted().map { k in
            ByKind(kind: k,
                   total: byKindTotals[k] ?? 0,
                   obfuscated: byKindObf[k] ?? 0,
                   structural: byKindStruct[k] ?? 0,
                   contextual: byKindCtx[k] ?? 0,
                   policy: byKindPolicy[k] ?? 0)
        }
        self.topProtectionReasons = Self.rankedReasons(reasonCounts)
    }

    /// Rank protection reasons for the summary and keep the top `limit`. The comparator is a TOTAL
    /// order — descending by count, then ascending by reason text on a tie — so the rendered list
    /// is byte-identical across runs. Without the secondary key, tied reasons came out in
    /// hash-seeded `Dictionary` order, which changed both the order AND (because the list is
    /// truncated) the membership of the tail between runs of the same binary on the same input.
    static func rankedReasons(_ counts: [String: Int], limit: Int = 10) -> [(reason: String, count: Int)] {
        counts
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(limit)
            .map { (reason: $0.key, count: $0.value) }
    }

    /// Strip parenthesised specifics to group similar reasons together for the summary.
    /// "stdlib requirement (View.body)" → "stdlib requirement (View)".
    private static func bucket(_ reason: String) -> String {
        if let openParen = reason.firstIndex(of: "(") {
            let head = reason[..<openParen]
            let rest = reason[reason.index(after: openParen)...]
            if let dot = rest.firstIndex(of: ".") {
                return "\(head)(\(rest[..<dot]))"
            }
            if let close = rest.firstIndex(of: ")") {
                return "\(head)(\(rest[..<close]))"
            }
        }
        return reason
    }

    public func formatted() -> String {
        var lines: [String] = []
        lines.append("=== SwiftProf coverage ===")
        let totalPct = totalDeclarations > 0
            ? Int(round(Double(obfuscated) / Double(totalDeclarations) * 100))
            : 0
        let obfPct = obfuscatableCount > 0
            ? Int(round(Double(obfuscated) / Double(obfuscatableCount) * 100))
            : 0
        lines.append(String(format: "declarations:  %d (writable)  +  %d (external readonly — SPM/system)",
                            totalDeclarations, externalDeclarations))
        lines.append("")
        lines.append(String(format: "  Total coverage         %4d / %-4d  = %3d%%   (pessimistic — whole writable project)",
                            obfuscated, totalDeclarations, totalPct))
        lines.append(String(format: "  Obfuscatable coverage  %4d / %-4d  = %3d%%   (realistic — excludes structural limits)",
                            obfuscated, obfuscatableCount, obfPct))
        lines.append("")
        lines.append("Breakdown of \(totalDeclarations) declarations:")
        lines.append(String(format: "  obfuscated:               %4d  ← actually renamed", obfuscated))
        lines.append(String(format: "  structural protection:    %4d  ← runtime/API/contract — cannot rename in principle", structuralCount))
        lines.append(String(format: "  contextual protection:    %4d  ← key paths / shorthand — fixable with future resolvers", contextualCount))
        lines.append(String(format: "  policy skip:              %4d  ← parameters, init, extension-of-external", policySkipped))
        lines.append("")
        lines.append("By kind:")
        lines.append("  kind             total   obf   struct ctx  policy")
        for entry in byKind {
            lines.append(String(format: "  %-15s  %5d %5d  %5d %4d  %5d",
                                (entry.kind as NSString).utf8String!,
                                entry.total,
                                entry.obfuscated,
                                entry.structural,
                                entry.contextual,
                                entry.policy))
        }
        if !topProtectionReasons.isEmpty {
            lines.append("")
            lines.append("Top protection reasons:")
            for r in topProtectionReasons {
                lines.append(String(format: "  %5d  %@", r.count, r.reason))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public func write(to url: URL) throws {
        try formatted().write(to: url, atomically: true, encoding: .utf8)
    }
}
