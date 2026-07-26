import Foundation
import SwiftSyntax

/// For each type T conforming to one of OUR protocols P, pair each method/property in T with
/// the same-named requirement in P. Unify their obfuscated names so that calling conventions
/// remain consistent after rewrite.
///
/// Unification policy (rollback-style):
/// - If at least one party in the group is protected (= no obf assigned) → revert obf for the
///   whole group. Both sides keep their original names; the build stays green.
/// - Otherwise → all parties adopt the obf of the protocol requirement (canonical).
public final class WitnessLinker {
    public let table: SymbolTable
    public let protector: Protector
    public let logger: Logger

    /// `owner symbol id → all scopes it owns` (primary inner scope + every extension scope). Built
    /// ONCE per run so `membersOfType` is O(1) lookup instead of walking every scope in the table
    /// per type-conformance — the old `allScopesInTable()` was O(types × scopes) (C-1).
    private var scopesByOwner: [Int: [Scope]] = [:]

    public init(table: SymbolTable, protector: Protector, logger: Logger) {
        self.table = table
        self.protector = protector
        self.logger = logger
    }

    public func link(map: RenameMap) {
        buildScopeIndex()
        // Build: protocol symbol → its requirement symbols (a LIST — a protocol may declare
        // several same-named overloaded requirements, distinguished by signature).
        var requirementsByProtocol: [Int: [Symbol]] = [:]
        for sym in table.symbols where sym.kind == .protocol {
            guard let parent = sym.scope,
                  let inner = parent.children.first(where: { $0.owner?.id == sym.id })
            else { continue }
            var reqs: [Symbol] = []
            for member in inner.symbols
            where member.kind == .method || member.kind == .property || member.kind == .associatedtype_ {
                reqs.append(member)
            }
            requirementsByProtocol[sym.id] = reqs
        }
        guard !requirementsByProtocol.isEmpty else { return }

        // For each type T, find which of OUR protocols it conforms to and pair members.
        // Groups indexed by requirement-symbol-id; value = all witnesses (including the requirement).
        var groups: [Int: [Symbol]] = [:]

        for sym in table.symbols where isTypeKind(sym.kind) && sym.kind != .protocol {
            // Conformances from the primary decl AND from extensions (`extension S: P`), so a
            // witness declared in an extension is still paired with its requirement (B-FIX-6).
            var inherits = inheritanceNames(for: sym)
            inherits.append(contentsOf: table.extensionConformanceNames(ownerId: sym.id))
            for name in inherits {
                // Find a local protocol matching this name, preferring one in the conformer's
                // own module. Fail closed on ambiguous cross-module collisions rather than `.first`
                // (B-FIX-5): an arbitrary pick links witnesses to the wrong-module requirement.
                guard let proto = ConformanceVisibility.preferredProtocol(
                          in: table, named: name, forModule: sym.module.name),
                      let reqs = requirementsByProtocol[proto.id]
                else { continue }
                // Members of T (and members of any extension of T).
                let memberSymbols = membersOfType(sym)
                for member in memberSymbols
                where member.kind == .method || member.kind == .property || member.kind == .typealias_ {
                    if let req = matchRequirement(member, in: reqs) {
                        groups[req.id, default: [req]].append(member)
                    }
                }
            }
        }

        for (_, group) in groups {
            let anyProtected = group.contains { protector.isProtected($0) || map.obf(for: $0) == nil }
            if anyProtected {
                // Revert: remove obf for everyone in the group.
                let reason = "witness group reverted — a member of protocol requirement '\(group[0].name)' is protected"
                for s in group {
                    if map.obf(for: s) != nil {
                        map.revert(s.id, reason: reason)
                    }
                }
                logger.log("witness rollback for group .\(group[0].name) (\(group.count) members)", verbose: true)
            } else {
                // Canonical: take the requirement's obf and force it onto witnesses.
                let canonical = group[0]   // by construction, [0] is the protocol requirement
                guard let canonObf = map.obf(for: canonical) else { continue }
                for s in group.dropFirst() {
                    map.assign(s, to: canonObf)
                }
            }
        }

        linkProtocolDefaults(map: map)
    }

    /// A protocol requirement and its DEFAULT IMPLEMENTATION (a same-name, same-signature method in
    /// the protocol's OWN `extension`) are the same member — Swift satisfies the requirement with
    /// the default and dispatches every call through one witness. The loop above only pairs
    /// witnesses in CONCRETE conformers (it skips protocols), so without this the two get DIFFERENT
    /// obfs: the protocol would declare `m0(...)` while its extension declares `m1(...)`, and `m1`
    /// no longer satisfies `m0` → conformers relying on the default break. It also leaves a call on
    /// a protocol-typed value (`p.f1(...)`) facing two same-named candidates the resolver can't
    /// disambiguate → the use-site isn't rewritten. Unify each (requirement, default-impl) pair to
    /// one obf (group-revert if either is protected), mirroring the witness policy above.
    private func linkProtocolDefaults(map: RenameMap) {
        for proto in table.symbols where proto.kind == .protocol {
            // Group this protocol's folded members (requirements + extension defaults) by name,
            // de-duplicating by symbol id (ScopeUnification may surface a member in >1 owned scope).
            var byName: [String: [Symbol]] = [:]
            var seen = Set<Int>()
            for m in membersOfType(proto)
            where (m.kind == .method || m.kind == .property) && seen.insert(m.id).inserted {
                byName[m.name, default: []].append(m)
            }
            for (_, sameName) in byName where sameName.count > 1 {
                // Within a name, cluster by compatible signature so genuine overloads (same name,
                // different signature) stay separate — only the requirement + its same-signature
                // default implementation land in the same cluster. Properties carry no signature.
                var clusters: [[Symbol]] = []
                for m in sameName {
                    if let i = clusters.firstIndex(where: {
                        $0[0].kind == m.kind && (m.kind == .property || signaturesCompatible($0[0], m))
                    }) {
                        clusters[i].append(m)
                    } else {
                        clusters.append([m])
                    }
                }
                for group in clusters where group.count > 1 {
                    let anyProtected = group.contains { protector.isProtected($0) || map.obf(for: $0) == nil }
                    if anyProtected {
                        let reason = "protocol default impl reverted — requirement/default '\(group[0].name)' is protected"
                        for s in group where map.obf(for: s) != nil { map.revert(s.id, reason: reason) }
                    } else if let canonObf = map.obf(for: group[0]) {
                        for s in group.dropFirst() { map.assign(s, to: canonObf) }
                    }
                }
            }
        }
    }

