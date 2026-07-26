import Foundation
import SwiftSyntax

/// Makes default protocol members visible in conforming types' scope chains.
///
/// Swift rule: `extension P { func foo() {} }` provides a default impl. Any `struct T: P { ... }`
/// that doesn't declare its own `foo` inherits this default and can call it as `foo()` via
/// implicit self. We model this by **copying references** to the protocol's members into the
/// conformer's scope (after ScopeUnification has folded extension members into the protocol's
/// canonical scope).
///
/// If the conformer already declares a member of the same name, we DON'T add the protocol's
/// version (the conformer's override shadows the default). WitnessLinker handles unifying the
/// obfuscated names of the override and the requirement.
public final class ConformanceVisibility {
    public let table: SymbolTable
    public let logger: Logger

    public init(table: SymbolTable, logger: Logger) {
        self.table = table
        self.logger = logger
    }

    public func run() {
        // Walk type symbols (struct/class/enum AND protocol-to-protocol inheritance). For each,
        // gather conformances from the primary decl AND its extensions, resolve names to local
        // protocol symbols, and fold protocol members into the conformer's canonical scope.
        var inherited = 0
        for sym in table.symbols where isConformerKind(sym.kind) {
            guard let parent = sym.scope,
                  let inner = parent.children.first(where: { $0.owner?.id == sym.id })
            else { continue }
            // Primary decl conformances + conformances declared in extensions (B-FIX-6).
            var conformedTo = inheritanceNames(for: sym)
            conformedTo.append(contentsOf: table.extensionConformanceNames(ownerId: sym.id))
            for name in conformedTo {
                // A protocol must not fold its own requirements into itself.
                if name == sym.name { continue }
                // Prefer the protocol declared in the conformer's own module. When the match fails,
                // accept a sole cross-module candidate, but if several same-named protocols live in
                // OTHER modules and none here, skip rather than pick a registration-order `.first`
                // (B-FIX-5 — fail closed: an arbitrary pick folds the wrong module's members in).
                guard let proto = preferredProtocol(named: name, forModule: sym.module.name),
                      let protoParent = proto.scope,
                      let protoScope = protoParent.children.first(where: { $0.owner?.id == proto.id })
                else { continue }

                let existingNames = Set(inner.symbols.map { $0.name })
                // Copy default-implementation refs for ALL requirement kinds: methods/properties
                // PLUS nested-type/typealias/associatedtype requirements (B-FIX-6 — a requirement
                // satisfied by a nested type or typealias was previously invisible to the conformer).
                for member in protoScope.symbols
                where copyableRequirement(member.kind) && !existingNames.contains(member.name) {
                    inner.add(symbol: member)
                    inherited += 1
                }
            }
        }
        if inherited > 0 {
            logger.log("ConformanceVisibility: \(inherited) inherited member references added")
        }
    }

    /// Types whose conformances we fold defaults into: concrete types AND protocols (the latter for
    /// protocol-to-protocol inheritance — `protocol Q: P` makes P's requirements visible in Q).
    private func isConformerKind(_ k: SymbolKind) -> Bool {
        switch k { case .class, .struct, .enum, .protocol: return true; default: return false }
    }

    /// Requirement kinds whose reference we copy into a conformer's scope.
    private func copyableRequirement(_ k: SymbolKind) -> Bool {
        switch k {
        case .method, .property, .typealias_, .associatedtype_, .class, .struct, .enum: return true
        default: return false
        }
    }

    /// Module-aware, fail-closed protocol lookup shared by the conformance passes: same-module
    /// candidate wins; a single cross-module candidate is accepted; multiple cross-module candidates
    /// with none in `module` are ambiguous → nil (never `.first`).
    static func preferredProtocol(in table: SymbolTable, named name: String, forModule module: String) -> Symbol? {
        let protos = table.types(named: name).filter { $0.kind == .protocol }
        if let same = protos.first(where: { $0.module.name == module }) { return same }
        return protos.count == 1 ? protos[0] : nil
    }

    private func preferredProtocol(named name: String, forModule module: String) -> Symbol? {
        Self.preferredProtocol(in: table, named: name, forModule: module)
    }

    private func inheritanceNames(for sym: Symbol) -> [String] {
        let collector = ConfInheritanceCollector(targetOffset: sym.declOffset)
        collector.walk(sym.file.syntax)
        return collector.collected
    }
}

private final class ConfInheritanceCollector: SyntaxVisitor {
    let targetOffset: Int
    var collected: [String] = []
    init(targetOffset: Int) {
        self.targetOffset = targetOffset
        super.init(viewMode: .sourceAccurate)
    }
    private func capture(_ inh: InheritanceClauseSyntax?) {
        guard let inh else { return }
        for entry in inh.inheritedTypes {
            collected.append(entry.type.trimmedDescription)
        }
    }
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.name.positionAfterSkippingLeadingTrivia.utf8Offset == targetOffset {
            capture(node.inheritanceClause); return .skipChildren
        }
        return .visitChildren
    }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.name.positionAfterSkippingLeadingTrivia.utf8Offset == targetOffset {
            capture(node.inheritanceClause); return .skipChildren
        }
        return .visitChildren
    }
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.name.positionAfterSkippingLeadingTrivia.utf8Offset == targetOffset {
            capture(node.inheritanceClause); return .skipChildren
        }
        return .visitChildren
    }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.name.positionAfterSkippingLeadingTrivia.utf8Offset == targetOffset {
            capture(node.inheritanceClause); return .skipChildren
        }
        return .visitChildren
    }
    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.name.positionAfterSkippingLeadingTrivia.utf8Offset == targetOffset {
            capture(node.inheritanceClause); return .skipChildren
        }
        return .visitChildren
    }
}
