import Foundation
import SwiftSyntax
import SwiftParser

public final class SourceFile {
    public let url: URL
    public let module: Module
    public private(set) var contents: String
    private var cachedTree: SourceFileSyntax?

    public init(url: URL, module: Module) throws {
        self.url = url
        self.module = module
        self.contents = try String(contentsOf: url, encoding: .utf8)
    }

    public var syntax: SourceFileSyntax {
        if let tree = cachedTree { return tree }
        let tree = Parser.parse(source: contents)
        cachedTree = tree
        return tree
    }

    public func updateContents(_ newContents: String) {
        contents = newContents
        cachedTree = nil
    }
}
