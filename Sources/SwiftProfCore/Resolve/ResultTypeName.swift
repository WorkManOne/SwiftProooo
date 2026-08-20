import Foundation

/// Model of the stdlib `Result<Success, Failure>` enum (B-FIX-57).
///
/// `Result` is not in our `SymbolTable` (it is stdlib), and its cases carry GENERIC payloads
/// (`.success(Success)` / `.failure(Failure)`), so the local-enum payload-typing path cannot type a
/// `case .success(let x)` binding — it would need generic substitution, which the syntactic resolver
/// does not do. But `Result`'s shape is fixed and universally known, so it is safe to model exactly
/// the way `CollectionMemberRegistry` models Array/Dictionary: `.success` binds the FIRST type
/// argument, `.failure` the SECOND. This is what lets `f4 { r in switch r { case .success(let x): x.member } }`
/// resolve `x`'s member when `f4`'s completion is a `Result` (the ubiquitous completion-handler shape,
/// often reached through a protocol `typealias`).
///
/// Fail-closed: a name that is not `Result<A, B>`, or arguments that do not parse cleanly, yields nil,
/// and the caller records no type (a missed rename, never a wrong one).
enum ResultTypeName {
    /// `(Success, Failure)` type-name strings of a `Result<Success, Failure>` name, or nil when the
    /// name is not a Result. Uses the shared balanced top-level scan so a nested generic argument
    /// (`Result<[Foo: Bar], Baz>`) splits on the RIGHT comma. Trailing optionals are peeled first.
    static func arguments(of typeName: String) -> (success: String, failure: String)? {
        // Whitespace AND newlines: a `typealias T1 = Result<\n S,\n F\n>` written across several
        // lines carries newlines into the stored type string, and `.whitespaces` alone leaves a
        // leading `\n` on each argument so it never resolves (the multi-line completion shape is the
        // common one — B-FIX-57 follow-up).
        var name = typeName.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasSuffix("?") || name.hasSuffix("!") {
            name = String(name.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let prefix = "Result<"
        guard name.hasPrefix(prefix), name.hasSuffix(">") else { return nil }
        let inner = String(name.dropFirst(prefix.count).dropLast())
        guard let comma = TypeResolver.topLevelIndex(of: ",", in: inner) else { return nil }
        let success = String(inner[..<comma]).trimmingCharacters(in: .whitespacesAndNewlines)
        let failure = String(inner[inner.index(after: comma)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !success.isEmpty, !failure.isEmpty else { return nil }
        return (success, failure)
    }

    /// The payload type of one `Result` case: `.success` → Success, `.failure` → Failure. nil for any
    /// other case name (fail-closed).
    static func payloadType(caseName: String, of typeName: String) -> String? {
        guard let (success, failure) = arguments(of: typeName) else { return nil }
        switch caseName {
        case "success": return success
        case "failure": return failure
        default:        return nil
        }
    }
}
