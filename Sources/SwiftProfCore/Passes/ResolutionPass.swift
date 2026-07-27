import Foundation
import SwiftSyntax

/// Walks all writable source files, resolves each identifier use-site against the SymbolTable
/// and the active scope chain, and emits Rename edits for sites whose target symbol is in the
/// rename map. Also emits Rename edits for the declarations themselves.
public final class ResolutionPass {
    public let table: SymbolTable
    public let map: RenameMap
    public let logger: Logger
    public let diagnoseOverloads: Bool
    /// A4 USR ground-truth, when `indexStorePath` is set. nil ⇒ syntactic resolution only.
    public let indexContext: IndexContext?

    public init(table: SymbolTable, map: RenameMap, logger: Logger, diagnoseOverloads: Bool = false,
                indexContext: IndexContext? = nil) {
        self.table = table
        self.map = map
        self.logger = logger
        self.diagnoseOverloads = diagnoseOverloads
        self.indexContext = indexContext
    }

    public func run(on files: [SourceFile]) -> [Rename] {
        var renames: [Rename] = []

        // 1) Declaration renames — for every symbol that has an obf name.
        for sym in table.symbols {
            guard let obf = map.obf(for: sym) else { continue }
            renames.append(Rename(
                file: sym.file,
                offset: sym.declOffset,
                length: sym.declLength,
                original: sym.name,
                replacement: NamePool.wrapIfKeyword(obf),
                targetSymbolId: sym.id
            ))
        }

        // 2) Use-site renames — walk each writable file's syntax tree.
        for file in files where file.module.writable {
            guard let fileScope = table.fileScopes[ObjectIdentifier(file)] else { continue }
            let visitor = ResolutionVisitor(file: file, table: table, map: map, fileScope: fileScope,
                                            logger: logger, diagnose: diagnoseOverloads,
                                            indexContext: indexContext)
            visitor.walk(file.syntax)
            renames.append(contentsOf: visitor.renames)
        }

        return renames
    }
}

private final class ResolutionVisitor: SyntaxVisitor {
    let file: SourceFile
    let table: SymbolTable
    let map: RenameMap
    let logger: Logger
    let diagnose: Bool
    let typeResolver: TypeResolver
    /// Cache of module-scoped resolvers (`resolveParamType` / `typealiasUnwrap` need a resolver in
    /// a candidate's OWN module). Reused so we don't allocate a fresh TypeResolver — and discard its
    /// memo cache — on every call (C-3).
    private var resolverByModule: [String: TypeResolver] = [:]
    var renames: [Rename] = []
    var scopeStack: [Scope]
    /// Names introduced by optional bindings (`guard let x`, `if let x`, `while let x`) that
    /// are currently in lexical scope. Such a name shadows any same-named property/global —
    /// references to it must NOT be renamed to the shadowed declaration's obf. Flow-sensitive:
    /// a binding is added only AFTER its initializer has been visited (so `guard let x = x`
    /// correctly resolves the RHS to the outer `x`). Frames align with function/closure scopes.
    var shadowFrames: [Set<String>] = [[]]
    /// Parallel to `shadowFrames`: the inferred STATIC TYPE NAME of each in-scope optional binding,
    /// keyed by bound name (when we could infer it from the initializer). An `if let u = makeURL()`
    /// binding carries no `declaredType` (it's not a declared symbol), so a call `c.f(u)` had no way
    /// to disambiguate overloads. Recording the binding's type here lets `argConstraint` type such a
    /// use-site argument (B-FIX-11 follow-up). Tracked here rather than as a real Symbol so the
    /// binding never shadows the same-named property during the binding's OWN initializer resolution
    /// (`guard let x = x` — the RHS must still resolve to the property).
    var shadowBindingTypeFrames: [[String: String]] = [[:]]
    /// Token ids whose rename decision was already made by qualified-type-chain resolution
    /// (`A.B.C`). Set by the outermost MemberType node; consulted by the inner MemberType nodes
    /// and the root IdentifierType so they do NOT independently rename a partial root match
    /// (which produced compile-breaking `<wrongObf>.Member` against a same-named sibling type).
    var chainHandled: Set<SyntaxIdentifier> = []

    /// A4 context (nil ⇒ syntactic only). When present, the per-file converter + normalized path
    /// let any TypeResolver turn a use-site offset into the line:column the index keys on.
    let indexContext: IndexContext?
    private let useSiteFilePath: String?
    private let useSiteConverter: SourceLocationConverter?

    init(file: SourceFile, table: SymbolTable, map: RenameMap, fileScope: Scope, logger: Logger,
         diagnose: Bool = false, indexContext: IndexContext? = nil) {
        self.file = file
        self.table = table
        self.map = map
        self.logger = logger
        self.diagnose = diagnose
        self.indexContext = indexContext
        // Build the converter only when the index is engaged (it parses positions; skip the cost
        // on the syntactic baseline). Use locals to avoid reading self before super.init.
        let path: String?
        let conv: SourceLocationConverter?
        if indexContext != nil {
            path = USRIndex.normalize(file.url.path)
            conv = SourceLocationConverter(fileName: file.url.path, tree: file.syntax)
        } else {
            path = nil
            conv = nil
        }
        self.useSiteFilePath = path
        self.useSiteConverter = conv
        self.typeResolver = TypeResolver(table: table, preferredModule: file.module.name,
                                         indexContext: indexContext,
                                         useSiteFilePath: path,
                                         useSiteConverter: conv)
        self.scopeStack = [fileScope]
        super.init(viewMode: .sourceAccurate)
        // Let TypeResolver type optional-binding locals (not Symbols) via the flow-sensitive tracker,
        // so member/chain resolution on a binding (`if let acc = makeFoo(); acc.x.y`) works. Safe: the
        // tracker is read at call time (typeSymbol(of:) is uncached), reflecting the current flow.
        self.typeResolver.localBindingTypeName = { [weak self] in self?.shadowBindingType($0) }
    }

    /// Deterministic anonymizing hash for a source identifier — keeps NDA logs leak-free while
    /// staying stable across log lines so the same symbol reads as the same `#token`. Common
    /// stdlib type names pass through unchanged (not sensitive, useful signal).
    private static let anonPassthrough: Set<String> = [
        "String", "Int", "Bool", "Double", "Float", "CGFloat", "Data", "Date", "URL", "UUID",
        "Void", "Any", "AnyObject", "Character", "Substring", "TimeInterval", "_"
    ]
    private func anon(_ s: String) -> String {
        if Self.anonPassthrough.contains(s) { return s }
        var h: UInt64 = 1469598103934665603
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return "#" + String(h & 0xFFFFFF, radix: 16)
    }
    private func anonLabels(_ labels: [String?]) -> String {
        "[" + labels.map { $0.map { anon($0) } ?? "_" }.joined(separator: ",") + "]"
    }
    private func diag(_ msg: @autoclosure () -> String) {
        if diagnose { logger.log("OVLD \(msg())") }
    }

    private var currentScope: Scope { scopeStack.last! }

    /// A reusable TypeResolver scoped to `module` (memoized — see `resolverByModule`).
    private func resolver(forModule module: String) -> TypeResolver {
        if module == file.module.name { return typeResolver }
        if let r = resolverByModule[module] { return r }
        // Use-site file/converter are the SAME (this visitor's file); only the preferred MODULE
        // differs, so the A4 context is shared.
        let r = TypeResolver(table: table, preferredModule: module,
                             indexContext: indexContext,
                             useSiteFilePath: useSiteFilePath,
                             useSiteConverter: useSiteConverter)
        resolverByModule[module] = r
        return r
    }

    /// True if `name` is shadowed by an in-scope optional binding (so it's a local, not a
    /// reference to the same-named declaration we may have renamed).
    private func isLocallyShadowed(_ name: String) -> Bool {
        for frame in shadowFrames where frame.contains(name) { return true }
        return false
    }

    /// Swift scoping invariant: a `let`/`var` local is NOT in scope within its OWN initializer.
    /// True when `node` sits inside the initializer of the SPECIFIC binding that declares `sym` — so
    /// a reference resolving lexically to `sym` there must instead resolve to the ENCLOSING
    /// declaration (an outer property or a method), never to the not-yet-declared local. Matching is
    /// by decl OFFSET, not by name: a same-named OUTER binding whose initializer also encloses
    /// `node` (e.g. `var resource = { let resource = …; return resource }()` — the property's closure
    /// initializer contains the local's `return resource`) must NOT trip this, since that reference
    /// legitimately targets the inner local, which is fully in scope. Plain locals are static scope
    /// symbols (unlike flow-sensitive optional bindings, which `shadowFrames` already covers), so
    /// `currentScope.lookup` would otherwise hand back the not-yet-in-scope local and shadow the
    /// real target.
    private func isInsideOwnInitializer(of sym: Symbol, node: some SyntaxProtocol) -> Bool {
        var child = Syntax(node)
        var parent = node.parent
        while let p = parent {
            if let binding = p.as(PatternBindingSyntax.self),
               let initializer = binding.initializer,
               child.id == Syntax(initializer).id,
               Self.patternDeclares(binding.pattern, at: sym.declOffset) {
                return true
            }
            child = p
            parent = p.parent
        }
        return false
    }

    /// `currentScope.lookup(name:)` for a bare reference, honouring the own-initializer rule: when
    /// the innermost match is a value local whose initializer contains `node`, resolve the name from
    /// the local's ENCLOSING scope instead (so `count` in `let count = count + 1` reads the outer
    /// property). Falls back to the plain match otherwise.
    private func lookupOutsideOwnInitializer(name: String, at node: some SyntaxProtocol) -> Symbol? {
        guard let sym = currentScope.lookup(name: name) else { return nil }
        guard Self.isValueBinding(sym.kind), let declScope = sym.scope,
              isInsideOwnInitializer(of: sym, node: node) else { return sym }
        return declScope.parent?.lookup(name: name)
    }

    /// Whether `pattern` declares an identifier at decl-offset `offset` (`let name`, or a tuple
    /// element). Offset-keyed so it identifies the EXACT binding, not merely a same-named one.
    static func patternDeclares(_ pattern: PatternSyntax, at offset: Int) -> Bool {
        if let ident = pattern.as(IdentifierPatternSyntax.self) {
            return ident.identifier.positionAfterSkippingLeadingTrivia.utf8Offset == offset
        }
        if let tuple = pattern.as(TuplePatternSyntax.self) {
            return tuple.elements.contains { patternDeclares($0.pattern, at: offset) }
        }
        return false
    }

