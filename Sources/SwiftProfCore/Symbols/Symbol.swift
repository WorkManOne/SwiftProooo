import Foundation
import SwiftSyntax

public enum SymbolKind: String, Hashable {
    case `class`
    case `struct`
    case `enum`
    case `protocol`
    case typealias_ = "typealias"
    case associatedtype_ = "associatedtype"
    case method
    case function
    case property
    case enumCase
    case initializer
    case parameter

    public var isTypeLike: Bool {
        switch self {
        case .class, .struct, .enum, .protocol, .typealias_, .associatedtype_: return true
        default: return false
        }
    }
}

public final class Symbol {
    public let id: Int
    public let name: String
    public let kind: SymbolKind
    public let module: Module
    public unowned let file: SourceFile
    public weak var scope: Scope?
    public let declOffset: Int
    public let declLength: Int

    /// Set for the one kind of declaration that does not span the scope it is registered in: a
    /// binding introduced by an `if` / `while` / `guard case` CONDITION, which `DeclarationPass`
    /// flattens into the ENCLOSING scope rather than giving it a scope of its own (B-FIX-42). It
    /// carries the region the binding is actually visible in, and its mere presence marks the
    /// symbol as lexically NESTED in that scope — which is what lets it shadow the scope's own
    /// same-named declarations (B-FIX-43). nil — the default and the case for every other symbol —
    /// means "visible to the end of its scope", from `declOffset` onward where B-FIX-40 applies.
    public let conditionBinding: ConditionBindingExtent.Visibility?

    public init(
        id: Int,
        name: String,
        kind: SymbolKind,
        module: Module,
        file: SourceFile,
        scope: Scope?,
        declOffset: Int,
        declLength: Int,
        conditionBinding: ConditionBindingExtent.Visibility? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.module = module
        self.file = file
        self.scope = scope
        self.declOffset = declOffset
        self.declLength = declLength
        self.conditionBinding = conditionBinding
    }
}
