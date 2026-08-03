import Foundation
import SwiftSyntax

/// Best-effort recursive type resolution that takes a `Scope` explicitly. Decoupled from
/// `ResolutionVisitor` so it can be used both during the main rename walk and during a
/// later `TypeInferencePass` (resolving initializer expressions of var/let bindings).
///
/// Coverage of expression kinds:
///   - `self` / `Self`           — enclosing type scope's owner
///   - `name`                    — scope lookup → property/parameter's declaredType → type
///   - `Foo`                     — global type lookup
///   - `Foo(...)` / `Foo.init()` — type of `Foo`
///   - `obj.member`              — recurse into base, look up member, follow its declaredType
///   - `$x`, `_x`                — projection / storage, treat as the wrapped property
///   - Optional chaining / force unwrap / try / await — transparent
///
/// What is intentionally NOT supported (these need full Sema-style inference):
///   - Generic substitution beyond simple `Foo<T>` decomposition
///   - Closure parameter typing from receiver's element (handled separately by HOF pass)
///   - Return type of method calls (`foo.method().X`)
///   - Conditional expressions
public final class TypeResolver {
    public let table: SymbolTable
    /// Module name of the use-site being resolved. When several types share a name across
    /// targets, the one declared in this module wins (mirrors Swift's same-module preference
    /// for unqualified type references).
    public let preferredModule: String?

    /// Memoizes `preferredConcreteType(named:)`. The type table is immutable after DeclarationPass,
    /// so caching the (filtered, module-narrowed) result per name is safe for the resolver's life
    /// and avoids re-filtering the global candidates on every lookup (C-3). Only UNAMBIGUOUS results
    /// (≤1 surviving top-level candidate) are cached — an ambiguous name's answer can depend on the
    /// use-site USR (A4), so it must be recomputed per use-site.
    private var preferredCache: [String: Symbol?] = [:]

    // MARK: - A4 USR tiebreak context (all nil ⇒ purely syntactic, the baseline)

    /// Compiler ground-truth, when `indexStorePath` is set. Consulted ONLY to break same-named
    /// cross-target ties; it never overrides a syntactic single match.
    public let indexContext: IndexContext?
    /// Normalized path of the file whose use-sites this resolver resolves (the visitor's file).
    public let useSiteFilePath: String?
    /// Converter for that file, turning a use-site UTF-8 offset into the line:column the index uses.
    public let useSiteConverter: SourceLocationConverter?

    /// Injected provider: given a bare value name with NO scope Symbol, returns its static type — the
    /// NAME together with the scope that name must be resolved in. ResolutionVisitor wires this to
    /// its optional-binding type tracker so `typeSymbol(of:)` can type a binding local (`if let acc =
    /// makeFoo(); acc.x.y`) that is not a `declaredType`-carrying Symbol (B-FIX-12). Default nil ⇒
    /// purely syntactic. Safe w.r.t. the `preferredCache` (name-keyed, top-level types only) because
    /// `typeSymbol(of:)` is not cached.
    ///
    /// The scope is part of the answer, not an optional extra (B-FIX-35): the name may be a written
    /// annotation (resolves where the binding is written) or an inferred nested type (resolves in the
    /// type's DECLARING scope, invisible from the use-site). Re-resolving a bare name at the use-site
    /// is the B-FIX-23 defect, so the two travel together and there is no name-only variant to reach for.
    public var localBindingTypeName: ((String) -> (name: String, scope: Scope)?)?

    public init(table: SymbolTable, preferredModule: String? = nil,
                indexContext: IndexContext? = nil,
                useSiteFilePath: String? = nil,
                useSiteConverter: SourceLocationConverter? = nil) {
        self.table = table
        self.preferredModule = preferredModule
        self.indexContext = indexContext
        self.useSiteFilePath = useSiteFilePath
        self.useSiteConverter = useSiteConverter
    }

