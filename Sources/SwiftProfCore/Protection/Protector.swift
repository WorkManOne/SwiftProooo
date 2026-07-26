import Foundation
import SwiftSyntax

/// Marks symbols that must never be renamed. Each protection records WHY (a short reason),
/// surfaced in the coverage report so users see which decisions reduced renaming.
public final class Protector {
    public let table: SymbolTable
    public let logger: Logger
    public let stdlibRegistry: StdlibRegistry
    /// id → human-readable reason. Presence in this map = protected.
    public private(set) var reasonForId: [Int: String] = [:]

    public init(table: SymbolTable, stdlibRegistry: StdlibRegistry, logger: Logger) {
        self.table = table
        self.stdlibRegistry = stdlibRegistry
        self.logger = logger
    }

    /// Mark a symbol as protected with a reason. First reason wins for any id.
    func protect(_ id: Int, reason: String) {
        if reasonForId[id] != nil { return }
        reasonForId[id] = reason
        logger.log("protect id=\(id) — \(reason)", verbose: true)
    }

    public func run(on files: [SourceFile]) {
        var classFacts: [(id: Int, inherited: [String], isObjCAttr: Bool)] = []
        var selectorNames: Set<String> = []
        var wrapperTypeNames: Set<String> = []
        var wrappedCandidates: [(id: Int, attrNames: [String])] = []
        for file in files {
            let visitor = ProtectionVisitor(file: file, table: table) { [unowned self] id, reason in
                self.protect(id, reason: reason)
            }
            visitor.walk(file.syntax)
            classFacts.append(contentsOf: visitor.classFacts)
            selectorNames.formUnion(visitor.selectorNames)
            wrapperTypeNames.formUnion(visitor.localPropertyWrapperNames)
            wrappedCandidates.append(contentsOf: visitor.wrappedPropertyCandidates)
        }
        // Cross-cutting passes that need the full table.
        runObjCInheritanceProtection(classFacts: classFacts)
        runSelectorNameProtection(selectorNames: selectorNames)
        runPropertyWrapperProtection(wrapperTypeNames: wrapperTypeNames, candidates: wrappedCandidates)
        runOperatorProtection()
        // After per-file structural detectors, run the cross-cutting non-local-conformance pass.
        // It needs the full SymbolTable populated to decide which inherited names are external.
        runNonLocalConformanceProtection()
        // Codable conformers: keep the serialization contract intact (stored-property names + an
        // explicit CodingKeys enum + implicit-raw-value cases of raw-typed Codable enums).
        runCodableProtection()
    }

    private static let codableProtocolNames: Set<String> = ["Codable", "Decodable", "Encodable"]

    /// A type conforming (directly or transitively, e.g. `protocol Model: Codable`) to
    /// Codable/Decodable/Encodable serializes by NAME: the synthesized `CodingKeys` are its STORED
    /// property names, so renaming a stored property silently changes the JSON contract (a green
    /// build but broken networking/persistence) — and, with an explicit `CodingKeys` enum, a renamed
    /// property desynced from its un-renamed case is a hard "does not conform to Codable" red build.
    /// Protect the contract: stored properties, the `CodingKeys` enum + its cases, and (for a
    /// raw-typed Codable enum) cases whose implicit raw value is the case name. Computed properties
    /// are NOT serialized → left renameable (no coverage loss).
    private func runCodableProtection() {
        for sym in table.symbols where isTypeKind(sym.kind) && sym.kind != .protocol {
            guard let parent = sym.scope,
                  let inner = parent.children.first(where: { $0.owner?.id == sym.id }) else { continue }
            let (known, _) = reachableExternalProtocols(from: sym)
            guard known.contains(where: { Self.codableProtocolNames.contains($0) }) else { continue }

            // Struct/class: stored-property names are the keys; computed properties stay renameable.
            // (Raw-typed Codable ENUMS need no handling here — the `EnumDeclSyntax` detector already
            // protects every raw-type enum's name + cases, which covers their serialization values.)
            for member in inner.symbols
            where member.kind == .property && table.storedPropertyIds.contains(member.id) {
                protect(member.id, reason: "Codable stored property (serialization key)")
            }
            // An explicit `CodingKeys` enum + its cases must stay matching the (protected) properties.
            for member in inner.symbols where member.kind == .enum && member.name == "CodingKeys" {
                protect(member.id, reason: "Codable CodingKeys enum")
                if let csScope = inner.children.first(where: { $0.owner?.id == member.id }) {
                    for c in csScope.symbols where c.kind == .enumCase {
                        protect(c.id, reason: "Codable CodingKeys case")
                    }
                }
            }
        }
    }

