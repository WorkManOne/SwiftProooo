import Foundation
import SwiftSyntax

/// Walks all writable source files, resolves each identifier use-site against the SymbolTable
/// and the active scope chain, and emits Rename edits for sites whose target symbol is in the
/// rename map. Also emits Rename edits for the declarations themselves.
public final class ResolutionPass {
    public let table: SymbolTable
    public let map: RenameMap
    public let logger: Logger
    /// A4 USR ground-truth, when `indexStorePath` is set. nil ⇒ syntactic resolution only.
    public let indexContext: IndexContext?
    /// Rewrite a member access by NAME when the name belongs to a project-unique member of an
    /// external-type extension and the receiver cannot be typed (`--no-unique-external-members`
    /// disables it). See `uniqueExternalExtensionMembers`.
    public let uniqueExternalMembers: Bool
    /// Per-use-site decision records for `--explain`. nil ⇒ no recording work at all.
    public let useSiteLog: UseSiteLog?

    public init(table: SymbolTable, map: RenameMap, logger: Logger,
                indexContext: IndexContext? = nil,
                uniqueExternalMembers: Bool = true, useSiteLog: UseSiteLog? = nil) {
        self.table = table
        self.map = map
        self.logger = logger
        self.indexContext = indexContext
        self.uniqueExternalMembers = uniqueExternalMembers
        self.useSiteLog = useSiteLog
    }

    /// name → the single declaration that owns it, for members of external-type extensions whose
    /// name is UNIQUE among every declaration in the project (B-FIX-31).
    ///
    /// Why a name-based rule is warranted here and nowhere else: an extension on an external
    /// PROTOCOL (`extension View { func frostBound() -> some View }` — the SwiftUI modifier idiom)
    /// is used on expressions whose type is `some View`, built by chained SDK calls. There is no
    /// syntactic way to type such a receiver, so type-matched resolution can NEVER reach those
    /// use-sites: the declaration renames, all 40 use-sites survive, and RollbackPass reverts the
    /// whole thing — the member stays readable forever.
    ///
    /// The guards make the rewrite safe: the name is declared exactly ONCE project-wide (any second
    /// declaration of any kind disqualifies it), it lives in an eligible external extension (no
    /// conformance in that extension family), and it survived the Planner — which already refuses
    /// Apple/stdlib API names (`allKnownMemberNames`, i.e. every member name of every loaded
    /// `.swiftinterface` when SDK introspection is on). A `.name` member access in compiling source
    /// must therefore denote this declaration. The residual risk is a member of an SDK framework
    /// that ships no interface (ObjC-only) sharing the exact custom name — hence the flag to bisect.
    /// Keyed by name, then by MODULE: a multi-target iOS app routinely compiles the same source into
    /// several writable targets, so "declared once" means once per module — the use-site takes the
    /// declaration from its OWN module (the cross-target same-module tiebreak used everywhere else).
    /// A name is admitted only when EVERY declaration of it project-wide is such a member, so a
    /// second, unrelated declaration anywhere still disqualifies it.
    static func uniqueExternalExtensionMembers(in table: SymbolTable,
                                               map: RenameMap) -> [String: [String: Symbol]] {
        var byName: [String: [Symbol]] = [:]
        for sym in table.symbols { byName[sym.name, default: []].append(sym) }
        var result: [String: [String: Symbol]] = [:]
        for (name, syms) in byName {
            let eligible = syms.allSatisfy { sym in
                guard let scope = sym.scope else { return false }
                return table.isExternalExtensionScope(scope) && map.obf(for: sym) != nil
            }
            guard eligible else { continue }
            var byModule: [String: Symbol] = [:]
            var ambiguous = false
            for sym in syms {
                if byModule.updateValue(sym, forKey: sym.module.name) != nil { ambiguous = true }
            }
            if !ambiguous { result[name] = byModule }
        }
        return result
    }

    public func run(on files: [SourceFile]) -> [Rename] {
        var renames: [Rename] = []

        // 1) Declaration renames — for every symbol that has an obf name.
        for sym in table.symbols {
            guard let obf = map.obf(for: sym) else { continue }
            renames.append(Rename(
                file: sym.file,
                offset: sym.declOffset,
                length: sym.declLength,
                original: sym.name,
                replacement: NamePool.wrapIfKeyword(obf),
                targetSymbolId: sym.id
            ))
        }

        // 1b) Index-driven use-site renames (opt-in, index active). These come from the compiler's
        // occurrence set (USR ground truth), so they cover the use-sites the syntactic resolver
        // cannot type (`receiver-untyped`, generic substitution). Their positions are recorded so
        // the syntactic pass below defers to them: the index wins wherever it has an occurrence, and
        // syntax fills the rest (the ~15% of symbols the index never maps, plus every unindexed
        // position). Declaration renames stay on the pass-1 loop above — the emitter skips each
        // declaration's own occurrence — so this only ever adds use-site edits.
        var coveredByIndex: [ObjectIdentifier: Set<Int>] = [:]
        // `--explain` only: offset → the symbol the index-driven edit targets, so a use-site the
        // resolver DECLINED (`receiver-untyped`) but the index renamed is recorded as the rewrite it
        // actually is, not as a survivor. Built only when recording is on.
        var indexTargetByOffset: [ObjectIdentifier: [Int: Int]] = [:]
        if let ctx = indexContext {
            let result = IndexDrivenRenamer(table: table, map: map, ctx: ctx, logger: logger)
                .run(on: files.filter { $0.module.writable })
            renames.append(contentsOf: result.renames)
            coveredByIndex = result.coveredOffsetsByFile
            if useSiteLog != nil {
                for r in result.renames {
                    indexTargetByOffset[ObjectIdentifier(r.file), default: [:]][r.offset] = r.targetSymbolId
                }
            }
        }

        // 2) Use-site renames — walk each writable file's syntax tree.
        let uniqueExternal = uniqueExternalMembers
            ? Self.uniqueExternalExtensionMembers(in: table, map: map) : [:]
        // Layer 2 filter: a use-site is worth describing when its name is declared by at least one
        // symbol of a WRITABLE module. Wider than `renamedNames` on purpose (a protected or
        // policy-skipped project symbol is exactly what explains a name that stayed original), and
        // narrow enough to drop the SDK bulk (`padding`, `leading`, `font`).
        var projectNames: Set<String> = []
        if useSiteLog != nil {
            for sym in table.symbols where sym.module.writable { projectNames.insert(sym.name) }
        }
        for file in files where file.module.writable {
            guard let fileScope = table.fileScopes[ObjectIdentifier(file)] else { continue }
            let fileKey = ObjectIdentifier(file)
            let covered = coveredByIndex[fileKey] ?? []
            let indexTargets = indexTargetByOffset[fileKey] ?? [:]
            let visitor = ResolutionVisitor(file: file, table: table, map: map, fileScope: fileScope,
                                            indexContext: indexContext,
                                            uniqueExternalMembers: uniqueExternal,
                                            useSiteLog: useSiteLog,
                                            projectNames: projectNames,
                                            indexCoveredOffsets: covered,
                                            indexTargetByOffset: indexTargets)
            visitor.walk(file.syntax)
            // Index priority: drop any syntactic edit at a position the index already resolved, so
            // the compiler's pick stands where it disagrees with the syntactic guess.
            if covered.isEmpty {
                renames.append(contentsOf: visitor.renames)
            } else {
                renames.append(contentsOf: visitor.renames.filter { !covered.contains($0.offset) })
            }
            // Prove the instrumentation's own coverage: any use-site position the resolver made no
            // decision about becomes a `no-decision` record rather than silence. A position the index
            // renamed but the resolver never visited is a rewrite, not a survivor.
            if let log = useSiteLog {
                let sweep = UseSiteSweep()
                sweep.walk(file.syntax)
                for site in sweep.sites
                where !visitor.recordedOffsets.contains(site.offset)
                   && projectNames.contains(site.name) {
                    if covered.contains(site.offset), let tid = indexTargets[site.offset] {
                        log.record(UseSiteRecord(filePath: file.url.path, offset: site.offset,
                                                 name: site.name,
                                                 outcome: .rewritten(targetSymbolId: tid)))
                    } else {
                        log.record(UseSiteRecord(
                            filePath: file.url.path, offset: site.offset, name: site.name,
                            outcome: .kept(cause: .noDecision, receiver: nil, candidateIds: [])))
                    }
                }
            }
        }

        return renames
    }
}

/// Why the resolver left a use-site un-rewritten. A CLOSED set: every declined `UseSiteRecord`
/// carries exactly one of these, so the report can be grepped and counted by cause.
///
/// The reporting this replaced answered only two questions — "which overload sets were ambiguous"
/// and "which original names survived into the output" — and neither says why a given use-site was
/// skipped. On a run where ~119 method names had surviving use-sites, the overload report produced a
/// SINGLE line, because it fired only when >1 candidate matched the labels AND argument types could
/// not pick one. Everything else resolved to nothing, silently.
public enum UnresolvedCause: String, CaseIterable {
    /// The receiver expression could not be typed at all, so no member scope was ever searched.
    case receiverUntyped = "receiver-untyped"
    /// The receiver typed fine, but its scope declares no member of that name (a member inherited
    /// from a superclass, a receiver we typed to the wrong thing, or a declaration we never saw).
    case noCandidateInScope = "no-candidate-in-scope"
    /// Several same-named candidates of different KINDS survived the position filter (e.g. a
    /// property and a nested type), so the rewrite target is genuinely ambiguous.
    case mixedKindCandidates = "mixed-kind-candidates"
    /// Several same-kind candidates and no argument signal picks one.
    case ambiguousOverload = "ambiguous-overload"
    /// The receiver's own scope declares this name at the WRONG kind for the position and something
    /// it INHERITS — a superclass (B-FIX-47) or a conformed protocol's extension default
    /// (B-FIX-48) — declares it at the right one, but which of the two the compiler picks depends on
    /// type information we do not have: a closure-typed property really does shadow the inherited
    /// method it is called instead of, and a function-typed context really does pick the local
    /// method over the inherited property. Fail closed: the use-site keeps its original name, so
    /// RollbackPass sees the survivor and reverts.
    case inheritedKindConflict = "inherited-kind-conflict"
    /// Resolved to exactly one declaration which is deliberately not renamed (protected or
    /// policy-skipped). Low-signal: the use-site is correct as it stands.
    case candidateHasNoObf = "candidate-has-no-obf"
    /// A base-less `.member` shorthand whose contextual type could not be determined.
    case noContextualType = "no-contextual-type"

    /// The resolver walked past this use-site without recording any outcome. Emitted by the
    /// post-walk sweep (`UseSiteSweep`), never by the resolver itself: it is the residue that
    /// proves the instrumentation's own coverage, so it is high-signal by construction.
    case noDecision = "no-decision"

    /// Low-signal causes go to the `v ` tier, the same split the report's `v ` tier makes: a use-site we
    /// resolved and deliberately left alone is not a lead, it is the answer.
    public var isExplained: Bool { self == .candidateHasNoObf }

    /// Is a use-site declined for this cause a LEAD for a red build — a place where the original name
    /// survives and the reader should suspect a desync we shipped?
    ///
    /// Consumed by the summary's tiering of `RollbackResult.blockedNames`: a shielded survivor whose
    /// every recorded decline is a non-lead has a benign reading and is demoted out of RED BUILD RISK.
    ///
    /// `receiver-untyped` / `no-contextual-type` are non-leads because they are the shape of an Apple
    /// modifier chain (`.font(.headline)` on a `some View`), which is where the bulk of them come
    /// from. They are NOT proof: the SAME record shape covers a use-site of OUR OWN that we failed to
    /// type, which is exactly why this only demotes a name to a softer section and never removes it.
    ///
    /// The switch is exhaustive on purpose. A new cause must be classified deliberately, and the
    /// fail-closed answer for one is `true`.
    public var isRedBuildLead: Bool {
        switch self {
        case .receiverUntyped, .noContextualType:
            return false        // unresolvable member chain; see the caveat above
        case .candidateHasNoObf:
            return false        // resolved to a declaration we chose not to rename: correct as it stands
        case .noCandidateInScope, .mixedKindCandidates, .ambiguousOverload,
             .inheritedKindConflict, .noDecision:
            return true
        }
    }

    /// One-line plain-English statement of the cause, rendered into the report next to the
    /// use-site. The enum is the ONE source: `Diagnostics.txt` used to carry a hand-maintained
    /// header listing the causes, which is how `inherited-kind-conflict` shipped undocumented in
    /// that header.
    public var gloss: String {
        switch self {
        case .receiverUntyped:
            return "the receiver expression could not be typed, so no member scope was searched"
        case .noCandidateInScope:
            return "the receiver typed fine, but declares no member of that name"
        case .mixedKindCandidates:
            return "the name is declared at several kinds here and the position rule could not narrow it"
        case .ambiguousOverload:
            return "several same-kind candidates and no argument type picks one"
        case .inheritedKindConflict:
            return "the type declares this name at the wrong kind and inherits it at the right one; "
                 + "which one Swift picks needs type information we do not have"
        case .candidateHasNoObf:
            return "resolved to one declaration that is deliberately not renamed; this line is correct as it stands"
        case .noContextualType:
            return "a base-less `.member` whose contextual type could not be determined"
        case .noDecision:
            return "the resolver walked past this use-site without recording an outcome; a reporter gap, please file it"
        }
    }
}

/// Outcome of resolving one use-site: the rewrite target (if any) and, when the resolver declined,
/// WHY. Returning the cause instead of a bare `Symbol?` is what lets a SINGLE reporting helper
/// record the decline — the classification stays in the one function that has the knowledge, rather
/// than being re-derived (and drifting) at each of the member-access branches.
struct LookupOutcome {
    let symbol: Symbol?
    let cause: UnresolvedCause?
    /// Symbol ids of the candidates that made this ambiguous, so the report can NAME them
    /// (`candidate: File.swift:12 Owner.member`) instead of printing a bare count. Empty when the
    /// cause is not about a candidate SET (`receiver-untyped`, `no-contextual-type`).
    let candidateIds: [Int]

    static func resolved(_ s: Symbol) -> LookupOutcome {
        .init(symbol: s, cause: nil, candidateIds: [])
    }
    static func failed(_ c: UnresolvedCause, candidateIds: [Int] = []) -> LookupOutcome {
        .init(symbol: nil, cause: c, candidateIds: candidateIds)
    }
}

private final class ResolutionVisitor: SyntaxVisitor {
    let file: SourceFile
    let table: SymbolTable
    let map: RenameMap
    let typeResolver: TypeResolver
    /// Cache of module-scoped resolvers (`resolveParamType` / `typealiasUnwrap` need a resolver in
    /// a candidate's OWN module). Reused so we don't allocate a fresh TypeResolver — and discard its
    /// memo cache — on every call (C-3).
    private var resolverByModule: [String: TypeResolver] = [:]
    /// `class symbol id → its LOCAL ancestors, nearest first`. `SuperclassChain.ancestors` re-parses
    /// the declaring file to read the inheritance clause, and `inheritedMembers` asks per use-site.
    var ancestorCache: [Int: [Symbol]] = [:]
    /// `type symbol id → the LOCAL protocols it (or an ancestor) conforms to, nearest first`. Same
    /// reason as `ancestorCache`: `ConformanceChain.protocols` re-parses the declaring file per level
    /// of the protocol graph, and `inheritedMembers` asks per use-site (B-FIX-48).
    var conformanceCache: [Int: [Symbol]] = [:]
    var renames: [Rename] = []
    var scopeStack: [Scope]
    /// Names introduced by optional bindings (`guard let x`, `if let x`, `while let x`) that
    /// are currently in lexical scope. Such a name shadows any same-named property/global —
    /// references to it must NOT be renamed to the shadowed declaration's obf. Flow-sensitive:
    /// a binding is added only AFTER its initializer has been visited (so `guard let x = x`
    /// correctly resolves the RHS to the outer `x`).
    ///
    /// A frame is pushed per SCOPE NODE — every kind in `ScopeNodes.kinds`, so since B-FIX-39 that
    /// includes every braced block, not just functions and closures. That is exactly why an entry
    /// needs an end: an `if let` condition is visited BEFORE the body's block scope is entered, so
    /// its binding lands in the ENCLOSING frame and would otherwise outlive the statement
    /// (B-FIX-45). See `BindingFrames` for the rule.
    ///
    /// Each frame also carries the SCOPE it was pushed for, so a lookup can tell whether a
    /// same-named declaration was written deeper than the binding and therefore beats it
    /// (B-FIX-46) — hence every read names its competitor.
    var shadowFrames: BindingFrames<Void>
    /// Parallel to `shadowFrames`: the STATIC TYPE of each in-scope binding, keyed by bound name. An
    /// `if let u = makeURL()` binding carries no `declaredType` (it's not a declared symbol), so a
    /// call `c.f(u)` had no way to disambiguate overloads. Recording the binding's type here lets
    /// `argConstraint` type such a use-site argument (B-FIX-11 follow-up) and lets `typeSymbol(of:)`
    /// resolve member access through it. Tracked here rather than as a real Symbol so the binding
    /// never shadows the same-named property during the binding's OWN initializer resolution
    /// (`guard let x = x` — the RHS must still resolve to the property).
    ///
    /// The value is a (name, scope) PAIR, never a bare name (B-FIX-35): the name is either written at
    /// the binding (`guard let r: Section.Row = …`, resolves where written) or inferred from the
    /// initializer (resolves in the type's DECLARING scope — a nested `Row` is invisible from the
    /// use-site). Re-resolving a bare name at the use-site is the B-FIX-23 defect.
    ///
    /// Each entry answers only over the REGION it was bound in — the statement body for an `if
    /// case`/`while case` payload binding (B-FIX-42) and for an `if let` / `while let` optional
    /// binding (B-FIX-45), both of which die with their statement while this frame (the enclosing
    /// block's) lives on to the end of the method; and for a `guard`, whose binding outlives its
    /// statement, no end but a HOLE over the guard's own `else` body (B-FIX-50). It is the type half
    /// of the same region `Symbol.conditionBinding` carries for the scope half, and both come from
    /// `ConditionBindingExtent`.
    var shadowBindingTypeFrames: BindingFrames<(name: String, scope: Scope)>
    /// Token ids whose rename decision was already made by qualified-type-chain resolution
    /// (`A.B.C`). Set by the outermost MemberType node; consulted by the inner MemberType nodes
    /// and the root IdentifierType so they do NOT independently rename a partial root match
    /// (which produced compile-breaking `<wrongObf>.Member` against a same-named sibling type).
    var chainHandled: Set<SyntaxIdentifier> = []

    /// A4 context (nil ⇒ syntactic only). When present, the per-file converter + normalized path
    /// let any TypeResolver turn a use-site offset into the line:column the index keys on.
    let indexContext: IndexContext?
    private let useSiteFilePath: String?
    private let useSiteConverter: SourceLocationConverter?
    /// Project-unique members of external-type extensions (see
    /// `ResolutionPass.uniqueExternalExtensionMembers`); empty when the feature is off.
    private let uniqueExternalMembers: [String: [String: Symbol]]
    /// Where use-site records go (`--explain`). nil ⇒ recording off.
    private let useSiteLog: UseSiteLog?
    /// Names declared by a writable-module symbol. The layer 2 filter.
    private let projectNames: Set<String>
    /// Positions the index-driven emitter renamed (`--explain` only; empty otherwise). A use-site the
    /// resolver DECLINES here was actually rewritten by the index, so it is recorded as a rewrite, not
    /// a survivor — otherwise the report over-counts `receiver-untyped` at positions that WERE renamed.
    private let indexCoveredOffsets: Set<Int>
    /// offset → the symbol id the index-driven edit at that offset targets. Read alongside
    /// `indexCoveredOffsets` when recording an otherwise-declined use-site.
    private let indexTargetByOffset: [Int: Int]
    /// Every use-site offset this visitor made a decision about, filtered or not. `UseSiteSweep`
    /// (Task 3) diffs against it, so an offset deliberately dropped by `projectNames` must still be
    /// inserted here or the sweep would re-report it as a reporter gap.
    var recordedOffsets: Set<Int> = []

