import Foundation

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
    public let outcome: Outcome

    public init(filePath: String, offset: Int, name: String, outcome: Outcome) {
        self.filePath = filePath
        self.offset = offset
        self.name = name
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
