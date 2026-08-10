import Foundation

public struct PipelineOptions {
    public var modules: [ModuleSpec]
    public var outputDirectory: URL
    public var dryRun: Bool
    public var nameStyle: NamePool.Style
    public var sdkName: String
    public var sdkPath: String?
    public var introspectSDK: Bool
    public var sdkModuleFilter: [String]

    // MARK: - User-defined ignore lists (SwiftShield-compatible)

    /// Symbol names that must never be renamed, regardless of any other rule.
    public var ignoreNames: Set<String>
    /// File-path fragments. A file is excluded from input if its absolute path contains any
    /// of these fragments. Simple substring match — not glob — keeps the contract obvious.
    public var ignoreFiles: [String]
    /// Module/target names to skip entirely (their files aren't loaded and their decls don't
    /// enter the SymbolTable). Useful to avoid heavy generated code or test targets.
    public var ignoreTargets: Set<String>

    // MARK: - SPM / DerivedData multi-module support

    /// When set, SwiftProf walks `~/Library/Developer/Xcode/DerivedData/<projectName>-*/
    /// SourcePackages/checkouts/*/Sources/*/` and adds each package as a read-only module.
    /// Their declarations enter the SymbolTable (so cross-module conformance resolves) but
    /// their files are never rewritten.
    public var autoDiscoverSPMForProject: String?
    /// Explicit DerivedData root override. Defaults to `~/Library/Developer/Xcode/DerivedData`.
    public var derivedDataPath: String?

    /// When true (default), runs RollbackPass after Rewriter to revert any rename whose original
    /// name still appears in the rewritten output (i.e., a use-site was missed). Trades a tiny
    /// bit of coverage for a guaranteed-compileable build.
    public var rollbackEnabled: Bool

    /// Symbol kinds that are ALLOWED to be obfuscated. Empty = all kinds. Used for iterative
    /// testing — e.g. obfuscate only `.class,.struct,.enum` to bisect which kind breaks a build.
    public var obfuscatableKinds: Set<SymbolKind>

    /// Raw-value obfuscation mode. When not `.off`, a preprocessing pass (before the main
    /// rename) obfuscates String-enum raw values, adds a `displayName` holding the originals, and
    /// rewrites resolvable `.rawValue` use-sites to `.displayName`. Default `.off`.
    public var rawValueMode: RawValueMode

    /// When true, ResolutionPass emits ANONYMIZED `OVLD …` diagnostics for every overloaded call
    /// resolution (original identifiers hashed; only structure/kinds/scores logged). For debugging
    /// why a call did/didn't resolve to the expected overload, on NDA code. Default false.
    public var diagnoseOverloads: Bool

    /// Green-build-first mode: pre-emptively skip obfuscating any function/method whose name has
    /// MORE than one callable in the project. The most common source of overload desync (wrong
    /// pick → `Type X has no member …`) — refusing to rename those at all eliminates the risk at
    /// the cost of obfuscating less. Default false (the resolver + smart rollback are tried first).
    public var skipOverloadedCallables: Bool

    /// More aggressive rollback safety net: disables the `un-renamed-namesake-shields-a-name`
    /// protection for ANY name with a renamed callable namesake (not just when the un-renamed
    /// sym itself is callable). A surviving occurrence of such a name → revert the whole group.
    /// Trades extra coverage loss for stronger green-build guarantee on overload-heavy projects.
    public var aggressiveRollback: Bool

    /// A7: index-store path — the SWITCH for the libIndexStore (USR ground-truth) layer. nil
    /// (default) ⇒ behaviour is exactly the syntactic baseline (all index-free tests stay green).
    /// When set (e.g. DerivedData `Index.noindex/DataStore`, or a dir produced by `swiftc
    /// -index-store-path`), the pipeline loads the index there, uses USRs to break same-named
    /// cross-target ties (A4) and to validate renames (A6). Fail-closed: a missing/stale index
    /// aborts with a clear error rather than guessing.
    public var indexStorePath: String?
    /// A5 gate, opt-in SEPARATELY from the index layer. Default false: the index gives A4 (tiebreak)
    /// + A6 (validator) — correctness/safety — WITHOUT skipping every symbol that fails to map to a
    /// USR. On real code that mapping is lossy, so gating on it craters coverage for no safety gain
    /// (A6 already catches a genuine wrong rename). Turn on only when you want the strictest
    /// "rename nothing the index can't vouch for" posture.
    public var indexStoreGate: Bool

