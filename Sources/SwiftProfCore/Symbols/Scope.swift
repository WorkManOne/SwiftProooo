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
    public func lookup(name: String) -> Symbol? {
        for sym in symbols where sym.name == name { return sym }
        return parent?.lookup(name: name)
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
