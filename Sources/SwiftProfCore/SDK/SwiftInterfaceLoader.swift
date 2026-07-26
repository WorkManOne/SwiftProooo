import Foundation
import SwiftSyntax
import SwiftParser

/// Per-module extracted protocol information: protocol name → set of required member names.
/// Only the names matter for protection — we don't need to model parameter types of requirements.
public struct LoadedInterface {
    public let module: String
    public let protocols: [String: Set<String>]   // protocol name → member names
    /// All declared public member names (vars, funcs, enum cases) across all types in this
    /// module. Used by RollbackPass as the "shielding set" — names which Apple's frameworks
    /// publish at call sites, so seeing them in user code doesn't necessarily indicate a
    /// desynced rename.
    public let allMemberNames: Set<String>
}

/// Parses a `.swiftinterface` file via SwiftParser and walks the AST to extract protocol
/// declarations and the names of their requirements (vars, funcs, inits, associatedtypes,
/// subscripts).
///
/// `.swiftinterface` files are guaranteed-stable textual Swift. Our parser swallows any
/// per-declaration parse failure silently — partial coverage is better than crashing on a new
/// Swift attribute we don't yet handle.
public final class SwiftInterfaceLoader {
    public let logger: Logger
    public init(logger: Logger) { self.logger = logger }

    public func load(_ url: URL, moduleName: String) -> LoadedInterface? {
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            logger.log("interface: failed to read \(url.path)", verbose: true)
            return nil
        }
        let tree = Parser.parse(source: source)
        let collector = ProtocolCollector()
        collector.walk(tree)
        return LoadedInterface(
            module: moduleName,
            protocols: collector.protocols,
            allMemberNames: collector.allMemberNames
        )
    }
}

private final class ProtocolCollector: SyntaxVisitor {
    var protocols: [String: Set<String>] = [:]
    var allMemberNames: Set<String> = []

    init() { super.init(viewMode: .sourceAccurate) }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        let name = node.name.text
        var members: Set<String> = []
        for memberItem in node.memberBlock.members {
            collectMemberNames(memberItem.decl, into: &members)
        }
        // Some interface files declare the same protocol with availability shadows. Merge.
        if let existing = protocols[name] {
            protocols[name] = existing.union(members)
        } else {
            protocols[name] = members
        }
        allMemberNames.formUnion(members)
        return .visitChildren
    }

    // Also collect names from class / struct / enum bodies and from top-level extensions —
    // these are the public Apple API call-site names (UIView.cornerRadius, NotificationCenter.default,
    // Color.primary, etc.) that legitimately survive in user code.
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        collectAllMembers(in: node.memberBlock)
        return .visitChildren
    }
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        collectAllMembers(in: node.memberBlock)
        return .visitChildren
    }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        collectAllMembers(in: node.memberBlock)
        return .visitChildren
    }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        collectAllMembers(in: node.memberBlock)
        return .visitChildren
    }

    private func collectAllMembers(in block: MemberBlockSyntax) {
        var bucket: Set<String> = []
        for memberItem in block.members {
            collectMemberNames(memberItem.decl, into: &bucket)
        }
        allMemberNames.formUnion(bucket)
    }

    /// `extension Foo { ... }` — collect member names for shielding. If the extension is on a
    /// known protocol, also fold into that protocol's requirement set (covers default impls).
    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        var members: Set<String> = []
        for memberItem in node.memberBlock.members {
            collectMemberNames(memberItem.decl, into: &members)
        }
        if !members.isEmpty {
            allMemberNames.formUnion(members)
        }
        // If extending a known protocol, also add to its requirement set (default impls).
        let extendedTypeName = node.extendedType.trimmedDescription
        if !extendedTypeName.contains("<"), !extendedTypeName.contains("."),
           protocols[extendedTypeName] != nil,
           !members.isEmpty {
            protocols[extendedTypeName] = protocols[extendedTypeName, default: []].union(members)
        }
        return .visitChildren
    }

    private func collectMemberNames(_ decl: DeclSyntax, into out: inout Set<String>) {
        if let v = decl.as(VariableDeclSyntax.self) {
            for binding in v.bindings {
                if let ident = binding.pattern.as(IdentifierPatternSyntax.self) {
                    out.insert(stripBackticks(ident.identifier.text))
                }
            }
        } else if let f = decl.as(FunctionDeclSyntax.self) {
            out.insert(stripBackticks(f.name.text))
        } else if decl.is(InitializerDeclSyntax.self) {
            out.insert("init")
        } else if let a = decl.as(AssociatedTypeDeclSyntax.self) {
            out.insert(stripBackticks(a.name.text))
        } else if let t = decl.as(TypeAliasDeclSyntax.self) {
            out.insert(stripBackticks(t.name.text))
        } else if decl.is(SubscriptDeclSyntax.self) {
            out.insert("subscript")
        } else if let e = decl.as(EnumCaseDeclSyntax.self) {
            for element in e.elements {
                out.insert(stripBackticks(element.name.text))
            }
        } else if let ifConfig = decl.as(IfConfigDeclSyntax.self) {
            // Walk all branches of #if/#else and collect from every branch — be inclusive.
            for clause in ifConfig.clauses {
                if let block = clause.elements?.as(MemberBlockItemListSyntax.self) {
                    for item in block { collectMemberNames(item.decl, into: &out) }
                }
            }
        }
    }

    private func stripBackticks(_ s: String) -> String {
        guard s.count >= 2, s.hasPrefix("`"), s.hasSuffix("`") else { return s }
        return String(s.dropFirst().dropLast())
    }
}
