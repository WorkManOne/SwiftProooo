import Foundation
import SwiftSyntax

public final class SymbolTable {
    public private(set) var symbols: [Symbol] = []
    public private(set) var fileScopes: [ObjectIdentifier: Scope] = [:]
    /// Inner scope opened by a declaration node (type scope for class/struct/enum/protocol/extension,
    /// function scope for func/init). Indexed by SyntaxIdentifier.
    public private(set) var innerScope: [SyntaxIdentifier: Scope] = [:]
    /// Enum-case symbols indexed by their case name (for shorthand `.case` resolution).
    public private(set) var enumCasesByName: [String: [Symbol]] = [:]
    /// Declared type name for property/parameter symbols (best-effort — IdentifierType only).
    public internal(set) var declaredType: [Int: String] = [:]
    /// Declared TUPLE type of a property/parameter/local (`(offset: Int, element: Row)`), kept SEPARATE
    /// from `declaredType` because `WrittenTypeName.of` deliberately returns nil for a tuple (a tuple in
    /// `declaredType` / `functionParamTypes` would reach witness linking and overload disambiguation,
    /// whose nil-as-wildcard semantics it must not disturb — the B-FIX-27 hazard). Read only by the
    /// tuple-component / tuple-pattern paths through `TypeResolver.receiverTypeInfo`, never by those
    /// matchers, so member access `pair.element` and a tuple-pattern binding resolve without touching
    /// them (B-FIX-78).
    public internal(set) var tupleDeclaredType: [Int: String] = [:]
    /// Written protocol/class COMPOSITION type of a property/parameter/local (`p: A & B`), kept OUT
    /// of `declaredType` for the same reason as a tuple (`WrittenTypeName.of` returns nil for a
    /// composition — the B-FIX-27 hazard). Stored as the "A & B" component string, read only by
    /// member resolution through `TypeResolver.receiverTypeInfo`, which tries each component
    /// (B-FIX-93). The flow-sensitive condition-binding form (`if let p: A & B = …`) is carried by
    /// `ResolutionPass.bindingType` instead, not here.
    public internal(set) var compositionDeclaredType: [Int: String] = [:]
    /// Raw type of an `enum X: String { … }` (or Int etc.). Populated during DeclarationPass when
    /// the enum's first inherited type is a basic raw type. Used by ResolutionPass's overload
    /// disambiguator to type `x.rawValue` arguments without full semantic analysis — without it,
    /// `f(par.rawValue)` carries no type signal, so the resolver falls back to module-level
    /// tiebreaking and can wrongly pick the SAME extension method (infinite-recursion rename).
    public internal(set) var enumRawType: [Int: String] = [:]
    /// Ordered parameter type names for function/method/initializer symbols (IdentifierType only,
    /// nil entries indicate non-trivial types we don't track).
    public internal(set) var functionParamTypes: [Int: [String?]] = [:]
    /// Return-type name of function/method symbols. Used by argument-type inference: when a call
    /// `obj.method(...)` is used as an argument, its type for disambiguation is the method's
    /// return type. Without this everything to the right of a method call has unknown type.
    public internal(set) var functionReturnType: [Int: String] = [:]
    /// Target type name of `typealias X = Foo.Bar` declarations. Used by qualified-chain
    /// resolution: a chain `T1.S2` where `T1` is a typealias must follow to T1's target type so
    /// `S2` can be looked up in the actual type's scope. Without this, `T1.S2` resolves nowhere
    /// and the use-site stays un-renamed while `S2`'s decl is obfuscated → desync.
    public internal(set) var typealiasTarget: [Int: String] = [:]
    /// Ordered external argument labels for function/method/initializer symbols. "_" means the
    /// parameter has no call-site label (positional). Used for overload resolution by labels.
    public internal(set) var functionParamLabels: [Int: [String]] = [:]
    /// Parallel to `functionParamLabels`: whether each parameter has a DEFAULT value (so the call
    /// may omit it). Required for correct overload label-matching — without it an overload with a
    /// trailing defaulted param is wrongly eliminated when the call omits it, and a same-named
    /// overload with a different signature is then mis-picked (wrong rename → compile break).
    public internal(set) var functionParamHasDefault: [Int: [Bool]] = [:]
    /// For function/method/initializer params that are themselves FUNCTION types (`(X, Y) -> R`),
    /// the closure's input type names, keyed by declared-parameter index. Lets a closure argument
    /// to a USER-defined higher-order function have its `$0`/named params typed from the callee's
    /// declared signature — generalizing HOF closure-param inference beyond the hardcoded stdlib
    /// registry (B-FIX-2). E.g. `func transform(_ f: (Item) -> Int)` records `[0: ["Item"]]`.
    public internal(set) var functionParamClosureInput: [Int: [Int: [String]]] = [:]
    /// For a VALUE (parameter / property / local) whose written type IS a FUNCTION type
    /// (`completion: (E1) -> Void`), the closure's input type names, keyed by that value symbol's OWN
    /// id. `functionParamClosureInput` is keyed by the OWNING callable + parameter index (for typing a
    /// closure ARGUMENT), which cannot answer "what does THIS value, called as a callee, take". So when
    /// the callee of a call is a function-typed value (`completion(.c2)`), its parameter TYPE at a
    /// shorthand `.case` argument is read from here. Function types carry no argument labels, so the
    /// call's arguments are positional and the argument index maps directly to the input position.
    /// Input names are WRITTEN in the value's declaring scope (carry `Symbol.scope` when reading). B-FIX-66.
    public internal(set) var valueClosureInput: [Int: [String]] = [:]
    /// For a VALUE of FUNCTION type, the RETURN type name — the twin of `valueClosureInput`. Lets a
    /// CALL through the value (`produce()`, `completion()`, `it()`) type its result, so a member chain
    /// or a switch/case subject reached through such a call resolves. A function-typed value is not a
    /// callable DECLARATION (no `functionReturnType`) and `WrittenTypeName` reduces no function type
    /// (no `declaredType`), so this is the only carrier. The name is WRITTEN in the value's declaring
    /// scope (carry `Symbol.scope` when reading).
    public internal(set) var valueClosureReturn: [Int: String] = [:]
    /// For a `typealias` whose underlying type is a FUNCTION type (`typealias Handler = (En1) -> Void`),
    /// the closure's input type names, keyed by the typealias symbol id. `functionParamClosureInput`
    /// only sees a LITERAL `FunctionTypeSyntax` on the parameter, so a `func f(_ h: Handler)` records
    /// nothing there and the closure's `$0`/named param could not be typed (a switch subject bound
    /// through such a completion handler stayed untyped → its payload binding untyped → member reads
    /// through it desynced). This side-table lets `hofClosureParamType` resolve the alias and recover
    /// the inputs. Input names are WRITTEN in the alias's own scope (carry `Symbol.scope` when reading).
    public internal(set) var typealiasClosureInput: [Int: [String]] = [:]
    /// For a CALLABLE whose RETURN is itself a function type (`func makeHandler() -> (E) -> R`), the
    /// parsed return / input of that returned function type, keyed by the callable's id. `WrittenTypeName`
    /// drops a function type, so `functionReturnType` is empty for such a callable — this is the only
    /// carrier. Consumed only when a local/property is INITIALIZED by calling it (`let f = makeHandler()`),
    /// to type `f()` (return) and `f(.case)` (input) exactly as a function-typed value is (B-FIX-73/66).
    /// Names are WRITTEN in the callable's declaring scope (carry `Symbol.scope` when reading). B-FIX-85.
    public internal(set) var callableClosureReturn: [Int: String] = [:]
    public internal(set) var callableClosureInput: [Int: [String]] = [:]
    /// Initializer expression for var/let bindings whose type we couldn't infer at declaration
    /// time. TypeInferencePass uses these later, with the full SymbolTable populated.
    public internal(set) var initializerExpr: [Int: ExprSyntax] = [:]
    /// For-loop sequence expressions, by loop-variable symbol id. The variable's type is the
    /// sequence's Element type — inferred when that information is available.
    public internal(set) var forLoopSequence: [Int: ExprSyntax] = [:]
    /// An accessor value binding (`newValue`/`oldValue`, or an explicit `set(incoming)`) whose owning
    /// property has NO written annotation → the id of that owning property. Its type is only known
    /// after TypeInferencePass resolves the property's initializer, so the binding's type is
    /// transferred from the owner there (B3). A binding with a written accessor type carries its
    /// `declaredType` directly and never appears here.
    public internal(set) var accessorBindingOwner: [Int: Int] = [:]
    /// For a loop variable bound by a TUPLE pattern (`for (offset, row) in rows.enumerated()`), the
    /// PATH of `(index, arity)` steps from the element down to it. The variable's type is the
    /// element's COMPONENT reached by walking the tuple type along that path (B-FIX-38); a NESTED
    /// pattern (`for (offset, (idx, cell)) in …`) yields a path longer than one (B5). The arity at
    /// each step is what lets the consumer refuse to descend into anything that is not a tuple of
    /// exactly that size (fail-closed).
    public internal(set) var forLoopTuplePosition: [Int: [(index: Int, arity: Int)]] = [:]
    /// IDs of method/property symbols declared with the `override` modifier. OverrideLinker unifies
    /// each override's obf with the base member it overrides — without it, the base and the override
    /// get INDEPENDENT obfs and Swift reports "method/property does not override any … from its
    /// superclass" (a default-run red build RollbackPass cannot catch, since no original survives).
    public internal(set) var overrideMemberIds: Set<Int> = []
    /// IDs of INSTANCE property symbols that are STORED (no computed getter — plain `let`/`var`, or a
    /// `var` with only `didSet`/`willSet` observers). Codable synthesizes its CodingKeys from exactly
    /// these, so they are the serialization contract; Protector keeps them un-renamed on a Codable type.
    /// Computed properties (with a getter) are NOT stored and stay renameable. `static`/`class` (TYPE)
    /// properties are EXCLUDED — they never appear in synthesized CodingKeys, so they stay renameable
    /// too. Fail-closed: an instance binding we can't classify is treated as stored.
    public internal(set) var storedPropertyIds: Set<Int> = []
    /// Associated-value TYPE names of an enum case, positionally (`case run(Mood)` → ["Mood"]); nil
    /// entries are types we don't track. A case with a payload is CALLED like a function, so this is
    /// the `functionParamTypes` of that call: without it a payload argument (`Command.run(.calm)`)
    /// has no contextual type, the shorthand stays original while the case renames, and the survivor
    /// reverts the enum's whole case group — plus the payload enum's, since the same argument site
    /// blocks both.
    public internal(set) var enumCaseAssociatedTypes: [Int: [String?]] = [:]
    /// IDs of generic-parameter placeholder symbols (`T` in `func f<T: P>(…)`, `<Element>` on a
    /// type). Registered as `.typealias_` (target = the constraint, so `r: T` member access
    /// resolves through the protocol) but NEVER renamed — a generic param is a local placeholder,
    /// not a declaration whose name we own. The Planner skips these; without the set they'd be
    /// treated as ordinary renameable typealiases.
    public internal(set) var genericParameterIds: Set<Int> = []
    /// The ORDERED generic-parameter names of a generic TYPE or function/init, keyed by owner symbol
    /// id (`struct Wrapper<T>` → [wrapperId: ["T"]], `struct Pair<A, B>` → [pairId: ["A","B"]]).
    /// `genericParameterIds` is a Set and carries no order, but generic substitution is POSITIONAL —
    /// mapping `Wrapper<Payload>`'s argument list to the parameter list — so the order is required.
    /// Used by `TypeResolver` to substitute a generic parameter appearing as a closure-typed init
    /// parameter (`init(_ f: (T) -> Void)`) with the concrete argument from context (B-FIX-62).
    public internal(set) var genericParameterNames: [Int: [String]] = [:]
    /// IDs of type symbols (structs) that declare an explicit `init` in their PRIMARY declaration
    /// (NOT in an extension). Swift suppresses the compiler-synthesized memberwise init only for
    /// these — a struct whose only inits are in extensions KEEPS its memberwise init. The
    /// memberwise-init-label-rename heuristic (ResolutionPass) must consult THIS, not the unified
    /// type scope (which includes extension inits) — else a struct with an extension init wrongly
    /// disables the label rename and its stored properties revert (B-FIX-19 follow-up).
    public internal(set) var structsWithMainDeclInit: Set<Int> = []
    /// IDs of function/method/initializer parameters that can be SAFELY renamed without
    /// changing the public call-site signature. A parameter is renameable when its declaration
    /// has a distinct external label (forms `_ name` or `label name`) — the rename touches only
    /// the internal name, leaving the call-site label unchanged. Parameters declared as plain
    /// `name:` (label == internal) are NOT in this set: renaming would alter the public API.
    public internal(set) var renameableParameters: Set<Int> = []
    /// Declared subscript signatures per OWNER type symbol id: for each `subscript(...) -> R` on a
    /// type (including its extensions), the external argument labels and the return-type name. Lets
    /// `base[args]` on a LOCAL type resolve to the subscript's DECLARED return type (read from
    /// source, never guessed) so a member reached through a custom subscript (`grid[i].member`)
    /// renames. Collections (Array/Dictionary/…) are handled separately by element/value extraction —
    /// they are NOT recorded here. Populated in DeclarationPass and finalized (owner-keyed) once
    /// extension owners are resolved; unresolvable owners (external/read-only) are dropped fail-closed.
    public struct SubscriptSignature {
        /// External call-site labels, "_" = positional (subscript param with no distinct external name).
        public let labels: [String]
        /// Declared return-type name (optionals peeled — the base type for member resolution).
        public let returnType: String
    }
    public internal(set) var subscriptSignatures: [Int: [SubscriptSignature]] = [:]
    /// Subscript signatures awaiting owner resolution (mirrors `extensionRefs`): the enclosing
    /// type/extension scope carries the owner, which for an extension is set only after
    /// ExtensionOwnerResolver. Drained by `finalizeSubscriptSignatures()`.
    private var pendingSubscriptSigs: [(scope: Scope, sig: SubscriptSignature)] = []

