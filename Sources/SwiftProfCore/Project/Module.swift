import Foundation

public struct Module: Hashable {
    public let name: String
    public let root: URL
    public let writable: Bool

    public init(name: String, root: URL, writable: Bool) {
        self.name = name
        self.root = root
        self.writable = writable
    }
}