    /// Operator-named callables (`==`, `+`, `<`, custom operators) must NEVER be renamed:
    /// 1. their use-sites are operator EXPRESSIONS (`a == b`), not `DeclReference`-by-name, so
    ///    ResolutionPass never rewrites a use-site — renaming the decl is an unconditional desync;
    /// 2. they are almost always protocol-operator witnesses (`Equatable.==`, `Comparable.<`, …)
    ///    whose exact spelling the conformance requires.
    /// Fail-closed and project-wide — there is no scenario where renaming an operator decl is safe.
    private func runOperatorProtection() {
        for sym in table.symbols
        where (sym.kind == .method || sym.kind == .function) && Self.isOperatorName(sym.name) {
            protect(sym.id, reason: "operator method (use-sites are operator syntax, not by-name)")
        }
    }

    /// A Swift identifier starts with a Unicode letter or `_`; anything else is an operator
    /// (`==`, `+`, `<>`, `|>`, `...`). Backtick-escaped identifiers (`` `default` ``) are stripped
    /// first so they are correctly treated as identifiers, not operators.
    static func isOperatorName(_ raw: String) -> Bool {
        var name = raw
        if name.hasPrefix("`") && name.hasSuffix("`") && name.count >= 2 {
            name = String(name.dropFirst().dropLast())
        }
        guard let first = name.unicodeScalars.first else { return false }
        if first == "_" { return false }
        return !first.properties.isAlphabetic
    }

    /// @objc taint is TRANSITIVE: a class is name-sensitive if it (or any ancestor) is `@objc` /
    /// `@objcMembers` / `@IBDesignable`, or if any transitive superclass is an Objective-C root
    /// (`NSObject`, `UIView`, `UIViewController`, …). The old shallow rule only caught DIRECT
    /// subclasses of a literal root name, so `class Base: UIViewController {}` then
    /// `class Leaf: Base {}` left `Leaf`'s `@objc` members renamable → dead `#selector` /
    /// `addTarget` / KVC strings at runtime (B-FIX-4). Protect every tainted class + its members
    /// (including extension members).
    private func runObjCInheritanceProtection(classFacts: [(id: Int, inherited: [String], isObjCAttr: Bool)]) {
        guard !classFacts.isEmpty else { return }
        // Index classes by simple name for module-aware-ish superclass resolution.
        var classesByName: [String: [Symbol]] = [:]
        for sym in table.symbols where sym.kind == .class {
            classesByName[sym.name, default: []].append(sym)
        }
        var tainted = Set<Int>()
        // Seed: classes with an @objc-ish attribute, or directly inheriting an ObjC root name.
        for f in classFacts {
            if f.isObjCAttr || f.inherited.contains(where: { Self.objcRootClassNames.contains($0) }) {
                tainted.insert(f.id)
            }
        }
        // Fixpoint: a class becomes tainted when a superclass name resolves to a tainted local
        // class. Conservative on same-named ambiguity (taint if ANY namesake is tainted).
        var changed = true
        while changed {
            changed = false
            for f in classFacts where !tainted.contains(f.id) {
                for name in f.inherited {
                    let supers = classesByName[name] ?? []
                    if supers.contains(where: { tainted.contains($0.id) }) {
                        tainted.insert(f.id); changed = true; break
                    }
                }
            }
        }
        // Precompute owner → scopes (primary inner + extensions) ONCE so applying protection to
        // many tainted classes stays linear, not O(tainted × scopes).
        var scopesByOwner: [Int: [Scope]] = [:]
        for (_, fileScope) in table.fileScopes {
            collectScopes(fileScope) { scope in
                if let ownerId = scope.owner?.id { scopesByOwner[ownerId, default: []].append(scope) }
            }
        }
        for id in tainted {
            protect(id, reason: "@objc / transitive objc-class")
            for scope in scopesByOwner[id] ?? [] {
                for member in scope.symbols { protect(member.id, reason: "@objc class member (transitive)") }
            }
        }
    }