    public func typeSymbol(of expr: ExprSyntax, in scope: Scope) -> Symbol? {
        if let opt = expr.as(OptionalChainingExprSyntax.self) {
            return typeSymbol(of: opt.expression, in: scope)
        }
        if let force = expr.as(ForceUnwrapExprSyntax.self) {
            return typeSymbol(of: force.expression, in: scope)
        }
        if let tryExpr = expr.as(TryExprSyntax.self) {
            return typeSymbol(of: tryExpr.expression, in: scope)
        }
        if let awaitExpr = expr.as(AwaitExprSyntax.self) {
            return typeSymbol(of: awaitExpr.expression, in: scope)
        }
        // `base[args]` — the subscript RESULT type (so `arr[i].member` / `dict[k]?.member` /
        // `grid[i].member` resolve). See `subscriptResultType`.
        if let sub = expr.as(SubscriptCallExprSyntax.self) {
            return subscriptResultType(of: sub, in: scope)
        }
        // `Foo(...)` or `Foo.init(...)` produces an instance of Foo.
        if let call = expr.as(FunctionCallExprSyntax.self) {
            if let callee = call.calledExpression.as(DeclReferenceExprSyntax.self) {
                let name = Self.stripBackticks(callee.baseName.text)
                if let first = name.first, first.isUppercase,
                   let sym = scope.lookup(name: name), sym.kind.isTypeLike {
                    return sym
                }
                // Cross-file (same-module) fallback. MUST be module-aware: a bare `Widget()`
                // in ModA must resolve to ModA.Widget, never some other target's same-named
                // Widget. Using `table.types(named:).first` here is registration-order-dependent
                // and silently picks a foreign type — its members then carry the WRONG obf, so a
                // call's base renames to the local type but the member renames to the foreign
                // method ("Value of type 'X' has no member 'Y'"). The use-site token offset feeds
                // the USR tiebreak (A4) so a cross-target same-named base resolves to the real one.
                let offset = callee.baseName.positionAfterSkippingLeadingTrivia.utf8Offset
                if let typeSym = preferredConcreteType(named: name, at: offset) { return typeSym }
            }
            if let memberCall = call.calledExpression.as(MemberAccessExprSyntax.self),
               memberCall.declName.baseName.text == "init",
               let base = memberCall.base {
                return typeSymbol(of: base, in: scope)
            }
            // `Foo.Bar(args)` — a QUALIFIED type reference being CONSTRUCTED (e.g. `E1.S2(...)`), not
            // a method call. Distinguished from `recv.method(...)` by the whole callee resolving to a
            // type-like Symbol (its last segment is upper-cased by convention — a cheap pre-filter).
            // Must precede the method-return case, which would otherwise treat `S2` as a method of E1.
            if let memberCall = call.calledExpression.as(MemberAccessExprSyntax.self),
               memberCall.declName.baseName.text != "init",
               let firstCh = memberCall.declName.baseName.text.first, firstCh.isUppercase,
               let typeSym = typeSymbol(forQualifiedName: call.calledExpression.trimmedDescription, in: scope),
               typeSym.kind.isTypeLike {
                return typeSym
            }
            // `E.case(payload)` — an enum case WITH associated values is called like a function, and
            // the expression's type is the ENUM itself, not a method return. Must precede the method
            // case, which finds no callable and would give up: without this a `let c = E.case(x)`
            // binding stays untyped, so a `switch c` cannot type its patterns and every shorthand in
            // it survives → the case group reverts.
            if let memberCall = call.calledExpression.as(MemberAccessExprSyntax.self),
               let base = memberCall.base,
               let baseSym = typeSymbol(of: base, in: scope), baseSym.kind == .enum,
               let inner = canonicalInnerScope(of: baseSym),
               inner.members(named: Self.stripBackticks(memberCall.declName.baseName.text))
                    .contains(where: { $0.kind == .enumCase }) {
                return baseSym
            }
            // `receiver.method(args)` → method's return-type Symbol (when we tracked it). Without
            // this, chains like `obj.foo().bar` couldn't resolve `.bar` against `foo()`'s return
            // type, so use-sites past a method call were left un-renamed. Picks the method by
            // label match; falls back to nil on ambiguity.
            if let memberCall = call.calledExpression.as(MemberAccessExprSyntax.self),
               memberCall.declName.baseName.text != "init",
               let base = memberCall.base,
               let recvType = typeSymbol(of: base, in: scope),
               let recvScope = canonicalInnerScope(of: recvType) {
                let methodName = Self.stripBackticks(memberCall.declName.baseName.text)
                let methods = recvScope.members(named: methodName)
                    .filter { $0.kind == .method || $0.kind == .function }
                // Label matching goes through the ONE shared rule (B-FIX-36): a private
                // count-equality copy lived here and rejected `recv.build(from: x) { … }.member`,
                // because the trailing closure contributes a nil label that never equals the
                // declared `transform:`. The call's return type then stayed unknown and every
                // member reached through it was left original while its decl renamed.
                let matching = methods.filter { ArgumentLabelMatch.matches($0, call: call, in: table) }
                if matching.count == 1, let ret = table.functionReturnType[matching[0].id] {
                    return typeSymbol(forQualifiedName: ret, in: scope)
                }
            }
            // `items.sorted()` / `items.first(where:)` — a stdlib collection member in call form.
            // The receiver names no declaration, so none of the cases above can reach it; the
            // registry's result shape does (B-FIX-30). Resolving `[Element]` still yields nil (a
            // collection names no declaration) — only an ELEMENT result produces a Symbol here.
            if let info = receiverTypeInfo(of: expr, in: scope) {
                return typeSymbol(forQualifiedName: info.name, in: info.declScope)
            }
        }
        if let ref = expr.as(DeclReferenceExprSyntax.self) {
            let rawName = Self.stripBackticks(ref.baseName.text)
            // Closure shorthand parameter: `$0`, `$1`, ... — resolve via enclosing HOF call.
            // Only matches when the suffix is numeric — otherwise it's `$x` (projected value).
            if rawName.hasPrefix("$"), let idx = Int(rawName.dropFirst()) {
                // Resolve in the scope the inferred type NAME was written in, never the use-site's
                // (B-FIX-23) — see `resolveSource`.
                if let t = inferClosureParamType(at: idx, from: ref, in: scope) {
                    return typeSymbol(forQualifiedName: t.name, in: t.scope)
                }
                return nil
            }
            // `$x` (property wrapper projection — Binding<T>) and `_x` (storage) both share
            // the wrapped property's declared type; strip the prefix and resolve as the wrapped.
            var name = rawName
            if name.hasPrefix("$") || name.hasPrefix("_") {
                name = String(name.dropFirst())
            }
            if name == "self" || name == "Self" {
                return Self.enclosingTypeScope(of: scope)?.owner
            }
            if let sym = scope.lookup(name: name), sym.kind.isTypeLike {
                return unwrapTypealias(sym, in: scope)
            }
            // Every non-type source of a value's written type, in one place (B-FIX-37) — resolving
            // it here to a DECLARATION is what makes `p.member` work; `receiverTypeInfo` asks the
            // same helper for the name with its brackets intact.
            if let t = bareValueTypeInfo(named: name, from: ref, in: scope) {
                return typeSymbol(forQualifiedName: t.name, in: t.scope)
            }
            // A name that IS in the scope tree but has no known type is answered, not guessed: a
            // global type of the same name is not what a value reference denotes.
            if scope.lookup(name: name) != nil { return nil }
            if let target = preferredConcreteType(named: name) {
                return unwrapTypealias(target, in: scope)
            }
            // Conformance-inherited typealias/associatedtype — `T1` may not be lexically visible
            // here but declared as `typealias T1 = E1` in a protocol the enclosing type conforms
            // to. Without this fallback, `T1.X` expressions in a conformer can't resolve.
            if let inherited = conformanceInheritedTypealias(named: name, in: scope) {
                return unwrapTypealias(inherited, in: scope)
            }
            return nil
        }
        if let member = expr.as(MemberAccessExprSyntax.self), let base = member.base {
            let memberName = Self.stripBackticks(member.declName.baseName.text)
            if let baseSym = typeSymbol(of: base, in: scope),
               let baseScope = canonicalInnerScope(of: baseSym) {
                guard let memberSym = baseScope.member(named: memberName) else { return nil }
                if memberSym.kind.isTypeLike { return unwrapTypealias(memberSym, in: scope) }
                if let typeName = table.declaredType[memberSym.id] {
                    // Declaring scope, not use-site (see the DeclRef branch above): a member typed as
                    // a sibling nested type (`var p2: S3` inside `enum E1`) only resolves from E1's
                    // scope.
                    return typeSymbol(forQualifiedName: typeName, in: memberSym.scope ?? scope)
                }
                return nil
            }
            // The base resolved to NO declaration — the stdlib-collection case (`items.first?.m`,
            // `dict.values`): a collection type names no declaration since B-FIX-28, so the member's
            // result shape is the only way through the chain (B-FIX-30). Reached only when the base
            // is not a local type, so it can never shadow the path above.
            if let info = collectionMemberResult(member: memberName, receiver: base, in: scope) {
                return typeSymbol(forQualifiedName: info.name, in: info.declScope)
            }
            return nil
        }
        return nil
    }

    /// Best-effort STATIC TYPE NAME of an expression as a string. Unlike `typeSymbol(of:)` — which
    /// can only name LOCAL types (it returns a Symbol) — this also recovers the names of EXTERNAL /
    /// stdlib types (`URL`, `String`, …) that have no Symbol in our table. Optionals are unwrapped
    /// (matching the table-wide convention that `declaredType` strings carry the bare base name), so
    /// `if let u = makeURL()` where `makeURL() -> URL?` yields "URL". Used to type optional-binding
    /// locals so overload disambiguation gets a signal at the use-site (B-FIX-11 follow-up).
    public func declaredTypeName(of expr: ExprSyntax, in scope: Scope) -> String? {
        // A resolvable LOCAL type carries the most precise info — prefer it (identity-grade name).
        if let sym = typeSymbol(of: expr, in: scope) { return sym.name }
        // typeSymbol returned nil — the named type is likely EXTERNAL. Peel the wrappers it peels
        // (they don't change the named type) and recover the name directly.
        if let opt = expr.as(OptionalChainingExprSyntax.self) { return declaredTypeName(of: opt.expression, in: scope) }
        if let force = expr.as(ForceUnwrapExprSyntax.self) { return declaredTypeName(of: force.expression, in: scope) }
        if let tryE = expr.as(TryExprSyntax.self) { return declaredTypeName(of: tryE.expression, in: scope) }
        if let awaitE = expr.as(AwaitExprSyntax.self) { return declaredTypeName(of: awaitE.expression, in: scope) }
        if let call = expr.as(FunctionCallExprSyntax.self) {
            // `Foo(...)` constructor → "Foo".
            if let callee = call.calledExpression.as(DeclReferenceExprSyntax.self) {
                let name = Self.stripBackticks(callee.baseName.text)
                if let first = name.first, first.isUppercase { return name }
            }
            // `Foo.init(...)` → base type name.
            if let m = call.calledExpression.as(MemberAccessExprSyntax.self),
               m.declName.baseName.text == "init", let base = m.base {
                return declaredTypeName(of: base, in: scope)
            }
            // Free function / implicit-self method / `recv.method(...)` → callee's return-type name
            // (covers an EXTERNAL return type like `URL?`, where typeSymbol bailed).
            if let callable = calleeCallable(for: call, in: scope),
               let ret = table.functionReturnType[callable.id] {
                return Self.unwrapOptionalName(ret)
            }
            return nil
        }
        if let ref = expr.as(DeclReferenceExprSyntax.self) {
            var name = Self.stripBackticks(ref.baseName.text)
            if name.hasPrefix("$") || name.hasPrefix("_") { name = String(name.dropFirst()) }
            // All three type sources, not just `declaredType` (B-FIX-37) — so a binding used as a
            // call argument (`f(rows)`) carries a signal into overload disambiguation.
            return bareValueTypeInfo(named: name, from: ref, in: scope).map { Self.unwrapOptionalName($0.name) }
        }
        if let member = expr.as(MemberAccessExprSyntax.self), let base = member.base,
           let baseSym = typeSymbol(of: base, in: scope),
           let baseScope = canonicalInnerScope(of: baseSym) {
            let mname = Self.stripBackticks(member.declName.baseName.text)
            if let mSym = baseScope.member(named: mname), let t = table.declaredType[mSym.id] {
                return Self.unwrapOptionalName(t)
            }
        }
        return nil
    }

