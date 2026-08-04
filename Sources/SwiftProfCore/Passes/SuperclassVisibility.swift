import Foundation
import SwiftSyntax

/// Makes a LOCAL superclass's members visible in subclass scopes — the class-inheritance analogue
/// of `ConformanceVisibility` (which does the same for protocol defaults).
///
/// Swift rule: `class Sub: Base { … }` inherits `Base`'s stored/computed properties, methods and
/// nested types, and can reference them via implicit `self` (bare `prop` / `self.prop` /
/// `self.method()`). Our scope tree is purely lexical and does NOT model inheritance, so without
/// this pass an inherited member use-site resolves to nothing → it stays the original name while
/// `Base`'s decl is obfuscated → desync → RollbackPass reverts `Base`'s member (under-obfuscation
/// across the whole class hierarchy). NOTE: bare inherited *method* CALLS were already rescued by
/// the global `table.callables(named:)` fallback in `ResolutionPass.resolveCall`, but inherited
/// *property* reads and `self.method()` member-access calls had no equivalent — this closes both.
///
/// We model it by **copying references** to each ancestor's members into the subclass's canonical
/// scope (same mechanism ConformanceVisibility uses), walking the FULL superclass chain so a
/// grand-parent's members are visible too. A member name the subclass already declares (an OVERRIDE)
/// is NOT copied — the subclass's own decl shadows it (and the base/override obf coordination is the
/// separate, still-open `OverrideLinker` concern; this pass does not touch overridden members).
///
/// **Only NON-callable members are copied** (stored/computed properties, nested types, typealiases)
/// — NOT methods, and this is still deliberate. Reason: `ResolutionPass.resolveCall` returns early
/// when the lexical scope yields a single same-named callable, BEFORE consulting the global
/// `table.callables(named:)` fallback that gathers cross-type/extension overloads. Injecting an
/// inherited method into the subclass scope can make it a false UNIQUE scope match and shadow a
/// protocol-extension overload the call actually selects (regressed `testOverloadByArgType_…`).
/// Properties never overload, so they have no such hazard.
///
/// Inherited *method* CALLS are therefore covered elsewhere, and both routes are now closed:
/// the bare `inheritedMethod()` form by the global callable fallback above, and the
/// `sub.inheritedMethod()` / `self.inheritedMethod()` MEMBER-ACCESS form by
/// `ResolutionVisitor.inheritedMembers` (B-FIX-47), which completes the candidate set from the
/// superclass chain inside the RESOLVER — no symbol is injected into any scope, so
/// `resolveCall`'s precedence is untouched and the regression above cannot come back.
///
/// The name-keyed `seenNames` shadowing here is likewise kind-BLIND on purpose: a subclass
/// `func flag()` blocks the copy of an ancestor's `var flag`, which is exactly right for this pass
/// (copying it would inject a mixed-kind set into the scope) and is handled at the use-site by the
/// same B-FIX-47 completion.
///
/// Safety (mirrors ConformanceVisibility's B-FIX-5 discipline): the chain walk, its module-aware
/// fail-closed superclass lookup, the external-superclass stop and the generics limit all live in
/// `SuperclassChain` — one implementation shared with `OverrideLinker` and the resolver.
public final class SuperclassVisibility {
    public let table: SymbolTable
    public let logger: Logger

    public init(table: SymbolTable, logger: Logger) {
        self.table = table
        self.logger = logger
    }

    public func run() {
        var inherited = 0
        for sym in table.symbols where sym.kind == .class {
            guard let parent = sym.scope,
                  let inner = parent.children.first(where: { $0.owner?.id == sym.id })
            else { continue }
            // Names already visible in the subclass (own decls + nearer-ancestor copies) shadow
            // farther ones — seed with the subclass's own members, then walk ancestors nearest-first.
            var seenNames = Set(inner.symbols.map { $0.name })
            for superSym in SuperclassChain.ancestors(of: sym, in: table) {
                if let superParent = superSym.scope,
                   let superScope = superParent.children.first(where: { $0.owner?.id == superSym.id }) {
                    for member in superScope.symbols
                    where copyableMember(member.kind) && !seenNames.contains(member.name) {
                        inner.add(symbol: member)
                        seenNames.insert(member.name)
                        inherited += 1
                    }
                }
            }
        }
        if inherited > 0 {
            logger.log("SuperclassVisibility: \(inherited) inherited member references added")
        }
    }

    /// Member kinds copied into a subclass scope: NON-callable inherited members only — properties,
    /// nested types, typealiases. METHODS are excluded on purpose (copying one can shadow the global
    /// overload-resolution fallback — see the type doc). `init` and enum cases are not inherited as
    /// implicit-self members.
    private func copyableMember(_ k: SymbolKind) -> Bool {
        switch k {
        case .property, .typealias_, .class, .struct, .enum: return true
        default: return false
        }
    }

}
