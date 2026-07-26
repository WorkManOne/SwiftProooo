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

    /// Returns the number of names rolled back. Updates `map` (removes reverted entries) and
    /// rewrites `file.contents` in place — the next writeToDisk picks up the changes.
    @discardableResult
    public func run(on files: [SourceFile]) -> Int {
        let writable = files.filter { $0.module.writable }
        guard !writable.isEmpty else { return 0 }

        // 1. Collect all renamed names → list of symbols with that name.
        var symbolsByName: [String: [Symbol]] = [:]
        for sym in table.symbols where map.obf(for: sym) != nil {
            symbolsByName[sym.name, default: []].append(sym)
        }
        guard !symbolsByName.isEmpty else { return 0 }
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
            }
        }
        // 1d. Swift keywords — appear in source as part of the syntax (`protocol Foo {}`,
        // `var x:`, `func bar() {}`, etc.). A symbol that's backticked-keyword-named
        // (`var \`protocol\``) loses its backticks in `sym.name` after `stripBackticks`, so
        // its name collides with the keyword's literal appearance. Without this shield,
        // rollback would falsely flag every keyword use as a desynced rename and revert.
        for kw in NamePool.swiftKeywords where renamedNames.contains(kw) {
            shieldedNames.insert(kw)
        }
        // 1e. Optional-binding locals (`guard let x`, `if let x`, `while let x`). The resolver
        // intentionally keeps the local name un-renamed (it shadows a same-named property), so
        // the local legitimately survives in output. Shield it so rollback doesn't mistake it
        // for a desynced property use and revert the property.
        let bindingCollector = OptionalBindingNameCollector()
        for f in writable { bindingCollector.walk(f.syntax) }
        for n in bindingCollector.names where renamedNames.contains(n) {
            shieldedNames.insert(n)
        }

        // 2. Scan each writable file's stripped content for any surviving original name.
        let identRegex = try! NSRegularExpression(pattern: #"\b[A-Za-z_][A-Za-z0-9_]*\b"#)
        var survivors: Set<String> = []
        for file in writable {
            autoreleasepool {
                let stripped = Self.strip(file.contents)
                let nsString = stripped as NSString
                let range = NSRange(location: 0, length: nsString.length)
                identRegex.enumerateMatches(in: stripped, range: range) { match, _, _ in
                    guard let match else { return }
                    let word = nsString.substring(with: match.range)
                    if renamedNames.contains(word), !shieldedNames.contains(word) {
                        survivors.insert(word)
                    }
                }
            }
        }
        guard !survivors.isEmpty else {
            logger.log("Rollback: 0 names desynced (\(shieldedNames.count) names shielded by un-renamed namesakes)")
            return 0
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
        return survivors.count
    }

    static func isCallable(_ k: SymbolKind) -> Bool {
        k == .method || k == .function
    }

    /// Strip string literals (triple-quoted FIRST, then single-quoted excluding newlines) and
    /// comments (line + block). Order matters — see handoff notes on multi-line string handling.
    static func strip(_ s: String) -> String {
        var out = s
        out = Self.regexReplace(out, pattern: #""""[\s\S]*?""""#, with: #""""#)
        out = Self.regexReplace(out, pattern: #""(?:[^"\\\n]|\\.)*""#, with: #""""#)
        out = Self.regexReplace(out, pattern: #"//[^\n]*"#, with: "")
        out = Self.regexReplace(out, pattern: #"/\*[\s\S]*?\*/"#, with: "")
        return out
    }

    private static func regexReplace(_ s: String, pattern: String, with replacement: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        let escaped = NSRegularExpression.escapedTemplate(for: replacement)
        return re.stringByReplacingMatches(in: s, range: range, withTemplate: escaped)
    }
}
