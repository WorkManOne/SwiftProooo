import Foundation

/// mtime-based staleness check (A2). Fail-closed and deliberately coarse: if a
/// writable source is newer than the index unit that recorded it, the index is
/// out of date and obfuscating against it would drift positions → corruption.
/// A content-hash check is a possible later refinement (see Handoff "Weak spots").
public enum IndexStaleness {
    /// Slack (seconds) absorbing filesystem mtime granularity / clock jitter.
    static let tolerance: TimeInterval = 2.0

    /// libIndexStore records the unit's modification time as an integer whose
    /// scale isn't promised by the header. Normalize to epoch seconds by
    /// magnitude (current epoch ≈ 1.8e9 s ≈ 1.8e12 ms ≈ 1.8e18 ns).
    static func epochSeconds(fromRecorded recorded: Int64) -> Double {
        let v = Double(recorded)
        switch v {
        case 1e17...:  return v / 1e9   // nanoseconds
        case 1e14...:  return v / 1e6   // microseconds
        case 1e11...:  return v / 1e3   // milliseconds
        default:       return v         // seconds
        }
    }

    static func fileModTimeSeconds(_ path: String) -> Double? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attrs[.modificationDate] as? Date else { return nil }
        return date.timeIntervalSince1970
    }

    /// True when `filePath` is newer than the index's recorded time for it (or
    /// when we can't read the file's mtime — unknown ⇒ treat as stale, fail closed).
    public static func isStale(filePath: String, recordedModTime: Int64) -> Bool {
        guard let fileSeconds = fileModTimeSeconds(filePath) else { return true }
        return fileSeconds > epochSeconds(fromRecorded: recordedModTime) + tolerance
    }
}

public enum IndexStoreProviderError: Error, CustomStringConvertible {
    case noIndexStorePath
    case storeNotFound(path: String)
    case staleSources([String])

    public var description: String {
        switch self {
        case .noIndexStorePath:
            return "--index-store-path is empty "
                + "(pass the DataStore directory, e.g. DerivedData/<proj>/Index.noindex/DataStore)"
        case .storeNotFound(let path):
            return "index store not found at \(path) — build with -index-store-path first"
        case .staleSources(let files):
            let list = files.prefix(8).joined(separator: "\n  ")
            let more = files.count > 8 ? "\n  …and \(files.count - 8) more" : ""
            return "index stale — rebuild before obfuscating. Newer than their index records:\n  "
                + list + more
        }
    }
}

/// A2: locate/load the index and guard against staleness. Day-1 scope supports an
/// explicit store path (the CI/sandbox route, mirroring `explicitSDKPath`); driving
/// a build to produce the index is a later addition. Anything uncertain fails
/// closed so the pipeline under-obfuscates rather than corrupts.
public final class IndexStoreProvider {
    public let logger: Logger

    public init(logger: Logger) {
        self.logger = logger
    }

    /// Open the store at `indexStorePath` and verify no writable source file in
    /// `writableFilePaths` is newer than its index record. Throws (fail closed) on
    /// an empty path, an unreadable store, or any stale source.
    public func loadIndex(indexStorePath: String, writableFilePaths: [String]) throws -> USRIndex {
        let path = indexStorePath
        guard !path.isEmpty else {
            throw IndexStoreProviderError.noIndexStorePath
        }
        guard FileManager.default.fileExists(atPath: path) else {
            throw IndexStoreProviderError.storeNotFound(path: path)
        }
        let index = try USRIndex(storePath: path)

        var stale: [String] = []
        for file in writableFilePaths {
            guard let recorded = index.indexedModTime(forFile: file) else {
                // No unit recorded this file at all: it wasn't part of the indexed
                // build. The Planner gate (A5) will refuse to rename its symbols
                // (no USR), so this is under-obfuscation, not corruption — don't
                // abort the whole run on it.
                continue
            }
            if IndexStaleness.isStale(filePath: file, recordedModTime: recorded) {
                stale.append(file)
            }
        }
        if !stale.isEmpty {
            throw IndexStoreProviderError.staleSources(stale.sorted())
        }
        logger.log("index store loaded: \(path)")
        return index
    }
}
