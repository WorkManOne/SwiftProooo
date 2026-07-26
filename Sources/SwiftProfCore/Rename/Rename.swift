import Foundation

/// A single edit to apply to a SourceFile.
public struct Rename {
    public let file: SourceFile
    public let offset: Int   // byte offset (UTF-8) from file start
    public let length: Int   // bytes to replace
    public let original: String
    public let replacement: String
    /// Symbol whose rename produced this edit, or -1 for non-symbol edits (raw-value literals,
    /// synthesized insertions). The A6 validator (IndexValidator) keys on this to cross-check each
    /// symbol's edit positions against the compiler's occurrence set.
    public let targetSymbolId: Int

    public init(file: SourceFile, offset: Int, length: Int, original: String, replacement: String,
                targetSymbolId: Int = -1) {
        self.file = file
        self.offset = offset
        self.length = length
        self.original = original
        self.replacement = replacement
        self.targetSymbolId = targetSymbolId
    }
}

/// Maps a Symbol → obfuscated name (built incrementally during planning).
public final class RenameMap {
    public internal(set) var obfBySymbolId: [Int: String] = [:]
    /// id → why a previously-planned rename was reverted (witness group, ambiguity, rollback, A6).
    /// First reason wins. Feeds the per-symbol decision report (`--explain`); a reverted symbol has
    /// no obf, so without this it would be indistinguishable from a never-planned policy skip.
    public private(set) var revertReasonBySymbolId: [Int: String] = [:]

    public init() {}

    public func assign(_ symbol: Symbol, to obf: String) {
        obfBySymbolId[symbol.id] = obf
    }

    public func obf(for symbol: Symbol) -> String? {
        obfBySymbolId[symbol.id]
    }

    public func revert(_ symbolId: Int, reason: String) {
        obfBySymbolId.removeValue(forKey: symbolId)
        if revertReasonBySymbolId[symbolId] == nil {
            revertReasonBySymbolId[symbolId] = reason
        }
    }

    public func revertReason(_ symbolId: Int) -> String? {
        revertReasonBySymbolId[symbolId]
    }
}
