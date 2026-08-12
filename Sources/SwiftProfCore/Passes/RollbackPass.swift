import Foundation
import SwiftSyntax

/// Collects the bound names of optional bindings (`guard let x`, `if let x`, `while let x`).
/// These locals are intentionally left un-renamed by the resolver (they shadow same-named
/// properties), so they legitimately survive in output and must be shielded from rollback.
final class OptionalBindingNameCollector: SyntaxVisitor {
    var names: Set<String> = []
    init() { super.init(viewMode: .sourceAccurate) }
    override func visit(_ node: OptionalBindingConditionSyntax) -> SyntaxVisitorContinueKind {
        if let ident = node.pattern.as(IdentifierPatternSyntax.self) {
            var n = ident.identifier.text
            if n.count >= 2, n.hasPrefix("`"), n.hasSuffix("`") { n = String(n.dropFirst().dropLast()) }
            names.insert(n)
        }
        return .visitChildren
    }
}

/// What `RollbackPass` observed. Returned always, not gated on a diagnostics flag: the data is two
/// name-keyed dictionaries, and gating it is what let the rollback report and the decision report
/// drift into two mechanisms.
public struct RollbackResult: Sendable {
    public struct Survivor: Sendable {
        public let occurrences: Int
        public let filePath: String
        /// 1-based line of the FIRST occurrence. Stored as a line rather than an offset because the
        /// scan works in UTF-16 (`NSRegularExpression`) while every other offset in the reporting
        /// layer is UTF-8; handing a raw UTF-16 offset to a consumer that assumes UTF-8 mis-locates
        /// on any file containing non-ASCII.
        public let line: Int
    }
    /// Names whose surviving occurrence was NOT shielded: the group was reverted. Green build,
    /// coverage lost.
    public let revertedNames: [String: Survivor]
    /// Names whose surviving occurrence WAS shielded: the revert did not happen and the desync
    /// ships. This is the red-build set.
    public let blockedNames: [String: Survivor]
    /// name → the shields that claimed it (`1b` / `1c` / `1d` / `1e`).
    public let shieldReasons: [String: Set<String>]
    /// The subset of `blockedNames` whose survival a DECLARATION WE DELIBERATELY LEFT ALONE already
    /// explains: the benign `self.name = name` shape (a property renamed, its same-named parameter
    /// policy-skipped), a Swift keyword, an optional-binding local. Such a name is EXPECTED in the
    /// output, so it is not a lead. Computed here rather than by the report because this is the only
    /// place that knows the KINDS on both sides of the rename boundary.
    ///
    /// Empty on `.empty`, and a name absent from it is treated as unexplained: a consumer that
    /// cannot compute this reports at full volume, which is the fail-closed direction.
    public let shieldExplainedNames: Set<String>
    /// How many names were actually reverted (the old `run` return value).
    public let revertedCount: Int

    public static let empty = RollbackResult(revertedNames: [:], blockedNames: [:],
                                             shieldReasons: [:], shieldExplainedNames: [],
                                             revertedCount: 0)
}

/// Safety net pass — scans already-rewritten writable files for surviving original names.
///
/// If a name `X` was supposed to be renamed (decl + all use-sites) but `X` still appears as a
/// FREE IDENTIFIER (not in a string literal or comment) anywhere in the rewritten output,
/// the rewrite must have missed a use-site. We then revert ALL renames of name `X` everywhere
/// — both the declaration and all use-sites that DID get renamed go back to the original.
///
/// This mirrors SwiftShield's `rollbackDesyncedNames` approach. It's deliberately conservative:
///   - false POSITIVES are possible (two symbols with same name both reverted when only one
///     was actually desynced)
///   - false NEGATIVES are possible too — case 2 in the doc: if we renamed a use-site to a
///     WRONG obf, scan finds nothing original-named and won't revert. These need manual
///     blacklisting.
///
/// Trade-off: ~0.1-1% coverage loss in exchange for guaranteed-compileable output on the
/// common case where our resolver missed a use-site.
public final class RollbackPass {
    public let table: SymbolTable
    public let map: RenameMap
    public let stdlibRegistry: StdlibRegistry
    public let logger: Logger
    /// When true, disables shield-1b (un-renamed namesake) for ANY name with a renamed callable
    /// namesake — even when the un-renamed sym isn't itself callable. Any surviving occurrence of
    /// such a name triggers a revert of the whole group. More coverage loss, stronger green-build
    /// guarantee. The default exception (callable un-renamed + callable renamed) remains active.
    public let aggressive: Bool

