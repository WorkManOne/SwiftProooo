import Foundation

/// Discovers .swiftinterface files in the active Xcode SDK and stdlib toolchain.
///
/// Strategy:
///   1. Find SDK root via `xcrun --sdk <name> --show-sdk-path`.
///   2. Enumerate framework interfaces under `<SDK>/System/Library/Frameworks/<X>.framework/Modules/<X>.swiftmodule/`.
///   3. Enumerate stdlib + private modules under `<SDK>/usr/lib/swift/<X>.swiftmodule/`.
///   4. Pick the arch-specific `.swiftinterface` matching the host (arm64-apple-ios-simulator
///      on Apple Silicon; x86_64 fallback). If a `.private.swiftinterface` is present alongside,
///      prefer the public one (less likely to depend on internal-only features).
///
/// All paths are returned even if some fail to parse later — InterfaceLoader handles individual
/// failures gracefully.
public struct SDKInterfacePaths {
    public let sdkRoot: URL
    public let sdkName: String
    public let arch: String
    /// (moduleName, interfaceFileURL)
    public let interfaces: [(module: String, url: URL)]
}

public struct SDKLocator {
    public let logger: Logger
    public init(logger: Logger) { self.logger = logger }

    /// Locates interface files for the given SDK ("iphonesimulator" by default).
    /// `explicitSDKPath` overrides the xcrun lookup; useful for CI/sandboxed environments.
    public func locate(
        sdkName: String = "iphonesimulator",
        explicitSDKPath: String? = nil,
        preferredArch: String = "arm64"
    ) throws -> SDKInterfacePaths {
        let sdkRoot: URL
        if let path = explicitSDKPath {
            sdkRoot = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        } else {
            sdkRoot = try runXcrun(sdkName: sdkName)
        }
        guard FileManager.default.fileExists(atPath: sdkRoot.path) else {
            throw SDKLocatorError.sdkNotFound(sdkRoot.path)
        }

        let archTag = "\(preferredArch)-apple-ios-simulator"  // matches iphonesimulator naming
        var found: [(String, URL)] = []

        // 1. Frameworks
        let frameworksRoot = sdkRoot.appendingPathComponent("System/Library/Frameworks")
        if let frameworks = try? FileManager.default.contentsOfDirectory(at: frameworksRoot, includingPropertiesForKeys: nil) {
            for fw in frameworks where fw.pathExtension == "framework" {
                let module = fw.deletingPathExtension().lastPathComponent
                let candidate = fw
                    .appendingPathComponent("Modules")
                    .appendingPathComponent("\(module).swiftmodule")
                    .appendingPathComponent("\(archTag).swiftinterface")
                if FileManager.default.fileExists(atPath: candidate.path) {
                    found.append((module, candidate))
                }
            }
        }

        // 2. Stdlib + private modules
        let stdlibRoot = sdkRoot.appendingPathComponent("usr/lib/swift")
        if let modules = try? FileManager.default.contentsOfDirectory(at: stdlibRoot, includingPropertiesForKeys: nil) {
            for m in modules where m.pathExtension == "swiftmodule" {
                let module = m.deletingPathExtension().lastPathComponent
                let candidate = m.appendingPathComponent("\(archTag).swiftinterface")
                if FileManager.default.fileExists(atPath: candidate.path) {
                    found.append((module, candidate))
                }
            }
        }

        logger.log("SDK \(sdkName) at \(sdkRoot.path): \(found.count) .swiftinterface files")
        return SDKInterfacePaths(sdkRoot: sdkRoot, sdkName: sdkName, arch: archTag, interfaces: found)
    }

    private func runXcrun(sdkName: String) throws -> URL {
        let process = Process()
        process.launchPath = "/usr/bin/xcrun"
        process.arguments = ["--sdk", sdkName, "--show-sdk-path"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SDKLocatorError.xcrunFailed(status: process.terminationStatus)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty else { throw SDKLocatorError.xcrunFailed(status: -1) }
        return URL(fileURLWithPath: path)
    }
}

public enum SDKLocatorError: Error, CustomStringConvertible {
    case sdkNotFound(String)
    case xcrunFailed(status: Int32)
    public var description: String {
        switch self {
        case .sdkNotFound(let p): return "SDK not found at \(p)"
        case .xcrunFailed(let s): return "xcrun exited with status \(s)"
        }
    }
}
