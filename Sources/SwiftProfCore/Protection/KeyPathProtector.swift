import Foundation
import SwiftSyntax

/// Proactive protector for property/method names whose resolution requires type information
/// we don't currently model. Until we add full key-path / closure-parameter / shorthand-binding
/// resolution, we scan for ambiguity-prone patterns and protect the referenced names.
///
/// Patterns scanned:
///
/// 1. **Key paths** — `\.X`, `\Type.X.Y` — Root type usually inferred by the compiler from
///    context (e.g. `filter(\.flag)`), which we don't model.
///
/// 2. **Closure shorthand member access** — `{ $0.X }`. Shorthand parameter types come from
///    the enclosing call signature.
///
/// 3. **Member access inside ANY closure** — `{ tab in tab.X }`. The closure parameter's
///    type is set by the receiver's element type, which we don't infer.
///
/// 4. **Shorthand if-let / guard-let** — `if let X { ... }`. The implicit rhs reads from the
///    scope's `X`; renaming the declaration without rewriting the binding orphans it.
public final class KeyPathProtector {
    public let table: SymbolTable
    public let protector: Protector
    public let logger: Logger

    public init(table: SymbolTable, protector: Protector, logger: Logger) {
        self.table = table
        self.protector = protector
        self.logger = logger
    }

    public func run(on files: [SourceFile]) {
        let visitor = AmbiguousAccessCollector()
        for file in files {
            visitor.walk(file.syntax)
        }
        var protectedCount = 0
        for sym in table.symbols where sym.kind == .property || sym.kind == .method {
            if !visitor.referencedNames.contains(sym.name) { continue }
            if protector.isProtected(sym) { continue }
            protector.protect(sym.id, reason: "ambiguous use site (key path / closure param / shorthand bind)")
            protectedCount += 1
        }
        logger.log("KeyPathProtector: \(visitor.referencedNames.count) names → \(protectedCount) symbols protected")
    }
}

private final class AmbiguousAccessCollector: SyntaxVisitor {
    var referencedNames: Set<String> = []

    init() { super.init(viewMode: .sourceAccurate) }

    // MARK: - Key paths

    /// `\.X` and `\Type.X.Y` — protect only those we can't resolve syntactically. A keypath is
    /// "resolvable" when it has an explicit root (`\Foo.bar`) OR it appears as an argument to
    /// a known HOF whose receiver type we can determine (e.g. `arr.filter(\.flag)` —
    /// receiver is `arr`, element type known via the HOF signature).
    override func visit(_ node: KeyPathExprSyntax) -> SyntaxVisitorContinueKind {
        if isResolvableKeyPath(node) {
            return .visitChildren
        }
        for component in node.components {
            if let prop = component.component.as(KeyPathPropertyComponentSyntax.self) {
                referencedNames.insert(prop.declName.baseName.text)
            }
        }
        return .visitChildren
    }

    private func isResolvableKeyPath(_ node: KeyPathExprSyntax) -> Bool {
        if node.root != nil { return true }
        var ref: Syntax = Syntax(node)
        var argumentIndex: Int? = nil
        while let parent = ref.parent {
            if argumentIndex == nil, let labeled = parent.as(LabeledExprSyntax.self),
               let list = labeled.parent?.as(LabeledExprListSyntax.self) {
                argumentIndex = list.enumerated().first(where: { $0.element.id == labeled.id })?.offset
            }
            if let call = parent.as(FunctionCallExprSyntax.self), let idx = argumentIndex {
                if let memberCall = call.calledExpression.as(MemberAccessExprSyntax.self) {
                    let method = memberCall.declName.baseName.text
                    if let sig = HOFRegistry.signature(forMethod: method), sig.closureArgIndex == idx {
                        return true
                    }
                }
                if let typeRef = call.calledExpression.as(DeclReferenceExprSyntax.self) {
                    let typeName = typeRef.baseName.text
                    if HOFRegistry.initSignature(forType: typeName, closureAt: idx) != nil {
                        return true
                    }
                }
                return false
            }
            if parent.is(SourceFileSyntax.self) { return false }
            ref = Syntax(parent)
        }
        return false
    }

    // Note: shorthand `if let X` is now handled by ResolutionVisitor — it inserts ` = obfName`
    // after the pattern token so the binding expands to `if let X = obfName`. No protection needed.

    // Note: closure parameter member access (`$0.X` / `{ item in item.X }`) used to be protected
    // here. That logic is now redundant — TypeResolver infers types of closure parameters from
    // their enclosing HOF call (filter/map/reduce/etc), and ResolutionVisitor resolves member
    // names correctly. Anything still ambiguous falls through and stays unrenamed (no rewrite),
    // which is preferable to over-protection.
}
