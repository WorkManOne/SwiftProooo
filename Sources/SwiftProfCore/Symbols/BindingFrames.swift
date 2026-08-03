/// A stack of lexical frames holding the FLOW-SENSITIVE bindings `ResolutionPass` tracks outside
/// the scope tree — the ones `DeclarationPass` deliberately does not register as Symbols, so that
/// `guard let x = x` still resolves its right-hand side to the property (B-FIX-12).
///
/// Two of them exist and they must answer the same way: `shadowFrames` (is this name a binding
/// here, so leave the reference alone) and `shadowBindingTypeFrames` (what is that binding's
/// type). This type is the one place the rule lives, because a name means the same thing to both
/// or the two halves disagree and the wrong one wins — the lesson `ConditionBindingExtent` records
/// for the `if case` family.
///
/// The rule, in two parts:
///
///  1. **An entry carries the offset it stops answering at** (`until`, EXCLUSIVE; nil = to the end
///     of its frame). A frame is pushed per SCOPE, but an `if let` condition is visited before the
///     body's scope is entered, so its binding lands in the ENCLOSING block's frame and outlives
///     the statement by a whole method unless it says where it ends (B-FIX-45).
///  2. **An expired entry is SKIPPED, never terminal.** The name is simply not bound by that entry
///     at this position, so an earlier still-live binding of the same name is the right answer.
///     That is why a name maps to a LIST rather than a single entry: `guard let box = …` followed
///     by `if let box = …` puts two bindings of one name in ONE frame, and replacing the first with
///     the second would leave the name unbound below the statement — where it is still the guard's.
///
/// Among the entries live at a position the NEWEST wins (innermost frame first, and within a frame
/// the most recently bound), which is what makes the inner `if let` shadow the outer `guard let`
/// inside its own body.
struct BindingFrames<Value> {
    private struct Entry {
        /// EXCLUSIVE offset the entry stops answering at; nil = live to the end of the frame.
        let until: Int?
        let value: Value
    }

    private var frames: [[String: [Entry]]] = [[:]]

    /// Enter a lexical scope. Paired with `pop()` by `enterInnerScope`/`exitInnerScope`.
    mutating func push() { frames.append([:]) }

    /// Leave a lexical scope, dropping every binding declared in it.
    mutating func pop() {
        guard frames.count > 1 else { return }
        frames.removeLast()
    }

    /// Bind `name` in the innermost frame until `until` (nil = to the end of that frame).
    mutating func bind(_ name: String, until: Int?, _ value: Value) {
        guard !frames.isEmpty else { return }
        frames[frames.count - 1][name, default: []].append(Entry(until: until, value: value))
    }

    /// The value of the newest binding of `name` that is still live at `offset`, or nil when the
    /// name is not bound there. A nil `offset` is a caller with no use-site position and gets the
    /// old, position-blind answer (the newest binding, expired or not).
    func newest(_ name: String, at offset: Int?) -> Value? {
        for frame in frames.reversed() {
            guard let entries = frame[name] else { continue }
            for entry in entries.reversed() {
                if let offset, let until = entry.until, offset >= until { continue }
                return entry.value
            }
        }
        return nil
    }
}

extension BindingFrames where Value == Void {
    mutating func bind(_ name: String, until: Int?) { bind(name, until: until, ()) }

    /// True when `name` is bound at `offset` — the "this is a local, not the declaration we may
    /// have renamed" question.
    func isBound(_ name: String, at offset: Int?) -> Bool { newest(name, at: offset) != nil }
}