    /// Protect every member whose name is referenced by a `#selector` / `Selector("…")` anywhere
    /// in the project. The runtime binds these by name, so a rename would point at a dead string.
    /// Coarse by design (protects same-named members project-wide) — fail closed (B-FIX-4).
    /// Protect properties annotated with a CUSTOM local `@propertyWrapper` (known SwiftUI/Combine
    /// wrappers are handled inline during the walk). The wrapper type may be declared in a different
    /// file than the use, so this runs after every file has contributed its wrapper-type names.
    private func runPropertyWrapperProtection(wrapperTypeNames: Set<String>,
                                              candidates: [(id: Int, attrNames: [String])]) {
        guard !wrapperTypeNames.isEmpty else { return }
        for c in candidates {
            if let w = c.attrNames.first(where: { wrapperTypeNames.contains($0) }) {
                protect(c.id, reason: "@\(w) property wrapper (creates _x/$x synonyms)")
            }
        }
    }

    private func runSelectorNameProtection(selectorNames: Set<String>) {
        guard !selectorNames.isEmpty else { return }
        for sym in table.symbols
        where (sym.kind == .method || sym.kind == .function || sym.kind == .property)
           && selectorNames.contains(sym.name) {
            protect(sym.id, reason: "referenced by #selector/Selector")
        }
    }

    private func collectScopes(_ scope: Scope, _ visit: (Scope) -> Void) {
        visit(scope)
        for c in scope.children { collectScopes(c, visit) }
    }

    /// Objective-C root class names whose (transitive) subclasses are runtime-name-sensitive.
    private static let objcRootClassNames: Set<String> = [
        "NSObject", "NSManagedObject", "NSDocument", "NSWindowController", "NSViewController", "NSView",
        "UIResponder", "UIView", "UIViewController", "UIControl", "UIButton", "UILabel", "UIWindow",
        "UITableViewCell", "UICollectionViewCell", "UITableViewController", "UICollectionViewController",
        "UINavigationController", "UITabBarController", "UIScrollView", "UIApplication",
        "UICollectionReusableView", "UIGestureRecognizer", "UIPageViewController",
    ]

    /// For each type that conforms to an unknown (external) protocol, protect only the members
    /// whose names match documented requirements of that protocol (View→body, Identifiable→id,
    /// etc). Other members of the type stay renameable. The type name itself is renameable too
    /// — stdlib protocols don't care about the conformer's name.
    ///
    /// For unknown protocols not in the registry, we fall back to protecting everything in the
    /// conformer — safest option until that protocol is added to the registry.
    private func runNonLocalConformanceProtection() {
        for sym in table.symbols where isTypeKind(sym.kind) {
            guard let parent = sym.scope else { continue }
            guard let inner = parent.children.first(where: { $0.owner?.id == sym.id }) else { continue }

            // External protocols this type conforms to — INCLUDING ones reached only THROUGH a
            // local protocol (`class C: Widget`, `protocol Widget: Hashable`). The conformer's
            // witness for such a requirement (`hash(into:)`) satisfies a stdlib protocol that is
            // NOT in our table, so WitnessLinker (local-only) never links it; without this
            // transitive walk it gets renamed and the build breaks ("does not conform to Hashable").
            let (knownExternal, unknownExternal) = reachableExternalProtocols(from: sym)
            guard !knownExternal.isEmpty || !unknownExternal.isEmpty else { continue }

            if !unknownExternal.isEmpty {
                // Unknown external protocol — we don't know its requirements, so any member COULD be
                // its witness ⇒ protect, fail-closed. EXCEPT members already explained by a LOCAL
                // protocol the type conforms to: those are that protocol's witnesses (WitnessLinker
                // renames them as a coordinated group) and are unrelated to the unknown external.
                // Blanket-protecting them was pure over-protection — a `QLPreviewControllerDataSource`
                // conformer lost its unrelated local-protocol method `f1`.
                let reason = "conforms to unknown external '\(unknownExternal.joined(separator: ","))'"
                protect(sym.id, reason: reason)
                protectAllMembers(of: sym, in: inner, reason: reason,
                                  except: localProtocolRequirementNames(for: sym))
                continue
            }

            if !knownExternal.isEmpty {
                // Known external protocols — protect only their documented requirements.
                var allReqs: Set<String> = []
                for protoName in knownExternal {
                    if let reqs = stdlibRegistry.requirements(for: protoName) {
                        for r in reqs { allReqs.insert(r) }
                    }
                }
                for member in inner.symbols where allReqs.contains(member.name) {
                    protect(member.id,
                            reason: "stdlib requirement (\(knownExternal.joined(separator: ",")).\(member.name))")
                }
                // Also: for representable/coordinator-style protocols, the nested Coordinator type
                // is part of the contract (associated type). Protect it if present.
                if knownExternal.contains(where: { $0.hasSuffix("Representable") }) {
                    if let coord = inner.symbols.first(where: { $0.name == "Coordinator" && isTypeKind($0.kind) }) {
                        protect(coord.id, reason: "stdlib requirement (Coordinator nested type)")
                        if let coordScope = inner.children.first(where: { $0.owner?.id == coord.id }) {
                            // Coordinator's protocol-driven methods (delegate callbacks) are typically
                            // @objc-driven. Protector's @objc rule handles this; if not @objc,
                            // explicit declaration of conformance to e.g. PHPickerViewControllerDelegate
                            // surfaces via the same NonLocalConformanceProtector pass — it'll handle Coordinator's
                            // members when it walks Coordinator as a type symbol.
                            _ = coordScope
                        }
                    }
                }
            }
        }
    }

