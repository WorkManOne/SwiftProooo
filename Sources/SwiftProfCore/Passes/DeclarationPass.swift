import Foundation
import SwiftSyntax

public final class DeclarationPass {
    public let table: SymbolTable
    public let logger: Logger
    private var nextId = 0

    public init(table: SymbolTable, logger: Logger) {
        self.table = table
        self.logger = logger
    }

    public func run(on files: [SourceFile]) {
        for file in files {
            let visitor = DeclVisitor(file: file, table: table, mintId: { [unowned self] in
                defer { self.nextId += 1 }
                return self.nextId
            })
            let fileScope = Scope(kind: .file, parent: nil)
            visitor.scopeStack = [fileScope]
            visitor.walk(file.syntax)
            table.attach(fileScope: fileScope, forFileId: ObjectIdentifier(file))
        }
    }
}

private final class DeclVisitor: SyntaxVisitor {
    let file: SourceFile
    let table: SymbolTable
    let mintId: () -> Int
    var scopeStack: [Scope] = []

    init(file: SourceFile, table: SymbolTable, mintId: @escaping () -> Int) {
        self.file = file
        self.table = table
        self.mintId = mintId
        super.init(viewMode: .sourceAccurate)
    }

    static func stripBackticks(_ s: String) -> String {
        guard s.count >= 2, s.hasPrefix("`"), s.hasSuffix("`") else { return s }
        return String(s.dropFirst().dropLast())
    }

    /// Whether a declaration carries a given keyword modifier (e.g. `override`, `static`).
    static func hasModifier(_ modifiers: DeclModifierListSyntax, _ name: String) -> Bool {
        modifiers.contains { $0.name.text == name }
    }

    /// Whether a `var`/`let` binding is STORED (vs computed). A plain binding with no accessor block
    /// is stored; a `{ get … }` getter makes it computed; `didSet`/`willSet` observers keep it stored.
    /// Fail-closed: any binding we can't classify is treated as stored (so a Codable type never has a
    /// real serialization key mistaken for a renameable computed property).
    static func isStoredBinding(_ binding: PatternBindingSyntax) -> Bool {
        guard let accessor = binding.accessorBlock else { return true }
        switch accessor.accessors {
        case .getter:
            return false
        case .accessors(let list):
            for a in list {
                switch a.accessorSpecifier.tokenKind {
                case .keyword(.didSet), .keyword(.willSet): continue
                default: return false        // get / set / _read / _modify → computed
                }
            }
            return true
        }
    }

    /// Cheap textual representation of a declared type, used as a key into `declaredType` and
    /// parsed downstream (TypeInferencePass extracts element types for for-loop variables).
    /// - `Foo`              → "Foo"
    /// - `Foo?` / `Foo??`   → "Foo" (optionals are unwrapped)
    /// - `Array<Foo>`       → "Array<Foo>"
    /// - `[Foo]`            → "[Foo]"
    /// - tuples / functions / composition → nil (not modelled)
    static func simpleTypeName(_ type: TypeSyntax) -> String? {
        var t = type
        // Peel attribute (`@escaping (X)->Y`), `inout`, and opaque/existential wrappers
        // (`some P` / `any P`) so `r: some Renderer` types `r` as `Renderer` and its members
        // resolve. Repeated because they can nest (`inout some P`).
        var changed = true
        while changed {
            changed = false
            if let attr = t.as(AttributedTypeSyntax.self) { t = attr.baseType; changed = true }
            if let opaque = t.as(SomeOrAnyTypeSyntax.self) { t = opaque.constraint; changed = true }
            if let opt = t.as(OptionalTypeSyntax.self) { t = opt.wrappedType; changed = true }
        }
        if let ident = t.as(IdentifierTypeSyntax.self) {
            if ident.genericArgumentClause == nil { return ident.name.text }
            return ident.trimmedDescription
        }
        if let arr = t.as(ArrayTypeSyntax.self) {
            return "[\(arr.element.trimmedDescription)]"
        }
        // `[K: V]` — keep the dictionary form so a subscript on it (`dict[k]`) can extract the Value
        // type. Consumers that only understand arrays bail on the `:` (extractElement,
        // typeSymbol(forQualifiedName:)) — which is NOT automatically harmless: a consumer that
        // treats a nil entry as a WILDCARD reads this string as "a type I can't resolve" and flips
        // from "matches anything" to "matches nothing". That is exactly how witness linking broke
        // into a red build (B-FIX-27); signature comparison now decomposes the form structurally
        // (`TypeNameEquivalence.sameType`). Check nil semantics at EVERY consumer before widening
        // what this function returns.
        if let dict = t.as(DictionaryTypeSyntax.self) {
            return "[\(dict.key.trimmedDescription): \(dict.value.trimmedDescription)]"
        }
        // `Foo.Bar` — store full qualified text; TypeResolver walks dotted names.
        if let member = t.as(MemberTypeSyntax.self) {
            return member.trimmedDescription
        }
        return nil
    }