    /// All declared types by name (for type-reference resolution).
    private var typesByName: [String: [Symbol]] = [:]
    /// All callable (function/method) symbols by name. Built once at registration so the global
    /// overload search and user-HOF callee resolution don't re-scan every symbol per call (C-2).
    private var callablesByName: [String: [Symbol]] = [:]

    /// Extension scopes awaiting owner resolution. The owner cannot be resolved reliably during
    /// DeclarationPass (the type may be declared later, and same-named types across modules need
    /// module-aware disambiguation). ExtensionOwnerResolver resolves these after the full table
    /// is built, using the same semantics as type-reference resolution.
    public struct ExtensionRef {
        public let scope: Scope
        public let extendedType: TypeSyntax
        public unowned let file: SourceFile
        /// Inherited-type names from the extension's own clause (`extension S: P, Q`). These are
        /// conformances declared on the extension, invisible from the extended type's primary decl
        /// — both ConformanceVisibility and WitnessLinker need them (B-FIX-6).
        public let inheritedNames: [String]
        /// Right-hand side of an `Element == X` same-type requirement in the extension's
        /// `where` clause (`extension Array where Element == Mood`), when present. Only meaningful
        /// for an extension on a stdlib COLLECTION — it is what tells two same-named members on
        /// `[Mood]` and `[String]` apart at a use-site (B-FIX-31).
        public let elementConstraint: String?
    }
    public private(set) var extensionRefs: [ExtensionRef] = []

