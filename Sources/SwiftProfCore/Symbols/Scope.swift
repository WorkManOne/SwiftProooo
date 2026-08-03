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
    /// Two independent bounds, and both need the use-site offset. The START (`declOffset`) applies
    /// only to a braced block's value locals — types and functions may be referenced before they are
    /// declared (B-FIX-40). The END (`visibilityEndOffset`) is carried by the symbol itself and
    /// applies wherever it is set, because the only symbols that set it are condition bindings,
    /// whose visibility genuinely stops mid-scope (B-FIX-42) — it is not a property of the scope
    /// kind, so it must not be filtered through `isVisibleOnlyAfterDeclaration`.
    public func declarations(named name: String, visibleAt offset: Int?) -> [Symbol] {
        symbols.filter { sym in
            guard sym.name == name else { return false }
            guard let offset else { return true }
            if let end = sym.visibilityEndOffset, offset >= end { return false }
            guard isVisibleOnlyAfterDeclaration(sym) else { return true }
            return sym.declOffset <= offset
        }
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
