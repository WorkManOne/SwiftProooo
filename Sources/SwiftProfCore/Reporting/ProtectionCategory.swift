import Foundation

/// Classifies WHY a symbol was protected from renaming, for the purposes of reporting.
/// Distinguishes "we couldn't rename in principle" from "we chose not to, this time".
public enum ProtectionCategory: String {
    /// Cannot be renamed without breaking runtime / compiler contracts. These are NOT failures
    /// of the obfuscator — they're hard constraints of the iOS platform / Swift language.
    ///   examples: @objc / NSObject inheritance, propertyWrapper requirements (wrappedValue),
    ///             resultBuilder requirements, raw-type enum cases, protocol-with-associatedtype
    ///             members, stdlib protocol requirements (View.body, Identifiable.id),
    ///             unknown-external conformance (we don't know the contract).
    case structural

    /// Could be renamed with better resolvers, but currently we don't. Counted against our
    /// effectiveness — "obfuscatable but not obfuscated".
    ///   examples: key path references (\.X), if-let shorthand (`if let X`).
    case contextual

    /// Maps a free-text reason string (as set by Protector) to a category. Falls back to
    /// .structural for any reason we don't explicitly recognise — safer to over-report
    /// the unavoidable bucket than to over-report the actionable one.
    public static func classify(reason: String) -> ProtectionCategory {
        // Contextual — could be fixed with future resolvers.
        if reason.hasPrefix("ambiguous use site") { return .contextual }
        // Everything else is structural / runtime / API contract.
        return .structural
    }
}

/// Why a symbol wasn't obfuscated, broader than just "protected" — also covers policy skips.
public enum NoObfuscateReason {
    case obfuscated                                  // ← actually renamed
    case structuralProtection(String)                // ← can never rename
    case contextualProtection(String)                // ← could rename with better resolvers
    case policyParameter                             // ← parameter (we don't touch labels)
    case policyInitializer                           // ← `init` keyword
    case policyExtensionOfExternal                   // ← extension on Array/etc.
    case policyNonWritable                           // ← read-only module
}