    /// A value binding (local var/let or a parameter) — the kinds that obey the own-initializer rule
    /// and can legitimately be an invoked closure value. NOT callable declarations (method/function).
    static func isValueBinding(_ k: SymbolKind) -> Bool { k == .property || k == .parameter }

    private func enterInnerScope(of node: some SyntaxProtocol) {
        if let s = table.innerScope[node.id] {
            scopeStack.append(s)
            shadowFrames.append([])   // new lexical frame for bindings
            shadowBindingTypeFrames.append([:])
        }
    }
    private func exitInnerScope(of node: some SyntaxProtocol) {
        if table.innerScope[node.id] != nil {
            scopeStack.removeLast()
            shadowFrames.removeLast()
            shadowBindingTypeFrames.removeLast()
        }
    }

    /// The inferred static type name of an in-scope optional binding named `name`, if recorded.
    /// Searches frames innermost-out (mirrors `shadowFrames`).
    private func shadowBindingType(_ name: String) -> String? {
        for frame in shadowBindingTypeFrames.reversed() {
            if let t = frame[name] { return t }
        }
        return nil
    }

    /// Record a binding's inferred type into the current frame (best-effort; nil inferences skipped).
    private func recordShadowBindingType(name: String, initializer: ExprSyntax) {
        guard !shadowBindingTypeFrames.isEmpty,
              let typeName = typeResolver.declaredTypeName(of: initializer, in: currentScope) else { return }
        shadowBindingTypeFrames[shadowBindingTypeFrames.count - 1][name] = typeName
    }

    /// Closest type scope walking up from `currentScope`.
    private func enclosingTypeScope() -> Scope? {
        var s: Scope? = currentScope
        while let cur = s {
            if cur.kind == .type { return cur }
            s = cur.parent
        }
        return nil
    }

    private func emitRename(for token: TokenSyntax, target: Symbol) {
        guard let obf = map.obf(for: target) else { return }
        let offset = token.positionAfterSkippingLeadingTrivia.utf8Offset
        let length = token.trimmedLength.utf8Length
        // Wrap as backticked identifier only when bare token already is the identifier (not `Foo`).
        renames.append(Rename(
            file: file,
            offset: offset,
            length: length,
            original: target.name,
            replacement: NamePool.wrapIfKeyword(obf),
            targetSymbolId: target.id
        ))
    }

    // MARK: - Scope tracking (mirrors DeclarationPass)

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind { enterInnerScope(of: node); return .visitChildren }
    override func visitPost(_ node: ClassDeclSyntax) { exitInnerScope(of: node) }
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { enterInnerScope(of: node); return .visitChildren }
    override func visitPost(_ node: StructDeclSyntax) { exitInnerScope(of: node) }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind { enterInnerScope(of: node); return .visitChildren }
    override func visitPost(_ node: ActorDeclSyntax) { exitInnerScope(of: node) }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind { enterInnerScope(of: node); return .visitChildren }
    override func visitPost(_ node: EnumDeclSyntax) { exitInnerScope(of: node) }
    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind { enterInnerScope(of: node); return .visitChildren }
    override func visitPost(_ node: ProtocolDeclSyntax) { exitInnerScope(of: node) }
    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind { enterInnerScope(of: node); return .visitChildren }
    override func visitPost(_ node: ExtensionDeclSyntax) { exitInnerScope(of: node) }
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { enterInnerScope(of: node); return .visitChildren }
    override func visitPost(_ node: FunctionDeclSyntax) { exitInnerScope(of: node) }
    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind { enterInnerScope(of: node); return .visitChildren }
    override func visitPost(_ node: InitializerDeclSyntax) { exitInnerScope(of: node) }
    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind { enterInnerScope(of: node); return .visitChildren }
    override func visitPost(_ node: SubscriptDeclSyntax) { exitInnerScope(of: node) }
    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind { enterInnerScope(of: node); return .visitChildren }
    override func visitPost(_ node: ClosureExprSyntax) { exitInnerScope(of: node) }
    override func visit(_ node: SwitchCaseSyntax) -> SyntaxVisitorContinueKind { enterInnerScope(of: node); return .visitChildren }
    override func visitPost(_ node: SwitchCaseSyntax) { exitInnerScope(of: node) }
    override func visit(_ node: CatchClauseSyntax) -> SyntaxVisitorContinueKind { enterInnerScope(of: node); return .visitChildren }
    override func visitPost(_ node: CatchClauseSyntax) { exitInnerScope(of: node) }

    // MARK: - Function calls (handles memberwise-init argument labels)

