import Foundation
import SwiftSyntax

/// Resolves the owner type of every `extension` scope, after the full SymbolTable is built.
///
/// DeclarationPass intentionally leaves extension owners nil: during that pass the table is only
/// partially populated and picking `table.types(named:).first` is registration-order-dependent —
/// it can attach an extension to a foreign module's same-named type, after which ScopeUnification
/// merges unrelated members into the extension's lookup scope (a root cause of wrong renames).
///
/// This pass resolves each owner with the SAME semantics used for type references at use-sites
/// (`TypeResolver`, module-aware): the extension binds to the type a same-module reference to that
/// name would resolve to. Consistency between extension-owner and reference resolution is the
/// point — it removes the desync that produced `<wrongObf>.member`.
///
/// When the owner cannot be resolved (extends an SDK / read-only type, or an unknown name), the
/// owner is left nil and ScopeUnification simply skips that extension — safe, no cross-wiring.
///
/// Resolution runs to a FIXPOINT (B-FIX-58). A type nested inside an EXTENSION of another type
/// (`extension E1 { enum E2 }`, then `extension E1.E2 { … }`) is not reachable by the plain
/// module-aware walk here: `typeSymbol(forQualifiedName: "E1.E2")` looks the middle segment `E2`
/// up in E1's PRIMARY inner scope, but `E2` lives in the `extension E1` scope and is not folded
/// into E1's canonical scope until ScopeUnification, which runs AFTER this pass. Left unresolved,
/// `extension E1.E2` was misclassified as an extension on an EXTERNAL type, its members renamed via
/// the external-unique path, and their typed use-sites (`x: E1.E2?` → `x?.member`) desynced.
/// So a nested type declared in an extension is resolved through an owner→member-types map that
/// spans extension scopes, iterated until no new owner resolves: `extension E1` resolves first
/// (trivially, a top-level name), which puts `E2` under E1 in the map, and `extension E1.E2`
/// resolves next.
public final class ExtensionOwnerResolver {
    public let table: SymbolTable
    public let logger: Logger

    public init(table: SymbolTable, logger: Logger) {
        self.table = table
        self.logger = logger
    }

    public func run() {
        var unresolved = table.extensionRefs
        var resolved = 0
        var progress = true
        while progress && !unresolved.isEmpty {
            progress = false
            var stillUnresolved: [SymbolTable.ExtensionRef] = []
            var needSlow: [SymbolTable.ExtensionRef] = []
            // Fast path: the existing module-aware resolver, unchanged. Handles the common cases —
            // a top-level extended type and a type nested inside its enclosing type's PRIMARY decl.
            for ext in unresolved {
                if let owner = fastResolve(ext) {
                    ext.scope.owner = owner
                    resolved += 1
                    progress = true
                } else {
                    needSlow.append(ext)
                }
            }
            // Slow path: a type nested inside ANOTHER extension. Its enclosing extension's owner had
            // to resolve first (it does in the fast loop above, or an earlier iteration), so the map
            // is rebuilt here to see the newly-owned extension scopes.
            if !needSlow.isEmpty {
                let membersByOwner = buildMemberTypesByOwner()
                for ext in needSlow {
                    if let owner = slowResolve(ext, membersByOwner: membersByOwner) {
                        ext.scope.owner = owner
                        resolved += 1
                        progress = true
                    } else {
                        stillUnresolved.append(ext)
                    }
                }
            }
            unresolved = stillUnresolved
        }
        for ext in unresolved { ext.scope.owner = nil }
        // Owners are final now, so the owner-keyed conformance index can be built. Every consumer of
        // `SymbolTable.conformanceNames` runs after this pass; building it here means no caller has
        // to know when the answer became stable.
        table.indexExtensionConformances()
        logger.log("extension owners resolved: \(resolved)/\(table.extensionRefs.count)", verbose: true)
    }

    /// The plain module-aware resolution (the pass's original behaviour). Returns nil for external
    /// types AND for a type nested inside another extension — the latter is what the slow path adds.
    private func fastResolve(_ ext: SymbolTable.ExtensionRef) -> Symbol? {
        guard let fileScope = table.fileScopes[ObjectIdentifier(ext.file)] else { return nil }
        let resolver = TypeResolver(table: table, preferredModule: ext.file.module.name)
        return resolver.typeSymbol(forQualifiedName: ext.extendedType.trimmedDescription, in: fileScope)
    }

    /// Resolve a dotted extended type whose middle/last segment is a type nested in an EXTENSION.
    /// Runs only when the fast path returned nil, so it can only ADD local resolutions.
    private func slowResolve(_ ext: SymbolTable.ExtensionRef,
                             membersByOwner: [Int: [Symbol]]) -> Symbol? {
        guard let fileScope = table.fileScopes[ObjectIdentifier(ext.file)] else { return nil }
        let resolver = TypeResolver(table: table, preferredModule: ext.file.module.name)
        return resolveTypeName(ext.extendedType.trimmedDescription, from: fileScope,
                               resolver: resolver, membersByOwner: membersByOwner, seen: [])
    }