    init(file: SourceFile, table: SymbolTable, map: RenameMap, fileScope: Scope,
         indexContext: IndexContext? = nil,
         uniqueExternalMembers: [String: [String: Symbol]] = [:],
         useSiteLog: UseSiteLog? = nil,
         projectNames: Set<String> = [],
         indexCoveredOffsets: Set<Int> = [],
         indexTargetByOffset: [Int: Int] = [:]) {
        self.file = file
        self.table = table
        self.map = map
        self.indexContext = indexContext
        self.uniqueExternalMembers = uniqueExternalMembers
        self.useSiteLog = useSiteLog
        self.projectNames = projectNames
        self.indexCoveredOffsets = indexCoveredOffsets
        self.indexTargetByOffset = indexTargetByOffset
        // Build the converter only when the index is engaged (it parses positions; skip the cost
        // on the syntactic baseline). Use locals to avoid reading self before super.init.
        let path: String?
        let conv: SourceLocationConverter?
        if indexContext != nil {
            path = USRIndex.normalize(file.url.path)
            conv = SourceLocationConverter(fileName: file.url.path, tree: file.syntax)
        } else {
            path = nil
            conv = nil
        }
        self.useSiteFilePath = path
        self.useSiteConverter = conv
        self.typeResolver = TypeResolver(table: table, preferredModule: file.module.name,
                                         indexContext: indexContext,
                                         useSiteFilePath: path,
                                         useSiteConverter: conv)
        self.scopeStack = [fileScope]
        // The bottom frame is the file scope's, so a binding written at top level is measured at
        // the same depth every other frame is (B-FIX-46).
        self.shadowFrames = BindingFrames(root: fileScope)
        self.shadowBindingTypeFrames = BindingFrames(root: fileScope)
        super.init(viewMode: .sourceAccurate)
        // Let TypeResolver type optional-binding locals (not Symbols) via the flow-sensitive tracker,
        // so member/chain resolution on a binding (`if let acc = makeFoo(); acc.x.y`) works. Safe: the
        // tracker is read at call time (typeSymbol(of:) is uncached), reflecting the current flow.
        // The offset is the reference's own position: a condition binding stops answering at the end
        // of its statement's body, even though the frame holding it lives longer (B-FIX-42).
        // The third argument is the competitor: the scope the same-named declaration the resolver's
        // own lookup found was written in. A binding loses only to one written DEEPER than its own
        // frame (B-FIX-46), and the resolver is the side that knows what it found.
        self.typeResolver.localBindingTypeName = { [weak self] name, at, competitor in
            self?.localBindingType(name, at: at, outScoping: competitor)
        }
    }

    /// The ONE place a declined use-site becomes a record. Every branch that gives up routes here
    /// rather than recording inline, so the filter, the position lookup and the cause classification
    /// stay in a single spot — instrumenting per resolver BRANCH is how the previous reporting ended
    /// up covering one case in twelve.
    ///
    /// Costs nothing on the default path: `useSiteLog` is nil and the guard fires first.
    private func reportUnresolved(_ cause: UnresolvedCause, name: String, token: TokenSyntax,
                                  receiver: String? = nil, candidateIds: [Int] = []) {
        // Guarded at the caller, not inside `recordUseSite`: Swift evaluates arguments eagerly, so
        // an inner nil-check would still pay for the position lookup and the `.kept(...)`
        // construction on every declined use-site of the default path (see `emitRename`).
        //
        // `candidateIds` is deliberately NOT deferred behind an `@autoclosure`, unlike the position
        // lookup. Its callers already hold the candidate array (they built it to classify the cause
        // at all), so the eager cost is one small `map` on a path that only runs when resolution
        // FAILED — not the per-use-site hot path the guard rule exists for.
        //
        // `.candidateHasNoObf` fires exactly where the caller is about to call `emitRename` on this
        // same token — the resolved-but-not-renamed target IS the record for this position, and it's
        // strictly more informative (it names the target). Recording a `.kept` here too would leave
        // two contradicting records at one source position.
        guard useSiteLog != nil, cause != .candidateHasNoObf else { return }
        let offset = token.positionAfterSkippingLeadingTrivia.utf8Offset
        // The index-driven emitter renamed this position, so the syntactic decline is not what
        // happened here: record the rewrite the index made, not a `receiver-untyped` survivor.
        if let tid = indexTargetByOffset[offset], indexCoveredOffsets.contains(offset) {
            recordUseSite(name: name, offset: offset, outcome: .rewritten(targetSymbolId: tid))
            return
        }
        recordUseSite(name: name, offset: offset,
                      outcome: .kept(cause: cause, receiver: receiver, candidateIds: candidateIds))
    }

    /// The ONE place a use-site becomes a record. Costs nothing when `useSiteLog` is nil.
    func recordUseSite(name: String, offset: Int, outcome: UseSiteRecord.Outcome) {
        guard let log = useSiteLog else { return }
        recordedOffsets.insert(offset)
        guard projectNames.contains(name) else { return }
        log.record(UseSiteRecord(filePath: file.url.path, offset: offset,
                                 name: name, outcome: outcome))
    }

    /// Report a `LookupOutcome` that carries a cause. Returns the outcome's symbol so call sites
    /// read as `if let m = report(lookupMember(…), …) { emitRename(…) }`.
    @discardableResult
    private func report(_ outcome: LookupOutcome, name: String, token: TokenSyntax,
                        receiver: Symbol?) -> Symbol? {
        if let cause = outcome.cause {
            reportUnresolved(cause, name: name, token: token, receiver: receiver?.name,
                             candidateIds: outcome.candidateIds)
        }
        return outcome.symbol
    }

    private var currentScope: Scope { scopeStack.last! }

    /// A reusable TypeResolver scoped to `module` (memoized — see `resolverByModule`).
    private func resolver(forModule module: String) -> TypeResolver {
        if module == file.module.name { return typeResolver }
        if let r = resolverByModule[module] { return r }
        // Use-site file/converter are the SAME (this visitor's file); only the preferred MODULE
        // differs, so the A4 context is shared.
        let r = TypeResolver(table: table, preferredModule: module,
                             indexContext: indexContext,
                             useSiteFilePath: useSiteFilePath,
                             useSiteConverter: useSiteConverter)
        resolverByModule[module] = r
        return r
    }

    /// True if `name` is shadowed by an in-scope optional binding (so it's a local, not a
    /// reference to the same-named declaration we may have renamed).
    ///
    /// `at` is the USE-SITE offset, and an `if let` / `while let` binding stops answering at the
    /// end of its statement's body (B-FIX-45): without it the name stayed "a local" for the rest
    /// of the enclosing block, so the read BELOW the statement — which is the same-named property —
    /// was skipped entirely while that property's declaration renamed.
    ///
    /// The competitor is what stops the binding from claiming a name that a DEEPER declaration owns
    /// (B-FIX-46): `if let slot = payload { … { let slot = DetailA(); slot.holdA } … }` reads the
    /// closure's local, which renames — so skipping its use-site here left the original name on a
    /// renamed declaration ("cannot find 'slot' in scope"). The lookup is inside a closure because
    /// every bare reference reaches this method and almost none of them is bound.
    private func isLocallyShadowed(_ name: String, at offset: Int?) -> Bool {
        shadowFrames.isBound(name, at: offset) { currentScope.lookup(name: name, at: offset)?.scope }
    }

    /// Swift scoping invariant: a `let`/`var` local is NOT in scope within its OWN initializer.
    /// True when `node` sits inside the initializer of the SPECIFIC binding that declares `sym` — so
    /// a reference resolving lexically to `sym` there must instead resolve to the ENCLOSING
    /// declaration (an outer property or a method), never to the not-yet-declared local. Matching is
    /// by decl OFFSET, not by name: a same-named OUTER binding whose initializer also encloses
    /// `node` (e.g. `var resource = { let resource = …; return resource }()` — the property's closure
    /// initializer contains the local's `return resource`) must NOT trip this, since that reference
    /// legitimately targets the inner local, which is fully in scope. Plain locals are static scope
    /// symbols (unlike flow-sensitive optional bindings, which `shadowFrames` already covers), so
    /// `currentScope.lookup` would otherwise hand back the not-yet-in-scope local and shadow the
    /// real target.
    private func isInsideOwnInitializer(of sym: Symbol, node: some SyntaxProtocol) -> Bool {
        var child = Syntax(node)
        var parent = node.parent
        while let p = parent {
            if let binding = p.as(PatternBindingSyntax.self),
               let initializer = binding.initializer,
               child.id == Syntax(initializer).id,
               Self.patternDeclares(binding.pattern, at: sym.declOffset) {
                return true
            }
            child = p
            parent = p.parent
        }
        return false
    }

    /// `currentScope.lookup(name:)` for a bare reference, at the use-site's POSITION (a local of a
    /// braced block is visible only after its declaration, so an earlier reference reads the outer
    /// parameter/property) and honouring the own-initializer rule: when the innermost match is a
    /// value local whose initializer contains `node`, resolve the name from the local's ENCLOSING
    /// scope instead (so `count` in `let count = count + 1` reads the outer property). The two rules
    /// are complementary — the initializer sits AFTER the declaration's identifier, so position
    /// alone never catches it.
    private func lookupOutsideOwnInitializer(name: String, at node: some SyntaxProtocol) -> Symbol? {
        let offset = node.positionAfterSkippingLeadingTrivia.utf8Offset
        guard let sym = currentScope.lookup(name: name, at: offset) else { return nil }
        guard Self.isValueBinding(sym.kind), let declScope = sym.scope,
              isInsideOwnInitializer(of: sym, node: node) else { return sym }
        // Re-resolve as if the local did not exist: from just before its own declaration. This finds
        // a same-scope shadowed PARAMETER (a closure's `{ p in var p = p }`, where parameter and body
        // local share ONE scope, B-FIX-59) — which `declScope.parent` would skip — and otherwise
        // walks the enclosing chain exactly as before (`let count = count + 1` reads the property).
        return declScope.lookup(name: name, at: sym.declOffset - 1)
    }

    /// Whether `pattern` declares an identifier at decl-offset `offset` (`let name`, or a tuple
    /// element). Offset-keyed so it identifies the EXACT binding, not merely a same-named one.
    static func patternDeclares(_ pattern: PatternSyntax, at offset: Int) -> Bool {
        if let ident = pattern.as(IdentifierPatternSyntax.self) {
            return ident.identifier.positionAfterSkippingLeadingTrivia.utf8Offset == offset
        }
        if let tuple = pattern.as(TuplePatternSyntax.self) {
            return tuple.elements.contains { patternDeclares($0.pattern, at: offset) }
        }
        return false
    }

    /// A value binding (local var/let or a parameter) — the kinds that obey the own-initializer rule
    /// and can legitimately be an invoked closure value. NOT callable declarations (method/function).
    static func isValueBinding(_ k: SymbolKind) -> Bool { k == .property || k == .parameter }

    /// `currentScope.lookup` for a name in CALLEE position (`name(args)`).
    ///
    /// Swift's unqualified lookup stops at the innermost scope that declares the name, and
    /// `Scope.lookup` returns that level's FIRST declaration in SOURCE ORDER — kind-blind. When one
    /// level declares both a value and a callable of the name (`var pf2: Bool` next to
    /// `func pf2(for:) -> Bool`, the shape a protocol overloading one name across kinds produces),
    /// first-in-order is a coin flip: picking the value rewrites the call's callee to a PROPERTY's
    /// obf, which is a wrong rename RollbackPass cannot catch. A callee denotes a callable, so
    /// prefer one at the level that declares the name.
    ///
    /// The value is still returned when that level declares no callable — a closure-typed property
    /// or parameter genuinely IS invoked as `content()`, and that branch must keep working. When a
    /// callable wins, the caller's `switch` falls through to `resolveCall`, which does full
    /// label/type-aware overload resolution over the same level.
    ///
    /// `at` is the use-site offset, applied through `Scope.declarations(named:visibleAt:)` so a
    /// level counts as declaring the name only where the declaration is already VISIBLE (B-FIX-40):
    /// a closure-typed local shadows a same-named method only from its own declaration onward, so
    /// `let a = compute(); let compute = { … }` calls the METHOD on the first line (verified against
    /// swiftc — it compiles and runs). Answering with the local rewrote that call to the local's obf
    /// ⇒ "use of local variable … before its declaration".
    private func lookupCallee(named name: String, at offset: Int? = nil) -> Symbol? {
        var s: Scope? = currentScope
        var at = offset
        while let cur = s {
            let level = cur.declarations(named: name, visibleAt: at)
            if !level.isEmpty {
                return Self.narrowed(level, to: .callee).first
            }
            at = cur.offsetForParent(at)
            s = cur.parent
        }
        return nil
    }

    private func enterInnerScope(of node: some SyntaxProtocol) {
        if let s = table.innerScope[node.id] {
            scopeStack.append(s)
            shadowFrames.push(s)   // new lexical frame for bindings, at that scope's depth
            shadowBindingTypeFrames.push(s)
        }
    }
    private func exitInnerScope(of node: some SyntaxProtocol) {
        if table.innerScope[node.id] != nil {
            scopeStack.removeLast()
            shadowFrames.pop()
            shadowBindingTypeFrames.pop()
        }
    }

    /// The static type of an in-scope binding named `name`, if recorded: the type NAME plus the scope
    /// that name resolves in. Searches frames innermost-out (mirrors `shadowFrames`).
    ///
    /// `at` is the use-site offset, and an entry that ends stops answering there — the frame
    /// outlives the `if case` / `if let` that recorded it, so without this the binding's type still
    /// typed the same-named outer symbol below the statement (B-FIX-42, B-FIX-45). A caller with no
    /// use-site passes nothing and keeps the old, position-blind answer.
    ///
    /// An expired entry does not end the search, it is SKIPPED: the name is simply not bound by
    /// that entry at this position, so an earlier still-live binding of the same name is the right
    /// answer (a `guard` binding that an inner `if let` shadowed for the length of its body). Same
    /// rule `Scope.declarations(named:visibleAt:)` applies to the scope chain — see `BindingFrames`.
    ///
    /// `competitor` is the scope the same-named DECLARATION visible here was written in, and the
    /// binding answers only while nothing deeper owns the name (B-FIX-46). It is the type half of
    /// the same rule `isLocallyShadowed` applies to the name.
    private func shadowBindingType(_ name: String, at offset: Int?,
                                   outScoping competitor: () -> Scope?)
        -> (name: String, scope: Scope)? {
        shadowBindingTypeFrames.newest(name, at: offset, outScoping: competitor)
    }

    /// What `name` means at `offset` when a flow-sensitive binding owns it — the whole answer the
    /// `TypeResolver` provider hands back, read from BOTH stacks in the one place that can keep
    /// them consistent.
    ///
    /// The type stack is asked first because it is the wider one: it also holds `if case` /
    /// `switch case` PAYLOAD bindings, which are real scope Symbols and never enter `shadowFrames`
    /// (B-FIX-29/42). Only when it has nothing does the name stack decide whether an OPTIONAL
    /// binding owns the name untyped — the `while let slot = it.next()` shape, where answering
    /// `nil` would hand the reference to the property the binding shadows (B-FIX-46).
    private func localBindingType(_ name: String, at offset: Int?,
                                  outScoping competitor: Scope?) -> LocalBindingType? {
        if let t = shadowBindingType(name, at: offset, outScoping: { competitor }) {
            return .typed(name: t.name, scope: t.scope)
        }
        if shadowFrames.isBound(name, at: offset, outScoping: { competitor }) { return .untyped }
        return nil
    }

    /// Type the bindings of an enum-case pattern (`case .run(let m)`, `case let .run(m)`) from the
    /// case's ASSOCIATED VALUE types, taken off the switch subject's enum. DeclarationPass registers
    /// those bindings as untyped locals (F1 shadowing) and nothing ever typed them, so a member
    /// access or a comparison through the payload had no context: the survivor then reverted the
    /// PAYLOAD enum's whole case group.
    ///
    /// The stored name is QUALIFIED (`NS.Mood`), because the associated type is written in the
    /// enum's own scope and the binding is read at the use-site (B-FIX-23 discipline). Fail-closed:
    /// an unresolvable subject, an unknown case, or a payload arity that doesn't line up with the
    /// pattern records nothing.
    private func recordEnumPayloadBindingTypes(of caseNode: SwitchCaseSyntax) {
        guard let label = caseNode.label.as(SwitchCaseLabelSyntax.self),
              let subject = Self.enclosingSwitchSubject(of: caseNode) else { return }
        for item in label.caseItems {
            recordEnumPayloadBindingTypes(pattern: item.pattern, matching: subject)
        }
    }

    /// Core of the above, shared with the `if/guard/while case .run(let m) = value` condition form:
    /// one pattern matched against one expression. Same fail-closed contract.
    ///
    /// `visibleIn` is the region the recorded types answer over — set by the condition entry point,
    /// whose bindings die with the statement's body (`if case` / `while case`) or skip the `else`
    /// body (`guard case`) while this frame does neither (B-FIX-42, B-FIX-50). A `switch` case
    /// passes nil: its frame is popped with its own scope.
    private func recordEnumPayloadBindingTypes(pattern: PatternSyntax, matching subject: ExprSyntax,
                                               visibleIn extent: ConditionBindingExtent.Visibility? = nil) {
        // A TUPLE pattern (`if case (let x, let y) = t`, `switch t { case (let x, let y): }`,
        // `guard case let (x, y) = t`, `if case (let x, let y)? = optT`) binds each identifier leaf to
        // the corresponding COMPONENT of the subject's TUPLE type — the pattern-matching sibling of the
        // tuple member access in B-FIX-69 (B-FIX-79). The subject's tuple type comes from
        // `receiverTypeInfo` (a written tuple via `tupleDeclaredType`, B-FIX-78, or a synthesized
        // `enumerated`/`zip`/dictionary tuple), unwrapped through any `typealias` by `expandedTypeName`.
        // A tuple pattern is never an enum-case pattern (that is an `ExpressionPattern` wrapping a
        // FunctionCall, this one wraps a TupleExpr), so this precedes the enum branches. Fail-closed per
        // leaf: a path that does not line up with the subject's components leaves that leaf untyped.
        if let leaves = Self.tuplePatternLeaves(of: pattern),
           let info = typeResolver.receiverTypeInfo(of: subject, in: currentScope) {
            recordTupleLeafTypes(leaves, tupleTypeName: info.name, in: info.declScope, visibleIn: extent)
            return
        }
        // LOCAL enum: the case's associated types are recorded and resolve in the enum's own scope.
        if let enumSym = typeResolver.typeSymbol(of: subject, in: currentScope), enumSym.kind == .enum,
           recordEnumPayloadTypes(pattern: pattern, enumSym: enumSym, substitutionReceiver: subject,
                                  visibleIn: extent) {
            return
        }
        // Stdlib `Result<Success, Failure>` (B-FIX-57): not in our table and its payloads are generic,
        // so the local path above cannot type `.success(let x)`. Result's shape is fixed, so model it.
        recordResultPayloadBindingTypes(pattern: pattern, matching: subject, visibleIn: extent)
    }

    /// Bind each tuple-pattern leaf to the component of `tupleTypeName` at its path (B-FIX-79),
    /// resolved in `scope`. Shared by the condition/switch recorder above and the for-case recorder
    /// (B-FIX-81). `expandedTypeName` unwraps a `typealias`; a leaf whose component the path cannot
    /// reach is left untyped (fail-closed).
    private func recordTupleLeafTypes(_ leaves: [(name: String, path: [(index: Int, arity: Int)])],
                                      tupleTypeName name: String, in scope: Scope,
                                      visibleIn extent: ConditionBindingExtent.Visibility?) {
        let expanded = typeResolver.expandedTypeName(name, in: scope)
        for leaf in leaves {
            guard let component = TupleTypeName.component(at: leaf.path, of: expanded.name) else { continue }
            let resolved = typeResolver.typeSymbol(forQualifiedName: component, in: expanded.scope)
            let bound = resolved.map { ($0.name, $0.scope ?? expanded.scope) } ?? (component, expanded.scope)
            shadowBindingTypeFrames.bind(leaf.name, visibleIn: extent, (name: bound.0, scope: bound.1))
        }
    }

    /// Record the payload bindings of an enum-case pattern (`case .run(let m)`) from `enumSym`'s case
    /// associated types. Returns true when it recorded (the caller then stops), false when the pattern
    /// is not a matching case of this enum (the caller falls through to Result). Shared by the
    /// condition/switch recorder (which passes the subject expression for B-FIX-63 generic
    /// substitution) and the for-case recorder (which has no subject expression and passes nil, so a
    /// generic enum payload stays fail-closed there).
    private func recordEnumPayloadTypes(pattern: PatternSyntax, enumSym: Symbol,
                                        substitutionReceiver: ExprSyntax?,
                                        visibleIn extent: ConditionBindingExtent.Visibility?) -> Bool {
        guard let enumScope = innerScope(of: enumSym),
              let (caseName, bindings) = Self.enumPatternBindings(of: pattern),
              let caseSym = enumScope.members(named: caseName).first(where: { $0.kind == .enumCase }),
              let types = table.enumCaseAssociatedTypes[caseSym.id],
              types.count == bindings.count else { return false }
        let caseScope = caseSym.scope ?? currentScope
        for (binding, type) in zip(bindings, types) {
            guard let binding, let type else { continue }
            // The associated type may BE the enum's generic parameter (`case filled(Wrapped)` on a
            // `Boxed<Payload>` subject) — substitute the concrete argument the subject carries
            // (B-FIX-63). Only when a subject expression is available; a for-case element has none.
            if let receiver = substitutionReceiver,
               let sub = typeResolver.substitutedGenericMemberType(type, receiver: receiver, in: currentScope) {
                let resolved = typeResolver.typeSymbol(forQualifiedName: sub.name, in: sub.scope)
                let bound = resolved.map { ($0.name, $0.scope ?? sub.scope) } ?? (sub.name, sub.scope)
                shadowBindingTypeFrames.bind(binding, visibleIn: extent, (name: bound.0, scope: bound.1))
                continue
            }
            // The associated type is WRITTEN in the enum's own scope, so that is where it resolves.
            // Storing the pair keeps that fact with the name instead of qualifying the string (B-FIX-35).
            let resolved = typeResolver.typeSymbol(forQualifiedName: type, in: caseScope)
            let info = resolved.map { ($0.name, $0.scope ?? caseScope) } ?? (type, caseScope)
            shadowBindingTypeFrames.bind(binding, visibleIn: extent, (name: info.0, scope: info.1))
        }
        return true
    }