    private func protectAllMembers(of sym: Symbol, in inner: Scope, reason: String,
                                   except explained: Set<String> = []) {
        for member in inner.symbols {
            if explained.contains(member.name) { continue }   // witness of a local protocol — leave it
            protect(member.id, reason: reason)
            if isTypeKind(member.kind),
               let nested = inner.children.first(where: { $0.owner?.id == member.id }) {
                for nm in nested.symbols { protect(nm.id, reason: reason) }
            }
        }
    }

    /// Names of all requirements of the LOCAL protocols `sym` conforms to (directly or via
    /// extensions). A member of `sym` matching one is a witness of a protocol we DO understand —
    /// WitnessLinker renames it as a coordinated group — so the unknown-external protect-all net must
    /// not swallow it. ConformanceVisibility (runs before Protector) has already folded inherited
    /// requirements into each local protocol's scope, so inner-scope members cover transitively-
    /// inherited requirements too.
    private func localProtocolRequirementNames(for sym: Symbol) -> Set<String> {
        var conformed = inheritanceNames(for: sym).map(simpleBaseName)
        conformed.append(contentsOf: table.extensionConformanceNames(ownerId: sym.id).map(simpleBaseName))
        var names: Set<String> = []
        for name in conformed {
            guard let proto = ConformanceVisibility.preferredProtocol(in: table, named: name, forModule: sym.module.name),
                  let protoParent = proto.scope,
                  let protoScope = protoParent.children.first(where: { $0.owner?.id == proto.id })
            else { continue }
            for m in protoScope.symbols
            where m.kind == .method || m.kind == .property || m.kind == .typealias_ || m.kind == .associatedtype_ {
                names.insert(m.name)
            }
        }
        return names
    }

    private func isTypeKind(_ k: SymbolKind) -> Bool {
        switch k { case .class, .struct, .enum, .protocol: return true; default: return false }
    }

    /// We don't bother protecting against names we know are pure-value built-ins
    /// (would otherwise force-protect any enum with a raw type which Protector already handles).
    private var knownStdlibTypes: Set<String> {
        ["String","Int","UInt","Int8","Int16","Int32","Int64","UInt8","UInt16","UInt32","UInt64",
         "Double","Float","Bool","Character","Void","Never","AnyObject","AnyHashable","Any"]
    }

    /// Best-effort re-walk: find the type declaration node for `sym` in its file's syntax and
    /// return inherited identifier names. Memoized by symbol id — the transitive walk below revisits
    /// the same local protocols across many conformers.
    private var inheritanceCache: [Int: [String]] = [:]
    private func inheritanceNames(for sym: Symbol) -> [String] {
        if let cached = inheritanceCache[sym.id] { return cached }
        let visitor = InheritanceCollector(targetOffset: sym.declOffset)
        visitor.walk(sym.file.syntax)
        inheritanceCache[sym.id] = visitor.collected
        return visitor.collected
    }

