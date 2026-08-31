import Foundation

/// The use-site peer of `CoverageReport`. Buckets every `--explain` use-site record as
/// POSITION -> precise `UnresolvedCause`, with a rewritten-by-kind split on the resolved rows and
/// the top offending names per (position, cause). Built from the FINAL `RenameMap`/`Protector`/
/// planner-skip, so its outcome classification reconciles with `DecisionReport` (a `.rewritten`
/// record whose target was reverted is `reverted`; a protected/skipped target is
/// `candidate-has-no-obf`). Report-only: it reads records and mints no rename.
public struct UseSiteReport {
    public struct NameCount { public let name: String; public let count: Int }
    public struct KindCount { public let kind: String; public let count: Int }
    public struct CauseBucket {
        public let cause: UnresolvedCause
        public let count: Int
        public let topNames: [NameCount]   // count desc, name asc; capped at `nameCap`
        public let moreNames: Int          // distinct names beyond the cap
    }
    public struct PositionBucket {
        public let position: UseSitePosition
        public let rewritten: Int
        public let reverted: Int
        public let kept: Int
        public let rewrittenByKind: [KindCount]   // count desc, kind asc
        public let causes: [CauseBucket]          // count desc, rawValue asc
        public var total: Int { rewritten + reverted + kept }
    }

    public let totalUseSites: Int
    public let totalRewritten: Int
    public let totalReverted: Int
    public let totalKept: Int
    public let positions: [PositionBucket]        // fixed enum order, empties dropped

    private static let nameCap = 6

    /// One record's normalised outcome. Kept private to the report; the drift-guard test pins its
    /// totals against `DecisionReport`'s use-site entries.
    private enum Bucket { case rewritten(kind: String); case reverted; case kept(UnresolvedCause) }

    private static func bucket(_ record: UseSiteRecord, map: RenameMap, protector: Protector,
                               plannerSkip: [Int: String], symbolById: [Int: Symbol]) -> Bucket {
        switch record.outcome {
        case .rewritten(let id):
            guard let sym = symbolById[id] else { return .kept(.candidateHasNoObf) }
            if map.obf(for: sym) != nil { return .rewritten(kind: sym.kind.rawValue) }
            if map.revertReason(sym.id) != nil { return .reverted }
            return .kept(.candidateHasNoObf)          // protected / skipped / no reason
        case .resolvedNotRenamed:
            return .kept(.candidateHasNoObf)
        case .kept(let cause, _, _):
            return .kept(cause)
        }
    }

    public init(records: [UseSiteRecord], table: SymbolTable, map: RenameMap,
                protector: Protector, plannerSkip: [Int: String]) {
        var symbolById: [Int: Symbol] = [:]
        for sym in table.symbols { symbolById[sym.id] = sym }

        // position -> tallies
        var rewritten: [UseSitePosition: Int] = [:]
        var reverted: [UseSitePosition: Int] = [:]
        var kept: [UseSitePosition: Int] = [:]
        var byKind: [UseSitePosition: [String: Int]] = [:]
        var byCause: [UseSitePosition: [UnresolvedCause: Int]] = [:]
        var names: [UseSitePosition: [UnresolvedCause: [String: Int]]] = [:]

        for r in records {
            switch Self.bucket(r, map: map, protector: protector,
                               plannerSkip: plannerSkip, symbolById: symbolById) {
            case .rewritten(let kind):
                rewritten[r.position, default: 0] += 1
                byKind[r.position, default: [:]][kind, default: 0] += 1
            case .reverted:
                reverted[r.position, default: 0] += 1
            case .kept(let cause):
                kept[r.position, default: 0] += 1
                byCause[r.position, default: [:]][cause, default: 0] += 1
                names[r.position, default: [:]][cause, default: [:]][r.name, default: 0] += 1
            }
        }

        self.totalRewritten = rewritten.values.reduce(0, +)
        self.totalReverted = reverted.values.reduce(0, +)
        self.totalKept = kept.values.reduce(0, +)
        self.totalUseSites = totalRewritten + totalReverted + totalKept

        // Causes for which top names are noise rather than an offender list.
        func showsNames(_ cause: UnresolvedCause) -> Bool {
            cause != .candidateHasNoObf && cause != .noDecision
        }

        var buckets: [PositionBucket] = []
        for position in UseSitePosition.orderedForReport {
            let r = rewritten[position] ?? 0, rv = reverted[position] ?? 0, k = kept[position] ?? 0
            if r + rv + k == 0 { continue }
            let kinds = (byKind[position] ?? [:])
                .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
                .map { KindCount(kind: $0.key, count: $0.value) }
            let causes: [CauseBucket] = (byCause[position] ?? [:])
                .sorted { ($0.value, $1.key.rawValue) > ($1.value, $0.key.rawValue) }
                .map { entry in
                    let raw = names[position]?[entry.key] ?? [:]
                    let ranked = showsNames(entry.key)
                        ? raw.sorted { ($0.value, $1.key) > ($1.value, $0.key) } : []
                    let top = ranked.prefix(Self.nameCap).map { NameCount(name: $0.key, count: $0.value) }
                    return CauseBucket(cause: entry.key, count: entry.value,
                                       topNames: Array(top),
                                       moreNames: max(0, ranked.count - Self.nameCap))
                }
            buckets.append(PositionBucket(position: position, rewritten: r, reverted: rv, kept: k,
                                          rewrittenByKind: kinds, causes: causes))
        }
        self.positions = buckets
    }

    // MARK: - Rendering

    public func formatted(identity: DecisionRenderer.Identity) -> String {
        func anon(_ name: String) -> String {
            switch identity { case .real: return name; case .anonymized: return Anon.forced(name) }
        }
        func grouped(_ n: Int) -> String {
            let digits = Array(String(n))
            var out = "", count = 0
            for ch in digits.reversed() {
                if count != 0 && count % 3 == 0 { out.append(",") }
                out.append(ch); count += 1
            }
            return String(out.reversed())
        }
        func names(_ b: CauseBucket) -> String {
            if b.cause == .candidateHasNoObf { return "(resolved, declaration deliberately not renamed)" }
            if b.cause == .noDecision { return "(reporter gap)" }
            guard !b.topNames.isEmpty else { return "" }
            var s = b.topNames.map { "\(anon($0.name)) \($0.count)" }.joined(separator: " · ")
            if b.moreNames > 0 { s += "  (+\(b.moreNames) more)" }
            return s
        }

        var lines = ["=== Use-site resolution ==="]
        lines.append("\(grouped(totalUseSites)) use-sites  ·  \(grouped(totalRewritten)) rewritten"
                     + "  ·  \(grouped(totalReverted)) reverted  ·  \(grouped(totalKept)) kept")
        for p in positions {
            lines.append("")
            lines.append("\(pad(p.position.rawValue, 16)) \(grouped(p.total))"
                         + "   rewritten \(grouped(p.rewritten)) · reverted \(grouped(p.reverted)) · kept \(grouped(p.kept))")
            if !p.rewrittenByKind.isEmpty {
                lines.append("  rewritten by kind:  "
                             + p.rewrittenByKind.map { "\($0.kind) \(grouped($0.count))" }.joined(separator: " · "))
            }
            for c in p.causes {
                let n = names(c)
                lines.append("  \(pad(c.cause.rawValue, 24)) \(grouped(c.count))" + (n.isEmpty ? "" : "   \(n)"))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }
}

extension UseSitePosition {
    /// Fixed print order for the report (byte-stable across runs).
    static let orderedForReport: [UseSitePosition] =
        [.memberAccess, .bareCall, .valueReference, .enumShorthand, .typeReference, .other]
}