    /// Type the bindings of a `for case <pattern> in <seq>` (B-FIX-81). The pattern is matched against
    /// each ELEMENT of the sequence, so the "subject" is the sequence's iteration element — a tuple
    /// pattern (`for case (_, let cell) in pairs`) destructures the element's tuple, an enum-case
    /// pattern (`for case .loaded(let row) in states`) takes the case's payload. The bindings live in
    /// the loop scope, so they are recorded with a nil extent (the frame is popped with the ForStmt
    /// scope, exactly like a `switch` case). Fail-closed: a non-case loop, an untypeable sequence, or a
    /// pattern that is neither a tuple nor a matching enum case records nothing. Called from
    /// `visit(ForStmtSyntax)` AFTER the loop scope's frame is pushed, so the bindings land in it.
    private func recordForCasePatternBindingTypes(_ node: ForStmtSyntax) {
        guard node.caseKeyword != nil, let element = forCaseElementType(of: node.sequence) else { return }
        if let leaves = Self.tuplePatternLeaves(of: node.pattern) {
            recordTupleLeafTypes(leaves, tupleTypeName: element.name, in: element.scope, visibleIn: nil)
            return
        }
        if let enumSym = typeResolver.typeSymbol(forQualifiedName: element.name, in: element.scope),
           enumSym.kind == .enum {
            _ = recordEnumPayloadTypes(pattern: node.pattern, enumSym: enumSym,
                                       substitutionReceiver: nil, visibleIn: nil)
        }
    }

    /// The iteration ELEMENT type of a for-in/for-case sequence as a (name, scope) pair:
    /// `CollectionMemberRegistry.iterationElement` over the sequence's written type (`receiverTypeInfo`
    /// + `expandedTypeName` unwrapping a `typealias`), so `[LoadState]` → `LoadState` and
    /// `[(Int, Cell)]` → `(Int, Cell)`. Fail-closed on an untypeable sequence.
    private func forCaseElementType(of sequence: ExprSyntax) -> (name: String, scope: Scope)? {
        guard let info = typeResolver.receiverTypeInfo(of: sequence, in: currentScope) else { return nil }
        let expanded = typeResolver.expandedTypeName(info.name, in: info.declScope)
        guard let element = CollectionMemberRegistry.iterationElement(of: expanded.name) else { return nil }
        return (element, expanded.scope)
    }

    /// `switch r { case .success(let x): … }` where `r : Result<Success, Failure>` (stdlib, commonly
    /// reached through a protocol `typealias` on a completion handler). `.success` binds the first
    /// type argument, `.failure` the second (`ResultTypeName`). The Result type name is read via
    /// `receiverTypeInfo` + `expandedTypeName` (so a `typealias T1 = Result<…>` is unwrapped) and the
    /// payload is resolved in the scope that type was WRITTEN in (B-FIX-35 discipline). Fail-closed:
    /// not a Result, an unknown case, or a single-binding pattern only.
    private func recordResultPayloadBindingTypes(pattern: PatternSyntax, matching subject: ExprSyntax,
                                                 visibleIn extent: ConditionBindingExtent.Visibility?) {
        guard let (caseName, bindings) = Self.enumPatternBindings(of: pattern),
              bindings.count == 1, let binding = bindings[0],
              let info = typeResolver.receiverTypeInfo(of: subject, in: currentScope) else { return }
        let expanded = typeResolver.expandedTypeName(info.name, in: info.declScope)
        guard let payload = ResultTypeName.payloadType(caseName: caseName, of: expanded.name) else { return }
        let resolved = typeResolver.typeSymbol(forQualifiedName: payload, in: expanded.scope)
        let bound = resolved.map { ($0.name, $0.scope ?? expanded.scope) } ?? (payload, expanded.scope)
        shadowBindingTypeFrames.bind(binding, visibleIn: extent, (name: bound.0, scope: bound.1))
    }

    /// Subject expression of the `switch` a case belongs to.
    private static func enclosingSwitchSubject(of caseNode: SwitchCaseSyntax) -> ExprSyntax? {
        var probe: Syntax? = Syntax(caseNode).parent
        while let p = probe {
            if let sw = p.as(SwitchExprSyntax.self) { return sw.subject }
            probe = p.parent
        }
        return nil
    }

    /// The identifier LEAVES of a TUPLE pattern with each leaf's positional PATH from the whole tuple
    /// down to it (B-FIX-79). A condition/switch tuple pattern raw-parses as an `ExpressionPattern`
    /// wrapping a `TupleExpr` (confirmed by AST dump) — NOT a `TuplePattern` (that is the for-in form),
    /// optionally wrapped in a `ValueBindingPattern` (`case let (x, y)`) or carrying a trailing `?`
    /// (`case (let x, let y)? = optT`, an `OptionalChainingExpr` inside the ExpressionPattern). A
    /// non-tuple pattern (an enum-case call, a scalar) yields nil so the caller falls through to the
    /// enum branches. A wildcard `_` or any non-binding element occupies a position but yields no leaf.
    private static func tuplePatternLeaves(of pattern: PatternSyntax)
        -> [(name: String, path: [(index: Int, arity: Int)])]? {
        var inner = pattern
        if let vb = inner.as(ValueBindingPatternSyntax.self) { inner = vb.pattern }
        guard let exprPattern = inner.as(ExpressionPatternSyntax.self) else { return nil }
        var expr = exprPattern.expression
        if let optional = expr.as(OptionalChainingExprSyntax.self) { expr = optional.expression }
        guard let tuple = expr.as(TupleExprSyntax.self) else { return nil }
        var out: [(name: String, path: [(index: Int, arity: Int)])] = []
        collectTupleExprLeaves(tuple, prefix: [], into: &out)
        return out.isEmpty ? nil : out
    }

    /// Recurse over a `TupleExpr`'s elements, recording each identifier leaf with the `(index, arity)`
    /// path that reaches it. A NESTED element (`(let a, (let b, let c))`) parses as an inner `TupleExpr`
    /// directly (no `PatternExpr` wrapper), so it is descended; an identifier leaf is a `PatternExpr`
    /// wrapping either a `ValueBindingPattern`→`IdentifierPattern` (`let x`) or a bare `IdentifierPattern`
    /// (`case let (x, y)` — the `let` is on the whole tuple). Everything else (a wildcard, a literal
    /// sub-pattern) still occupies its position so later leaves keep their index.
    private static func collectTupleExprLeaves(_ tuple: TupleExprSyntax, prefix: [(index: Int, arity: Int)],
                                               into out: inout [(name: String, path: [(index: Int, arity: Int)])]) {
        let elements = Array(tuple.elements)
        let arity = elements.count
        for (index, element) in elements.enumerated() {
            let path = prefix + [(index: index, arity: arity)]
            if let nested = element.expression.as(TupleExprSyntax.self) {
                collectTupleExprLeaves(nested, prefix: path, into: &out)
                continue
            }
            guard let patExpr = element.expression.as(PatternExprSyntax.self) else { continue }
            var p = patExpr.pattern
            if let vb = p.as(ValueBindingPatternSyntax.self) { p = vb.pattern }
            if let ident = p.as(IdentifierPatternSyntax.self) {
                out.append((name: TypeResolver.stripBackticks(ident.identifier.text), path: path))
            }
        }
    }

    /// `(caseName, bindingNames)` of an enum-case pattern with a payload, for both spellings:
    /// `case .run(let m)` (binding inside) and `case let .run(m)` (binding specifier in front).
    /// Non-binding positions (`_`, a literal) yield nil entries so the arity still lines up with the
    /// case's associated values.
    private static func enumPatternBindings(of pattern: PatternSyntax) -> (String, [String?])? {
        var inner = pattern
        if let valueBinding = inner.as(ValueBindingPatternSyntax.self) { inner = valueBinding.pattern }
        guard let exprPattern = inner.as(ExpressionPatternSyntax.self) else { return nil }
        // `case .calm(let x)? = optSubject` (B4) — an OPTIONAL PATTERN wraps the case call in an
        // `OptionalChainingExpr` carrying the trailing `?`. Peel it to reach the enum-case call; the
        // enum itself is the subject's WRAPPED type, which `typeSymbol(of:)` already unwraps.
        var callExpr = exprPattern.expression
        if let optional = callExpr.as(OptionalChainingExprSyntax.self) { callExpr = optional.expression }
        guard let call = callExpr.as(FunctionCallExprSyntax.self),
              let callee = call.calledExpression.as(MemberAccessExprSyntax.self),
              callee.base == nil else { return nil }
        let bindings: [String?] = call.arguments.map { argument in
            guard let patternExpr = argument.expression.as(PatternExprSyntax.self) else { return nil }
            var p = patternExpr.pattern
            if let vb = p.as(ValueBindingPatternSyntax.self) { p = vb.pattern }
            return p.as(IdentifierPatternSyntax.self).map { TypeResolver.stripBackticks($0.identifier.text) }
        }
        return (TypeResolver.stripBackticks(callee.declName.baseName.text), bindings)
    }

    /// Record an optional binding's type into the current frame (best-effort; nil results skipped).
    /// The ONE place a `let`/`var` optional binding gets a type — every entry form (`if let`,
    /// `while let`, `guard let`) routes here so the annotation rule cannot be forgotten at one of them.
    ///
    /// `visibleIn` is where the binding answers, from `ConditionBindingExtent`: the end of the
    /// statement's body for `if let`/`while let`, and for a `guard let` no end at all but a hole
    /// over its own `else` body (B-FIX-45, B-FIX-50). It is the same region `shadowFrames` gets for
    /// the same binding — the two must agree or one half keeps answering for a name the other has
    /// already released.
    private func recordShadowBindingType(name: String, annotation: TypeAnnotationSyntax?,
                                         initializer: ExprSyntax,
                                         visibleIn extent: ConditionBindingExtent.Visibility?) {
        guard let info = bindingType(annotation: annotation, initializer: initializer) else { return }
        shadowBindingTypeFrames.bind(name, visibleIn: extent, (name: info.name, scope: info.scope))
    }

    /// The static type of a binding, as a (name, resolving-scope) pair.
    ///
    /// A WRITTEN annotation is ground truth and outranks any inference (B-FIX-35): the compiler has
    /// been told the type, so there is nothing to guess. Only the inference below can fail, and it
    /// fails exactly where the real project broke — `guard let row: Section.Row = items[safe: i]`,
    /// where the initializer is a labeled subscript / cast / external generic the resolver cannot
    /// type. The binding then stayed untyped and every member read through it landed in
    /// `receiver-untyped`, un-renamed, while the member declarations renamed.
    ///
    /// Each branch pairs the name with the scope it must be resolved in, never the use-site's:
    ///   1. annotation → the scope it is WRITTEN in (`currentScope`), so an unqualified nested name
    ///      (`Row` written inside `enum Section`) still resolves;
    ///   2. inferred LOCAL type → the type's own DECLARING scope, since `Symbol.name` is bare and a
    ///      nested type is invisible from the use-site (this is the second half of the same bug);
    ///   3. inferred EXTERNAL type (`URL`, `String`) → no Symbol exists, but the NAME still feeds
    ///      overload disambiguation, and a top-level external name resolves anywhere.
    ///
    /// An annotation `WrittenTypeName.of` cannot reduce (a function type, a tuple) falls through to
    /// inference rather than failing closed: recording nothing is what we did before, so the
    /// fall-through can only add information, never change an existing answer.
    private func bindingType(annotation: TypeAnnotationSyntax?,
                             initializer: ExprSyntax) -> (name: String, scope: Scope)? {
        if let annotation, let written = WrittenTypeName.of(annotation.type) {
            return (written, currentScope)
        }
        if let sym = typeResolver.typeSymbol(of: initializer, in: currentScope) {
            return (sym.name, sym.scope ?? currentScope)
        }
        // The initializer types to a COMPOSITE STRING that names no declaration — a collection
        // (`if let xs = rows.filter { … }`), a tuple (`if let pair = rows.enumerated().first`), or an
        // iterator element (`while let pair = it.next()` over a Dictionary iterator) — so `typeSymbol`
        // above returned nil. Store the string with the scope it was written in, exactly as
        // `TypeInferencePass` does for a plain-`let` local (B-FIX-75/76); a member reached through the
        // binding (`pair.element.m`, `xs.first?.m`) then resolves via the tuple/collection machinery.
        // B-FIX-77. Runs before `declaredTypeName`, which cannot name a composite call result and
        // would answer nil here anyway.
        if let info = typeResolver.receiverTypeInfo(of: initializer, in: currentScope),
           TypeResolver.isChaseableComposite(info.name) {
            return (info.name, info.declScope)
        }
        if let name = typeResolver.declaredTypeName(of: initializer, in: currentScope) {
            return (name, currentScope)
        }
        return nil
    }

    /// Closest type scope walking up from `currentScope`.
    private func enclosingTypeScope() -> Scope? {
        var s: Scope? = currentScope
        while let cur = s {
            if cur.kind == .type { return cur }
            s = cur.parent
        }
        return nil
    }

    private func emitRename(for token: TokenSyntax, target: Symbol) {
        let obf = map.obf(for: target)
        // Guarded at the caller, not inside `recordUseSite`: Swift evaluates arguments eagerly, so
        // an inner nil-check would still pay for the position lookup and the `stripBackticks` scan
        // on every call of the default path.
        if useSiteLog != nil {
            recordUseSite(name: stripBackticks(token.text),
                          offset: token.positionAfterSkippingLeadingTrivia.utf8Offset,
                          outcome: obf != nil ? .rewritten(targetSymbolId: target.id)
                                              : .resolvedNotRenamed(targetSymbolId: target.id))
        }
        guard let obf else { return }
        let offset = token.positionAfterSkippingLeadingTrivia.utf8Offset
        let length = token.trimmedLength.utf8Length
        // Wrap as backticked identifier only when bare token already is the identifier (not `Foo`).
        renames.append(Rename(
            file: file,
            offset: offset,
            length: length,
            original: target.name,
            replacement: NamePool.wrapIfKeyword(obf),
            targetSymbolId: target.id
        ))
    }

    // MARK: - Scope tracking (mirrors DeclarationPass)

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind { enterInnerScope(of: node); return .visitChildren }
    override func visitPost(_ node: ClassDeclSyntax) { exitInnerScope(of: node) }
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { enterInnerScope(of: node); return .visitChildren }
    override func visitPost(_ node: StructDeclSyntax) { exitInnerScope(of: node) }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind { enterInnerScope(of: node); return .visitChildren }
    override func visitPost(_ node: ActorDeclSyntax) { exitInnerScope(of: node) }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind { enterInnerScope(of: node); return .visitChildren }
    override func visitPost(_ node: EnumDeclSyntax) { exitInnerScope(of: node) }
    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind { enterInnerScope(of: node); return .visitChildren }
    override func visitPost(_ node: ProtocolDeclSyntax) { exitInnerScope(of: node) }
    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind { enterInnerScope(of: node); return .visitChildren }
    override func visitPost(_ node: ExtensionDeclSyntax) { exitInnerScope(of: node) }
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { enterInnerScope(of: node); return .visitChildren }
    override func visitPost(_ node: FunctionDeclSyntax) { exitInnerScope(of: node) }
    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind { enterInnerScope(of: node); return .visitChildren }
    override func visitPost(_ node: InitializerDeclSyntax) { exitInnerScope(of: node) }
    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind { enterInnerScope(of: node); return .visitChildren }
    override func visitPost(_ node: SubscriptDeclSyntax) { exitInnerScope(of: node) }
    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind { enterInnerScope(of: node); return .visitChildren }
    override func visitPost(_ node: ClosureExprSyntax) { exitInnerScope(of: node) }
    // A braced block is a scope (statement bodies, accessor bodies, a function's own body). Missing
    // it made every local of a method resolve against the flat function scope — see `ScopeNodes`.
    override func visit(_ node: CodeBlockSyntax) -> SyntaxVisitorContinueKind { enterInnerScope(of: node); return .visitChildren }
    override func visitPost(_ node: CodeBlockSyntax) { exitInnerScope(of: node) }
    // An IMPLICIT getter's body (`var x: T { … }`) is the one braced body that is not a
    // `CodeBlockSyntax` — DeclarationPass scopes it here (B-FIX-49). Unconditional, because
    // `enterInnerScope` is a no-op unless a scope was actually attached to this node.
    override func visit(_ node: AccessorBlockSyntax) -> SyntaxVisitorContinueKind { enterInnerScope(of: node); return .visitChildren }
    override func visitPost(_ node: AccessorBlockSyntax) { exitInnerScope(of: node) }
    override func visit(_ node: SwitchCaseSyntax) -> SyntaxVisitorContinueKind {
        enterInnerScope(of: node)
        recordEnumPayloadBindingTypes(of: node)
        return .visitChildren
    }
    override func visitPost(_ node: SwitchCaseSyntax) { exitInnerScope(of: node) }
    override func visit(_ node: CatchClauseSyntax) -> SyntaxVisitorContinueKind { enterInnerScope(of: node); return .visitChildren }
    override func visitPost(_ node: CatchClauseSyntax) { exitInnerScope(of: node) }
    // The loop VARIABLE's scope — the statement, not the body, since it is declared before the brace
    // and is also in scope in the `where` clause (B-FIX-44).
    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind {
        enterInnerScope(of: node)
        // Type a `for case <pattern> in <seq>`'s bindings from the sequence's element (B-FIX-81) —
        // after the scope's frame is pushed, so they land in it.
        recordForCasePatternBindingTypes(node)
        return .visitChildren
    }
    override func visitPost(_ node: ForStmtSyntax) { exitInnerScope(of: node) }

    // MARK: - Function calls (handles memberwise-init argument labels)