    /// Emit a per-symbol decision report (`Decisions.txt` + `decisions.json` in `--output`): for
    /// every writable declaration, exactly why it was obfuscated / protected / skipped / reverted.
    /// Off by default (extra work + a large file on big projects). See `DecisionReport`.
    public var explain: Bool

    /// Rewrite a member access by NAME when that name is a PROJECT-UNIQUE member of an external-type
    /// extension whose receiver cannot be typed — the SwiftUI `extension View { func frostBound() }`
    /// modifier idiom, whose use-sites sit on `some View` chains no syntactic resolver can type
    /// (B-FIX-31). Default ON: without it those declarations rename, every use-site survives and
    /// RollbackPass reverts the group, so the members stay readable. Turn OFF (`--no-unique-external
    /// -members`) to bisect a red build back to this heuristic.
    public var uniqueExternalMembers: Bool

    /// How much Objective-C runtime name sensitivity the Protector assumes. `.strict` (default) is
    /// the historical behaviour: every descendant of an ObjC root class keeps all its members.
    /// `.relaxed` narrows that to DECLARED exposure (annotations, selectors, Core Data), which is
    /// the main coverage lever on a UIKit project; `.off` drops ObjC protections entirely.
    /// Non-ObjC protections (Codable keys, property wrappers, conformances) never answer to this.
    public var objcProtection: ObjCProtectionMode

    public init(
        modules: [ModuleSpec],
        outputDirectory: URL,
        dryRun: Bool,
        nameStyle: NamePool.Style = .random,
        sdkName: String = "iphonesimulator",
        sdkPath: String? = nil,
        introspectSDK: Bool = true,
        sdkModuleFilter: [String] = [],
        ignoreNames: Set<String> = [],
        ignoreFiles: [String] = [],
        ignoreTargets: Set<String> = [],
        autoDiscoverSPMForProject: String? = nil,
        derivedDataPath: String? = nil,
        rollbackEnabled: Bool = true,
        obfuscatableKinds: Set<SymbolKind> = [],
        rawValueMode: RawValueMode = .off,
        diagnoseOverloads: Bool = false,
        skipOverloadedCallables: Bool = false,
        aggressiveRollback: Bool = false,
        indexStorePath: String? = nil,
        indexStoreGate: Bool = false,
        explain: Bool = false,
        uniqueExternalMembers: Bool = true,
        objcProtection: ObjCProtectionMode = .strict
    ) {
        self.modules = modules
        self.outputDirectory = outputDirectory
        self.dryRun = dryRun
        self.nameStyle = nameStyle
        self.sdkName = sdkName
        self.sdkPath = sdkPath
        self.introspectSDK = introspectSDK
        self.sdkModuleFilter = sdkModuleFilter
        self.ignoreNames = ignoreNames
        self.ignoreFiles = ignoreFiles
        self.ignoreTargets = ignoreTargets
        self.autoDiscoverSPMForProject = autoDiscoverSPMForProject
        self.derivedDataPath = derivedDataPath
        self.rollbackEnabled = rollbackEnabled
        self.obfuscatableKinds = obfuscatableKinds
        self.rawValueMode = rawValueMode
        self.diagnoseOverloads = diagnoseOverloads
        self.skipOverloadedCallables = skipOverloadedCallables
        self.aggressiveRollback = aggressiveRollback
        self.indexStorePath = indexStorePath
        self.indexStoreGate = indexStoreGate
        self.explain = explain
        self.uniqueExternalMembers = uniqueExternalMembers
        self.objcProtection = objcProtection
    }
}

/// Default set of stdlib / SwiftUI / Foundation / Combine interfaces we want to load for
/// iOS app obfuscation. Other modules can be added by the user via `sdkModuleFilter`.
/// Smaller subset = faster startup; comprehensive set = better protocol coverage AND
/// fewer rollback false-positives (Apple's public API names shield same-named locals).
let defaultSDKModulesForIOS: Set<String> = [
    // Core language + Foundation
    "Swift", "Foundation", "Combine", "Observation", "_Concurrency", "_StringProcessing",
    // SwiftUI stack
    "SwiftUI", "SwiftUICore", "DeveloperToolsSupport",
    // UIKit family
    "UIKit", "UIKitCore",
    // Common media / picker frameworks
    "AVFoundation", "AVKit", "PhotosUI", "Photos",
    // Maps / location / device
    "MapKit", "CoreLocation", "CoreMotion",
    // Persistence / data
    "CoreData", "CoreGraphics", "CoreFoundation", "CoreImage", "CoreText",
    // Network / web
    "Network", "WebKit", "SafariServices",
    // Animation / drawing
    "QuartzCore", "Metal",
    // Logging
    "OSLog", "os",
    // Misc commonly imported
    "Contacts", "EventKit", "EventKitUI", "MessageUI", "StoreKit",
    "UserNotifications", "Intents", "Speech",
]

