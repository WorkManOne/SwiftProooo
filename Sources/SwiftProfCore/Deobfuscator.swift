import Foundation

/// Restores original identifiers in a piece of ERROR TEXT (a compiler / Xcode diagnostic
/// produced from obfuscated sources), using `ConversionMap.json` read in REVERSE.
///
/// The obfuscator writes a `ConversionMap` of `original → obfuscated` ("was → became").
/// A build against the obfuscated code reports errors that name the OBFUSCATED symbols, e.g.
///
///     error: value of type 'saysrsrtdurdfgjdgfjdfgj' has no member 'qwex…'
///
/// This type reads the SAME map the other way (`obfuscated → original`) and rewrites those
/// tokens back, so a developer reads the original error:
///
///     error: value of type 'UserService' has no member 'save'
///
/// It transforms arbitrary text: only whole identifier tokens that are known obfuscated names
/// are touched; every other character (the diagnostic words, quotes, dots, line numbers,
/// paths) passes through verbatim.
///
/// Scope: this is de-obfuscation via the reversible map. It does NOT de-anonymize the
/// `-anon.txt` `Anon.of` hashes (one-way), and it does not decode mangled linker symbols
/// (`$s…`) — obfuscated names do not appear verbatim inside Swift name mangling.
///
/// Reverse lookup is a function: obfuscated names are minted collision-free (`NamePool`), and
/// where witness/override linking maps several symbols to one obf they share one `original`
/// (linking is by name). The rare "one obf → several distinct originals" case is not silently
/// resolved — it is annotated with kind/module (see `render`).
public struct Deobfuscator {

    /// How a matched token is emitted.
    public enum Mode {
        /// Substitute the original in place; the obfuscated token disappears. Safe and cleanest
        /// for random 32-char names.
        case replace
        /// Keep the obfuscated token and append the original next to it (`p0⟨→save⟩`). Nothing is
        /// destroyed — the correct default for short debug names that can collide with real
        /// identifiers in the text, and for a genuine ambiguity.
        case annotate
    }

    /// The naming style of the loaded map, inferred from the obfuscated values.
    public enum Style {
        case random   // 32-char [A-Za-z][A-Za-z0-9]{31} — production default
        case debug    // short kind-prefixed T0 / m0 / p0 / c0 — fixtures/inspection
        case mixed    // both seen (should not happen within one run)
        case unknown  // empty map, or values matching neither shape
    }

    /// obfuscated → the distinct originals it maps to (normally one entry).
    private let index: [String: [ConversionEntry]]

    public let style: Style

    /// The mode to use when the caller did not force one: `replace` for a random map (safe to
    /// substitute), `annotate` otherwise (never destroy a token that might be a real identifier).
    public var defaultMode: Mode { style == .random ? .replace : .annotate }

    public init(entries: [ConversionEntry]) {
        var idx: [String: [ConversionEntry]] = [:]
        for e in entries {
            idx[e.obfuscated, default: []].append(e)
        }
        // Collapse duplicates that carry the same identity (a witness group maps several symbols
        // of the SAME name to one obf), so a unique obf stays unique.
        self.index = idx.mapValues { group in
            var seen = Set<String>()
            var out: [ConversionEntry] = []
            for e in group where seen.insert("\(e.original)\u{1}\(e.kind)\u{1}\(e.module)").inserted {
                out.append(e)
            }
            return out
        }
        self.style = Self.detectStyle(idx.keys)
    }

