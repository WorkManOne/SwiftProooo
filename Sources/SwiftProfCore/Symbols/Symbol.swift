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

    /// EXCLUSIVE end of this symbol's visibility, for the one kind of declaration whose visibility
    /// ends before its scope does: a binding introduced by an `if case` / `while case` condition,
    /// which dies with the statement's body (`ConditionBindingExtent`, B-FIX-42). nil — the default
    /// and the case for every other symbol — means "visible to the end of its scope", which is what
    /// `declOffset` alone already expressed (B-FIX-40).
    public let visibilityEndOffset: Int?

    public init(
        id: Int,
        name: String,
        kind: SymbolKind,
        module: Module,
        file: SourceFile,
        scope: Scope?,
        declOffset: Int,
        declLength: Int,
        visibilityEndOffset: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.module = module
        self.file = file
        self.scope = scope
        self.declOffset = declOffset
        self.declLength = declLength
        self.visibilityEndOffset = visibilityEndOffset
    }
}