    /// `membersByOwner`-aware resolution of a (possibly dotted) type name during owner resolution,
    /// while the scope tree is NOT yet unified. Mirrors `TypeResolver.typeSymbol(forQualifiedName:)`
    /// but sees types declared in EXTENSIONS, which is exactly what the fast path cannot (B-FIX-58):
    ///   - each dotted segment is looked up across ALL scopes owned by the current type
    ///     (`membersByOwner`), not just the primary inner scope;
    ///   - a typealias segment is UNWRAPPED, and its TARGET is resolved the same way — a target may
    ///     itself be a nested-in-extension type invisible to the fast path (`extension E { typealias
    ///     B = Inner }` where `Inner` is a sibling member), so unwrapping via the fast resolver alone
    ///     left the owner pointing at the typealias, its members unfolded, and the getter body's
    ///     `self` member desynced (NOT mere under-obf — it can ship red);
    ///   - an unqualified FIRST segment is resolved as an ENCLOSING type's member first (walk the
    ///     scope chain, which for a typealias target reaches the type the alias is declared in), and
    ///     only then as a top-level type via the module-aware resolver.
    /// Fail-closed: a segment that is not a locally-owned type (an external type) returns nil, so the
    /// extension stays external exactly as before. `seen` breaks typealias cycles.
    private func resolveTypeName(_ rawName: String, from scope: Scope, resolver: TypeResolver,
                                 membersByOwner: [Int: [Symbol]], seen: Set<Int>) -> Symbol? {
        let segments = Self.segments(of: rawName)
        guard let firstSeg = segments.first, !firstSeg.isEmpty else { return nil }
        // First segment: an ENCLOSING type's member (innermost owner first), else a top-level type.
        var found: Symbol?
        var s: Scope? = scope
        while let c = s {
            if let ownerId = c.owner?.id,
               let m = (membersByOwner[ownerId] ?? []).first(where: { $0.name == firstSeg && $0.kind.isTypeLike }) {
                found = m; break
            }
            s = c.parent
        }
        if found == nil { found = resolver.typeSymbol(forQualifiedName: firstSeg, in: scope) }
        guard var cur = found.map({ unwrapAlias($0, resolver: resolver, membersByOwner: membersByOwner, seen: seen) })
        else { return nil }
        for seg in segments.dropFirst() {
            guard let next = (membersByOwner[cur.id] ?? [])
                .first(where: { $0.name == seg && $0.kind.isTypeLike }) else { return nil }
            cur = unwrapAlias(next, resolver: resolver, membersByOwner: membersByOwner, seen: seen)
        }
        return cur
    }

    /// Unwrap a typealias symbol to its underlying type, resolving the target through the same
    /// `membersByOwner`-aware path (so a nested-in-extension target resolves). Non-typealias → itself.
    private func unwrapAlias(_ sym: Symbol, resolver: TypeResolver,
                             membersByOwner: [Int: [Symbol]], seen: Set<Int>) -> Symbol {
        guard sym.kind == .typealias_, !seen.contains(sym.id),
              let target = table.typealiasTarget[sym.id], let aliasScope = sym.scope else { return sym }
        return resolveTypeName(target, from: aliasScope, resolver: resolver,
                               membersByOwner: membersByOwner, seen: seen.union([sym.id])) ?? sym
    }

    /// type-symbol id → member TYPES declared in any scope owned by it, spanning extension scopes
    /// (an extension scope's owner is set as this pass resolves it, so the map grows across
    /// iterations). Mirrors the split ScopeUnification does, but keyed for lookup and types-only.
    private func buildMemberTypesByOwner() -> [Int: [Symbol]] {
        var map: [Int: [Symbol]] = [:]
        for (_, fileScope) in table.fileScopes {
            collectMemberTypes(fileScope, into: &map)
        }
        return map
    }

    private func collectMemberTypes(_ scope: Scope, into map: inout [Int: [Symbol]]) {
        if let ownerId = scope.owner?.id {
            for s in scope.symbols where s.kind.isTypeLike {
                map[ownerId, default: []].append(s)
            }
        }
        for c in scope.children { collectMemberTypes(c, into: &map) }
    }

    /// Split a dotted type name into segments, mirroring `typeSymbol(forQualifiedName:)`: drop a
    /// trailing `?`/`!`, split on `.`, strip a generic argument clause per segment (`Box<Foo>` → `Box`).
    private static func segments(of rawName: String) -> [String] {
        var name = rawName
        while name.hasSuffix("?") || name.hasSuffix("!") { name = String(name.dropLast()) }
        return name.split(separator: ".").map { seg -> String in
            var s = String(seg)
            if let lt = s.firstIndex(of: "<") { s = String(s[..<lt]) }
            return s
        }
    }
}