    /// Collect the EXTERNAL (stdlib/SDK, not-in-our-table) protocols `sym` conforms to, following
    /// inherited LOCAL protocols transitively. `protocol Widget: Hashable` + `class C: Widget` ⇒
    /// `C` reaches external `Hashable`, so its `hash(into:)` witness must be protected even though
    /// `Hashable` lives in the stdlib and `Widget` is local. Returns the reachable external names
    /// split into (known-in-registry → protect by requirement name, unknown → protect everything).
    ///
    /// Only LOCAL PROTOCOLS are followed — NOT local base classes. A member inherited/overridden
    /// from a local base class is the OverrideLinker's concern; expanding through base classes here
    /// would over-protect every subclass for no correctness gain.
    private func reachableExternalProtocols(from sym: Symbol) -> (known: [String], unknown: [String]) {
        var known: Set<String> = []
        var unknown: Set<String> = []
        var visitedLocal: Set<Int> = []          // local protocol ids already expanded
        var seenNames: Set<String> = []
        var queue = inheritanceNames(for: sym).map(simpleBaseName)
        while let name = queue.popLast() {
            guard seenNames.insert(name).inserted else { continue }
            if knownStdlibTypes.contains(name) { continue }              // value type — not a protocol
            let locals = table.types(named: name)
            if locals.isEmpty {
                // External protocol (or unmodeled external type).
                if stdlibRegistry.requirements(for: name) != nil { known.insert(name) }
                else { unknown.insert(name) }
            } else {
                // Local — recurse into its OWN conformances, protocols only.
                for t in locals where t.kind == .protocol {
                    if visitedLocal.insert(t.id).inserted {
                        queue.append(contentsOf: inheritanceNames(for: t).map(simpleBaseName))
                    }
                }
            }
        }
        return (Array(known), Array(unknown))
    }

    /// Strip a trailing generic argument clause and surrounding whitespace so an inherited entry
    /// like `Foo<Bar>` resolves against `table.types(named: "Foo")`.
    private func simpleBaseName(_ s: String) -> String {
        var n = s
        if let lt = n.firstIndex(of: "<") { n = String(n[..<lt]) }
        return n.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func isProtected(_ sym: Symbol) -> Bool {
        reasonForId[sym.id] != nil
    }

    public func reason(for sym: Symbol) -> String? {
        reasonForId[sym.id]
    }
}

private final class InheritanceCollector: SwiftSyntax.SyntaxVisitor {
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

private final class ProtectionVisitor: SyntaxVisitor {
    let file: SourceFile
    let table: SymbolTable
    let protect: (Int, String) -> Void

    /// Class inheritance + @objc-attribute facts collected during the walk, consumed by the
    /// transitive @objc-taint pass (B-FIX-4). `id` is the class symbol; `inherited` its clause.
    var classFacts: [(id: Int, inherited: [String], isObjCAttr: Bool)] = []
    /// Names referenced by `#selector(...)` / `Selector("…")` anywhere in the file. The runtime
    /// resolves these by name, so any member of that name must be protected (B-FIX-4).
    var selectorNames: Set<String> = []
    /// Names of LOCAL types declared `@propertyWrapper` (struct/class/enum). A property annotated
    /// with one of these gets `$x`/`_x` synonyms — protect it (cross-file pass in Protector).
    var localPropertyWrapperNames: Set<String> = []
    /// Properties carrying an attribute, with the attribute names. The cross-file pass protects any
    /// whose attribute is a known SwiftUI/Combine wrapper OR a local `@propertyWrapper` type.
    var wrappedPropertyCandidates: [(id: Int, attrNames: [String])] = []

    init(file: SourceFile, table: SymbolTable, protect: @escaping (Int, String) -> Void) {
        self.file = file
        self.table = table
        self.protect = protect
        super.init(viewMode: .sourceAccurate)
    }

    private func hasAttribute(_ attributes: AttributeListSyntax, named name: String) -> Bool {
        for attr in attributes {
            if let a = attr.as(AttributeSyntax.self),
               a.attributeName.trimmedDescription == name {
                return true
            }
        }
        return false
    }

    /// Resolve the type symbol DECLARED at `token` in THIS file. The visitor is sitting on a
    /// specific decl node, so the precise symbol is the one whose decl position matches — never a
    /// same-named type from another module/file. `table.types(named:).first` was registration-order
    /// dependent and could protect the wrong-module namesake while leaving the real decl renameable
    /// (B-FIX-5 — module-aware invariant).
    private func typeSymbol(declaredAt token: TokenSyntax) -> Symbol? {
        let offset = token.positionAfterSkippingLeadingTrivia.utf8Offset
        for sym in table.symbols
        where sym.file === file && sym.declOffset == offset && sym.kind.isTypeLike {
            return sym
        }
        return nil
    }

