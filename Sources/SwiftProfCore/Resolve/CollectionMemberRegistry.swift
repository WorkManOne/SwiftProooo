import Foundation

/// Result SHAPE of a stdlib collection member, expressed in terms of the receiver's own type
/// (B-FIX-30).
///
/// **Invariant: a stdlib collection member's result type is a known function of the receiver's
/// Element** — `first`/`last`/`randomElement()` yield the Element, `sorted()`/`filter{}`/
/// `dropFirst()` yield a collection with the SAME Element, a Dictionary's `keys`/`values` yield
/// collections of its Key/Value. A member that is NOT in this table has an unknown result and must
/// fail closed: the next step of the chain stays untyped and nothing is renamed there
/// (under-obfuscation, never a wrong rename).
///
/// Why it exists: since B-FIX-28 a collection type name resolves to NO declaration — correct, but
/// it leaves every chain that passes THROUGH a collection member (`arr.first?.m`, `dict.values`,
/// `arr.sorted().first`) unresolved, so the member's declaration renames while the use-site does
/// not. That is a desync — a red build whenever RollbackPass's shields block the rescue. This table
/// is the deliberately small, result-shape-only part of "knowing Array's API"; it never claims a
/// member EXISTS (we only ever look up members we then find in a real scope) and it never renames a
/// stdlib member.
///
/// Deliberately EXCLUDED (their result element differs from the receiver's in a way we don't model):
/// `map`/`compactMap`/`flatMap`/`joined`/`zip`, a Dictionary's `first`/`sorted`, `mapValues`. Wrong
/// here would be a wrong rename, so absence is the safe default.
///
/// `enumerated()` used to be excluded on the same grounds ("its element is a tuple"), and that gap
/// is what left `rows.enumerated().forEach { i, row in row.member }` untyped (B-FIX-38). Its element
/// IS modelled now — as the written tuple `(offset: Int, element: E)` — because a tuple name is
/// honest information: it resolves to no declaration, so every consumer that wants a declaration
/// still fails closed exactly as before, while the consumers that destructure it
/// (`TupleTypeName.components`) finally get the component they need.
enum CollectionMemberRegistry {

    /// The result type NAME of `receiver.member` / `receiver.member(...)`, where `receiverType` is
    /// the receiver's WRITTEN type name (`[Item]`, `Array<Item>`, `Set<Item>`, `[String: Item]`).
    /// nil when the receiver is not a collection we parse or the member is not in the table.
    static func resultTypeName(member: String, receiverType: String) -> String? {
        // Dictionary first: it also matches no sequence shape, but its Element is a `(key, value)`
        // tuple, so the sequence members below must NOT be applied to it.
        if let key = TypeResolver.dictionaryKeyType(from: receiverType),
           let value = TypeResolver.dictionaryValueType(from: receiverType) {
            switch member {
            case "keys":   return "[\(key)]"
            case "values": return "[\(value)]"
            case "filter": return receiverType   // a Dictionary's filter keeps the dictionary type
            case "enumerated": return "[\(enumeratedElement(of: "(key: \(key), value: \(value))"))]"
            default:       return nil
            }
        }
        guard let element = sequenceElement(of: receiverType) else { return nil }
        if member == "enumerated" { return "[\(enumeratedElement(of: element))]" }
        if elementMembers.contains(member) { return element }
        if sameElementMembers.contains(member) { return "[\(element)]" }
        return nil
    }

    /// The element `enumerated()` yields over a sequence whose own element is `element`. Spelled with
    /// the stdlib's own labels so a consumer that later learns tuple MEMBER access (`pair.element`)
    /// reads them from one place.
    private static func enumeratedElement(of element: String) -> String {
        "(offset: Int, element: \(element))"
    }

    /// The Element a type hands to a closure or a `for` pattern when ITERATED as a Sequence: a
    /// Dictionary yields the tuple `(key: K, value: V)`, everything else yields what
    /// `TypeResolver.extractElement` reports (arrays, sets, and — for `Optional.map` — the Wrapped
    /// type).
    ///
    /// Deliberately SEPARATE from `extractElement`, which must stay dictionary-blind: that one
    /// answers the SUBSCRIPT question, where `dict[k]` yields `V?` and never the tuple. Iterating a
    /// dictionary and subscripting it are different questions with different answers, and merging
    /// them would type `dict[k].member` as a tuple — a wrong rename (B-FIX-38).
    static func iterationElement(of typeName: String) -> String? {
        if let key = TypeResolver.dictionaryKeyType(from: typeName),
           let value = TypeResolver.dictionaryValueType(from: typeName) {
            return "(key: \(key), value: \(value))"
        }
        return TypeResolver.extractElement(from: typeName)
    }

