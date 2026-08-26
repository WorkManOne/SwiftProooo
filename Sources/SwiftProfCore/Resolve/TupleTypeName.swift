import Foundation

/// Parsing of a written TUPLE type name into its component type names (B-FIX-38).
///
/// **Invariant: a binding pattern with several names destructures a tuple** — `{ offset, row in … }`
/// and `for (offset, row) in …` each bind their *n*-th name to the *n*-th COMPONENT of the element,
/// not to the whole element. The stdlib sources that hand out a tuple element are `enumerated()`
/// (`(offset: Int, element: Element)`) and a Dictionary (`(key: Key, value: Value)`); before this
/// existed, both were simply unmodelled, so every member read through such a binding stayed
/// original while its declaration renamed.
///
/// Fail-closed by construction: anything this cannot parse as a tuple of >1 components yields nil,
/// and the caller keeps the whole element. The consumers require the component COUNT to equal the
/// pattern's arity before destructuring, so a mis-parse costs a rename, never a wrong one.
enum TupleTypeName {

    /// Component type names of a written tuple type, or nil when `typeName` is not a tuple of more
    /// than one component. Labels are dropped — `(offset: Int, element: Row)` → `["Int", "Row"]` —
    /// because a component's TYPE is all a destructured binding takes from it.
    ///
    /// A single parenthesized type (`(Row)`) is deliberately NOT a tuple: Swift treats it as `Row`
    /// itself, and reporting one component would let a 1-name pattern "destructure" a plain type.
    static func components(of typeName: String) -> [String]? {
        labeledComponents(of: typeName)?.map { $0.type }
    }

    /// Component (label, type) pairs of a written tuple type, or nil when `typeName` is not a tuple
    /// of more than one component. Same parse as `components`, but KEEPS the labels so a member
    /// access on a tuple-typed value (`pair.element`, `pair.offset`) can pick the component by name
    /// (B2). A component with no label yields `nil` for that slot — a positional access (`pair.0`)
    /// then indexes by position.
    static func labeledComponents(of typeName: String) -> [(label: String?, type: String)]? {
        var name = typeName.trimmingCharacters(in: .whitespaces)
        while name.hasSuffix("?") || name.hasSuffix("!") {
            name = String(name.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        guard name.hasPrefix("("), name.hasSuffix(")"), name.count > 2 else { return nil }
        let inner = String(name.dropFirst().dropLast())
        // The parens must be each other's match, not two separate groups (`(A, B) -> (C)`).
        guard isBalanced(inner) else { return nil }
        let parts = splitTopLevel(inner)
        guard parts.count > 1 else { return nil }
        var out: [(label: String?, type: String)] = []
        for part in parts {
            let (label, rawType) = splitLabel(part)
            let component = rawType.trimmingCharacters(in: .whitespaces)
            guard !component.isEmpty else { return nil }
            out.append((label, component))
        }
        return out
    }

    /// `offset: Int` → `(label: "offset", type: "Int")`; `Int` → `(nil, "Int")`. Only a TOP-LEVEL
    /// colon is a label separator, so a dictionary component (`[String: Row]`) keeps its colon and
    /// yields no label.
    private static func splitLabel(_ part: String) -> (label: String?, type: String) {
        let trimmed = part.trimmingCharacters(in: .whitespaces)
        guard let idx = TypeResolver.topLevelIndex(of: ":", in: trimmed) else { return (nil, trimmed) }
        // A label is a plain identifier; anything else (`inout`, an operator) means this is not a
        // `label: Type` pair and must be left alone.
        let label = trimmed[..<idx].trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty, label.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
            return (nil, trimmed)
        }
        return (String(label), String(trimmed[trimmed.index(after: idx)...]))
    }

    /// Split on commas at bracket/angle/paren depth 0, so a nested generic or tuple component
    /// (`(offset: Int, element: (key: String, value: Row))`) does not split on its inner comma.
    private static func splitTopLevel(_ s: String) -> [String] {
        var parts: [String] = []
        var depth = 0
        var current = ""
        for c in s {
            if c == "[" || c == "<" || c == "(" { depth += 1 }
            else if c == "]" || c == ">" || c == ")" { depth = max(0, depth - 1) }
            if c == "," && depth == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(c)
            }
        }
        parts.append(current)
        return parts
    }

    /// True when every bracket in `s` closes at or above depth 0 and the string ends balanced —
    /// i.e. the outer parens we stripped really were a matching pair.
    private static func isBalanced(_ s: String) -> Bool {
        var depth = 0
        for c in s {
            if c == "[" || c == "<" || c == "(" { depth += 1 }
            else if c == "]" || c == ">" || c == ")" {
                depth -= 1
                if depth < 0 { return false }
            }
        }
        return depth == 0
    }
}
