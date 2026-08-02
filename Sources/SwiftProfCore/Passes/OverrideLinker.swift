import Foundation
import SwiftSyntax

/// Coordinates the obfuscated names of `override` members with the base member they override — the
/// class-inheritance analogue of `WitnessLinker` (which does the same for protocol witnesses).
///
/// Swift requires an `override func`/`var`/`subscript` to match a member of the same name (and, for
/// methods, the same signature) in an ancestor. The Planner assigns names per-symbol with no notion
/// of inheritance, so the base and each override get INDEPENDENT obfs → the compiler reports
/// "method/property does not override any … from its superclass". This is a DEFAULT-run red build
/// (no `--kinds` needed) and RollbackPass cannot catch it: when both the base decl and the override
/// decl are renamed cleanly, no original name survives in the output for the surviving-name scan to
/// trip on. (It bites computed-`var` overrides most often, because property reads resolve at the
/// use-site while member-access method calls frequently don't.)
///
/// Policy (mirrors WitnessLinker's group-rollback):
///   - Walk the LOCAL superclass chain (module-aware, fail-closed `preferredClass`) to pair each
///     override with the nearest ancestor member it overrides. Union the override + its base into
///     one group; a multi-level chain (`Base.f` ← `Mid.f` ← `Leaf.f`) collapses to one group.
///   - **Local base** → every member in the group adopts the base's obf (the base is the group's
///     only non-override root). Base + all overrides rename identically → green AND obfuscated.
///   - **External / un-renameable base** (UIKit's `UIViewController`, a read-only-module class, or a
///     base our signature model couldn't match) → the inherited name must be preserved → revert the
///     whole group (every member keeps its original name). This is the only legitimate
///     can't-obfuscate case, and it is fail-closed.
///   - If ANY member of a group is protected (e.g. `@objc`/IBAction override) or already has no obf,
///     the whole group reverts — exactly the WitnessLinker discipline.
///
/// Ordering: runs AFTER WitnessLinker so that a base member which is ALSO a protocol witness has
/// already been pinned to the requirement's obf; the override chain then adopts that same obf and
/// stays consistent with the protocol. (The narrow residual — an override that is itself a witness
/// of a protocol its base does NOT conform to — today that case is also
/// red, so this is a strict improvement.)
public final class OverrideLinker {
    public let table: SymbolTable
    public let protector: Protector
    public let logger: Logger

    /// `owner symbol id → all scopes it owns` (primary inner + extension scopes), built once (C-1).
    private var scopesByOwner: [Int: [Scope]] = [:]
    private var symbolById: [Int: Symbol] = [:]

    public init(table: SymbolTable, protector: Protector, logger: Logger) {
        self.table = table
        self.protector = protector
        self.logger = logger
    }

    public func link(map: RenameMap) {
        guard !table.overrideMemberIds.isEmpty else { return }
        buildIndexes()

        // Union-find over the symbol ids touched by override linking (overrides + their bases).
        var parent: [Int: Int] = [:]
        var externalBase: Set<Int> = []   // override ids whose base is external / un-renameable

        func ensure(_ x: Int) { if parent[x] == nil { parent[x] = x } }
        func find(_ x: Int) -> Int {
            var r = x
            while let p = parent[r], p != r { r = p }
            var c = x
            while let p = parent[c], p != r { parent[c] = r; c = p }
            return r
        }
        func union(_ a: Int, _ b: Int) { ensure(a); ensure(b); parent[find(a)] = find(b) }

        for ovId in table.overrideMemberIds {
            guard let m = symbolById[ovId], m.kind == .method || m.kind == .property else { continue }
            ensure(ovId)
            guard let cls = ownerClass(of: m) else { externalBase.insert(ovId); continue }
            if let base = findLocalBase(of: m, startingFrom: cls) {
                union(ovId, base.id)
            } else {
                externalBase.insert(ovId)
            }
        }

        // Gather components.
        var components: [Int: [Int]] = [:]
        for id in parent.keys { components[find(id), default: []].append(id) }

        var revertedGroups = 0, unifiedGroups = 0
        for (_, ids) in components {
            let members = ids.compactMap { symbolById[$0] }
            let forceRevert = members.contains { protector.isProtected($0) || map.obf(for: $0) == nil }
                || ids.contains { externalBase.contains($0) }
            if forceRevert {
                let reason = "override chain reverted — base is external/un-renameable or a member is protected"
                for s in members where map.obf(for: s) != nil { map.revert(s.id, reason: reason) }
                revertedGroups += 1
            } else {
                // Canonical = the group's only non-override root (the base). Every override adopts it.
                let canonical = members.first { !table.overrideMemberIds.contains($0.id) } ?? members[0]
                guard let canonObf = map.obf(for: canonical) else { continue }
                for s in members where s.id != canonical.id { map.assign(s, to: canonObf) }
                unifiedGroups += 1
            }
        }
        if unifiedGroups > 0 || revertedGroups > 0 {
            logger.log("OverrideLinker: \(unifiedGroups) chains unified, \(revertedGroups) reverted",
                       verbose: true)
        }
    }

