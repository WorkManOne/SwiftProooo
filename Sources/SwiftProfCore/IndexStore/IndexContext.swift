import Foundation

/// Compiler ground-truth bundle threaded into resolution when `indexStorePath` is
/// set: the parsed index plus the precomputed `Symbol.id → USR` map (built once per
/// run via `USRIndex.usrBySymbol`). Immutable and shared across every resolver in a
/// run. Absent ⇒ purely syntactic behaviour (the index-free baseline).
public struct IndexContext {
    public let usrIndex: USRIndex
    public let usrBySymbolId: [Int: String]

    public init(usrIndex: USRIndex, usrBySymbolId: [Int: String]) {
        self.usrIndex = usrIndex
        self.usrBySymbolId = usrBySymbolId
    }

    /// USR the compiler recorded at a use-site position, or nil if unindexed.
    public func useSiteUSR(file: String, line: Int, column: Int) -> String? {
        usrIndex.usr(atFile: file, line: line, column: column)
    }
}
