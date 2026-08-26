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

    private var currentScope: Scope { scopeStack.last! }

    private func push(_ kind: ScopeKind, owner: Symbol? = nil, node: some SyntaxProtocol) -> Scope {
        // Every scope node must be listed in `ScopeNodes.kinds`, whose doc names the passes that
        // mirror this tree — a mirror missing a kind resolves use-sites under it to outer symbols.
        assert(ScopeNodes.kinds.contains(node.kind),
               "scope attached to \(node.kind), which is not in ScopeNodes.kinds; mirrors will drift")
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
        if let t = WrittenTypeName.of(node.initializer.value) {
            table.typealiasTarget[sym.id] = t
        }
        // A typealias to a FUNCTION type (`typealias Handler = (En1) -> Void`) carries closure inputs
        // that `WrittenTypeName.of` cannot express (it returns nil for function types), so record them
        // here so a `func f(_ h: Handler)` parameter can still type its closure argument (B-FIX-55).
        if let inputs = Self.closureInputTypeNames(of: node.initializer.value) {
            table.typealiasClosureInput[sym.id] = inputs
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

    // MARK: - Braced blocks (block scope)

    /// A braced block is a lexical scope of its own, and a local declared in it is visible only
    /// inside it. This covers every statement body (`if` / `else` / `for` / `while` / `repeat` /
    /// `do` / `guard`'s else), accessor bodies, and — the load-bearing one — a function's OWN body,
    /// whose parent is the function scope holding the PARAMETERS.
    ///
    /// Without it every local of a method landed in one flat function scope, where
    /// `Scope.lookup(name:)` answers with the first declaration in SOURCE order. Two consequences,
    /// both wrong renames that RollbackPass cannot see (no original name survives):
    /// `func f(for slot: Mode) { let slot: Detail = …; slot.tag }` resolved `slot` to the PARAMETER
    /// (declared first), and two sibling `if` bodies each declaring `parts` collapsed onto the first
    /// one, so the second block's use was rewritten to a name declared in the other block.
    ///
    /// The block is only HALF the answer: within it a local is visible from its DECLARATION onward,
    /// not from the opening brace, so a reference above it reads the outer parameter/property
    /// (B-FIX-40). That half lives in `Scope.lookup(name:at:)`, which is why the scope tree may stay
    /// order-blind here.
    override func visit(_ node: CodeBlockSyntax) -> SyntaxVisitorContinueKind {
        _ = push(.block, owner: nil, node: node)
        registerAccessorValueBinding(bodyOf: node)
        return .visitChildren
    }
    override func visitPost(_ node: CodeBlockSyntax) { pop() }

    /// The body of an IMPLICIT getter (`var x: T { … }`, `subscript(i: Int) -> T { … }`) — the one
    /// braced body in the language that is not a `CodeBlockSyntax`. Its statements hang off the
    /// `AccessorBlock` directly (`Accessors.getter`), so the block scope above never fired for it and
    /// its locals were registered into the ENCLOSING scope (B-FIX-49).
    ///
    /// Where they landed decided the symptom, and none of the three was caught by a safety net:
    /// in a TYPE scope (the common case) the position rule of B-FIX-40 does not apply, so two
    /// sibling computed properties' same-named locals collapsed onto the first-declared one and a
    /// getter's local lost to a same-named stored PROPERTY; in a `.function`/`.block` scope the
    /// local merely leaked past the property, over a sibling local below it or the subscript's own
    /// parameter.
    ///
    /// Pushed only for the `.getter` form: an explicit `get`/`set` accessor has a `CodeBlockSyntax`
    /// body that already carries the scope, and pushing here as well would add an empty level for
    /// every computed property in the project. The two mirrors named in `ScopeNodes` key on
    /// `innerScope[node.id]`, so they follow this condition without repeating it.
    override func visit(_ node: AccessorBlockSyntax) -> SyntaxVisitorContinueKind {
        if case .getter = node.accessors { _ = push(.block, owner: nil, node: node) }
        return .visitChildren
    }
    override func visitPost(_ node: AccessorBlockSyntax) {
        if case .getter = node.accessors { pop() }
    }

    /// An accessor's implicit value parameter: `set`/`willSet` (and an `init` accessor) bind
    /// `newValue`, `didSet` binds `oldValue`, and an explicit name in parentheses (`set(incoming)`,
    /// `didSet(previous)`) REPLACES the implicit one. Same rule and same precedent as the implicit
    /// `error` of a bare `catch` — register a non-renameable `.parameter` so a body reference
    /// resolves to the BINDING, never to a same-named property of the enclosing type (B-FIX-41).
    ///
    /// Registered into the accessor BODY's scope, which we have just pushed — the binding must not be
    /// visible outside the braces, and an accessor body is always a `CodeBlockSyntax`, so no new scope
    /// node (and no `ScopeNodes.kinds` / mirror edit) is needed. The anchor is the accessor keyword
    /// (or the explicit name token), both of which precede the body, so `Scope.lookup(name:at:)`'s
    /// position rule (B-FIX-40) sees the binding as visible throughout it.
    ///
    /// Only ONE name is bound per accessor: `oldValue` is not in scope in a `willSet`, nor `newValue`
    /// in a `didSet`, so a same-named property reference there must still follow the property's rename.
    private func registerAccessorValueBinding(bodyOf block: CodeBlockSyntax) {
        guard let accessor = block.parent?.as(AccessorDeclSyntax.self), accessor.body == block else { return }
        let type = Self.accessorValueType(of: accessor)
        // When the owning property's type is INFERRED (no written annotation, so `type == nil`), link
        // the binding to the owner property; TypeInferencePass transfers the resolved type once the
        // initializer is typed (B3). A written accessor type is carried directly and needs no link.
        let ownerId = type == nil ? ownerPropertyId(of: accessor) : nil
        if let explicit = accessor.parameters?.name {
            registerLocalBinding(explicit, type: type)
        } else {
            let implicit: String
            switch accessor.accessorSpecifier.text {
            case "set", "willSet", "init": implicit = "newValue"
            case "didSet": implicit = "oldValue"
            default: return                  // get / _read / _modify introduce no value parameter
            }
            registerLocalBinding(name: implicit, at: accessor.accessorSpecifier, type: type)
        }
        if let ownerId, let bindingSym = currentScope.symbols.last {
            table.accessorBindingOwner[bindingSym.id] = ownerId
        }
    }

    /// The id of the property symbol whose accessor this is — matched by the property identifier's
    /// offset in an enclosing scope (the property was registered by `visit(VariableDeclSyntax)` before
    /// the accessor body was descended into). Used only to transfer an INFERRED property type to the
    /// accessor's value binding (B3); a subscript accessor always has a written return type, so it
    /// never reaches here.
    private func ownerPropertyId(of accessor: AccessorDeclSyntax) -> Int? {
        guard let owner = accessor.parent?.parent?.as(AccessorBlockSyntax.self)?.parent,
              let binding = owner.as(PatternBindingSyntax.self),
              let ident = binding.pattern.as(IdentifierPatternSyntax.self) else { return nil }
        let offset = ident.identifier.positionAfterSkippingLeadingTrivia.utf8Offset
        var scope: Scope? = currentScope
        while let s = scope {
            if let sym = s.symbols.first(where: { $0.kind == .property && $0.declOffset == offset }) {
                return sym.id
            }
            scope = s.parent
        }
        return nil
    }

    /// The accessor value's type: the WRITTEN annotation of the property it accesses (`var row: Row
    /// { set { … } }`) or a subscript's written return type. Ground truth only — an inferred
    /// property type (`var row = makeRow() { didSet { … } }`) is not known at declaration time, and
    /// guessing one would drive a wrong rename, so it stays nil (the binding is then merely
    /// untyped, exactly as every unregistered name is today).
    ///
    /// Without it the fix would COST a rename in the reported shape: with a property `var newValue:
    /// Row` in scope, `set { … newValue.rowTag … }` used to type the receiver from that property and
    /// rewrite `rowTag` — wrongly, but it did rewrite it. Now the binding wins the lookup, so it has
    /// to carry the type too or the member read stays original while its declaration renames.
    private static func accessorValueType(of accessor: AccessorDeclSyntax) -> TypeSyntax? {
        // AccessorDecl → AccessorDeclList → AccessorBlock → PatternBinding / SubscriptDecl.
        guard let owner = accessor.parent?.parent?.as(AccessorBlockSyntax.self)?.parent else { return nil }
        if let binding = owner.as(PatternBindingSyntax.self) { return binding.typeAnnotation?.type }
        if let sub = owner.as(SubscriptDeclSyntax.self) { return sub.returnClause.type }
        return nil
    }

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
    /// `visibleIn` is the REGION the binding is visible in, set only for an `if`/`while`/`guard
    /// case` CONDITION binding, which is registered into the ENCLOSING scope and so needs one
    /// (`ConditionBindingExtent`, B-FIX-42): an `if`/`while` binding dies with its statement's body,
    /// a `guard`'s outlives the statement but is absent from its own `else`. Carrying it also marks
    /// the symbol as lexically nested in that scope, which is what lets it SHADOW a same-named
    /// declaration of the scope itself (B-FIX-43). Every other binding is visible to the end of the
    /// scope it is registered in, and passes nil.
    private func registerLocalBinding(_ token: TokenSyntax, type: TypeSyntax? = nil,
                                      visibleIn: ConditionBindingExtent.Visibility? = nil) {
        registerLocalBinding(name: token.text, at: token, type: type, visibleIn: visibleIn)
    }

    private func registerLocalBinding(name rawName: String, at token: TokenSyntax,
                                      type: TypeSyntax? = nil, visibleIn: ConditionBindingExtent.Visibility? = nil) {
        let name = Self.stripBackticks(rawName)
        guard name != "_", name != "self" else { return }
        let sym = Symbol(
            id: mintId(), name: name, kind: .parameter,
            module: file.module, file: file, scope: currentScope,
            declOffset: token.positionAfterSkippingLeadingTrivia.utf8Offset,
            declLength: token.trimmedLength.utf8Length,
            conditionBinding: visibleIn
        )
        currentScope.add(symbol: sym)
        table.register(sym)
        if let type, let t = WrittenTypeName.of(type) {
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
    /// CURRENT scope, with a visibility REGION instead of a dedicated scope node (B-FIX-42): for
    /// `if`/`while` the binding dies with the statement's BODY, so it is invisible in the `else` and
    /// below the statement, while a LATER CONDITION of the same list still sees it (all three
    /// checked against swiftc). A region expresses that exactly; a scope node could not, because the
    /// `else` body is a child of the same statement.
    ///
    /// `guard case` is the shape the region (rather than a bare end) is for: its binding really is
    /// in scope after the statement, and absent only from the guard's OWN else body — a hole in the
    /// middle. The payload TYPE half applies the SAME region since B-FIX-50; it used to be withheld
    /// from the else body by being recorded after that body was visited, which cost it the later
    /// conditions of the guard's own list.
    ///
    /// Landing in the enclosing scope means the binding can sit next to a same-named declaration of
    /// that scope, which it SHADOWS wherever it is visible — the ordering half of the same rule,
    /// in `Scope.declarations(named:visibleAt:)` (B-FIX-43).
    override func visit(_ node: MatchingPatternConditionSyntax) -> SyntaxVisitorContinueKind {
        registerCaseItemPattern(node.pattern, visibleIn: ConditionBindingExtent.visibility(of: node))
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
    ///
    /// `visibleIn` rides all the way down to `registerLocalBinding` because a single condition
    /// pattern can bind several names at any nesting depth (`case .pair(let a, let b)`,
    /// `case let .pair((a, b))`) and they ALL end with the same statement. Threading it explicitly
    /// rather than parking it in a field keeps that visible at every hop — the switch/catch callers
    /// pass nothing and keep the scope-wide default.
    private func registerCaseItemPattern(_ pattern: PatternSyntax, visibleIn: ConditionBindingExtent.Visibility? = nil) {
        if let vb = pattern.as(ValueBindingPatternSyntax.self) {
            registerBindingSubpattern(vb.pattern, visibleIn: visibleIn)
        } else if let expr = pattern.as(ExpressionPatternSyntax.self) {
            // `.foo(let x)` — the bindings are PatternExprs nested inside the expression.
            registerNestedBindings(in: expr.expression, visibleIn: visibleIn)
        } else if let tuple = pattern.as(TuplePatternSyntax.self) {
            for el in tuple.elements { registerCaseItemPattern(el.pattern, visibleIn: visibleIn) }
        }
        // (`case let x?` parses the `x?` as an ExpressionPattern — covered above.)
    }

    /// Everything under a `let`/`var` binds: `let x`, `let (a, b)`, `let x?`, `let .foo(a, b)`
    /// (bare refs inside the expression are the bindings).
    private func registerBindingSubpattern(_ pattern: PatternSyntax, visibleIn: ConditionBindingExtent.Visibility? = nil) {
        if let ident = pattern.as(IdentifierPatternSyntax.self) {
            registerLocalBinding(ident.identifier, visibleIn: visibleIn)
        } else if let tuple = pattern.as(TuplePatternSyntax.self) {
            for el in tuple.elements { registerBindingSubpattern(el.pattern, visibleIn: visibleIn) }
        } else if let expr = pattern.as(ExpressionPatternSyntax.self) {
            // `let x as Foo` (checked-cast PATTERN) — bind `x` with the cast target as its type, so a
            // member read through it (`x.member()`) resolves to Foo's member (B1). All three matching
            // positions (switch case, catch, if/guard/while-case) parse it identically:
            // ExpressionPattern → SequenceExpr[ PatternExpr(x), UnresolvedAsExpr, TypeExpr(Foo) ].
            if let asBinding = Self.asPatternBinding(expr.expression) {
                registerLocalBinding(asBinding.token, type: asBinding.type, visibleIn: visibleIn)
            } else {
                registerBindingRefs(in: expr.expression, visibleIn: visibleIn)
            }
        } else if let vb = pattern.as(ValueBindingPatternSyntax.self) {
            registerBindingSubpattern(vb.pattern, visibleIn: visibleIn)
        }
    }

    /// Recognise a checked-cast PATTERN `x as T` (`case let x as T`, `catch let e as T`,
    /// `if case let y as T = …`) — the pattern-position sibling of `TypeResolver.castTargetTypeName`.
    /// It raw-parses (no operator folding) as a `SequenceExpr` of EXACTLY
    /// `[ PatternExpr(IdentifierPattern), UnresolvedAsExpr, TypeExpr ]`; anything else (a tuple
    /// binding `let (a, b) as T`, a longer sequence) fails closed and falls back to the generic
    /// binding-ref collector, which still registers the names, just untyped. Pattern casts are
    /// always plain `as` (never `as?`/`as!`), so the target is the binding's non-optional type;
    /// `registerLocalBinding` stores it via `WrittenTypeName.of`, resolved later in the binding's
    /// own declaring scope (B-FIX-23), exactly like any written annotation.
    private static func asPatternBinding(_ expr: ExprSyntax) -> (token: TokenSyntax, type: TypeSyntax)? {
        guard let seq = expr.as(SequenceExprSyntax.self) else { return nil }
        let elements = Array(seq.elements)
        guard elements.count == 3,
              let patExpr = elements[0].as(PatternExprSyntax.self),
              let ident = patExpr.pattern.as(IdentifierPatternSyntax.self),
              elements[1].is(UnresolvedAsExprSyntax.self),
              let typeExpr = elements[2].as(TypeExprSyntax.self)
        else { return nil }
        return (ident.identifier, typeExpr.type)
    }

    /// Under a `let`/`var`, `case let .foo(a, b)` binds `a`/`b`. Depending on the exact source
    /// shape the parser represents them either as nested `PatternExprSyntax` (→ IdentifierPattern)
    /// or as bare `DeclReferenceExpr`s inside the call expression. Collect BOTH.
    private func registerBindingRefs(in expr: ExprSyntax, visibleIn: ConditionBindingExtent.Visibility? = nil) {
        let collector = BindingRefCollector()
        collector.walk(expr)
        for token in collector.found { registerLocalBinding(token, visibleIn: visibleIn) }
        // These PatternExprs sit UNDER a `let`/`var`, so a bare identifier inside them IS a binding
        // (unlike a top-level matching position) — route through the binding path.
        for pat in collector.foundPatterns { registerBindingSubpattern(pat, visibleIn: visibleIn) }
    }

    /// `.foo(let x)` — walk the expression for nested PatternExprs and register their bindings.
    private func registerNestedBindings(in expr: ExprSyntax, visibleIn: ConditionBindingExtent.Visibility? = nil) {
        let collector = NestedPatternCollector()
        collector.walk(expr)
        for pat in collector.found { registerCaseItemPattern(pat, visibleIn: visibleIn) }
    }

    // MARK: - Function-like declarations

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let kind: SymbolKind = currentScope.kind == .type ? .method : .function
        let sym = makeSymbol(name: node.name.text, kind: kind, identifierToken: node.name)
        if Self.hasModifier(node.modifiers, "override") { table.overrideMemberIds.insert(sym.id) }
        if let ret = node.signature.returnClause, let t = WrittenTypeName.of(ret.type) {
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
            if let t = WrittenTypeName.of(param.type) {
                table.declaredType[sym.id] = t
            }
        }
        // Record the subscript's signature (external labels + declared return type) against the
        // enclosing type/extension scope, so `base[args]` on a LOCAL type can resolve to the exact
        // declared return type. Subscript label rule differs from functions: a plain `subscript(i:)`
        // is called `x[5]` with NO label — a label exists ONLY when there's a distinct external name
        // (`subscript(safe i:)` → `x[safe: 5]`), i.e. when `secondName` is present.
        if let enclosing = scope.parent, let ret = WrittenTypeName.of(node.returnClause.type) {
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
        return fn.parameters.map { WrittenTypeName.of($0.type) ?? "" }
    }

    /// Register generic parameters (`<T: P, U>`) as NON-renameable `.typealias_` placeholders in
    /// `scope`. Target = the constraint's bare type name so member access through the placeholder
    /// (`r: T` → `r.render()`) resolves via the constraint protocol. Recorded in
    /// `genericParameterIds` so the Planner never renames them (a generic param is a local
    /// placeholder, and it also shadows any same-named global type inside the decl).
    private func registerGenericParameters(_ clause: GenericParameterClauseSyntax?, into scope: Scope) {
        guard let clause else { return }
        var orderedNames: [String] = []
        for p in clause.parameters {
            let token = p.name
            let name = Self.stripBackticks(token.text)
            guard name != "_" else { continue }
            orderedNames.append(name)
            let sym = Symbol(
                id: mintId(), name: name, kind: .typealias_,
                module: file.module, file: file, scope: scope,
                declOffset: token.positionAfterSkippingLeadingTrivia.utf8Offset,
                declLength: token.trimmedLength.utf8Length
            )
            scope.add(symbol: sym)
            table.register(sym)
            table.genericParameterIds.insert(sym.id)
            if let inherited = p.inheritedType, let t = WrittenTypeName.of(inherited) {
                table.typealiasTarget[sym.id] = t
            }
        }
        // Record the ORDERED names against the owner (the type or func the clause belongs to) so a
        // generic parameter used as a closure-typed init parameter can be substituted positionally
        // with the concrete argument (B-FIX-62). `scope.owner` is the type/func symbol at this point.
        if let ownerId = scope.owner?.id, !orderedNames.isEmpty {
            table.genericParameterNames[ownerId] = orderedNames
        }
    }

    private func registerParameters(_ params: FunctionParameterListSyntax, in scope: Scope, funcId: Int) {
        var paramTypes: [String?] = []
        var paramLabels: [String] = []
        var paramHasDefault: [Bool] = []
        var closureInputs: [Int: [String]] = [:]
        for (paramIndex, param) in params.enumerated() {
            paramTypes.append(WrittenTypeName.of(param.type))
            paramHasDefault.append(param.defaultValue != nil)
            let closureInput = Self.closureInputTypeNames(of: param.type)
            if let closureInput {
                closureInputs[paramIndex] = closureInput
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
            if let t = WrittenTypeName.of(param.type) {
                table.declaredType[sym.id] = t
            }
            // The internal name is safely renameable iff the parameter has a DISTINCT external
            // label. Forms `func f(_ x:)` and `func f(label x:)` have secondName set — renaming
            // `x` doesn't touch the call-site signature. Form `func f(x:)` has secondName=nil —
            // renaming `x` would change `f(x:)` to `f(p0:)` and break callers.
            if param.secondName != nil {
                table.renameableParameters.insert(sym.id)
            }
            // A function-typed parameter (`completion: (E1) -> Void`) called as a callee reads its
            // input types from `valueClosureInput`, keyed by its OWN id (B-FIX-66). `declaredType` is
            // nil for it (`WrittenTypeName.of` reduces no function type), so this is the only carrier.
            if let closureInput { table.valueClosureInput[sym.id] = closureInput }
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
                // A function-typed property/local (`let completion: (E1) -> Void`) records its input
                // types under its own id so a call through it as a callee can type a shorthand argument
                // (B-FIX-66). `WrittenTypeName.of` reduces no function type, so the annotation branch
                // below records no `declaredType` for it — this is the only carrier.
                if let annotation = binding.typeAnnotation,
                   let closureInput = Self.closureInputTypeNames(of: annotation.type) {
                    table.valueClosureInput[sym.id] = closureInput
                }
                if let annotation = binding.typeAnnotation,
                   let typeName = WrittenTypeName.of(annotation.type) {
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
    ///
    /// The STATEMENT itself is the scope, not its body: a loop variable is declared before the
    /// opening brace (and is in scope in the `where` clause, which also sits outside the body), and
    /// it dies with the loop. Registering it into the enclosing scope instead left it visible BELOW
    /// the loop, where `for row in rows { … }; return row` reads the same-named PROPERTY — so the
    /// return was resolved to the un-renameable loop variable, kept its original name while the
    /// property renamed, and shield 1b (the loop variable is an un-renamed namesake) blocked the
    /// rollback rescue: "cannot find 'row' in scope" (B-FIX-44). The body's own `CodeBlockSyntax`
    /// scope simply nests inside this one, so a body local still shadows the loop variable.
    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind {
        _ = push(.block, owner: nil, node: node)
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
                // `for row: Section.Row in rows` — a WRITTEN annotation is ground truth and outranks
                // element inference (B-FIX-35), which has to guess through the sequence expression.
                // The string resolves later in `sym.scope`, which is where it was written.
                if let annotation = node.typeAnnotation,
                   let typeName = WrittenTypeName.of(annotation.type) {
                    table.declaredType[sym.id] = typeName
                } else {
                    table.forLoopSequence[sym.id] = node.sequence
                }
            }
        } else if node.caseKeyword != nil {
            registerCaseItemPattern(node.pattern)
        } else if let tuple = node.pattern.as(TuplePatternSyntax.self), node.typeAnnotation == nil {
            registerForInTuplePattern(tuple, sequence: node.sequence)
        } else {
            registerDeclarationPattern(node.pattern)
        }
        return .visitChildren
    }
    override func visitPost(_ node: ForStmtSyntax) { pop() }

    /// `for (offset, row) in rows.enumerated()` — the pattern DESTRUCTURES the element, so each name
    /// takes the component at its own position rather than the whole element (B-FIX-38). Record the
    /// sequence AND the position; TypeInferencePass resolves the pair once the table is complete.
    ///
    /// Only a flat list of plain identifiers and wildcards is handled — a nested tuple or a
    /// sub-pattern falls back to the untyped registration below, which is what every element of this
    /// pattern used to get. A `_` binds nothing but still OCCUPIES a position, so it is counted:
    /// `for (_, row) in rows.enumerated()` must take component 1, not component 0.
    private func registerForInTuplePattern(_ tuple: TuplePatternSyntax, sequence: ExprSyntax) {
        // A single-element parenthesised pattern (`for (x) in …`) is just `x` — not a destructuring.
        guard tuple.elements.count > 1 else {
            registerDeclarationPattern(PatternSyntax(tuple))
            return
        }
        registerTuplePatternLeaves(tuple, sequence: sequence, prefix: [])
    }

    /// Register each IDENTIFIER leaf of a (possibly NESTED) for-in tuple pattern with the PATH of
    /// `(index, arity)` steps from the element down to it, so TypeInferencePass can walk the element's
    /// tuple type to the leaf's component. A flat pattern (`for (offset, row) in …`) yields a
    /// length-1 path (B-FIX-38); a nested one (`for (offset, (idx, cell)) in …`) descends (B5). A
    /// non-identifier leaf (`_`, or a shape we don't model) is registered without a path — it binds
    /// nothing renameable or falls back to the plain declaration path, exactly as before.
    private func registerTuplePatternLeaves(_ tuple: TuplePatternSyntax, sequence: ExprSyntax,
                                            prefix: [(index: Int, arity: Int)]) {
        let elements = Array(tuple.elements)
        let arity = elements.count
        for (index, element) in elements.enumerated() {
            let path = prefix + [(index: index, arity: arity)]
            if let nested = element.pattern.as(TuplePatternSyntax.self) {
                registerTuplePatternLeaves(nested, sequence: sequence, prefix: path)
            } else if let ident = element.pattern.as(IdentifierPatternSyntax.self) {
                registerLocalBinding(ident.identifier)
                // `registerLocalBinding` skips `_`/`self`; only a symbol it actually created can be typed.
                guard let sym = currentScope.symbols.last,
                      sym.declOffset == ident.identifier.positionAfterSkippingLeadingTrivia.utf8Offset
                else { continue }
                table.forLoopSequence[sym.id] = sequence
                table.forLoopTuplePosition[sym.id] = path
            } else {
                // Wildcard `_` occupies a position but binds nothing; any other shape falls back to
                // the plain declaration path (registers its names, untyped).
                registerDeclarationPattern(element.pattern)
            }
        }
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
        // `x as? T` / `x as! T` / `x as T` — the local's static type is T (unwrapped for the same
        // reason an annotation is: member access is what consumes it). It raw-parses as a SequenceExpr
        // of exactly `[expr, UnresolvedAsExpr, TypeExpr]`; a LONGER sequence means the cast is embedded
        // in a bigger expression (`x as? T ?? y`, `x as? T == z`) whose result type is not T, so it is
        // skipped (fail closed). Without this a `let a = x as? T; a?.member` local was untyped and the
        // member read stayed original while its declaration renamed — a desync that ships red when the
        // member is a protocol requirement its witness keeps renamed (B-FIX-61).
        if let seq = expr.as(SequenceExprSyntax.self) {
            let elems = Array(seq.elements)
            if elems.count == 3, elems[1].is(UnresolvedAsExprSyntax.self),
               let typeExpr = elems[2].as(TypeExprSyntax.self) {
                return WrittenTypeName.of(typeExpr.type)
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
                table.enumCaseAssociatedTypes[sym.id] = params.map { WrittenTypeName.of($0.type) }
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
