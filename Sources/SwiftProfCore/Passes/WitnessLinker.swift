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
    /// A witness also has to match the requirement's KIND. A protocol may overload ONE name across
    /// kinds (`var pf2: Bool { get set }` next to `func pf2(for:) -> Bool` — legal Swift), and
    /// `sameName.first` for a property/typealias witness was kind-blind: with the method declared
    /// first, the class's PROPERTY linked to the METHOD requirement and adopted its obf, while the
    /// protocol's property requirement kept its own ⇒ "does not conform to protocol", a wrong-rename
    /// red RollbackPass cannot catch (no original name survives). Kinds pair as
    /// property↔property, method↔method (plus signature) and typealias↔associatedtype.
    private func matchRequirement(_ member: Symbol, in reqs: [Symbol]) -> Symbol? {
        let sameName = reqs.filter { $0.name == member.name }
        guard !sameName.isEmpty else { return nil }
        switch member.kind {
        case .method:
            return sameName.first { $0.kind == .method && signaturesCompatible(member, $0) }
        case .property:
            return sameName.first { $0.kind == .property }
        case .typealias_:
            // A `typealias` witnesses an `associatedtype`; requirements never carry `.typealias_`
            // (see the collection loop in `link`), so accept both spellings defensively.
            return sameName.first { $0.kind == .associatedtype_ || $0.kind == .typealias_ }
        default:
            return nil
        }
    }

    /// Two method symbols have compatible signatures when their external labels match and no
    /// KNOWN parameter types differ. Unknown (untracked) types are treated as wildcards so we
    /// never MISS a genuine witness whose type we couldn't model. Two type-name strings that
    /// differ TEXTUALLY may still denote the SAME type (a witness writes `Inner` while the
    /// requirement writes `Outer.Inner`; a witness writes a dictionary key through a typealias) —
    /// `TypeNameEquivalence.sameType` decides that structurally, resolving each LEAF to a Symbol.
    /// Comparing the whole string (or handing a composite name to the leaf resolver, which bails
    /// on it) misses the witness link and lets both sides mint their own obf ⇒ "does not conform"
    /// (B-FIX-27).
    private func signaturesCompatible(_ a: Symbol, _ b: Symbol) -> Bool {
        guard (table.functionParamLabels[a.id] ?? []) == (table.functionParamLabels[b.id] ?? []) else {
            return false
        }
        let ta = table.functionParamTypes[a.id] ?? []
        let tb = table.functionParamTypes[b.id] ?? []
        guard ta.count == tb.count else { return true }
        for (x, y) in zip(ta, tb) {
            guard let x, let y else { continue }   // wildcard
            if TypeNameEquivalence.sameType(x, inScope: a.scope, module: a.module.name,
                                            y, inScope: b.scope, module: b.module.name,
                                            table: table) { continue }
            return false
        }
        return true
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