    /// Load one or more `ConversionMap.json` files and build a deobfuscator over their union.
    /// A later file's entries are merged, so a genuine cross-map conflict on one obf surfaces as
    /// an ambiguity (annotated) rather than a silent overwrite. Throws on a missing or malformed
    /// file (fail-closed — a bad map is a hard error, never a silent no-op).
    public static func load(mapPaths: [String]) throws -> Deobfuscator {
        var entries: [ConversionEntry] = []
        let decoder = JSONDecoder()
        for path in mapPaths {
            let url = URL(fileURLWithPath: path)
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw LoadError.unreadable(path: path, underlying: error)
            }
            do {
                entries.append(contentsOf: try decoder.decode(ConversionMap.self, from: data).entries)
            } catch {
                throw LoadError.malformed(path: path, underlying: error)
            }
        }
        return Deobfuscator(entries: entries)
    }

    public enum LoadError: Error, CustomStringConvertible {
        case unreadable(path: String, underlying: Error)
        case malformed(path: String, underlying: Error)

        public var description: String {
            switch self {
            case .unreadable(let path, let underlying):
                return "cannot read conversion map '\(path)': \(underlying.localizedDescription)"
            case .malformed(let path, let underlying):
                return "conversion map '\(path)' is not a valid ConversionMap.json: \(underlying)"
            }
        }
    }

    /// True when the map holds nothing to restore (used by the CLI to warn instead of silently
    /// echoing the input unchanged).
    public var isEmpty: Bool { index.isEmpty }

    // MARK: - Transform

    /// Rewrite `text`, restoring originals for every known obfuscated token.
    public func deobfuscate(_ text: String, mode: Mode) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if Self.isIdentifierStart(c) {
                var j = text.index(after: i)
                while j < text.endIndex, Self.isIdentifierPart(text[j]) {
                    j = text.index(after: j)
                }
                result += render(String(text[i..<j]), mode: mode)
                i = j
            } else {
                result.append(c)
                i = text.index(after: i)
            }
        }
        return result
    }

    /// Render one identifier token: passthrough if unknown, restored if known, and always
    /// annotated (with kind/module) when a single obf maps to several distinct originals.
    private func render(_ token: String, mode: Mode) -> String {
        guard let group = index[token] else { return token }
        if group.count == 1 {
            let original = group[0].original
            switch mode {
            case .replace:  return original
            case .annotate: return "\(token)⟨→\(original)⟩"
            }
        }
        // Ambiguous: never pick silently, regardless of mode.
        let parts = group.map { "\($0.original)[\($0.kind)@\($0.module)]" }.joined(separator: " | ")
        return "\(token)⟨→\(parts)⟩"
    }

    // MARK: - Identifier tokenisation
    //
    // A token is a maximal run of identifier characters. Unicode letters/digits are included so a
    // non-ASCII identifier stays ONE token and never exposes an inner ASCII run that could false-
    // match; obfuscated names are ASCII-only, so only ASCII tokens can ever be map keys anyway.

    static func isIdentifierStart(_ c: Character) -> Bool { c == "_" || c.isLetter }
    static func isIdentifierPart(_ c: Character) -> Bool { c == "_" || c.isLetter || c.isNumber }

    // MARK: - Style detection

    static func detectStyle<S: Sequence>(_ obfs: S) -> Style where S.Element == String {
        var sawRandom = false
        var sawDebug = false
        for o in obfs {
            if isRandomName(o) { sawRandom = true }
            else if isDebugName(o) { sawDebug = true }
        }
        switch (sawRandom, sawDebug) {
        case (true, false):  return .random
        case (false, true):  return .debug
        case (true, true):   return .mixed
        case (false, false): return .unknown
        }
    }

    /// 32-char `[A-Za-z][A-Za-z0-9]{31}`, the production random shape (`NamePool.mintRandom`).
    static func isRandomName(_ s: String) -> Bool {
        guard s.count == 32 else { return false }
        for (i, ch) in s.enumerated() {
            guard ch.isASCII else { return false }
            if i == 0 {
                if !ch.isLetter { return false }
            } else if !(ch.isLetter || ch.isNumber) {
                return false
            }
        }
        return true
    }

    /// Short kind-prefixed `[Tmpc][0-9]+`, the debug shape (`NamePool.mintDebug`).
    static func isDebugName(_ s: String) -> Bool {
        guard let first = s.first, "Tmpc".contains(first) else { return false }
        let rest = s.dropFirst()
        guard !rest.isEmpty else { return false }
        return rest.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
