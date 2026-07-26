import Foundation

public protocol Logger {
    func log(_ message: @autoclosure () -> String, verbose: Bool)
}

public extension Logger {
    func log(_ message: @autoclosure () -> String) { log(message(), verbose: false) }
}

public struct StderrLogger: Logger {
    public var verbose: Bool
    public init(verbose: Bool = false) { self.verbose = verbose }
    public func log(_ message: @autoclosure () -> String, verbose isVerbose: Bool) {
        if isVerbose && !verbose { return }
        FileHandle.standardError.write(Data((message() + "\n").utf8))
    }
}