    private func isTypeKind(_ k: SymbolKind) -> Bool {
        switch k { case .class, .struct, .enum, .protocol: return true; default: return false }
    }

    /// Find the requirement a member actually witnesses. Same-named requirement is necessary but
    /// NOT sufficient: a method witnesses a requirement only when their SIGNATURES match (labels
    /// + parameter types). Otherwise a same-named overload (`f1(par1: Token, par2: Token)`) would
    /// be wrongly paired with an unrelated requirement (`f1(par1: String, par2: String)`) and, if
    /// the requirement is protected/read-only, dragged into a group rollback — un-obfuscating an
    /// overload that has nothing to do with the protocol.
    private func matchRequirement(_ member: Symbol, in reqs: [Symbol]) -> Symbol? {
        let sameName = reqs.filter { $0.name == member.name }
        guard !sameName.isEmpty else { return nil }
        if member.kind == .method {
            return sameName.first { $0.kind == .method && signaturesCompatible(member, $0) }
        }
        // Property / typealias witnesses carry no signature — match by name.
        return sameName.first
    }

    /// Two method symbols have compatible signatures when their external labels match and no
    /// KNOWN parameter types differ. Unknown (untracked) types are treated as wildcards so we
    /// never MISS a genuine witness whose type we couldn't model. When two type-name strings
    /// differ TEXTUALLY (e.g. a witness writes `Inner` while the protocol requirement writes
    /// `Outer.Inner` for the SAME nested enum), we resolve both names to Symbols and compare by
    /// Symbol identity — string compare alone treats the same type as different and misses the
    /// witness link.
    private func signaturesCompatible(_ a: Symbol, _ b: Symbol) -> Bool {
        guard (table.functionParamLabels[a.id] ?? []) == (table.functionParamLabels[b.id] ?? []) else {
            return false
        }
        let ta = table.functionParamTypes[a.id] ?? []
        let tb = table.functionParamTypes[b.id] ?? []
        guard ta.count == tb.count else { return true }
        for (x, y) in zip(ta, tb) {
            guard let x, let y else { continue }   // wildcard
            let bx = bareName(x), by = bareName(y)
            if bx == by { continue }
            // Different strings — handles bare-vs-qualified, typealias resolution, etc.
            if let xSym = resolveTypeName(bx, fromScope: a.scope, moduleHint: a.module.name),
               let ySym = resolveTypeName(by, fromScope: b.scope, moduleHint: b.module.name),
               xSym.id == ySym.id {
                continue
            }
            return false
        }
        return true
    }

    private func bareName(_ s: String) -> String {
        var n = s
        while n.hasSuffix("?") || n.hasSuffix("!") { n = String(n.dropLast()) }
        return n
    }

    /// Resolve a type-name string written at `scope`'s lexical position to a Symbol (handles
    /// bare names visible via scope chain, dotted qualified names, optional/array suffixes).
    private func resolveTypeName(_ name: String, fromScope scope: Scope?, moduleHint: String) -> Symbol? {
        guard let scope = scope else { return nil }
        return TypeResolver(table: table, preferredModule: moduleHint)
            .typeSymbol(forQualifiedName: name, in: scope)
    }

    private func membersOfType(_ sym: Symbol) -> [Symbol] {
        var out: [Symbol] = []
        // All scopes owned by this type symbol (primary inner + extensions), from the prebuilt
        // index. `scope.owner == sym` already excludes the type's enclosing/parent scope.
        for scope in scopesByOwner[sym.id] ?? [] {
            out.append(contentsOf: scope.symbols)
        }
        return out
    }

    /// Build `scopesByOwner` once by walking every file scope. The old per-type `allScopesInTable()`
    /// re-walked the whole tree for each type — O(types × scopes) (C-1).
    private func buildScopeIndex() {
        scopesByOwner.removeAll()
        for (_, fileScope) in table.fileScopes {
            collect(fileScope)
        }
    }

    private func collect(_ scope: Scope) {
        if let ownerId = scope.owner?.id {
            scopesByOwner[ownerId, default: []].append(scope)
        }
        for c in scope.children { collect(c) }
    }

    private func inheritanceNames(for sym: Symbol) -> [String] {
        InheritanceClause.names(atOffset: sym.declOffset, in: sym.file.syntax)
    }
}
