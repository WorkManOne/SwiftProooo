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
                table.declaredType[sym.id] = typeSym.name
                inferred += 1
                logger.log("[infer-init] \(sym.name)#\(sym.id) → \(typeSym.name)", verbose: true)
            } else {
                logger.log("[infer-init-fail] \(sym.name)#\(sym.id) — could not resolve init expr", verbose: true)
            }
        }
        // 2. For-loop variable inference: element type of the sequence.
        for sym in table.symbols where table.declaredType[sym.id] == nil {
            guard let seq = table.forLoopSequence[sym.id], let scope = sym.scope else { continue }
            if let elementName = inferElementType(of: seq, in: scope) {
                table.declaredType[sym.id] = elementName
                inferred += 1
                logger.log("[infer-loop] \(sym.name)#\(sym.id) → \(elementName)", verbose: true)
            } else {
                let leaf = leafDeclaredTypeName(of: seq, in: scope) ?? "<nil>"
                logger.log("[infer-loop-fail] \(sym.name)#\(sym.id) — leaf=\(leaf)", verbose: true)
            }
        }
        if inferred > 0 {
            logger.log("TypeInferencePass: \(inferred) symbols typed")
        }
    }

    /// Returns the element type name of a sequence expression. Handles:
    /// - Property/var with type `[T]` or `Array<T>` (introspect declaredType, extract bracket inner)
    /// - Property/var with type `Set<T>` (same)
    /// - Member access chains where the leaf has a known sequence type
    /// - Direct expression of form `[X]` (array literals — skipped for MVP)
    private func inferElementType(of expr: ExprSyntax, in scope: Scope) -> String? {
        // Resolve the expression's type symbol via TypeResolver — but the sequence's type is
        // usually a generic `Array<Element>` which we DON'T capture in declaredType (we only
        // store IdentifierTypeSyntax base names). Instead, peek at the declared type STRING
        // for the leaf reference and parse it for `[T]` / `Array<T>` / `Set<T>` syntax.
        guard let typeName = leafDeclaredTypeName(of: expr, in: scope) else { return nil }
        return extractElement(from: typeName)
    }

    /// Get the raw declaredType string of the leaf-most identifier/property in a sequence expr.
    private func leafDeclaredTypeName(of expr: ExprSyntax, in scope: Scope) -> String? {
        if let opt = expr.as(OptionalChainingExprSyntax.self) {
            return leafDeclaredTypeName(of: opt.expression, in: scope)
        }
        if let force = expr.as(ForceUnwrapExprSyntax.self) {
            return leafDeclaredTypeName(of: force.expression, in: scope)
        }
        if let ref = expr.as(DeclReferenceExprSyntax.self) {
            let name = TypeResolver.stripBackticks(ref.baseName.text)
            if let sym = scope.lookup(name: name) {
                return table.declaredType[sym.id]
            }
            return nil
        }
        if let member = expr.as(MemberAccessExprSyntax.self), let base = member.base {
            guard let baseSym = resolver.typeSymbol(of: base, in: scope),
                  let baseScope = resolver.canonicalInnerScope(of: baseSym) else { return nil }
            let memberName = TypeResolver.stripBackticks(member.declName.baseName.text)
            guard let memberSym = baseScope.member(named: memberName) else { return nil }
            return table.declaredType[memberSym.id]
        }
        return nil
    }

    private func extractElement(from typeName: String) -> String? {
        TypeResolver.extractElement(from: typeName)
    }
}
