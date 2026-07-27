import Foundation
import Yams

/// `swiftprof.yaml` — the project config file. Design (see
/// docs/superpowers/specs/2026-07-06-config-file-design.md):
///
/// - **Config key = flag name** (kebab-case, no `--`). No second naming scheme. The only
///   deltas: CSV-valued flags (`--sdk-modules`, `--ignore-*`, `--kinds`) take a YAML *list*,
///   and `module`/`readonly` are lists of the same `name:path` strings the CLI takes.
/// - Precedence per field: CLI > config > built-in default. The CLI layer is itself
///   represented as a `ConfigFile` (only user-passed fields non-nil) so `merging(over:)`
///   is a pure, testable field-wise `cli ?? config`.
/// - Relative paths in the file resolve against the CONFIG FILE's directory (the file sits
///   next to the project; runs from any CWD via `--config` still work). CLI paths keep
///   resolving against CWD — `load(from:)` absolutizes config paths eagerly so downstream
///   code can't tell the difference.
/// - Fail-closed on typos: Codable silently ignores unknown keys, and a misspelled
///   `ignore-name:` silently doing nothing on a real project is the worst failure mode —
///   so loading is two-pass: key validation (with a did-you-mean suggestion), then decode.
public struct ConfigFile: Decodable, Equatable {
    public var module: [String]?
    public var readonly: [String]?
    public var output: String?
    public var dryRun: Bool?
    public var debugNames: Bool?
    public var sdk: String?
    public var sdkPath: String?
    public var noSdkIntrospect: Bool?
    public var sdkModules: [String]?
    public var ignoreNames: [String]?
    public var ignoreFiles: [String]?
    public var ignoreTargets: [String]?
    public var autoSpm: String?
    public var derivedDataPath: String?
    public var noRollback: Bool?
    public var kinds: [String]?
    public var rawValues: String?
    public var diagnoseOverloads: Bool?
    public var skipOverloadedCallables: Bool?
    public var indexStorePath: String?
    public var indexStoreGate: Bool?
    public var aggressiveRollback: Bool?
    public var uniqueExternalMembers: Bool?
    public var explain: Bool?
    public var verbose: Bool?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case module
        case readonly
        case output
        case dryRun = "dry-run"
        case debugNames = "debug-names"
        case sdk
        case sdkPath = "sdk-path"
        case noSdkIntrospect = "no-sdk-introspect"
        case sdkModules = "sdk-modules"
        case ignoreNames = "ignore-names"
        case ignoreFiles = "ignore-files"
        case ignoreTargets = "ignore-targets"
        case autoSpm = "auto-spm"
        case derivedDataPath = "derived-data-path"
        case noRollback = "no-rollback"
        case kinds
        case rawValues = "raw-values"
        case diagnoseOverloads = "diagnose-overloads"
        case skipOverloadedCallables = "skip-overloaded-callables"
        case indexStorePath = "index-store-path"
        case indexStoreGate = "index-store-gate"
        case aggressiveRollback = "aggressive-rollback"
        case uniqueExternalMembers = "unique-external-members"
        case explain
        case verbose
    }

    public init() {}

    // MARK: - Discovery

    /// Filenames probed (in order) when no explicit `--config` is given.
    public static let discoveryNames = ["swiftprof.yaml", "swiftprof.yml"]

    /// Auto-discover a config file in `directory`. `swiftprof.yaml` wins over `.yml`.
    public static func discover(in directory: URL) -> URL? {
        for name in discoveryNames {
            let candidate = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    // MARK: - Loading

    /// Two-pass load: (1) raw-YAML key validation against the known key set — an unknown
    /// top-level key is a hard error with a nearest-match suggestion; (2) typed decode.
    /// Relative paths are resolved against the config file's directory before returning.
    public static func load(from url: URL) throws -> ConfigFile {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConfigFileError.fileNotFound(url.path)
        }
        let text = try String(contentsOf: url, encoding: .utf8)

        let raw: Any?
        do {
            raw = try Yams.load(yaml: text)
        } catch {
            throw ConfigFileError.unparseable(url.path, underlying: "\(error)")
        }
        guard let raw else { return ConfigFile() }   // empty file = empty config
        guard let dict = raw as? [String: Any] else {
            throw ConfigFileError.notAMapping(url.path)
        }
        let known = Set(CodingKeys.allCases.map(\.rawValue))
        for key in dict.keys.sorted() where !known.contains(key) {
            throw ConfigFileError.unknownKey(key, suggestion: nearestKnownKey(to: key), file: url.path)
        }

        var config: ConfigFile
        do {
            config = try YAMLDecoder().decode(ConfigFile.self, from: text)
        } catch {
            throw ConfigFileError.unparseable(url.path, underlying: "\(error)")
        }
        config.resolvePaths(relativeTo: url.deletingLastPathComponent())
        return config
    }

    // MARK: - Merging

    /// Field-wise precedence: every non-nil field of `self` (the CLI layer) wins over `base`
    /// (the file layer). Built-in defaults are applied by the consumer AFTER the merge.
    public func merging(over base: ConfigFile) -> ConfigFile {
        var r = ConfigFile()
        r.module = module ?? base.module
        r.readonly = readonly ?? base.readonly
        r.output = output ?? base.output
        r.dryRun = dryRun ?? base.dryRun
        r.debugNames = debugNames ?? base.debugNames
        r.sdk = sdk ?? base.sdk
        r.sdkPath = sdkPath ?? base.sdkPath
        r.noSdkIntrospect = noSdkIntrospect ?? base.noSdkIntrospect
        r.sdkModules = sdkModules ?? base.sdkModules
        r.ignoreNames = ignoreNames ?? base.ignoreNames
        r.ignoreFiles = ignoreFiles ?? base.ignoreFiles
        r.ignoreTargets = ignoreTargets ?? base.ignoreTargets
        r.autoSpm = autoSpm ?? base.autoSpm
        r.derivedDataPath = derivedDataPath ?? base.derivedDataPath
        r.noRollback = noRollback ?? base.noRollback
        r.kinds = kinds ?? base.kinds
        r.rawValues = rawValues ?? base.rawValues
        r.diagnoseOverloads = diagnoseOverloads ?? base.diagnoseOverloads
        r.skipOverloadedCallables = skipOverloadedCallables ?? base.skipOverloadedCallables
        r.indexStorePath = indexStorePath ?? base.indexStorePath
        r.indexStoreGate = indexStoreGate ?? base.indexStoreGate
        r.aggressiveRollback = aggressiveRollback ?? base.aggressiveRollback
        r.uniqueExternalMembers = uniqueExternalMembers ?? base.uniqueExternalMembers
        r.explain = explain ?? base.explain
        r.verbose = verbose ?? base.verbose
        return r
    }

    // MARK: - Path resolution

    /// Resolve every path-valued field against `base` (the config file's directory).
    /// Absolute paths and `~` are honoured; already-absolute values pass through, so the
    /// consumer's own CWD-based absolutization becomes a no-op for config-sourced values.
    mutating func resolvePaths(relativeTo base: URL) {
        module = module.map { $0.map { Self.resolveModuleSpec($0, against: base) } }
        readonly = readonly.map { $0.map { Self.resolveModuleSpec($0, against: base) } }
        output = output.map { Self.resolvePath($0, against: base) }
        sdkPath = sdkPath.map { Self.resolvePath($0, against: base) }
        derivedDataPath = derivedDataPath.map { Self.resolvePath($0, against: base) }
        indexStorePath = indexStorePath.map { Self.resolvePath($0, against: base) }
    }

    static func resolvePath(_ raw: String, against base: URL) -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        if (expanded as NSString).isAbsolutePath {
            return (expanded as NSString).standardizingPath
        }
        return base.appendingPathComponent(expanded).standardizedFileURL.path
    }

    /// `name:path` module spec — only the path part is resolved. A malformed spec (no `:`)
    /// is passed through untouched; the consumer's spec parser reports it with its usual error.
    static func resolveModuleSpec(_ spec: String, against base: URL) -> String {
        guard let sep = spec.firstIndex(of: ":") else { return spec }
        let name = spec[..<sep]
        let path = String(spec[spec.index(after: sep)...])
        return "\(name):\(Self.resolvePath(path, against: base))"
    }

    // MARK: - Typo suggestions

    /// Nearest known key by edit distance (≤ 3), for the unknown-key error message.
    static func nearestKnownKey(to key: String) -> String? {
        let candidates = CodingKeys.allCases.map(\.rawValue)
        let best = candidates
            .map { (key: $0, dist: editDistance(key.lowercased(), $0)) }
            .min { $0.dist < $1.dist }
        guard let best, best.dist <= 3 else { return nil }
        return best.key
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                let sub = prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, sub)
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}

public enum ConfigFileError: Error, CustomStringConvertible {
    case fileNotFound(String)
    case unparseable(String, underlying: String)
    case notAMapping(String)
    case unknownKey(String, suggestion: String?, file: String)

    public var description: String {
        switch self {
        case .fileNotFound(let path):
            return "config file not found: \(path)"
        case .unparseable(let path, let underlying):
            return "config file \(path) could not be parsed: \(underlying)"
        case .notAMapping(let path):
            return "config file \(path) must be a YAML mapping (key: value pairs) at the top level"
        case .unknownKey(let key, let suggestion, let file):
            let hint = suggestion.map { " — did you mean '\($0)'?" } ?? ""
            return "unknown key '\(key)' in \(file)\(hint) (keys mirror the CLI flag names)"
        }
    }
}
