import Foundation

/// Merges extension scopes into the canonical inner scope of each type.
///
/// Before unification: `class Foo { ... }` and `extension Foo { ... }` produce two sibling
/// scopes under file scope, both with `owner = Foo`. Lookups from inside Foo's body do NOT
/// see members declared in extensions, and vice-versa.
///
/// After unification:
/// - The class/struct/enum decl's inner scope ("canonical") receives all symbols from every
///   extension scope of the same type (by reference; symbols themselves unchanged).
/// - Each extension scope's `parent` is rewired to the canonical scope, so lookups from inside
///   the extension chain through the canonical scope and see the type's own members.
///
/// Pure syntactic, no semantic dependency.
public final class ScopeUnification {
    public let table: SymbolTable
    public let logger: Logger

    public init(table: SymbolTable, logger: Logger) {
        self.table = table
        self.logger = logger
    }

    public func run() {
        // Collect all scopes by their owner symbol id.
        var scopesByOwner: [Int: [Scope]] = [:]
        for (_, fileScope) in table.fileScopes {
            collect(fileScope, into: &scopesByOwner)
        }

        for typeSym in table.symbols where isTypeKind(typeSym.kind) {
            guard let group = scopesByOwner[typeSym.id], group.count > 1 else { continue }
            // Canonical: the scope that is the type's own inner scope (direct child of typeSym.scope).
            guard let parent = typeSym.scope else { continue }
            guard let canonical = parent.children.first(where: { $0.owner?.id == typeSym.id }) else { continue }
            var merged = 0
            for other in group where other !== canonical {
                for s in other.symbols {
                    canonical.add(symbol: s)
                    merged += 1
                }
                other.parent = canonical
            }
            if merged > 0 {
                logger.log("unified \(merged) members into \(typeSym.name) (across \(group.count) scopes)", verbose: true)
            }
        }
    }

    private func collect(_ scope: Scope, into out: inout [Int: [Scope]]) {
        if let ownerId = scope.owner?.id {
            out[ownerId, default: []].append(scope)
        }
        for c in scope.children { collect(c, into: &out) }
    }

    private func isTypeKind(_ k: SymbolKind) -> Bool {
        switch k { case .class, .struct, .enum, .protocol: return true; default: return false }
    }
}