    /// When call is `TypeName(label1: ..., label2: ...)` and TypeName is one of OUR struct/class
    /// types, the labels of a memberwise-init must match the type's property names. If we renamed
    /// those properties, the labels at the call site need to follow.
    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        // Resolve callee to a type symbol — supports both `TypeName(...)` (DeclRef) and
        // `Outer.Nested(...)` (MemberAccess chain).
        let calleeTypeSym: Symbol? = {
            if let ref = node.calledExpression.as(DeclReferenceExprSyntax.self) {
                let name = stripBackticks(ref.baseName.text)
                if let sym = currentScope.lookup(name: name), sym.kind.isTypeLike {
                    return sym
                }
                return lookupType(named: name)
            }
            if let member = node.calledExpression.as(MemberAccessExprSyntax.self) {
                // `self.init(...)` / `Self.init(...)` / `TypeName.init(...)` — a delegating or
                // qualified memberwise call. Resolve to the constructed TYPE so its memberwise
                // labels follow the renamed properties (without this, `self.init(alphaValue:…)` in
                // an extension keeps the original label while the property renamed → "incorrect
                // argument label" red).
                if stripBackticks(member.declName.baseName.text) == "init", let base = member.base {
                    if let baseRef = base.as(DeclReferenceExprSyntax.self) {
                        let baseName = stripBackticks(baseRef.baseName.text)
                        if baseName == "self" || baseName == "Self" {
                            return enclosingTypeScope()?.owner
                        }
                        if let s = currentScope.lookup(name: baseName), s.kind.isTypeLike { return s }
                        return lookupType(named: baseName)
                    }
                }
                return typeResolver.typeSymbol(of: node.calledExpression, in: currentScope)
            }
            return nil
        }()
        // Unwrap typealias before checking the underlying kind — `typealias T = SomeStruct` then
        // `T(label: …)` must still drive memberwise-init label renaming on `SomeStruct`'s scope.
        let calleeUnwrapped = calleeTypeSym.map { typealiasUnwrap($0) }
        if let typeSym = calleeUnwrapped,
           typeSym.kind == .struct,
           let typeScope = innerScope(of: typeSym) {
            // Memberwise inits exist ONLY for STRUCTS — a class is ALWAYS constructed through an
            // explicit/inherited init whose labels are real parameter labels (policy-skipped, never
            // renamed). Including classes here renamed `Sub(side:)` (which inherits the init) to the
            // SuperclassVisibility-copied `side` property's obf → "incorrect argument label" red.
            // Swift suppresses the memberwise init only when the struct wrote an explicit init in
            // its PRIMARY declaration (an EXTENSION init does NOT suppress it). Consult the
            // main-decl side-table, NOT the unified type scope (which includes extension inits) —
            // else a struct with only an extension init wrongly disables the label rename and its
            // stored properties revert (B-FIX-19 follow-up).
            let hasExplicitInit = table.structsWithMainDeclInit.contains(typeSym.id)
            if !hasExplicitInit {
                for arg in node.arguments {
                    guard let label = arg.label else { continue }
                    let labelText = label.text
                    // A memberwise-init label names a stored PROPERTY; a same-named method must not
                    // win `member(named:)`'s source-order pick and silently drop the label rename.
                    if let member = Self.narrowed(typeScope.members(named: labelText), to: .value).first,
                       member.kind == .property,
                       map.obf(for: member) != nil {
                        emitRename(for: label, target: member)
                    }
                }
            }
        }
        return .visitChildren
    }

    // MARK: - if-let / guard-let shorthand

    /// Expand shorthand `if let X { ... }` to `if let <obf> = <obf> { ... }` when the property
    /// `X` is being renamed. Both sides of the binding use the obfuscated name:
    ///   - rhs reads from the renamed property in enclosing scope
    ///   - lhs introduces a local shadow (same name as rhs after rename = consistent)
    /// References to `X` inside the body get renamed by normal DeclRef handling — they now
    /// resolve to the property symbol's obf, which equals the local shadow's name. Compiler
    /// treats the in-body references as the local (the unwrapped value), which is correct.
    override func visit(_ node: OptionalBindingConditionSyntax) -> SyntaxVisitorContinueKind {
        // Only the SHORTHAND form (`if let X`, no initializer) needs the expand-rewrite. The
        // explicit form (`guard let X = expr`) is handled by shadow tracking in visitPost.
        guard node.initializer == nil,
              let ident = node.pattern.as(IdentifierPatternSyntax.self) else {
            return .visitChildren
        }
        let name = stripBackticks(ident.identifier.text)
        // The shadowed symbol is the one visible AT THE `if`, so the lookup carries the use-site
        // offset (B-FIX-40): `if let opt { … }; let opt = 5` shadows the PARAMETER, and an
        // order-blind lookup answered with the local declared below, expanding the shorthand into
        // `if let <local obf> = <local obf>` ⇒ "use of local variable … before its declaration".
        guard let target = currentScope.lookup(
                  name: name, at: ident.identifier.positionAfterSkippingLeadingTrivia.utf8Offset),
              let obf = map.obf(for: target) else {
            return .visitChildren
        }
        let safeObf = NamePool.wrapIfKeyword(obf)
        // Shorthand `if let X` → `if let <obf> = <obf>`. Pattern renamed + explicit rhs inserted.
        // Body references to X get renamed to the same obf (consistent shadow), so we do NOT
        // add a shadow frame entry here.
        emitRename(for: ident.identifier, target: target)
        let insertOffset = ident.identifier.endPositionBeforeTrailingTrivia.utf8Offset
        renames.append(Rename(
            file: file,
            offset: insertOffset,
            length: 0,
            original: "",
            replacement: " = \(safeObf)"
        ))
        return .visitChildren
    }

    /// After an optional binding's initializer has been resolved, the bound name becomes a
    /// LOCAL that shadows any same-named declaration — over the region
    /// `ConditionBindingExtent.visibility(of:)` answers with: the statement's BODY for an
    /// `if let` / `while let` (B-FIX-45), and everything after the condition EXCEPT the `else` body
    /// for a `guard let` (B-FIX-50). Record it so subsequent references inside that region resolve
    /// to the local (and stay un-renamed) while a read outside it follows the same-named
    /// declaration again.
    /// Only for the EXPLICIT form (`guard let X = expr`); the shorthand form is rewritten above
    /// and intentionally renamed instead.
    ///
    /// This runs for a `guard` condition too, and that is the point. Recording a guard's bindings
    /// only in `visitPost(GuardStmtSyntax)` kept them out of the `else` body correctly, but it also
    /// kept them out of the LATER CONDITIONS of the guard's own list, where they ARE in scope:
    /// `guard let e = items.first, let d = e.blob else { … }` typed nothing for `e`, so `e.blob`
    /// stayed original while the property renamed. The `else` body is now excluded by the `hole`
    /// instead, which is the same bound the SYMBOL half already applies.
    override func visitPost(_ node: OptionalBindingConditionSyntax) {
        guard node.initializer != nil,
              let ident = node.pattern.as(IdentifierPatternSyntax.self) else { return }
        let name = stripBackticks(ident.identifier.text)
        // The same region for both halves, from the one helper the `if case` family already answers
        // with. The frame this lands in is the ENCLOSING block's, so without the bound the binding
        // outlives its statement by the whole method.
        let extent = ConditionBindingExtent.visibility(of: node)
        // Type the initializer BEFORE marking the name a binding. `shadowFrames.bind` makes
        // `localBindingType(name)` answer `.untyped` (B-FIX-46) for that name, and for a same-name
        // rebinding `guard let x = x` the initializer IS `x` — binding the name first poisons the
        // typing of the binding's OWN initializer, so `x` (an HOF-typed closure param, or any value
        // reachable only by inference) types to nil and every member read through the binding fails.
        // This is the TYPE half of "a binding is not in scope within its own initializer" (B-FIX-21
        // covered the NAME half). Order matters, not the presence of both binds.
        if let initializer = node.initializer {
            recordShadowBindingType(name: name, annotation: node.typeAnnotation,
                                    initializer: initializer.value, visibleIn: extent)
        }
        shadowFrames.bind(name, visibleIn: extent)
    }

    /// `if case .run(let m) = value` / `while case …` / `guard case …` — the payload binding of a
    /// MATCHING pattern condition, typed exactly like a `switch` case's (B-FIX-29 covered only
    /// `switch`). In `visitPost` so the matched expression has been resolved first.
    ///
    /// The frame this records into is the ENCLOSING block's and lives to the end of the method,
    /// while the binding dies with the statement's body — hence the region (B-FIX-42). Without
    /// it, `if case .calm(let item) = mood { … }` still typed a same-named property below the
    /// statement as the payload and rewrote its members to the payload type's obfs. A `guard case`
    /// binding outlives its statement and is excluded from the `else` body by the region's `hole`,
    /// for the reason spelled out above `visitPost(OptionalBindingConditionSyntax)`.
    override func visitPost(_ node: MatchingPatternConditionSyntax) {
        recordEnumPayloadBindingTypes(pattern: node.pattern, matching: node.initializer.value,
                                      visibleIn: ConditionBindingExtent.visibility(of: node))
    }

    // MARK: - Key paths

    /// Resolve `\.X.Y.Z` (root inferred from context) and `\Foo.X.Y.Z` (explicit root).
    /// Each `.X` component is looked up as a member of the previous step's type and renamed.
    override func visit(_ node: KeyPathExprSyntax) -> SyntaxVisitorContinueKind {
        var current: Symbol?
        if let root = node.root {
            current = resolveTypeFromTypeSyntax(root)
        } else {
            current = inferKeyPathRoot(for: node)
        }
        guard var typeSym = current else { return .visitChildren }

        for component in node.components {
            guard let prop = component.component.as(KeyPathPropertyComponentSyntax.self) else {
                break
            }
            let memberName = stripBackticks(prop.declName.baseName.text)
            // A key-path component is never a callable, so a same-named method must not win the
            // source-order pick `member(named:)` makes (same position rule as `lookupMember`).
            guard let inner = innerScope(of: typeSym),
                  let member = Self.narrowed(inner.members(named: memberName), to: .value).first else {
                break
            }
            emitRename(for: prop.declName.baseName, target: member)
            // Chain: follow declared type for next component. The stored type name is written in
            // the MEMBER's own scope, never the key path's (B-FIX-23 / B-FIX-52): `var voucher:
            // Voucher` on `Ledger` spells a type nested in `Ledger`, which is invisible from the
            // file the key path is written in, and `preferredConcreteType` refuses a nested name
            // by contract. Resolving at the use-site therefore broke the walk at the first
            // nested component — and, where an UNRELATED top-level type shared the name, resolved
            // the rest of the chain against it, which is a wrong rename.
            if member.kind.isTypeLike {
                typeSym = member
            } else if let declType = table.declaredType[member.id],
                      let next = typeResolver.typeSymbol(forQualifiedName: declType,
                                                         in: member.scope ?? currentScope) {
                typeSym = next
            } else {
                break  // can't follow further
            }
        }
        return .visitChildren
    }

    /// Walk up from a `\.X` shorthand to the enclosing FunctionCallExpr argument slot,
    /// look up the call as a HOF and use the element type as the root.
    private func inferKeyPathRoot(for node: KeyPathExprSyntax) -> Symbol? {
        var ref: Syntax = Syntax(node)
        var argumentIndex: Int? = nil
        while let parent = ref.parent {
            if argumentIndex == nil, let labeled = parent.as(LabeledExprSyntax.self),
               let list = labeled.parent?.as(LabeledExprListSyntax.self) {
                argumentIndex = list.enumerated().first(where: { $0.element.id == labeled.id })?.offset
            }
            if let call = parent.as(FunctionCallExprSyntax.self), let idx = argumentIndex {
                return typeResolver.hofElementType(forCallArgument: call, argIndex: idx, in: currentScope)
            }
            if parent.is(SourceFileSyntax.self) { return nil }
            ref = Syntax(parent)
        }
        return nil
    }

    // MARK: - Type references (parameter types, return types, var types, inheritance, generic args)

    override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
        // Root of a qualified chain already decided (renamed or deliberately left as-is) by
        // full-chain resolution — never rename it independently. Still descend for generic args.
        if chainHandled.contains(node.name.id) {
            return .visitChildren
        }
        let name = stripBackticks(node.name.text)
        // Prefer scope-chain lookup — catches associatedtype, generic parameters, nested types
        // that shadow globally-named types. Fall back to module-aware global type table.
        if let target = currentScope.lookup(name: name), target.kind.isTypeLike {
            emitRename(for: node.name, target: target)
        } else if let target = lookupType(named: name) {
            emitRename(for: node.name, target: target)
        }
        return .visitChildren  // also visit generic arguments
    }

    /// `Foo.Bar` in type position (e.g. `func handle(_: Foo.Bar)`). A qualified type chain must
    /// be renamed all-or-nothing against a single fully-resolving candidate: renaming only the
    /// root segment of a partial match produces an invalid `<wrongObf>.Bar` when `Foo` collides
    /// with a same-named sibling/nested type that lacks `Bar`. The OUTERMOST member-type node
    /// drives full-chain resolution; inner nodes and the root IdentifierType defer via
    /// `chainHandled`.
    override func visit(_ node: MemberTypeSyntax) -> SyntaxVisitorContinueKind {
        // Decided by an enclosing chain — skip, but still descend for generic arguments.
        if chainHandled.contains(node.name.id) {
            return .visitChildren
        }
        let isOutermost = node.parent?.is(MemberTypeSyntax.self) != true
        if isOutermost, let segments = flattenTypeChain(node) {
            resolveQualifiedTypeChain(segments)
            return .visitChildren
        }
        // Fallback for chains we can't flatten (generic / optional / array / metatype bases):
        // resolve the immediate base and rename only this member, as before.
        let memberName = stripBackticks(node.name.text)
        // TYPE position: the member denotes a type, so a same-named property/method must not win
        // `member(named:)`'s source-order pick (same position rule as `lookupMember`).
        if let baseSym = resolveTypeFromTypeSyntax(node.baseType),
           let baseScope = innerScope(of: baseSym),
           let member = Self.narrowed(baseScope.members(named: memberName), to: .typeReference).first,
           member.kind.isTypeLike {
            emitRename(for: node.name, target: member)
        }
        return .visitChildren
    }

    /// Flattens a pure dotted type chain (`A.B.C`) into ordered (token, name) segments from root
    /// to member. Returns nil when the base is not a plain Identifier/Member chain (generic root,
    /// optional, array, tuple, metatype) — those fall back to per-node resolution.
    private func flattenTypeChain(_ node: MemberTypeSyntax) -> [(token: TokenSyntax, name: String)]? {
        var segs: [(TokenSyntax, String)] = [(node.name, stripBackticks(node.name.text))]
        var base: TypeSyntax = node.baseType
        while true {
            if let m = base.as(MemberTypeSyntax.self) {
                segs.append((m.name, stripBackticks(m.name.text)))
                base = m.baseType
            } else if let ident = base.as(IdentifierTypeSyntax.self) {
                segs.append((ident.name, stripBackticks(ident.name.text)))
                break
            } else {
                return nil
            }
        }
        return segs.reversed()
    }

    /// All-or-nothing resolution of a qualified type chain. Gathers every candidate for the root
    /// segment (lexically-visible type + all globally same-named types), keeps only candidates
    /// whose ENTIRE chain resolves to type-like members, and emits renames only when exactly one
    /// full chain matches. In every outcome the chain's tokens are marked handled so the root
    /// IdentifierType / inner MemberType visitors never independently rename a partial match.
    private func resolveQualifiedTypeChain(_ segments: [(token: TokenSyntax, name: String)]) {
        defer { for seg in segments { chainHandled.insert(seg.token.id) } }
        guard let rootName = segments.first?.name else { return }

        var roots: [Symbol] = []
        if let s = currentScope.lookup(name: rootName), s.kind.isTypeLike {
            roots.append(s)  // lexically-reachable (may be a nested type) — always a valid root
        }
        // Global candidates for the chain ROOT must be TOP-LEVEL: a bare first segment can't
        // name some unrelated type's nested member (req 7). Lexical nested roots already added.
        for t in table.types(named: rootName)
            where t.scope?.kind == .file && !roots.contains(where: { $0.id == t.id }) {
            roots.append(t)
        }
        // Conformance inheritance: a name like `T1` in `class C: P { … T1.S2 … }` may be a typealias
        // declared in P (or any ancestor protocol). Walk enclosing type scopes, look at their
        // inheritance clause, find protocols, and pull in typealiases/associatedtypes matching the
        // root name. Without this, `T1.S2` (where T1 = E1 via protocol typealias) can't resolve.
        if roots.isEmpty {
            for inherited in inheritedTypealiases(named: rootName) {
                if !roots.contains(where: { $0.id == inherited.id }) { roots.append(inherited) }
            }
        }

        var fullMatches: [[Symbol]] = []
        for root in roots {
            var path: [Symbol] = [root]
            // For chain WALKING use the typealias-unwrapped target; the ORIGINAL Symbol is kept
            // in `path` so its token gets renamed to ITS obf (the typealias's own rename), not the
            // underlying type's.
            var walkSym = typealiasUnwrap(root)
            var ok = true
            for seg in segments.dropFirst() {
                guard let inner = innerScope(of: walkSym),
                      let m = Self.narrowed(inner.members(named: seg.name), to: .typeReference).first,
                      m.kind.isTypeLike else {
                    ok = false; break
                }
                path.append(m)
                walkSym = typealiasUnwrap(m)
            }
            if ok { fullMatches.append(path) }
        }

        // Unique full match → rename the whole chain consistently. Zero matches → leave untouched.
        // Multiple full matches (the SAME nested type-chain exists in several writable targets —
        // common when a shared source file is compiled into multiple iOS app targets) → tiebreak
        // to the chain whose ROOT lives in the use-site's own module. That's how Swift resolves
        // the reference at compile time, and matches our overload tiebreaker for consistency.
        // Without this, references like `C1.E1` in a protocol get left un-renamed while C1's decl
        // is renamed in each target — the desync RollbackPass would normally catch, but with
        // `--kinds class` only the chain ROOT is renameable and the desync slips through.
        let chosen: [Symbol]
        if fullMatches.count == 1 {
            chosen = fullMatches[0]
        } else if fullMatches.count > 1 {
            let sameModule = fullMatches.filter { $0.first?.module.name == file.module.name }
            guard sameModule.count == 1 else { return }
            chosen = sameModule[0]
        } else {
            return
        }
        for (i, seg) in segments.enumerated() {
            emitRename(for: seg.token, target: chosen[i])
        }
    }

    /// If `sym` is a typealias whose RHS resolves to another type Symbol, return that Symbol;
    /// otherwise return `sym` itself. Used by the qualified-chain walker so `T1.S2` (where
    /// `typealias T1 = E1`) is walked through E1's inner scope to find S2 — but T1 itself stays
    /// the renamed token at the use-site.
    private func typealiasUnwrap(_ sym: Symbol) -> Symbol {
        guard sym.kind == .typealias_,
              let target = table.typealiasTarget[sym.id],
              let aliasScope = sym.scope,
              let resolved = typeResolver.typeSymbol(forQualifiedName: target, in: aliasScope)
        else { return sym }
        return resolved
    }

    /// Look for a typealias/associatedtype named `name` declared in any protocol that an enclosing
    /// type scope (class/struct/enum/extension) conforms to. Mirrors how Swift resolves bare
    /// references through protocol-conformance inheritance — our scope chain doesn't model this,
    /// so without an explicit search a name like `T1` (defined as `typealias T1 = E1` in protocol
    /// P) is invisible from inside a conforming `class C: P`.
    private func inheritedTypealiases(named name: String) -> [Symbol] {
        var found: [Symbol] = []
        var seenProtocols = Set<Int>()
        var s: Scope? = currentScope
        while let cur = s {
            defer { s = cur.parent }
            guard cur.kind == .type, let owner = cur.owner else { continue }
            // Conformances declared in an extension count too (G2): `extension C: P {}` makes P's
            // typealiases just as visible inside C as writing `class C: P` would.
            for inh in table.conformanceNames(of: owner) {
                for proto in table.types(named: inh) where proto.kind == .protocol {
                    guard !seenProtocols.contains(proto.id) else { continue }
                    seenProtocols.insert(proto.id)
                    guard let inner = innerScope(of: proto) else { continue }
                    for m in inner.members(named: name)
                        where m.kind == .typealias_ || m.kind == .associatedtype_ {
                        found.append(m)
                    }
                }
            }
        }
        return found
    }

    /// Walk type-position syntax (IdentifierType / MemberType / OptionalType / ArrayType-of-type)
    /// and return the underlying type Symbol when resolvable.
    private func resolveTypeFromTypeSyntax(_ type: TypeSyntax) -> Symbol? {
        if let ident = type.as(IdentifierTypeSyntax.self) {
            let name = stripBackticks(ident.name.text)
            if let target = currentScope.lookup(name: name), target.kind.isTypeLike {
                return target
            }
            return lookupType(named: name, at: ident.name.positionAfterSkippingLeadingTrivia.utf8Offset)
        }
        if let member = type.as(MemberTypeSyntax.self) {
            guard let baseSym = resolveTypeFromTypeSyntax(member.baseType),
                  let baseScope = innerScope(of: baseSym) else { return nil }
            // TYPE position — see `UsePosition`.
            return Self.narrowed(baseScope.members(named: stripBackticks(member.name.text)),
                                 to: .typeReference).first
        }
        if let opt = type.as(OptionalTypeSyntax.self) {
            return resolveTypeFromTypeSyntax(opt.wrappedType)
        }
        return nil
    }

    private func stripBackticks(_ s: String) -> String {
        guard s.count >= 2, s.hasPrefix("`"), s.hasSuffix("`") else { return s }
        return String(s.dropFirst().dropLast())
    }

    /// Module-aware type lookup: prefers a type declared in the same module as the file being
    /// rewritten, disambiguating same-named types across targets. Pass the use-site token's UTF-8
    /// offset to engage the USR tiebreak (A4) when several same-named candidates survive.
    private func lookupType(named name: String, at useSiteOffset: Int? = nil) -> Symbol? {
        typeResolver.resolveType(named: name, at: useSiteOffset)
    }

    // MARK: - Expression references

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        // Key-path property component (`\.title`, the `bar` in `\Root.bar`): resolved ENTIRELY by
        // visit(KeyPathExprSyntax) against the root TYPE, not lexical scope. Emitting here as well
        // would (a) double-edit the same token — the Rewriter then eats the following bytes (the
        // `))` after `\.title`) — and (b) in the keypath's un-resolvable-root fallback, wrongly
        // rename by lexical scope (a keypath member is never a lexical lookup). Owned there, skip here.
        if node.parent?.is(KeyPathPropertyComponentSyntax.self) == true {
            return .skipChildren
        }
        // Skip if this DeclReferenceExpr is part of a MemberAccessExpr (handled there)
        // OR is the `calledExpression` of a function call where we'd resolve the call separately.
        if node.parent?.is(MemberAccessExprSyntax.self) == true {
            // Member-side handled by MemberAccessExpr visitor; base-side falls into here separately.
            // We need to distinguish: if this is the `declName` of MemberAccess, skip (it's the member).
            if let memberAccess = node.parent?.as(MemberAccessExprSyntax.self),
               memberAccess.declName.id == node.id {
                return .skipChildren
            }
            // Otherwise this is the base — fall through to resolve as identifier.
        }
        let token = node.baseName
        let name = stripBackticks(token.text)
        // self/Self/super/etc — skip.
        if NamePool.swiftKeywords.contains(name) { return .skipChildren }
        // Local optional-binding shadow (`guard let x = x; ... x ...`) — `x` here is the local,
        // not the same-named property we may have renamed. Leave it untouched. At the use-site's
        // POSITION: an `if let x` binding is gone below its statement, where `x` is the property
        // again (B-FIX-45).
        if isLocallyShadowed(name, at: token.positionAfterSkippingLeadingTrivia.utf8Offset) {
            return .skipChildren
        }

        // Callee of a function call `name(args)`.
        if let call = node.parent?.as(FunctionCallExprSyntax.self),
           call.calledExpression.id == node.id {
            // A name in scope. Decide how to treat it — but a `let`/`var` local is NOT in scope
            // within its OWN initializer (Swift), so a call to the same name there targets the
            // enclosing method, not the not-yet-declared (non-callable) local. Skip such a local so
            // control falls through to resolveCall (callable-only, overload-aware). Without this,
            // `f(…)` inside `let f = … f(…) …` binds to the value local → the call is left
            // un-renamed while the method decl renames → "use of local variable before its decl".
            if let sym = lookupCallee(named: name,
                                      at: token.positionAfterSkippingLeadingTrivia.utf8Offset),
               !(Self.isValueBinding(sym.kind) && isInsideOwnInitializer(of: sym, node: node)) {
                switch sym.kind {
                case .class, .struct, .enum, .protocol, .typealias_, .associatedtype_:
                    // Constructor call `TypeName(...)` — rename as a type reference.
                    emitRename(for: token, target: sym)
                    return .skipChildren
                case .parameter, .property:
                    // A MEMBER property does not shadow an inherited callable the way a local or a
                    // parameter does: Swift unions a type's own members with its ancestors' AND
                    // with its protocols' extension defaults, so `tick()` inside
                    // `class Sub: Base { var tick: String }` calls `Base.tick()` and `go()` inside
                    // `struct Impl: Runner { var go: Bool }` calls `Runner`'s default — while the
                    // same name as a LOCAL or PARAMETER really does shadow it
                    // (`func f(tick: String) { tick() }` is "cannot call value of non-function type
                    // 'String'", checked against swiftc). Same B-FIX-47/48 rule as `lookupMember`,
                    // on the other lookup path: this branch used to rename the CALL to the
                    // property's obf and `return`, never reaching `resolveCall`.
                    if sym.kind == .property, let owner = memberOwnerType(of: sym),
                       !inheritedMembers(name, of: owner, admitting: .callee).isEmpty {
                        guard isKnownNonFunctionTyped(sym) else {
                            // Might be closure-typed, in which case the property IS what is called.
                            reportUnresolved(.inheritedKindConflict, name: name, token: token)
                            return .skipChildren
                        }
                        break   // to `resolveCall`, which finds the inherited callable
                    }
                    // A closure-typed value being invoked, e.g. `content()` where
                    // `content: () -> String`. Single binding — rename directly, no overload logic.
                    emitRename(for: token, target: sym)
                    return .skipChildren
                default:
                    break  // function/method — fall through to label-aware overload resolution
                }
            }
            if let typeSym = lookupType(named: name, at: token.positionAfterSkippingLeadingTrivia.utf8Offset) {
                emitRename(for: token, target: typeSym)
                return .skipChildren
            }
            // Function call — resolve the overload by argument labels (and, when labels alone are
            // ambiguous, by argument types) so we don't pick a same-named-but-different-signature
            // function from an enclosing scope or a foreign module.
            if let target = resolveCall(name: name, call: call) {
                if map.obf(for: target) == nil {
                    reportUnresolved(.candidateHasNoObf, name: name, token: token)
                }
                emitRename(for: token, target: target)
            } else {
                // Ambiguous / no unique match → leave the call un-renamed. The original name then
                // survives in output and RollbackPass reverts any partial renames of it. Which of
                // the two it was is exactly what the report has to say, so classify it the same way
                // `lookupMember` does: a name with no label-matching callable in reach never had a
                // candidate; one with several was an unresolved overload.
                let lexical = lexicalCallableCandidates(named: name)
                let global = table.callables(named: name)
                let hadCandidates = !lexical.isEmpty || !global.isEmpty
                reportUnresolved(hadCandidates ? .ambiguousOverload : .noCandidateInScope,
                                 name: name, token: token,
                                 candidateIds: (lexical.isEmpty ? global : lexical).map(\.id))
            }
            return .skipChildren
        }

        if let target = lookupOutsideOwnInitializer(name: name, at: node) {
            // A bare reference to a CALLABLE used as a value (`let h = send`, `perform(send)`).
            // If `send` is overloaded (>1 same-named callable with differing obfs), `lookup`'s
            // first-match risks binding the wrong overload — a wrong-rename red RollbackPass can't
            // catch. Resolve by the expected function-type annotation, else fail closed.
            if Self.isCallable(target.kind) {
                if let resolved = resolveBareCallableReference(name: name, target: target, node: node) {
                    emitRename(for: token, target: resolved)
                }
                // else: leave un-renamed → the surviving original triggers RollbackPass to revert
                // the whole group (green), instead of a silent wrong-overload rewrite.
                return .skipChildren
            }
            emitRename(for: token, target: target)
        } else if let target = lookupType(named: name, at: token.positionAfterSkippingLeadingTrivia.utf8Offset) {
            emitRename(for: token, target: target)
        } else if let inherited = inheritedTypealiases(named: name).first {
            // Conformance-inherited typealias as a VALUE reference: `T1.X` or `T1.self` — rename
            // the bare token to the typealias's OWN obf (its decl's rename), not the underlying
            // type's. Without this, T1 stays original while T1's decl was renamed → desync.
            emitRename(for: token, target: inherited)
        }
        return .skipChildren
    }

    /// Argument labels at a call site, including trailing closures (which are positional / nil).
    static func argumentLabels(of call: FunctionCallExprSyntax) -> [String?] {
        ArgumentLabelMatch.labels(of: call)
    }

    /// Same-named callables visible from `currentScope`, honouring LEXICAL SHADOWING: Swift's
    /// unqualified lookup stops at the INNERMOST scope that declares the name, so an inner
    /// declaration hides same-named outer ones ENTIRELY. Verified against swiftc: with a global
    /// `func f(_ x: String)` and a member `func f(_ x: Int)`, the call `f("a")` inside the type is
    /// an error, NOT a fallback to the global. So candidate sets must never straddle scope levels.
    ///
    /// Flattening every level into one overload set (the old behaviour) made an unrelated outer
    /// namesake a phantom candidate. When its signature is IDENTICAL to the inner ones, no argument
    /// signal can eliminate it and no shared obf covers it, so the call resolved to nothing and was
    /// left original while its decls renamed. `Scope.lookup` already stops at the innermost level;
    /// these callable walks are the two places that did not.
    ///
    /// `accept` filters WITHIN a level (label matching for calls). A level whose declarations all
    /// fail `accept` is skipped rather than treated as a stop: strict Swift would stop and reject
    /// the call, but our label model is incomplete (variadics), so skipping keeps the pre-existing
    /// behaviour for shapes we cannot model instead of losing a rename.
    private func lexicalCallableCandidates(named name: String,
                                           accept: (Symbol) -> Bool = { _ in true }) -> [Symbol] {
        var s: Scope? = currentScope
        var seen = Set<Int>()
        while let cur = s {
            var level: [Symbol] = []
            for sym in cur.symbols where sym.name == name && Self.isCallable(sym.kind) {
                if seen.insert(sym.id).inserted, accept(sym) { level.append(sym) }
            }
            if !level.isEmpty { return level }
            s = cur.parent
        }
        return []
    }

    /// The rewrite target when EVERY same-named candidate maps to the SAME obf: ambiguous to PICK,
    /// unambiguous in OUTCOME, so rewrite to it instead of failing closed. This is how an
    /// obf-unified group resolves — a protocol requirement unified with its own default
    /// implementation (`WitnessLinker.linkProtocolDefaults`), a requirement unified with its
    /// witnesses, an override chain unified by `OverrideLinker` — where no argument signal can ever
    /// tell the candidates apart because their signatures are identical by construction.
    /// Returns nil when the candidates disagree (or none is renamed): the caller then
    /// disambiguates / fails closed as before.
    private func unambiguousSharedObfTarget(_ candidates: [Symbol]) -> Symbol? {
        guard let first = candidates.first, let firstObf = map.obf(for: first) else { return nil }
        return candidates.allSatisfy { map.obf(for: $0) == firstObf } ? first : nil
    }

    /// Resolve a function call to a unique Symbol. First matches argument labels: prefers
    /// candidates visible in the scope chain, falls back to a global search (inherited / cross-
    /// type / extension overloads we don't model in the scope tree). When labels alone leave more
    /// than one candidate, disambiguates by argument TYPES. Returns nil when still ambiguous —
    /// caller should NOT rename then.
    private func resolveCall(name: String, call: FunctionCallExprSyntax) -> Symbol? {
        let callLabels = Self.argumentLabels(of: call)
        let trailingStart = ArgumentLabelMatch.trailingStart(of: call)
        let scopeMatches = lexicalCallableCandidates(named: name) {
            labelsMatch($0, callLabels, trailingStart: trailingStart)
        }
        if scopeMatches.count == 1 { return scopeMatches[0] }
        if scopeMatches.count > 1 {
            if let shared = unambiguousSharedObfTarget(scopeMatches) { return shared }
            return disambiguateByArgTypes(scopeMatches, call: call)
        }

        // Nothing matched lexically — search globally, but a bare `f(args)` can only reach a
        // callable via IMPLICIT SELF: a free function, or a METHOD of the use-site's enclosing type
        // family (the enclosing type(s) + their local superclass chains + conformed protocols).
        // A same-named method of an UNRELATED type is NOT reachable this way — picking it renames
        // the call to that method's obf while the call actually targets a stdlib/other function
        // ("cannot find <obf> in scope"). This filter is exactly how Swift scopes an unqualified
        // call. (`inherited` overloads stay covered — the superclass chain is in the family.)
        var globalMatches: [Symbol] = []
        var family: Set<Int>? = nil
        for sym in table.callables(named: name) where labelsMatch(sym, callLabels, trailingStart: trailingStart) {
            if sym.kind == .method {
                if family == nil { family = enclosingTypeFamilyIds() }
                guard let ownerId = sym.scope?.owner?.id, family!.contains(ownerId) else { continue }
            }
            globalMatches.append(sym)
        }
        if globalMatches.count == 1 {
            // Single global candidate is lower-confidence than a lexical one — veto it if the
            // argument types positively contradict its signature (e.g. a local free func
            // `abs(_: Distance)` vs a call `abs(intValue)`). Leaving it un-renamed → RollbackPass
            // reverts the group → green, instead of a wrong rename it cannot catch.
            return argTypesContradict(globalMatches[0], call: call) ? nil : globalMatches[0]
        }
        if globalMatches.count > 1 {
            if let shared = unambiguousSharedObfTarget(globalMatches) { return shared }
            return disambiguateByArgTypes(globalMatches, call: call)
        }
        return nil
    }

    /// Resolve a bare (non-call) reference to a callable used as a value. When the name has a
    /// single callable meaning, return it. When OVERLOADED (>1 same-named callable reachable via
    /// the scope chain, with differing obfs), pick the overload whose signature matches the
    /// expected function-type annotation of the enclosing `let/var` binding; if that can't uniquely
    /// decide, return nil (fail closed — never guess between overloads).
    private func resolveBareCallableReference(name: String, target: Symbol,
                                              node: DeclReferenceExprSyntax) -> Symbol? {
        let candidates = lexicalCallableCandidates(named: name)
        if candidates.count <= 1 { return target }   // not overloaded — safe
        if let shared = unambiguousSharedObfTarget(candidates) { return shared }
        // Overloaded with differing obfs — only rename if the expected function type picks exactly
        // one. Look for the enclosing `let/var x: (A, B) -> R = <ref>` annotation.
        guard let expected = expectedFunctionParamTypeNames(around: node) else { return nil }
        let matches = candidates.filter { cand in
            guard let pTypes = table.functionParamTypes[cand.id], pTypes.count == expected.count else { return false }
            for (p, e) in zip(pTypes, expected) {
                guard let p else { return false }
                if bareTypeName(p) != e { return false }
            }
            return true
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// The parameter-type names of the function-type annotation on the enclosing `let/var` binding
    /// (`let h: (String) -> Void = send` → ["String"]). Returns nil when the reference isn't the
    /// initializer value of a function-type-annotated binding.
    private func expectedFunctionParamTypeNames(around node: DeclReferenceExprSyntax) -> [String]? {
        var p: Syntax? = Syntax(node)
        while let cur = p {
            if let binding = cur.as(PatternBindingSyntax.self) {
                guard var t = binding.typeAnnotation?.type else { return nil }
                if let attr = t.as(AttributedTypeSyntax.self) { t = attr.baseType }
                while let opt = t.as(OptionalTypeSyntax.self) { t = opt.wrappedType }
                if let tup = t.as(TupleTypeSyntax.self), tup.elements.count == 1 { t = tup.elements.first!.type }
                if let attr = t.as(AttributedTypeSyntax.self) { t = attr.baseType }
                guard let fn = t.as(FunctionTypeSyntax.self) else { return nil }
                return fn.parameters.map { Self.bareTypeNameOf($0.type) }
            }
            // Stop climbing at a statement/closure boundary — the reference isn't a plain binding.
            if cur.is(CodeBlockSyntax.self) || cur.is(FunctionCallExprSyntax.self) { return nil }
            p = cur.parent
        }
        return nil
    }

    /// Bare type NAME of a type node for signature matching (`String` → "String", `[Int]` → "[Int]",
    /// `Foo?` → "Foo", `Foo<T>` → "Foo").
    private static func bareTypeNameOf(_ type: TypeSyntax) -> String {
        var t = type
        while let opt = t.as(OptionalTypeSyntax.self) { t = opt.wrappedType }
        if let id = t.as(IdentifierTypeSyntax.self) { return id.name.text }
        return t.trimmedDescription
    }

    /// Set of type-symbol ids reachable from the use-site via IMPLICIT SELF: every enclosing type
    /// scope's owner, plus each owner's LOCAL superclass chain and conformed (transitively-inherited)
    /// protocols. A method whose owning type is in this set is callable bare; one outside it is not.
    private func enclosingTypeFamilyIds() -> Set<Int> {
        var result = Set<Int>()
        var s: Scope? = currentScope
        while let cur = s {
            if cur.kind == .type, let owner = cur.owner {
                addTypeFamily(owner, into: &result)
            }
            s = cur.parent
        }
        return result
    }

    private func addTypeFamily(_ typeSym: Symbol, into result: inout Set<Int>) {
        guard result.insert(typeSym.id).inserted else { return }   // cycle / already-seen guard
        // Primary-decl inheritance clause + conformances declared on the type's EXTENSIONS
        // (`extension Tool: Helper` — B-FIX-6 discipline; without them a protocol adopted in an
        // extension is missing from the family / conformance evidence).
        for inh in table.conformanceNames(of: typeSym) {
            let base = bareTypeName(inh)
            // Module-aware: a bare inherited name resolves in the type's own module first.
            for cand in table.types(named: base)
            where cand.kind == .class || cand.kind == .protocol {
                if cand.module.name == typeSym.module.name || table.types(named: base).count == 1 {
                    addTypeFamily(cand, into: &result)
                }
            }
        }
    }

    /// Transitive type family of an arbitrary type symbol (itself + superclasses + protocols,
    /// incl. extension-declared conformances). Used as conformance evidence when scoring a
    /// concrete argument against a protocol-typed parameter.
    private func typeFamilyIds(of typeSym: Symbol) -> Set<Int> {
        var result = Set<Int>()
        addTypeFamily(typeSym, into: &result)
        return result
    }

    /// True when at least one argument's static type POSITIVELY contradicts the candidate's
    /// parameter type at that index (both sides known and different). Neutral/unknown args never
    /// contradict. Mirrors `disambiguateByArgTypes`'s `consistent` check, factored for the
    /// single-global-candidate veto.
    private func argTypesContradict(_ cand: Symbol, call: FunctionCallExprSyntax) -> Bool {
        guard let pTypes = table.functionParamTypes[cand.id] else { return false }
        // Argument i does not necessarily bind parameter i — a call that omits a defaulted parameter
        // shifts every later argument. Ask the label-matching walk which parameter each argument
        // took (B-FIX-36); comparing against the wrong parameter's type is how a correct candidate
        // gets vetoed.
        let bound = ArgumentLabelMatch.parameterIndices(cand, call: call, in: table)
        let args = Array(call.arguments.map { $0.expression })
        for (i, arg) in args.enumerated() {
            let pi = bound.map { i < $0.count ? $0[i] : Int.max } ?? i
            guard pi < pTypes.count, let pType = pTypes[pi] else { continue }
            switch argConstraint(arg) {
            case .enumCase(let caseName):
                if let t = resolveParamType(pType, candidate: cand),
                   t.kind == .enum, !enumHasCase(t, caseName) { return true }
            case .typeSymbol(let argSym):
                // Protocol-typed params accept any conformer — never a contradiction (mirrors
                // disambiguateByArgTypes' neutrality guard).
                if let pSym = resolveParamType(pType, candidate: cand), pSym.id != argSym.id,
                   pSym.kind != .protocol { return true }
            case .typeName(let tn):
                if bareTypeName(pType) != tn,
                   !Self.isCollectionTypeName(tn), !Self.isCollectionTypeName(pType),
                   let pSym = resolveParamType(pType, candidate: cand),
                   pSym.kind != .protocol { return true }
            case .unknown:
                break
            }
        }
        return false
    }

    /// Among label-matching overloads, pick the one whose declared parameter types best fit the
    /// call's argument expressions. The strongest signal we can read syntactically is an enum-case
    /// shorthand (`.none`): it fits a parameter whose type is an enum declaring that case, and is
    /// INCONSISTENT with a parameter whose type is a known enum that does NOT declare it. Literal
    /// arguments contribute a weaker positive signal (`"x"` → String, `1` → Int, …).
    ///
    /// Returns the unique candidate with a strictly-highest POSITIVE score among the
    /// type-consistent ones. Returns nil when there's no positive evidence or a tie — we never
    /// guess between equally-plausible overloads (that would risk a compile-breaking wrong rename).
    private func disambiguateByArgTypes(_ candidates: [Symbol], call: FunctionCallExprSyntax) -> Symbol? {
        let args = Array(call.arguments.map { $0.expression })
        var scored: [(sym: Symbol, score: Int)] = []
        for cand in candidates {
            guard let pTypes = table.functionParamTypes[cand.id] else { continue }
            // Same argument→parameter mapping as `argTypesContradict`: scoring an argument against
            // the parameter at its own ordinal is wrong for any call that omits a defaulted one.
            let bound = ArgumentLabelMatch.parameterIndices(cand, call: call, in: table)
            var score = 0
            var consistent = true
            for (i, arg) in args.enumerated() {
                let pi = bound.map { i < $0.count ? $0[i] : Int.max } ?? i
                guard pi < pTypes.count, let pType = pTypes[pi] else { continue }
                switch argConstraint(arg) {
                case .enumCase(let caseName):
                    if let t = resolveParamType(pType, candidate: cand),
                       t.kind == .enum {
                        if enumHasCase(t, caseName) { score += 1 } else { consistent = false }
                    }
                case .typeSymbol(let argSym):
                    let pSym = resolveParamType(pType, candidate: cand)
                    if let pSym {
                        if pSym.id == argSym.id { score += 1 }
                        else if pSym.kind == .protocol {
                            // A protocol-typed parameter (`_ r: Renderer` / `some Renderer`)
                            // accepts any CONFORMER — identity mismatch is not a contradiction.
                            // Conformance (transitive, incl. extension-declared) is positive
                            // evidence; unknown conformance stays neutral (never eliminate — our
                            // conformance detection is incomplete, fail-safe).
                            if typeFamilyIds(of: argSym).contains(pSym.id) { score += 1 }
                        }
                        else { consistent = false }   // both concrete and different → incompatible
                    }
                    // pType unresolvable (primitive/external) → neutral
                case .typeName(let tn):
                    if bareTypeName(pType) == tn { score += 1 }
                    else if Self.isCollectionTypeName(tn) || Self.isCollectionTypeName(pType) {
                        break  // composite spellings can differ for the SAME type → no evidence
                    }
                    else if let pSym = resolveParamType(pType, candidate: cand),
                            pSym.kind != .protocol {
                        // pType is a user-defined CONCRETE Symbol but the arg is a different
                        // primitive / external (e.g. `String` arg into a custom-enum parameter) →
                        // eliminate. A PROTOCOL param stays neutral — the external type could
                        // conform via an extension we don't see.
                        consistent = false
                    }
                    // both primitive / external with different names → neutral (implicit conv)
                case .unknown:
                    break
                }
            }
            if consistent { scored.append((cand, score)) }
        }
        // Cross-target duplicate methods (the same source file compiled into several writable
        // targets → N identical candidates, one per module) are common in multi-target iOS apps.
        // Swift resolves such a call to the candidate in the use-site's own module. Apply that
        // tiebreak both when several overloads tie at the top positive score AND when there's no
        // discriminating arg signal at all (zero-arg calls, all-unknown args) — the only thing
        // that distinguishes the duplicates is their module.
        var pool: [Symbol]
        if let maxScore = scored.map(\.score).max(), maxScore > 0 {
            let top = scored.filter { $0.score == maxScore }
            if top.count == 1 { return top[0].sym }
            pool = top.map { $0.sym }
        } else {
            // No positive evidence (zero-arg call, or all args are variables/expressions we can't
            // type) — fall through to module-based tiebreak across all label-matching candidates.
            pool = scored.map { $0.sym }
        }
        // Result-type disambiguation. Swift resolves overloads by the EXPECTED RESULT TYPE too, not
        // only by arguments — and that is the ONLY signal left when the argument is untypeable (a
        // stdlib optional-chain call like `source?.data(using:)`, the reported desync). When the
        // enclosing context WRITES the type the result must have (`guard let x: T = f1(...)`,
        // `let x: T = …`, an explicit `return`), keep only the candidates whose own return type is
        // consistent with it. A unique positive match wins; a set narrowed to one survivor wins;
        // otherwise fall through to the module tiebreak on the (possibly narrowed) pool. Fail-safe:
        // a protocol / unknown return stays neutral (never eliminated), so a mis-read context can
        // only fail to pick, never pick wrong.
        if pool.count > 1, let expected = expectedResultType(of: call) {
            let fits = pool.map { (sym: $0, fit: resultFit(of: $0, expected: expected)) }
            let matched = fits.filter { $0.fit == .matches }
            if matched.count == 1 { return matched[0].sym }
            let survivors = fits.filter { $0.fit != .contradicts }.map(\.sym)
            if survivors.count == 1 { return survivors[0] }
            if survivors.count > 1 && survivors.count < pool.count { pool = survivors }
        }
        let sameModule = pool.filter { $0.module.name == file.module.name }
        return sameModule.count == 1 ? sameModule[0] : nil
    }

    /// How a candidate's declared RETURN type fits an expected result type. Mirrors the
    /// argument-side neutrality of `disambiguateByArgTypes`: a protocol on either side (a conformer
    /// is a valid result we cannot string-match) or an unknown return (tuple/function/`Void`) stays
    /// `.neutral` and is never eliminated; only two resolvable CONCRETE / external types that differ
    /// `.contradicts`. Elimination therefore carries the same class-hierarchy imprecision the
    /// argument side already accepts, which is safe next to the String-vs-Data shape this resolves.
    private enum ResultFit { case matches, neutral, contradicts }
    private func resultFit(of cand: Symbol, expected: ContextualType) -> ResultFit {
        guard let ret = table.functionReturnType[cand.id] else { return .neutral }
        let expScope = expected.scope ?? currentScope
        if TypeNameEquivalence.sameType(expected.name, inScope: expScope, module: file.module.name,
                                        ret, inScope: cand.scope, module: cand.module.name,
                                        table: table) {
            return .matches
        }
        // A protocol on EITHER side accepts a conformer we cannot string-match — stay neutral.
        if typeResolver.typeSymbol(forQualifiedName: bareTypeName(expected.name), in: expScope)?.kind == .protocol
            || resolveParamType(ret, candidate: cand)?.kind == .protocol {
            return .neutral
        }
        return .contradicts
    }

    /// The type a call's RESULT is expected to have, from an enclosing WRITTEN annotation or an
    /// explicit `return` — the signal Swift uses to disambiguate overloads by result type. Only the
    /// IMMEDIATE binding/return context counts: a call nested inside a larger expression (a member
    /// access `f1(...).x`, an operator, another call's argument) has no directly-written expected
    /// type, so this returns nil rather than borrow an annotation that types the OUTER expression.
    /// The optional wrapper is dropped by `WrittenTypeName.of` on both this side and the stored
    /// return type, so a `guard let x: Data` (unwrapped annotation) compares equal to a `-> Data?`.
    private func expectedResultType(of call: FunctionCallExprSyntax) -> ContextualType? {
        guard let parent = call.parent else { return nil }
        // `let / var / guard let / if let / while let  x: T = call` — the call is the initializer
        // directly (not nested inside a bigger initializer expression).
        if let initClause = parent.as(InitializerClauseSyntax.self), initClause.value.id == call.id {
            if let ob = initClause.parent?.as(OptionalBindingConditionSyntax.self),
               let annotation = ob.typeAnnotation, let name = WrittenTypeName.of(annotation.type) {
                return ContextualType(name: name, scope: nil)   // written at the use-site
            }
            if let pb = initClause.parent?.as(PatternBindingSyntax.self),
               let annotation = pb.typeAnnotation, let name = WrittenTypeName.of(annotation.type) {
                return ContextualType(name: name, scope: nil)
            }
            return nil
        }
        // `return call` — the enclosing function's written return type.
        if parent.is(ReturnStmtSyntax.self) {
            var probe: Syntax? = parent.parent
            while let p = probe {
                if let fn = p.as(FunctionDeclSyntax.self) {
                    if let rc = fn.signature.returnClause, let name = WrittenTypeName.of(rc.type) {
                        return ContextualType(name: name, scope: nil)
                    }
                    return nil
                }
                // A closure / accessor return type is inferred or unwritten — we don't model it.
                if p.is(ClosureExprSyntax.self) || p.is(AccessorDeclSyntax.self) { return nil }
                probe = p.parent
            }
        }
        return nil
    }

    private enum ArgConstraint {
        case enumCase(String)
        case typeSymbol(Symbol)   // resolved user-defined type — match by Symbol identity
        case typeName(String)     // primitive / external (stdlib) — match by name string
        case unknown
    }

    private func argConstraint(_ expr: ExprSyntax) -> ArgConstraint {
        if let m = expr.as(MemberAccessExprSyntax.self), m.base == nil {
            return .enumCase(stripBackticks(m.declName.baseName.text))  // `.case` shorthand
        }
        if expr.is(StringLiteralExprSyntax.self) { return .typeName("String") }
        if expr.is(IntegerLiteralExprSyntax.self) { return .typeName("Int") }
        if expr.is(BooleanLiteralExprSyntax.self) { return .typeName("Bool") }
        if expr.is(FloatLiteralExprSyntax.self) { return .typeName("Double") }
        // `<enum>.rawValue` → the enum's raw type.
        if let m = expr.as(MemberAccessExprSyntax.self),
           let base = m.base,
           stripBackticks(m.declName.baseName.text) == "rawValue",
           let baseSym = typeResolver.typeSymbol(of: base, in: currentScope),
           baseSym.kind == .enum,
           let raw = table.enumRawType[baseSym.id] {
            return .typeName(raw)
        }
        // A method call's return type used to be read HERE, by a third private copy of the
        // receiver-typing + label-matching + `functionReturnType` walk (after `calleeCallable` and
        // `TypeResolver.typeSymbol(of:)`'s own), resolving the return-type string against the
        // use-site scope. Deleted in B-FIX-52: the two general fallbacks at the bottom of this
        // function already answer it and answer it correctly — `typeSymbol(of:)` for the identity
        // half (it funnels a call through `receiverTypeInfo`, which carries the CALLEE's scope)
        // and `declaredTypeName(of:)` for the external/stdlib half. The copy resolved a nested
        // return type (`-> Voucher` inside `Ledger`) to nil, silently DOWNGRADING the argument
        // from `.typeSymbol` (identity) to `.typeName("Voucher")`, which then mismatched the
        // written `Ledger.Voucher` and eliminated the only correct overload. Measured on the
        // reproduction: 0 desyncs, 100% reported coverage, no diagnostics — and a red build.
        //
        // Optional-binding local: `if let u = makeURL()` carries no declared Symbol, but we recorded
        // its inferred type when the binding entered scope (B-FIX-11 follow-up). Check it BEFORE the
        // general typeSymbol fallback so a binding that shadows a same-named property uses the
        // binding's own (unwrapped) type. The name is external/stdlib (URL, …) → match by name.
        // The competitor is the same-named declaration visible here, so a binding that a DEEPER
        // local out-scopes does not type this argument either (B-FIX-46).
        if let ref = expr.as(DeclReferenceExprSyntax.self) {
            let name = stripBackticks(ref.baseName.text)
            let at = ref.positionAfterSkippingLeadingTrivia.utf8Offset
            if let bindingType = shadowBindingType(name, at: at,
                                                   outScoping: {
                                                       currentScope.lookup(name: name, at: at)?.scope
                                                   }) {
                // Prefer identity when the name resolves in the scope it belongs to; fall back to
                // the NAME for external/stdlib types (URL, …), which have no Symbol — the original
                // signal.
                if let sym = typeResolver.typeSymbol(forQualifiedName: bindingType.name,
                                                     in: bindingType.scope) {
                    return .typeSymbol(sym)
                }
                return .typeName(bareTypeName(bindingType.name))
            }
        }
        // General fallback — resolve the expression's static type via TypeResolver. Catches a
        // bare DeclRef to a typed parameter / property / variable, `obj.prop`, etc. We keep the
        // resolved Symbol so downstream matching is by IDENTITY, not by the (possibly-bare) name.
        if let sym = typeResolver.typeSymbol(of: expr, in: currentScope) {
            return .typeSymbol(sym)
        }
        // No local Symbol for the expression's type. Two populations end up here: EXTERNAL/primitive
        // types (`URL`, `String`) and — since B-FIX-28 — every COLLECTION type, because `[Item]`
        // names no declaration. Fall back to the declared type NAME so disambiguation still gets a
        // signal. `declaredTypeName` covers a bare reference, `obj.items`, a call's return type and
        // the optional/try/await wrappers; the previous bare-DeclRef-only fallback left every
        // member-access argument (`f(h.items)`) with no signal at all, tying the overload set.
        if let typeName = typeResolver.declaredTypeName(of: expr, in: currentScope) {
            return .typeName(bareTypeName(typeName))
        }
        return .unknown
    }

    private func enumHasCase(_ typeSym: Symbol, _ caseName: String) -> Bool {
        guard let inner = innerScope(of: typeSym) else { return false }
        // Kind-filtered, not first-match: a same-named method declared before the case would
        // otherwise answer "no case" (`member(named:)` is kind-blind — see `UsePosition`).
        return inner.members(named: caseName).contains { $0.kind == .enumCase }
    }

    private func bareTypeName(_ s: String) -> String {
        var n = s
        while n.hasSuffix("?") || n.hasSuffix("!") { n = String(n.dropLast()) }
        // A collection SUGAR name is composite, not a generic instantiation: cutting `[Box<Foo>]`
        // at the `<` yields the garbage `[Box`. Only a LEAF name sheds its generic arguments.
        guard !n.hasPrefix("[") else { return n }
        if let lt = n.firstIndex(of: "<") { n = String(n[..<lt]) }  // `Box<Foo>` → `Box`
        return n
    }

    /// A COLLECTION type name (`[T]`, `[K: V]`, `Array<T>`, …). Such a name denotes no declaration
    /// (B-FIX-28), so two collection names that differ textually may still be the same type
    /// (`Items` vs `[Item]`, `Array<T>` vs `[T]`, a typealias vs its target). A textual mismatch on
    /// one is therefore NO evidence — never a contradiction: eliminating a candidate on it would
    /// hand the call to the wrong overload, a wrong rename RollbackPass cannot catch. Equality still
    /// scores positively, so the common same-spelling case keeps disambiguating.
    private static func isCollectionTypeName(_ s: String) -> Bool {
        s.hasPrefix("[") || s.hasPrefix("Array<") || s.hasPrefix("Set<") || s.hasPrefix("Dictionary<")
    }

    /// Resolve a candidate's parameter-type string (as written in source) to a Symbol in the
    /// CANDIDATE's lexical context. Returns nil for primitives / external types (`String`, `Int`,
    /// SwiftUI / Foundation) that aren't in our SymbolTable — those are matched by name instead.
    ///
    /// THE one way to turn a `functionParamTypes` entry into a Symbol. The `.enumCase` branches of
    /// `argTypesContradict` / `disambiguateByArgTypes` used to read the same side table through the
    /// use-site scope and resolver instead, so one `switch` answered one question two ways
    /// (B-FIX-52). A parameter type spelled unqualified in the callee's scope (`_ shade: Shade` for
    /// a `Shade` nested in `Palette`) does not resolve at the call site at all — and where an
    /// UNRELATED top-level namesake exists it resolves to THAT, which is worse than nil: a
    /// same-named enum without the case scores the CORRECT overload inconsistent and eliminates it,
    /// leaving a sibling as a false unique match. That is a wrong rename, and RollbackPass cannot
    /// see it (the callee renamed cleanly, no original name survives).
    private func resolveParamType(_ paramTypeName: String, candidate: Symbol) -> Symbol? {
        let candScope = candidate.scope ?? currentScope
        return resolver(forModule: candidate.module.name)
            .typeSymbol(forQualifiedName: bareTypeName(paramTypeName), in: candScope)
    }

    /// Pick the overload from `candidates` that the call selects: filter by argument labels, then
    /// (if still >1) by argument types. Returns nil on zero or unresolved-ambiguous — callers must
    /// NOT rename then. Shared by free-function calls and member calls so both disambiguate
    /// identically.
    private func chooseOverload(_ candidates: [Symbol], call: FunctionCallExprSyntax) -> Symbol? {
        let callLabels = Self.argumentLabels(of: call)
        let labelMatches = candidates.filter { labelsMatch($0, callLabels, trailingStart: ArgumentLabelMatch.trailingStart(of: call)) }
        if labelMatches.count == 1 { return labelMatches[0] }
        if labelMatches.count > 1 { return disambiguateByArgTypes(labelMatches, call: call) }
        return nil
    }

    /// The FunctionCallExpr this member access is the callee of (`obj.method` in `obj.method(…)`),
    /// or nil when the member access isn't being called.
    private func enclosingCall(of node: MemberAccessExprSyntax) -> FunctionCallExprSyntax? {
        if let call = node.parent?.as(FunctionCallExprSyntax.self),
           call.calledExpression.id == Syntax(node).id {
            return call
        }
        return nil
    }

    /// Resolve `name` as a member of `typeScope` for a use-site, reporting WHY when it declines.
    ///
    /// When the name resolves to a single member, return it. When it's an OVERLOADED method
    /// (several same-named members), disambiguate by the enclosing call's signature — first-match
    /// would otherwise pick the wrong overload and emit a compile-breaking rename. Returns no
    /// symbol when overloaded but unresolvable (no call context, or still ambiguous): never guess
    /// between overloads.
    private func lookupMember(_ name: String, in typeScope: Scope,
                              node: MemberAccessExprSyntax) -> LookupOutcome {
        let declared = typeScope.members(named: name)
        guard !declared.isEmpty else { return .failed(.noCandidateInScope) }
        let call = enclosingCall(of: node)
        let position: UsePosition = call != nil ? .callee : .value
        // Narrow by SYNTACTIC POSITION before any fail-closed bail: a member access in callee
        // position denotes a callable, one that is not denotes a non-callable. Without this, a type
        // declaring both `var pf2: Bool` and `func pf2(for:) -> Bool` produced a mixed-kind set that
        // the bail below refused outright, so `p1.pf2(for: path)` was never rewritten while the
        // method's declaration was — and rollback shield 1b (the un-renamed property is a namesake)
        // blocked the rescue, so the desync SHIPPED as "cannot call value of non-function type".
        var candidates = Self.narrowed(declared, to: position)
        // Position narrowing can only pick from the set it is GIVEN, and a type's own scope is not
        // that set. Both visibility passes that fill it shadow BY NAME, so a type declaring the name
        // at ANY kind loses the inherited declaration: `SuperclassVisibility` copies an ancestor's
        // non-callables only (and drops even those), `ConformanceVisibility` copies a protocol's
        // defaults only while the name is free. So `class Sub: Base { var run: Bool }` over
        // `class Base { func run() }` (B-FIX-47) and `final class Impl: Runner { var go: Bool }`
        // over `extension Runner { func go() }` (B-FIX-48) both reach here with one candidate of the
        // WRONG kind, `narrowed` falls back to it (by contract — a closure-typed property IS
        // legitimately called), and the `count == 1` exit below rewrites the call to the PROPERTY's
        // obf. Complete the set from what the receiver inherits first.
        if !candidates.contains(where: { position.admits($0.kind) }) {
            switch inheritedCompletion(name, of: typeScope.owner, position: position,
                                       local: candidates) {
            case .none:
                break
            case .use(let inherited):
                candidates = inherited
            case .unknowable:
                return .failed(.inheritedKindConflict, candidateIds: candidates.map(\.id))
            }
        }
        if candidates.count == 1 { return outcome(for: candidates[0]) }
        // Checked BEFORE label filtering on purpose: a call may omit a defaulted label in a way
        // `labelsMatch` can't model, and when every candidate shares one obf the outcome is right
        // regardless of which overload the compiler selects.
        if let shared = unambiguousSharedObfTarget(candidates) { return .resolved(shared) }
        guard candidates.allSatisfy({ Self.isCallable($0.kind) }) else {
            return .failed(.mixedKindCandidates, candidateIds: candidates.map(\.id))
        }
        guard let call else {
            return .failed(.ambiguousOverload, candidateIds: candidates.map(\.id))
        }
        guard let picked = chooseOverload(candidates, call: call) else {
            return .failed(.ambiguousOverload, candidateIds: candidates.map(\.id))
        }
        return outcome(for: picked)
    }

    /// What the inheritance graph adds to a member candidate set that has nothing of the right kind.
    enum InheritedCompletion {
        /// Nothing the type inherits declares the name at the demanded kind — the local set is the
        /// whole story.
        case none
        /// These inherited declarations ARE the candidate set: every local candidate is a
        /// non-callable of a KNOWN, non-function type, so the compiler cannot be reading one of them.
        case use([Symbol])
        /// Both readings are live and only type inference settles it — fail closed.
        case unknowable
    }

    /// Complete a member candidate set from what the receiver INHERITS — its LOCAL superclass chain
    /// (B-FIX-47) and its LOCAL protocols' extension defaults (B-FIX-48) — when the receiver's own
    /// scope declares the name only at the wrong KIND for this use-site's position.
    ///
    /// The three shapes, all run through swiftc as programs before this was written, in both the
    /// class form and the protocol form (they behave identically, which is why one decision table
    /// serves both):
    ///
    ///   1. `class Base { func run() -> String }` / `class Sub: Base { var run: Bool }` — `s.run()`
    ///      prints `BASE-METHOD`: a `Bool` is not callable, so the base METHOD is what is called.
    ///      Answer `.use([Base.run])`. Protocol form: `extension Runner { func go() -> String }` /
    ///      `final class Impl: Runner { var go: Bool }` — `i.go()` prints `PROTO` (the property does
    ///      NOT witness the requirement; the extension default does).
    ///   2. Same shape with `var run: () -> String` — `s.run()` prints `PROP`: a closure-typed
    ///      property IS callable and shadows the base method. `WrittenTypeName.of` returns nil for a
    ///      function type, so a property that might be one is exactly a property with no recorded
    ///      `declaredType` — that is the `.unknowable` test, and it also covers `var run = { … }`.
    ///      Protocol form: `final class Impl: Runner { var go: () -> String }` also prints `PROP`.
    ///   3. Mirror image, `class Base { var flag: Bool }` / `class Sub: Base { func flag() }` —
    ///      `let a = s.flag` reads the base PROPERTY, but `let g: () -> Int = s.flag` picks the
    ///      subclass METHOD. The use-site's contextual type decides, and this tier does not model
    ///      contextual types, so VALUE position is always `.unknowable`. That still fixes the bug it
    ///      is there for: today the local method is rewritten anyway (a wrong rename nothing
    ///      catches), and `.unknowable` turns it into a surviving original name RollbackPass reverts.
    ///      Protocol form: `extension Flagged { var flag: Bool }` / `final class Impl: Flagged
    ///      { func flag() -> Int }` prints `true 7` for the same two sites.
    ///
    /// Deliberately a RESOLVER-side walk, not an injection into the conformer's scope: an inherited
    /// method placed in a lexical scope becomes a false unique match in `resolveCall` and shadows the
    /// protocol-extension overload a call actually selects (the regression that keeps
    /// `SuperclassVisibility` non-callable-only — `testOverloadByArgType_…`). Nothing here touches
    /// `resolveCall`.
    private func inheritedCompletion(_ name: String, of owner: Symbol?, position: UsePosition,
                                     local: [Symbol]) -> InheritedCompletion {
        guard let owner, Self.hasInheritedMembers(owner.kind) else { return .none }
        let inherited = inheritedMembers(name, of: owner, admitting: position)
        guard !inherited.isEmpty else { return .none }
        guard position == .callee else { return .unknowable }
        // Callee position: the local candidates keep the call only if one of them can be called AS A
        // VALUE, i.e. is or might be function-typed. Anything with a known non-function type cannot.
        return local.allSatisfy(isKnownNonFunctionTyped) ? .use(inherited) : .unknowable
    }

    /// Kinds whose member set can be larger than their own scope: a CLASS through its superclass
    /// chain, and every conformer kind — including a `protocol`, for protocol-to-protocol
    /// inheritance — through its protocols' extension defaults. `struct`/`enum` are in the set for
    /// the conformance half ONLY (they have no superclass), and that half is what makes them belong:
    /// `struct Impl: Runner { var go: Bool }` calls the extension default exactly as the class does.
    private static func hasInheritedMembers(_ k: SymbolKind) -> Bool {
        switch k { case .class, .struct, .enum, .protocol: return true; default: return false }
    }

    /// The TYPE a symbol is a member of, or nil when it is a local or a parameter — the kinds that
    /// genuinely SHADOW an inherited callable instead of unioning with it (`func f(tick: String)
    /// { tick() }` is an error in Swift, verified).
    private func memberOwnerType(of sym: Symbol) -> Symbol? {
        guard let scope = sym.scope, scope.kind == .type,
              let owner = scope.owner, Self.hasInheritedMembers(owner.kind) else { return nil }
        return owner
    }

    /// Members named `name` that `position` admits, taken from the NEAREST inherited level declaring
    /// the name at that kind. Levels in Swift's own precedence order: the superclass chain first
    /// (nearest ancestor first — a base-class member beats a protocol default), then the protocols
    /// the type or any of its ancestors conforms to. Memoized per type: both walks re-parse the
    /// declaring file's inheritance clause.
    private func inheritedMembers(_ name: String, of type: Symbol,
                                  admitting position: UsePosition) -> [Symbol] {
        let ancestors: [Symbol]
        if let cached = ancestorCache[type.id] {
            ancestors = cached
        } else {
            // Harmless and correct on a struct/enum/protocol: `preferredType(kind: .class, …)`
            // answers nil for every name in their clause, so the chain is empty.
            ancestors = SuperclassChain.ancestors(of: type, in: table)
            ancestorCache[type.id] = ancestors
        }
        for ancestor in ancestors {
            if let found = members(name, in: ancestor, admitting: position) { return found }
        }
        let protocols: [Symbol]
        if let cached = conformanceCache[type.id] {
            protocols = cached
        } else {
            // A class inherits its superclass's CONFORMANCES too: `final class D: B { var ping: Int }`
            // over `class B: Pinger {}` calls `Pinger`'s default at `D().ping()` (checked against
            // swiftc). Dedup by id — protocol-to-protocol inheritance is already folded into each
            // protocol's scope by ConformanceVisibility, so the same protocol is reachable twice.
            var seen: Set<Int> = []
            protocols = ([type] + ancestors)
                .flatMap { ConformanceChain.protocols(of: $0, in: table) }
                .filter { seen.insert($0.id).inserted }
            conformanceCache[type.id] = protocols
        }
        for proto in protocols {
            if let found = members(name, in: proto, admitting: position) { return found }
        }
        return []
    }

    /// The members of `owner`'s canonical inner scope named `name` that `position` admits, or nil
    /// when it declares none — "nil" is what makes the caller keep walking to the next level.
    private func members(_ name: String, in owner: Symbol,
                         admitting position: UsePosition) -> [Symbol]? {
        guard let scope = innerScope(of: owner) else { return nil }
        let found = scope.members(named: name).filter { position.admits($0.kind) }
        return found.isEmpty ? nil : found
    }

    /// True when `sym`'s type is KNOWN and is not a function type — the only state in which we can
    /// say the compiler is NOT calling this member at `obj.name()`.
    ///
    /// `WrittenTypeName.of` (the single reducer behind `declaredType` and `typealiasTarget`) returns
    /// nil for a function type, so "no recorded type" already means "possibly callable" — and so does
    /// a chain that ends at a typealias with no recorded target, which is how
    /// `typealias Handler = () -> Void; var run: Handler` reaches us.
    private func isKnownNonFunctionTyped(_ sym: Symbol) -> Bool {
        var typeName = table.declaredType[sym.id]
        var scope = sym.scope
        var hops = 0
        while let written = typeName, hops < 8 {
            hops += 1
            guard let resolved = typeResolver.typeSymbol(forQualifiedName: written,
                                                         in: scope ?? currentScope) else {
                return true                       // a name we don't own — a written, non-function type
            }
            guard resolved.kind == .typealias_ else { return true }
            guard let target = table.typealiasTarget[resolved.id] else { return false }
            typeName = target
            scope = resolved.scope
        }
        return false
    }

    /// A resolved candidate, tagged `candidate-has-no-obf` when it carries no obf: the use-site is
    /// correct as it stands (the declaration was protected or policy-skipped), which is exactly what
    /// turns an unexplained survivor into an explained one.
    private func outcome(for sym: Symbol) -> LookupOutcome {
        map.obf(for: sym) != nil
            ? .resolved(sym)
            // Empty on purpose: `reportUnresolved` returns before touching `candidateIds` for
            // `.candidateHasNoObf` (that position's record comes from `emitRename` instead), and
            // this branch runs on EVERY resolved-but-unrenamed member — the largest population in
            // the report. Allocating a one-element array here would be a per-use-site cost on the
            // default path for a value nothing ever reads.
            : .init(symbol: sym, cause: .candidateHasNoObf, candidateIds: [])
    }

    static func isCallable(_ k: SymbolKind) -> Bool {
        k == .method || k == .function
    }

    /// What the SYNTAX at a use-site says about the kind of declaration it references — the part of
    /// name resolution Swift's grammar settles before any type information exists.
    ///
    /// `Scope.member(named:)` / `Scope.members(named:)` are kind-BLIND and hand back declarations in
    /// source order, so a type that declares two same-named members of different kinds (`var pf2:
    /// Bool` plus `func pf2(for:) -> Bool` — legal Swift, and the shape a protocol overloading one
    /// name across kinds produces) resolved by a coin flip or, worse, was refused outright.
    enum UsePosition {
        /// `x.f(…)` / `f(…)` — the callee of a call: a method or function.
        case callee
        /// `x.f` read as a value, and every key-path component: never a callable.
        case value
        /// `A.B` in TYPE position: a type-like declaration.
        case typeReference

        func admits(_ k: SymbolKind) -> Bool {
            switch self {
            case .callee:        return ResolutionVisitor.isCallable(k)
            case .value:         return !ResolutionVisitor.isCallable(k)
            case .typeReference: return k.isTypeLike
            }
        }
    }

    /// The candidates that can occupy `position`. Applied ONLY when it leaves a non-empty set: an
    /// empty result means the grammar rule does not apply at this site — a closure-typed PROPERTY is
    /// legitimately invoked as `obj.handler()`, whose callee is not a callable *declaration* — so
    /// the original set is the honest answer and the caller's fail-closed logic decides as before.
    static func narrowed(_ candidates: [Symbol], to position: UsePosition) -> [Symbol] {
        guard candidates.count > 1 else { return candidates }
        let matching = candidates.filter { position.admits($0.kind) }
        return matching.isEmpty ? candidates : matching
    }

    /// True when the call's argument labels can be satisfied by the symbol's parameters. Thin
    /// wrapper over the ONE implementation of that rule (`ArgumentLabelMatch`, B-FIX-36) — defaulted
    /// parameters may be skipped (B-FIX-11), an unlabeled TRAILING closure satisfies a labeled
    /// closure-typed parameter (F5). Do not reimplement either half here or anywhere else.
    private func labelsMatch(_ sym: Symbol, _ callLabels: [String?], trailingStart: Int) -> Bool {
        ArgumentLabelMatch.matches(sym, callLabels: callLabels, trailingStart: trailingStart, in: table)
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        let memberToken = node.declName.baseName
        let memberName = stripBackticks(memberToken.text)

        if let base = node.base {
            // Resolve base to a scope.
            if let baseRef = base.as(DeclReferenceExprSyntax.self) {
                let baseName = stripBackticks(baseRef.baseName.text)
                if baseName == "self" || baseName == "Self" {
                    // For `Self.X` inside an extension, the enclosing scope is the extension's
                    // own scope — which only knows extension-declared members. Members declared
                    // on the main type need lookup against the type symbol's CANONICAL inner scope.
                    let owner = enclosingTypeScope()?.owner
                    if let owner, let canonical = innerScope(of: owner) {
                        let found = lookupMember(memberName, in: canonical, node: node)
                        if let target = report(found, name: memberName, token: memberToken,
                                               receiver: owner) {
                            emitRename(for: memberToken, target: target)
                        }
                    } else if let extScope = enclosingExternalExtensionScope() {
                        // Inside an extension of an EXTERNAL type there IS no owner symbol, so
                        // `self.member` resolves against the extension's own scope (B-FIX-31).
                        // Without it the decl renames while `self.member` survives → revert.
                        let found = lookupMember(memberName, in: extScope, node: node)
                        if let target = report(found, name: memberName, token: memberToken,
                                               receiver: nil) {
                            emitRename(for: memberToken, target: target)
                        }
                    } else {
                        reportUnresolved(.receiverUntyped, name: memberName, token: memberToken)
                    }
                    return .visitChildren
                }
                // Base may be a type name. Resolve it preferring the LEXICAL scope chain — a
                // bare `Constants` inside `class C1 { enum Constants {...} }` means C1.Constants
                // (the nested, lexically-nearest type), NOT some other module's same-named type.
                // Only when no lexical type is visible do we fall back to the global,
                // module-aware table. (Skip if the name is a shadowed local — that's a value.)
                if !isLocallyShadowed(
                       baseName,
                       at: baseRef.baseName.positionAfterSkippingLeadingTrivia.utf8Offset) {
                    let baseTypeSym: Symbol? = {
                        if let s = currentScope.lookup(name: baseName), s.kind.isTypeLike { return s }
                        return lookupType(named: baseName)
                    }()
                    if let typeSym = baseTypeSym {
                        emitRename(for: baseRef.baseName, target: typeSym)
                        // Unwrap typealias so members live in the underlying type's scope. When
                        // `typeSym` is `typealias T1 = E1`, `innerScope(T1)` is nil — but `.ErrorType`
                        // is a member of E1. Without this unwrap, the member token stays un-renamed
                        // while the typealias's own decl was obfuscated → desync.
                        let walkSym = typealiasUnwrap(typeSym)
                        if let typeScope = innerScope(of: walkSym) {
                            let found = lookupMember(memberName, in: typeScope, node: node)
                            if let target = report(found, name: memberName, token: memberToken,
                                                   receiver: walkSym) {
                                emitRename(for: memberToken, target: target)
                            }
                        } else {
                            reportUnresolved(.receiverUntyped, name: memberName, token: memberToken,
                                             receiver: walkSym.name)
                        }
                        return .skipChildren
                    }
                }
                // Base is an identifier we don't know as a type. Try precise type resolution
                // (handles property/parameter declared types, $x/_x property-wrapper projections,
                // optional chaining, try/await, etc.) and look up `member` in the resolved type.
                resolveMemberAccess(memberName, token: memberToken, base: base, node: node)
                return .visitChildren
            }
            // Chained / complex base: type-resolve to a precise type symbol (avoids ambiguity
            // when two types share a simple name — e.g. nested Coordinator inside different parents).
            resolveMemberAccess(memberName, token: memberToken, base: base, node: node)
            return .visitChildren
        } else {
            // Shorthand `.member` — only rename if we positively identify the contextual type.
            // Globally-unique-name fallback was removed: stdlib enums often collide with our names.
            // The context carries its own SCOPE: a type name read off another declaration (a
            // callee's parameter, a stored property) is written where THAT declaration lives, so a
            // nested type spelled unqualified resolves only there (B-FIX-23 discipline).
            if let context = contextualType(for: node),
               let typeSym = typeResolver.typeSymbol(forQualifiedName: context.name,
                                                     in: context.scope ?? currentScope),
               let typeScope = innerScope(of: typeSym) {
                let found = lookupMember(memberName, in: typeScope, node: node)
                if let member = report(found, name: memberName, token: memberToken, receiver: typeSym) {
                    emitRename(for: memberToken, target: member)
                }
            } else {
                reportUnresolved(.noContextualType, name: memberName, token: memberToken)
            }
            return .visitChildren
        }
    }

    /// A member access whose base is an EXPRESSION (a value reference or a chain), shared by the
    /// two branches that reach one. Type the receiver, look the member up in it, and only when the
    /// receiver could NOT be typed at all fall back to the name-based external-extension routes.
    ///
    /// That last condition is the load-bearing one. `uniqueExternalMember` rewrites by NAME alone
    /// (see `ResolutionPass.uniqueExternalExtensionMembers`), and it used to fire whenever the whole
    /// `if` chain failed — including when the receiver typed PERFECTLY and only the member lookup
    /// did not (Case A's mixed-kind bail, an inherited member, a typo'd side table). A well-typed
    /// LOCAL receiver would then have its member rewritten to the obf of an unrelated `extension
    /// String { func foo() }` member that merely shares the name: a wrong rename, the class
    /// RollbackPass cannot catch because no original name is left behind. The fallback is only ever
    /// justified by "we have no idea what this receiver is", so that is now literally the condition.
    private func resolveMemberAccess(_ memberName: String, token: TokenSyntax,
                                     base: ExprSyntax, node: MemberAccessExprSyntax) {
        let baseSym = resolveTypeSymbol(of: base)
        if let baseSym {
            if let typeScope = innerScope(of: baseSym) {
                let found = lookupMember(memberName, in: typeScope, node: node)
                if let member = report(found, name: memberName, token: token, receiver: baseSym) {
                    emitRename(for: token, target: member)
                }
            } else {
                reportUnresolved(.receiverUntyped, name: memberName, token: token,
                                 receiver: baseSym.name)
            }
            return
        }
        // No typeable receiver. `resolveExternalExtensionMember` still matches on the receiver's
        // WRITTEN type (a collection has no Symbol since B-FIX-28 but does have a written type);
        // `uniqueExternalMember` is the last resort for receivers that cannot be typed at all —
        // the SwiftUI `extension View` modifier idiom, whose receivers are `some View` chains no
        // syntactic resolver can reach.
        if let member = resolveExternalExtensionMember(memberName, base: base, node: node)
            ?? uniqueExternalMember(memberName) {
            emitRename(for: token, target: member)
        } else {
            reportUnresolved(.receiverUntyped, name: memberName, token: token)
        }
    }

    // MARK: - Members of extensions on EXTERNAL types (B-FIX-31)

    /// The enclosing scope that is the body of an eligible external-type extension, if any.
    private func enclosingExternalExtensionScope() -> Scope? {
        var s: Scope? = currentScope
        while let cur = s {
            if cur.kind == .type, cur.owner == nil, table.isExternalExtensionScope(cur) { return cur }
            s = cur.parent
        }
        return nil
    }

    /// A member declared in an extension of a type we do NOT own (`extension String { … }`,
    /// `extension Array where Element == Mood { … }`), reached through `base`.
    ///
    /// Invariant: such an extension binds to a WRITTEN TYPE, not to a Symbol, so the use-site is
    /// matched the same way — the receiver's written type must denote the extended type (for a
    /// collection: a compatible collection KIND whose Element satisfies the extension's `Element ==`
    /// constraint). Fail-closed at every step: a receiver we cannot type, a kind that doesn't match,
    /// an element that isn't provably the same type, or several candidate declarations that don't
    /// share one obf all yield nil, leaving the use-site original (RollbackPass then reverts the
    /// group — under-obfuscation, never a wrong rename).
    private func resolveExternalExtensionMember(_ name: String, base: ExprSyntax,
                                                node: MemberAccessExprSyntax) -> Symbol? {
        guard !table.externalExtensions.isEmpty,
              let info = typeResolver.receiverTypeInfo(of: base, in: currentScope) else { return nil }
        let receiver = typeResolver.expandedTypeName(info.name, in: info.declScope)
        var declared: [Symbol] = []
        for ext in table.externalExtensions
        where externalExtensionApplies(ext, toReceiverType: receiver.name, writtenIn: receiver.scope) {
            declared.append(contentsOf: ext.scope.members(named: name))
        }
        // Same position rule as `lookupMember`: an extension may declare `var foo` and `func foo()`
        // on the same external type just as a local type may.
        let call = enclosingCall(of: node)
        var candidates = Self.narrowed(declared, to: call != nil ? .callee : .value)
        if candidates.count == 1 { return candidates[0] }
        guard candidates.count > 1 else { return nil }
        // Cross-target duplicates: a multi-target app compiles the same file into several writable
        // modules, so the same extension member exists once per module, each with its own obf. The
        // use-site takes its OWN module's copy — the same tiebreak `disambiguateByArgTypes` and
        // `resolveQualifiedTypeChain` apply. Without it every such member is ambiguous ⇒ reverted.
        let sameModule = candidates.filter { $0.module.name == file.module.name }
        if sameModule.count == 1 { return sameModule[0] }
        if !sameModule.isEmpty { candidates = sameModule }
        if let shared = unambiguousSharedObfTarget(candidates) { return shared }
        guard candidates.allSatisfy({ Self.isCallable($0.kind) }), let call else { return nil }
        return chooseOverload(candidates, call: call)
    }

    /// The project-unique external-extension member named `name`, taken from the USE-SITE's own
    /// module (a multi-target app compiles the same source into several modules — each target's
    /// copy has its own Symbol and its own obf). nil when the name isn't admitted or this module
    /// declares no copy of it.
    private func uniqueExternalMember(_ name: String) -> Symbol? {
        guard let byModule = uniqueExternalMembers[name] else { return nil }
        if let same = byModule[file.module.name] { return same }
        return byModule.count == 1 ? byModule.values.first : nil
    }

    /// Does `ext` apply to a receiver whose written type is `raw` (written in `scope`)?
    private func externalExtensionApplies(_ ext: SymbolTable.ExternalExtensionRef,
                                          toReceiverType raw: String, writtenIn scope: Scope) -> Bool {
        if let kind = CollectionMemberRegistry.collectionKind(of: raw) {
            guard CollectionMemberRegistry.applicableExtensionBases(forKind: kind).contains(ext.baseName) else {
                return false
            }
            guard let constraint = ext.elementConstraint else { return true }   // applies to any Element
            guard let element = CollectionMemberRegistry.sequenceElement(of: raw) else { return false }
            // Element identity, not string equality: the constraint and the receiver's element are
            // written in DIFFERENT scopes and may be spelled differently (bare vs qualified, or
            // through a typealias) — the B-FIX-27 comparator is exactly this question.
            return TypeNameEquivalence.sameType(element, inScope: scope, module: file.module.name,
                                                constraint, inScope: ext.declScope, module: ext.module,
                                                table: table)
        }
        // A named external type (`extension String`, `extension Date`). An element constraint on a
        // non-collection is a shape we don't model — fail closed.
        return ext.elementConstraint == nil && bareTypeName(raw) == ext.baseName
    }

    /// A contextual type for a base-less `.member`: the written type NAME plus the scope that name
    /// must be RESOLVED in. The scope matters whenever the name is read off ANOTHER declaration (a
    /// callee's parameter, a stored property): a nested type written unqualified is visible only
    /// where it was written, so resolving it at the use-site silently finds nothing (B-FIX-23).
    /// `scope == nil` means "written here", i.e. resolve at the use-site scope.
    private struct ContextualType {
        let name: String
        let scope: Scope?
    }

    /// One level of LITERAL nesting between the shorthand and the declaration that types it:
    /// `[.a]` is an element of the context type, `[.k: v]` its dictionary key, `[k: .v]` its value.
    /// Collected innermost-first while walking up, applied outermost-first to the written type.
    private enum LiteralPeel { case element, dictionaryKey, dictionaryValue }

    /// Peel a written type name along the literal path the shorthand sits in. Fail-closed: a level
    /// we cannot peel (a non-collection type, an unmodelled shape) yields nil rather than a guessed
    /// context — a wrong context rewrites `.case` to ANOTHER enum's obf, which RollbackPass cannot
    /// catch. This is the single chokepoint where a contextual type meets literal nesting; it
    /// replaced `scalarElementType`, whose fixed "unwrap array/optional" could not tell a key from a
    /// value, ignored the nesting DEPTH, and unwrapped even when no literal was involved.
    private static func peeled(_ typeName: String, through peels: [LiteralPeel]) -> String? {
        var name = typeName
        for peel in peels.reversed() {
            switch peel {
            case .element:
                guard let e = TypeResolver.extractElement(from: name) else { return nil }
                name = e
            case .dictionaryKey:
                guard let k = TypeResolver.dictionaryKeyType(from: name) else { return nil }
                name = k
            case .dictionaryValue:
                guard let v = TypeResolver.dictionaryValueType(from: name) else { return nil }
                name = v
            }
        }
        return name
    }

    /// Walks up the parent chain looking for a context that tells us the type of a shorthand
    /// `.member` expression. Handles:
    ///   - `let x: T = .member` / `var x: T = .member` (PatternBinding type annotation)
    ///   - `f(.member)` / `f(arg: .member)` (function-call argument; callee resolved to a local
    ///     function / method / INITIALIZER whose nth parameter has a known simple type)
    ///   - the same through literal wrappers: `[.member]`, `[[.member]]`, `[.key: .value]`
    /// Returns the resolved type name plus the scope to resolve it in, or nil.
    private func contextualType(for memberAccess: MemberAccessExprSyntax) -> ContextualType? {
        var current: Syntax? = Syntax(memberAccess).parent
        // First wrapper we want to skip: LabeledExprSyntax (`label: .case` arg). Track if we
        // came via an argument list so we can resolve the call.
        var argumentIndex: Int? = nil
        var sawReturn = false
        var peels: [LiteralPeel] = []
        while let node = current {
            if node.is(ReturnStmtSyntax.self) { sawReturn = true }
            // Literal wrappers between the shorthand and its typing declaration.
            if node.is(ArrayExprSyntax.self) { peels.append(.element) }
            if let element = node.as(DictionaryElementSyntax.self) {
                peels.append(Self.isDescendant(Syntax(memberAccess), of: Syntax(element.key))
                             ? .dictionaryKey : .dictionaryValue)
            }
            if let tuple = node.as(TupleExprSyntax.self) {
                // A single unlabeled element is just parentheses (transparent). A real tuple is a
                // shape we don't model — fail closed rather than type the shorthand as the whole
                // tuple.
                guard tuple.elements.count == 1, tuple.elements.first?.label == nil else { return nil }
            }
            // Switch case pattern: contextual type is the switch subject's type. Also covers the
            // `if/guard/while case .x = e` (MatchingPatternCondition) and `for case .x in seq`
            // (ForStmt, peeled one element level) forms — context = the matched value's type. If we
            // cannot resolve it, return nil — never fall through to outer contexts (the enclosing
            // var/return type is NOT the same as the matched subject's type).
            if node.is(SwitchCaseItemSyntax.self) || node.is(ExpressionPatternSyntax.self) {
                var probe = node.parent
                while let p = probe {
                    if let sw = p.as(SwitchExprSyntax.self) {
                        return resolveExpressionContext(sw.subject, peels: peels)
                    }
                    if let mc = p.as(MatchingPatternConditionSyntax.self) {
                        return resolveExpressionContext(mc.initializer.value, peels: peels)
                    }
                    // `for case .loaded(let row) in states` (B-FIX-81) — the pattern is matched against
                    // each ELEMENT of the sequence, so the shorthand's context is the sequence's element
                    // type. `forCaseElementType` gets it via `receiverTypeInfo` (NOT `typeSymbol`, which
                    // answers nil for a collection value, B-FIX-28, so `resolveExpressionContext` cannot).
                    // Without this the case name stays original while the case declaration renames →
                    // `type 'T' has no member 'loaded'`.
                    if let forStmt = p.as(ForStmtSyntax.self), forStmt.caseKeyword != nil {
                        guard let element = forCaseElementType(of: forStmt.sequence),
                              let name = Self.peeled(element.name, through: peels) else { return nil }
                        return ContextualType(name: name, scope: element.scope)
                    }
                    probe = p.parent
                }
                return nil
            }
            // Binary-operator operand: `x == .case` / `x != .case` / `x ~= .case` / `opt ?? .case`
            // (raw-parsed as a SequenceExpr `[lhs, BinaryOperatorExpr, rhs]`). The shorthand takes
            // the type of the OTHER operand — NOT the enclosing return/var type. Without this a
            // `.case` compared against a property of a DIFFERENT type wrongly grabs the return-type
            // context (a static member of that type) and renames to it → wrong-rename red.
            if let seq = node.as(SequenceExprSyntax.self) {
                let elems = Array(seq.elements)
                // Which TOP-LEVEL element are we inside? A raw-parsed sequence is flat, so a ternary
                // (`x = flag ? .a : .b` parses as 5+ elements, the `? .a :` part being one
                // UnresolvedTernaryExpr) must not be mistaken for "not an assignment" — the old
                // exact-3-element shape silently dropped the context for every ternary branch.
                if let idx = elems.firstIndex(where: { Self.isDescendant(Syntax(memberAccess), of: Syntax($0)) }) {
                    // Comparison / coalescing FIRST: it binds tighter than the assignment around it.
                    // In `self.mood = slot == .morning ? .calm : .sharp` the `.morning` operand is
                    // typed by `slot`, NOT by the assignment's left-hand side — letting the
                    // assignment claim the whole right-hand side would type it as the LHS's enum and
                    // rewrite it to a same-named case of the WRONG enum. The shorthand's IMMEDIATE
                    // operator neighbour decides; the other operand is the element beyond it.
                    if idx >= 2, let op = elems[idx - 1].as(BinaryOperatorExprSyntax.self),
                       Self.contextGivingOperators.contains(op.operator.text) {
                        return resolveExpressionContext(elems[idx - 2], peels: peels)
                    }
                    if idx + 2 < elems.count, let op = elems[idx + 1].as(BinaryOperatorExprSyntax.self),
                       Self.contextGivingOperators.contains(op.operator.text) {
                        return resolveExpressionContext(elems[idx + 2], peels: peels)
                    }
                    // Assignment: everything right of `=` takes the LHS's type, however many
                    // elements the RHS parsed into (a ternary makes it 5+, which the old exact
                    // 3-element shape dropped). A base-less `.case` is always on the RHS — you
                    // cannot assign to a shorthand.
                    if elems.count > 2, idx >= 2, elems[1].is(AssignmentExprSyntax.self) {
                        return resolveExpressionContext(elems[0], peels: peels)
                    }
                }
            }
            // Variable/property type annotation. The literal path decides how much of the written
            // type to peel: `let xs: [E] = [.a]` peels one element level, `let m: [K: V] = [.a: .b]`
            // peels a key on one side and a value on the other, `let o: E? = .a` peels nothing (the
            // optional marker is stripped by the resolver itself).
            if let binding = node.as(PatternBindingSyntax.self),
               let annotation = binding.typeAnnotation,
               let name = Self.peeled(annotation.type.trimmedDescription, through: peels) {
                return ContextualType(name: name, scope: nil)   // written here
            }
            // Function call argument context.
            if argumentIndex == nil, let labeled = node.as(LabeledExprSyntax.self) {
                if let list = labeled.parent?.as(LabeledExprListSyntax.self) {
                    argumentIndex = list.enumerated().first(where: { $0.element.id == labeled.id })?.offset
                }
            }
            if let call = node.as(FunctionCallExprSyntax.self), let idx = argumentIndex {
                // The parameter type is written in the CALLEE's scope, so it travels with it.
                if let param = resolveCalleeParamType(call: call, argIndex: idx),
                   let name = Self.peeled(param.name, through: peels) {
                    return ContextualType(name: name, scope: param.scope)
                }
                return nil  // Resolved call but couldn't get param type → give up.
            }
            // Default value of a function/init parameter: `func f(x: E = .case)`. The context is the
            // PARAMETER's own declared type — must be checked BEFORE the FunctionDecl branch below,
            // or we'd wrongly grab the function's return type. (Walking up, the parameter node is
            // reached first.) Without this the `.case` default is left un-renamed while the enum case
            // is obfuscated → the original name survives → RollbackPass reverts the case → under-obf,
            // or (short debug names) an obf collision = `invalid redeclaration` red build.
            if let param = node.as(FunctionParameterSyntax.self),
               let name = Self.peeled(param.type.trimmedDescription, through: peels) {
                return ContextualType(name: name, scope: nil)   // written here
            }
            // Function/method/init return type acts as context for a `.case` ONLY in return
            // position — an explicit `return .case` (sawReturn) or a single-expression implicit
            // return (`func f() -> E { .a }`). A `.case` elsewhere in the body (e.g. a comparison
            // operand) must NOT grab the return type — that leaked Style.active into `mode ==
            // .active` → wrong-rename red. If we reached the function without a return position and
            // no earlier context matched, fail closed (nil).
            if let fn = node.as(FunctionDeclSyntax.self),
               let returnClause = fn.signature.returnClause,
               let returned = Self.peeled(returnClause.type.trimmedDescription, through: peels) {
                let implicitReturn = fn.body?.statements.count == 1
                return (sawReturn || implicitReturn) ? ContextualType(name: returned, scope: nil) : nil
            }
            // Don't escape past the file root.
            if node.is(SourceFileSyntax.self) { return nil }
            current = node.parent
        }
        return nil
    }

    /// Binary operators whose base-less-`.case` operand takes its type from the OTHER operand:
    /// equality/pattern-match comparisons and nil-coalescing. Arithmetic/logical operators never
    /// take an enum-case shorthand, so they're excluded (no false context).
    static let contextGivingOperators: Set<String> = ["==", "!=", "~=", "??"]

    /// True when `node` is (transitively) contained in `ancestor`.
    static func isDescendant(_ node: Syntax, of ancestor: Syntax) -> Bool {
        var p: Syntax? = node
        while let cur = p {
            if cur.id == ancestor.id { return true }
            p = cur.parent
        }
        return false
    }

    /// Delegate to shared TypeResolver, providing current scope context.
    private func resolveTypeSymbol(of expr: ExprSyntax) -> Symbol? {
        typeResolver.typeSymbol(of: expr, in: currentScope)
    }

    /// Contextual type from an EXPRESSION (switch subject, assignment LHS, comparison operand). The
    /// type is a resolved Symbol, so its own scope is the right place to re-resolve the name from:
    /// a nested type's bare name (`Mode` inside `enum NS`) does not resolve at the use-site.
    private func resolveExpressionContext(_ expr: ExprSyntax, peels: [LiteralPeel]) -> ContextualType? {
        guard let sym = resolveTypeSymbol(of: expr),
              let name = Self.peeled(sym.name, through: peels) else { return nil }
        return ContextualType(name: name, scope: sym.scope)
    }

    /// Parameter type at `argIndex` of whatever `call` calls — a function, a method, or an
    /// INITIALIZER (explicit or the struct's synthesized memberwise one). The type NAME travels with
    /// the scope it was written in, because that is the only scope it is guaranteed to resolve in.
    private func resolveCalleeParamType(call: FunctionCallExprSyntax, argIndex: Int) -> ContextualType? {
        // Direct call: `funcName(...)` / `TypeName(...)` — calledExpression is DeclReferenceExpr.
        if let ref = call.calledExpression.as(DeclReferenceExprSyntax.self) {
            let name = stripBackticks(ref.baseName.text)
            // Use full overload resolution (label + type aware) so we find the right overload
            // even when it's an extension / cross-module method not visible in the scope chain —
            // otherwise a shorthand `.case` argument can't learn its contextual enum type and is
            // left un-renamed while the enum case itself was renamed (`has no member` breakage).
            if let sym = resolveCall(name: name, call: call) ?? currentScope.lookup(name: name) {
                if let type = declaredParamType(of: sym, call: call, argIndex: argIndex) {
                    return ContextualType(name: type, scope: sym.scope)
                }
                // The callee is a VALUE of function type (a closure/function-typed parameter, local or
                // property — `completion(.c2)` where `completion: (E1) -> Void`), which has no
                // `functionParamTypes` entry. Its input at this argument types the shorthand (B-FIX-66).
                if let ctx = closureValueInputType(of: sym, at: argIndex) { return ctx }
            }
            // CONSTRUCTOR call. A type name is not a callable, so neither branch above can see it
            // and the argument had NO context at all — the single widest hole in contextual `.case`
            // resolution, since one uncovered constructor call reverts the enum's whole case group.
            if let typeSym = constructedType(named: name) {
                return initializerParamType(ofType: typeSym, call: call, argIndex: argIndex)
            }
            return nil
        }
        // Base-less callee: `let c: Command = .run(.calm)` — the callee is ITSELF a shorthand, so
        // the payload's context sits one level deeper. Resolve the callee's own contextual type
        // first, then read the case's associated type. Terminates: the callee is the call's
        // `calledExpression`, never one of its arguments, so its walk-up skips this same call.
        if let m = call.calledExpression.as(MemberAccessExprSyntax.self), m.base == nil {
            guard let context = contextualType(for: m),
                  let enumSym = typeResolver.typeSymbol(forQualifiedName: context.name,
                                                        in: context.scope ?? currentScope),
                  let type = enumCaseAssociatedType(named: stripBackticks(m.declName.baseName.text),
                                                    in: enumSym, argIndex: argIndex) else { return nil }
            return type
        }
        // Member-access callee: `obj.method(...)`, `Type.init(...)`, `NS.Type(...)`, `E.case(...)`.
        if let m = call.calledExpression.as(MemberAccessExprSyntax.self), let receiver = m.base {
            let methodName = stripBackticks(m.declName.baseName.text)
            // `X.init(...)` / `self.init(...)` — an explicit initializer reference.
            if methodName == "init" {
                guard let typeSym = resolveTypeSymbol(of: receiver) else { return nil }
                return initializerParamType(ofType: typeSym, call: call, argIndex: argIndex)
            }
            // `NS.Config(...)` — a QUALIFIED type being CONSTRUCTED, not a method call on `NS`.
            // Same discrimination TypeResolver uses for this shape: the whole callee resolves to a
            // type-like Symbol, with the upper-case last segment as a cheap pre-filter.
            if let first = methodName.first, first.isUppercase,
               let typeSym = typeResolver.typeSymbol(forQualifiedName: call.calledExpression.trimmedDescription,
                                                     in: currentScope),
               typeSym.kind.isTypeLike {
                return initializerParamType(ofType: typeSym, call: call, argIndex: argIndex)
            }
            guard let recvType = resolveTypeSymbol(of: receiver),
                  let scope = innerScope(of: recvType) else { return nil }
            // `Command.run(payload)` — an enum case with associated values, called like a function.
            if recvType.kind == .enum,
               let type = enumCaseAssociatedType(named: methodName, in: recvType, argIndex: argIndex) {
                return type
            }
            let cands = scope.members(named: methodName).filter { Self.isCallable($0.kind) }
            if let sym = (cands.count == 1 ? cands.first : chooseOverload(cands, call: call)),
               let type = declaredParamType(of: sym, call: call, argIndex: argIndex) {
                return ContextualType(name: type, scope: sym.scope)
            }
            // Disambiguation failed but we only need the parameter TYPE: if every label-matching
            // candidate agrees on the type at argIndex, that's the answer regardless of which
            // overload the compiler picks. This rescues a `.case` argument to a protocol method that
            // has both a requirement and a same-signature default impl (two indistinguishable cands)
            // — otherwise the shorthand stays un-renamed while the case is obfuscated → desync.
            if let agreed = agreedParamType(cands, call: call, argIndex: argIndex) {
                return ContextualType(name: agreed, scope: cands.first?.scope)
            }
            // `self.handler(.ok)` / `obj.handler(.ok)` — the member is a function-typed PROPERTY, not a
            // callable declaration, so it is absent from `cands`. Its input types come from
            // `valueClosureInput`, keyed by the property's own id (B-FIX-66).
            if let member = scope.members(named: methodName).first(where: { !Self.isCallable($0.kind) }),
               let ctx = closureValueInputType(of: member, at: argIndex) {
                return ctx
            }
            return nil
        }
        // `sinks[0](.alpha)` — the callee is a SUBSCRIPT whose element is a function type; the input at
        // `argIndex` types the shorthand (B-FIX-84, the input twin of the return in B-FIX-83). The
        // subscript resolves to no value Symbol, so `closureValueInputType` (keyed by Symbol) cannot see
        // it. Peel a trailing `?` on the callee (`sinks["k"]?(.alpha)`, a dictionary of closures).
        var subCalleeExpr = call.calledExpression
        if let opt = subCalleeExpr.as(OptionalChainingExprSyntax.self) { subCalleeExpr = opt.expression }
        if let subCallee = subCalleeExpr.as(SubscriptCallExprSyntax.self),
           let elem = typeResolver.subscriptResultTypeName(of: subCallee, in: currentScope),
           let inputs = TypeResolver.functionTypeInputNames(of: elem.name),
           argIndex < inputs.count, !inputs[argIndex].isEmpty {
            return ContextualType(name: stripBackticks(inputs[argIndex]), scope: elem.declScope)
        }
        return nil
    }

    /// The parameter TYPE at `argIndex` of a callee that is a VALUE of function type (a
    /// closure/function-typed parameter, local or property — `completion(.c2)` where
    /// `completion: (E1) -> Void`). Function types carry no argument labels, so the call's arguments
    /// are positional and `argIndex` maps directly to the input position. Handles a direct function
    /// type (`valueClosureInput`) and a `typealias` to one (`typealiasClosureInput`). The input name is
    /// written in the value's (or the alias's) declaring scope, so it is returned with that scope
    /// (B-FIX-23). Fail-closed: no recorded inputs, an out-of-range index, or an empty (unreducible)
    /// input name yields nil, so a shorthand stays un-renamed rather than typed to a guessed enum.
    /// B-FIX-66.
    private func closureValueInputType(of sym: Symbol, at argIndex: Int) -> ContextualType? {
        if let inputs = table.valueClosureInput[sym.id], argIndex < inputs.count, !inputs[argIndex].isEmpty {
            return ContextualType(name: inputs[argIndex], scope: sym.scope)
        }
        // `completion: Handler`, `typealias Handler = (E1) -> Void` — the written type is the alias
        // name (recorded in `declaredType`), whose inputs live in `typealiasClosureInput` (B-FIX-55).
        if let typeName = table.declaredType[sym.id],
           let aliasSym = typeResolver.typeSymbol(forQualifiedName: typeName, in: sym.scope ?? currentScope),
           let inputs = table.typealiasClosureInput[aliasSym.id], argIndex < inputs.count,
           !inputs[argIndex].isEmpty {
            return ContextualType(name: inputs[argIndex], scope: aliasSym.scope)
        }
        // `let f = makeHandler()` — f's function type comes from the callee's parsed return, so its
        // input at `argIndex` types a shorthand `f(.case)` (B-FIX-85, the input twin of the return
        // handled in `functionTypedValueReturn`).
        if let input = typeResolver.closureInputOfInitializerCall(of: sym, at: argIndex, in: currentScope) {
            return ContextualType(name: input.name, scope: input.scope)
        }
        return nil
    }

    /// Declared type of the associated value at `argIndex` of `enumSym`'s case `name` — the payload
    /// of a case constructor. nil when the case has no payload at that position or its type isn't a
    /// name we track (fail closed, as everywhere in contextual resolution).
    private func enumCaseAssociatedType(named name: String, in enumSym: Symbol,
                                        argIndex: Int) -> ContextualType? {
        guard let scope = innerScope(of: enumSym),
              let caseSym = scope.members(named: name).first(where: { $0.kind == .enumCase }),
              let types = table.enumCaseAssociatedTypes[caseSym.id],
              argIndex < types.count, let type = types[argIndex] else { return nil }
        return ContextualType(name: type, scope: caseSym.scope)
    }

    /// The TYPE that a `Name(...)` callee constructs, or nil when `Name` names no type we know.
    /// `Self(...)` constructs the enclosing type. A typealias is followed to its underlying type
    /// (its initializers live there).
    private func constructedType(named name: String) -> Symbol? {
        if name == "Self" || name == "self" { return enclosingTypeScope()?.owner }
        if let s = currentScope.lookup(name: name), s.kind.isTypeLike { return typealiasUnwrap(s) }
        if let s = lookupType(named: name) { return typealiasUnwrap(s) }
        return nil
    }

    /// Declared type of the parameter at `argIndex` of the initializer `call` selects on `typeSym`:
    /// an explicit `init` picked by argument labels (extension inits included — they are real
    /// initializers), or, for a struct that declares NO init in its primary declaration, the
    /// compiler-synthesized MEMBERWISE init, whose labels are the stored property names and whose
    /// types are their declared types.
    ///
    /// Fail-closed at every step: several label-matching inits that disagree on the type, an unknown
    /// or external type, a class/enum without a matching init, an argument with no label on the
    /// memberwise path — all yield nil. Inventing a context here would rewrite `.case` to ANOTHER
    /// enum's obf, a wrong rename RollbackPass cannot catch (no original name survives).
    private func initializerParamType(ofType typeSym: Symbol,
                                      call: FunctionCallExprSyntax,
                                      argIndex: Int) -> ContextualType? {
        guard let typeScope = innerScope(of: typeSym) else { return nil }
        let inits = typeScope.members(named: "init").filter { $0.kind == .initializer }
        if !inits.isEmpty {
            let callLabels = Self.argumentLabels(of: call)
            let matching = inits.filter { labelsMatch($0, callLabels, trailingStart: ArgumentLabelMatch.trailingStart(of: call)) }
            if matching.count == 1, let type = declaredParamType(of: matching[0], call: call, argIndex: argIndex) {
                return ContextualType(name: type, scope: matching[0].scope)
            }
            if matching.count > 1, let agreed = agreedParamType(matching, call: call, argIndex: argIndex) {
                return ContextualType(name: agreed, scope: matching[0].scope)
            }
            // Explicit inits exist and one of them matched the labels: the memberwise init is either
            // suppressed or irrelevant, and we could not name the type — stop rather than guess.
            if !matching.isEmpty { return nil }
        }
        // Memberwise init. Only a struct whose PRIMARY declaration has no explicit init gets one
        // (an extension init does not suppress it — B-FIX-19 discipline, same side-table).
        guard typeSym.kind == .struct, !table.structsWithMainDeclInit.contains(typeSym.id),
              let label = Self.argumentLabel(of: call, at: argIndex) else { return nil }
        guard let property = typeScope.symbols.first(where: {
            $0.kind == .property && $0.name == label && table.storedPropertyIds.contains($0.id)
        }), let type = table.declaredType[property.id] else { return nil }
        return ContextualType(name: type, scope: property.scope)
    }

    /// Call-site label of the argument at `index` ("_"-style positional arguments have none).
    private static func argumentLabel(of call: FunctionCallExprSyntax, at index: Int) -> String? {
        guard index < call.arguments.count else { return nil }
        let arg = call.arguments[call.arguments.index(call.arguments.startIndex, offsetBy: index)]
        return arg.label.map { TypeResolver.stripBackticks($0.text) }
    }

    /// The parameter type at `argIndex` when ALL label-matching candidates agree on it (else nil).
    private func agreedParamType(_ candidates: [Symbol], call: FunctionCallExprSyntax, argIndex: Int) -> String? {
        let callLabels = Self.argumentLabels(of: call)
        let matching = candidates.filter { labelsMatch($0, callLabels, trailingStart: ArgumentLabelMatch.trailingStart(of: call)) }
        guard !matching.isEmpty else { return nil }
        let types = matching.compactMap { declaredParamType(of: $0, call: call, argIndex: argIndex) }
        guard types.count == matching.count, let first = types.first,
              types.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    /// Declared type of the parameter that the call's argument at `argIndex` actually BINDS on
    /// `sym`. The argument's own ordinal is not that parameter's index once the call omits a
    /// defaulted parameter, so the position comes from the shared label-matching walk (B-FIX-36).
    /// Falls back to the ordinal when the walk finds no match, which keeps the old behaviour for
    /// shapes the label model cannot express (variadics).
    private func declaredParamType(of sym: Symbol, call: FunctionCallExprSyntax, argIndex: Int) -> String? {
        guard let types = table.functionParamTypes[sym.id] else { return nil }
        let pi = ArgumentLabelMatch.parameterIndex(ofArgument: argIndex, for: sym, call: call, in: table) ?? argIndex
        guard pi < types.count else { return nil }
        return types[pi]
    }

    // MARK: - Helpers

    /// Inner scope of a type symbol — automatically follows typealiases to the underlying type's
    /// scope. A typealias has no inner scope of its own; its "members" ARE the members of its
    /// underlying type, and every caller wanting `.member` access expects that semantics. Without
    /// this canonicalization, anywhere we did `innerScope(of: someTypeAlias)` got nil and skipped
    /// the member rename — the same desync bug appearing one site at a time across the codebase.
    private func innerScope(of typeSym: Symbol) -> Scope? {
        let canonical = typealiasUnwrap(typeSym)
        guard let parent = canonical.scope else { return nil }
        for child in parent.children where child.owner?.id == canonical.id {
            return child
        }
        return nil
    }

}

