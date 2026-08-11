import Foundation

/// NDA-safe anonymization of identifiers for diagnostic output.
///
/// Every emitter MUST hash identifiers through here rather than rolling its own, so the SAME
/// identifier produces the SAME token everywhere in `Decisions-anon.txt` — the summary and the
/// per-file trace, a name and the target it resolved to. Correlating two lines is the whole point:
/// without a shared hash the user cannot tell whether the unresolved call and the surviving name
/// are the same symbol, and the only way to find out would be pasting real client code.
///
/// CAVEAT for the decisions report: the passthrough list below is a READABILITY affordance for
/// stdlib type names, and it is unconditional — a project that DECLARES a type named `URL` or
/// `Date` has that name printed in clear. `DecisionRenderer` therefore does not route free text
/// through here blindly; it hashes by project-name membership first (see `scrubFreeText`), and a
/// declared name that collides with this list is hashed by that path before it reaches here.
public enum Anon {
    private static let passthrough: Set<String> = [
        "String", "Int", "Bool", "Double", "Float", "CGFloat", "Data", "Date", "URL", "UUID",
        "Void", "Any", "AnyObject", "Character", "Substring", "TimeInterval", "_"
    ]

    /// FNV-1a truncated to 24 bits. Not a security hash: it hides the identifier from a reader,
    /// it does not resist a dictionary attack by someone who already guessed the name.
    public static func of(_ s: String) -> String {
        if passthrough.contains(s) { return s }
        return forced(s)
    }

    /// `of` WITHOUT the passthrough. Use it whenever the token is known to be an identifier the
    /// CLIENT declared: the passthrough is a readability affordance for stdlib type names, and it is
    /// blind to who declared them, so a project that declares a type named `URL` or `Date` would
    /// have that name printed in clear by `of`.
    public static func forced(_ s: String) -> String {
        var h: UInt64 = 1469598103934665603
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return "#" + String(h & 0xFFFFFF, radix: 16)
    }
}