    public init(table: SymbolTable, map: RenameMap, stdlibRegistry: StdlibRegistry, logger: Logger,
                aggressive: Bool = false) {
        self.table = table
        self.map = map
        self.stdlibRegistry = stdlibRegistry
        self.logger = logger
        self.aggressive = aggressive
    }

    /// One surviving original name, as observed in the rewritten output.
    private struct Hit {
        var occurrences = 0
        var filePath = ""        // path of the writable file, for the first occurrence
        var line = 0             // 1-based line of the first occurrence
    }

    /// Returns what was observed: which names were reverted, which survived behind a shield (the
    /// red-build set), and which shield claimed each. Updates `map` (removes reverted entries) and
    /// rewrites `file.contents` in place — the next writeToDisk picks up the changes.
    @discardableResult
    public func run(on files: [SourceFile]) -> RollbackResult {
        let writable = files.filter { $0.module.writable }
        guard !writable.isEmpty else { return .empty }

        // 1. Collect all renamed names → list of symbols with that name.
        var symbolsByName: [String: [Symbol]] = [:]
        for sym in table.symbols where map.obf(for: sym) != nil {
            symbolsByName[sym.name, default: []].append(sym)
        }
        guard !symbolsByName.isEmpty else { return .empty }
        let renamedNames = Set(symbolsByName.keys)

        // 1b. Names that ALSO exist as un-renamed symbols (protected / policy-skipped /
        // read-only-module / local-var-in-different-form). These names are EXPECTED to appear
        // in output text — they "shield" their renamed namesakes from rollback. Skipping them
        // avoids the most common false-positive: a parameter `x: Int` and a property `x: Int`
        // share the name, the property gets renamed correctly, the parameter stays — and
        // rollback would otherwise see surviving `x` and incorrectly revert the property.
        // Names that have at least one RENAMED callable (method/function). Used by the overload
        // exception below.
        var renamedCallableNames: Set<String> = []
        for sym in table.symbols where Self.isCallable(sym.kind) && map.obf(for: sym) != nil {
            renamedCallableNames.insert(sym.name)
        }
        // Which shield claimed each name, and the kinds on both sides of the rename boundary —
        // a shield is what turns "coverage loss" into "red build", so naming it is what lets the
        // `--explain` report distinguish the two.
        var shieldReasons: [String: Set<String>] = [:]
        // Names with an UN-renamed callable namesake. Collected in its own loop on purpose: the
        // shield loop below `continue`s past exactly these names when the overload exception fires,
        // so folding the two would lose the very names the tiering rule asks about.
        var unrenamedCallableNames: Set<String> = []
        for sym in table.symbols where map.obf(for: sym) == nil {
            if Self.isCallable(sym.kind), renamedNames.contains(sym.name) {
                unrenamedCallableNames.insert(sym.name)
            }
        }
        var shieldedNames: Set<String> = []
        for sym in table.symbols where map.obf(for: sym) == nil {
            guard renamedNames.contains(sym.name) else { continue }
            // Aggressive rollback: if the name has ANY renamed callable namesake — regardless of
            // whether THIS un-renamed sym is itself callable — refuse to shield it. Catches more
            // overload-desync cases at the cost of reverting same-named property/param renames
            // when a method by that name is also overloaded.
            if aggressive, renamedCallableNames.contains(sym.name) { continue }
            // Default (smart) exception: only when the un-renamed namesake is itself a callable
            // AND a renamed callable of the same name exists — overload set straddles the rename
            // boundary. Preserves property/parameter shields (avoids `self.name = name` regressions)
            // while still surfacing genuine method-overload desync.
            if Self.isCallable(sym.kind) && renamedCallableNames.contains(sym.name) {
                continue
            }
            shieldedNames.insert(sym.name)
            shieldReasons[sym.name, default: []].insert("1b")
        }
        // 1c. Apple API names — any member name declared publicly in stdlib / SwiftUI / UIKit /
        // Combine / Foundation. When user code calls `view.cornerRadius`, `Color.primary`,
        // `NotificationCenter.default.post(...)`, the names appear in output but they're calls
        // to Apple's API, not desynced renames of our local symbols.
        // AGGRESSIVE mode disables this shield: a renamed local that happens to share a name with
        // a stdlib member (`update`, `save`, `value`, `id`, `count`, `result`, …) is currently
        // protected even when its own decl/uses are desynced. Trading "Apple-API-only surviving"
        // false-positives for stronger green-build guarantee — the caller asked for that tradeoff.
        if !aggressive {
            for name in stdlibRegistry.allKnownMemberNames where renamedNames.contains(name) {
                shieldedNames.insert(name)
                shieldReasons[name, default: []].insert("1c")
            }
        }
        // 1d. Swift keywords — appear in source as part of the syntax (`protocol Foo {}`,
        // `var x:`, `func bar() {}`, etc.). A symbol that's backticked-keyword-named
        // (`var \`protocol\``) loses its backticks in `sym.name` after `stripBackticks`, so
        // its name collides with the keyword's literal appearance. Without this shield,
        // rollback would falsely flag every keyword use as a desynced rename and revert.
        for kw in NamePool.swiftKeywords where renamedNames.contains(kw) {
            shieldedNames.insert(kw)
            shieldReasons[kw, default: []].insert("1d")
        }
        // 1e. Optional-binding locals (`guard let x`, `if let x`, `while let x`). The resolver
        // intentionally keeps the local name un-renamed (it shadows a same-named property), so
        // the local legitimately survives in output. Shield it so rollback doesn't mistake it
        // for a desynced property use and revert the property.
        let bindingCollector = OptionalBindingNameCollector()
        for f in writable { bindingCollector.walk(f.syntax) }
        for n in bindingCollector.names where renamedNames.contains(n) {
            shieldedNames.insert(n)
            shieldReasons[n, default: []].insert("1e")
        }

        // 2. Scan each writable file's stripped content for any surviving original name.
        let identRegex = try! NSRegularExpression(pattern: #"\b[A-Za-z_][A-Za-z0-9_]*\b"#)
        var survivors: Set<String> = []
        // First location + occurrence count per name, on both sides of the shield. Collected
        // always — this is what feeds the `--explain` report, not gated on a diagnostics flag.
        var revertedHits: [String: Hit] = [:]
        var blockedHits: [String: Hit] = [:]
        for file in writable {
            autoreleasepool {
                let stripped = Self.strip(file.contents)
                let nsString = stripped as NSString
                let range = NSRange(location: 0, length: nsString.length)
                identRegex.enumerateMatches(in: stripped, range: range) { match, _, _ in
                    guard let match else { return }
                    let word = nsString.substring(with: match.range)
                    guard renamedNames.contains(word) else { return }
                    if !shieldedNames.contains(word) {
                        survivors.insert(word)
                        Self.record(word, at: match.range.location, in: nsString,
                                    file.url.path, into: &revertedHits)
                    } else {
                        Self.record(word, at: match.range.location, in: nsString,
                                    file.url.path, into: &blockedHits)
                    }
                }
            }
        }

        // 2b. Split the blocked names by whether a declaration we deliberately left alone explains
        // the survivor. The rule is `main`'s, restored verbatim in meaning from the `reportSurvivors`
        // reporter this pass used to carry:
        //
        //   * shielded ONLY as an Apple API name (1c) — no un-renamed declaration of ours can be
        //     what survived, so the occurrence is either Apple's own member or our miss;
        //   * shielded by 1b while a CALLABLE of the name was renamed and the un-renamed namesake is
        //     NOT callable — a surviving CALL cannot be that namesake.
        //
        // Everything else is the benign `self.name = name` shape (a property renamed, its same-named
        // parameter left alone), a keyword, or an optional-binding local. Fail closed: a name is
        // explained only when the rule says so, never by default.
        var shieldExplained: Set<String> = []
        for name in blockedHits.keys {
            let shields = shieldReasons[name] ?? []
            let renamedCallable = (symbolsByName[name] ?? []).contains { Self.isCallable($0.kind) }
            let unexplained = shields == ["1c"]
                || (shields.contains("1b") && renamedCallable && !unrenamedCallableNames.contains(name))
            if !unexplained { shieldExplained.insert(name) }
        }

        func result(_ revertedCount: Int) -> RollbackResult {
            RollbackResult(
                revertedNames: revertedHits.mapValues {
                    RollbackResult.Survivor(occurrences: $0.occurrences, filePath: $0.filePath, line: $0.line)
                },
                blockedNames: blockedHits.mapValues {
                    RollbackResult.Survivor(occurrences: $0.occurrences, filePath: $0.filePath, line: $0.line)
                },
                shieldReasons: shieldReasons,
                shieldExplainedNames: shieldExplained,
                revertedCount: revertedCount)
        }

        guard !survivors.isEmpty else {
            logger.log("Rollback: 0 names desynced (\(shieldedNames.count) names shielded by un-renamed namesakes)")
            return result(0)
        }
        logger.log("Rollback: \(survivors.count) names desynced — reverting")
        if survivors.count <= 30 {
            for n in survivors.sorted() { logger.log("  ↩ \(n)") }
        }

        // 3. Build the list of (obf → original) pairs to revert; clear them from the map.
        var obfsByName: [String: [(obf: String, original: String)]] = [:]
        for name in survivors {
            guard let syms = symbolsByName[name] else { continue }
            for sym in syms {
                if let obf = map.obf(for: sym) {
                    obfsByName[name, default: []].append((obf: obf, original: name))
                    map.revert(sym.id, reason: "rollback safety net — original name '\(name)' still appeared in rewritten output")
                }
            }
        }

        // 4. For each writable file, run regex replacement `\bobf\b → original` for every
        //    obf that needs reverting. We do this textually because the offsets in `file.contents`
        //    have already been shuffled by the forward pass.
        let totalObfs = obfsByName.values.reduce(0) { $0 + $1.count }
        logger.log("Rollback: \(totalObfs) obf entries to revert across \(writable.count) writable files")
        for file in writable {
            autoreleasepool {
                var content = file.contents
                var changed = false
                for (_, pairs) in obfsByName {
                    for (obf, original) in pairs {
                        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: obf) + #"\b"#
                        guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
                        let nsString = content as NSString
                        let range = NSRange(location: 0, length: nsString.length)
                        if re.firstMatch(in: content, range: range) == nil { continue }
                        let safeOrig = NSRegularExpression.escapedTemplate(
                            for: NamePool.wrapIfKeyword(original)
                        )
                        content = re.stringByReplacingMatches(in: content, range: range, withTemplate: safeOrig)
                        changed = true
                    }
                }
                if changed { file.updateContents(content) }
            }
        }
        return result(survivors.count)
    }