    private var currentScope: Scope { scopeStack.last! }

    private func push(_ kind: ScopeKind, owner: Symbol? = nil, node: some SyntaxProtocol) -> Scope {
        let s = Scope(kind: kind, parent: currentScope)
        s.owner = owner
        currentScope.add(child: s)
        scopeStack.append(s)
        table.attach(innerScope: s, forNode: node.id)
        return s
    }

    private func pop() {
        scopeStack.removeLast()
    }

    private func makeSymbol(name rawName: String, kind: SymbolKind, identifierToken: TokenSyntax) -> Symbol {
        let name = Self.stripBackticks(rawName)
        let position = identifierToken.positionAfterSkippingLeadingTrivia.utf8Offset
        let length = identifierToken.trimmedLength.utf8Length
        let sym = Symbol(
            id: mintId(),
            name: name,
            kind: kind,
            module: file.module,
            file: file,
            scope: currentScope,
            declOffset: position,
            declLength: length
        )
        currentScope.add(symbol: sym)
        table.register(sym)
        return sym
    }

    // MARK: - Type declarations

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        let sym = makeSymbol(name: node.name.text, kind: .class, identifierToken: node.name)
        let scope = push(.type, owner: sym, node: node)
        registerGenericParameters(node.genericParameterClause, into: scope)
        return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { pop() }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        let sym = makeSymbol(name: node.name.text, kind: .struct, identifierToken: node.name)
        let scope = push(.type, owner: sym, node: node)
        registerGenericParameters(node.genericParameterClause, into: scope)
        return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { pop() }