    // MARK: - Base-member lookup

    /// The nearest LOCAL ancestor member that `m` overrides: walk the superclass chain and, at each
    /// ancestor, look for a member of the same kind + name (and, for methods, a compatible
    /// signature). Returns nil when the base is external / unresolved (→ caller reverts the group).
    private func findLocalBase(of m: Symbol, startingFrom cls: Symbol) -> Symbol? {
        var visited: Set<Int> = [cls.id]
        var current = cls
        while let superSym = superclass(of: current), !visited.contains(superSym.id) {
            visited.insert(superSym.id)
            for scope in scopesByOwner[superSym.id] ?? [] {
                for cand in scope.symbols where cand.kind == m.kind && cand.name == m.name {
                    if m.kind == .property || signaturesCompatible(m, cand) { return cand }
                }
            }
            current = superSym
        }
        return nil
    }

    /// The class symbol that owns `m`'s declaration (the type-scope owner), or nil.
    private func ownerClass(of m: Symbol) -> Symbol? {
        guard let owner = m.scope?.owner, owner.kind == .class else { return nil }
        return owner
    }

    /// The single LOCAL class `sym` directly inherits from, or nil (external / none / ambiguous).
    /// A class's first resolvable inheritance entry is its superclass; the rest are protocols.
    ///
    /// Primary declaration only, on purpose (same reason as SuperclassVisibility): an extension
    /// cannot add a superclass, so `SymbolTable.conformanceNames` would only add protocol names.
    private func superclass(of sym: Symbol) -> Symbol? {
        for name in inheritanceNames(for: sym) {
            var base = name
            if let lt = base.firstIndex(of: "<") { base = String(base[..<lt]) }   // strip `Base<T>`
            if let cls = preferredClass(named: base, forModule: sym.module.name) { return cls }
        }
        return nil
    }

    /// Module-aware, fail-closed class lookup (same discipline as
    /// `SuperclassVisibility.preferredClass` / `ConformanceVisibility.preferredProtocol`).
    private func preferredClass(named name: String, forModule module: String) -> Symbol? {
        table.preferredType(kind: .class, named: name, inModule: module)
    }

    /// Method signature compatibility for override pairing: external labels equal and no KNOWN
    /// parameter type differs (nil = untracked = wildcard, so we never miss a real override). A valid
    /// Swift override has an identical signature, so a mismatch here means "not this overload" — and
    /// if it leaves no local base at all the group is reverted (fail-closed). Return type is not
    /// compared (covariant overrides are allowed).
    ///
    /// Type comparison goes through `TypeNameEquivalence.sameType` (B-FIX-27): the base and the
    /// override are written in DIFFERENT lexical positions, so the same type is routinely spelled
    /// differently (bare vs qualified, through a typealias). The old plain string compare missed
    /// those pairs → no local base found → the whole chain reverted (under-obfuscation).
    private func signaturesCompatible(_ a: Symbol, _ b: Symbol) -> Bool {
        guard (table.functionParamLabels[a.id] ?? []) == (table.functionParamLabels[b.id] ?? []) else {
            return false
        }
        let ta = table.functionParamTypes[a.id] ?? []
        let tb = table.functionParamTypes[b.id] ?? []
        guard ta.count == tb.count else { return false }
        for (x, y) in zip(ta, tb) {
            guard let x, let y else { continue }            // wildcard
            if TypeNameEquivalence.sameType(x, inScope: a.scope, module: a.module.name,
                                            y, inScope: b.scope, module: b.module.name,
                                            table: table) { continue }
            return false
        }
        return true
    }

    // MARK: - Indexes

    private func buildIndexes() {
        scopesByOwner.removeAll()
        symbolById.removeAll()
        for s in table.symbols { symbolById[s.id] = s }
        for (_, fileScope) in table.fileScopes { collect(fileScope) }
    }

    private func collect(_ scope: Scope) {
        if let ownerId = scope.owner?.id { scopesByOwner[ownerId, default: []].append(scope) }
        for c in scope.children { collect(c) }
    }

    private func inheritanceNames(for sym: Symbol) -> [String] {
        InheritanceClause.names(atOffset: sym.declOffset, in: sym.file.syntax)
    }
}
