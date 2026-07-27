import Foundation

/// Buffers diagnostic lines for `Diagnostics.txt` instead of printing them.
///
/// Diagnostics and progress output are different products: progress is read live in the terminal,
/// diagnostics are grepped afterwards and can run to thousands of lines. Mixing them makes both
/// useless, so every `OVLD` / `SURV` line goes here and the console gets one summary line.
///
/// Unlike `StderrLogger`, verbose lines are KEPT: a file has no volume problem, and the low-signal
/// tier is exactly what a later investigation needs. Lines are tagged so `grep -v '^[v] '` drops them.
public final class DiagnosticsLog: Logger {
    public private(set) var lines: [String] = []

    public init() {}

    public func log(_ message: @autoclosure () -> String, verbose: Bool) {
        lines.append(verbose ? "v " + message() : message())
    }

    public var isEmpty: Bool { lines.isEmpty }

    /// True for the file-hash legend, which is the ONLY output carrying real paths.
    private static func isLegend(_ line: String) -> Bool {
        line.hasPrefix("SURV-FILE ") || line.hasPrefix("v SURV-FILE ")
    }

    /// Writes `Diagnostics.txt` and, when a file-hash legend exists, `Diagnostics-files.txt`.
    ///
    /// They are SEPARATE on purpose: `Diagnostics.txt` must stay safe to paste under NDA, so every
    /// real path lives in the other file. One accidental paste of a client path is worse than one
    /// extra file. Returns the number of lines in each.
    @discardableResult
    public func write(toDirectory dir: URL) throws -> (diagnostics: Int, legend: Int) {
        let legend = lines.filter(Self.isLegend)
        let body = lines.filter { !Self.isLegend($0) }
        try render(body).write(to: dir.appendingPathComponent("Diagnostics.txt"),
                               atomically: true, encoding: .utf8)
        if !legend.isEmpty {
            let text = "# file-hash legend for Diagnostics.txt. CONTAINS REAL PATHS — local use only.\n"
                + legend.map { $0.hasPrefix("v ") ? String($0.dropFirst(2)) : $0 }.joined(separator: "\n")
                + "\n"
            try text.write(to: dir.appendingPathComponent("Diagnostics-files.txt"),
                           atomically: true, encoding: .utf8)
        }
        return (body.count, legend.count)
    }

    private func render(_ body: [String]) -> String {
        var out = """
        # SwiftProf diagnostics (--diagnose-overloads)
        # Safe to share: every identifier and file name here is hashed (FNV-1a/24bit). The SAME
        # identifier hashes to the SAME token in every line, so OVLD and SURV lines can be
        # correlated without real names. Real paths are in Diagnostics-files.txt, not here.
        #
        # OVLD unresolved …   a call the resolver refused to rewrite: several candidates matched the
        #                     argument labels and no argument type could pick one. Use-site keeps the
        #                     original name; RollbackPass then reverts the group (coverage loss).
        # SURV reverted …     an original name survived in the output and NOTHING shielded it, so the
        #                     whole group was reverted. Green build, lost coverage.
        # SURV blocked …      an original name survived and a shield stopped the revert, so the desync
        #                     SHIPS. This is the red-build set. Read these first.
        # SURV blocked-explained …  same, but the survivor is explained by a declaration we
        #                     deliberately left alone (the benign `self.name = name` shape).
        # Lines starting with 'v ' are the low-signal tier.
        #

        """
        out += body.joined(separator: "\n")
        out += "\n"
        return out
    }
}