    /// An extension of a type that is NOT in our table — a stdlib/SDK type (`extension String`,
    /// `extension Array where Element == Mood`). Its members ARE renameable: since the extended type
    /// has no Symbol, use-sites are matched by the receiver's WRITTEN TYPE instead of by Symbol
    /// identity (B-FIX-31). The scope is deliberately NOT unified with anything — an extension on
    /// `Array` must never make its members visible on the ELEMENT type.
    public struct ExternalExtensionRef {
        public let scope: Scope
        /// Extended type normalized to a base NAME: `Array` for both `Array`, `[Mood]` and
        /// `Array<Mood>`; `Dictionary` for `[K: V]`; `String` for a plain named type.
        public let baseName: String
        /// The Element this extension is constrained to (from a `where Element == X` clause or from
        /// the sugar/generic spelling). nil ⇒ applies to every element type.
        public let elementConstraint: String?
        /// Scope the two names above were written in (the extension's enclosing scope): a nested
        /// element type spelled unqualified resolves only there (B-FIX-23 discipline).
        public let declScope: Scope
        public let module: String
    }
    public private(set) var externalExtensions: [ExternalExtensionRef] = []
    private var externalExtensionScopes: Set<ObjectIdentifier> = []

    public init() {}

    public func registerExtension(scope: Scope, extendedType: TypeSyntax, file: SourceFile,
                                  inheritedNames: [String] = [], elementConstraint: String? = nil) {
        extensionRefs.append(ExtensionRef(scope: scope, extendedType: extendedType, file: file,
                                          inheritedNames: inheritedNames,
                                          elementConstraint: elementConstraint))
    }