    static func isCallable(_ k: SymbolKind) -> Bool {
        k == .method || k == .function
    }

    private static func record(_ name: String, at offset: Int, in text: NSString,
                               _ filePath: String, into dict: inout [String: Hit]) {
        if dict[name] != nil {
            dict[name]!.occurrences += 1
            return
        }
        // Counted only for the FIRST occurrence of each name, so this stays O(file) per reported
        // name rather than per match. `text` is the length-preserving stripped content, so a
        // newline count up to `offset` is the line in the REAL file.
        var line = 1
        var i = 0
        while i < offset && i < text.length {
            if text.character(at: i) == 10 { line += 1 }
            i += 1
        }
        dict[name] = Hit(occurrences: 1, filePath: filePath, line: line)
    }

    /// Strip string literals (triple-quoted FIRST, then single-quoted excluding newlines) and
    /// comments (line + block). Order matters — see handoff notes on multi-line string handling.
    ///
    /// LENGTH-PRESERVING: every stripped character becomes a space (newlines kept), so an offset in
    /// the result names the same position in the input. The scan only looks for free identifiers
    /// and a run of spaces bounds a word exactly like the removed text did, so the scan is
    /// unaffected — and the recorded line number points at the real file.
    static func strip(_ s: String) -> String {
        var out = s
        out = Self.blankMatches(out, pattern: #""""[\s\S]*?""""#)
        out = Self.blankMatches(out, pattern: #""(?:[^"\\\n]|\\.)*""#)
        out = Self.blankMatches(out, pattern: #"//[^\n]*"#)
        out = Self.blankMatches(out, pattern: #"/\*[\s\S]*?\*/"#)
        return out
    }

    private static func blankMatches(_ s: String, pattern: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        let matches = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return s }
        let out = NSMutableString(string: s)
        for m in matches.reversed() {
            // Build the blank run per UTF-16 UNIT, not per Character: a surrogate pair is one
            // Character but two units, and padding by Character count would shift every later offset.
            var blank = ""
            blank.reserveCapacity(m.range.length)
            for i in 0..<m.range.length {
                blank.append(ns.character(at: m.range.location + i) == 10 ? "\n" : " ")
            }
            out.replaceCharacters(in: m.range, with: blank)
        }
        return out as String
    }
}
