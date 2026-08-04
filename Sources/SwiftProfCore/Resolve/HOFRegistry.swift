import Foundation

/// Hard-coded knowledge of well-known higher-order functions (HOFs) from the Swift stdlib /
/// Foundation. For each method, describes:
///   - Receiver: which conformance the HOF lives on (Sequence/Collection/Optional/...)
///   - Closure arg position: which positional argument is the closure (0-based)
///   - For each closure parameter slot: what type that parameter receives at runtime
///
/// We model only the SIMPLE case where the closure parameter is the receiver's `Element` (for
/// sequences/collections) or `Wrapped` (for Optional). Combinations like `reduce`'s `(T, Element)`
/// where T is itself a function-argument type are handled by a small variant — see HOFParamSource.
///
/// The registry intentionally hard-codes — these APIs have been stable since Swift 3+ and the
/// list of useful HOFs is small (~30 methods). Auto-generation from `.swiftinterface` is a
/// future improvement; the registry can be replaced wholesale without changing call sites.
///
/// An entry that is MISSING is silent: the closure's parameters simply stay untyped, so every
/// member read through them keeps its original name while the declaration renames — a desync,
/// reported only as `UNRES cause=receiver-untyped`. Hence the one standing rule for edits here:
/// **a method and its in-place sibling go in together** (`sorted`/`sort`), because they hand the
/// closure the same parameters and a project uses whichever one it happens to need (B-FIX-51).
public enum HOFRegistry {
    public struct Signature: Sendable {
        public let methodName: String
        public let closureArgIndex: Int
        /// For each closure parameter (in order), where to get its type.
        public let closureParamSources: [HOFParamSource]
    }

    public enum HOFParamSource: Sendable {
        /// The receiver's Element (Sequence/Collection family) or Wrapped (Optional).
        case element
        /// The type of an argument at the given index of the FunctionCall. Used by `reduce`
        /// where the closure's first param is the accumulator (same type as `initialResult`).
        case argType(Int)
    }

    /// Find the HOF signature for `methodName`. Returns nil if not a known HOF.
    public static func signature(forMethod methodName: String) -> Signature? {
        all.first(where: { $0.methodName == methodName })
    }

    /// All known HOF signatures. Order doesn't matter — lookup is by name.
    /// We don't store receiver type here because Swift overloads HOF names across multiple
    /// conformances (`Sequence.map` AND `Optional.map` exist); element-type extraction is
    /// driven by the receiver's declared type string (`extractElement` parses both forms).
    static let all: [Signature] = [
        // Sequence / Collection — element-based, single-param
        Signature(methodName: "filter",       closureArgIndex: 0, closureParamSources: [.element]),
        Signature(methodName: "map",          closureArgIndex: 0, closureParamSources: [.element]),
        Signature(methodName: "compactMap",   closureArgIndex: 0, closureParamSources: [.element]),
        Signature(methodName: "flatMap",      closureArgIndex: 0, closureParamSources: [.element]),
        Signature(methodName: "forEach",      closureArgIndex: 0, closureParamSources: [.element]),
        Signature(methodName: "first",        closureArgIndex: 0, closureParamSources: [.element]),
        Signature(methodName: "last",         closureArgIndex: 0, closureParamSources: [.element]),
        Signature(methodName: "firstIndex",   closureArgIndex: 0, closureParamSources: [.element]),
        Signature(methodName: "lastIndex",    closureArgIndex: 0, closureParamSources: [.element]),
        Signature(methodName: "contains",     closureArgIndex: 0, closureParamSources: [.element]),
        Signature(methodName: "allSatisfy",   closureArgIndex: 0, closureParamSources: [.element]),
        Signature(methodName: "drop",         closureArgIndex: 0, closureParamSources: [.element]),
        Signature(methodName: "prefix",       closureArgIndex: 0, closureParamSources: [.element]),
        Signature(methodName: "split",        closureArgIndex: 0, closureParamSources: [.element]),
        Signature(methodName: "min",          closureArgIndex: 0, closureParamSources: [.element, .element]),
        Signature(methodName: "max",          closureArgIndex: 0, closureParamSources: [.element, .element]),
        // Two-element closures. `sort(by:)` is `sorted(by:)`'s in-place sibling and hands its
        // closure exactly the same two Elements — registering one without the other left `$0` in
        // `rows.sort { $0.a > $1.a }` untyped, so every member read through it stayed original
        // while the declaration renamed (B-FIX-51).
        Signature(methodName: "sorted",       closureArgIndex: 0, closureParamSources: [.element, .element]),
        Signature(methodName: "sort",         closureArgIndex: 0, closureParamSources: [.element, .element]),
        // Reduce: closure is arg #1, closure params are (accumulator: typeOfArg0, element: Element)
        Signature(methodName: "reduce",       closureArgIndex: 1, closureParamSources: [.argType(0), .element]),
        // Grouping / chunking
        Signature(methodName: "partition",    closureArgIndex: 0, closureParamSources: [.element]),
        // Subscript-style modifications
        Signature(methodName: "removeAll",    closureArgIndex: 0, closureParamSources: [.element]),
    ]

    // MARK: - Init-style HOFs (type constructors taking a sequence + content closure)

    public struct InitSignature: Sendable {
        public let typeName: String
        /// Position of the data/sequence argument (0-based) in the call.
        public let sequenceArgIndex: Int
        /// Position of the closure argument (0-based, may be trailing = arguments.count).
        public let closureArgIndex: Int
        /// Closure parameter sources (always 1 for ForEach/List/etc).
        public let closureParamSources: [HOFParamSource]
    }

    /// Type-init HOFs: `ForEach(arr) { item in ... }`, `List(arr) { ... }`, etc.
    /// Receiver of `.element` is the data argument's type.
    public static let initStyleHOFs: [InitSignature] = [
        // ForEach(_ data: ...) { content in ... }  -- two-arg form (data + closure)
        InitSignature(typeName: "ForEach", sequenceArgIndex: 0, closureArgIndex: 1, closureParamSources: [.element]),
        // ForEach(_ data:, id: KeyPath) { content in ... } -- three-arg form (data + id + closure)
        InitSignature(typeName: "ForEach", sequenceArgIndex: 0, closureArgIndex: 2, closureParamSources: [.element]),
        // List(_ data:, id:) { ... } — same shape as ForEach
        InitSignature(typeName: "List",    sequenceArgIndex: 0, closureArgIndex: 1, closureParamSources: [.element]),
        InitSignature(typeName: "List",    sequenceArgIndex: 0, closureArgIndex: 2, closureParamSources: [.element]),
    ]

    public static func initSignature(forType typeName: String, closureAt argIndex: Int) -> InitSignature? {
        initStyleHOFs.first(where: { $0.typeName == typeName && $0.closureArgIndex == argIndex })
    }
}
