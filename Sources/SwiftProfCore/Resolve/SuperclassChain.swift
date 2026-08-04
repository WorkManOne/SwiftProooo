import Foundation
import SwiftSyntax

/// The one answer to "which LOCAL classes does this class inherit from, nearest ancestor first".
///
/// Three consumers need the same walk and must not drift apart: `SuperclassVisibility` (copies an
/// ancestor's non-callable members into the subclass scope), `OverrideLinker` (pairs an `override`
/// with the base member it overrides) and `ResolutionVisitor.inheritedMembers` (completes a member
/// candidate set with inherited declarations of the KIND the use-site's position demands, B-FIX-47).
/// Two of them had a byte-identical private copy of `superclass(of:)` + `preferredClass`; the third
/// would have made three, and a divergence between them is a wrong view of the hierarchy, which is
/// a wrong rename no safety net catches.
///
/// Safety rules the walk carries (all three consumers depend on every one of them):
///   - **Module-aware and fail-closed** (`SymbolTable.preferredType`): the same-module candidate
///     wins; a sole cross-module candidate is accepted; several same-named classes in OTHER modules
///     with none here ⇒ stop (never an arbitrary `.first`, which would read the wrong module's
///     members).
///   - An **EXTERNAL** superclass (`UIViewController`, …) is not in our table ⇒ doesn't resolve ⇒
///     the chain stops there, as it must: its members stay original.
///   - A **generic** superclass (`Base<T>`) resolves by its base name (`Base`); element substitution
///     is not modelled (the documented partial-generics limit).
///   - The **PRIMARY declaration only**, on purpose: Swift does not allow an extension to add a
///     superclass, so `SymbolTable.conformanceNames` would contribute nothing but protocol names.
///   - A **cycle guard**, so invalid input cannot hang the pipeline.
public enum SuperclassChain {
    /// Every LOCAL ancestor of `cls`, NEAREST FIRST. Empty when the superclass is external, absent
    /// or ambiguous. Callers that want "the nearest ancestor declaring X" take the first hit while
    /// iterating — that ordering IS Swift's shadowing rule between levels.
    public static func ancestors(of cls: Symbol, in table: SymbolTable) -> [Symbol] {
        var result: [Symbol] = []
        var visited: Set<Int> = [cls.id]
        var current = cls
        while let superSym = superclass(of: current, in: table), !visited.contains(superSym.id) {
            visited.insert(superSym.id)
            result.append(superSym)
            current = superSym
        }
        return result
    }

    /// The single LOCAL class `sym` directly inherits from, or nil. A class has at most one
    /// superclass; the remaining inheritance entries are protocols, which resolve to nil here.
    public static func superclass(of sym: Symbol, in table: SymbolTable) -> Symbol? {
        for name in InheritanceClause.names(atOffset: sym.declOffset, in: sym.file.syntax) {
            var base = name
            if let lt = base.firstIndex(of: "<") { base = String(base[..<lt]) }   // strip `Base<T>`
            if let cls = table.preferredType(kind: .class, named: base, inModule: sym.module.name) {
                return cls
            }
        }
        return nil
    }
}
