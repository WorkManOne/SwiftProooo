import SwiftSyntax

/// Where a binding introduced by a CONDITION is visible.
///
/// `if case .calm(let item) = mood { … }` and its `while` twin bind `item` for the rest of the
/// condition list and the statement's BODY — and nowhere else. Not in the `else`, not below the
/// statement (verified against swiftc: both positions read the same-named outer symbol, and
/// reaching for a payload-only member there is "value of type 'Detail' has no member …").
///
/// `guard case` is the deliberate opposite: its binding is in scope AFTER the statement, so it has
/// no end at all. It is still not in scope inside the guard's OWN `else` body, which sits in the
/// middle of that region — hence a HOLE rather than an end (also verified against swiftc: in the
/// else, the name still means the same-named symbol declared above).
///
/// The two consumers are the two halves of "what does this name mean here", and they must agree or
/// the wrong one wins: the scope SYMBOL registered by `DeclarationPass` (which decides which
/// declaration a bare reference names) and the payload TYPE recorded by `ResolutionPass` into
/// `shadowBindingTypeFrames` (which decides what its members are). Hence one shared answer. The
/// type half needs no `hole`: `ResolutionPass.visitPost(GuardStmtSyntax)` records a guard's payload
/// types only after the else body has been visited, which excludes it by construction.
public enum ConditionBindingExtent {
    /// The region a condition's bindings are visible in, relative to their own declaration.
    ///
    /// Presence of this value is itself meaningful: it marks a binding that `DeclarationPass`
    /// flattened into the ENCLOSING scope instead of a scope of its own, which is what
    /// `Scope.declarations(named:visibleAt:)` needs in order to let it SHADOW that scope's own
    /// same-named declarations (B-FIX-43).
    public struct Visibility: Equatable {
        /// EXCLUSIVE end of the region, or nil when the binding outlives its statement (`guard`).
        public let end: Int?
        /// A gap inside the region where the binding is NOT yet in scope: a `guard`'s own `else`
        /// body. nil for `if`/`while`, whose else body already falls outside `end`.
        public let hole: Range<Int>?

        public init(end: Int?, hole: Range<Int>?) {
            self.end = end
            self.hole = hole
        }
    }

    /// The visibility region of the bindings of `node` (a condition), or nil when the shape is not
    /// a recognised condition — in which case the binding keeps the plain "visible to the end of
    /// its scope" behaviour of any other declaration.
    ///
    /// The walk is short by construction: a `MatchingPatternConditionSyntax`'s parent chain is
    /// `ConditionElement` → `ConditionElementList` → the statement. The `CodeBlock` stop is a
    /// belt-and-braces bail for any shape that does not match that, where "no region" is the safe
    /// answer (it is exactly the pre-B-FIX-42 behaviour).
    public static func visibility(of node: some SyntaxProtocol) -> Visibility? {
        var probe: Syntax? = Syntax(node).parent
        while let cur = probe {
            if let ifExpr = cur.as(IfExprSyntax.self) {
                return Visibility(end: ifExpr.body.endPositionBeforeTrailingTrivia.utf8Offset,
                                  hole: nil)
            }
            if let whileStmt = cur.as(WhileStmtSyntax.self) {
                return Visibility(end: whileStmt.body.endPositionBeforeTrailingTrivia.utf8Offset,
                                  hole: nil)
            }
            if let guardStmt = cur.as(GuardStmtSyntax.self) {
                // `body` IS the else body of a `guard`.
                let elseBody = guardStmt.body
                let start = elseBody.positionAfterSkippingLeadingTrivia.utf8Offset
                let end = elseBody.endPositionBeforeTrailingTrivia.utf8Offset
                return Visibility(end: nil, hole: start < end ? start..<end : nil)
            }
            if cur.is(CodeBlockSyntax.self) { return nil }
            probe = cur.parent
        }
        return nil
    }

    /// The EXCLUSIVE end offset alone, for callers that track only the end (the payload-TYPE half —
    /// see the note above on why it needs no `hole`).
    public static func endOffset(of node: some SyntaxProtocol) -> Int? {
        visibility(of: node)?.end
    }
}
