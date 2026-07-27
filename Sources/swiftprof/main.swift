import ArgumentParser
import Foundation
import SwiftProfCore

struct SwiftProfCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swiftprof",
        abstract: "Swift identifier obfuscator (SwiftSyntax-based).",
        subcommands: [Obfuscate.self],
        defaultSubcommand: Obfuscate.self
    )
}

// Every option/flag is Optional so "not passed" is distinguishable from "default passed":
// per-field precedence is CLI > swiftprof.yaml > built-in default (applied after the merge
// in run()). Flags use `.prefixedNo` inversion, so each boolean also gets an explicit
// off-switch (`--no-debug-names`) that can override a config-file `true`.
struct Obfuscate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "obfuscate",
        abstract: "Obfuscate identifiers in a Swift project.",
        discussion: """
        Project-shaped settings can live in a swiftprof.yaml next to the project (auto-discovered \
        in the current directory, or passed via --config). Config keys mirror the flag names \
        (kebab-case, no --); comma-separated flags become YAML lists; module/readonly are lists \
        of the same name:path strings. Relative paths in the file resolve against the file's \
        directory. CLI flags override config values. Unknown keys are a hard error (typo guard).
        """
    )

    @Option(name: .long, help: "Path to a swiftprof.yaml. Without it, swiftprof.yaml / swiftprof.yml in the current directory is auto-discovered (no file = pure-CLI run, as before).")
    var config: String?

    @Option(name: .long, help: "name:path of a writable module. Repeatable.")
    var module: [String] = []

    @Option(name: .long, help: "name:path of a read-only module (e.g. DerivedData package). Repeatable.")
    var readonly: [String] = []

    @Option(name: .long, help: "Output directory for ConversionMap.json + CoverageReport.txt. Default: ./out")
    var output: String?

    @Flag(name: .long, inversion: .prefixedNo, help: "Don't write source files; only emit reports.")
    var dryRun: Bool?

    @Flag(name: .long, inversion: .prefixedNo, help: "Use short readable names (T0, m0, p0) instead of random 32-char tokens. For inspection/debugging only.")
    var debugNames: Bool?

    @Option(name: .long, help: "SDK name for introspection (iphonesimulator/iphoneos/macosx). Default: iphonesimulator.")
    var sdk: String?

    @Option(name: .long, help: "Explicit SDK root. Overrides xcrun lookup.")
    var sdkPath: String?

    @Flag(name: .long, inversion: .prefixedNo, help: "SDK .swiftinterface introspection (default: on). --no-sdk-introspect uses only the hardcoded fallback registry.")
    var sdkIntrospect: Bool?

    @Option(name: .long, help: "Comma-separated SDK module names to introspect IN ADDITION to the default set and the project's auto-detected imports.")
    var sdkModules: String?

    @Option(name: .long, help: "Comma-separated names that must never be renamed.")
    var ignoreNames: String?

    @Option(name: .long, help: "Comma-separated path fragments — files whose path contains any fragment are skipped.")
    var ignoreFiles: String?

    @Option(name: .long, help: "Comma-separated module/target names to skip entirely (their files aren't loaded).")
    var ignoreTargets: String?

    @Option(name: .long, help: "Auto-discover SPM packages in DerivedData for the given Xcode project name, add them as read-only modules.")
    var autoSpm: String?

    @Option(name: .long, help: "Override DerivedData root (defaults to ~/Library/Developer/Xcode/DerivedData).")
    var derivedDataPath: String?

    @Flag(name: .long, inversion: .prefixedNo, help: "RollbackPass safety net (default: on). --no-rollback keeps all renames even if some use-sites stay desynced (faster, but build may fail).")
    var rollback: Bool?

    @Option(name: .long, help: "Comma-separated symbol kinds to obfuscate (class,struct,enum,protocol,typealias,associatedtype,method,function,property,enumCase,parameter). Empty = all. For bisecting which kind breaks a build.")
    var kinds: String?

    @Option(name: .long, help: "Raw-value obfuscation mode: off (default) / safe (skip Codable, explicit literals only) / all (every String enum, materializes implicit raw values). Obfuscates String-enum raw values, adds a `displayName` with the originals, rewrites resolvable .rawValue use-sites to .displayName.")
    var rawValues: String?

    @Flag(name: .long, inversion: .prefixedNo, help: "Emit anonymized OVLD diagnostics for overloaded-call resolution (identifiers hashed; safe to share). For debugging why a call did/didn't resolve to the expected overload.")
    var diagnoseOverloads: Bool?

    @Flag(name: .long, inversion: .prefixedNo, help: "Green-build-first: pre-emptively skip renaming any function/method whose name has >1 callable in the project. Eliminates overload-desync risk entirely (no rename → no possible miss). Use when guaranteed-green build matters more than obfuscation coverage.")
    var skipOverloadedCallables: Bool?

    @Option(name: .long, help: "Path to the compiler index store (e.g. DerivedData/<proj>/Index.noindex/DataStore, or a dir produced by `swiftc -index-store-path`). Setting it ENABLES the USR ground-truth layer: disambiguates same-named symbols across targets (A4) and validates renames (A6). Requires a prior indexed build. Fail-closed: missing/stale index aborts rather than guesses. Omit for the pure syntactic baseline.")
    var indexStorePath: String?

    @Flag(name: .long, inversion: .prefixedNo, help: "Strict A5 gate: skip renaming any writable symbol that has no USR in the index. OFF by default — on real projects the index is often partial, and gating on it craters coverage for no safety gain (A4 tiebreak + A6 validator already give correctness). Only enable for a maximally-conservative 'rename nothing unverified' posture.")
    var indexStoreGate: Bool?

    @Flag(name: .long, inversion: .prefixedNo, help: "Stronger rollback safety net for overload-heavy projects: any surviving name whose renamed callable namesake exists triggers a group revert, regardless of what kind the un-renamed sym is. Trades coverage for green build.")
    var aggressiveRollback: Bool?

    @Flag(name: .long, inversion: .prefixedNo, help: "Rewrite a member access by NAME when the name is a PROJECT-UNIQUE member of an extension on an external type whose receiver can't be typed (the SwiftUI `extension View { func myModifier() }` idiom). ON by default — without it such members rename but every use-site survives and the rollback reverts them. Pass --no-unique-external-members to bisect a red build back to this heuristic.")
    var uniqueExternalMembers: Bool?

    @Flag(name: .long, inversion: .prefixedNo, help: "Emit a per-symbol decision report (Decisions.txt + decisions.json in --output): for every writable declaration, exactly why it was obfuscated / protected / skipped / reverted.")
    var explain: Bool?

    @Flag(name: .long, inversion: .prefixedNo, help: "Verbose logging.")
    var verbose: Bool?

    func run() throws {
        // Config-file layer: explicit --config (missing file = hard error) or auto-discovery
        // in CWD; neither ⇒ empty layer, pure-CLI behaviour.
        let fileConfig: ConfigFile
        if let config {
            fileConfig = try ConfigFile.load(from: Self.absolutize(config, isDirectory: false))
        } else if let discovered = ConfigFile.discover(
            in: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)) {
            fileConfig = try ConfigFile.load(from: discovered)
        } else {
            fileConfig = ConfigFile()
        }

        // CLI layer: only fields the user actually passed are non-nil. The two
        // negatively-named config keys map from their positive CLI declarations.
        var cli = ConfigFile()
        cli.module = module.isEmpty ? nil : module
        cli.readonly = readonly.isEmpty ? nil : readonly
        cli.output = output
        cli.dryRun = dryRun
        cli.debugNames = debugNames
        cli.sdk = sdk
        cli.sdkPath = sdkPath
        cli.noSdkIntrospect = sdkIntrospect.map { !$0 }
        cli.sdkModules = sdkModules.map(splitCSV)
        cli.ignoreNames = ignoreNames.map(splitCSV)
        cli.ignoreFiles = ignoreFiles.map(splitCSV)
        cli.ignoreTargets = ignoreTargets.map(splitCSV)
        cli.autoSpm = autoSpm
        cli.derivedDataPath = derivedDataPath
        cli.noRollback = rollback.map { !$0 }
        cli.kinds = kinds.map(splitCSV)
        cli.rawValues = rawValues
        cli.diagnoseOverloads = diagnoseOverloads
        cli.skipOverloadedCallables = skipOverloadedCallables
        cli.indexStorePath = indexStorePath
        cli.indexStoreGate = indexStoreGate
        cli.aggressiveRollback = aggressiveRollback
        cli.explain = explain
        cli.uniqueExternalMembers = uniqueExternalMembers
        cli.verbose = verbose

        let merged = cli.merging(over: fileConfig)

        let logger = StderrLogger(verbose: merged.verbose ?? false)
        let specs = try parseSpecs(merged.module ?? [], writable: true)
            + parseSpecs(merged.readonly ?? [], writable: false)
        guard !specs.isEmpty else {
            throw ValidationError("at least one --module (or a `module:` list in swiftprof.yaml) is required")
        }
        // Validate writable module paths up front — give a clear error instead of an obscure
        // failure deep inside the pipeline.
        let fm = FileManager.default
        for spec in specs where spec.writable {
            var isDir: ObjCBool = false
            if !fm.fileExists(atPath: spec.root.path, isDirectory: &isDir) {
                throw ValidationError("Module '\(spec.name)' path not found: \(spec.root.path) (CWD: \(fm.currentDirectoryPath))")
            }
            if !isDir.boolValue {
                throw ValidationError("Module '\(spec.name)' path must be a directory: \(spec.root.path)")
            }
        }
        let outputURL = Self.absolutize(merged.output ?? "./out", isDirectory: true)
        let options = PipelineOptions(
            modules: specs,
            outputDirectory: outputURL,
            dryRun: merged.dryRun ?? false,
            nameStyle: (merged.debugNames ?? false) ? .debug : .random,
            sdkName: merged.sdk ?? "iphonesimulator",
            sdkPath: merged.sdkPath,
            introspectSDK: !(merged.noSdkIntrospect ?? false),
            sdkModuleFilter: merged.sdkModules ?? [],
            ignoreNames: Set(merged.ignoreNames ?? []),
            ignoreFiles: merged.ignoreFiles ?? [],
            ignoreTargets: Set(merged.ignoreTargets ?? []),
            autoDiscoverSPMForProject: merged.autoSpm,
            derivedDataPath: merged.derivedDataPath,
            rollbackEnabled: !(merged.noRollback ?? false),
            obfuscatableKinds: Set((merged.kinds ?? []).compactMap { SymbolKind(rawValue: $0) }),
            rawValueMode: try parseRawValueMode(merged.rawValues ?? "off"),
            diagnoseOverloads: merged.diagnoseOverloads ?? false,
            skipOverloadedCallables: merged.skipOverloadedCallables ?? false,
            aggressiveRollback: merged.aggressiveRollback ?? false,
            indexStorePath: merged.indexStorePath,
            indexStoreGate: merged.indexStoreGate ?? false,
            explain: merged.explain ?? false,
            uniqueExternalMembers: merged.uniqueExternalMembers ?? true
        )
        let result = try Pipeline(options: options, logger: logger).run()
        FileHandle.standardOutput.write(Data(result.coverage.formatted().utf8))
    }

    private func parseRawValueMode(_ s: String) throws -> RawValueMode {
        guard let mode = RawValueMode(rawValue: s.trimmingCharacters(in: .whitespaces).lowercased()) else {
            throw ValidationError("--raw-values must be one of: \(RawValueMode.allCases.map { $0.rawValue }.joined(separator: ", "))")
        }
        return mode
    }

    private func splitCSV(_ s: String) -> [String] {
        guard !s.isEmpty else { return [] }
        return s.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func parseSpecs(_ raw: [String], writable: Bool) throws -> [ModuleSpec] {
        try raw.map { entry in
            guard let sep = entry.firstIndex(of: ":") else {
                throw ValidationError("--module / --readonly must be in form name:path (got \(entry))")
            }
            let name = String(entry[..<sep])
            let pathStr = String(entry[entry.index(after: sep)...])
            let url = Self.absolutize(pathStr, isDirectory: true)
            return ModuleSpec(name: name, root: url, writable: writable)
        }
    }

    /// Resolve a possibly-relative file path against the current working directory and return
    /// an absolute file URL. CFURL operations downstream sometimes fail on URLs whose path is
    /// stored as relative — absolutising eagerly avoids the obscure "URL has no scheme" error.
    static func absolutize(_ rawPath: String, isDirectory: Bool) -> URL {
        let expanded = (rawPath as NSString).expandingTildeInPath
        let absolute: String
        if (expanded as NSString).isAbsolutePath {
            absolute = expanded
        } else {
            absolute = (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(expanded)
        }
        let standardized = (absolute as NSString).standardizingPath
        return URL(fileURLWithPath: standardized, isDirectory: isDirectory)
    }
}

SwiftProfCLI.main()
