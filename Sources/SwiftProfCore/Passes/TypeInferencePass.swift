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
            } else {
                logger.log("[infer-init-fail] \(sym.name)#\(sym.id) — could not resolve init expr", verbose: true)
            }
        }
        // 2. For-loop variable inference: element type of the sequence.
        for sym in table.symbols where table.declaredType[sym.id] == nil {
            guard let seq = table.forLoopSequence[sym.id], let scope = sym.scope else { continue }
            if let position = table.forLoopTuplePosition[sym.id] {
                if let componentName = inferTupleComponentType(of: seq, position: position, in: scope) {
                    table.declaredType[sym.id] = componentName
                    inferred += 1
                    logger.log("[infer-loop-tuple] \(sym.name)#\(sym.id)[\(position.index)] → \(componentName)",
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
    private func inferTupleComponentType(of expr: ExprSyntax, position: (index: Int, arity: Int),
                                         in scope: Scope) -> String? {
        guard let leaf = leafDeclaredType(of: expr, in: scope),
              // The ITERATION element — dictionary-aware, unlike `extractElement`: `for (k, v) in
              // dict` destructures `(key: K, value: V)` while `dict[k]` still yields `V`.
              let element = CollectionMemberRegistry.iterationElement(of: leaf.name),
              let components = TupleTypeName.components(of: element),
              components.count == position.arity, position.index < components.count else { return nil }
        let component = components[position.index]
        // Qualified in the scope the element name was WRITTEN in, exactly as the element path below —
        // a bare nested name is invisible from the loop body (B-FIX-23).
        if let sym = resolver.typeSymbol(forQualifiedName: component, in: leaf.scope) {
            return Self.qualifiedName(of: sym)
        }
        return component
    }

    private func inferElementType(of expr: ExprSyntax, in scope: Scope) -> String? {
        // Resolve the expression's type symbol via TypeResolver — but the sequence's type is
        // usually a generic `Array<Element>` which we DON'T capture in declaredType (we only
        // store IdentifierTypeSyntax base names). Instead, peek at the declared type STRING
        // for the leaf reference and parse it for `[T]` / `Array<T>` / `Set<T>` syntax.
        guard let leaf = leafDeclaredType(of: expr, in: scope),
              let element = extractElement(from: leaf.name) else { return nil }
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

    private func extractElement(from typeName: String) -> String? {
        TypeResolver.extractElement(from: typeName)
    }
}
