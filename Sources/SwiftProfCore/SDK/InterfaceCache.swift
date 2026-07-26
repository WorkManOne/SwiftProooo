import Foundation
import CryptoKit

/// Persistent disk cache for parsed `.swiftinterface` data, keyed by SDK path + arch.
/// First run on a new SDK pays the ~30s parse cost; subsequent runs load in milliseconds.
///
/// Cache invalidation: if the SDK path or any tracked file's mtime changes, we re-parse.
/// (Tracking individual file mtimes would be more precise but parses-when-Xcode-updates is
/// good enough — Apple bumps SDK paths with the Xcode version.)
public struct InterfaceCache {
    public let cacheDirectory: URL
    public let logger: Logger

    public init(logger: Logger, cacheDirectory: URL? = nil) {
        self.logger = logger
        if let dir = cacheDirectory {
            self.cacheDirectory = dir
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.cacheDirectory = home.appendingPathComponent("Library/Caches/SwiftProf", isDirectory: true)
        }
    }

    /// Cache key combines SDK root, arch, and a content-fingerprint based on file mtimes for the
    /// modules we're going to parse. If any file's mtime differs from what's cached, we re-parse.
    public func cacheKey(sdkRoot: URL, arch: String, files: [URL]) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(sdkRoot.path.utf8))
        hasher.update(data: Data(arch.utf8))
        for f in files.sorted(by: { $0.path < $1.path }) {
            hasher.update(data: Data(f.path.utf8))
            if let attrs = try? FileManager.default.attributesOfItem(atPath: f.path),
               let mtime = attrs[.modificationDate] as? Date {
                hasher.update(data: Data("\(mtime.timeIntervalSince1970)".utf8))
            }
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public func load(key: String) -> [LoadedInterface]? {
        let url = cacheFile(key)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([SerializableInterface].self, from: data)
        else { return nil }
        logger.log("interface cache hit: \(decoded.count) modules from \(url.lastPathComponent)")
        return decoded.map {
            LoadedInterface(
                module: $0.module,
                protocols: $0.protocols.mapValues(Set.init),
                allMemberNames: Set($0.allMemberNames)
            )
        }
    }

    public func store(_ interfaces: [LoadedInterface], key: String) {
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let serialisable = interfaces.map {
            SerializableInterface(
                module: $0.module,
                protocols: $0.protocols.mapValues(Array.init),
                allMemberNames: Array($0.allMemberNames)
            )
        }
        guard let data = try? JSONEncoder().encode(serialisable) else { return }
        try? data.write(to: cacheFile(key))
        logger.log("interface cache stored \(interfaces.count) modules → \(cacheFile(key).lastPathComponent)", verbose: true)
    }

    private func cacheFile(_ key: String) -> URL {
        cacheDirectory.appendingPathComponent("interfaces-\(key).json")
    }
}

private struct SerializableInterface: Codable {
    let module: String
    let protocols: [String: [String]]
    let allMemberNames: [String]
}
