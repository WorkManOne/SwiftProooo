import Foundation

/// Generates collision-free obfuscated names.
///
/// Two styles:
/// - `.random`: 32-character alphanumeric, indistinguishable from machine-generated tokens.
///   This is the production default — defeats trivial reverse engineering since names carry
///   no information about kind, order, or relation to siblings.
/// - `.debug`: short kind-prefixed sequential names (T0, m0, p0, c0) for unit-test fixtures
///   and human inspection.
public final class NamePool {
    public enum Style {
        case random        // 32-char [A-Za-z][A-Za-z0-9]{31}
        case debug         // sequential by kind
    }

    public static let swiftKeywords: Set<String> = [
        "associatedtype","class","deinit","enum","extension","fileprivate","func","import",
        "init","inout","internal","let","open","operator","private","precedencegroup",
        "protocol","public","rethrows","static","struct","subscript","typealias","var",
        "break","case","catch","continue","default","defer","do","else","fallthrough","for",
        "guard","if","in","repeat","return","throw","switch","where","while",
        "Any","as","false","is","nil","self","Self","super","true","try",
        "Type","Protocol"
    ]

    public let style: Style
    private var counters: [String: Int] = [:]
    private var used: Set<String>

    public init(style: Style = .random, reservedNames: Set<String> = []) {
        self.style = style
        self.used = reservedNames.union(Self.swiftKeywords)
    }

    private static let alphaStart: [Character] = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
    private static let alphaNum:   [Character] = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

    public func mint(for kind: SymbolKind) -> String {
        switch style {
        case .random:  return mintRandom()
        case .debug:   return mintDebug(for: kind)
        }
    }

    private func mintRandom() -> String {
        while true {
            var s = ""
            s.append(Self.alphaStart.randomElement()!)
            for _ in 0..<31 { s.append(Self.alphaNum.randomElement()!) }
            if !used.contains(s) {
                used.insert(s)
                return s
            }
        }
    }

    private func mintDebug(for kind: SymbolKind) -> String {
        let p = debugPrefix(for: kind)
        while true {
            let n = counters[p, default: 0]
            counters[p] = n + 1
            let candidate = "\(p)\(n)"
            if !used.contains(candidate) {
                used.insert(candidate)
                return candidate
            }
        }
    }

    private func debugPrefix(for kind: SymbolKind) -> String {
        switch kind {
        case .class, .struct, .enum, .protocol, .typealias_, .associatedtype_: return "T"
        case .method, .function, .initializer:               return "m"
        case .property, .parameter:                          return "p"
        case .enumCase:                                      return "c"
        }
    }

    public static func wrapIfKeyword(_ s: String) -> String {
        swiftKeywords.contains(s) ? "`\(s)`" : s
    }
}