    /// Collect the extensions whose owner did NOT resolve — i.e. extensions on external types —
    /// into `externalExtensions`. Call once after `ExtensionOwnerResolver` and BEFORE
    /// `ScopeUnification` (which rewires only owned extension scopes).
    ///
    /// Fail-closed eligibility: an extension is skipped when IT, or any other extension of the SAME
    /// extended type anywhere in the project, declares a conformance. Such members are witnesses of
    /// a protocol on a type we don't own, so `WitnessLinker` cannot pair them with the requirement
    /// and renaming one silently breaks the conformance.
    public func finalizeExternalExtensions() {
        var conformingBases = Set<String>()
        for ext in extensionRefs where !ext.inheritedNames.isEmpty {
            conformingBases.insert(Self.normalizedExtendedType(ext).base)
        }
        for ext in extensionRefs where ext.scope.owner == nil {
            guard ext.inheritedNames.isEmpty, let declScope = ext.scope.parent else { continue }
            let normalized = Self.normalizedExtendedType(ext)
            guard !conformingBases.contains(normalized.base) else { continue }
            externalExtensions.append(ExternalExtensionRef(
                scope: ext.scope, baseName: normalized.base, elementConstraint: normalized.element,
                declScope: declScope, module: ext.file.module.name
            ))
            externalExtensionScopes.insert(ObjectIdentifier(ext.scope))
        }
    }