    /// Element type of an ARRAY/SET-like collection name, or nil. Narrower than
    /// `TypeResolver.extractElement` on purpose: that one also treats `Optional<T>` / `T?` as
    /// element-bearing (which is right for `opt.map { … }` but wrong here — an Optional receiver has
    /// none of these members, and typing `opt.first` as the wrapped type would be a guess).
    static func sequenceElement(of typeName: String) -> String? {
        var name = typeName.trimmingCharacters(in: .whitespaces)
        while name.hasSuffix("?") || name.hasSuffix("!") { name = String(name.dropLast()) }
        if name.hasPrefix("[") && name.hasSuffix("]") {
            let inner = String(name.dropFirst().dropLast())
            guard TypeResolver.topLevelIndex(of: ":", in: inner) == nil else { return nil }  // a dictionary
            let element = inner.trimmingCharacters(in: .whitespaces)
            return element.isEmpty ? nil : element
        }
        for base in genericCollections {
            let prefix = "\(base)<"
            guard name.hasPrefix(prefix), name.hasSuffix(">") else { continue }
            let inner = String(name.dropFirst(prefix.count).dropLast())
            guard TypeResolver.topLevelIndex(of: ",", in: inner) == nil else { return nil }
            let element = inner.trimmingCharacters(in: .whitespaces)
            return element.isEmpty ? nil : element
        }
        return nil
    }

    /// Generic spellings whose single type argument IS the Element.
    private static let genericCollections = [
        "Array", "Set", "ArraySlice", "ContiguousArray", "ReversedCollection",
    ]

    /// The stdlib collection a WRITTEN type name denotes (`[T]` → Array, `Set<T>` → Set,
    /// `[K: V]` → Dictionary), or nil when the name is not a collection we parse. Decides which
    /// `extension <Collection>` bodies can possibly apply to a receiver (B-FIX-31).
    static func collectionKind(of typeName: String) -> String? {
        var name = typeName.trimmingCharacters(in: .whitespaces)
        while name.hasSuffix("?") || name.hasSuffix("!") { name = String(name.dropLast()) }
        if name.hasPrefix("[") && name.hasSuffix("]") {
            let inner = String(name.dropFirst().dropLast())
            return TypeResolver.topLevelIndex(of: ":", in: inner) == nil ? "Array" : "Dictionary"
        }
        for base in genericCollections + ["Dictionary"]
        where name.hasPrefix("\(base)<") && name.hasSuffix(">") {
            return base
        }
        return nil
    }

    /// Extension bases whose members apply to a receiver of collection `kind` — the concrete type
    /// itself plus the collection PROTOCOLS it conforms to. Deliberately conservative: an unlisted
    /// pairing simply doesn't match, which costs a rename, never correctness.
    static func applicableExtensionBases(forKind kind: String) -> Set<String> {
        let shared: Set<String> = ["Collection", "Sequence", kind]
        switch kind {
        case "Array", "ArraySlice", "ContiguousArray":
            return shared.union(["BidirectionalCollection", "RandomAccessCollection",
                                 "MutableCollection", "RangeReplaceableCollection"])
        case "Set":
            return shared.union(["SetAlgebra"])
        default:
            return shared
        }
    }

    /// Members whose result is the receiver's ELEMENT. Optionality is irrelevant here: every
    /// consumer peels optionals before/after resolving, exactly as it does for a declared `T?`.
    /// Both spellings of each name are covered — `arr.first` and `arr.first(where:)` are the same
    /// member name, and the table is keyed by name only.
    private static let elementMembers: Set<String> = [
        "first", "last", "randomElement", "min", "max",
        "popFirst", "popLast", "removeFirst", "removeLast", "remove",
    ]

    /// Members whose result is a collection with the SAME Element (returned in array sugar so the
    /// next step of a chain parses it uniformly — we care only about the Element, never about which
    /// concrete stdlib collection type it is).
    private static let sameElementMembers: Set<String> = [
        "sorted", "reversed", "shuffled", "filter", "lazy",
        "dropFirst", "dropLast", "drop", "prefix", "suffix",
        "union", "intersection", "subtracting", "symmetricDifference",
    ]
}
