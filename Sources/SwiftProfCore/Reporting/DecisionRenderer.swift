import Foundation

/// Renders a `DecisionReport` as text. The ONLY place this project formats a decision, so the
/// real-name and anonymized artifacts cannot drift apart: they are the same code path under a
/// different identity policy.
public enum DecisionRenderer {

    /// How identifiers and paths are printed.
    public enum Identity {
        /// Real names and real paths. The artifact a human opens next to Xcode.
        case real
        /// Every identifier and file name through `Anon.of`. The artifact that is safe to hand out.
        case anonymized
    }

    private static func ident(_ s: String, _ identity: Identity) -> String {
        switch identity {
        case .real: return s
        case .anonymized: return Anon.of(s)
        }
    }

    /// A path is anonymized by its LAST COMPONENT only; the legend file maps it back.
    private static func path(_ p: String, _ identity: Identity) -> String {
        switch identity {
        case .real: return p
        case .anonymized: return Anon.of(URL(fileURLWithPath: p).lastPathComponent)
        }
    }

    /// A "File.swift:12 Owner.member" string, re-anonymized component by component.
    private static func target(_ t: String, _ identity: Identity) -> String {
        guard identity == .anonymized else { return t }
        // "<file>:<line> <Owner>.<member>"
        let parts = t.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return Anon.of(t) }
        let fileAndLine = parts[0].split(separator: ":").map(String.init)
        let file = fileAndLine.first.map { Anon.of($0) } ?? "?"
        let line = fileAndLine.count > 1 ? fileAndLine[1] : "?"
        let qualified = parts[1].split(separator: ".").map { Anon.of(String($0)) }.joined(separator: ".")
        return "\(file):\(line) \(qualified)"
    }

    private static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }

    public static func render(_ report: DecisionReport, rollback: RollbackResult,
                              identity: Identity) -> String {
        var out = header(identity)
        out += summary(report, rollback: rollback, identity: identity)
        out += perFile(report, identity: identity)
        return out
    }

    /// The layer-1 summary: tens of lines read FIRST, answering "where is the damage". Three
    /// sections — the red-build set (a shielded survivor, revert blocked, desync ships), the
    /// coverage losses (a revert that DID happen, green but under-obfuscated), and a histogram of
    /// unresolved use-sites by cause with the top names per cause. This is what the separate
    /// `Diagnostics.txt` aggregates today.
    private static func summary(_ report: DecisionReport, rollback: RollbackResult,
                                identity: Identity) -> String {
        let all = report.byFile.values.flatMap { $0 }
        let decls = all.filter { $0.role == "declaration" }
        let uses = all.filter { $0.role == "use-site" }
        let rewritten = uses.filter { $0.decision == "rewritten" }.count

        var lines = ["=== SwiftProf decisions: summary ==="]
        lines.append("files \(report.byFile.count) · declarations \(decls.count) "
                   + "· use-sites recorded \(uses.count) · rewritten \(rewritten)")
        lines.append("")

        lines.append("--- RED BUILD RISK: original name survived, revert was blocked "
                   + "(\(rollback.blockedNames.count) names) ---")
        for (name, hit) in rollback.blockedNames.sorted(by: { $0.value.occurrences > $1.value.occurrences }) {
            let shields = (rollback.shieldReasons[name] ?? []).sorted().joined(separator: "+")
            lines.append("  \(pad(ident(name, identity), 24)) occ=\(hit.occurrences)  shield \(shields)")
            lines.append("  \(String(repeating: " ", count: 24)) first at \(path(hit.filePath, identity))")
        }
        lines.append("")

        lines.append("--- COVERAGE LOSS: rename reverted because a use-site survived "
                   + "(\(rollback.revertedNames.count) names) ---")
        for (name, hit) in rollback.revertedNames.sorted(by: { $0.value.occurrences > $1.value.occurrences }) {
            lines.append("  \(pad(ident(name, identity), 24)) occ=\(hit.occurrences)")
            lines.append("  \(String(repeating: " ", count: 24)) first at \(path(hit.filePath, identity))")
        }
        lines.append("")

        var byCause: [String: Int] = [:]
        var topName: [String: [String: Int]] = [:]
        for u in uses where u.decision == "kept" {
            byCause[u.reason, default: 0] += 1
            topName[u.reason, default: [:]][u.name, default: 0] += 1
        }
        lines.append("--- UNRESOLVED USE-SITES by cause ---")
        for (cause, count) in byCause.sorted(by: { $0.value > $1.value }) {
            let gloss = UnresolvedCause(rawValue: cause)?.gloss ?? ""
            lines.append("  \(pad(String(count), 6)) \(pad(cause, 24)) \(gloss)")
            let top = (topName[cause] ?? [:]).sorted { $0.value > $1.value }.prefix(3)
                .map { "\(ident($0.key, identity)) \($0.value)" }.joined(separator: " · ")
            if !top.isEmpty { lines.append("         top: \(top)") }
        }
        lines.append("")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func header(_ identity: Identity) -> String {
        var s = "=== SwiftProf decisions ===\n"
        if identity == .anonymized {
            s += "# Every identifier and file name here is hashed (FNV-1a/24bit). The SAME identifier\n"
            s += "# hashes to the SAME token in every line. Real paths are in Decisions-files.txt.\n"
        }
        s += "# decl <verdict>: OBFUSCATED → <obf> | PROTECTED: <why> | SKIPPED: <why> | REVERTED: <why>\n"
        s += "# use  <verdict>: → <obf> plus the declaration it resolved to, or KEPT: <cause>\n"
        s += "# lines starting with 'v ' are the low-signal tier (grep -v '^v ' removes them)\n\n"
        return s
    }

    private static func perFile(_ report: DecisionReport, identity: Identity) -> String {
        var lines: [String] = []
        for filePath in report.byFile.keys.sorted() {
            lines.append("===== \(path(filePath, identity)) =====")
            lines.append("")
            var lastRole = ""
            for e in report.byFile[filePath]! {
                if !lastRole.isEmpty && e.role != lastRole { lines.append("") }
                lastRole = e.role
                lines.append(contentsOf: entryLines(e, identity: identity))
            }
            lines.append("")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// One entry: a head line plus indented detail lines. `lowSignal` entries carry the `v ` prefix
    /// on the head line only, so a `grep -v '^v '` leaves no orphan detail behind — detail lines are
    /// indented past column 0 and are dropped with their head by any line-oriented filter that keys
    /// on the head. Detail lines therefore also carry the prefix.
    private static func entryLines(_ e: DecisionReport.Entry, identity: Identity) -> [String] {
        let lowSignal = e.decision == "kept" && e.reason == UnresolvedCause.candidateHasNoObf.rawValue
        let prefix = lowSignal ? "v " : "  "
        let role = e.role == "declaration" ? "decl" : "use "
        let head = prefix
            + pad("\(e.line):\(e.column)", 8)
            + role + " "
            + pad(e.kind, 11) + " "
            + pad(ident(e.name, identity), 15) + " "
            + verdict(e, identity: identity)
        var out = [head]
        let indent = prefix + String(repeating: " ", count: 8 + 5 + 12 + 16)
        for d in e.detail ?? [] { out.append(indent + detailLine(d, identity: identity)) }
        return out
    }

    private static func verdict(_ e: DecisionReport.Entry, identity: Identity) -> String {
        switch (e.role, e.decision) {
        case ("declaration", "obfuscated"):
            return "OBFUSCATED → \(e.reason)"
        case ("declaration", _):
            return "\(e.decision.uppercased()): \(e.reason)"
        case (_, "rewritten") where e.reason == "reverted":
            return "→ REVERTED   resolved: \(target(e.target ?? "?", identity))"
        case (_, "rewritten"):
            return "→ \(e.reason)   resolved: \(target(e.target ?? "?", identity))"
        default:
            if let t = e.target { return "resolved: \(target(t, identity))" }
            return "KEPT: \(e.reason)"
        }
    }

    /// Detail lines are free text produced by the assembler. Only the two that embed an identifier
    /// need the identity policy applied.
    private static func detailLine(_ d: String, identity: Identity) -> String {
        guard identity == .anonymized else { return d }
        if let r = d.range(of: "candidate: ") {
            return "candidate: " + target(String(d[r.upperBound...]), identity)
        }
        if let r = d.range(of: "receiver type: ") {
            return "receiver type: " + Anon.of(String(d[r.upperBound...]))
        }
        return d
    }
}
