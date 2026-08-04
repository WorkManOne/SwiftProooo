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
/// The rule, in three parts:
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
///  3. **A binding is beaten by a declaration written DEEPER than its frame** (B-FIX-46). Every
///     lookup therefore names the competitor: the scope the same-named DECLARATION the lexical
///     lookup found was written in. A binding is lexically nested in the scope it was flattened
///     into, so it wins against that scope's own declarations and against every scope above it, and
///     loses only to a declaration written in a scope nested INSIDE it — `if let slot = payload { …
///     { let slot = DetailA(); slot.holdA } … }` reads the closure's local, not the binding.
///     Verified against swiftc on all six shapes (enclosing property, enclosing parameter, local of
///     the same block above the statement, local of the body block, local of a closure in the body,
///     local of a nested `func` in the body).
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

    /// One lexical frame. `scope` is the scope it was pushed for — the depth every entry in it is
    /// measured at (part 3 of the rule); the bottom frame's is the file scope.
    private struct Frame {
        let scope: Scope
        var bindings: [String: [Entry]] = [:]
    }

    private var frames: [Frame]

    /// `root` is the file scope, the depth of a binding written at top level.
    init(root: Scope) { frames = [Frame(scope: root)] }

    /// Enter a lexical scope. Paired with `pop()` by `enterInnerScope`/`exitInnerScope`.
    mutating func push(_ scope: Scope) { frames.append(Frame(scope: scope)) }

    /// Leave a lexical scope, dropping every binding declared in it.
    mutating func pop() {
        guard frames.count > 1 else { return }
        frames.removeLast()
    }

    /// Bind `name` in the innermost frame until `until` (nil = to the end of that frame).
    mutating func bind(_ name: String, until: Int?, _ value: Value) {
        frames[frames.count - 1].bindings[name, default: []].append(Entry(until: until, value: value))
    }

    /// The value of the newest binding of `name` that is still live at `offset` AND not out-scoped
    /// by `competitor`, or nil when the name is not bound there. A nil `offset` is a caller with no
    /// use-site position and gets the old, position-blind answer (the newest binding, expired or not).
    ///
    /// `competitor` returns the declaring scope of the same-named DECLARATION visible at the
    /// use-site — nil when the lexical lookup found none. It is a closure, not a value, because
    /// every bare reference in the project asks this question while almost none of them has a live
    /// binding: the lookup it performs runs at most once per call, and only once a live entry has
    /// actually been found.
    func newest(_ name: String, at offset: Int?, outScoping competitor: () -> Scope?) -> Value? {
        var competitorScope: Scope??
        for frame in frames.reversed() {
            guard let entries = frame.bindings[name] else { continue }
            for entry in entries.reversed() {
                if let offset, let until = entry.until, offset >= until { continue }
                if competitorScope == nil { competitorScope = competitor() }
                if let declared = competitorScope!, declared.isNested(in: frame.scope) { continue }
                return entry.value
            }
        }
        return nil
    }
}

/// What a bare name means when a flow-sensitive BINDING owns it at the use-site — the whole answer
/// `TypeResolver` gets from `localBindingTypeName`, and the reason it is not just an optional type.
///
/// `.untyped` is the load-bearing case: a live binding that out-scopes the lexical declaration owns
/// the name whether or not its own type could be inferred, so the declaration it SHADOWS must not
/// answer for it. `while let slot = it.next()` types nothing (an external iterator), and falling
/// through typed the in-body `slot.holdB` from the same-named property — the same wrong rename as
/// the reported case, just with an initializer the resolver cannot read. Failing closed there costs
/// one member rewrite; falling through ships a member of the WRONG type's obf (B-FIX-46).
public enum LocalBindingType {
    /// The binding owns the name and this is its static type, with the scope that name resolves in.
    case typed(name: String, scope: Scope)
    /// The binding owns the name but its type is unknown — answer nothing, never the shadowed decl.
    case untyped
}

extension BindingFrames where Value == Void {
    mutating func bind(_ name: String, until: Int?) { bind(name, until: until, ()) }

    /// True when `name` is bound at `offset` — the "this is a local, not the declaration we may
    /// have renamed" question. See `newest` for `competitor`.
    func isBound(_ name: String, at offset: Int?, outScoping competitor: () -> Scope?) -> Bool {
        newest(name, at: offset, outScoping: competitor) != nil
    }
}