public struct PipelineResult {
    public let project: LoadedProject
    public let table: SymbolTable
    public let renameMap: RenameMap
    public let renames: [Rename]
    public let coverage: CoverageReport
    /// Per-use-site decision records. Empty unless `--explain` was on.
    public let useSites: [UseSiteRecord]
}

public enum PipelineError: Error, CustomStringConvertible {
    case noWritableFiles(modules: [String])

    public var description: String {
        switch self {
        case .noWritableFiles(let modules):
            return """
                No writable .swift files found in any --module path. \
                Check that your paths exist and contain Swift sources.
                Configured writable modules: \(modules.joined(separator: ", "))
                """
        }
    }
}

public final class Pipeline {
    public let options: PipelineOptions
    public let logger: Logger

    public init(options: PipelineOptions, logger: Logger) {
        self.options = options
        self.logger = logger
    }

    @discardableResult
    public func run() throws -> PipelineResult {
        // Augment modules with auto-discovered SPM packages if requested.
        var allModules = options.modules
        if let projectName = options.autoDiscoverSPMForProject {
            let discovered = SPMDiscovery.findPackages(
                projectName: projectName,
                derivedDataPath: options.derivedDataPath,
                logger: logger
            )
            allModules.append(contentsOf: discovered)
        }

        let loader = ProjectLoader(
            logger: logger,
            ignoreTargets: options.ignoreTargets,
            ignoreFiles: options.ignoreFiles
        )
        let project = try loader.load(specs: allModules)
        logger.log("loaded \(project.files.count) files across \(project.modules.count) modules")

        let writableFiles = project.files.filter { $0.module.writable }
        if writableFiles.isEmpty {
            let writableModuleNames = project.modules.filter { $0.writable }.map { "\($0.name) (\($0.root.path))" }
            throw PipelineError.noWritableFiles(modules: writableModuleNames)
        }

        // 1. Build the stdlib registry: parse SDK interfaces, fall back to hardcoded if disabled.
        let registry = StdlibRegistry()
        registry.seedWithHardcoded()
        if options.introspectSDK {
            do {
                let locator = SDKLocator(logger: logger)
                let paths = try locator.locate(sdkName: options.sdkName, explicitSDKPath: options.sdkPath)
                // Load the curated default set ∪ user-specified ∪ EVERY framework the project
                // actually imports. The last term is the coverage lever: a conformer to e.g.
                // `QLPreviewControllerDataSource` only gets surgical protection (its two real
                // requirements) instead of unknown→protect-all once QuickLook's interface is loaded.
                // Only modules that exist as a `.swiftinterface` in the SDK match; bogus/SPM imports
                // are harmlessly ignored. (`--sdk-modules` is ADDITIVE now, not a replace.)
                let importedModules = ImportCollector.modules(in: project.files)
                let filter: Set<String> = defaultSDKModulesForIOS
                    .union(options.sdkModuleFilter)
                    .union(importedModules)
                let selected = paths.interfaces.filter { filter.contains($0.module) }
                let cache = InterfaceCache(logger: logger)
                let cacheKey = cache.cacheKey(
                    sdkRoot: paths.sdkRoot,
                    arch: paths.arch,
                    files: selected.map { $0.url }
                )
                let loaded: [LoadedInterface]
                if let cached = cache.load(key: cacheKey) {
                    loaded = cached
                } else {
                    let ifaceLoader = SwiftInterfaceLoader(logger: logger)
                    var parsed: [LoadedInterface] = []
                    for (module, url) in selected {
                        if let result = ifaceLoader.load(url, moduleName: module) {
                            parsed.append(result)
                            logger.log("interface \(module): \(result.protocols.count) protocols", verbose: true)
                        }
                    }
                    cache.store(parsed, key: cacheKey)
                    loaded = parsed
                }
                registry.merge(loaded)
                logger.log("stdlib registry: \(registry.totalProtocols) protocols from \(loaded.count) modules (\(importedModules.count) project imports folded into the load set)")
            } catch {
                logger.log("SDK introspection failed (\(error)) — using hardcoded registry only")
            }
        }

        // 0. Raw-value obfuscation preprocessing (opt-in). Runs on the original source with its
        // own throwaway symbol table, rewrites files in place; the main pipeline below re-parses
        // the transformed contents as ordinary input.
        if options.rawValueMode != .off {
            let pre = SymbolTable()
            DeclarationPass(table: pre, logger: logger).run(on: project.files)
            ExtensionOwnerResolver(table: pre, logger: logger).run()
            ScopeUnification(table: pre, logger: logger).run()
            TypeInferencePass(table: pre, logger: logger).run()
            RawValueObfuscationPass(
                table: pre, mode: options.rawValueMode,
                debugNames: options.nameStyle == .debug, logger: logger
            ).run(on: project.files)
        }

        let table = SymbolTable()
        DeclarationPass(table: table, logger: logger).run(on: project.files)
        logger.log("declarations: \(table.symbols.count)")

        ExtensionOwnerResolver(table: table, logger: logger).run()
        // Extension owners are now resolved — fold subscript signatures onto their owner types so
        // `base[args]` on a local type can resolve to a subscript's declared return type.
        table.finalizeSubscriptSignatures()
        // Extensions whose owner did NOT resolve are extensions on EXTERNAL types. Their members are
        // renameable via receiver-type matching (B-FIX-31) — collect them before ScopeUnification,
        // which rewires only OWNED extension scopes.
        table.finalizeExternalExtensions()
        ScopeUnification(table: table, logger: logger).run()
        ConformanceVisibility(table: table, logger: logger).run()
        SuperclassVisibility(table: table, logger: logger).run()
        TypeInferencePass(table: table, logger: logger).run()

        // A2/A3/A7: load the compiler index (fail-closed) and build the Symbol→USR map. The
        // index-store PATH is the switch: nil (default) ⇒ indexContext stays nil and everything
        // below is the syntactic baseline.
        var indexContext: IndexContext? = nil
        if let indexStorePath = options.indexStorePath {
            let writablePaths = project.files.filter { $0.module.writable }.map { $0.url.path }
            let provider = IndexStoreProvider(logger: logger)
            let index = try provider.loadIndex(indexStorePath: indexStorePath,
                                               writableFilePaths: writablePaths)
            let usrBySymbolId = index.usrBySymbol(in: table)
            logger.log("index store: mapped \(usrBySymbolId.count)/\(table.symbols.count) symbols to USRs")
            indexContext = IndexContext(usrIndex: index, usrBySymbolId: usrBySymbolId)
        }

        let protector = Protector(table: table, stdlibRegistry: registry, logger: logger,
                                  objcProtection: options.objcProtection)
        protector.run(on: project.files)
        KeyPathProtector(table: table, protector: protector, logger: logger).run(on: project.files)
        logger.log("protected: \(protector.reasonForId.count)")

        let pool = NamePool(style: options.nameStyle)
        // Aggressive ignore: pre-emptively exclude every callable name that has >1 callable in
        // the project. Eliminates overload-desync risk entirely (no rename → no possible miss).
        var effectiveIgnoreNames = options.ignoreNames
        if options.skipOverloadedCallables {
            var counts: [String: Int] = [:]
            for sym in table.symbols where sym.kind == .function || sym.kind == .method {
                counts[sym.name, default: 0] += 1
            }
            var added = 0
            for (name, c) in counts where c > 1 {
                if effectiveIgnoreNames.insert(name).inserted { added += 1 }
            }
            if added > 0 {
                logger.log("skipOverloadedCallables: \(added) overloaded callable names ignored")
            }
        }
        // A5 gate is opt-in (`--index-store-gate`) and OFF by default: on real projects the
        // Symbol→USR map is incomplete (partial index / unindexed modules), and gating on it
        // craters coverage for no safety gain — A4 (tiebreak) + A6 (validator) already provide the
        // correctness. Only pass the map to the Planner when the strict gate is explicitly enabled.
        let gateUSRMap = options.indexStoreGate ? indexContext?.usrBySymbolId : nil
        let planner = Planner(
            table: table, protector: protector, pool: pool, logger: logger,
            ignoreNames: effectiveIgnoreNames,
            allowedKinds: options.obfuscatableKinds,
            usrBySymbolId: gateUSRMap,
            apiNames: registry.allKnownMemberNames
        )
        let map = planner.plan()
        logger.log("planned renames: \(map.obfBySymbolId.count)")

        WitnessLinker(table: table, protector: protector, logger: logger).link(map: map)
        logger.log("after witness linking: \(map.obfBySymbolId.count)")

        // Unify each `override` member with the base it overrides (after witness linking, so a base
        // that is also a protocol witness is already pinned and the chain adopts the same obf).
        OverrideLinker(table: table, protector: protector, logger: logger).link(map: map)
        logger.log("after override linking: \(map.obfBySymbolId.count)")

        AmbiguityRollback(table: table, logger: logger).run(map: map, files: project.files)
        logger.log("after ambiguity rollback: \(map.obfBySymbolId.count)")

        // Diagnostics go to a FILE, not the console: they are grepped after the run and can be
        // thousands of lines, which would bury the progress output they are mixed into.
        let diagnostics: DiagnosticsLog? = options.diagnoseOverloads ? DiagnosticsLog() : nil
        let useSiteLog: UseSiteLog? = options.explain ? UseSiteLog() : nil
        var renames = ResolutionPass(table: table, map: map, logger: logger,
                                     diagnoseOverloads: options.diagnoseOverloads,
                                     diagnostics: diagnostics,
                                     indexContext: indexContext,
                                     uniqueExternalMembers: options.uniqueExternalMembers,
                                     useSiteLog: useSiteLog).run(on: project.files)
        logger.log("rename edits: \(renames.count)")

        // A6: validate every edit against the compiler's occurrence set; drop renames the index
        // contradicts (cross-target wrong-rename → would compile-break) before they reach disk.
        if let ctx = indexContext {
            let bad = IndexValidator(table: table, usrIndex: ctx.usrIndex,
                                     usrBySymbolId: ctx.usrBySymbolId, logger: logger)
                .findDesyncs(in: renames)
            if !bad.isEmpty {
                renames = renames.filter { !bad.contains($0.targetSymbolId) }
                for id in bad { map.revert(id, reason: "A6 index validator — edit attributed to a different module") }
                logger.log("A6 validator: reverted \(bad.count) symbol(s) whose edits the index contradicted")
            }
        }

        let rewriter = Rewriter(logger: logger)
        rewriter.apply(renames)

        // Safety net: revert any rename whose original name still appears in writable output.
        if options.rollbackEnabled {
            let rolledBack = RollbackPass(
                table: table, map: map, stdlibRegistry: registry, logger: logger,
                aggressive: options.aggressiveRollback, diagnose: options.diagnoseOverloads,
                diagnostics: diagnostics
            ).run(on: project.files)
            if rolledBack > 0 {
                logger.log("rollback: \(rolledBack) names reverted")
            }
        }

        if !options.dryRun {
            try rewriter.writeToDisk(project.files)
            logger.log("wrote \(project.files.filter { $0.module.writable }.count) files")
        }

        try FileManager.default.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)
        let conversion = ConversionMap(table: table, map: map)
        try conversion.write(to: options.outputDirectory.appendingPathComponent("ConversionMap.json"))
        let coverage = CoverageReport(table: table, map: map, protector: protector)
        try coverage.write(to: options.outputDirectory.appendingPathComponent("CoverageReport.txt"))

        if let diagnostics, !diagnostics.isEmpty {
            let written = try diagnostics.write(toDirectory: options.outputDirectory)
            logger.log("wrote \(written.diagnostics) diagnostic lines to "
                       + "\(options.outputDirectory.appendingPathComponent("Diagnostics.txt").path)"
                       + " (--diagnose-overloads)")
        }

        if options.explain {
            let decisions = DecisionReport(table: table, map: map, protector: protector,
                                           plannerSkip: planner.skipReason)
            try decisions.writeText(to: options.outputDirectory.appendingPathComponent("Decisions.txt"))
            try decisions.writeJSON(to: options.outputDirectory.appendingPathComponent("decisions.json"))
            logger.log("wrote per-symbol decisions for \(decisions.byFile.count) files (--explain)")
        }

        return PipelineResult(project: project, table: table, renameMap: map,
                              renames: renames, coverage: coverage,
                              useSites: useSiteLog?.records ?? [])
    }
}
