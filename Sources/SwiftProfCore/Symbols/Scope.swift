import Foundation

public enum ScopeKind {
    case file
    case type      // class/struct/enum/protocol/extension
    case function  // func/init/deinit/subscript
    case block     // if/for/while/do/closure
}

public final class Scope {
    public let kind: ScopeKind
    public weak var parent: Scope?
    public private(set) var children: [Scope] = []
    public private(set) var symbols: [Symbol] = []

    /// For type/function scopes: the declaring symbol (e.g. the class symbol for a type scope).
    public weak var owner: Symbol?

    public init(kind: ScopeKind, parent: Scope?) {
        self.kind = kind
        self.parent = parent
    }

    public func add(child: Scope) {
        children.append(child)
    }

    public func add(symbol: Symbol) {
        symbols.append(symbol)
    }

    /// Walk up scopes looking for a symbol with the given name.
    /// Returns first match (innermost shadows outer).
    ///
    /// `at` is the USE-SITE byte offset, and it is what makes a local's visibility start at its
    /// declaration rather than at the opening brace: `func f(for p2: Mode) { if … = p2 …; let p2:
    /// Detail = … }` reads the PARAMETER on the first line and the LOCAL on the last (verified
    /// against swiftc: the same holds for a shadowed property and a shadowed global). Only VALUE
    /// locals of a braced block are position-sensitive; types and functions may be referenced before
    /// they are declared, and a type/file scope has no order at all.
    ///
    /// Crossing a `.function` or `.type` boundary DROPS the offset, because from there the reference
    /// is a capture, and a nested `func` legitimately captures a local declared after it
    /// (`func outer() { func inner() { use(x) }; let x = 1; inner() }` compiles and `inner` sees the
    /// local). Passing no offset keeps the old, order-blind behaviour for callers that resolve a
    /// name with no use-site (a stored type string, a declaration-time lookup).
    public func lookup(name: String, at offset: Int? = nil) -> Symbol? {
        if let sym = declarations(named: name, visibleAt: offset).first { return sym }
        return parent?.lookup(name: name, at: offsetForParent(offset))
    }

    /// THIS scope's declarations of `name` that are visible at use-site `offset` — the position rule
    /// of `lookup(name:at:)` for callers that walk the chain themselves (`ResolutionVisitor
    /// .lookupCallee`, which stops at the innermost LEVEL declaring the name and narrows by kind).
    /// Such a caller must ask this, not `symbols`: a level whose only declaration is not yet visible
    /// has not declared the name at that position, and the walk has to continue outward.
    ///
    /// Two independent visibility rules, and both need the use-site offset.
    ///
    /// A CONDITION BINDING (`sym.conditionBinding` — an `if`/`while`/`guard case` binding, which
    /// `DeclarationPass` flattens into the enclosing scope) carries its own complete REGION and is
    /// answered entirely by it: from its own declaration, to `end` where it has one, minus the
    /// `hole` a `guard`'s else body punches in the middle (B-FIX-42). That start is unconditional
    /// rather than routed through `isVisibleOnlyAfterDeclaration`, because it is not a property of
    /// the scope kind — the binding is not really a declaration of this scope at all, so it must
    /// start at its own declaration even in a `.file` scope, which is otherwise order-blind.
    ///
    /// Every OTHER declaration follows B-FIX-40: the START (`declOffset`) applies only to a braced
    /// block's value locals, since types and functions may be referenced before they are declared —
    /// and at file scope nothing is order-bound, because a top-level value is a global that really
    /// is forward-referenceable (checked against swiftc: `print(later); let later = 5` in
    /// `main.swift` compiles AND runs, printing the zero value).
    ///
    /// The result is in SHADOWING order — see `shadowingOrder`, which is what makes `lookup`'s
    /// `.first` mean "the declaration in effect here" rather than "the earliest in the file".
    public func declarations(named name: String, visibleAt offset: Int?) -> [Symbol] {
        let visible = symbols.filter { sym in
            guard sym.name == name else { return false }
            guard let offset else { return true }
            if let region = sym.conditionBinding {
                guard sym.declOffset <= offset else { return false }
                if let end = region.end, offset >= end { return false }
                if let hole = region.hole, hole.contains(offset) { return false }
                return true
            }
            guard isVisibleOnlyAfterDeclaration(sym) else { return true }
            return sym.declOffset <= offset
        }
        return Self.shadowingOrder(visible)
    }

