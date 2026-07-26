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

    public init(
        table: SymbolTable,
        protector: Protector,
        pool: NamePool,
        logger: Logger,
        ignoreNames: Set<String> = [],
        allowedKinds: Set<SymbolKind> = [],
        usrBySymbolId: [Int: String]? = nil
    ) {
        self.table = table
        self.protector = protector
        self.pool = pool
        self.logger = logger
        self.ignoreNames = ignoreNames
        self.allowedKinds = allowedKinds
        self.usrBySymbolId = usrBySymbolId
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
            if isExtensionOfExternalType(sym) {
                skipReason[sym.id] = "member of an extension on an external (non-local) type"
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
    /// extension on a non-local type (`extension Array where ...`). Renaming such members
    /// breaks use-sites because we cannot resolve `someArray.member` syntactically.
    private func isExtensionOfExternalType(_ sym: Symbol) -> Bool {
        guard let scope = sym.scope, scope.kind == .type, scope.owner == nil else { return false }
        return true
    }
}