    /// The WRITTEN type name of a bare value reference (`rows`, `$x`, `_x`), together with the scope
    /// that name must be resolved in. THE one answer to "what type does this value have", for every
    /// caller that needs the name rather than a declaration.
    ///
    /// A value's type comes from three sources, and each of them is the only source for a whole
    /// class of bindings (B-FIX-37):
    ///   1. `table.declaredType` — a declared property / parameter / local;
    ///   2. HOF closure-parameter inference — `rows.map { row in … }`, where `row` is registered for
    ///      shadow correctness (F1) but carries no declared type;
    ///   3. the injected flow-sensitive provider — an optional binding (`guard let rows = …`,
    ///      B-FIX-12) or an enum-case payload (`case .load(let rows)`, B-FIX-29), which live outside
    ///      the table entirely.
    ///
    /// `typeSymbol(of:)` consulted all three; `receiverTypeInfo` and `declaredTypeName` consulted
    /// only the first, and that is the bug this helper exists to make unrepeatable. The two of them
    /// are the paths that keep a COLLECTION name intact (`typeSymbol` answers nil for one, B-FIX-28),
    /// so a binding typed as a collection had no way through them: `case .load(let rows)` followed by
    /// `rows.map { $0.field }` left `$0` untyped, every member read through it survived while its
    /// declaration renamed, and the desync shipped wherever a shield blocked the revert. The same nil
    /// silently disabled subscript results (`rows[0].field`) and stdlib-collection members
    /// (`rows.first?.field`) on any binding.
    ///
    /// Order matches the three-source list and is load-bearing where sources overlap: a recorded
    /// `declaredType` is a written fact and outranks both inferences.
    private func bareValueTypeInfo(named name: String, from ref: DeclReferenceExprSyntax,
                                   in scope: Scope) -> (name: String, scope: Scope)? {
        if let sym = scope.lookup(name: name) {
            if sym.kind.isTypeLike { return nil }
            if let t = table.declaredType[sym.id] {
                // The DECLARING scope, not the use-site: a bare nested type (`var p: S3` inside
                // `enum E1`) is written relative to where it was declared and is invisible from
                // other scopes (B-FIX-23).
                return (t, sym.scope ?? scope)
            }
            // Registered but untyped — a closure parameter or a case-let binding. Registering it for
            // shadow correctness must not disable the typing that ran when the name was absent from
            // the scope tree, so both remaining sources are tried here too.
            guard sym.kind == .parameter else { return nil }
            if let t = inferNamedClosureParamType(name: name, from: ref, in: scope) { return t }
            return localBindingTypeName?(name)
        }
        // Not a scope Symbol at all — an optional binding (`if let acc = makeFoo()`). Returns nil for
        // external types (URL, …), leaving external members untouched.
        if let t = localBindingTypeName?(name) { return t }
        return inferNamedClosureParamType(name: name, from: ref, in: scope)
    }

    /// Strip trailing optional markers (`?`/`!`) from a type-name string.
    static func unwrapOptionalName(_ s: String) -> String {
        var n = s
        while n.hasSuffix("?") || n.hasSuffix("!") { n = String(n.dropLast()) }
        return n
    }

    /// If `sym` is a typealias whose RHS resolves to another type Symbol, follow the chain to the
    /// underlying type. Cycle-safe. Non-typealias inputs (and typealiases that don't resolve) are
    /// returned unchanged so callers can still rename the original token to ITS obf.
    private func unwrapTypealias(_ sym: Symbol, in scope: Scope) -> Symbol {
        var current = sym
        var seen = Set<Int>()
        while current.kind == .typealias_, !seen.contains(current.id),
              let target = table.typealiasTarget[current.id],
              let aliasScope = current.scope {
            seen.insert(current.id)
            guard let resolved = typeSymbol(forQualifiedName: target, in: aliasScope) else { break }
            current = resolved
        }
        return current
    }

    /// Look for a typealias/associatedtype declared in any protocol that an enclosing type scope
    /// conforms to. Models the part of Swift name resolution where a conformer sees protocol
    /// typealiases — our scope chain doesn't include conformance, so this fills the gap.
    private func conformanceInheritedTypealias(named name: String, in scope: Scope) -> Symbol? {
        var seenProtocols = Set<Int>()
        var s: Scope? = scope
        while let cur = s {
            defer { s = cur.parent }
            guard cur.kind == .type, let owner = cur.owner else { continue }
            // Extension-declared conformances included (G2) — `extension C: P {}` is a conformance.
            for inh in table.conformanceNames(of: owner) {
                for proto in table.types(named: inh) where proto.kind == .protocol {
                    guard !seenProtocols.contains(proto.id) else { continue }
                    seenProtocols.insert(proto.id)
                    guard let inner = Self.innerScope(of: proto) else { continue }
                    for m in inner.symbols
                    where m.name == name && (m.kind == .typealias_ || m.kind == .associatedtype_) {
                        return m
                    }
                }
            }
        }
        return nil
    }

    /// Resolves a possibly-qualified type name string ("Foo" or "Foo.Bar.Baz") to a Symbol.
    /// Strips optional `?` / `!` suffixes. Returns nil if any segment doesn't match.
    public func typeSymbol(forQualifiedName rawName: String, in scope: Scope) -> Symbol? {
        // Strip trailing `?` / `!` for optionals/force-unwraps that may have leaked into the text.
        var name = rawName
        while name.hasSuffix("?") || name.hasSuffix("!") {
            name = String(name.dropLast())
        }
        // A COLLECTION type names no declaration in our table: `[T]` is Array<T> (a stdlib type),
        // NOT `T`. This function answers "which DECLARATION does this name refer to", and its
        // result is fed straight into member lookup — so returning the Element for an array made
        // `items.count` (where `items: [Item]` and `Item` declares `count`) resolve to `Item.count`
        // and rewrite the use-site to that member's obf ⇒ "value of type '[Item]' has no member
        // '<obf>'". A wrong rename, invisible to RollbackPass (both ends renamed consistently, no
        // original survives). Dictionaries were already fail-closed here; arrays were not, and the
        // plausible-looking substitution is exactly what hid the flaw (B-FIX-28).
        //
        // Callers that genuinely want the ELEMENT ask for it explicitly — `extractElement` /
        // `dictionaryValueType` (HOF closure typing, subscript results, B-FIX-22). Fail closed here
        // so member access on a collection stays unresolved (no rename) instead of guessing.
        if name.hasPrefix("[") && name.hasSuffix("]") { return nil }
        // Strip generic argument clauses per segment (`Box<Foo>` → `Box`, `Outer<T>.Inner` →
        // `Outer.Inner`) so a member access through a generic-typed value resolves to the BASE
        // type's scope. Element substitution beyond this (typing `box.value` as the concrete `T`)
        // is still not modelled — the documented partial-generics limit. Same prefix-before-`<`
        // technique already used in `Protector.bareName`.
        let segments = name.split(separator: ".").map { seg -> String in
            var s = String(seg)
            if let lt = s.firstIndex(of: "<") { s = String(s[..<lt]) }
            return s
        }
        guard let firstSeg = segments.first, !firstSeg.isEmpty else { return nil }
        // First segment: prefer scope chain (catches associatedtype / nested in same file).
        var current: Symbol?
        if let s = scope.lookup(name: firstSeg), s.kind.isTypeLike {
            current = s
        } else if let g = preferredConcreteType(named: firstSeg) {
            current = g
        } else {
            current = conformanceInheritedTypealias(named: firstSeg, in: scope)
        }
        guard var cur = current else { return nil }
        cur = unwrapTypealias(cur, in: scope)
        // Walk dotted segments down the inner scopes — unwrap typealias at each step so a chain
        // like `Foo.T.Bar` (where T is a typealias) follows T to its target's inner scope.
        for seg in segments.dropFirst() {
            guard let inner = Self.innerScope(of: cur),
                  let next = inner.member(named: seg) else { return nil }
            cur = unwrapTypealias(next, in: scope)
        }
        return cur
    }

