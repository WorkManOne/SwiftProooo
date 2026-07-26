import Foundation
import SwiftSyntax

/// Per-symbol provenance: for EVERY writable declaration, exactly why it was obfuscated, protected,
/// skipped, or reverted. Lets you open any file and look up the decision for a specific object.
///
/// Precedence (a symbol has exactly one outcome):
///   1. obf assigned        → `obfuscated`  (reason = the obfuscated name)
///   2. revert reason set    → `reverted`   (planned, then rolled back — witness/ambiguity/rollback/A6)
///   3. Protector reason set → `protected`  (never planned — runtime/API/contract)
///   4. Planner skip reason  → `skipped`    (policy: parameter/init/ext-of-external/kind/ignore/A5)
/// Steps 2–4 are mutually exclusive in practice: Protector-protected symbols are never planned (so
/// no revert reason), and reverted symbols were planned (so not Protector-protected).
public struct DecisionReport {
    public struct Entry: Codable {
        public let line: Int
        public let column: Int
        public let name: String
        public let kind: String
        public let decision: String   // obfuscated | protected | skipped | reverted
        public let reason: String     // the obfuscated name (when obfuscated) or the human reason
    }

    /// Absolute file path → entries, sorted by source position.
    public let byFile: [String: [Entry]]

    public init(table: SymbolTable, map: RenameMap, protector: Protector, plannerSkip: [Int: String]) {
        var grouped: [String: [Entry]] = [:]
        var convertersByFile: [ObjectIdentifier: SourceLocationConverter] = [:]

        for sym in table.symbols where sym.module.writable {
            let fileKey = ObjectIdentifier(sym.file)
            let converter: SourceLocationConverter
            if let cached = convertersByFile[fileKey] {
                converter = cached
            } else {
                converter = SourceLocationConverter(fileName: sym.file.url.path, tree: sym.file.syntax)
                convertersByFile[fileKey] = converter
            }
            let loc = converter.location(for: AbsolutePosition(utf8Offset: sym.declOffset))

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
                Entry(line: loc.line, column: loc.column, name: sym.name,
                      kind: sym.kind.rawValue, decision: decision, reason: reason))
        }

        for (path, entries) in grouped {
            grouped[path] = entries.sorted {
                $0.line != $1.line ? $0.line < $1.line : $0.column < $1.column
            }
        }
        self.byFile = grouped
    }

    private func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }

    public func formattedText() -> String {
        var lines: [String] = [
            "=== SwiftProf per-symbol decisions ===",
            "OBFUSCATED → <obf>  |  PROTECTED: <reason>  |  SKIPPED: <reason>  |  REVERTED: <reason>",
            "",
        ]
        for path in byFile.keys.sorted() {
            lines.append("===== \(path) =====")
            for e in byFile[path]! {
                let loc = pad("\(e.line):\(e.column)", 9)
                let head = "\(loc)\(pad(e.kind, 13))\(pad(e.name, 30))"
                let verdict = e.decision == "obfuscated"
                    ? "OBFUSCATED → \(e.reason)"
                    : "\(e.decision.uppercased()): \(e.reason)"
                lines.append("  \(head) \(verdict)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    public func writeText(to url: URL) throws {
        try formattedText().write(to: url, atomically: true, encoding: .utf8)
    }

    public func writeJSON(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(byFile).write(to: url)
    }
}