    /// An `actor` is a reference type — register it exactly like a class (kind `.class`) so all
    /// class machinery (member obfuscation, superclass/override linking, @objc inheritance) applies
    /// and external `await a.method()` use-sites resolve. Without this its members landed in FILE
    /// scope with the wrong kind → external calls reverted and members leaked as global candidates.
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        let sym = makeSymbol(name: node.name.text, kind: .class, identifierToken: node.name)
        let scope = push(.type, owner: sym, node: node)
        registerGenericParameters(node.genericParameterClause, into: scope)
        return .visitChildren
    }
    override func visitPost(_ node: ActorDeclSyntax) { pop() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        let sym = makeSymbol(name: node.name.text, kind: .enum, identifierToken: node.name)
        // Record raw type (`enum X: String`, `enum Y: Int`, etc.) so overload disambiguation can
        // type `x.rawValue` arguments later. Only basic raw types — anything else stays unknown.
        if let inh = node.inheritanceClause {
            for entry in inh.inheritedTypes {
                guard let ident = entry.type.as(IdentifierTypeSyntax.self) else { continue }
                let n = ident.name.text
                if Self.basicRawTypes.contains(n) {
                    table.enumRawType[sym.id] = n
                    break
                }
            }
        }
        let scope = push(.type, owner: sym, node: node)
        registerGenericParameters(node.genericParameterClause, into: scope)
        return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) { pop() }

    /// Basic Swift types valid as enum raw types. We don't track `enum: SomeCustomProtocol`
    /// (not a raw type anyway).
    private static let basicRawTypes: Set<String> = [
        "String", "Int", "Int8", "Int16", "Int32", "Int64",
        "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
        "Float", "Double", "Character"
    ]

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        let sym = makeSymbol(name: node.name.text, kind: .protocol, identifierToken: node.name)
        _ = push(.type, owner: sym, node: node)
        return .visitChildren
    }
    override func visitPost(_ node: ProtocolDeclSyntax) { pop() }

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        let sym = makeSymbol(name: node.name.text, kind: .typealias_, identifierToken: node.name)
        if let t = Self.simpleTypeName(node.initializer.value) {
            table.typealiasTarget[sym.id] = t
        }
        return .visitChildren
    }

    override func visit(_ node: AssociatedTypeDeclSyntax) -> SyntaxVisitorContinueKind {
        _ = makeSymbol(name: node.name.text, kind: .associatedtype_, identifierToken: node.name)
        return .visitChildren
    }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        // Extension contributes its members into a type scope tied (semantically) to the extended
        // type. Owner is NOT resolved here: at this point the table is only partially populated
        // (the type may be declared later) and a `.first` pick over same-named types is
        // registration-order-dependent — it can cross-wire to a foreign module's same-named type
        // and make unrelated nested members visible inside the extension. Defer to
        // ExtensionOwnerResolver, which resolves module-aware against the full table.
        let scope = push(.type, owner: nil, node: node)
        let inheritedNames = node.inheritanceClause?.inheritedTypes.map { $0.type.trimmedDescription } ?? []
        table.registerExtension(scope: scope, extendedType: node.extendedType, file: file,
                                inheritedNames: inheritedNames,
                                elementConstraint: Self.elementConstraint(of: node.genericWhereClause))
        return .visitChildren
    }

    /// Right-hand side of an `Element == X` same-type requirement (`extension Array where Element ==
    /// Mood`). This is what distinguishes two same-named members declared on `[Mood]` and `[String]`
    /// at a use-site, so an extension on an external collection can be renamed at all (B-FIX-31).
    /// Any other requirement shape (a conformance bound, `Self.Element`, several requirements we
    /// can't reduce to one element) yields nil — the extension then applies to every element type.
    private static func elementConstraint(of clause: GenericWhereClauseSyntax?) -> String? {
        guard let clause else { return nil }
        for requirement in clause.requirements {
            guard let sameType = requirement.requirement.as(SameTypeRequirementSyntax.self) else { continue }
            let lhs = sameType.leftType.trimmedDescription
            guard lhs == "Element" || lhs == "Self.Element" else { continue }
            let rhs = sameType.rightType.trimmedDescription
            return rhs.isEmpty ? nil : rhs
        }
        return nil
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { pop() }

    // MARK: - Closures (block scope)

    /// A closure introduces its own lexical scope. Locals declared inside it (`let x = ...`)
    /// must NOT collide with same-named declarations of the enclosing type/function — they
    /// shadow them. Pushing a `.block` scope keeps these locals nested so resolution finds the
    /// innermost binding first. (e.g. `var p1: URL = { let p1 = ...; return p1 }()` — the
    /// `return p1` refers to the local, not the property.)
    /// The closure's own parameters (`{ item in … }` / `{ (w: Widget) in … }`) are registered as
    /// non-renameable locals: a body reference must resolve to the PARAMETER, never to a
    /// same-named property of the enclosing type (which would rewrite the use to the property's
    /// obf — a silent wrong-storage read, or a red build when the name is Apple-shielded).
    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        _ = push(.block, owner: nil, node: node)
        if let clause = node.signature?.parameterClause {
            switch clause {
            case .parameterClause(let params):
                for p in params.parameters {
                    registerLocalBinding(p.secondName ?? p.firstName, type: p.type)
                }
            case .simpleInput(let shorthand):
                for p in shorthand {
                    registerLocalBinding(p.name)
                }
            }
        }
        return .visitChildren
    }
    override func visitPost(_ node: ClosureExprSyntax) { pop() }

    // MARK: - Binding patterns (switch case-let / catch / tuples / if-case)

    /// Register a name-introducing local binding as a NON-renameable `.parameter` symbol (the
    /// subscript-parameter precedent): it is never renamed itself (not in `renameableParameters`),
    /// but its presence makes body references resolve to it instead of a same-named outer
    /// property/global. Skips `_` and `self`.
    private func registerLocalBinding(_ token: TokenSyntax, type: TypeSyntax? = nil) {
        registerLocalBinding(name: token.text, at: token, type: type)
    }

    private func registerLocalBinding(name rawName: String, at token: TokenSyntax, type: TypeSyntax? = nil) {
        let name = Self.stripBackticks(rawName)
        guard name != "_", name != "self" else { return }
        let sym = Symbol(
            id: mintId(), name: name, kind: .parameter,
            module: file.module, file: file, scope: currentScope,
            declOffset: token.positionAfterSkippingLeadingTrivia.utf8Offset,
            declLength: token.trimmedLength.utf8Length
        )
        currentScope.add(symbol: sym)
        table.register(sym)
        if let type, let t = Self.simpleTypeName(type) {
            table.declaredType[sym.id] = t
        }
    }

    /// A `switch` case body is a lexical scope of its own: `case .foo(let value):` bindings are
    /// visible only inside that case. Push a `.block` scope (mirrored by ResolutionPass) and
    /// register the case items' bindings into it.
    override func visit(_ node: SwitchCaseSyntax) -> SyntaxVisitorContinueKind {
        _ = push(.block, owner: nil, node: node)
        if let label = node.label.as(SwitchCaseLabelSyntax.self) {
            for item in label.caseItems {
                registerCaseItemPattern(item.pattern)
            }
        }
        return .visitChildren
    }
    override func visitPost(_ node: SwitchCaseSyntax) { pop() }

    /// `catch let e` / `catch Boom.bad(let x)` / bare `catch` (implicit `error`). The clause body
    /// is a scope; bindings (or the implicit `error`) are visible only inside it.
    override func visit(_ node: CatchClauseSyntax) -> SyntaxVisitorContinueKind {
        _ = push(.block, owner: nil, node: node)
        if node.catchItems.isEmpty {
            // Bare `catch` introduces the implicit `error` local. There is no identifier token to
            // anchor to — use the `catch` keyword position (the symbol is never a rename target;
            // offsets only feed reports).
            registerLocalBinding(name: "error", at: node.catchKeyword)
        } else {
            for item in node.catchItems {
                if let pattern = item.pattern { registerCaseItemPattern(pattern) }
            }
        }
        return .visitChildren
    }
    override func visitPost(_ node: CatchClauseSyntax) { pop() }

    /// `if case .foo(let x) = y` / `guard case` / `while case` — bindings are registered into the
    /// CURRENT scope (no dedicated scope node). Over-broad for `guard case`'s else-body (where the
    /// binding is not yet in scope) — a same-named property ref there resolves to the binding and
    /// stays un-renamed → RollbackPass reverts the property (safe under-obf, never a wrong rename).
    override func visit(_ node: MatchingPatternConditionSyntax) -> SyntaxVisitorContinueKind {
        registerCaseItemPattern(node.pattern)
        return .visitChildren
    }

    /// Pattern in a DECLARATION position (`let (a, b) = …`, `for (k, v) in …`) — every identifier
    /// binds a new local.
    private func registerDeclarationPattern(_ pattern: PatternSyntax) {
        if let ident = pattern.as(IdentifierPatternSyntax.self) {
            registerLocalBinding(ident.identifier)
        } else if let tuple = pattern.as(TuplePatternSyntax.self) {
            for el in tuple.elements { registerDeclarationPattern(el.pattern) }
        } else if let vb = pattern.as(ValueBindingPatternSyntax.self) {
            registerBindingSubpattern(vb.pattern)
        } else if let expr = pattern.as(ExpressionPatternSyntax.self) {
            // Declaration positions bind bare refs too (parser may produce ExpressionPattern for
            // tuple elements).
            registerBindingRefs(in: expr.expression)
        }
        // Wildcard / is-type / missing — nothing to bind.
    }

    /// Pattern in a MATCHING position (switch case item, catch item, if/guard/while-case). Only
    /// `let`/`var` subtrees bind; a bare identifier/expression matches an EXISTING value.
    private func registerCaseItemPattern(_ pattern: PatternSyntax) {
        if let vb = pattern.as(ValueBindingPatternSyntax.self) {
            registerBindingSubpattern(vb.pattern)
        } else if let expr = pattern.as(ExpressionPatternSyntax.self) {
            // `.foo(let x)` — the bindings are PatternExprs nested inside the expression.
            registerNestedBindings(in: expr.expression)
        } else if let tuple = pattern.as(TuplePatternSyntax.self) {
            for el in tuple.elements { registerCaseItemPattern(el.pattern) }
        }
        // (`case let x?` parses the `x?` as an ExpressionPattern — covered above.)
    }

    /// Everything under a `let`/`var` binds: `let x`, `let (a, b)`, `let x?`, `let .foo(a, b)`
    /// (bare refs inside the expression are the bindings).
    private func registerBindingSubpattern(_ pattern: PatternSyntax) {
        if let ident = pattern.as(IdentifierPatternSyntax.self) {
            registerLocalBinding(ident.identifier)
        } else if let tuple = pattern.as(TuplePatternSyntax.self) {
            for el in tuple.elements { registerBindingSubpattern(el.pattern) }
        } else if let expr = pattern.as(ExpressionPatternSyntax.self) {
            registerBindingRefs(in: expr.expression)
        } else if let vb = pattern.as(ValueBindingPatternSyntax.self) {
            registerBindingSubpattern(vb.pattern)
        }
    }

    /// Under a `let`/`var`, `case let .foo(a, b)` binds `a`/`b`. Depending on the exact source
    /// shape the parser represents them either as nested `PatternExprSyntax` (→ IdentifierPattern)
    /// or as bare `DeclReferenceExpr`s inside the call expression. Collect BOTH.
    private func registerBindingRefs(in expr: ExprSyntax) {
        let collector = BindingRefCollector()
        collector.walk(expr)
        for token in collector.found { registerLocalBinding(token) }
        // These PatternExprs sit UNDER a `let`/`var`, so a bare identifier inside them IS a binding
        // (unlike a top-level matching position) — route through the binding path.
        for pat in collector.foundPatterns { registerBindingSubpattern(pat) }
    }

    /// `.foo(let x)` — walk the expression for nested PatternExprs and register their bindings.
    private func registerNestedBindings(in expr: ExprSyntax) {
        let collector = NestedPatternCollector()
        collector.walk(expr)
        for pat in collector.found { registerCaseItemPattern(pat) }
    }

    // MARK: - Function-like declarations

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let kind: SymbolKind = currentScope.kind == .type ? .method : .function
        let sym = makeSymbol(name: node.name.text, kind: kind, identifierToken: node.name)
        if Self.hasModifier(node.modifiers, "override") { table.overrideMemberIds.insert(sym.id) }
        if let ret = node.signature.returnClause, let t = Self.simpleTypeName(ret.type) {
            table.functionReturnType[sym.id] = t
        }
        let funcScope = push(.function, owner: sym, node: node)
        registerGenericParameters(node.genericParameterClause, into: funcScope)
        registerParameters(node.signature.parameterClause.parameters, in: funcScope, funcId: sym.id)
        return .visitChildren
    }
    override func visitPost(_ node: FunctionDeclSyntax) { pop() }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        // Record a PRIMARY-declaration init on a struct (owner != nil ⇒ NOT an extension, whose
        // scope owner is nil until ExtensionOwnerResolver). This is what actually suppresses the
        // memberwise init — an extension init does NOT, so it must not count here.
        if let owner = currentScope.owner, owner.kind == .struct, currentScope.kind == .type {
            table.structsWithMainDeclInit.insert(owner.id)
        }
        let sym = Symbol(
            id: mintId(), name: "init", kind: .initializer,
            module: file.module, file: file, scope: currentScope,
            declOffset: node.initKeyword.positionAfterSkippingLeadingTrivia.utf8Offset,
            declLength: node.initKeyword.trimmedLength.utf8Length
        )
        currentScope.add(symbol: sym)
        table.register(sym)
        let funcScope = push(.function, owner: sym, node: node)
        registerParameters(node.signature.parameterClause.parameters, in: funcScope, funcId: sym.id)
        return .visitChildren
    }
    override func visitPost(_ node: InitializerDeclSyntax) { pop() }

    /// `subscript(params) -> T { ... }` — push a function scope and register its parameters as
    /// locals so a bare reference to a subscript parameter in the body resolves to the PARAMETER,
    /// not to a same-named property of the enclosing type (which would wrongly rewrite the use to
    /// the property's obf — a silent semantic change, RollbackPass can't catch it). The subscript
    /// itself is never a rename target (use-sites are `x[i]` syntax, not a name); its parameters are
    /// registered but NOT added to `renameableParameters`, so the Planner skips them (never renamed).
    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        let scope = push(.function, owner: nil, node: node)
        for param in node.parameterClause.parameters {
            let internalToken = param.secondName ?? param.firstName
            let name = Self.stripBackticks(internalToken.text)
            guard name != "_" else { continue }
            let sym = Symbol(
                id: mintId(), name: name, kind: .parameter,
                module: file.module, file: file, scope: scope,
                declOffset: internalToken.positionAfterSkippingLeadingTrivia.utf8Offset,
                declLength: internalToken.trimmedLength.utf8Length
            )
            scope.add(symbol: sym)
            table.register(sym)
            if let t = Self.simpleTypeName(param.type) {
                table.declaredType[sym.id] = t
            }
        }
        // Record the subscript's signature (external labels + declared return type) against the
        // enclosing type/extension scope, so `base[args]` on a LOCAL type can resolve to the exact
        // declared return type. Subscript label rule differs from functions: a plain `subscript(i:)`
        // is called `x[5]` with NO label — a label exists ONLY when there's a distinct external name
        // (`subscript(safe i:)` → `x[safe: 5]`), i.e. when `secondName` is present.
        if let enclosing = scope.parent, let ret = Self.simpleTypeName(node.returnClause.type) {
            let labels: [String] = node.parameterClause.parameters.map { param in
                param.secondName != nil ? Self.stripBackticks(param.firstName.text) : "_"
            }
            table.registerSubscript(enclosingScope: enclosing, labels: labels, returnType: ret)
        }
        return .visitChildren
    }
    override func visitPost(_ node: SubscriptDeclSyntax) { pop() }

    /// Closure/function-type parameter input type names: `(X, Y) -> R` → ["X","Y"]. Unwraps
    /// `@escaping`/attributes, optionals, and a single-element paren wrapper (`((X) -> Y)?`).
    /// Returns nil when the parameter isn't a function type (B-FIX-2).
    static func closureInputTypeNames(of type: TypeSyntax) -> [String]? {
        var t = type
        if let attr = t.as(AttributedTypeSyntax.self) { t = attr.baseType }
        while let opt = t.as(OptionalTypeSyntax.self) { t = opt.wrappedType }
        if let tup = t.as(TupleTypeSyntax.self), tup.elements.count == 1 {
            t = tup.elements.first!.type
        }
        if let attr = t.as(AttributedTypeSyntax.self) { t = attr.baseType }
        guard let fn = t.as(FunctionTypeSyntax.self) else { return nil }
        return fn.parameters.map { Self.simpleTypeName($0.type) ?? "" }
    }

    /// Register generic parameters (`<T: P, U>`) as NON-renameable `.typealias_` placeholders in
    /// `scope`. Target = the constraint's bare type name so member access through the placeholder
    /// (`r: T` → `r.render()`) resolves via the constraint protocol. Recorded in
    /// `genericParameterIds` so the Planner never renames them (a generic param is a local
    /// placeholder, and it also shadows any same-named global type inside the decl).
    private func registerGenericParameters(_ clause: GenericParameterClauseSyntax?, into scope: Scope) {
        guard let clause else { return }
        for p in clause.parameters {
            let token = p.name
            let name = Self.stripBackticks(token.text)
            guard name != "_" else { continue }
            let sym = Symbol(
                id: mintId(), name: name, kind: .typealias_,
                module: file.module, file: file, scope: scope,
                declOffset: token.positionAfterSkippingLeadingTrivia.utf8Offset,
                declLength: token.trimmedLength.utf8Length
            )
            scope.add(symbol: sym)
            table.register(sym)
            table.genericParameterIds.insert(sym.id)
            if let inherited = p.inheritedType, let t = Self.simpleTypeName(inherited) {
                table.typealiasTarget[sym.id] = t
            }
        }
    }

    private func registerParameters(_ params: FunctionParameterListSyntax, in scope: Scope, funcId: Int) {
        var paramTypes: [String?] = []
        var paramLabels: [String] = []
        var paramHasDefault: [Bool] = []
        var closureInputs: [Int: [String]] = [:]
        for (paramIndex, param) in params.enumerated() {
            paramTypes.append(Self.simpleTypeName(param.type))
            paramHasDefault.append(param.defaultValue != nil)
            if let inputs = Self.closureInputTypeNames(of: param.type) {
                closureInputs[paramIndex] = inputs
            }
            // External label is `firstName` ("_" when there's no call-site label, or the
            // declared label otherwise). Used for overload resolution by argument labels.
            paramLabels.append(Self.stripBackticks(param.firstName.text))
            // Internal name (used inside body) is `secondName` if present, else `firstName`.
            let internalToken = param.secondName ?? param.firstName
            let name = internalToken.text
            guard name != "_" else { continue }
            let sym = Symbol(
                id: mintId(), name: Self.stripBackticks(name), kind: .parameter,
                module: file.module, file: file, scope: scope,
                declOffset: internalToken.positionAfterSkippingLeadingTrivia.utf8Offset,
                declLength: internalToken.trimmedLength.utf8Length
            )
            scope.add(symbol: sym)
            table.register(sym)
            if let t = Self.simpleTypeName(param.type) {
                table.declaredType[sym.id] = t
            }
            // The internal name is safely renameable iff the parameter has a DISTINCT external
            // label. Forms `func f(_ x:)` and `func f(label x:)` have secondName set — renaming
            // `x` doesn't touch the call-site signature. Form `func f(x:)` has secondName=nil —
            // renaming `x` would change `f(x:)` to `f(p0:)` and break callers.
            if param.secondName != nil {
                table.renameableParameters.insert(sym.id)
            }
        }
        table.functionParamTypes[funcId] = paramTypes
        table.functionParamLabels[funcId] = paramLabels
        table.functionParamHasDefault[funcId] = paramHasDefault
        if !closureInputs.isEmpty { table.functionParamClosureInput[funcId] = closureInputs }
    }

    // MARK: - Variable / property bindings

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        let kind: SymbolKind = .property
        let isOverride = Self.hasModifier(node.modifiers, "override")
        // `static`/`class` (TYPE) properties are never part of Codable: the compiler synthesizes
        // CodingKeys from INSTANCE stored properties only, so a static stored property is not a
        // serialization key and stays renameable. Keep it OUT of storedPropertyIds (whose sole
        // consumer is runCodableProtection). Was over-protecting `static let` on Codable types.
        let isStatic = Self.hasModifier(node.modifiers, "static") || Self.hasModifier(node.modifiers, "class")
        for binding in node.bindings {
            // Tuple destructuring (`let (a, b) = …`) — register each element as a non-renameable
            // local binding so body references shadow same-named properties correctly. (Renaming
            // them is a possible future coverage lever; shadow correctness is the load-bearing part.)
            if binding.pattern.is(TuplePatternSyntax.self) {
                registerDeclarationPattern(binding.pattern)
                continue
            }
            if let ident = binding.pattern.as(IdentifierPatternSyntax.self) {
                let sym = makeSymbol(name: ident.identifier.text, kind: kind, identifierToken: ident.identifier)
                if isOverride { table.overrideMemberIds.insert(sym.id) }
                if !isStatic, Self.isStoredBinding(binding) { table.storedPropertyIds.insert(sym.id) }
                if let annotation = binding.typeAnnotation,
                   let typeName = Self.simpleTypeName(annotation.type) {
                    table.declaredType[sym.id] = typeName
                } else if let init_ = binding.initializer {
                    // Try the cheap initializer-call shortcut first; otherwise defer to TypeInferencePass.
                    if let typeName = Self.inferTypeFromInitializer(init_.value) {
                        table.declaredType[sym.id] = typeName
                    } else {
                        table.initializerExpr[sym.id] = init_.value
                    }
                }
            }
        }
        return .visitChildren
    }

    /// `for x in seq { ... }` — register `x` as a local symbol and remember `seq` so that
    /// TypeInferencePass can deduce x's type from seq's element type later. Tuple patterns
    /// (`for (k, v) in dict`) and `for case`-patterns register their bindings too (untyped,
    /// shadow-correctness only).
    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind {
        if let ident = node.pattern.as(IdentifierPatternSyntax.self) {
            let token = ident.identifier
            let name = token.text
            if name != "_" {
                let sym = Symbol(
                    id: mintId(), name: Self.stripBackticks(name), kind: .parameter,
                    module: file.module, file: file, scope: currentScope,
                    declOffset: token.positionAfterSkippingLeadingTrivia.utf8Offset,
                    declLength: token.trimmedLength.utf8Length
                )
                currentScope.add(symbol: sym)
                table.register(sym)
                table.forLoopSequence[sym.id] = node.sequence
            }
        } else if node.caseKeyword != nil {
            registerCaseItemPattern(node.pattern)
        } else {
            registerDeclarationPattern(node.pattern)
        }
        return .visitChildren
    }

    /// Cheap initializer-based type inference. Handles `let x = Foo()` and `let x = Foo.init()`.
    /// Returns the type name when we can recover it cheaply; nil otherwise.
    static func inferTypeFromInitializer(_ expr: ExprSyntax) -> String? {
        // `Foo(...)` — calledExpression is DeclReferenceExpr matching a type name.
        if let call = expr.as(FunctionCallExprSyntax.self) {
            if let callee = call.calledExpression.as(DeclReferenceExprSyntax.self) {
                let name = stripBackticks(callee.baseName.text)
                // Heuristic: types start with uppercase. Avoids matching `print()` etc.
                if let first = name.first, first.isUppercase {
                    return name
                }
            }
            // `Foo.init(...)`
            if let member = call.calledExpression.as(MemberAccessExprSyntax.self),
               member.declName.baseName.text == "init",
               let base = member.base?.as(DeclReferenceExprSyntax.self) {
                let name = stripBackticks(base.baseName.text)
                if let first = name.first, first.isUppercase { return name }
            }
        }
        return nil
    }

    // MARK: - Enum cases

    override func visit(_ node: EnumCaseDeclSyntax) -> SyntaxVisitorContinueKind {
        for element in node.elements {
            let sym = makeSymbol(name: element.name.text, kind: .enumCase, identifierToken: element.name)
            // A case WITH associated values is CALLED like a function (`Command.run(.calm)`), so its
            // payload types play the role of `functionParamTypes` for that call — they are what lets
            // a shorthand payload argument learn its contextual enum.
            if let params = element.parameterClause?.parameters {
                table.enumCaseAssociatedTypes[sym.id] = params.map { Self.simpleTypeName($0.type) }
            }
        }
        return .visitChildren
    }

}

