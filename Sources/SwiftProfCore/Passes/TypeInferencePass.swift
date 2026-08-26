import Foundation
import SwiftSyntax

/// Resolves the declared type of var/let bindings and for-loop variables whose type wasn't
/// known at DeclarationPass time. Runs after the symbol table is fully built (including
/// ScopeUnification and ConformanceVisibility) so that lookups can succeed across files.
///
/// Two cases:
///   1. `let x = <expr>` — type of `x` is the type of `<expr>`. Resolved via TypeResolver.
///   2. `for x in <seq>` — type of `x` is the element type of `<seq>`. We unwrap `Array<T>`,
///      `[T]` (ArrayType), `Set<T>` etc. to extract Element.
public final class TypeInferencePass {
    public let table: SymbolTable
    public let logger: Logger
    private let resolver: TypeResolver

    public init(table: SymbolTable, logger: Logger) {
        self.table = table
        self.logger = logger
        self.resolver = TypeResolver(table: table)
    }

    public func run() {
        var inferred = 0
        // 1. Initializer-driven inference.
        for sym in table.symbols where table.declaredType[sym.id] == nil {
            guard let expr = table.initializerExpr[sym.id], let scope = sym.scope else { continue }
            if let typeSym = resolver.typeSymbol(of: expr, in: scope) {
                // Store the QUALIFIED name (`NS.Widget`), not the simple one: `declaredType` is a
                // string re-resolved later from a possibly-different scope, and a bare nested-type
                // name (`Widget`) is invisible outside its own nesting. Top-level types qualify to
                // just their name (no change). Fixes inference from `var x = NS.Widget(...)`.
                let name = Self.qualifiedName(of: typeSym)
                table.declaredType[sym.id] = name
                inferred += 1
                logger.log("[infer-init] \(sym.name)#\(sym.id) → \(name)", verbose: true)
            } else if let composite = storableCompositeType(of: expr, in: scope) {
                // `typeSymbol` names only LOCAL declarations, so a local whose initializer types to a
                // COLLECTION / TUPLE string (`let xs = rows.filter { … }` → `[Row]`,
                // `let pairs = zip(a, b)` → `[(A, B)]`) was left untyped, and every chain through it
                // (`xs.first?.m`, a for-in over `pairs`) stayed un-renamed while the member declaration
                // renamed — the desync class (B-FIX-75). The for-loop path (step 2) already stores such
                // strings via `receiverTypeInfo`; this gives the initializer path the same reach, gated
                // to the "chaseable composite" shapes so an external scalar (`URL`) is not persisted.
                table.declaredType[sym.id] = composite
                inferred += 1
                logger.log("[infer-init-composite] \(sym.name)#\(sym.id) → \(composite)", verbose: true)
            } else {
                logger.log("[infer-init-fail] \(sym.name)#\(sym.id) — could not resolve init expr", verbose: true)
            }
        }
        // 2. For-loop variable inference: element type of the sequence.
        for sym in table.symbols where table.declaredType[sym.id] == nil {
            guard let seq = table.forLoopSequence[sym.id], let scope = sym.scope else { continue }
            if let path = table.forLoopTuplePosition[sym.id] {
                if let componentName = inferTupleComponentType(of: seq, path: path, in: scope) {
                    table.declaredType[sym.id] = componentName
                    inferred += 1
                    logger.log("[infer-loop-tuple] \(sym.name)#\(sym.id)\(path.map { $0.index }) → \(componentName)",
                               verbose: true)
                }
                continue
            }
            if let elementName = inferElementType(of: seq, in: scope) {
                table.declaredType[sym.id] = elementName
                inferred += 1
                logger.log("[infer-loop] \(sym.name)#\(sym.id) → \(elementName)", verbose: true)
            } else {
                let leaf = leafDeclaredType(of: seq, in: scope)?.name ?? "<nil>"
                logger.log("[infer-loop-fail] \(sym.name)#\(sym.id) — leaf=\(leaf)", verbose: true)
            }
        }
        // 3. Accessor value binding (`newValue`/`oldValue`) whose owning property has an INFERRED
        //    type: transfer the owner's now-resolved declaredType to the binding (B3). Runs after
        //    step 1 has typed the owner from its initializer. A binding with a written accessor type
        //    never appears in `accessorBindingOwner`, so this only fills the inferred case.
        for (bindingId, ownerId) in table.accessorBindingOwner where table.declaredType[bindingId] == nil {
            if let ownerType = table.declaredType[ownerId] {
                table.declaredType[bindingId] = ownerType
                inferred += 1
                logger.log("[infer-accessor] binding#\(bindingId) → \(ownerType) (from owner#\(ownerId))",
                           verbose: true)
            }
        }
        if inferred > 0 {
            logger.log("TypeInferencePass: \(inferred) symbols typed")
        }
    }

    /// Fully-qualified name of a type Symbol (`NS.Widget`, `E1.S2`), built from its enclosing-TYPE
    /// chain so the stored string resolves from any scope. A type declared at top level (or nested
    /// only inside functions, which can't be qualified) yields just its own name — no change from
    /// the previous simple-name behavior.
    static func qualifiedName(of typeSym: Symbol) -> String {
        var parts = [typeSym.name]
        var owner = typeSym.scope?.owner
        while let o = owner, o.kind.isTypeLike {
            parts.insert(o.name, at: 0)
            owner = o.scope?.owner
        }
        return parts.joined(separator: ".")
    }

