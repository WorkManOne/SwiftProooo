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
    /// Initializer expression for var/let bindings whose type we couldn't infer at declaration
    /// time. TypeInferencePass uses these later, with the full SymbolTable populated.
    public internal(set) var initializerExpr: [Int: ExprSyntax] = [:]
    /// For-loop sequence expressions, by loop-variable symbol id. The variable's type is the
    /// sequence's Element type — inferred when that information is available.
    public internal(set) var forLoopSequence: [Int: ExprSyntax] = [:]
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
    /// IDs of generic-parameter placeholder symbols (`T` in `func f<T: P>(…)`, `<Element>` on a
    /// type). Registered as `.typealias_` (target = the constraint, so `r: T` member access
    /// resolves through the protocol) but NEVER renamed — a generic param is a local placeholder,
    /// not a declaration whose name we own. The Planner skips these; without the set they'd be
    /// treated as ordinary renameable typealiases.
    public internal(set) var genericParameterIds: Set<Int> = []
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
    }
    public private(set) var extensionRefs: [ExtensionRef] = []

    public init() {}

    public func registerExtension(scope: Scope, extendedType: TypeSyntax, file: SourceFile,
                                  inheritedNames: [String] = []) {
        extensionRefs.append(ExtensionRef(scope: scope, extendedType: extendedType, file: file,
                                          inheritedNames: inheritedNames))
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
    public func extensionConformanceNames(ownerId: Int) -> [String] {
        var out: [String] = []
        for ext in extensionRefs where ext.scope.owner?.id == ownerId {
            out.append(contentsOf: ext.inheritedNames)
        }
        return out
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

    /// All function/method symbols with the given name (overload search index — C-2).
    public func callables(named name: String) -> [Symbol] {
        callablesByName[name] ?? []
    }
}
