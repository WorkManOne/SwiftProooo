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

    /// Injected provider: given a bare value name with NO scope Symbol, returns its static type NAME
    /// if the caller knows it out-of-band. ResolutionVisitor wires this to its optional-binding type
    /// tracker so `typeSymbol(of:)` can type a binding local (`if let acc = makeFoo(); acc.x.y`) that
    /// is not a `declaredType`-carrying Symbol (B-FIX-12). Default nil ⇒ purely syntactic. Safe w.r.t.
    /// the `preferredCache` (name-keyed, top-level types only) because `typeSymbol(of:)` is not cached.
    public var localBindingTypeName: ((String) -> String?)?

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
                var callLabels: [String?] = call.arguments.map { $0.label?.text }
                if call.trailingClosure != nil { callLabels.append(nil) }
                for extra in call.additionalTrailingClosures { callLabels.append(extra.label.text) }
                let methods = recvScope.members(named: methodName)
                    .filter { $0.kind == .method || $0.kind == .function }
                let matching = methods.filter { sym in
                    guard let sLabels = table.functionParamLabels[sym.id],
                          sLabels.count == callLabels.count else { return false }
                    for (ext, cl) in zip(sLabels, callLabels) {
                        if ext == "_" {
                            if cl != nil { return false }
                        } else if ext != cl {
                            return false
                        }
                    }
                    return true
                }
                if matching.count == 1, let ret = table.functionReturnType[matching[0].id] {
                    return typeSymbol(forQualifiedName: ret, in: scope)
                }
            }
        }
        if let ref = expr.as(DeclReferenceExprSyntax.self) {
            let rawName = Self.stripBackticks(ref.baseName.text)
            // Closure shorthand parameter: `$0`, `$1`, ... — resolve via enclosing HOF call.
            // Only matches when the suffix is numeric — otherwise it's `$x` (projected value).
            if rawName.hasPrefix("$"), let idx = Int(rawName.dropFirst()) {
                if let typeName = inferClosureParamType(at: idx, from: ref, in: scope) {
                    return typeSymbol(forQualifiedName: typeName, in: scope)
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
            if let sym = scope.lookup(name: name) {
                if sym.kind.isTypeLike { return unwrapTypealias(sym, in: scope) }
                if let typeName = table.declaredType[sym.id] {
                    return typeSymbol(forQualifiedName: typeName, in: scope)
                }
                // Registered-but-untyped local binding (unannotated closure param, case-let
                // binding): try HOF closure-param inference before giving up — registering the
                // binding for shadow correctness must not disable the typing that previously ran
                // when the name was absent from the scope tree.
                if sym.kind == .parameter,
                   let typeName = inferNamedClosureParamType(name: name, from: ref, in: scope) {
                    return typeSymbol(forQualifiedName: typeName, in: scope)
                }
                return nil
            }
            // Optional-binding local (`if let acc = makeFoo()`) — not a scope Symbol, but the caller
            // (ResolutionVisitor) may know its type out-of-band. Consult the injected provider so a
            // chain `acc.x.y` types `acc` and resolves through it. Returns nil for external types
            // (URL, …) → falls through, leaving external members untouched (B-FIX-12).
            if let provider = localBindingTypeName, let typeName = provider(name) {
                return typeSymbol(forQualifiedName: typeName, in: scope)
            }
            // Maybe `name` is a named closure parameter — find enclosing closure and check.
            if let typeName = inferNamedClosureParamType(name: name, from: ref, in: scope) {
                return typeSymbol(forQualifiedName: typeName, in: scope)
            }
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
            guard let baseSym = typeSymbol(of: base, in: scope),
                  let baseScope = canonicalInnerScope(of: baseSym) else { return nil }
            let memberName = Self.stripBackticks(member.declName.baseName.text)
            guard let memberSym = baseScope.member(named: memberName) else { return nil }
            if memberSym.kind.isTypeLike { return unwrapTypealias(memberSym, in: scope) }
            if let typeName = table.declaredType[memberSym.id] {
                return typeSymbol(forQualifiedName: typeName, in: scope)
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
            if let sym = scope.lookup(name: name), !sym.kind.isTypeLike,
               let t = table.declaredType[sym.id] {
                return Self.unwrapOptionalName(t)
            }
            return nil
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
            for inh in inheritanceNames(of: owner) {
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

    private func inheritanceNames(of sym: Symbol) -> [String] {
        let v = TR_InheritanceCollector(targetOffset: sym.declOffset)
        v.walk(sym.file.syntax)
        return v.collected
    }

    /// Resolves a possibly-qualified type name string ("Foo" or "Foo.Bar.Baz") to a Symbol.
    /// Strips optional `?` / `!` suffixes. Returns nil if any segment doesn't match.
    public func typeSymbol(forQualifiedName rawName: String, in scope: Scope) -> Symbol? {
        // Strip trailing `?` / `!` for optionals/force-unwraps that may have leaked into the text.
        var name = rawName
        while name.hasSuffix("?") || name.hasSuffix("!") {
            name = String(name.dropLast())
        }
        // Bare-array `[T]` → resolve T (caller will likely want Element type instead, but
        // this best-effort makes simple cases work).
        if name.hasPrefix("[") && name.hasSuffix("]") {
            let inner = String(name.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            if inner.contains(":") || inner.isEmpty { return nil }
            return typeSymbol(forQualifiedName: inner, in: scope)
        }
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
    func inferClosureParamType(at index: Int, from ref: DeclReferenceExprSyntax, in scope: Scope) -> String? {
        // Positional `$N` binds to the INNERMOST enclosing closure — each closure has its own `$0`,
        // so (unlike a named param) it is NOT visible from an outer closure. Don't walk outward.
        guard let closure = Self.enclosingClosure(of: Syntax(ref)),
              let (call, closureArgIndex) = hofContext(of: closure) else {
            return nil
        }
        return hofClosureParamType(call: call, closureArgIndex: closureArgIndex, paramIndex: index, in: scope)
    }

    /// Resolve a named closure parameter like `arr.filter { item in item.x }` where the inner
    /// reference is `item`. Walks up to ClosureExpr, finds the param by name in its signature,
    /// determines its index, delegates to the HOF inference.
    func inferNamedClosureParamType(name: String, from ref: DeclReferenceExprSyntax, in scope: Scope) -> String? {
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
                return hofClosureParamType(call: call, closureArgIndex: closureArgIndex, paramIndex: idx, in: scope)
            }
            guard let parent = closure.parent else { return nil }
            node = parent
        }
        return nil
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
        in scope: Scope
    ) -> String? {
        // Method-style: `receiver.method(...)`
        if let memberCall = call.calledExpression.as(MemberAccessExprSyntax.self),
           let receiver = memberCall.base {
            let methodName = Self.stripBackticks(memberCall.declName.baseName.text)
            if let sig = HOFRegistry.signature(forMethod: methodName),
               sig.closureArgIndex == closureArgIndex,
               paramIndex < sig.closureParamSources.count {
                return resolveSource(sig.closureParamSources[paramIndex], call: call, receiver: receiver, in: scope)
            }
        }
        // Init-style: `TypeName(data, ...) { ... }`
        if let ref = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            let typeName = Self.stripBackticks(ref.baseName.text)
            if let initSig = HOFRegistry.initSignature(forType: typeName, closureAt: closureArgIndex),
               paramIndex < initSig.closureParamSources.count,
               initSig.sequenceArgIndex < call.arguments.count {
                let arg = call.arguments[call.arguments.index(call.arguments.startIndex, offsetBy: initSig.sequenceArgIndex)]
                return resolveSource(initSig.closureParamSources[paramIndex], call: call, receiver: arg.expression, in: scope)
            }
        }
        // User-defined HOF fallback (B-FIX-2): no stdlib registry entry, but the callee is one of
        // OUR functions/methods whose param at `closureArgIndex` is a function type — type the
        // closure's params from that declared signature. Generalizes closure-param inference to any
        // function, no per-HOF hardcoding.
        if let callee = calleeCallable(for: call, in: scope),
           let inputs = table.functionParamClosureInput[callee.id]?[closureArgIndex],
           paramIndex < inputs.count, !inputs[paramIndex].isEmpty {
            return inputs[paramIndex]
        }
        return nil
    }

    /// Resolve the callee of a function call to a unique callable Symbol by name + argument labels.
    /// Handles free functions (DeclRef, scope-chain then global) and methods (`recv.method`). Returns
    /// nil on ambiguity — callers must not guess.
    private func calleeCallable(for call: FunctionCallExprSyntax, in scope: Scope) -> Symbol? {
        var callLabels: [String?] = call.arguments.map { $0.label?.text }
        if call.trailingClosure != nil { callLabels.append(nil) }
        for extra in call.additionalTrailingClosures { callLabels.append(extra.label.text) }
        func labelsMatch(_ sym: Symbol) -> Bool {
            guard let symLabels = table.functionParamLabels[sym.id],
                  symLabels.count == callLabels.count else { return false }
            for (ext, cl) in zip(symLabels, callLabels) {
                if ext == "_" { if cl != nil { return false } }
                else if ext != cl { return false }
            }
            return true
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

    private func resolveSource(
        _ source: HOFRegistry.HOFParamSource,
        call: FunctionCallExprSyntax,
        receiver: ExprSyntax,
        in scope: Scope
    ) -> String? {
        switch source {
        case .element:
            guard let recType = receiverTypeName(of: receiver, in: scope) else { return nil }
            return Self.extractElement(from: recType)
        case .argType(let argIdx):
            guard argIdx < call.arguments.count else { return nil }
            let arg = call.arguments[call.arguments.index(call.arguments.startIndex, offsetBy: argIdx)]
            return typeSymbol(of: arg.expression, in: scope)?.name
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
               let typeName = resolveSource(firstSource, call: call, receiver: receiver, in: scope) {
                return typeSymbol(forQualifiedName: typeName, in: scope)
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
                if let n = resolveSource(firstSource, call: call, receiver: receiver, in: scope) {
                    return typeSymbol(forQualifiedName: n, in: scope)
                }
            }
        }
        return nil
    }

    /// Get the textual type name of the receiver expression. Tries declared type first
    /// (the most useful path — we want `[Purchase]`, not `Purchase` after type lookup).
    private func receiverTypeName(of expr: ExprSyntax, in scope: Scope) -> String? {
        if let ref = expr.as(DeclReferenceExprSyntax.self) {
            let name = Self.stripBackticks(ref.baseName.text)
            // `$x` / `_x` projection / storage — same wrapped type as `x`.
            var lookupName = name
            if lookupName.hasPrefix("$") || lookupName.hasPrefix("_") {
                lookupName = String(lookupName.dropFirst())
            }
            if let sym = scope.lookup(name: lookupName), !sym.kind.isTypeLike {
                return table.declaredType[sym.id]
            }
            return nil
        }
        if let member = expr.as(MemberAccessExprSyntax.self), let base = member.base {
            let memberName = Self.stripBackticks(member.declName.baseName.text)
            // Special: `Type.allCases` (CaseIterable) → `[Type]`.
            // Equally common: `Type.cases` if user-defined sometimes. Stick to .allCases.
            if memberName == "allCases",
               let baseTypeSym = typeSymbol(of: base, in: scope) {
                return "[\(baseTypeSym.name)]"
            }
            // General: resolve base, look up member's declared type.
            if let baseSym = typeSymbol(of: base, in: scope),
               let baseScope = canonicalInnerScope(of: baseSym) {
                if let memberSym = baseScope.member(named: memberName) {
                    return table.declaredType[memberSym.id]
                }
            }
            return nil
        }
        return nil
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
        // unwraps `[T]`→`T`, hiding the collection-ness we must branch on). nil ⇒ unknown base ⇒ bail.
        guard let raw = receiverTypeName(of: sub.calledExpression, in: scope) else { return nil }
        // 1. Collection / Optional element (same parser HOF closure-typing uses — one source of truth).
        if let elem = Self.extractElement(from: raw) {
            return typeSymbol(forQualifiedName: elem, in: scope)
        }
        // 2. Dictionary value (extractElement bails on dicts by design — a dict's Element is (K,V),
        //    but its SUBSCRIPT yields V?).
        if let value = Self.dictionaryValueType(from: raw) {
            return typeSymbol(forQualifiedName: value, in: scope)
        }
        // 3. Local type with a recorded subscript signature → its declared return type.
        if let baseSym = typeSymbol(forQualifiedName: raw, in: scope),
           let ret = subscriptReturnType(ofType: baseSym, forCall: sub) {
            return typeSymbol(forQualifiedName: ret, in: scope)
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
    private static func topLevelIndex(of target: Character, in s: String) -> String.Index? {
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
    /// Returns nil for unrecognised forms (Dictionaries, tuples, etc).
    public static func extractElement(from typeName: String) -> String? {
        var name = typeName
        while name.hasSuffix("?") || name.hasSuffix("!") {
            name = String(name.dropLast())
        }
        if name.hasPrefix("[") && name.hasSuffix("]") {
            let inner = name.dropFirst().dropLast()
            if inner.contains(":") { return nil }
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

/// File-private inheritance-clause collector for TypeResolver's conformance lookup. Walks the
/// type's SourceFile syntax to find the inheritance clause of the decl whose name token starts
/// at `targetOffset`. Mirrors the pattern used by WitnessLinker / ResolutionPass.
private final class TR_InheritanceCollector: SyntaxVisitor {
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
