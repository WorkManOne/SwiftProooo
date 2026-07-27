import Foundation

/// NDA-safe anonymization of identifiers for diagnostic output.
///
/// Every diagnostic emitter MUST hash identifiers through here rather than rolling its own, so the
/// SAME identifier produces the SAME token in EVERY log kind (`OVLD` from the resolver, `SURV` from
/// the rollback pass). Correlating two lines is the whole point: without a shared hash the user
/// cannot tell whether the unresolved call and the surviving name are the same symbol, and the only
/// way to find out would be pasting real client code.
///
/// Common type names pass through unhashed: they carry no client information and reading
/// `pTypes=[String,Bool]` beats reading `pTypes=[#4a1f0c,#88b2e1]`.
public enum Anon {
    private static let passthrough: Set<String> = [
        "String", "Int", "Bool", "Double", "Float", "CGFloat", "Data", "Date", "URL", "UUID",
        "Void", "Any", "AnyObject", "Character", "Substring", "TimeInterval", "_"
    ]

    /// FNV-1a truncated to 24 bits. Not a security hash: it hides the identifier from a reader,
    /// it does not resist a dictionary attack by someone who already guessed the name.
    public static func of(_ s: String) -> String {
        if passthrough.contains(s) { return s }
        var h: UInt64 = 1469598103934665603
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return "#" + String(h & 0xFFFFFF, radix: 16)
    }
}