    /// Order visible declarations of one name INNERMOST first, so a `.first` pick is the one in
    /// effect at the use-site.
    ///
    /// One scope holds two visible declarations of a name only because a condition binding was
    /// flattened into it (B-FIX-42) — Swift itself rejects a redeclaration, and an overload set is
    /// narrowed by kind and signature downstream, never by this order. Where that happens the
    /// binding is the lexically NESTED one and shadows the scope's own declaration, including one
    /// declared ABOVE it, which is legal Swift: `let item = Detail(); if case .calm(let item) = mood
    /// { item.payloadTag }` compiles, and the body reads the BINDING. Source order answered with the
    /// enclosing declaration instead, so the binding never won anywhere — a wrong rename no safety
    /// net catches, since nothing of the original name survives (B-FIX-43).
    ///
    /// Only condition bindings are reordered, and only against non-bindings; among themselves the
    /// most recently declared wins (two sibling `guard case`s binding one name). Everything else
    /// keeps source order, so no overload set and no cross-file unified type scope is disturbed.
    private static func shadowingOrder(_ visible: [Symbol]) -> [Symbol] {
        guard visible.contains(where: { $0.conditionBinding != nil }) else { return visible }
        return visible.filter { $0.conditionBinding != nil }.sorted { $0.declOffset > $1.declOffset }
            + visible.filter { $0.conditionBinding == nil }
    }

    /// The offset to carry into the PARENT scope: nil past a `.function`/`.type` boundary, where the
    /// reference becomes a capture and the position rule no longer applies (see `lookup`).
    public func offsetForParent(_ offset: Int?) -> Int? {
        (kind == .function || kind == .type) ? nil : offset
    }

    /// A `let`/`var` local or a pattern binding declared in a braced block: the only declarations
    /// Swift makes visible from their declaration onward rather than throughout their scope.
    private func isVisibleOnlyAfterDeclaration(_ sym: Symbol) -> Bool {
        guard kind == .block || kind == .function else { return false }
        return sym.kind == .property || sym.kind == .parameter
    }

    /// True when `self` is a STRICT descendant of `other` — `other` encloses it and is not it.
    ///
    /// This is the LEXICAL DEPTH a flat frame stack cannot express, and the reason it is needed:
    /// an optional binding (`if let slot = payload`) is deliberately not a Symbol of any scope
    /// (B-FIX-12), so it lives only in `ResolutionPass`'s frames — and a frame knows which scope it
    /// belongs to but nothing about where a competing DECLARATION was written. The binding beats a
    /// declaration of the scope it was flattened into or of any scope ABOVE it (a property, a
    /// parameter, a local declared earlier in the same block) and loses to one written in a scope
    /// NESTED inside its own body (a closure's local, a nested `func`'s local, a local of the body
    /// block itself). All six shapes verified against swiftc — see `BindingFrames` (B-FIX-46).
    ///
    /// Cheap and allocation-free: the chain from a use-site scope to the file scope is a handful of
    /// links, and the walk stops at the first match.
    public func isNested(in other: Scope) -> Bool {
        var probe = parent
        while let cur = probe {
            if cur === other { return true }
            probe = cur.parent
        }
        return false
    }

    /// Find direct child symbol by name (used for `Type.member`).
    public func member(named name: String) -> Symbol? {
        for sym in symbols where sym.name == name { return sym }
        return nil
    }

    /// All direct child symbols with the given name (method overloads share a name — callers
    /// disambiguate by signature).
    public func members(named name: String) -> [Symbol] {
        symbols.filter { $0.name == name }
    }
}