    /// True when `scope` is the body of an eligible external-type extension (see above).
    public func isExternalExtensionScope(_ scope: Scope) -> Bool {
        externalExtensionScopes.contains(ObjectIdentifier(scope))
    }

    /// Base name + element constraint of an extended type, folding the sugar and generic spellings
    /// onto the same pair: `[Mood]` / `Array<Mood>` / `Array where Element == Mood` all normalize to
    /// (`Array`, `Mood`); `[K: V]` to (`Dictionary`, nil); `String` to (`String`, nil).
    static func normalizedExtendedType(_ ext: ExtensionRef) -> (base: String, element: String?) {
        let written = ext.extendedType.trimmedDescription.trimmingCharacters(in: .whitespaces)
        if written.hasPrefix("["), written.hasSuffix("]") {
            let inner = String(written.dropFirst().dropLast())
            if TypeResolver.topLevelIndex(of: ":", in: inner) != nil { return ("Dictionary", nil) }
            return ("Array", inner.trimmingCharacters(in: .whitespaces))
        }
        guard let lt = written.firstIndex(of: "<"), written.hasSuffix(">") else {
            return (written, ext.elementConstraint)
        }
        let base = String(written[..<lt])
        let args = String(written[written.index(after: lt)...].dropLast())
        // A single generic argument on a collection IS the Element (`Array<Mood>`); anything else
        // (Dictionary's two arguments, an unparsable list) carries no element constraint.
        if TypeResolver.topLevelIndex(of: ",", in: args) == nil {
            return (base, args.trimmingCharacters(in: .whitespaces))
        }
        return (base, ext.elementConstraint)
    }

    /// Record a `subscript(...) -> R` declaration. `enclosingScope` is the type/extension scope that
    /// lexically contains the subscript (its `.owner` names the type — resolved now for a type body,
    /// after ExtensionOwnerResolver for an extension). Deferred so both cases key by the resolved owner.
    public func registerSubscript(enclosingScope: Scope, labels: [String], returnType: String) {
        pendingSubscriptSigs.append((enclosingScope, SubscriptSignature(labels: labels, returnType: returnType)))
    }

    /// Fold pending subscript signatures into the owner-keyed `subscriptSignatures`. Call once after
    /// ExtensionOwnerResolver (so extension scopes have their owner). Signatures whose owner didn't
    /// resolve (external/read-only extended type) are dropped — we never model a subscript on a type
    /// we can't rename anyway (fail-closed).
    public func finalizeSubscriptSignatures() {
        for (scope, sig) in pendingSubscriptSigs {
            guard let owner = scope.owner else { continue }
            subscriptSignatures[owner.id, default: []].append(sig)
        }
        pendingSubscriptSigs.removeAll()
    }