    // MARK: - Closure parameter inference

    /// Resolve `$N` inside a closure passed to a known HOF.
    /// Walks: `ref` → enclosing ClosureExpr → enclosing FunctionCallExpr → look up HOF in registry.
    /// If the closure is the HOF's expected closure-argument and `N` < expected param count,
    /// produces the type of that closure parameter (typically the receiver's Element).
    func inferClosureParamType(at index: Int, from ref: DeclReferenceExprSyntax,
                               in scope: Scope) -> (name: String, scope: Scope)? {
        // Positional `$N` binds to the INNERMOST enclosing closure — each closure has its own `$0`,
        // so (unlike a named param) it is NOT visible from an outer closure. Don't walk outward.
        guard let closure = Self.enclosingClosure(of: Syntax(ref)),
              let (call, closureArgIndex) = hofContext(of: closure) else {
            return nil
        }
        return hofClosureParamType(call: call, closureArgIndex: closureArgIndex, paramIndex: index,
                                   closureArity: Self.closureArity(of: closure), in: scope)
    }

    /// Resolve a named closure parameter like `arr.filter { item in item.x }` where the inner
    /// reference is `item`. Walks up to ClosureExpr, finds the param by name in its signature,
    /// determines its index, delegates to the HOF inference.
    func inferNamedClosureParamType(name: String, from ref: DeclReferenceExprSyntax,
                                    in scope: Scope) -> (name: String, scope: Scope)? {
        // A NAMED closure parameter is lexically visible throughout the closure body, INCLUDING
        // inside nested (non-HOF) closures — e.g. `arr.map { row in cb = { use(row.x) } }`, where
        // `row.x` sits in the escaping `cb` closure. So walk up through EVERY enclosing closure
        // (not only HOF-argument ones) and, for the closure that actually DECLARES `name`, type it
        // from the HOF call that closure is an argument of. The old code stopped at the first
        // non-HOF closure (enclosingHOFContext returned nil there) and never reached the outer HOF
        // param → the member use-site stayed un-renamed while its decl was renamed (a desync).
        var node: Syntax = Syntax(ref)
        while let closure = Self.enclosingClosure(of: node) {
            if let signature = closure.signature,
               let paramClause = signature.parameterClause,
               let idx = parameterIndex(named: name, in: paramClause) {
                // This closure introduces `name`; it can be typed only if it is a HOF argument.
                guard let (call, closureArgIndex) = hofContext(of: closure) else { return nil }
                return hofClosureParamType(call: call, closureArgIndex: closureArgIndex, paramIndex: idx,
                                           closureArity: Self.closureArity(of: closure), in: scope)
            }
            guard let parent = closure.parent else { return nil }
            node = parent
        }
        return nil
    }

    /// How many values `cl`'s parameter list BINDS — the number a tuple element would have to be
    /// destructured into (B-FIX-38).
    ///
    /// An explicit list answers directly. An implicit one is measured by the highest `$N` the body
    /// uses, because that is the only syntactic evidence of arity there is: `{ print($0, $1) }` over
    /// `enumerated()` binds two values, `{ $0.element }` binds one (the whole tuple). Getting this
    /// wrong cannot produce a wrong type — the caller destructures only when the component count
    /// EQUALS the arity — it can only cost a rename.
    ///
    /// `$N` inside a NESTED closure belongs to that closure, so those are not counted.
    static func closureArity(of cl: ClosureExprSyntax) -> Int {
        if let params = cl.signature?.parameterClause {
            if let list = params.as(ClosureShorthandParameterListSyntax.self) { return list.count }
            if let list = params.as(ClosureParameterClauseSyntax.self) { return list.parameters.count }
        }
        var maxIndex = -1
        func scan(_ node: Syntax) {
            for child in node.children(viewMode: .sourceAccurate) {
                if child.is(ClosureExprSyntax.self) { continue }   // its own `$0`
                if let ref = child.as(DeclReferenceExprSyntax.self) {
                    let text = ref.baseName.text
                    if text.hasPrefix("$"), let n = Int(text.dropFirst()) { maxIndex = max(maxIndex, n) }
                }
                scan(child)
            }
        }
        scan(Syntax(cl.statements))
        return maxIndex + 1
    }

    /// Innermost `ClosureExpr` strictly enclosing `node` (nil if `node` is not inside a closure).
    private static func enclosingClosure(of node: Syntax) -> ClosureExprSyntax? {
        var current: Syntax? = node.parent
        while let n = current {
            if let cl = n.as(ClosureExprSyntax.self) { return cl }
            current = n.parent
        }
        return nil
    }

    /// If `cl` is the closure-argument of a function call, return that call and the closure's
    /// argument index within it. Handles the three closure-as-argument shapes:
    ///   - the call's primary `trailingClosure`
    ///   - a regular `LabeledExpr` argument inside the call's `arguments` list
    ///   - an additional trailing closure (SwiftUI `Button {} label: {}` — the second trailing)
    /// Returns nil when the closure is NOT a call argument (e.g. it is the RHS of an assignment or
    /// a stored property's value) — such a closure's params cannot be HOF-typed.
    private func hofContext(of cl: ClosureExprSyntax) -> (FunctionCallExprSyntax, Int)? {
        // Primary trailing closure.
        if let call = cl.parent?.as(FunctionCallExprSyntax.self), call.trailingClosure?.id == cl.id {
            return (call, call.arguments.count)
        }
        // Labeled argument inside arguments list.
        if let labeled = cl.parent?.as(LabeledExprSyntax.self),
           let list = labeled.parent?.as(LabeledExprListSyntax.self),
           let call = list.parent?.as(FunctionCallExprSyntax.self) {
            let idx = list.enumerated().first(where: { $0.element.id == labeled.id })?.offset ?? 0
            return (call, idx)
        }
        // Additional trailing closure (e.g. `Button {} label: { ... }`).
        if let elem = cl.parent?.as(MultipleTrailingClosureElementSyntax.self),
           let elemList = elem.parent?.as(MultipleTrailingClosureElementListSyntax.self),
           let call = elemList.parent?.as(FunctionCallExprSyntax.self) {
            // Index = args.count + 1 (primary trailing) + position-in-additionalTrailingList.
            let primaryOffset = (call.trailingClosure != nil) ? 1 : 0
            let elemIdx = elemList.enumerated().first(where: { $0.element.id == elem.id })?.offset ?? 0
            return (call, call.arguments.count + primaryOffset + elemIdx)
        }
        return nil
    }

