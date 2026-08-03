import SwiftSyntax

/// Where a binding introduced by a CONDITION stops being visible.
///
/// `if case .calm(let item) = mood { … }` and its `while` twin bind `item` for the rest of the
/// condition list and the statement's BODY — and nowhere else. Not in the `else`, not below the
/// statement (verified against swiftc: both positions read the same-named outer symbol, and
/// reaching for a payload-only member there is "value of type 'Detail' has no member …").
///
/// `guard case` is the deliberate opposite: its binding is in scope AFTER the statement, so it has
/// no end at all — the answer is nil, and both callers keep their previous behaviour for it.
///
/// The two consumers are the two halves of "what does this name mean here", and they must agree or
/// the wrong one wins: the scope SYMBOL registered by `DeclarationPass` (which decides which
/// declaration a bare reference names) and the payload TYPE recorded by `ResolutionPass` into
/// `shadowBindingTypeFrames` (which decides what its members are). Hence one shared answer.
public enum ConditionBindingExtent {
    /// The EXCLUSIVE end offset of the region the condition's bindings are visible in, or nil when
    /// they outlive their statement (`guard case`) — in which case no end bound is applied.
    ///
    /// The walk is short by construction: a `MatchingPatternConditionSyntax`'s parent chain is
    /// `ConditionElement` → `ConditionElementList` → the statement. The `CodeBlock` stop is a
    /// belt-and-braces bail for any shape that does not match that, where "no bound" is the safe
    /// answer (it is exactly today's behaviour).
    public static func endOffset(of node: some SyntaxProtocol) -> Int? {
        var probe: Syntax? = Syntax(node).parent
        while let cur = probe {
            if let ifExpr = cur.as(IfExprSyntax.self) {
                return ifExpr.body.endPositionBeforeTrailingTrivia.utf8Offset
            }
            if let whileStmt = cur.as(WhileStmtSyntax.self) {
                return whileStmt.body.endPositionBeforeTrailingTrivia.utf8Offset
            }
            if cur.is(GuardStmtSyntax.self) { return nil }
            if cur.is(CodeBlockSyntax.self) { return nil }
            probe = cur.parent
        }
        return nil
    }
}
