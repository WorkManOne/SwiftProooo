import Foundation
import SwiftSyntax

/// The syntactic position of a use-site, derived from the AST node around its identifier token.
/// Known for EVERY use-site including unresolved ones — a `MemberAccessExpr` is a member access
/// whether or not it resolved — which is why it is the outer axis of the use-site report where the
/// resolved-declaration kind (unknown for a kept site) cannot be.
public enum UseSitePosition: String, Codable, Sendable {
    case memberAccess   = "member-access"     // a.b  and  a.b()
    case enumShorthand  = "enum-shorthand"    // .case (base-less member access)
    case bareCall       = "bare-call"         // foo()  (no receiver)
    case valueReference = "value-reference"   // bare foo used as a value
    case typeReference  = "type-reference"    // IdentifierType / MemberType
    case other          = "other"             // fail-closed catch-all

    /// Classify by the token's parent chain. Fail-closed to `.other`.
    static func classify(_ token: TokenSyntax) -> UseSitePosition {
        guard let parent = token.parent else { return .other }
        if let t = parent.as(IdentifierTypeSyntax.self), t.name.id == token.id { return .typeReference }
        if let t = parent.as(MemberTypeSyntax.self), t.name.id == token.id { return .typeReference }
        guard let declRef = parent.as(DeclReferenceExprSyntax.self),
              declRef.baseName.id == token.id else { return .other }
        if let member = declRef.parent?.as(MemberAccessExprSyntax.self),
           member.declName.id == declRef.id {
            return member.base == nil ? .enumShorthand : .memberAccess
        }
        if let call = declRef.parent?.as(FunctionCallExprSyntax.self),
           call.calledExpression.id == declRef.id {
            return .bareCall
        }
        return .valueReference
    }
}

/// What the resolver decided about ONE identifier use-site.
///
/// Positions are stored as raw UTF-8 offsets, not line/column: building a `SourceLocationConverter`
/// costs a full scan of the file, and the report needs one per file at RENDER time, not one per
/// record at resolution time.
///
/// The outcome carries SYMBOL IDS, never resolved names or obfuscated names. `RollbackPass` and the
/// A6 `IndexValidator` both run after `ResolutionPass` and remove entries from the `RenameMap`, so
/// anything resolved eagerly here would be stale in exactly the cases the report exists to explain.
public struct UseSiteRecord {
    public enum Outcome {
        /// Resolved, the target had an obfuscated name, an edit was emitted.
        case rewritten(targetSymbolId: Int)
        /// Resolved, but the target is deliberately not renamed (protected, policy-skipped, or
        /// reverted before this pass ran). Correct as it stands.
        case resolvedNotRenamed(targetSymbolId: Int)
        /// Not resolved. `receiver` is the receiver type's name when one was known.
        case kept(cause: UnresolvedCause, receiver: String?, candidateIds: [Int])
    }

    public let filePath: String
    public let offset: Int
    public let name: String
    public let position: UseSitePosition
    public let outcome: Outcome

    public init(filePath: String, offset: Int, name: String,
                position: UseSitePosition, outcome: Outcome) {
        self.filePath = filePath
        self.offset = offset
        self.name = name
        self.position = position
        self.outcome = outcome
    }
}

/// Collector handed to `ResolutionPass`. nil at the call site means the feature is off and no
/// recording work happens at all.
public final class UseSiteLog {
    public private(set) var records: [UseSiteRecord] = []
    public init() {}
    public func record(_ r: UseSiteRecord) { records.append(r) }
}
