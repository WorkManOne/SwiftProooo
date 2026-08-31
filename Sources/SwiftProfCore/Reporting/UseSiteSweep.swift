import Foundation
import SwiftSyntax

/// Lists every identifier USE-SITE position in a file: `DeclReferenceExprSyntax.baseName` and
/// `MemberAccessExprSyntax.declName.baseName`, which together are the only nodes through which an
/// identifier reference is written in an expression.
///
/// Why a separate sweep rather than a hook on `ResolutionVisitor`'s two `visit` methods:
/// `ResolutionVisitor` returns `.skipChildren` from many branches, so a use-site nested inside a
/// subtree the resolver skipped is never visited at all and an entry hook could not see it. Those
/// are precisely the positions where a reporter gap hides. This visitor shares none of the
/// resolver's traversal decisions, so its list is the ground truth the resolver's records are
/// diffed against.
final class UseSiteSweep: SyntaxVisitor {
    private(set) var sites: [(name: String, offset: Int, position: UseSitePosition)] = []

    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        add(node.baseName)
        return .visitChildren
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        add(node.declName.baseName)
        return .visitChildren
    }

    /// A name in TYPE position — an annotation, a return clause, an `extension` head, a generic
    /// argument, an inheritance clause. `ResolutionVisitor` rewrites these through `emitRename` as
    /// well, so leaving them out of the sweep meant a type reference the resolver silently failed to
    /// resolve produced no record AND no `no-decision` line: exactly the silence this pass exists to
    /// abolish, over a large population.
    override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
        add(node.name)
        return .visitChildren
    }

    override func visit(_ node: MemberTypeSyntax) -> SyntaxVisitorContinueKind {
        add(node.name)
        return .visitChildren
    }

    private func add(_ token: TokenSyntax) {
        guard case .identifier = token.tokenKind else { return }
        sites.append((TypeResolver.stripBackticks(token.text),
                      token.positionAfterSkippingLeadingTrivia.utf8Offset,
                      UseSitePosition.classify(token)))
    }
}
