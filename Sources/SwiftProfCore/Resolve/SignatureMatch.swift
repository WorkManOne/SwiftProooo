import Foundation

/// The ONE answer to "do these two callables have compatible parameter signatures" — external
/// labels equal AND no KNOWN parameter type differs. Three passes need it and must not drift apart:
/// `WitnessLinker` (requirement ↔ witness), `OverrideLinker` (base ↔ override), and the Protector's
/// unknown-external protect-all exemption (`witnessesLocalRequirement`, B-FIX-89/90). Two copies had
/// already appeared, byte-identical except for the arity-mismatch line; a third copy in the Protector
/// is exactly the "a simpler private copy survives in another file" anti-pattern, so it lives here.
///
/// Two type-name strings that differ TEXTUALLY may still denote the SAME type (a witness writes
/// `Inner` while the requirement writes `Outer.Inner`; a witness spells a dictionary key through a
/// typealias) — `TypeNameEquivalence.sameType` decides that structurally, resolving each LEAF to a
/// Symbol (B-FIX-27). An UNKNOWN (untracked) parameter type is a WILDCARD: it matches, so a genuine
/// link whose type we could not model is never MISSED — the safe direction for LINKING, and also for
/// the Protector exemption (an unknown-typed local witness stays exempted, i.e. obfuscatable, rather
/// than force-protected). What the exemption relies on is the CONVERSE, already covered here: two
/// KNOWN types that DIFFER return `false`, so a member whose types match the local requirement is
/// exempted while one whose types match a DIFFERENT (external) requirement of the same name+labels is
/// not — closing the B-FIX-89 residual whenever the colliding types are known.
public enum SignatureMatch {
    /// - Parameter arityMismatch: the answer when the label arrays are equal but the recorded
    ///   parameter-TYPE arrays differ in length (a should-not-happen edge, since a label slot exists
    ///   per parameter). `WitnessLinker` passes `true` (never miss a witness); `OverrideLinker` and the
    ///   Protector exemption pass `false` (a differing arity is not the same member — the safe answer
    ///   for "is this the base I override" and "is this the local witness I may release").
    public static func compatibleParameters(_ a: Symbol, _ b: Symbol, in table: SymbolTable,
                                            arityMismatch: Bool) -> Bool {
        guard (table.functionParamLabels[a.id] ?? []) == (table.functionParamLabels[b.id] ?? []) else {
            return false
        }
        let ta = table.functionParamTypes[a.id] ?? []
        let tb = table.functionParamTypes[b.id] ?? []
        guard ta.count == tb.count else { return arityMismatch }
        for (x, y) in zip(ta, tb) {
            guard let x, let y else { continue }   // wildcard — an untracked type never misses a link
            if TypeNameEquivalence.sameType(x, inScope: a.scope, module: a.module.name,
                                            y, inScope: b.scope, module: b.module.name,
                                            table: table) { continue }
            return false
        }
        return true
    }
}
