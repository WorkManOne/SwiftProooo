import Foundation

/// Decides which symbols get obfuscated and assigns names. MVP rules:
/// - Skip symbols flagged by Protector.
/// - Skip parameters (label/internal-name handling deferred — keeps API stable).
/// - Skip read-only modules (we never rewrite them; renaming their decls would orphan refs).
/// - Skip `init` initializer symbol (keyword, not a rename target).
public final class Planner {
    public let table: SymbolTable
    public let protector: Protector
    public let pool: NamePool
    public let logger: Logger
    /// User-provided allowlist: any symbol whose name is in this set is never renamed.
    public let ignoreNames: Set<String>
    /// If non-empty, only these symbol kinds are obfuscated (for iterative testing).
    public let allowedKinds: Set<SymbolKind>
    /// A5 gate: when non-nil (index active), Symbol.id → USR. A writable-module symbol absent
    /// from this map is one the index can't vouch for ⇒ skip its rename (fail-closed). nil ⇒
    /// gate disabled (syntactic baseline).
    public let usrBySymbolId: [Int: String]?
    /// Apple/stdlib API member names (`StdlibRegistry.allKnownMemberNames`) — RollbackPass shield
    /// 1c. A member of an EXTERNAL-type extension carrying one of these names is not renamed: its
    /// use-sites are matched by the receiver's written type, so a miss is likelier than for a local
    /// type, and the shield would block the rollback rescue — the desync would SHIP (B-FIX-31).
    public let apiNames: Set<String>

    public init(
        table: SymbolTable,
        protector: Protector,
        pool: NamePool,
        logger: Logger,
        ignoreNames: Set<String> = [],
        allowedKinds: Set<SymbolKind> = [],
        usrBySymbolId: [Int: String]? = nil,
        apiNames: Set<String> = []
    ) {
        self.table = table
        self.protector = protector
        self.pool = pool
        self.logger = logger
        self.ignoreNames = ignoreNames
        self.allowedKinds = allowedKinds
        self.usrBySymbolId = usrBySymbolId
        self.apiNames = apiNames
    }

    /// id → why a writable symbol was NOT planned (specific policy reason). Protected symbols are
    /// owned by Protector (not recorded here). Feeds the per-symbol decision report (`--explain`).
    public private(set) var skipReason: [Int: String] = [:]

    public func plan() -> RenameMap {
        let map = RenameMap()
        var ignoredCount = 0
        var gatedCount = 0
        for sym in table.symbols {
            if protector.isProtected(sym) { continue }   // Protector owns the reason
            if !sym.module.writable {
                skipReason[sym.id] = "read-only module (\(sym.module.name)) — never rewritten"
                continue
            }
            // A5 gate: a writable-module symbol with no USR means the index can't vouch for it —
            // renaming would be a guess, so skip (under-obfuscate) rather than risk a wrong rename.
            if let usrMap = usrBySymbolId, usrMap[sym.id] == nil {
                gatedCount += 1
                skipReason[sym.id] = "index gate (A5) — symbol has no USR in the index store"
                continue
            }
            if table.genericParameterIds.contains(sym.id) {
                skipReason[sym.id] = "generic parameter placeholder (local, not a rename target)"
                continue
            }
            if isExtensionOfExternalType(sym), let reason = externalExtensionSkipReason(sym) {
                skipReason[sym.id] = reason
                continue
            }
            if !allowedKinds.isEmpty && !allowedKinds.contains(sym.kind) {
                skipReason[sym.id] = "kind '\(sym.kind.rawValue)' not in --kinds"
                continue
            }
            if ignoreNames.contains(sym.name) {
                ignoredCount += 1
                skipReason[sym.id] = "name in --ignore-names (or skip-overloaded-callables)"
                continue
            }
            switch sym.kind {
            case .initializer:
                skipReason[sym.id] = "initializer (the `init` keyword is not a rename target)"
                continue
            case .parameter:
                // Function/method/init parameters: rename only when the call-site signature is
                // unaffected. That means the parameter must have a distinct external label
                // (forms `_ name` / `label name`), tracked at DeclarationPass time.
                if !table.renameableParameters.contains(sym.id) {
                    skipReason[sym.id] = "parameter without a distinct external label (renaming would change the call site)"
                    continue
                }
            default:
                break
            }
            map.assign(sym, to: pool.mint(for: sym.kind))
        }
        if ignoredCount > 0 {
            logger.log("Planner: \(ignoredCount) symbols ignored by --ignore-names")
        }
        if gatedCount > 0 {
            logger.log("Planner: \(gatedCount) writable symbols gated (no USR — A5 fail-closed)")
        }
        return map
    }

    /// True if the symbol is declared inside a type-scope whose owner is unknown — i.e. an
    /// extension on a non-local type (`extension String`, `extension Array where Element == …`).
    private func isExtensionOfExternalType(_ sym: Symbol) -> Bool {
        guard let scope = sym.scope, scope.kind == .type, scope.owner == nil else { return false }
        return true
    }

    /// Why a member of an external-type extension may NOT be renamed — nil means it MAY (B-FIX-31).
    ///
    /// Such a member has no owning Symbol, so its use-sites are matched by the receiver's WRITTEN
    /// type (`ResolutionVisitor.resolveExternalExtensionMember`). That works for a receiver we can
    /// type and fails closed for one we cannot: the original name survives and RollbackPass reverts
    /// the group. The exceptions below are the cases where that safety net does NOT hold, or where
    /// there is no matching machinery at all:
    ///   - the extension family declares a conformance ⇒ the member is a witness on a type we don't
    ///     own (handled upstream: such extensions never enter `externalExtensions`);
    ///   - the name is an Apple/stdlib API name ⇒ RollbackPass shield 1c blocks the revert, so a
    ///     missed use-site would ship as a red build;
    ///   - the kind is not a property/method ⇒ no receiver-matched use-site form to rewrite.
    private func externalExtensionSkipReason(_ sym: Symbol) -> String? {
        guard let scope = sym.scope, table.isExternalExtensionScope(scope) else {
            return "member of an extension on an external (non-local) type"
        }
        switch sym.kind {
        case .property, .method: break
        default: return "member of an extension on an external type (kind '\(sym.kind.rawValue)' has no receiver-matched use-site)"
        }
        if apiNames.contains(sym.name) {
            return "member of an extension on an external type whose name is an Apple/stdlib API name (rollback shield would block the rescue)"
        }
        return nil
    }
}