    /// Conformance names declared on EXTENSIONS of the type whose canonical inner scope is owned by
    /// `ownerId`. Combined with the type's primary-decl inheritance clause, this is the full set of
    /// protocols a type conforms to (B-FIX-6 — extension-declared conformances).
    ///
    /// Reads the owner-keyed index once `indexExtensionConformances()` has been called (which
    /// ExtensionOwnerResolver does as its last act, i.e. exactly when owners are final); before that
    /// it falls back to the linear scan, which returns the same answer — no owner is resolved yet, so
    /// an early caller correctly sees nothing.
    public func extensionConformanceNames(ownerId: Int) -> [String] {
        if let index = extensionConformanceIndex { return index[ownerId] ?? [] }
        var out: [String] = []
        for ext in extensionRefs where ext.scope.owner?.id == ownerId {
            out.append(contentsOf: ext.inheritedNames)
        }
        return out
    }

    /// Owner id → conformance names declared on that type's extensions. nil until built.
    private var extensionConformanceIndex: [Int: [String]]?

    /// Build the owner-keyed extension-conformance index. Called by ExtensionOwnerResolver once every
    /// extension's owner is resolved — the answer cannot change after that, and `conformanceNames` is
    /// consulted from the per-use-site resolution paths where a linear scan over every extension in
    /// the project would show up.
    public func indexExtensionConformances() {
        var index: [Int: [String]] = [:]
        for ext in extensionRefs {
            guard let ownerId = ext.scope.owner?.id, !ext.inheritedNames.isEmpty else { continue }
            index[ownerId, default: []].append(contentsOf: ext.inheritedNames)
        }
        extensionConformanceIndex = index
    }

    /// EVERY protocol (and superclass) name written for `sym`: its PRIMARY declaration's inheritance
    /// clause plus the conformances declared on its extensions.
    ///
    /// This is the invariant `extension Model: Codable {}` broke over and over: a conformance is a
    /// conformance wherever it is written, so every consumer asking "what does this type conform to"
    /// must read BOTH halves. `InheritanceClause.names` deliberately reads only the primary decl, so
    /// asking it alone is always a half-answer — ask this instead.
    ///
    /// The two deliberate NON-consumers are `SuperclassVisibility` and `OverrideLinker`: Swift does
    /// not allow an extension to add a SUPERCLASS, so for those two the primary clause IS the whole
    /// answer and reading extensions would only add protocol names they must ignore anyway.
    public func conformanceNames(of sym: Symbol) -> [String] {
        InheritanceClause.names(atOffset: sym.declOffset, in: sym.file.syntax)
            + extensionConformanceNames(ownerId: sym.id)
    }

    public func register(_ symbol: Symbol) {
        symbols.append(symbol)
        switch symbol.kind {
        case .class, .struct, .enum, .protocol, .typealias_, .associatedtype_:
            typesByName[symbol.name, default: []].append(symbol)
        case .enumCase:
            enumCasesByName[symbol.name, default: []].append(symbol)
        case .method, .function:
            callablesByName[symbol.name, default: []].append(symbol)
        default: break
        }
    }

    public func attach(fileScope: Scope, forFileId id: ObjectIdentifier) {
        fileScopes[id] = fileScope
    }

    public func attach(innerScope scope: Scope, forNode id: SyntaxIdentifier) {
        innerScope[id] = scope
    }

    public func types(named name: String) -> [Symbol] {
        typesByName[name] ?? []
    }

    /// Module-aware, fail-closed pick of the type of `kind` named `name`: the same-module candidate
    /// wins; otherwise a UNIQUE cross-module candidate; otherwise nil (never guess among several).
    /// One implementation for the inheritance-chain passes — `.class` for SuperclassVisibility /
    /// OverrideLinker, `.protocol` for ConformanceVisibility / WitnessLinker / Protector. NOT for
    /// use-site concrete-type resolution, which is `TypeResolver.preferredConcreteType` (that also
    /// consults the USR index, A4). `module` is the `--module` LABEL by design in this syntactic tier.
    public func preferredType(kind: SymbolKind, named name: String, inModule module: String) -> Symbol? {
        let cands = types(named: name).filter { $0.kind == kind }
        if let same = cands.first(where: { $0.module.name == module }) { return same }
        return cands.count == 1 ? cands[0] : nil
    }

    /// All function/method symbols with the given name (overload search index — C-2).
    public func callables(named name: String) -> [Symbol] {
        callablesByName[name] ?? []
    }
}
