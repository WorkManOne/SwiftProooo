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
/// — NOT methods. Reason: `ResolutionPass.resolveCall` returns early when the lexical scope yields a
/// single same-named callable, BEFORE consulting the global `table.callables(named:)` fallback that
/// gathers cross-type/extension overloads. Injecting an inherited method into the subclass scope can
/// make it a false UNIQUE scope match and shadow a protocol-extension overload the call actually
/// selects (regressed `testOverloadByArgType_…`). Properties never overload, so they have no such
/// hazard. Inherited *method* uses are already covered for bare calls (the global callable fallback);
/// the residual `self.inheritedMethod()` member-access case is left to a future superclass-aware
/// member resolver / `OverrideLinker`.
///
/// Safety (mirrors ConformanceVisibility's B-FIX-5 discipline):
///   - Superclass name resolution is **module-aware and fail-closed** (`preferredClass`): the
///     same-module candidate wins; a sole cross-module candidate is accepted; several same-named
///     classes in OTHER modules with none here ⇒ skip (never an arbitrary `.first`, which would copy
///     the wrong module's members and produce a wrong rename).
///   - An EXTERNAL superclass (UIKit's `UIViewController`, …) is not in our table ⇒ doesn't resolve
///     ⇒ the chain stops there (its members stay external/original, as they must).
///   - Generic superclasses (`Base<T>`) resolve by their base name (`Base`); element substitution is
///     not modelled (the documented partial-generics limit).
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
            var visitedClassIds: Set<Int> = [sym.id]   // cycle guard (invalid Swift, but be safe)
            var current = sym
            while let superSym = superclass(of: current),
                  !visitedClassIds.contains(superSym.id) {
                visitedClassIds.insert(superSym.id)
                if let superParent = superSym.scope,
                   let superScope = superParent.children.first(where: { $0.owner?.id == superSym.id }) {
                    for member in superScope.symbols
                    where copyableMember(member.kind) && !seenNames.contains(member.name) {
                        inner.add(symbol: member)
                        seenNames.insert(member.name)
                        inherited += 1
                    }
                }
                current = superSym
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

    /// The single LOCAL class a class directly inherits from, or nil (external / no superclass /
    /// ambiguous). A class has at most one superclass; the remaining inheritance entries are
    /// protocols, which resolve to nil here.
    private func superclass(of sym: Symbol) -> Symbol? {
        for name in inheritanceNames(for: sym) {
            // Strip generic args (`Base<T>` → `Base`) before lookup — partial-generics limit applies.
            var base = name
            if let lt = base.firstIndex(of: "<") { base = String(base[..<lt]) }
            if let cls = preferredClass(named: base, forModule: sym.module.name) {
                return cls
            }
        }
        return nil
    }

    /// Module-aware, fail-closed class lookup (same discipline as
    /// `ConformanceVisibility.preferredProtocol`): same-module candidate wins; a single cross-module
    /// candidate is accepted; multiple cross-module candidates with none in `module` ⇒ nil.
    private func preferredClass(named name: String, forModule module: String) -> Symbol? {
        let classes = table.types(named: name).filter { $0.kind == .class }
        if let same = classes.first(where: { $0.module.name == module }) { return same }
        return classes.count == 1 ? classes[0] : nil
    }

    private func inheritanceNames(for sym: Symbol) -> [String] {
        let collector = SuperInheritanceCollector(targetOffset: sym.declOffset)
        collector.walk(sym.file.syntax)
        return collector.collected
    }
}

private final class SuperInheritanceCollector: SyntaxVisitor {
    let targetOffset: Int
    var collected: [String] = []
    init(targetOffset: Int) {
        self.targetOffset = targetOffset
        super.init(viewMode: .sourceAccurate)
    }
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.name.positionAfterSkippingLeadingTrivia.utf8Offset == targetOffset {
            if let inh = node.inheritanceClause {
                for entry in inh.inheritedTypes { collected.append(entry.type.trimmedDescription) }
            }
            return .skipChildren
        }
        return .visitChildren
    }
}