/// Collects BINDINGS inside a `case let .foo(a, b)` expression pattern: nested
/// `PatternExprSyntax` (the sub-pattern form) plus bare `DeclReferenceExpr`s that are neither a
/// member name (`.foo`) nor a callee.
private final class BindingRefCollector: SyntaxVisitor {
    var found: [TokenSyntax] = []
    var foundPatterns: [PatternSyntax] = []
    init() { super.init(viewMode: .sourceAccurate) }
    override func visit(_ node: PatternExprSyntax) -> SyntaxVisitorContinueKind {
        foundPatterns.append(node.pattern)
        return .skipChildren
    }
    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        if let member = node.parent?.as(MemberAccessExprSyntax.self),
           member.declName.id == node.id {
            return .skipChildren   // `.foo` — the case name, not a binding
        }
        if let call = node.parent?.as(FunctionCallExprSyntax.self),
           call.calledExpression.id == Syntax(node).id {
            return .skipChildren   // callee — not a binding
        }
        found.append(node.baseName)
        return .skipChildren
    }
}

/// Collects nested PatternExprs (`.foo(let x)` — the `let x` inside the expression).
private final class NestedPatternCollector: SyntaxVisitor {
    var found: [PatternSyntax] = []
    init() { super.init(viewMode: .sourceAccurate) }
    override func visit(_ node: PatternExprSyntax) -> SyntaxVisitorContinueKind {
        found.append(node.pattern)
        return .skipChildren
    }
}