    /// Returns the element type name of a sequence expression. Handles:
    /// - Property/var with type `[T]` or `Array<T>` (introspect declaredType, extract bracket inner)
    /// - Property/var with type `Set<T>` (same)
    /// - Member access chains where the leaf has a known sequence type
    /// - Direct expression of form `[X]` (array literals — skipped for MVP)
    /// The type of a loop variable bound at `position` of a TUPLE pattern: the sequence element's
    /// COMPONENT at that index (B-FIX-38). `for (offset, row) in rows.enumerated()` types `row` as
    /// the element, `offset` as `Int`.
    ///
    /// Fail-closed on everything it cannot read as a tuple of exactly the pattern's arity — a
    /// destructuring we mis-count would type the binding as the WRONG component, which is a wrong
    /// rename RollbackPass cannot catch. Refusing costs a rename instead.
    private func inferTupleComponentType(of expr: ExprSyntax, path: [(index: Int, arity: Int)],
                                         in scope: Scope) -> String? {
        guard let leaf = leafDeclaredType(of: expr, in: scope),
              // The ITERATION element — dictionary-aware, unlike `extractElement`: `for (k, v) in
              // dict` destructures `(key: K, value: V)` while `dict[k]` still yields `V`.
              var current = CollectionMemberRegistry.iterationElement(of: leaf.name) else { return nil }
        // Walk the tuple type along the pattern's path, descending one nesting level per step
        // (`for (offset, (idx, cell)) in …` — B5). Fail-closed at every step: a component count that
        // does not match the pattern's arity there, or an index out of range, would type the binding
        // as the WRONG component (a wrong rename RollbackPass cannot catch), so refuse instead.
        for step in path {
            guard let components = TupleTypeName.components(of: current),
                  components.count == step.arity, step.index < components.count else { return nil }
            current = components[step.index]
        }
        // Qualified in the scope the element name was WRITTEN in, exactly as the element path below —
        // a bare nested name is invisible from the loop body (B-FIX-23).
        if let sym = resolver.typeSymbol(forQualifiedName: current, in: leaf.scope) {
            return Self.qualifiedName(of: sym)
        }
        return current
    }

    private func inferElementType(of expr: ExprSyntax, in scope: Scope) -> String? {
        // Resolve the expression's type symbol via TypeResolver — but the sequence's type is
        // usually a generic `Array<Element>` which we DON'T capture in declaredType (we only
        // store IdentifierTypeSyntax base names). Instead, peek at the declared type STRING
        // for the leaf reference and parse it for `[T]` / `Array<T>` / `Set<T>` syntax.
        guard let leaf = leafDeclaredType(of: expr, in: scope),
              // The ITERATION element, dictionary-aware: `for pair in dict` binds the whole
              // `(key: K, value: V)` tuple (a member access `pair.value` then picks the component,
              // B2), while `dict[k]` still yields `V` (that path stays on `extractElement`). For an
              // array/set/`enumerated()` result this is identical to `extractElement`.
              let element = CollectionMemberRegistry.iterationElement(of: leaf.name) else { return nil }
        // The element name is written in the scope of the SEQUENCE's declaration, so a nested type
        // spelled unqualified (`[Section]` on `Container`) is invisible from the loop body. Resolve
        // it there and store the QUALIFIED name, exactly as the initializer-driven inference does —
        // otherwise every member reached through the loop variable stays un-renamed while the member
        // decl renames, which is a red build whenever the name is shielded from rollback.
        if let sym = resolver.typeSymbol(forQualifiedName: element, in: leaf.scope) {
            return Self.qualifiedName(of: sym)
        }
        return element   // external/stdlib element (String, URL) — nothing to qualify
    }

    /// The raw declaredType string of the leaf-most identifier/property in a sequence expr, PLUS the
    /// scope that string was written in (the declaring scope of the symbol carrying it).
    ///
    /// Delegates to `TypeResolver.receiverTypeInfo`, the single place that answers "what is the
    /// WRITTEN type name of this expression" (brackets intact). Sharing it means a sequence spelled
    /// through a stdlib collection member (`for x in items.filter { … }`, `for v in dict.values`) or
    /// through a call (`for x in makeItems()`) types its loop variable too, instead of each consumer
    /// re-implementing a narrower walk (B-FIX-30).
    private func leafDeclaredType(of expr: ExprSyntax, in scope: Scope) -> (name: String, scope: Scope)? {
        guard let info = resolver.receiverTypeInfo(of: expr, in: scope) else { return nil }
        return (info.name, info.declScope)
    }

    /// The WRITTEN type-name string of an initializer expression, but ONLY when that string is a
    /// "chaseable composite" (`TypeResolver.isChaseableComposite` — a collection `[Row]` / `Set<Row>`
    /// / `[K: V]`, a tuple `(offset: Int, element: Row)`, or an iterator marker `$Iterator<E>`). Such
    /// a string names no declaration, so `typeSymbol(of:)` returns nil for it and step 1's Symbol-only
    /// inference could not persist it (B-FIX-75/76). Storing it lets a chain through the local —
    /// `xs.first?.m`, a for-in over `pairs`, `it.next()` — resolve, exactly as the for-loop path
    /// (step 2) already does for the loop variable's SEQUENCE.
    ///
    /// Gated to those shapes on purpose: an external SCALAR (`URL`) that `receiverTypeInfo` can also
    /// name gives no chain to type and is left unstored, keeping the change's surface minimal. The
    /// string is stored VERBATIM and later resolved in the symbol's OWN declaring scope; a leaf whose
    /// type is a nested name written in a scope where the local cannot see it stays a residual
    /// (fail-closed, under-obfuscation) — the same limit every synthesized tuple string already carries.
    private func storableCompositeType(of expr: ExprSyntax, in scope: Scope) -> String? {
        guard let info = resolver.receiverTypeInfo(of: expr, in: scope),
              TypeResolver.isChaseableComposite(info.name) else { return nil }
        return info.name
    }
}