    /// When call is `TypeName(label1: ..., label2: ...)` and TypeName is one of OUR struct/class
    /// types, the labels of a memberwise-init must match the type's property names. If we renamed
    /// those properties, the labels at the call site need to follow.
    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        // Resolve callee to a type symbol — supports both `TypeName(...)` (DeclRef) and
        // `Outer.Nested(...)` (MemberAccess chain).
        let calleeTypeSym: Symbol? = {
            if let ref = node.calledExpression.as(DeclReferenceExprSyntax.self) {
                let name = stripBackticks(ref.baseName.text)
                if let sym = currentScope.lookup(name: name), sym.kind.isTypeLike {
                    return sym
                }
                return lookupType(named: name)
            }
            if let member = node.calledExpression.as(MemberAccessExprSyntax.self) {
                // `self.init(...)` / `Self.init(...)` / `TypeName.init(...)` — a delegating or
                // qualified memberwise call. Resolve to the constructed TYPE so its memberwise
                // labels follow the renamed properties (without this, `self.init(alphaValue:…)` in
                // an extension keeps the original label while the property renamed → "incorrect
                // argument label" red).
                if stripBackticks(member.declName.baseName.text) == "init", let base = member.base {
                    if let baseRef = base.as(DeclReferenceExprSyntax.self) {
                        let baseName = stripBackticks(baseRef.baseName.text)
                        if baseName == "self" || baseName == "Self" {
                            return enclosingTypeScope()?.owner
                        }
                        if let s = currentScope.lookup(name: baseName), s.kind.isTypeLike { return s }
                        return lookupType(named: baseName)
                    }
                }
                return typeResolver.typeSymbol(of: node.calledExpression, in: currentScope)
            }
            return nil
        }()
        // Unwrap typealias before checking the underlying kind — `typealias T = SomeStruct` then
        // `T(label: …)` must still drive memberwise-init label renaming on `SomeStruct`'s scope.
        let calleeUnwrapped = calleeTypeSym.map { typealiasUnwrap($0) }
        if let typeSym = calleeUnwrapped,
           typeSym.kind == .struct,
           let typeScope = innerScope(of: typeSym) {
            // Memberwise inits exist ONLY for STRUCTS — a class is ALWAYS constructed through an
            // explicit/inherited init whose labels are real parameter labels (policy-skipped, never
            // renamed). Including classes here renamed `Sub(side:)` (which inherits the init) to the
            // SuperclassVisibility-copied `side` property's obf → "incorrect argument label" red.
            // Swift suppresses the memberwise init only when the struct wrote an explicit init in
            // its PRIMARY declaration (an EXTENSION init does NOT suppress it). Consult the
            // main-decl side-table, NOT the unified type scope (which includes extension inits) —
            // else a struct with only an extension init wrongly disables the label rename and its
            // stored properties revert (B-FIX-19 follow-up).
            let hasExplicitInit = table.structsWithMainDeclInit.contains(typeSym.id)
            if !hasExplicitInit {
                for arg in node.arguments {
                    guard let label = arg.label else { continue }
                    let labelText = label.text
                    if let member = typeScope.member(named: labelText),
                       member.kind == .property,
                       map.obf(for: member) != nil {
                        emitRename(for: label, target: member)
                    }
                }
            }
        }
        return .visitChildren
    }

    // MARK: - if-let / guard-let shorthand

    /// Expand shorthand `if let X { ... }` to `if let <obf> = <obf> { ... }` when the property
    /// `X` is being renamed. Both sides of the binding use the obfuscated name:
    ///   - rhs reads from the renamed property in enclosing scope
    ///   - lhs introduces a local shadow (same name as rhs after rename = consistent)
    /// References to `X` inside the body get renamed by normal DeclRef handling — they now
    /// resolve to the property symbol's obf, which equals the local shadow's name. Compiler
    /// treats the in-body references as the local (the unwrapped value), which is correct.
    override func visit(_ node: OptionalBindingConditionSyntax) -> SyntaxVisitorContinueKind {
        // Only the SHORTHAND form (`if let X`, no initializer) needs the expand-rewrite. The
        // explicit form (`guard let X = expr`) is handled by shadow tracking in visitPost.
        guard node.initializer == nil,
              let ident = node.pattern.as(IdentifierPatternSyntax.self) else {
            return .visitChildren
        }
        let name = stripBackticks(ident.identifier.text)
        guard let target = currentScope.lookup(name: name),
              let obf = map.obf(for: target) else {
            return .visitChildren
        }
        let safeObf = NamePool.wrapIfKeyword(obf)
        // Shorthand `if let X` → `if let <obf> = <obf>`. Pattern renamed + explicit rhs inserted.
        // Body references to X get renamed to the same obf (consistent shadow), so we do NOT
        // add a shadow frame entry here.
        emitRename(for: ident.identifier, target: target)
        let insertOffset = ident.identifier.endPositionBeforeTrailingTrivia.utf8Offset
        renames.append(Rename(
            file: file,
            offset: insertOffset,
            length: 0,
            original: "",
            replacement: " = \(safeObf)"
        ))
        return .visitChildren
    }

    /// After an optional binding's initializer has been resolved, the bound name becomes a
    /// LOCAL that shadows any same-named declaration for the rest of the lexical scope.
    /// Record it so subsequent references resolve to the local (and stay un-renamed).
    /// Only for the EXPLICIT form (`guard let X = expr`); the shorthand form is rewritten above
    /// and intentionally renamed instead.
    override func visitPost(_ node: OptionalBindingConditionSyntax) {
        guard node.initializer != nil,
              let ident = node.pattern.as(IdentifierPatternSyntax.self) else { return }
        // A `guard let X = …` binding is in scope AFTER the guard (the enclosing block), but NOT
        // inside the guard's `else` body. Adding it to the shadow frame here would shadow `X`
        // inside `else` too — so a reference like `if let X = X` in the else (where the RHS `X` is
        // actually the same-named PROPERTY) would be wrongly left un-renamed → `cannot find X in
        // scope`. Defer guard bindings to visitPost(GuardStmt), which runs after the else body.
        if isInGuardCondition(node) { return }
        let name = stripBackticks(ident.identifier.text)
        if !shadowFrames.isEmpty {
            shadowFrames[shadowFrames.count - 1].insert(name)
        }
        if let initializer = node.initializer {
            recordShadowBindingType(name: name, initializer: initializer.value)
        }
    }

    override func visit(_ node: GuardStmtSyntax) -> SyntaxVisitorContinueKind { return .visitChildren }

    /// Guard bindings come into scope only AFTER the whole guard statement. Register them now
    /// (the `else` body has already been visited with the outer meaning of these names intact).
    override func visitPost(_ node: GuardStmtSyntax) {
        guard !shadowFrames.isEmpty else { return }
        for cond in node.conditions {
            guard let binding = cond.condition.as(OptionalBindingConditionSyntax.self),
                  let initializer = binding.initializer,
                  let ident = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
            let name = stripBackticks(ident.identifier.text)
            shadowFrames[shadowFrames.count - 1].insert(name)
            recordShadowBindingType(name: name, initializer: initializer.value)
        }
    }

    /// True when an optional binding belongs to a `guard` condition (vs `if let` / `while let`).
    private func isInGuardCondition(_ node: OptionalBindingConditionSyntax) -> Bool {
        var p: Syntax? = node.parent
        while let cur = p {
            if cur.is(GuardStmtSyntax.self) { return true }
            // Stop once we leave the condition list into a body or a different statement.
            if cur.is(IfExprSyntax.self) || cur.is(WhileStmtSyntax.self) || cur.is(CodeBlockSyntax.self) {
                return false
            }
            p = cur.parent
        }
        return false
    }

    // MARK: - Key paths

    /// Resolve `\.X.Y.Z` (root inferred from context) and `\Foo.X.Y.Z` (explicit root).
    /// Each `.X` component is looked up as a member of the previous step's type and renamed.
    override func visit(_ node: KeyPathExprSyntax) -> SyntaxVisitorContinueKind {
        var current: Symbol?
        if let root = node.root {
            current = resolveTypeFromTypeSyntax(root)
        } else {
            current = inferKeyPathRoot(for: node)
        }
        guard var typeSym = current else { return .visitChildren }

        for component in node.components {
            guard let prop = component.component.as(KeyPathPropertyComponentSyntax.self) else {
                break
            }
            let memberName = stripBackticks(prop.declName.baseName.text)
            guard let inner = innerScope(of: typeSym),
                  let member = inner.member(named: memberName) else {
                break
            }
            emitRename(for: prop.declName.baseName, target: member)
            // Chain: follow declared type for next component.
            if member.kind.isTypeLike {
                typeSym = member
            } else if let declType = table.declaredType[member.id],
                      let next = typeResolver.typeSymbol(forQualifiedName: declType, in: currentScope) {
                typeSym = next
            } else {
                break  // can't follow further
            }
        }
        return .visitChildren
    }

    /// Walk up from a `\.X` shorthand to the enclosing FunctionCallExpr argument slot,
    /// look up the call as a HOF and use the element type as the root.
    private func inferKeyPathRoot(for node: KeyPathExprSyntax) -> Symbol? {
        var ref: Syntax = Syntax(node)
        var argumentIndex: Int? = nil
        while let parent = ref.parent {
            if argumentIndex == nil, let labeled = parent.as(LabeledExprSyntax.self),
               let list = labeled.parent?.as(LabeledExprListSyntax.self) {
                argumentIndex = list.enumerated().first(where: { $0.element.id == labeled.id })?.offset
            }
            if let call = parent.as(FunctionCallExprSyntax.self), let idx = argumentIndex {
                return typeResolver.hofElementType(forCallArgument: call, argIndex: idx, in: currentScope)
            }
            if parent.is(SourceFileSyntax.self) { return nil }
            ref = Syntax(parent)
        }
        return nil
    }

    // MARK: - Type references (parameter types, return types, var types, inheritance, generic args)

    override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
        // Root of a qualified chain already decided (renamed or deliberately left as-is) by
        // full-chain resolution — never rename it independently. Still descend for generic args.
        if chainHandled.contains(node.name.id) {
            return .visitChildren
        }
        let name = stripBackticks(node.name.text)
        // Prefer scope-chain lookup — catches associatedtype, generic parameters, nested types
        // that shadow globally-named types. Fall back to module-aware global type table.
        if let target = currentScope.lookup(name: name), target.kind.isTypeLike {
            emitRename(for: node.name, target: target)
        } else if let target = lookupType(named: name) {
            emitRename(for: node.name, target: target)
        }
        return .visitChildren  // also visit generic arguments
    }

    /// `Foo.Bar` in type position (e.g. `func handle(_: Foo.Bar)`). A qualified type chain must
    /// be renamed all-or-nothing against a single fully-resolving candidate: renaming only the
    /// root segment of a partial match produces an invalid `<wrongObf>.Bar` when `Foo` collides
    /// with a same-named sibling/nested type that lacks `Bar`. The OUTERMOST member-type node
    /// drives full-chain resolution; inner nodes and the root IdentifierType defer via
    /// `chainHandled`.
    override func visit(_ node: MemberTypeSyntax) -> SyntaxVisitorContinueKind {
        // Decided by an enclosing chain — skip, but still descend for generic arguments.
        if chainHandled.contains(node.name.id) {
            return .visitChildren
        }
        let isOutermost = node.parent?.is(MemberTypeSyntax.self) != true
        if isOutermost, let segments = flattenTypeChain(node) {
            resolveQualifiedTypeChain(segments)
            return .visitChildren
        }
        // Fallback for chains we can't flatten (generic / optional / array / metatype bases):
        // resolve the immediate base and rename only this member, as before.
        let memberName = stripBackticks(node.name.text)
        if let baseSym = resolveTypeFromTypeSyntax(node.baseType),
           let baseScope = innerScope(of: baseSym),
           let member = baseScope.member(named: memberName),
           member.kind.isTypeLike {
            emitRename(for: node.name, target: member)
        }
        return .visitChildren
    }

    /// Flattens a pure dotted type chain (`A.B.C`) into ordered (token, name) segments from root
    /// to member. Returns nil when the base is not a plain Identifier/Member chain (generic root,
    /// optional, array, tuple, metatype) — those fall back to per-node resolution.
    private func flattenTypeChain(_ node: MemberTypeSyntax) -> [(token: TokenSyntax, name: String)]? {
        var segs: [(TokenSyntax, String)] = [(node.name, stripBackticks(node.name.text))]
        var base: TypeSyntax = node.baseType
        while true {
            if let m = base.as(MemberTypeSyntax.self) {
                segs.append((m.name, stripBackticks(m.name.text)))
                base = m.baseType
            } else if let ident = base.as(IdentifierTypeSyntax.self) {
                segs.append((ident.name, stripBackticks(ident.name.text)))
                break
            } else {
                return nil
            }
        }
        return segs.reversed()
    }

    /// All-or-nothing resolution of a qualified type chain. Gathers every candidate for the root
    /// segment (lexically-visible type + all globally same-named types), keeps only candidates
    /// whose ENTIRE chain resolves to type-like members, and emits renames only when exactly one
    /// full chain matches. In every outcome the chain's tokens are marked handled so the root
    /// IdentifierType / inner MemberType visitors never independently rename a partial match.
    private func resolveQualifiedTypeChain(_ segments: [(token: TokenSyntax, name: String)]) {
        defer { for seg in segments { chainHandled.insert(seg.token.id) } }
        guard let rootName = segments.first?.name else { return }

        var roots: [Symbol] = []
        if let s = currentScope.lookup(name: rootName), s.kind.isTypeLike {
            roots.append(s)  // lexically-reachable (may be a nested type) — always a valid root
        }
        // Global candidates for the chain ROOT must be TOP-LEVEL: a bare first segment can't
        // name some unrelated type's nested member (req 7). Lexical nested roots already added.
        for t in table.types(named: rootName)
            where t.scope?.kind == .file && !roots.contains(where: { $0.id == t.id }) {
            roots.append(t)
        }
        // Conformance inheritance: a name like `T1` in `class C: P { … T1.S2 … }` may be a typealias
        // declared in P (or any ancestor protocol). Walk enclosing type scopes, look at their
        // inheritance clause, find protocols, and pull in typealiases/associatedtypes matching the
        // root name. Without this, `T1.S2` (where T1 = E1 via protocol typealias) can't resolve.
        if roots.isEmpty {
            for inherited in inheritedTypealiases(named: rootName) {
                if !roots.contains(where: { $0.id == inherited.id }) { roots.append(inherited) }
            }
        }

        var fullMatches: [[Symbol]] = []
        for root in roots {
            var path: [Symbol] = [root]
            // For chain WALKING use the typealias-unwrapped target; the ORIGINAL Symbol is kept
            // in `path` so its token gets renamed to ITS obf (the typealias's own rename), not the
            // underlying type's.
            var walkSym = typealiasUnwrap(root)
            var ok = true
            for seg in segments.dropFirst() {
                guard let inner = innerScope(of: walkSym),
                      let m = inner.member(named: seg.name), m.kind.isTypeLike else {
                    ok = false; break
                }
                path.append(m)
                walkSym = typealiasUnwrap(m)
            }
            if ok { fullMatches.append(path) }
        }

        // Unique full match → rename the whole chain consistently. Zero matches → leave untouched.
        // Multiple full matches (the SAME nested type-chain exists in several writable targets —
        // common when a shared source file is compiled into multiple iOS app targets) → tiebreak
        // to the chain whose ROOT lives in the use-site's own module. That's how Swift resolves
        // the reference at compile time, and matches our overload tiebreaker for consistency.
        // Without this, references like `C1.E1` in a protocol get left un-renamed while C1's decl
        // is renamed in each target — the desync RollbackPass would normally catch, but with
        // `--kinds class` only the chain ROOT is renameable and the desync slips through.
        let chosen: [Symbol]
        if fullMatches.count == 1 {
            chosen = fullMatches[0]
        } else if fullMatches.count > 1 {
            let sameModule = fullMatches.filter { $0.first?.module.name == file.module.name }
            guard sameModule.count == 1 else { return }
            chosen = sameModule[0]
        } else {
            return
        }
        for (i, seg) in segments.enumerated() {
            emitRename(for: seg.token, target: chosen[i])
        }
    }

    /// If `sym` is a typealias whose RHS resolves to another type Symbol, return that Symbol;
    /// otherwise return `sym` itself. Used by the qualified-chain walker so `T1.S2` (where
    /// `typealias T1 = E1`) is walked through E1's inner scope to find S2 — but T1 itself stays
    /// the renamed token at the use-site.
    private func typealiasUnwrap(_ sym: Symbol) -> Symbol {
        guard sym.kind == .typealias_,
              let target = table.typealiasTarget[sym.id],
              let aliasScope = sym.scope,
              let resolved = typeResolver.typeSymbol(forQualifiedName: target, in: aliasScope)
        else { return sym }
        return resolved
    }

    /// Look for a typealias/associatedtype named `name` declared in any protocol that an enclosing
    /// type scope (class/struct/enum/extension) conforms to. Mirrors how Swift resolves bare
    /// references through protocol-conformance inheritance — our scope chain doesn't model this,
    /// so without an explicit search a name like `T1` (defined as `typealias T1 = E1` in protocol
    /// P) is invisible from inside a conforming `class C: P`.
    private func inheritedTypealiases(named name: String) -> [Symbol] {
        var found: [Symbol] = []
        var seenProtocols = Set<Int>()
        var s: Scope? = currentScope
        while let cur = s {
            defer { s = cur.parent }
            guard cur.kind == .type, let owner = cur.owner else { continue }
            for inh in inheritanceNames(for: owner) {
                for proto in table.types(named: inh) where proto.kind == .protocol {
                    guard !seenProtocols.contains(proto.id) else { continue }
                    seenProtocols.insert(proto.id)
                    guard let inner = innerScope(of: proto) else { continue }
                    for m in inner.members(named: name)
                        where m.kind == .typealias_ || m.kind == .associatedtype_ {
                        found.append(m)
                    }
                }
            }
        }
        return found
    }

    /// Inheritance-clause type names for a type symbol (re-reading its decl node — same pattern
    /// WitnessLinker uses). Returns an empty list if the symbol's decl can't be located.
    private func inheritanceNames(for sym: Symbol) -> [String] {
        InheritanceClause.names(atOffset: sym.declOffset, in: sym.file.syntax)
    }

    /// Walk type-position syntax (IdentifierType / MemberType / OptionalType / ArrayType-of-type)
    /// and return the underlying type Symbol when resolvable.
    private func resolveTypeFromTypeSyntax(_ type: TypeSyntax) -> Symbol? {
        if let ident = type.as(IdentifierTypeSyntax.self) {
            let name = stripBackticks(ident.name.text)
            if let target = currentScope.lookup(name: name), target.kind.isTypeLike {
                return target
            }
            return lookupType(named: name, at: ident.name.positionAfterSkippingLeadingTrivia.utf8Offset)
        }
        if let member = type.as(MemberTypeSyntax.self) {
            guard let baseSym = resolveTypeFromTypeSyntax(member.baseType),
                  let baseScope = innerScope(of: baseSym) else { return nil }
            return baseScope.member(named: stripBackticks(member.name.text))
        }
        if let opt = type.as(OptionalTypeSyntax.self) {
            return resolveTypeFromTypeSyntax(opt.wrappedType)
        }
        return nil
    }

    private func stripBackticks(_ s: String) -> String {
        guard s.count >= 2, s.hasPrefix("`"), s.hasSuffix("`") else { return s }
        return String(s.dropFirst().dropLast())
    }

    /// Module-aware type lookup: prefers a type declared in the same module as the file being
    /// rewritten, disambiguating same-named types across targets. Pass the use-site token's UTF-8
    /// offset to engage the USR tiebreak (A4) when several same-named candidates survive.
    private func lookupType(named name: String, at useSiteOffset: Int? = nil) -> Symbol? {
        typeResolver.resolveType(named: name, at: useSiteOffset)
    }

    // MARK: - Expression references

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        // Key-path property component (`\.title`, the `bar` in `\Root.bar`): resolved ENTIRELY by
        // visit(KeyPathExprSyntax) against the root TYPE, not lexical scope. Emitting here as well
        // would (a) double-edit the same token — the Rewriter then eats the following bytes (the
        // `))` after `\.title`) — and (b) in the keypath's un-resolvable-root fallback, wrongly
        // rename by lexical scope (a keypath member is never a lexical lookup). Owned there, skip here.
        if node.parent?.is(KeyPathPropertyComponentSyntax.self) == true {
            return .skipChildren
        }
        // Skip if this DeclReferenceExpr is part of a MemberAccessExpr (handled there)
        // OR is the `calledExpression` of a function call where we'd resolve the call separately.
        if node.parent?.is(MemberAccessExprSyntax.self) == true {
            // Member-side handled by MemberAccessExpr visitor; base-side falls into here separately.
            // We need to distinguish: if this is the `declName` of MemberAccess, skip (it's the member).
            if let memberAccess = node.parent?.as(MemberAccessExprSyntax.self),
               memberAccess.declName.id == node.id {
                return .skipChildren
            }
            // Otherwise this is the base — fall through to resolve as identifier.
        }
        let token = node.baseName
        let name = stripBackticks(token.text)
        // self/Self/super/etc — skip.
        if NamePool.swiftKeywords.contains(name) { return .skipChildren }
        // Local optional-binding shadow (`guard let x = x; ... x ...`) — `x` here is the local,
        // not the same-named property we may have renamed. Leave it untouched.
        if isLocallyShadowed(name) { return .skipChildren }

        // Callee of a function call `name(args)`.
        if let call = node.parent?.as(FunctionCallExprSyntax.self),
           call.calledExpression.id == node.id {
            // A name in scope. Decide how to treat it — but a `let`/`var` local is NOT in scope
            // within its OWN initializer (Swift), so a call to the same name there targets the
            // enclosing method, not the not-yet-declared (non-callable) local. Skip such a local so
            // control falls through to resolveCall (callable-only, overload-aware). Without this,
            // `f(…)` inside `let f = … f(…) …` binds to the value local → the call is left
            // un-renamed while the method decl renames → "use of local variable before its decl".
            if let sym = currentScope.lookup(name: name),
               !(Self.isValueBinding(sym.kind) && isInsideOwnInitializer(of: sym, node: node)) {
                switch sym.kind {
                case .class, .struct, .enum, .protocol, .typealias_, .associatedtype_:
                    // Constructor call `TypeName(...)` — rename as a type reference.
                    emitRename(for: token, target: sym)
                    return .skipChildren
                case .parameter, .property:
                    // A closure-typed value being invoked, e.g. `content()` where
                    // `content: () -> String`. Single binding — rename directly, no overload logic.
                    emitRename(for: token, target: sym)
                    return .skipChildren
                default:
                    break  // function/method — fall through to label-aware overload resolution
                }
            }
            if let typeSym = lookupType(named: name, at: token.positionAfterSkippingLeadingTrivia.utf8Offset) {
                emitRename(for: token, target: typeSym)
                return .skipChildren
            }
            // Function call — resolve the overload by argument labels (and, when labels alone are
            // ambiguous, by argument types) so we don't pick a same-named-but-different-signature
            // function from an enclosing scope or a foreign module.
            if let target = resolveCall(name: name, call: call) {
                emitRename(for: token, target: target)
            }
            // Ambiguous / no unique match → leave the call un-renamed. The original name then
            // survives in output and RollbackPass reverts any partial renames of it.
            return .skipChildren
        }

        if let target = lookupOutsideOwnInitializer(name: name, at: node) {
            // A bare reference to a CALLABLE used as a value (`let h = send`, `perform(send)`).
            // If `send` is overloaded (>1 same-named callable with differing obfs), `lookup`'s
            // first-match risks binding the wrong overload — a wrong-rename red RollbackPass can't
            // catch. Resolve by the expected function-type annotation, else fail closed.
            if Self.isCallable(target.kind) {
                if let resolved = resolveBareCallableReference(name: name, target: target, node: node) {
                    emitRename(for: token, target: resolved)
                }
                // else: leave un-renamed → the surviving original triggers RollbackPass to revert
                // the whole group (green), instead of a silent wrong-overload rewrite.
                return .skipChildren
            }
            emitRename(for: token, target: target)
        } else if let target = lookupType(named: name, at: token.positionAfterSkippingLeadingTrivia.utf8Offset) {
            emitRename(for: token, target: target)
        } else if let inherited = inheritedTypealiases(named: name).first {
            // Conformance-inherited typealias as a VALUE reference: `T1.X` or `T1.self` — rename
            // the bare token to the typealias's OWN obf (its decl's rename), not the underlying
            // type's. Without this, T1 stays original while T1's decl was renamed → desync.
            emitRename(for: token, target: inherited)
        }
        return .skipChildren
    }

    /// Argument labels at a call site, including trailing closures (which are positional / nil).
    static func argumentLabels(of call: FunctionCallExprSyntax) -> [String?] {
        var labels: [String?] = call.arguments.map { $0.label?.text }
        if call.trailingClosure != nil { labels.append(nil) }
        for extra in call.additionalTrailingClosures { labels.append(extra.label.text) }
        return labels
    }

    /// The rewrite target when EVERY same-named candidate maps to the SAME obf: ambiguous to PICK,
    /// unambiguous in OUTCOME, so rewrite to it instead of failing closed. This is how an
    /// obf-unified group resolves — a protocol requirement unified with its own default
    /// implementation (`WitnessLinker.linkProtocolDefaults`), a requirement unified with its
    /// witnesses, an override chain unified by `OverrideLinker` — where no argument signal can ever
    /// tell the candidates apart because their signatures are identical by construction.
    /// Returns nil when the candidates disagree (or none is renamed): the caller then
    /// disambiguates / fails closed as before.
    private func unambiguousSharedObfTarget(_ candidates: [Symbol]) -> Symbol? {
        guard let first = candidates.first, let firstObf = map.obf(for: first) else { return nil }
        return candidates.allSatisfy { map.obf(for: $0) == firstObf } ? first : nil
    }

    /// Resolve a function call to a unique Symbol. First matches argument labels: prefers
    /// candidates visible in the scope chain, falls back to a global search (inherited / cross-
    /// type / extension overloads we don't model in the scope tree). When labels alone leave more
    /// than one candidate, disambiguates by argument TYPES. Returns nil when still ambiguous —
    /// caller should NOT rename then.
    private func resolveCall(name: String, call: FunctionCallExprSyntax) -> Symbol? {
        let callLabels = Self.argumentLabels(of: call)
        let trailingStart = call.arguments.count
        var scopeMatches: [Symbol] = []
        var seen = Set<Int>()
        var s: Scope? = currentScope
        while let cur = s {
            for sym in cur.symbols where sym.name == name && Self.isCallable(sym.kind) {
                if !seen.contains(sym.id), labelsMatch(sym, callLabels, trailingStart: trailingStart) {
                    scopeMatches.append(sym); seen.insert(sym.id)
                }
            }
            s = cur.parent
        }
        if scopeMatches.count == 1 { return scopeMatches[0] }
        if scopeMatches.count > 1 {
            if let shared = unambiguousSharedObfTarget(scopeMatches) { return shared }
            let r = disambiguateByArgTypes(scopeMatches, call: call)
            reportOverloadProblem(name: name, call: call, candidates: scopeMatches, result: r)
            return r
        }

        // Nothing matched lexically — search globally, but a bare `f(args)` can only reach a
        // callable via IMPLICIT SELF: a free function, or a METHOD of the use-site's enclosing type
        // family (the enclosing type(s) + their local superclass chains + conformed protocols).
        // A same-named method of an UNRELATED type is NOT reachable this way — picking it renames
        // the call to that method's obf while the call actually targets a stdlib/other function
        // ("cannot find <obf> in scope"). This filter is exactly how Swift scopes an unqualified
        // call. (`inherited` overloads stay covered — the superclass chain is in the family.)
        var globalMatches: [Symbol] = []
        var family: Set<Int>? = nil
        for sym in table.callables(named: name) where labelsMatch(sym, callLabels, trailingStart: trailingStart) {
            if sym.kind == .method {
                if family == nil { family = enclosingTypeFamilyIds() }
                guard let ownerId = sym.scope?.owner?.id, family!.contains(ownerId) else { continue }
            }
            globalMatches.append(sym)
        }
        if globalMatches.count == 1 {
            // Single global candidate is lower-confidence than a lexical one — veto it if the
            // argument types positively contradict its signature (e.g. a local free func
            // `abs(_: Distance)` vs a call `abs(intValue)`). Leaving it un-renamed → RollbackPass
            // reverts the group → green, instead of a wrong rename it cannot catch.
            return argTypesContradict(globalMatches[0], call: call) ? nil : globalMatches[0]
        }
        if globalMatches.count > 1 {
            if let shared = unambiguousSharedObfTarget(globalMatches) { return shared }
            let r = disambiguateByArgTypes(globalMatches, call: call)
            reportOverloadProblem(name: name, call: call, candidates: globalMatches, result: r)
            return r
        }
        return nil
    }

    /// Resolve a bare (non-call) reference to a callable used as a value. When the name has a
    /// single callable meaning, return it. When OVERLOADED (>1 same-named callable reachable via
    /// the scope chain, with differing obfs), pick the overload whose signature matches the
    /// expected function-type annotation of the enclosing `let/var` binding; if that can't uniquely
    /// decide, return nil (fail closed — never guess between overloads).
    private func resolveBareCallableReference(name: String, target: Symbol,
                                              node: DeclReferenceExprSyntax) -> Symbol? {
        var candidates: [Symbol] = []
        var seen = Set<Int>()
        var s: Scope? = currentScope
        while let cur = s {
            for sym in cur.symbols where sym.name == name && Self.isCallable(sym.kind) {
                if seen.insert(sym.id).inserted { candidates.append(sym) }
            }
            s = cur.parent
        }
        if candidates.count <= 1 { return target }   // not overloaded — safe
        if let shared = unambiguousSharedObfTarget(candidates) { return shared }
        // Overloaded with differing obfs — only rename if the expected function type picks exactly
        // one. Look for the enclosing `let/var x: (A, B) -> R = <ref>` annotation.
        guard let expected = expectedFunctionParamTypeNames(around: node) else { return nil }
        let matches = candidates.filter { cand in
            guard let pTypes = table.functionParamTypes[cand.id], pTypes.count == expected.count else { return false }
            for (p, e) in zip(pTypes, expected) {
                guard let p else { return false }
                if bareTypeName(p) != e { return false }
            }
            return true
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// The parameter-type names of the function-type annotation on the enclosing `let/var` binding
    /// (`let h: (String) -> Void = send` → ["String"]). Returns nil when the reference isn't the
    /// initializer value of a function-type-annotated binding.
    private func expectedFunctionParamTypeNames(around node: DeclReferenceExprSyntax) -> [String]? {
        var p: Syntax? = Syntax(node)
        while let cur = p {
            if let binding = cur.as(PatternBindingSyntax.self) {
                guard var t = binding.typeAnnotation?.type else { return nil }
                if let attr = t.as(AttributedTypeSyntax.self) { t = attr.baseType }
                while let opt = t.as(OptionalTypeSyntax.self) { t = opt.wrappedType }
                if let tup = t.as(TupleTypeSyntax.self), tup.elements.count == 1 { t = tup.elements.first!.type }
                if let attr = t.as(AttributedTypeSyntax.self) { t = attr.baseType }
                guard let fn = t.as(FunctionTypeSyntax.self) else { return nil }
                return fn.parameters.map { Self.bareTypeNameOf($0.type) }
            }
            // Stop climbing at a statement/closure boundary — the reference isn't a plain binding.
            if cur.is(CodeBlockSyntax.self) || cur.is(FunctionCallExprSyntax.self) { return nil }
            p = cur.parent
        }
        return nil
    }

    /// Bare type NAME of a type node for signature matching (`String` → "String", `[Int]` → "[Int]",
    /// `Foo?` → "Foo", `Foo<T>` → "Foo").
    private static func bareTypeNameOf(_ type: TypeSyntax) -> String {
        var t = type
        while let opt = t.as(OptionalTypeSyntax.self) { t = opt.wrappedType }
        if let id = t.as(IdentifierTypeSyntax.self) { return id.name.text }
        return t.trimmedDescription
    }

    /// Set of type-symbol ids reachable from the use-site via IMPLICIT SELF: every enclosing type
    /// scope's owner, plus each owner's LOCAL superclass chain and conformed (transitively-inherited)
    /// protocols. A method whose owning type is in this set is callable bare; one outside it is not.
    private func enclosingTypeFamilyIds() -> Set<Int> {
        var result = Set<Int>()
        var s: Scope? = currentScope
        while let cur = s {
            if cur.kind == .type, let owner = cur.owner {
                addTypeFamily(owner, into: &result)
            }
            s = cur.parent
        }
        return result
    }

    private func addTypeFamily(_ typeSym: Symbol, into result: inout Set<Int>) {
        guard result.insert(typeSym.id).inserted else { return }   // cycle / already-seen guard
        // Primary-decl inheritance clause + conformances declared on the type's EXTENSIONS
        // (`extension Tool: Helper` — B-FIX-6 discipline; without them a protocol adopted in an
        // extension is missing from the family / conformance evidence).
        var names = inheritanceNames(for: typeSym)
        names.append(contentsOf: table.extensionConformanceNames(ownerId: typeSym.id))
        for inh in names {
            let base = bareTypeName(inh)
            // Module-aware: a bare inherited name resolves in the type's own module first.
            for cand in table.types(named: base)
            where cand.kind == .class || cand.kind == .protocol {
                if cand.module.name == typeSym.module.name || table.types(named: base).count == 1 {
                    addTypeFamily(cand, into: &result)
                }
            }
        }
    }

    /// Transitive type family of an arbitrary type symbol (itself + superclasses + protocols,
    /// incl. extension-declared conformances). Used as conformance evidence when scoring a
    /// concrete argument against a protocol-typed parameter.
    private func typeFamilyIds(of typeSym: Symbol) -> Set<Int> {
        var result = Set<Int>()
        addTypeFamily(typeSym, into: &result)
        return result
    }

    /// True when at least one argument's static type POSITIVELY contradicts the candidate's
    /// parameter type at that index (both sides known and different). Neutral/unknown args never
    /// contradict. Mirrors `disambiguateByArgTypes`'s `consistent` check, factored for the
    /// single-global-candidate veto.
    private func argTypesContradict(_ cand: Symbol, call: FunctionCallExprSyntax) -> Bool {
        guard let pTypes = table.functionParamTypes[cand.id] else { return false }
        let args = Array(call.arguments.map { $0.expression })
        for (i, arg) in args.enumerated() {
            guard i < pTypes.count, let pType = pTypes[i] else { continue }
            switch argConstraint(arg) {
            case .enumCase(let caseName):
                if let t = typeResolver.typeSymbol(forQualifiedName: pType, in: currentScope),
                   t.kind == .enum, !enumHasCase(t, caseName) { return true }
            case .typeSymbol(let argSym):
                // Protocol-typed params accept any conformer — never a contradiction (mirrors
                // disambiguateByArgTypes' neutrality guard).
                if let pSym = resolveParamType(pType, candidate: cand), pSym.id != argSym.id,
                   pSym.kind != .protocol { return true }
            case .typeName(let tn):
                if bareTypeName(pType) != tn,
                   let pSym = resolveParamType(pType, candidate: cand),
                   pSym.kind != .protocol { return true }
            case .unknown:
                break
            }
        }
        return false
    }

    /// Among label-matching overloads, pick the one whose declared parameter types best fit the
    /// call's argument expressions. The strongest signal we can read syntactically is an enum-case
    /// shorthand (`.none`): it fits a parameter whose type is an enum declaring that case, and is
    /// INCONSISTENT with a parameter whose type is a known enum that does NOT declare it. Literal
    /// arguments contribute a weaker positive signal (`"x"` → String, `1` → Int, …).
    ///
    /// Returns the unique candidate with a strictly-highest POSITIVE score among the
    /// type-consistent ones. Returns nil when there's no positive evidence or a tie — we never
    /// guess between equally-plausible overloads (that would risk a compile-breaking wrong rename).
    private func disambiguateByArgTypes(_ candidates: [Symbol], call: FunctionCallExprSyntax) -> Symbol? {
        let args = Array(call.arguments.map { $0.expression })
        var scored: [(sym: Symbol, score: Int)] = []
        for cand in candidates {
            guard let pTypes = table.functionParamTypes[cand.id] else { continue }
            var score = 0
            var consistent = true
            for (i, arg) in args.enumerated() {
                guard i < pTypes.count, let pType = pTypes[i] else { continue }
                switch argConstraint(arg) {
                case .enumCase(let caseName):
                    if let t = typeResolver.typeSymbol(forQualifiedName: pType, in: currentScope),
                       t.kind == .enum {
                        if enumHasCase(t, caseName) { score += 1 } else { consistent = false }
                    }
                case .typeSymbol(let argSym):
                    let pSym = resolveParamType(pType, candidate: cand)
                    if let pSym {
                        if pSym.id == argSym.id { score += 1 }
                        else if pSym.kind == .protocol {
                            // A protocol-typed parameter (`_ r: Renderer` / `some Renderer`)
                            // accepts any CONFORMER — identity mismatch is not a contradiction.
                            // Conformance (transitive, incl. extension-declared) is positive
                            // evidence; unknown conformance stays neutral (never eliminate — our
                            // conformance detection is incomplete, fail-safe).
                            if typeFamilyIds(of: argSym).contains(pSym.id) { score += 1 }
                        }
                        else { consistent = false }   // both concrete and different → incompatible
                    }
                    // pType unresolvable (primitive/external) → neutral
                case .typeName(let tn):
                    if bareTypeName(pType) == tn { score += 1 }
                    else if let pSym = resolveParamType(pType, candidate: cand),
                            pSym.kind != .protocol {
                        // pType is a user-defined CONCRETE Symbol but the arg is a different
                        // primitive / external (e.g. `String` arg into a custom-enum parameter) →
                        // eliminate. A PROTOCOL param stays neutral — the external type could
                        // conform via an extension we don't see.
                        consistent = false
                    }
                    // both primitive / external with different names → neutral (implicit conv)
                case .unknown:
                    break
                }
            }
            if consistent { scored.append((cand, score)) }
        }
        // Cross-target duplicate methods (the same source file compiled into several writable
        // targets → N identical candidates, one per module) are common in multi-target iOS apps.
        // Swift resolves such a call to the candidate in the use-site's own module. Apply that
        // tiebreak both when several overloads tie at the top positive score AND when there's no
        // discriminating arg signal at all (zero-arg calls, all-unknown args) — the only thing
        // that distinguishes the duplicates is their module.
        let pool: [Symbol]
        if let maxScore = scored.map(\.score).max(), maxScore > 0 {
            let top = scored.filter { $0.score == maxScore }
            if top.count == 1 { return top[0].sym }
            pool = top.map { $0.sym }
        } else {
            // No positive evidence (zero-arg call, or all args are variables/expressions we can't
            // type) — fall through to module-based tiebreak across all label-matching candidates.
            pool = scored.map { $0.sym }
        }
        let sameModule = pool.filter { $0.module.name == file.module.name }
        return sameModule.count == 1 ? sameModule[0] : nil
    }

    /// Emits one compact, anonymized diagnostic per PROBLEMATIC overloaded call — defined as: at
    /// least one label-matching candidate is a renamed overload, but the resolver did NOT pick a
    /// renamed one (either left the call un-renamed, or picked a non-renamed sibling). These are
    /// exactly the calls that risk a `Type X has no member Y` desync; everything else is silent.
    private func reportOverloadProblem(name: String, call: FunctionCallExprSyntax, candidates: [Symbol], result: Symbol?) {
        guard diagnose else { return }
        // Only flag UNRESOLVED calls where at least one renamed overload was a label-match — that's
        // the desync-risk shape (use stays original while a sibling decl was renamed). A result
        // that picked an un-renamed overload is left silent: with the type-aware argConstraint,
        // that's almost always the genuine read-only/protocol target (e.g. a forwarder calling
        // `self.f(par.rawValue)` correctly resolving to the String overload, not its own enum one).
        guard result == nil else { return }
        let renamed = candidates.filter { map.obf(for: $0) != nil }
        guard !renamed.isEmpty else { return }

        let off = call.calledExpression.positionAfterSkippingLeadingTrivia.utf8Offset
        let renamedDetails = renamed.map { describeCandidateFit($0, call: call) }.joined(separator: " ; ")
        logger.log("OVLD unresolved name=\(anon(name)) off=\(off) labels=\(anonLabels(Self.argumentLabels(of: call))) cands=\(candidates.count) renamed=\(renamed.count): \(renamedDetails)")
    }

    /// Per-arg fit detail for a single candidate (recomputes scoring locally) — only used by the
    /// diagnostic reporter, so the hot path stays log-free.
    private func describeCandidateFit(_ cand: Symbol, call: FunctionCallExprSyntax) -> String {
        guard let pTypes = table.functionParamTypes[cand.id] else { return "noPTypes" }
        let args = Array(call.arguments.map { $0.expression })
        var perArg: [String] = []
        var score = 0
        for (i, arg) in args.enumerated() {
            guard i < pTypes.count, let pType = pTypes[i] else { perArg.append("?"); continue }
            switch argConstraint(arg) {
            case .enumCase(let c):
                if let t = typeResolver.typeSymbol(forQualifiedName: pType, in: currentScope),
                   t.kind == .enum {
                    if enumHasCase(t, c) { score += 1; perArg.append(".\(anon(c))→\(anon(pType))✓") }
                    else { perArg.append(".\(anon(c))→\(anon(pType))✗noCase") }
                } else {
                    perArg.append(".\(anon(c))→\(anon(pType))~unresolvedType")
                }
            case .typeSymbol(let argSym):
                if let pSym = resolveParamType(pType, candidate: cand) {
                    if pSym.id == argSym.id { score += 1; perArg.append("\(anon(argSym.name))==\(anon(pType))✓") }
                    else { perArg.append("\(anon(argSym.name))≠\(anon(pType))✗") }
                } else {
                    perArg.append("\(anon(argSym.name))~\(anon(pType))")
                }
            case .typeName(let tn):
                if bareTypeName(pType) == tn {
                    score += 1; perArg.append("\(anon(tn))==\(anon(pType))✓")
                } else if resolveParamType(pType, candidate: cand) != nil {
                    perArg.append("\(anon(tn))≠\(anon(pType))✗")
                } else {
                    perArg.append("\(anon(tn))~\(anon(pType))")
                }
            case .unknown:
                perArg.append("?~\(anon(pType))")
            }
        }
        let mod = "\(anon(cand.module.name))/\(cand.module.writable ? "w" : "r")"
        return "mod=\(mod) pTypes=[\(pTypes.map { $0.map(anon) ?? "nil" }.joined(separator: ","))] args=[\(perArg.joined(separator: ","))] score=\(score)"
    }

    private enum ArgConstraint {
        case enumCase(String)
        case typeSymbol(Symbol)   // resolved user-defined type — match by Symbol identity
        case typeName(String)     // primitive / external (stdlib) — match by name string
        case unknown
    }

    private func argConstraint(_ expr: ExprSyntax) -> ArgConstraint {
        if let m = expr.as(MemberAccessExprSyntax.self), m.base == nil {
            return .enumCase(stripBackticks(m.declName.baseName.text))  // `.case` shorthand
        }
        if expr.is(StringLiteralExprSyntax.self) { return .typeName("String") }
        if expr.is(IntegerLiteralExprSyntax.self) { return .typeName("Int") }
        if expr.is(BooleanLiteralExprSyntax.self) { return .typeName("Bool") }
        if expr.is(FloatLiteralExprSyntax.self) { return .typeName("Double") }
        // `<enum>.rawValue` → the enum's raw type.
        if let m = expr.as(MemberAccessExprSyntax.self),
           let base = m.base,
           stripBackticks(m.declName.baseName.text) == "rawValue",
           let baseSym = typeResolver.typeSymbol(of: base, in: currentScope),
           baseSym.kind == .enum,
           let raw = table.enumRawType[baseSym.id] {
            return .typeName(raw)
        }
        // Method-call return type: `obj.method(args)` as an argument carries its method's return
        // type. Without this, anything past a method call has unknown type and disambiguation
        // falls to coarse same-module tiebreaks (a common source of wrong-overload renames).
        if let call = expr.as(FunctionCallExprSyntax.self),
           let m = call.calledExpression.as(MemberAccessExprSyntax.self),
           let recv = m.base,
           let recvType = typeResolver.typeSymbol(of: recv, in: currentScope),
           let recvScope = innerScope(of: recvType) {
            let methodName = stripBackticks(m.declName.baseName.text)
            let labels = Self.argumentLabels(of: call)
            let matches = recvScope.members(named: methodName)
                .filter { Self.isCallable($0.kind) && labelsMatch($0, labels, trailingStart: call.arguments.count) }
            if matches.count == 1, let ret = table.functionReturnType[matches[0].id] {
                // Try to resolve the return-type name to a Symbol so disambiguation uses identity;
                // fall back to the raw string when it's a primitive / external (stdlib) type.
                if let retSym = typeResolver.typeSymbol(forQualifiedName: ret, in: currentScope) {
                    return .typeSymbol(retSym)
                }
                return .typeName(ret)
            }
        }
        // Optional-binding local: `if let u = makeURL()` carries no declared Symbol, but we recorded
        // its inferred type when the binding entered scope (B-FIX-11 follow-up). Check it BEFORE the
        // general typeSymbol fallback so a binding that shadows a same-named property uses the
        // binding's own (unwrapped) type. The name is external/stdlib (URL, …) → match by name.
        if let ref = expr.as(DeclReferenceExprSyntax.self),
           let bindingType = shadowBindingType(stripBackticks(ref.baseName.text)) {
            return .typeName(bareTypeName(bindingType))
        }
        // General fallback — resolve the expression's static type via TypeResolver. Catches a
        // bare DeclRef to a typed parameter / property / variable, `obj.prop`, etc. We keep the
        // resolved Symbol so downstream matching is by IDENTITY, not by the (possibly-bare) name.
        if let sym = typeResolver.typeSymbol(of: expr, in: currentScope) {
            return .typeSymbol(sym)
        }
        // EXTERNAL/primitive-typed value (no local Symbol for its type, so the above returns nil):
        // fall back to the declared type NAME so disambiguation can still match it against a
        // candidate's param-type string. Without this a `URL`-typed argument gives NO signal and an
        // overload `f(_: URL, …)` can't be distinguished from `f(_: S2)` → either a wrong pick or
        // (now that labels are default-aware) an unresolved call. Bare value reference only.
        if let ref = expr.as(DeclReferenceExprSyntax.self),
           let valueSym = currentScope.lookup(name: stripBackticks(ref.baseName.text)),
           let typeName = table.declaredType[valueSym.id] {
            return .typeName(bareTypeName(typeName))
        }
        return .unknown
    }

    private func enumHasCase(_ typeSym: Symbol, _ caseName: String) -> Bool {
        guard let inner = innerScope(of: typeSym),
              let m = inner.member(named: caseName) else { return false }
        return m.kind == .enumCase
    }

    private func bareTypeName(_ s: String) -> String {
        var n = s
        while n.hasSuffix("?") || n.hasSuffix("!") { n = String(n.dropLast()) }
        if let lt = n.firstIndex(of: "<") { n = String(n[..<lt]) }  // `Box<Foo>` → `Box`
        return n
    }

    /// Resolve a candidate's parameter-type string (as written in source) to a Symbol in the
    /// CANDIDATE's lexical context. Returns nil for primitives / external types (`String`, `Int`,
    /// SwiftUI / Foundation) that aren't in our SymbolTable — those are matched by name instead.
    private func resolveParamType(_ paramTypeName: String, candidate: Symbol) -> Symbol? {
        let candScope = candidate.scope ?? currentScope
        return resolver(forModule: candidate.module.name)
            .typeSymbol(forQualifiedName: bareTypeName(paramTypeName), in: candScope)
    }

    /// Pick the overload from `candidates` that the call selects: filter by argument labels, then
    /// (if still >1) by argument types. Returns nil on zero or unresolved-ambiguous — callers must
    /// NOT rename then. Shared by free-function calls and member calls so both disambiguate
    /// identically.
    private func chooseOverload(_ candidates: [Symbol], call: FunctionCallExprSyntax) -> Symbol? {
        let callLabels = Self.argumentLabels(of: call)
        let labelMatches = candidates.filter { labelsMatch($0, callLabels, trailingStart: call.arguments.count) }
        if labelMatches.count == 1 { return labelMatches[0] }
        if labelMatches.count > 1 { return disambiguateByArgTypes(labelMatches, call: call) }
        return nil
    }

    /// The FunctionCallExpr this member access is the callee of (`obj.method` in `obj.method(…)`),
    /// or nil when the member access isn't being called.
    private func enclosingCall(of node: MemberAccessExprSyntax) -> FunctionCallExprSyntax? {
        if let call = node.parent?.as(FunctionCallExprSyntax.self),
           call.calledExpression.id == Syntax(node).id {
            return call
        }
        return nil
    }

    /// Resolve `name` as a member of `typeScope` for a use-site. When the name resolves to a
    /// single member, return it. When it's an OVERLOADED method (several same-named members),
    /// disambiguate by the enclosing call's signature — first-match would otherwise pick the wrong
    /// overload and emit a compile-breaking rename. Returns nil when overloaded but unresolvable
    /// (no call context, or still ambiguous): never guess between overloads.
    private func resolveMemberForUse(_ name: String, in typeScope: Scope, node: MemberAccessExprSyntax) -> Symbol? {
        let candidates = typeScope.members(named: name)
        if candidates.count <= 1 { return candidates.first }
        // Checked BEFORE label filtering on purpose: a call may omit a defaulted label in a way
        // `labelsMatch` can't model, and when every candidate shares one obf the outcome is right
        // regardless of which overload the compiler selects.
        if let shared = unambiguousSharedObfTarget(candidates) { return shared }
        guard candidates.allSatisfy({ Self.isCallable($0.kind) }), let call = enclosingCall(of: node) else {
            return nil
        }
        return chooseOverload(candidates, call: call)
    }

    static func isCallable(_ k: SymbolKind) -> Bool {
        k == .method || k == .function
    }

    /// True when the call's argument labels can be satisfied by the symbol's parameters. Matches
    /// left-to-right, SKIPPING a parameter only when it has a default value (so the call may omit
    /// it); every parameter left unsatisfied at the end must also be defaulted. This is the part of
    /// Swift's argument matching that overload resolution needs: matching labels EXACTLY by count
    /// wrongly eliminates an overload with a trailing defaulted param (`f(_ url: URL, with: = [:])`)
    /// when the call omits it (`f(u)`), leaving a different same-named overload (`f(_ par2: S2)`) as
    /// a false unique match → wrong rename → "cannot convert URL to S2". (Variadics not modelled —
    /// rare, and a miss here only costs a no-rename, never a wrong one.)
    private func labelsMatch(_ sym: Symbol, _ callLabels: [String?], trailingStart: Int = Int.max) -> Bool {
        guard let symLabels = table.functionParamLabels[sym.id] else { return false }
        let defaults = table.functionParamHasDefault[sym.id] ?? Array(repeating: false, count: symLabels.count)
        let closureParams = table.functionParamClosureInput[sym.id]
        var ci = 0, pi = 0
        while ci < callLabels.count {
            guard pi < symLabels.count else { return false }   // more args than params
            let ext = symLabels[pi]
            let callLabel = callLabels[ci]
            // A TRAILING closure (call index ≥ trailingStart) with no explicit label satisfies a
            // LABELED closure-typed parameter — Swift lets `perform { }` match
            // `perform(action: () -> Void)`. Without this the labeled param never matched a nil
            // trailing label → the whole overload was eliminated → method reverted (under-obf).
            let isTrailing = ci >= trailingStart
            let closureMatchesLabeled = isTrailing && callLabel == nil && ext != "_"
                && closureParams?[pi] != nil
            let matches = (ext == "_" ? (callLabel == nil) : (ext == callLabel)) || closureMatchesLabeled
            if matches {
                ci += 1; pi += 1
            } else if pi < defaults.count && defaults[pi] {
                pi += 1                                          // omit this defaulted parameter
            } else {
                return false                                     // required param can't be skipped
            }
        }
        // Any parameters not consumed by the call must all be defaulted.
        while pi < symLabels.count {
            guard pi < defaults.count && defaults[pi] else { return false }
            pi += 1
        }
        return true
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        let memberToken = node.declName.baseName
        let memberName = stripBackticks(memberToken.text)

        if let base = node.base {
            // Resolve base to a scope.
            if let baseRef = base.as(DeclReferenceExprSyntax.self) {
                let baseName = stripBackticks(baseRef.baseName.text)
                if baseName == "self" || baseName == "Self" {
                    // For `Self.X` inside an extension, the enclosing scope is the extension's
                    // own scope — which only knows extension-declared members. Members declared
                    // on the main type need lookup against the type symbol's CANONICAL inner scope.
                    if let typeScope = enclosingTypeScope(),
                       let owner = typeScope.owner,
                       let canonical = innerScope(of: owner),
                       let target = resolveMemberForUse(memberName, in: canonical, node: node) {
                        emitRename(for: memberToken, target: target)
                    }
                    return .visitChildren
                }
                // Base may be a type name. Resolve it preferring the LEXICAL scope chain — a
                // bare `Constants` inside `class C1 { enum Constants {...} }` means C1.Constants
                // (the nested, lexically-nearest type), NOT some other module's same-named type.
                // Only when no lexical type is visible do we fall back to the global,
                // module-aware table. (Skip if the name is a shadowed local — that's a value.)
                if !isLocallyShadowed(baseName) {
                    let baseTypeSym: Symbol? = {
                        if let s = currentScope.lookup(name: baseName), s.kind.isTypeLike { return s }
                        return lookupType(named: baseName)
                    }()
                    if let typeSym = baseTypeSym {
                        emitRename(for: baseRef.baseName, target: typeSym)
                        // Unwrap typealias so members live in the underlying type's scope. When
                        // `typeSym` is `typealias T1 = E1`, `innerScope(T1)` is nil — but `.ErrorType`
                        // is a member of E1. Without this unwrap, the member token stays un-renamed
                        // while the typealias's own decl was obfuscated → desync.
                        let walkSym = typealiasUnwrap(typeSym)
                        if let typeScope = innerScope(of: walkSym),
                           let target = resolveMemberForUse(memberName, in: typeScope, node: node) {
                            emitRename(for: memberToken, target: target)
                        }
                        return .skipChildren
                    }
                }
                // Base is an identifier we don't know as a type. Try precise type resolution
                // (handles property/parameter declared types, $x/_x property-wrapper projections,
                // optional chaining, try/await, etc.) and look up `member` in the resolved type.
                if let baseTypeSym = resolveTypeSymbol(of: base),
                   let typeScope = innerScope(of: baseTypeSym),
                   let member = resolveMemberForUse(memberName, in: typeScope, node: node) {
                    emitRename(for: memberToken, target: member)
                }
                return .visitChildren
            }
            // Chained / complex base: type-resolve to a precise type symbol (avoids ambiguity
            // when two types share a simple name — e.g. nested Coordinator inside different parents).
            if let baseSym = resolveTypeSymbol(of: base),
               let typeScope = innerScope(of: baseSym),
               let member = resolveMemberForUse(memberName, in: typeScope, node: node) {
                emitRename(for: memberToken, target: member)
            }
            return .visitChildren
        } else {
            // Shorthand `.member` — only rename if we positively identify the contextual type.
            // Globally-unique-name fallback was removed: stdlib enums often collide with our names.
            if let typeName = contextualTypeName(for: node),
               let typeSym = typeResolver.typeSymbol(forQualifiedName: typeName, in: currentScope),
               let typeScope = innerScope(of: typeSym),
               let member = resolveMemberForUse(memberName, in: typeScope, node: node) {
                emitRename(for: memberToken, target: member)
            }
            return .visitChildren
        }
    }

    /// Walks up the parent chain looking for a context that tells us the type of a shorthand
    /// `.member` expression. Handles:
    ///   - `let x: T = .member` / `var x: T = .member` (PatternBinding type annotation)
    ///   - `f(.member)` / `f(arg: .member)` (function-call positional argument; callee resolved
    ///     to a local function/method whose nth parameter has a known simple type)
    /// Returns the resolved type name or nil.
    private func contextualTypeName(for memberAccess: MemberAccessExprSyntax) -> String? {
        var current: Syntax? = Syntax(memberAccess).parent
        // First wrapper we want to skip: LabeledExprSyntax (`label: .case` arg). Track if we
        // came via an argument list so we can resolve the call.
        var argumentIndex: Int? = nil
        var sawReturn = false
        while let node = current {
            if node.is(ReturnStmtSyntax.self) { sawReturn = true }
            // Switch case pattern: contextual type is the switch subject's type. Also covers the
            // `if/guard/while case .x = e` (MatchingPatternCondition) and `for case .x in seq`
            // forms — context = the matched value's type. If we cannot resolve it, return nil —
            // never fall through to outer contexts (the enclosing var/return type is NOT the same
            // as the matched subject's type).
            if node.is(SwitchCaseItemSyntax.self) || node.is(ExpressionPatternSyntax.self) {
                var probe = node.parent
                while let p = probe {
                    if let sw = p.as(SwitchExprSyntax.self) {
                        return resolveExpressionType(sw.subject)
                    }
                    if let mc = p.as(MatchingPatternConditionSyntax.self) {
                        return resolveExpressionType(mc.initializer.value)
                    }
                    probe = p.parent
                }
                return nil
            }
            // Binary-operator operand: `x == .case` / `x != .case` / `x ~= .case` / `opt ?? .case`
            // (raw-parsed as a SequenceExpr `[lhs, BinaryOperatorExpr, rhs]`). The shorthand takes
            // the type of the OTHER operand — NOT the enclosing return/var type. Without this a
            // `.case` compared against a property of a DIFFERENT type wrongly grabs the return-type
            // context (a static member of that type) and renames to it → wrong-rename red.
            if let seq = node.as(SequenceExprSyntax.self) {
                let elems = Array(seq.elements)
                if elems.count == 3 {
                    if elems[1].is(AssignmentExprSyntax.self) {
                        // Assignment RHS: context is the LHS's type. A base-less `.case` is always
                        // on the RHS (you can't assign to a shorthand). Covers `x = .case`,
                        // `self.x = .case`, `obj.a.b = .case`.
                        return resolveExpressionType(elems[0])
                    }
                    if let op = elems[1].as(BinaryOperatorExprSyntax.self),
                       Self.contextGivingOperators.contains(op.operator.text) {
                        // Resolve the operand that is NOT the shorthand we came up from.
                        let cameFromRHS = Self.isDescendant(Syntax(memberAccess), of: Syntax(elems[2]))
                        let other = cameFromRHS ? elems[0] : elems[2]
                        return resolveExpressionType(other)
                    }
                }
            }
            // Variable/property type annotation. Unwrap array/optional so `let xs: [E] = [.a]` and
            // `let o: E? = .a` resolve the element/case context too, not just `let x: E = .a`.
            if let binding = node.as(PatternBindingSyntax.self),
               let annotation = binding.typeAnnotation,
               let elem = Self.scalarElementType(of: annotation.type) {
                return elem
            }
            // Function call argument context.
            if argumentIndex == nil, let labeled = node.as(LabeledExprSyntax.self) {
                if let list = labeled.parent?.as(LabeledExprListSyntax.self) {
                    argumentIndex = list.enumerated().first(where: { $0.element.id == labeled.id })?.offset
                }
            }
            if let call = node.as(FunctionCallExprSyntax.self), let idx = argumentIndex {
                if let typeName = resolveCalleeParamType(call: call, argIndex: idx) {
                    return typeName
                }
                return nil  // Resolved call but couldn't get param type → give up.
            }
            // Default value of a function/init parameter: `func f(x: E = .case)`. The context is the
            // PARAMETER's own declared type — must be checked BEFORE the FunctionDecl branch below,
            // or we'd wrongly grab the function's return type. (Walking up, the parameter node is
            // reached first.) Without this the `.case` default is left un-renamed while the enum case
            // is obfuscated → the original name survives → RollbackPass reverts the case → under-obf,
            // or (short debug names) an obf collision = `invalid redeclaration` red build.
            if let param = node.as(FunctionParameterSyntax.self),
               let elem = Self.scalarElementType(of: param.type) {
                return elem
            }
            // Function/method/init return type acts as context for a `.case` ONLY in return
            // position — an explicit `return .case` (sawReturn) or a single-expression implicit
            // return (`func f() -> E { .a }`). A `.case` elsewhere in the body (e.g. a comparison
            // operand) must NOT grab the return type — that leaked Style.active into `mode ==
            // .active` → wrong-rename red. If we reached the function without a return position and
            // no earlier context matched, fail closed (nil).
            if let fn = node.as(FunctionDeclSyntax.self),
               let returnClause = fn.signature.returnClause,
               let ident = returnClause.type.as(IdentifierTypeSyntax.self),
               ident.genericArgumentClause == nil {
                let implicitReturn = fn.body?.statements.count == 1
                return (sawReturn || implicitReturn) ? ident.name.text : nil
            }
            // Don't escape past the file root.
            if node.is(SourceFileSyntax.self) { return nil }
            current = node.parent
        }
        return nil
    }

    /// Binary operators whose base-less-`.case` operand takes its type from the OTHER operand:
    /// equality/pattern-match comparisons and nil-coalescing. Arithmetic/logical operators never
    /// take an enum-case shorthand, so they're excluded (no false context).
    static let contextGivingOperators: Set<String> = ["==", "!=", "~=", "??"]

    /// True when `node` is (transitively) contained in `ancestor`.
    static func isDescendant(_ node: Syntax, of ancestor: Syntax) -> Bool {
        var p: Syntax? = node
        while let cur = p {
            if cur.id == ancestor.id { return true }
            p = cur.parent
        }
        return false
    }

    /// Simple element-type NAME for contextual `.case` resolution: `E` → "E", `[E]` → "E",
    /// `E?` → "E", `[E]?` → "E". Returns nil for generic-argument identifiers, tuples, dictionaries,
    /// functions and anything else we don't model — fail closed (don't guess a contextual type).
    static func scalarElementType(of type: TypeSyntax) -> String? {
        if let id = type.as(IdentifierTypeSyntax.self) {
            return id.genericArgumentClause == nil ? id.name.text : nil
        }
        if let arr = type.as(ArrayTypeSyntax.self) {
            return scalarElementType(of: arr.element)
        }
        if let opt = type.as(OptionalTypeSyntax.self) {
            return scalarElementType(of: opt.wrappedType)
        }
        return nil
    }

    /// Delegate to shared TypeResolver, providing current scope context.
    private func resolveTypeSymbol(of expr: ExprSyntax) -> Symbol? {
        typeResolver.typeSymbol(of: expr, in: currentScope)
    }

    /// Convenience: type NAME for callers that still want a string (switch-case context, etc).
    private func resolveExpressionType(_ expr: ExprSyntax) -> String? {
        resolveTypeSymbol(of: expr)?.name
    }

    /// Best-effort: if the callee is a local function/method symbol we can look up its parameter
    /// types via SymbolTable.functionParamTypes. Returns the simple type name of the parameter
    /// at `argIndex` if known.
    private func resolveCalleeParamType(call: FunctionCallExprSyntax, argIndex: Int) -> String? {
        // Direct call: `funcName(...)` — calledExpression is DeclReferenceExpr.
        if let ref = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            let name = stripBackticks(ref.baseName.text)
            // Use full overload resolution (label + type aware) so we find the right overload
            // even when it's an extension / cross-module method not visible in the scope chain —
            // otherwise a shorthand `.case` argument can't learn its contextual enum type and is
            // left un-renamed while the enum case itself was renamed (`has no member` breakage).
            guard let sym = resolveCall(name: name, call: call) ?? currentScope.lookup(name: name) else {
                return nil
            }
            guard let types = table.functionParamTypes[sym.id], argIndex < types.count else { return nil }
            return types[argIndex]
        }
        // Method call: `obj.method(...)` — resolve the receiver's type, pick the called overload
        // by signature, and read its parameter type so a shorthand `.case` argument resolves too.
        if let m = call.calledExpression.as(MemberAccessExprSyntax.self), let receiver = m.base {
            let methodName = stripBackticks(m.declName.baseName.text)
            guard let recvType = resolveTypeSymbol(of: receiver),
                  let scope = innerScope(of: recvType) else { return nil }
            let cands = scope.members(named: methodName).filter { Self.isCallable($0.kind) }
            if let sym = (cands.count == 1 ? cands.first : chooseOverload(cands, call: call)),
               let types = table.functionParamTypes[sym.id], argIndex < types.count {
                return types[argIndex]
            }
            // Disambiguation failed but we only need the parameter TYPE: if every label-matching
            // candidate agrees on the type at argIndex, that's the answer regardless of which
            // overload the compiler picks. This rescues a `.case` argument to a protocol method that
            // has both a requirement and a same-signature default impl (two indistinguishable cands)
            // — otherwise the shorthand stays un-renamed while the case is obfuscated → desync.
            return agreedParamType(cands, call: call, argIndex: argIndex)
        }
        return nil
    }

    /// The parameter type at `argIndex` when ALL label-matching candidates agree on it (else nil).
    private func agreedParamType(_ candidates: [Symbol], call: FunctionCallExprSyntax, argIndex: Int) -> String? {
        let callLabels = Self.argumentLabels(of: call)
        let matching = candidates.filter { labelsMatch($0, callLabels, trailingStart: call.arguments.count) }
        guard !matching.isEmpty else { return nil }
        let types = matching.compactMap { sym -> String? in
            guard let t = table.functionParamTypes[sym.id], argIndex < t.count else { return nil }
            return t[argIndex]
        }
        guard types.count == matching.count, let first = types.first,
              types.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    // MARK: - Helpers

    /// Inner scope of a type symbol — automatically follows typealiases to the underlying type's
    /// scope. A typealias has no inner scope of its own; its "members" ARE the members of its
    /// underlying type, and every caller wanting `.member` access expects that semantics. Without
    /// this canonicalization, anywhere we did `innerScope(of: someTypeAlias)` got nil and skipped
    /// the member rename — the same desync bug appearing one site at a time across the codebase.
    private func innerScope(of typeSym: Symbol) -> Scope? {
        let canonical = typealiasUnwrap(typeSym)
        guard let parent = canonical.scope else { return nil }
        for child in parent.children where child.owner?.id == canonical.id {
            return child
        }
        return nil
    }

}