    /// Look up the HOF in the registry by callee method name, verify closureArgIndex matches,
    /// extract the closure-param type per `closureParamSources[paramIndex]`.
    ///
    /// Two HOF shapes are handled:
    ///   - **Method HOF**: `arr.filter { ... }` — callee is `MemberAccess(receiver, method)`.
    ///   - **Init-style HOF**: `ForEach(arr) { ... }` — callee is `DeclRef(TypeName)`, receiver
    ///     comes from the data-argument's position.
    private func hofClosureParamType(
        call: FunctionCallExprSyntax,
        closureArgIndex: Int,
        paramIndex: Int,
        closureArity: Int,
        in scope: Scope
    ) -> (name: String, scope: Scope)? {
        // Method-style: `receiver.method(...)`
        if let memberCall = call.calledExpression.as(MemberAccessExprSyntax.self),
           let receiver = memberCall.base {
            let methodName = Self.stripBackticks(memberCall.declName.baseName.text)
            if let sig = HOFRegistry.signature(forMethod: methodName),
               sig.closureArgIndex == closureArgIndex {
                if let t = destructuredElement(sources: sig.closureParamSources, paramIndex: paramIndex,
                                               closureArity: closureArity, receiver: receiver, in: scope) {
                    return t
                }
                if paramIndex < sig.closureParamSources.count {
                    return resolveSource(sig.closureParamSources[paramIndex], call: call, receiver: receiver, in: scope)
                }
            }
        }
        // Init-style: `TypeName(data, ...) { ... }`
        if let ref = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            let typeName = Self.stripBackticks(ref.baseName.text)
            if let initSig = HOFRegistry.initSignature(forType: typeName, closureAt: closureArgIndex),
               initSig.sequenceArgIndex < call.arguments.count {
                let arg = call.arguments[call.arguments.index(call.arguments.startIndex, offsetBy: initSig.sequenceArgIndex)]
                if let t = destructuredElement(sources: initSig.closureParamSources, paramIndex: paramIndex,
                                               closureArity: closureArity, receiver: arg.expression, in: scope) {
                    return t
                }
                if paramIndex < initSig.closureParamSources.count {
                    return resolveSource(initSig.closureParamSources[paramIndex], call: call, receiver: arg.expression, in: scope)
                }
            }
        }
        // User-defined HOF fallback (B-FIX-2): no stdlib registry entry, but the callee is one of
        // OUR functions/methods whose param at `closureArgIndex` is a function type — type the
        // closure's params from that declared signature. Generalizes closure-param inference to any
        // function, no per-HOF hardcoding.
        //
        // The recorded input type is written in the CALLEE's scope, so it carries that scope for the
        // same reason the element does above: `func each(_ f: (Row) -> Void)` declared inside a type
        // that also declares `Row` names a type invisible from the call site.
        //
        // `closureArgIndex` is the closure's position among the CALL's arguments; the side table is
        // keyed by the callee's PARAMETER position. They diverge as soon as the call omits a
        // defaulted parameter (`fetch(from: rows) { … }` against `fetch(from:tag:completion:)` puts
        // the closure at argument 1 and parameter 2), so the mapping has to come from the same
        // label-matching walk that selected the callee (B-FIX-36).
        if let callee = calleeCallable(for: call, in: scope),
           let paramPos = ArgumentLabelMatch.parameterIndex(ofArgument: closureArgIndex, for: callee,
                                                            call: call, in: table),
           let inputs = table.functionParamClosureInput[callee.id]?[paramPos],
           paramIndex < inputs.count, !inputs[paramIndex].isEmpty {
            return (inputs[paramIndex], callee.scope ?? scope)
        }
        return nil
    }

    /// The type of closure parameter `paramIndex` when the closure DESTRUCTURES a tuple element
    /// (B-FIX-38): the HOF hands the closure ONE value, the closure names several, and each name
    /// binds one component — `rows.enumerated().forEach { offset, row in … }`,
    /// `dict.forEach { key, value in … }`.
    ///
    /// nil means "not a destructuring", and the caller falls back to the ordinary per-source path.
    /// Three conditions gate it, and each one is what keeps a mis-read from becoming a wrong type:
    ///   - the HOF supplies exactly ONE closure value (a 2-source HOF like `sorted` hands the whole
    ///     element to BOTH parameters, which is a different shape);
    ///   - the closure binds more than one name;
    ///   - the element parses as a tuple of EXACTLY that many components.
    /// Anything else keeps today's behaviour, so the worst outcome remains a missed rename.
    private func destructuredElement(
        sources: [HOFRegistry.HOFParamSource],
        paramIndex: Int,
        closureArity: Int,
        receiver: ExprSyntax,
        in scope: Scope
    ) -> (name: String, scope: Scope)? {
        guard sources.count == 1, case .element = sources[0], closureArity > 1,
              paramIndex < closureArity else { return nil }
        guard let info = receiverTypeInfo(of: receiver, in: scope) else { return nil }
        // Same typealias expansion `resolveSource` does — a collection name resolves to no
        // declaration, so an alias for one has to be followed textually.
        let expanded = expandedTypeName(info.name, in: info.declScope)
        // The ITERATION element, which is dictionary-aware: iterating `[K: V]` yields
        // `(key: K, value: V)` even though subscripting it yields `V`.
        guard let element = CollectionMemberRegistry.iterationElement(of: expanded.name),
              let components = TupleTypeName.components(of: element),
              components.count == closureArity else { return nil }
        return (components[paramIndex], expanded.scope)
    }

    /// Resolve the callee of a function call to a unique callable Symbol by name + argument labels.
    /// Handles free functions (DeclRef, scope-chain then global) and methods (`recv.method`). Returns
    /// nil on ambiguity — callers must not guess.
    ///
    /// Label matching goes through the ONE shared rule (`ArgumentLabelMatch`, B-FIX-36). A private
    /// count-equality copy used to live here, and it is the reason a user-defined HOF called with a
    /// TRAILING closure never found its callee: `loader.fetch(from: rows) { row in … }` presents the
    /// labels `["from", nil]` while `fetch(from:completion:)` declares `["from", "completion"]`, so
    /// the only candidate was eliminated, `functionParamClosureInput` was never consulted, and every
    /// member read through `row` survived while its declaration renamed.
    private func calleeCallable(for call: FunctionCallExprSyntax, in scope: Scope) -> Symbol? {
        let callLabels = ArgumentLabelMatch.labels(of: call)
        let trailingStart = ArgumentLabelMatch.trailingStart(of: call)
        func labelsMatch(_ sym: Symbol) -> Bool {
            ArgumentLabelMatch.matches(sym, callLabels: callLabels, trailingStart: trailingStart, in: table)
        }
        func isCallable(_ k: SymbolKind) -> Bool { k == .function || k == .method }

        if let ref = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            let name = Self.stripBackticks(ref.baseName.text)
            var matches: [Symbol] = []
            var seen = Set<Int>()
            var s: Scope? = scope
            while let cur = s {
                for sym in cur.symbols where sym.name == name && isCallable(sym.kind) && labelsMatch(sym) {
                    if seen.insert(sym.id).inserted { matches.append(sym) }
                }
                s = cur.parent
            }
            if matches.count == 1 { return matches[0] }
            if matches.isEmpty {
                let global = table.callables(named: name).filter { labelsMatch($0) }
                if global.count == 1 { return global[0] }
            }
            return nil
        }
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self), let recv = member.base {
            let methodName = Self.stripBackticks(member.declName.baseName.text)
            guard let recvType = typeSymbol(of: recv, in: scope),
                  let recvScope = canonicalInnerScope(of: recvType) else { return nil }
            let cands = recvScope.members(named: methodName).filter { isCallable($0.kind) && labelsMatch($0) }
            if cands.count == 1 { return cands[0] }
        }
        return nil
    }

    /// The type a closure parameter takes from an HOF's `HOFParamSource`, PLUS the scope that type
    /// name was WRITTEN in.
    ///
    /// The scope half is B-FIX-23 applied to closure-parameter inference: a receiver's element type
    /// is spelled in the scope of the declaration the receiver came from, so a nested type spelled
    /// unqualified there (`E1.E2.allCases` yields the element `E2`, written inside `E1`) is
    /// INVISIBLE from the use-site. Resolving it against the use-site's scope — which is what every
    /// consumer did while this returned a bare string — finds nothing, `$0` stays untyped, and every
    /// member reached through the closure parameter (`$0.getTitle(…)`, `.c9`, `case .c1`) is left
    /// original while its declaration renames. That is the desync class, and a red build wherever a
    /// shield blocks the rollback rescue.
    private func resolveSource(
        _ source: HOFRegistry.HOFParamSource,
        call: FunctionCallExprSyntax,
        receiver: ExprSyntax,
        in scope: Scope
    ) -> (name: String, scope: Scope)? {
        switch source {
        case .element:
            guard let info = receiverTypeInfo(of: receiver, in: scope) else { return nil }
            // Expand a typealias to a composite (`typealias Items = [Item]`) before parsing out the
            // element: a collection name resolves to no declaration (B-FIX-28), so the alias has to
            // be followed textually — the same step `collectionMemberResult` takes.
            let expanded = expandedTypeName(info.name, in: info.declScope)
            guard let element = Self.extractElement(from: expanded.name) else { return nil }
            return (element, expanded.scope)
        case .argType(let argIdx):
            guard argIdx < call.arguments.count else { return nil }
            let arg = call.arguments[call.arguments.index(call.arguments.startIndex, offsetBy: argIdx)]
            guard let sym = typeSymbol(of: arg.expression, in: scope) else { return nil }
            // Qualified, resolved in the symbol's own declaring scope — a bare nested name would be
            // scope-trapped exactly like the element above.
            return (TypeInferencePass.qualifiedName(of: sym), sym.scope ?? scope)
        }
    }

    // MARK: - Public HOF helper for KeyPath inference

    /// Returns the type Symbol that an argument at `argIndex` of `call` should resolve to,
    /// for HOFs that accept a closure or key path in that slot (`filter`, `map`, `ForEach`, etc.).
    /// E.g., for `arr.filter(\.flag)`, this returns the Element type of `arr` so callers can
    /// resolve `flag` as a property of that type.
    public func hofElementType(
        forCallArgument call: FunctionCallExprSyntax,
        argIndex: Int,
        in scope: Scope
    ) -> Symbol? {
        // Method-style: `receiver.method(...)`
        if let memberCall = call.calledExpression.as(MemberAccessExprSyntax.self),
           let receiver = memberCall.base {
            let methodName = Self.stripBackticks(memberCall.declName.baseName.text)
            if let sig = HOFRegistry.signature(forMethod: methodName),
               sig.closureArgIndex == argIndex,
               let firstSource = sig.closureParamSources.first,
               let t = resolveSource(firstSource, call: call, receiver: receiver, in: scope) {
                return typeSymbol(forQualifiedName: t.name, in: t.scope)
            }
        }
        // Init-style: `TypeName(data, ...) { ... }`
        if let ref = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            let typeName = Self.stripBackticks(ref.baseName.text)
            if let initSig = HOFRegistry.initSignature(forType: typeName, closureAt: argIndex),
               let firstSource = initSig.closureParamSources.first,
               initSig.sequenceArgIndex < call.arguments.count {
                let receiver = call.arguments[call.arguments.index(
                    call.arguments.startIndex, offsetBy: initSig.sequenceArgIndex
                )].expression
                if let t = resolveSource(firstSource, call: call, receiver: receiver, in: scope) {
                    return typeSymbol(forQualifiedName: t.name, in: t.scope)
                }
            }
        }
        return nil
    }

    /// The textual type name of a receiver expression (declared type first — we want `[Purchase]`,
    /// not `Purchase` after type lookup) TOGETHER WITH the scope that name should be RESOLVED in:
    /// the declaring scope of the symbol whose type it is. A member's stored type is written relative
    /// to where it was declared (a bare nested name like `S3`/`[S1]` on `enum E1`'s member is
    /// invisible from the use-site), so a consumer that resolves the name to a Symbol must use this
    /// scope, not the use-site's.
    ///
    /// The name and the scope are deliberately INSEPARABLE — there is no string-only variant to
    /// call. The former `receiverTypeName` was exactly that variant, and dropping the scope through
    /// it is how HOF closure-parameter inference lost `E1.E2` (see `resolveSource`).
    ///
    /// This is the ONE place that answers "what is the WRITTEN type name of this expression" — with
    /// the brackets intact, unlike `typeSymbol(of:)`, which resolves to a declaration and therefore
    /// answers nil for every collection (B-FIX-28). Subscript results, HOF element typing, the
    /// for-in element inference and stdlib-collection chains all funnel through it, so a new
    /// expression shape is taught here once rather than at each consumer.
    public func receiverTypeInfo(of expr: ExprSyntax, in scope: Scope) -> (name: String, declScope: Scope)? {
        // Wrappers that don't change the named type (`items?`, `items!`, `try f()`, `await f()`).
        if let opt = expr.as(OptionalChainingExprSyntax.self) { return receiverTypeInfo(of: opt.expression, in: scope) }
        if let force = expr.as(ForceUnwrapExprSyntax.self) { return receiverTypeInfo(of: force.expression, in: scope) }
        if let tryE = expr.as(TryExprSyntax.self) { return receiverTypeInfo(of: tryE.expression, in: scope) }
        if let awaitE = expr.as(AwaitExprSyntax.self) { return receiverTypeInfo(of: awaitE.expression, in: scope) }
        if let ref = expr.as(DeclReferenceExprSyntax.self) {
            let name = Self.stripBackticks(ref.baseName.text)
            // `$x` / `_x` projection / storage — same wrapped type as `x`.
            var lookupName = name
            if lookupName.hasPrefix("$") || lookupName.hasPrefix("_") {
                lookupName = String(lookupName.dropFirst())
            }
            // All three type sources (B-FIX-37). This branch is the one that must keep a collection
            // name intact, so a binding typed `[Row]` reaches element extraction, subscript results
            // and the collection-member registry instead of dying at a missing `declaredType`.
            return bareValueTypeInfo(named: lookupName, from: ref, in: scope)
                .map { (name: $0.name, declScope: $0.scope) }
        }
        if let member = expr.as(MemberAccessExprSyntax.self), let base = member.base {
            let memberName = Self.stripBackticks(member.declName.baseName.text)
            // Special: `Type.allCases` (CaseIterable) → `[Type]`.
            // Equally common: `Type.cases` if user-defined sometimes. Stick to .allCases.
            if memberName == "allCases",
               let baseTypeSym = typeSymbol(of: base, in: scope) {
                return ("[\(baseTypeSym.name)]", baseTypeSym.scope ?? scope)
            }
            // General: resolve base, look up member's declared type.
            if let baseSym = typeSymbol(of: base, in: scope),
               let baseScope = canonicalInnerScope(of: baseSym),
               let memberSym = baseScope.member(named: memberName),
               let t = table.declaredType[memberSym.id] {
                return (t, memberSym.scope ?? scope)
            }
            // Stdlib collection member (`items.first`, `dict.values`) — the receiver names no
            // declaration, so the general path above cannot answer it (B-FIX-30).
            return collectionMemberResult(member: memberName, receiver: base, in: scope)
        }
        // `items.sorted()` / `items.first(where:)` — the same members in CALL form; then a call to
        // one of OUR callables, whose declared return type names the receiver of the next step
        // (`makeItems()[0].m`, `makeItems().map { $0.m }`).
        if let call = expr.as(FunctionCallExprSyntax.self) {
            if let m = call.calledExpression.as(MemberAccessExprSyntax.self), let base = m.base,
               let result = collectionMemberResult(member: Self.stripBackticks(m.declName.baseName.text),
                                                   receiver: base, in: scope) {
                return result
            }
            if let callee = calleeCallable(for: call, in: scope),
               let ret = table.functionReturnType[callee.id] {
                return (ret, callee.scope ?? scope)
            }
        }
        return nil
    }

    /// Result type of `receiver.member` when `receiver` is a stdlib collection whose member has a
    /// modelled result shape (`CollectionMemberRegistry`). The name is returned with the RECEIVER's
    /// declaring scope: the element name was written there (B-FIX-23 discipline). Fail-closed —
    /// an unparsable receiver or an unmodelled member yields nil, never a guessed type.
    private func collectionMemberResult(member: String, receiver: ExprSyntax,
                                        in scope: Scope) -> (name: String, declScope: Scope)? {
        guard let info = receiverTypeInfo(of: receiver, in: scope) else { return nil }
        let expanded = expandedTypeName(info.name, in: info.declScope)
        guard let result = CollectionMemberRegistry.resultTypeName(member: member,
                                                                   receiverType: expanded.name) else { return nil }
        return (result, expanded.scope)
    }

    /// A written type name with any typealias to a COMPOSITE type expanded (`typealias Items =
    /// [Item]` → `[Item]`), together with the scope the expansion was written in. A collection name
    /// resolves to no declaration (B-FIX-28), so an alias for one cannot be followed through
    /// `unwrapTypealias` — it has to be expanded textually, exactly as `TypeNameEquivalence` does.
    /// Bounded against cyclic aliases; a name that is not such an alias comes back unchanged.
    public func expandedTypeName(_ raw: String, in scope: Scope) -> (name: String, scope: Scope) {
        var name = raw
        var declScope = scope
        for _ in 0..<4 {
            guard let sym = typeSymbol(forQualifiedName: name, in: declScope), sym.kind == .typealias_,
                  let target = table.typealiasTarget[sym.id], target != name else { break }
            name = target
            declScope = sym.scope ?? declScope
        }
        return (name, declScope)
    }

    // MARK: - Subscript result typing

    /// Static type of a subscript expression `base[args]`:
    ///   1. base is a collection/optional (`[T]`, `Array<T>`, `T?`, …) → its Element/Wrapped type;
    ///   2. base is a Dictionary (`[K: V]`, `Dictionary<K, V>`)         → its Value type;
    ///   3. base is a LOCAL type declaring a `subscript`                → that subscript's DECLARED
    ///      return type (matched by argument labels; an unambiguous match required).
    /// Anything else — an external non-collection subscript we have no signature for, a generic
    /// element we can't substitute, or an unrecognised base shape — returns nil. We NEVER guess a
    /// subscript result: a wrong type here would drive a wrong rename RollbackPass can't catch.
    private func subscriptResultType(of sub: SubscriptCallExprSyntax, in scope: Scope) -> Symbol? {
        // The base's RAW declared type string (brackets preserved — `typeSymbol(of:)` eagerly
        // unwraps `[T]`→`T`, hiding the collection-ness we must branch on) PLUS the scope that string
        // must resolve in (the base member's declaring scope — a bare nested element name like `S1`
        // is invisible from the use-site). nil ⇒ unknown base ⇒ bail.
        guard let info = receiverTypeInfo(of: sub.calledExpression, in: scope) else { return nil }
        let raw = info.name, declScope = info.declScope
        // 1. Collection / Optional element (same parser HOF closure-typing uses — one source of truth).
        if let elem = Self.extractElement(from: raw) {
            return typeSymbol(forQualifiedName: elem, in: declScope)
        }
        // 2. Dictionary value (extractElement bails on dicts by design — a dict's Element is (K,V),
        //    but its SUBSCRIPT yields V?).
        if let value = Self.dictionaryValueType(from: raw) {
            return typeSymbol(forQualifiedName: value, in: declScope)
        }
        // 3. Local type with a recorded subscript signature → its declared return type (written in the
        //    type's own scope, so resolve there).
        if let baseSym = typeSymbol(forQualifiedName: raw, in: declScope),
           let ret = subscriptReturnType(ofType: baseSym, forCall: sub) {
            return typeSymbol(forQualifiedName: ret, in: canonicalInnerScope(of: baseSym) ?? declScope)
        }
        return nil
    }

    /// Declared return type of the `subscript` on `typeSym` selected by `call`'s argument labels.
    /// Requires an unambiguous outcome: a single label-matching overload, or several that all agree
    /// on the return type. nil ⇒ no/ambiguous match ⇒ caller bails (never guesses).
    private func subscriptReturnType(ofType typeSym: Symbol, forCall call: SubscriptCallExprSyntax) -> String? {
        let sigs = table.subscriptSignatures[typeSym.id] ?? []
        guard !sigs.isEmpty else { return nil }
        let callLabels: [String] = call.arguments.map { arg in
            arg.label.map { Self.stripBackticks($0.text) } ?? "_"
        }
        let matches = sigs.filter { $0.labels == callLabels }
        guard let first = matches.first else { return nil }
        return matches.allSatisfy { $0.returnType == first.returnType } ? first.returnType : nil
    }

    /// Key type of a Dictionary type string: `[K: V]` → "K", `Dictionary<K, V>` → "K". Mirror of
    /// `dictionaryValueType` (same balanced scan, same fail-closed contract) — needed because a
    /// shorthand `.case` in a dictionary LITERAL takes its context from the Key on one side of the
    /// `:` and from the Value on the other.
    static func dictionaryKeyType(from typeName: String) -> String? {
        var name = typeName.trimmingCharacters(in: .whitespaces)
        while name.hasSuffix("?") || name.hasSuffix("!") { name = String(name.dropLast()) }
        if name.hasPrefix("[") && name.hasSuffix("]") {
            let inner = String(name.dropFirst().dropLast())
            guard let idx = topLevelIndex(of: ":", in: inner) else { return nil }
            let key = String(inner[..<idx]).trimmingCharacters(in: .whitespaces)
            return key.isEmpty ? nil : key
        }
        let prefix = "Dictionary<"
        if name.hasPrefix(prefix) && name.hasSuffix(">") {
            let inner = String(name.dropFirst(prefix.count).dropLast())
            guard let idx = topLevelIndex(of: ",", in: inner) else { return nil }
            let key = String(inner[..<idx]).trimmingCharacters(in: .whitespaces)
            return key.isEmpty ? nil : key
        }
        return nil
    }

    /// Value type of a Dictionary type string: `[K: V]` → "V", `Dictionary<K, V>` → "V". Uses a
    /// balanced scan for the TOP-LEVEL separator so nested generics/brackets don't mis-split. Returns
    /// nil (fail-closed) on anything it can't parse cleanly — a wrong value type would drive a wrong rename.
    static func dictionaryValueType(from typeName: String) -> String? {
        var name = typeName.trimmingCharacters(in: .whitespaces)
        while name.hasSuffix("?") || name.hasSuffix("!") { name = String(name.dropLast()) }
        if name.hasPrefix("[") && name.hasSuffix("]") {
            let inner = String(name.dropFirst().dropLast())
            guard let idx = topLevelIndex(of: ":", in: inner) else { return nil }
            let value = String(inner[inner.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        let prefix = "Dictionary<"
        if name.hasPrefix(prefix) && name.hasSuffix(">") {
            let inner = String(name.dropFirst(prefix.count).dropLast())
            guard let idx = topLevelIndex(of: ",", in: inner) else { return nil }
            let value = String(inner[inner.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// First index of `target` in `s` at bracket/angle/paren depth 0 (nil if none). Keeps a nested
    /// generic key like `[Wrap<A, B>: V]` from splitting on the inner comma/colon.
    /// Shared with `TypeNameEquivalence` (one balanced-scan implementation, B-FIX-27).
    static func topLevelIndex(of target: Character, in s: String) -> String.Index? {
        var depth = 0
        for i in s.indices {
            let c = s[i]
            if c == "[" || c == "<" || c == "(" { depth += 1 }
            else if c == "]" || c == ">" || c == ")" { depth = max(0, depth - 1) }
            else if c == target && depth == 0 { return i }
        }
        return nil
    }

    private func parameterIndex(named name: String, in clause: ClosureSignatureSyntax.ParameterClause) -> Int? {
        switch clause {
        case .parameterClause(let params):
            for (idx, p) in params.parameters.enumerated() {
                let pName = (p.secondName ?? p.firstName).text
                if Self.stripBackticks(pName) == name { return idx }
            }
        case .simpleInput(let shorthand):
            for (idx, p) in shorthand.enumerated() {
                if Self.stripBackticks(p.name.text) == name { return idx }
            }
        }
        return nil
    }

    /// When multiple types share a simple name (e.g. `Item` declared once as associatedtype
    /// in protocol P, once as typealias in conformer C, once as nested struct in container D,
    /// or `P1` declared in three different targets), pick the most appropriate one:
    /// 1. **Same module as the use-site** wins (Swift resolves unqualified names to the local
    ///    module first). This disambiguates same-named types across targets.
    /// 2. Concrete types (class/struct/enum/protocol) win over typealias/associatedtype.
    /// 3. Among ties, prefer the one with a non-empty inner scope.
    /// Resolve a bare type name to its best symbol, module-aware. When several same-named
    /// top-level candidates survive (an inherently cross-target situation), and a use-site offset
    /// + index are available, the compiler's USR at that use-site picks the exact one — removing
    /// the syntactic guess that is the root of the wrong-rename class (A4).
    func preferredConcreteType(named name: String, at useSiteOffset: Int? = nil) -> Symbol? {
        if let cached = preferredCache[name] { return cached }
        let (result, ambiguous) = computePreferred(named: name, at: useSiteOffset)
        // Only memoize a location-independent answer; an ambiguous name is recomputed per use-site.
        if !ambiguous { preferredCache[name] = result }
        return result
    }

    private func computePreferred(named name: String, at useSiteOffset: Int?)
        -> (symbol: Symbol?, ambiguous: Bool)
    {
        let all = table.types(named: name)
        guard !all.isEmpty else { return (nil, false) }

        // A bare, unqualified name resolved through the GLOBAL type table must be a TOP-LEVEL
        // type. Nested types are reachable only lexically (via `scope.lookup`, which every caller
        // tries first) or through a qualified chain — never as a bare global name. Resolving a
        // bare name to some unrelated class's nested type (e.g. `enum Result` nested in a class)
        // produced `Cannot find type '<obf>' in scope`, because that obf exists only as
        // `Owner.<obf>`. It also stole bare references meant for a stdlib type of the same name
        // (`Result`, `Box`, …). Invariant: a bare global type name resolves only to a top-level type.
        let topLevel = all.filter { $0.scope?.kind == .file }
        guard !topLevel.isEmpty else { return (nil, false) }
        if topLevel.count == 1 { return (topLevel.first, false) }

        // Narrow to same-module candidates first, if any exist.
        var pool = topLevel
        if let mod = preferredModule {
            let sameModule = topLevel.filter { $0.module.name == mod }
            if !sameModule.isEmpty { pool = sameModule }
        }

        let concrete = pool.filter {
            switch $0.kind { case .class, .struct, .enum, .protocol: return true; default: return false }
        }
        let candidates = concrete.isEmpty ? pool : concrete
        if candidates.count == 1 { return (candidates.first, false) }

        // >1 same-named candidate survives module narrowing — inherently a cross-target situation
        // (Swift forbids same-name top-level redeclaration within one module). A4: if the compiler
        // recorded a USR at the use-site that matches exactly one candidate's decl-USR, that is the
        // ground-truth pick — this removes the syntactic guess that is the wrong-rename root cause.
        if let picked = usrDisambiguatedCandidate(candidates, at: useSiteOffset) {
            return (picked, true)   // ambiguous ⇒ never cache (the answer depends on the use-site)
        }

        // No index help (off / unindexed / no unique match): the syntactic heuristic, as before.
        let fallback = candidates.first { Self.innerScope(of: $0)?.symbols.isEmpty == false } ?? candidates.first
        return (fallback, true)
    }

    /// Among same-named `candidates`, the single one whose decl-USR equals the USR the compiler
    /// recorded at `useSiteOffset`. Returns nil — so the caller fails closed to the syntactic
    /// heuristic — when the index is off, the use-site is unindexed, or the match isn't unique.
    private func usrDisambiguatedCandidate(_ candidates: [Symbol], at useSiteOffset: Int?) -> Symbol? {
        guard let offset = useSiteOffset,
              let ctx = indexContext,
              let path = useSiteFilePath,
              let converter = useSiteConverter else { return nil }
        let loc = converter.location(for: AbsolutePosition(utf8Offset: offset))
        guard let useSiteUSR = ctx.useSiteUSR(file: path, line: loc.line, column: loc.column) else { return nil }

        // Fast path: the use-site USR is exactly a candidate's decl-USR (bare type references).
        let exact = candidates.filter { ctx.usrBySymbolId[$0.id] == useSiteUSR }
        if exact.count == 1 { return exact.first }

        // Constructor calls bind the use-site to the type's `init` USR, not the type USR — but its
        // mangling still names the module. Same-named top-level candidates are always in DISTINCT
        // modules (Swift forbids same-module redeclaration), so a unique module match IS the answer.
        // Match the use-site USR's REAL module against each candidate's USR-derived real module —
        // NOT `candidate.module.name`, which is the arbitrary `--module` label and may not equal the
        // compiled module name (e.g. `--module App:./Pulse/...` → real module "Pulse").
        if let useMod = ctx.usrIndex.module(ofUSR: useSiteUSR) {
            let byModule = candidates.filter { c in
                guard let cUSR = ctx.usrBySymbolId[c.id],
                      let cMod = ctx.usrIndex.module(ofUSR: cUSR) else { return false }
                return cMod == useMod
            }
            if byModule.count == 1 { return byModule.first }
        }
        return nil
    }

    /// Public module-aware type lookup for callers that just want "the right type symbol for
    /// this name at this use-site". Pass the use-site token offset to engage the USR tiebreak (A4).
    public func resolveType(named name: String, at useSiteOffset: Int? = nil) -> Symbol? {
        preferredConcreteType(named: name, at: useSiteOffset)
    }

    /// Walk from a scope upward to the nearest type scope. Used to resolve `self` / `Self`.
    public static func enclosingTypeScope(of scope: Scope) -> Scope? {
        var s: Scope? = scope
        while let cur = s {
            if cur.kind == .type { return cur }
            s = cur.parent
        }
        return nil
    }

    /// Inner scope of a type symbol AS WRITTEN. A typealias has no inner scope of its own — this
    /// returns nil for one. Most callers actually want `canonicalInnerScope(of:)` below, which
    /// unwraps typealiases to the underlying type before looking up its scope. This raw variant
    /// is kept for the few places that need it (e.g. `preferredConcreteType`'s heuristic that
    /// uses "no inner scope" as a signal the symbol is a typealias / associatedtype).
    public static func innerScope(of typeSym: Symbol) -> Scope? {
        guard let parent = typeSym.scope else { return nil }
        for child in parent.children where child.owner?.id == typeSym.id {
            return child
        }
        return nil
    }

    /// Canonical inner scope — same as `innerScope(of:)` but unwraps typealiases first so a
    /// reference like `Alias.X` resolves `X` in the underlying type's scope. ALL member-resolution
    /// callers should use this; using the raw static `innerScope(of:)` on a typealias returns nil
    /// and silently drops member renames (the desync bug class).
    public func canonicalInnerScope(of typeSym: Symbol) -> Scope? {
        var canonical = typeSym
        if typeSym.kind == .typealias_, let s = typeSym.scope {
            canonical = unwrapTypealias(typeSym, in: s)
        }
        return Self.innerScope(of: canonical)
    }

    public static func stripBackticks(_ s: String) -> String {
        guard s.count >= 2, s.hasPrefix("`"), s.hasSuffix("`") else { return s }
        return String(s.dropFirst().dropLast())
    }

    /// Parse a collection type string and return the element type name.
    /// Handles `[T]`, `Array<T>`, `Set<T>`, `ArraySlice<T>`, `ContiguousArray<T>`, plus
    /// `Optional<T>` / `T?` which (for HOF purposes) expose `Wrapped` as element-equivalent.
    /// Returns nil for unrecognised forms — Dictionaries above all, whose Element is a tuple while
    /// their SUBSCRIPT yields the Value (`CollectionMemberRegistry.iterationElement` is the one that
    /// answers the iteration question).
    public static func extractElement(from typeName: String) -> String? {
        var name = typeName
        while name.hasSuffix("?") || name.hasSuffix("!") {
            name = String(name.dropLast())
        }
        if name.hasPrefix("[") && name.hasSuffix("]") {
            let inner = String(name.dropFirst().dropLast())
            // Only a TOP-LEVEL colon means "dictionary". A tuple element (`[(offset: Int,
            // element: Row)]`, what `enumerated()` yields) carries its colons inside the parens, and
            // the old unbalanced `contains(":")` rejected it — which is why a destructuring closure
            // over `enumerated()` had no element to destructure at all (B-FIX-38).
            if topLevelIndex(of: ":", in: inner) != nil { return nil }
            let elem = inner.trimmingCharacters(in: .whitespaces)
            return elem.isEmpty ? nil : elem
        }
        let collections: [String] = [
            "Array", "Set", "ArraySlice", "ContiguousArray", "Sequence", "Collection",
            "Optional",  // .map / .flatMap on Optional
        ]
        for col in collections {
            let prefix = "\(col)<"
            if name.hasPrefix(prefix) && name.hasSuffix(">") {
                let inner = name.dropFirst(prefix.count).dropLast()
                let elem = inner.trimmingCharacters(in: .whitespaces)
                if !elem.contains(",") && !elem.isEmpty { return elem }
            }
        }
        return nil
    }
}
