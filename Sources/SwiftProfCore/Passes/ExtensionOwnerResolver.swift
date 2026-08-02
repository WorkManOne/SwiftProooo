import Foundation
import SwiftSyntax

/// Resolves the owner type of every `extension` scope, after the full SymbolTable is built.
///
/// DeclarationPass intentionally leaves extension owners nil: during that pass the table is only
/// partially populated and picking `table.types(named:).first` is registration-order-dependent —
/// it can attach an extension to a foreign module's same-named type, after which ScopeUnification
/// merges unrelated members into the extension's lookup scope (a root cause of wrong renames).
///
/// This pass resolves each owner with the SAME semantics used for type references at use-sites
/// (`TypeResolver`, module-aware): the extension binds to the type a same-module reference to that
/// name would resolve to. Consistency between extension-owner and reference resolution is the
/// point — it removes the desync that produced `<wrongObf>.member`.
///
/// When the owner cannot be resolved (extends an SDK / read-only type, or an unknown name), the
/// owner is left nil and ScopeUnification simply skips that extension — safe, no cross-wiring.
public final class ExtensionOwnerResolver {
    public let table: SymbolTable
    public let logger: Logger

    public init(table: SymbolTable, logger: Logger) {
        self.table = table
        self.logger = logger
    }

    public func run() {
        var resolved = 0
        for ext in table.extensionRefs {
            guard let fileScope = table.fileScopes[ObjectIdentifier(ext.file)] else { continue }
            let resolver = TypeResolver(table: table, preferredModule: ext.file.module.name)
            let name = ext.extendedType.trimmedDescription
            if let owner = resolver.typeSymbol(forQualifiedName: name, in: fileScope) {
                ext.scope.owner = owner
                resolved += 1
            } else {
                ext.scope.owner = nil
            }
        }
        // Owners are final now, so the owner-keyed conformance index can be built. Every consumer of
        // `SymbolTable.conformanceNames` runs after this pass; building it here means no caller has
        // to know when the answer became stable.
        table.indexExtensionConformances()
        logger.log("extension owners resolved: \(resolved)/\(table.extensionRefs.count)", verbose: true)
    }
}