    private func protectMembers(of typeSym: Symbol, reason: String) {
        guard let scope = typeSym.scope else { return }
        // Find the child scope owned by this type symbol.
        for child in scope.children where child.owner?.id == typeSym.id {
            for member in child.symbols {
                protect(member.id, reason)
            }
        }
    }

    /// Member symbol (property/method/function) declared at `token` in THIS file.
    private func memberSymbol(declaredAt token: TokenSyntax) -> Symbol? {
        let offset = token.positionAfterSkippingLeadingTrivia.utf8Offset
        for sym in table.symbols
        where sym.file === file && sym.declOffset == offset
           && (sym.kind == .property || sym.kind == .method || sym.kind == .function) {
            return sym
        }
        return nil
    }

    // @objc / @objcMembers / @IBDesignable — record the class as an @objc-taint SEED. The actual
    // protection (this class + every transitive subclass + their members) is applied by the
    // cross-cutting transitive pass in Protector, because a subclass-of-a-subclass of an @objc root
    // is otherwise missed (B-FIX-4). Also record the inheritance clause for taint propagation.
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        let isObjCAttr = hasAttribute(node.attributes, named: "objc")
            || hasAttribute(node.attributes, named: "objcMembers")
            || hasAttribute(node.attributes, named: "IBDesignable")
        if hasAttribute(node.attributes, named: "propertyWrapper") {
            localPropertyWrapperNames.insert(node.name.text)
        }
        if let sym = typeSymbol(declaredAt: node.name) {
            let inherited = node.inheritanceClause?.inheritedTypes.map { $0.type.trimmedDescription } ?? []
            classFacts.append((id: sym.id, inherited: inherited, isObjCAttr: isObjCAttr))
        }
        return .visitChildren
    }

    // Protocol with associatedtype — generic resolution depends on declared names.
    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        var hasAssoc = false
        for member in node.memberBlock.members {
            if member.decl.is(AssociatedTypeDeclSyntax.self) { hasAssoc = true; break }
        }
        if hasAssoc, let sym = typeSymbol(declaredAt: node.name) {
            protect(sym.id, "protocol with associatedtype")
            protectMembers(of: sym, reason: "member of assoc-type protocol")
        }
        return .visitChildren
    }

