import Foundation

public struct ModuleSpec {
    public let name: String
    public let root: URL
    public let writable: Bool
    public init(name: String, root: URL, writable: Bool) {
        self.name = name
        self.root = root
        self.writable = writable
    }
}

public struct LoadedProject {
    public let modules: [Module]
    public let files: [SourceFile]
}

public struct ProjectLoader {
    public let logger: Logger
    /// Module names to skip entirely. Files inside these modules are not loaded.
    public var ignoreTargets: Set<String>
    /// File path substrings — a file whose absolute path contains any substring is skipped.
    public var ignoreFiles: [String]

    public init(logger: Logger, ignoreTargets: Set<String> = [], ignoreFiles: [String] = []) {
        self.logger = logger
        self.ignoreTargets = ignoreTargets
        self.ignoreFiles = ignoreFiles
    }

    public func load(specs: [ModuleSpec]) throws -> LoadedProject {
        var modules: [Module] = []
        var files: [SourceFile] = []
        let fm = FileManager.default

        for spec in specs {
            if ignoreTargets.contains(spec.name) {
                logger.log("skip target \(spec.name) (matches --ignore-targets)")
                continue
            }
            let module = Module(name: spec.name, root: spec.root, writable: spec.writable)
            modules.append(module)

            var collected: [URL] = []
            let enumerator = fm.enumerator(
                at: spec.root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            while let url = enumerator?.nextObject() as? URL {
                guard url.pathExtension == "swift" else { continue }
                if matchesIgnoreFiles(url) {
                    logger.log("skip file \(url.path) (matches --ignore-files)", verbose: true)
                    continue
                }
                collected.append(url)
            }
            collected.sort { $0.path < $1.path }
            for url in collected {
                files.append(try SourceFile(url: url, module: module))
            }
            logger.log("loaded module \(spec.name) (\(spec.writable ? "rw" : "ro")) — \(collected.count) files", verbose: true)
        }

        return LoadedProject(modules: modules, files: files)
    }

    private func matchesIgnoreFiles(_ url: URL) -> Bool {
        let path = url.path
        for fragment in ignoreFiles where path.contains(fragment) {
            return true
        }
        return false
    }
}
