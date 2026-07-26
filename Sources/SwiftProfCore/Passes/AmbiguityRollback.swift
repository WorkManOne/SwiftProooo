import Foundation
import SwiftSyntax

/// Reverts obfuscation for symbols whose resolution at use-sites would be ambiguous without
/// type information.
///
/// Enum cases sharing a name across enums — shorthand `.case` cannot always be disambiguated. But
/// reverting EVERY colliding case (the old behaviour) cratered coverage for popular names
/// (`none`/`success`/`shared`/…) even when the case was never used in shorthand form, or only ever
/// used qualified (`EnumName.case`, which is unambiguous). B-FIX-1: revert a colliding case only
/// when its name actually appears at a shorthand `.case` use-site. Cases that are unused, or only
/// referenced qualified, stay renamed.
///
/// Fail-closed scope: any shorthand `.name` occurrence of a colliding case name reverts the whole
/// same-named group — we do not attempt to prove each shorthand site binds to a unique enum (that
/// is the resolver's job; here we err toward under-obfuscation, never a wrong rename).
///
/// NOTE: overloaded functions/methods are NOT blanket-reverted here. The ResolutionPass resolver
/// is signature-aware (it disambiguates same-named overloads by argument labels and types), so
/// renaming them to distinct obfs is safe; any use-site the resolver still can't resolve leaves
/// the original name in output, and RollbackPass reverts that group as the safety net.
public final class AmbiguityRollback {
    public let table: SymbolTable
    public let logger: Logger

    public init(table: SymbolTable, logger: Logger) {
        self.table = table
        self.logger = logger
    }

    public func run(map: RenameMap, files: [SourceFile]) {
        rollbackAmbiguousEnumCases(map: map, files: files)
    }

    private func rollbackAmbiguousEnumCases(map: RenameMap, files: [SourceFile]) {
        // Names with a colliding case decl across enums — only these can be shorthand-ambiguous.
        let collidingNames = Set(table.enumCasesByName.filter { $0.value.count > 1 }.keys)
        guard !collidingNames.isEmpty else { return }

        // Which of those names appear at a shorthand `.case` use-site anywhere in writable code.
        let scanner = ShorthandCaseScanner(interesting: collidingNames)
        for file in files where file.module.writable {
            scanner.walk(file.syntax)
        }

        for name in collidingNames where scanner.usedShorthand.contains(name) {
            guard let cases = table.enumCasesByName[name] else { continue }
            var reverted = 0
            let reason = "ambiguous enum case '\(name)' — same name in >1 enum, used at a shorthand `.\(name)` site"
            for c in cases where map.obf(for: c) != nil {
                map.revert(c.id, reason: reason)
                reverted += 1
            }
            if reverted > 0 {
                logger.log("ambiguous enum case `\(name)` (shorthand use) — rolled back \(reverted)", verbose: true)
            }
        }
    }
}

/// Collects the set of `interesting` names that occur as a shorthand `.name` member access (base
/// == nil) — the only positions where a same-named case across enums can't be disambiguated by the
/// token itself. Qualified `Enum.name` uses carry their own base and are excluded.
private final class ShorthandCaseScanner: SyntaxVisitor {
    let interesting: Set<String>
    var usedShorthand: Set<String> = []

    init(interesting: Set<String>) {
        self.interesting = interesting
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        if node.base == nil {
            let name = Self.strip(node.declName.baseName.text)
            if interesting.contains(name) { usedShorthand.insert(name) }
        }
        return .visitChildren
    }

    private static func strip(_ s: String) -> String {
        guard s.count >= 2, s.hasPrefix("`"), s.hasSuffix("`") else { return s }
        return String(s.dropFirst().dropLast())
    }
}
