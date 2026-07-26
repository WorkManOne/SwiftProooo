import SwiftSyntax

/// Collects the inherited-type names (superclass + protocol conformances) written on the PRIMARY
/// declaration whose name token begins at a given byte offset.
///
/// One shared implementation replaces the seven byte-identical per-pass collectors that previously
/// had to be kept in lockstep — the maintenance hazard was real: adding `actor` support (F9) meant
/// editing an `ActorDeclSyntax` visit into every copy, and a divergence between two of them is a
/// wrong-conformance-view → wrong rename RollbackPass can't catch. The class-only callers
/// (SuperclassVisibility / OverrideLinker) only ever query a CLASS's offset, so visiting every
/// type-decl kind here is behavior-identical for them (offsets are unique); WitnessLinker never
/// queries a protocol's offset (its loop skips protocols), so protocol coverage is a no-op there too.
///
/// Conformances declared on an `extension S: P` are a SEPARATE mechanism
/// (`SymbolTable.extensionConformanceNames`) and intentionally NOT collected here — this reads only
/// the type's own primary-decl inheritance clause.
public enum InheritanceClause {
    /// Inherited-type names of the type decl whose name token starts at `offset` in `file`, in
    /// source order. Empty if that decl has no inheritance clause, or if no decl starts exactly there.
    public static func names(atOffset offset: Int, in file: SourceFileSyntax) -> [String] {
        let collector = Collector(targetOffset: offset)
        collector.walk(file)
        return collector.collected
    }

    private final class Collector: SyntaxVisitor {
        let targetOffset: Int
        var collected: [String] = []
        init(targetOffset: Int) {
            self.targetOffset = targetOffset
            super.init(viewMode: .sourceAccurate)
        }
        /// Match by the decl's name-token offset (how symbols record `declOffset`). On a hit capture
        /// the inheritance clause and stop descending; otherwise keep walking to reach nested types.
        private func capture(_ name: TokenSyntax, _ inh: InheritanceClauseSyntax?) -> SyntaxVisitorContinueKind {
            guard name.positionAfterSkippingLeadingTrivia.utf8Offset == targetOffset else {
                return .visitChildren
            }
            if let inh {
                for entry in inh.inheritedTypes { collected.append(entry.type.trimmedDescription) }
            }
            return .skipChildren
        }
        override func visit(_ n: ClassDeclSyntax) -> SyntaxVisitorContinueKind { capture(n.name, n.inheritanceClause) }
        override func visit(_ n: ActorDeclSyntax) -> SyntaxVisitorContinueKind { capture(n.name, n.inheritanceClause) }
        override func visit(_ n: StructDeclSyntax) -> SyntaxVisitorContinueKind { capture(n.name, n.inheritanceClause) }
        override func visit(_ n: EnumDeclSyntax) -> SyntaxVisitorContinueKind { capture(n.name, n.inheritanceClause) }
        override func visit(_ n: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind { capture(n.name, n.inheritanceClause) }
    }
}