    // Enum with raw-type (String/Int/...) — rawValue strings/literals tie cases to names.
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        let rawTypes: Set<String> = ["String", "Int", "UInt", "Int8", "Int16", "Int32", "Int64",
                                     "UInt8", "UInt16", "UInt32", "UInt64", "Double", "Float", "Bool"]
        var hasRaw = false
        if let inh = node.inheritanceClause {
            for entry in inh.inheritedTypes {
                if rawTypes.contains(entry.type.trimmedDescription) {
                    hasRaw = true; break
                }
            }
        }
        if hasRaw, let sym = typeSymbol(declaredAt: node.name) {
            protect(sym.id, "enum with raw type")
            protectMembers(of: sym, reason: "raw-type enum case")
        }
        return .visitChildren
    }

    // @propertyWrapper — projected/wrappedValue contract.
    // @resultBuilder — buildBlock contract.
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        if hasAttribute(node.attributes, named: "propertyWrapper") || hasAttribute(node.attributes, named: "resultBuilder") {
            if hasAttribute(node.attributes, named: "propertyWrapper") {
                localPropertyWrapperNames.insert(node.name.text)
            }
            if let sym = typeSymbol(declaredAt: node.name) {
                let reason = hasAttribute(node.attributes, named: "propertyWrapper") ? "@propertyWrapper" : "@resultBuilder"
                protect(sym.id, reason)
                protectMembers(of: sym, reason: "\(reason) member")
            }
        }
        return .visitChildren
    }

    /// Property wrappers (`@State`/`@Binding`/`@Published` and any CUSTOM `@propertyWrapper` type)
    /// create hidden synonyms `_x` / `$x` at the use-site that we can't rename consistently — and
    /// relying on RollbackPass to revert `x` is unsafe (it strips string literals, so a `$x` inside
    /// `"\($x)"` is invisible to it). Protect the wrapped property. Known SwiftUI/Combine wrappers are
    /// protected here immediately (their type isn't in our source); custom local wrappers are matched
    /// cross-file by `runPropertyWrapperProtection` against `localPropertyWrapperNames`.
    private static let knownWrapperNames: Set<String> = [
        "State", "Binding", "Published", "StateObject", "ObservedObject", "EnvironmentObject",
        "Environment", "AppStorage", "SceneStorage", "FocusState", "FocusedBinding",
        "FocusedValue", "GestureState", "Namespace", "ScaledMetric", "FetchRequest",
        "SectionedFetchRequest", "Bindable", "Default",
    ]
    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        var attrNames: [String] = []
        for attr in node.attributes {
            if let a = attr.as(AttributeSyntax.self) { attrNames.append(a.attributeName.trimmedDescription) }
        }
        guard !attrNames.isEmpty else { return .visitChildren }
        let knownWrapper = attrNames.first { Self.knownWrapperNames.contains($0) }
        for binding in node.bindings {
            guard let ident = binding.pattern.as(IdentifierPatternSyntax.self),
                  let sym = memberSymbol(declaredAt: ident.identifier), sym.kind == .property else { continue }
            if let wrapper = knownWrapper {
                protect(sym.id, "@\(wrapper) property wrapper (creates _x/$x synonyms)")
            }
            // Defer custom-@propertyWrapper matching to the cross-file pass (the wrapper type may be
            // declared in another file we haven't walked yet).
            wrappedPropertyCandidates.append((id: sym.id, attrNames: attrNames))
        }
        return .visitChildren
    }

    // @IBOutlet / @IBInspectable / @objc properties — the runtime / Interface Builder reference
    // these by name (KVC / storyboard outlets), so renaming orphans them (B-FIX-4).
    override func visitPost(_ node: VariableDeclSyntax) {
        let objcExposing: Set<String> = ["IBOutlet", "IBInspectable", "objc"]
        guard let attr = firstAttribute(node.attributes, in: objcExposing) else { return }
        for binding in node.bindings {
            guard let ident = binding.pattern.as(IdentifierPatternSyntax.self),
                  let sym = memberSymbol(declaredAt: ident.identifier) else { continue }
            protect(sym.id, "@\(attr) (runtime/IB name-sensitive)")
        }
    }

    // @IBAction / @objc methods — referenced by selector string at runtime; protect by name.
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let objcExposing: Set<String> = ["IBAction", "objc", "IBSegueAction"]
        if let attr = firstAttribute(node.attributes, in: objcExposing),
           let sym = memberSymbol(declaredAt: node.name) {
            protect(sym.id, "@\(attr) (selector/runtime name-sensitive)")
        }
        return .visitChildren
    }

    // `#selector(Foo.bar)` / `#selector(getter: bar)` — collect the referenced member name(s).
    override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
        if node.macroName.text == "selector" {
            for arg in node.arguments { collectSelectorName(from: arg.expression) }
        }
        return .visitChildren
    }

    // `Selector("doThing:withOther:")` — protect the method base name (`doThing`).
    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let callee = node.calledExpression.as(DeclReferenceExprSyntax.self),
           callee.baseName.text == "Selector",
           let firstArg = node.arguments.first,
           let str = firstArg.expression.as(StringLiteralExprSyntax.self),
           let value = str.representedLiteralValue {
            let base = value.split(separator: ":").first.map(String.init) ?? value
            if !base.isEmpty { selectorNames.insert(base) }
        }
        return .visitChildren
    }

    /// Extract the referenced identifier from a `#selector` argument expression: `Foo.bar` →
    /// `bar`, bare `bar` → `bar`.
    private func collectSelectorName(from expr: ExprSyntax) {
        if let member = expr.as(MemberAccessExprSyntax.self) {
            selectorNames.insert(strip(member.declName.baseName.text))
        } else if let ref = expr.as(DeclReferenceExprSyntax.self) {
            selectorNames.insert(strip(ref.baseName.text))
        }
    }

    private func firstAttribute(_ attributes: AttributeListSyntax, in names: Set<String>) -> String? {
        for attr in attributes {
            if let a = attr.as(AttributeSyntax.self) {
                // `@objc(custom)` keeps the base name `objc`.
                let name = a.attributeName.trimmedDescription
                if names.contains(name) { return name }
            }
        }
        return nil
    }

    private func strip(_ s: String) -> String {
        guard s.count >= 2, s.hasPrefix("`"), s.hasSuffix("`") else { return s }
        return String(s.dropFirst().dropLast())
    }
}
