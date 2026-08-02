import SwiftSyntax

/// The ONE rule for "can this call's argument labels be satisfied by this declaration's parameters".
///
/// Swift's argument matching is not label-array equality. Two rules make it not equality, and both
/// were learned the hard way from red builds:
///
///   - **Defaulted parameters may be omitted** (B-FIX-11). Matching is left-to-right and may SKIP a
///     parameter that has a default value; every parameter left unconsumed at the end must also be
///     defaulted. Comparing counts wrongly eliminates an overload with a trailing defaulted param
///     (`f(_ url: URL, with: = [:])`) when the call omits it (`f(u)`), leaving a different
///     same-named overload as a false unique match → wrong rename.
///   - **A trailing closure carries no label** (F5). `perform { }` satisfies
///     `perform(action: () -> Void)`, so a nil label at a TRAILING position (call index
///     ≥ `trailingStart`) matches a LABELED parameter as long as that parameter is closure-typed
///     (`functionParamClosureInput`). Comparing that nil against the written label eliminates the
///     only candidate.
///
/// This type exists because the rule had THREE implementations and only one of them knew both
/// halves: `ResolutionPass` had the full rule, while `TypeResolver.calleeCallable` and
/// `TypeResolver.typeSymbol(of:)`'s method-return branch each carried a private count-equality copy
/// (B-FIX-36). The divergence was invisible in the resolver's own tests because those two copies
/// feed TYPE INFERENCE, not rewriting: when they reject the callee the result is not a wrong name
/// but NO type, so every member reached through the closure parameter is simply left original while
/// its declaration renames. Any new site that matches call labels against parameters must call in
/// here rather than writing a fourth copy.
///
/// Variadics are deliberately not modelled — rare, and a miss costs a no-rename, never a wrong one.
enum ArgumentLabelMatch {

    /// Argument labels at a call site, in the order the parameters must consume them. Trailing
    /// closures are included: the primary one contributes `nil` (it is written without a label),
    /// each additional trailing closure contributes its own label (`Button {} label: {}`).
    static func labels(of call: FunctionCallExprSyntax) -> [String?] {
        var labels: [String?] = call.arguments.map { $0.label?.text }
        if call.trailingClosure != nil { labels.append(nil) }
        for extra in call.additionalTrailingClosures { labels.append(extra.label.text) }
        return labels
    }

    /// The index into `labels(of:)` at which trailing closures begin. Everything from here on was
    /// written outside the parentheses, which is what licenses the unlabeled-closure match.
    static func trailingStart(of call: FunctionCallExprSyntax) -> Int {
        call.arguments.count
    }

    /// True when `call`'s labels can be satisfied by `sym`'s parameters.
    static func matches(_ sym: Symbol, call: FunctionCallExprSyntax, in table: SymbolTable) -> Bool {
        parameterIndices(sym, call: call, in: table) != nil
    }

    /// True when `callLabels` can be satisfied by `sym`'s parameters. Use this overload when the
    /// caller already computed the labels; `trailingStart` must come from `trailingStart(of:)`.
    static func matches(_ sym: Symbol,
                        callLabels: [String?],
                        trailingStart: Int,
                        in table: SymbolTable) -> Bool {
        parameterIndices(sym, callLabels: callLabels, trailingStart: trailingStart, in: table) != nil
    }

    /// The DECLARED PARAMETER index each call argument binds to, or nil when the labels don't match
    /// at all. `result[i]` is the parameter consumed by call argument `i`.
    ///
    /// Argument index and parameter index are the same number only when the call omits nothing. Once
    /// a defaulted parameter is skipped they diverge, and every side table keyed by PARAMETER
    /// position (`functionParamTypes`, `functionParamClosureInput`) must be indexed through this
    /// mapping rather than by the argument's own ordinal. Reading the wrong entry gives a parameter
    /// type belonging to a different parameter: in overload scoring that is a comparison against the
    /// wrong declaration, and in closure-parameter inference it is the difference between typing the
    /// closure and leaving every member read through it un-renamed (B-FIX-36).
    static func parameterIndices(_ sym: Symbol,
                                 call: FunctionCallExprSyntax,
                                 in table: SymbolTable) -> [Int]? {
        parameterIndices(sym, callLabels: labels(of: call), trailingStart: trailingStart(of: call), in: table)
    }

    /// The parameter index bound by the argument at `argIndex`, or nil when the labels don't match
    /// or the call has no such argument.
    static func parameterIndex(ofArgument argIndex: Int,
                               for sym: Symbol,
                               call: FunctionCallExprSyntax,
                               in table: SymbolTable) -> Int? {
        guard let indices = parameterIndices(sym, call: call, in: table),
              argIndex >= 0, argIndex < indices.count else { return nil }
        return indices[argIndex]
    }

    static func parameterIndices(_ sym: Symbol,
                                 callLabels: [String?],
                                 trailingStart: Int,
                                 in table: SymbolTable) -> [Int]? {
        guard let symLabels = table.functionParamLabels[sym.id] else { return nil }
        let defaults = table.functionParamHasDefault[sym.id] ?? Array(repeating: false, count: symLabels.count)
        let closureParams = table.functionParamClosureInput[sym.id]
        var bound: [Int] = []
        bound.reserveCapacity(callLabels.count)
        var ci = 0, pi = 0
        while ci < callLabels.count {
            guard pi < symLabels.count else { return nil }     // more args than params
            let ext = symLabels[pi]
            let callLabel = callLabels[ci]
            let isTrailing = ci >= trailingStart
            let closureMatchesLabeled = isTrailing && callLabel == nil && ext != "_"
                && closureParams?[pi] != nil
            let matched = (ext == "_" ? (callLabel == nil) : (ext == callLabel)) || closureMatchesLabeled
            if matched {
                bound.append(pi)
                ci += 1; pi += 1
            } else if pi < defaults.count && defaults[pi] {
                pi += 1                                          // omit this defaulted parameter
            } else {
                return nil                                       // required param can't be skipped
            }
        }
        // Any parameters not consumed by the call must all be defaulted.
        while pi < symLabels.count {
            guard pi < defaults.count && defaults[pi] else { return nil }
            pi += 1
        }
        return bound
    }
}
