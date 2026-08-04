import Foundation
import SwiftSyntax

/// The one answer to "which LOCAL protocols does this type conform to, nearest first".
///
/// The conformance analogue of `SuperclassChain`, and the second half of the same invariant: a
/// type's member set is its OWN declarations UNIONED with everything it inherits, and a protocol
/// EXTENSION default is inherited exactly like a superclass method. `ConformanceVisibility` copies
/// those defaults into the conformer's scope, but shadows them BY NAME, so a conformer declaring the
/// name at ANY kind loses the default — `final class Impl: Runner { var go: Bool }` over
/// `extension Runner { func go() -> String }` (legal Swift, the property does NOT witness the
/// requirement; the default does). `ResolutionVisitor.inheritedMembers` completes the candidate set
/// from here instead, in the resolver, injecting nothing into any scope (B-FIX-48).
///
/// Safety rules the walk carries (identical in spirit to `SuperclassChain`'s):
///   - **BOTH halves of a conformance** (`SymbolTable.conformanceNames`): the primary declaration's
///     inheritance clause AND the conformances declared on `extension Impl: Runner {}` — a
///     conformance is a conformance wherever it is written (B-FIX-6).
///   - **Module-aware and fail-closed** (`ConformanceVisibility.preferredProtocol`, the same helper
///     the pass itself uses, so pass and resolver never disagree about which protocol a name means):
///     the same-module candidate wins; a sole cross-module candidate is accepted; several same-named
///     protocols in OTHER modules with none here ⇒ skip (never an arbitrary `.first`, B-FIX-5).
///   - **Protocol-to-protocol inheritance** is followed transitively (`protocol Mid: Pinger` makes
///     `Pinger`'s defaults reachable from a `Mid` conformer), breadth-first so DIRECT conformances
///     come before inherited ones.
///   - A name that is not a local protocol — an EXTERNAL protocol (`Codable`, `View`) or the
///     SUPERCLASS entry of a class's clause — does not resolve here and is simply skipped: an
///     external protocol's members are not in our table and must stay original.
///   - A **generic** conformance (`P<Int>`) resolves by its base name; substitution is not modelled,
///     the same documented partial-generics limit `SuperclassChain` carries.
///   - A **cycle guard**, so invalid input cannot hang the pipeline.
public enum ConformanceChain {
    /// Every LOCAL protocol `sym` conforms to, directly or transitively, NEAREST FIRST. Empty when
    /// the type declares no conformance, or when every name it declares is external or ambiguous.
    ///
    /// Callers that want "the nearest declaration of X" take the first hit while iterating. Between
    /// two UNRELATED protocols both providing a default of one name there is no Swift shadowing rule
    /// to model — such a call is "ambiguous use" at the source level, so that input never reaches a
    /// green control build.
    public static func protocols(of sym: Symbol, in table: SymbolTable) -> [Symbol] {
        var result: [Symbol] = []
        var visited: Set<Int> = [sym.id]
        var queue: [Symbol] = [sym]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            for written in table.conformanceNames(of: current) {
                var name = written
                if let lt = name.firstIndex(of: "<") { name = String(name[..<lt]) }   // strip `P<T>`
                guard let proto = ConformanceVisibility.preferredProtocol(
                        in: table, named: name, forModule: current.module.name),
                      !visited.contains(proto.id)
                else { continue }
                visited.insert(proto.id)
                result.append(proto)
                queue.append(proto)
            }
        }
        return result
    }
}
