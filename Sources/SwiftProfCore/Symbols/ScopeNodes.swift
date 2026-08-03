import SwiftSyntax

/// The syntax nodes that introduce a lexical scope.
///
/// `SymbolTable.innerScope` is the single source of truth for the scope TREE (built by
/// `DeclarationPass`); this list is the contract for who must MIRROR it. Every pass that walks
/// source positions with its own scope stack has to enter and exit exactly these node kinds:
///
/// - `ResolutionPass.ResolutionVisitor`
/// - `RawValueObfuscation.RawValueUseVisitor`
///
/// A mirror that misses a kind sees every declaration made under it as invisible, so a use-site
/// there resolves to an outer same-named symbol instead — a wrong rename, which RollbackPass cannot
/// catch (no original name survives). `DeclarationPass.push` asserts against this list, so adding a
/// scope node forces an edit here, and this doc names the mirrors that then need the same node.
public enum ScopeNodes {
    public static let kinds: Set<SyntaxKind> = [
        // Type scopes
        .classDecl, .structDecl, .actorDecl, .enumDecl, .protocolDecl, .extensionDecl,
        // Function scopes (the PARAMETERS live here; the body is a nested block)
        .functionDecl, .initializerDecl, .subscriptDecl,
        // Block scopes. `forStmt` holds the LOOP VARIABLE, which is declared outside the body and
        // must die with the loop — the body's own `codeBlock` is nested inside it.
        .closureExpr, .switchCase, .catchClause, .codeBlock, .forStmt,
    ]
}
