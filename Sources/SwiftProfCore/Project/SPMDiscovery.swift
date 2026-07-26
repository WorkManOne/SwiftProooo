import Foundation

/// Finds Swift Package Manager checkouts in DerivedData for a given Xcode project.
///
/// Standard layout written by Xcode:
///   ~/Library/Developer/Xcode/DerivedData/<ProjectName>-<hash>/SourcePackages/checkouts/<PackageName>/
///
/// Each discovered package contributes ONE module:
///   - name = package directory name (e.g. "PullTheTicketCore")
///   - root = the inner Sources/<PackageName>/ directory if it exists; otherwise the package root
///   - writable = false (we never rewrite SPM code)
///
/// If multiple `<ProjectName>-<hash>` directories exist (happens after multiple Xcode opens),
/// we pick the most recently modified one — closest to the user's current working state.
public enum SPMDiscovery {
    public static func findPackages(
        projectName: String,
        derivedDataPath: String?,
        logger: Logger
    ) -> [ModuleSpec] {
        let derivedRoot: URL
        if let p = derivedDataPath {
            derivedRoot = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        } else {
            derivedRoot = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: derivedRoot.path) else {
            logger.log("auto-spm: DerivedData not found at \(derivedRoot.path)")
            return []
        }

        // Find <ProjectName>-* subdirectories.
        guard let contents = try? fm.contentsOfDirectory(at: derivedRoot,
                                                         includingPropertiesForKeys: [.contentModificationDateKey]) else {
            logger.log("auto-spm: cannot read DerivedData")
            return []
        }
        let prefix = "\(projectName)-"
        let candidates = contents.filter { $0.lastPathComponent.hasPrefix(prefix) }
        guard let projectDir = mostRecent(candidates) else {
            logger.log("auto-spm: no DerivedData directory matching '\(prefix)*' found")
            return []
        }
        logger.log("auto-spm: using \(projectDir.lastPathComponent)")

        let checkouts = projectDir
            .appendingPathComponent("SourcePackages", isDirectory: true)
            .appendingPathComponent("checkouts", isDirectory: true)
        guard fm.fileExists(atPath: checkouts.path) else {
            logger.log("auto-spm: no SourcePackages/checkouts in \(projectDir.lastPathComponent)")
            return []
        }

        guard let packages = try? fm.contentsOfDirectory(at: checkouts,
                                                         includingPropertiesForKeys: nil) else {
            return []
        }

        var specs: [ModuleSpec] = []
        for pkg in packages {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: pkg.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let pkgName = pkg.lastPathComponent
            // Prefer Sources/<pkgName>/ as the module root if present — that's where the
            // primary target lives in standard SPM layout.
            let standardRoot = pkg.appendingPathComponent("Sources/\(pkgName)", isDirectory: true)
            let root: URL
            if fm.fileExists(atPath: standardRoot.path) {
                root = standardRoot
            } else {
                root = pkg.appendingPathComponent("Sources", isDirectory: true)
                guard fm.fileExists(atPath: root.path) else {
                    logger.log("auto-spm: \(pkgName) has no Sources/ — skipping", verbose: true)
                    continue
                }
            }
            specs.append(ModuleSpec(name: pkgName, root: root, writable: false))
            logger.log("auto-spm: + \(pkgName) at \(root.path)", verbose: true)
        }
        logger.log("auto-spm: discovered \(specs.count) packages")
        return specs
    }

    private static func mostRecent(_ urls: [URL]) -> URL? {
        urls.max { a, b in
            let aMtime = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            let bMtime = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            return aMtime < bMtime
        }
    }
}
