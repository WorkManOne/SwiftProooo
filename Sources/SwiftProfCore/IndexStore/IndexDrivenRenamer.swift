import Foundation
import SwiftSyntax

/// Stage-1 index-driven use-site renaming (opt-in behind `--index-store-path`).
///
/// The syntactic resolver types each use-site by hand and fails on the shapes it cannot model
/// (`receiver-untyped`: a member reached through a value whose type needs generic substitution, a
/// labeled subscript, an external generic). For every such use-site the compiler already knows the
/// answer: its index records an occurrence of the member's USR at that exact position. This pass
/// turns those occurrences into edits, so a mapped use-site is renamed regardless of whether the
/// syntactic resolver could type it.
///
/// It is the WRITE half of what `IndexValidator` (A6) reads: A6 takes each planned edit and checks
/// its position against the compiler's USR; this takes each renamed declaration's USR and emits an
/// edit at every position the compiler attributes to it.
///
/// Scope (Stage 1): member/value declarations only (`method`/`function`/`property`/`enumCase`/
/// `parameter`) — NOT type-like kinds or `init`. A constructor use-site (`Widget()`) reports the
/// `init` USR, not the type USR, so driving type renames from the index would miss it; types and
/// constructors stay on the syntactic + A4 path, where the same-named cross-target tie is already
/// resolved. Widen later if a coverage measurement warrants it.
///
/// Fail-closed at every step (a wrong rename is one RollbackPass cannot catch):
///   - no USR for the declaration → left to the syntactic resolver (the ~15% the index never maps);
///   - a USR that maps to more than one of our symbols → skipped (ambiguous inverse);
///   - an occurrence in a non-writable file → skipped (we never rewrite read-only modules);
///   - the source text at the computed offset does not equal the original name → skipped (guards a
///     stale/looser index, a backticked or operator spelling, a label position).
public final class IndexDrivenRenamer {
    let table: SymbolTable
    let map: RenameMap
    let ctx: IndexContext
    let logger: Logger

    public init(table: SymbolTable, map: RenameMap, ctx: IndexContext, logger: Logger) {
        self.table = table
        self.map = map
        self.ctx = ctx
        self.logger = logger
    }

    /// The edits, plus the positions they cover so the syntactic pass can defer to them (index wins
    /// wherever it has an occurrence; syntax fills the rest).
    public struct Result {
        public let renames: [Rename]
        /// `file identity → set of covered UTF-8 offsets`.
        public let coveredOffsetsByFile: [ObjectIdentifier: Set<Int>]
    }

    /// Stage-1 eligible kinds: a member or value, never a type reference or an initializer.
    private func isEligible(_ kind: SymbolKind) -> Bool {
        !kind.isTypeLike && kind != .initializer
    }

    public func run(on writableFiles: [SourceFile]) -> Result {
        // Writable files keyed by the SAME normalized path the index records occurrences under.
        var fileByPath: [String: SourceFile] = [:]
        for f in writableFiles { fileByPath[USRIndex.normalize(f.url.path)] = f }

        // Invert Symbol.id → USR so a USR shared by more than one of our symbols can be skipped.
        var symbolIdsByUSR: [String: [Int]] = [:]
        for (id, usr) in ctx.usrBySymbolId { symbolIdsByUSR[usr, default: []].append(id) }

        var convertersByFile: [ObjectIdentifier: SourceLocationConverter] = [:]
        var bytesByFile: [ObjectIdentifier: [UInt8]] = [:]

        var renames: [Rename] = []
        var covered: [ObjectIdentifier: Set<Int>] = [:]
        var emitted = 0

        for sym in table.symbols {
            guard let obf = map.obf(for: sym), isEligible(sym.kind) else { continue }
            guard let usr = ctx.usrBySymbolId[sym.id] else { continue }         // unmapped → syntactic
            guard symbolIdsByUSR[usr]?.count == 1 else { continue }             // ambiguous inverse
            let replacement = NamePool.wrapIfKeyword(obf)
            let nameBytes = Array(sym.name.utf8)
            let nameLen = nameBytes.count

            for occ in ctx.usrIndex.occurrences(ofUSR: usr) {
                guard let file = fileByPath[occ.file] else { continue }         // read-only / foreign
                let key = ObjectIdentifier(file)

                let converter: SourceLocationConverter
                if let c = convertersByFile[key] { converter = c } else {
                    converter = SourceLocationConverter(fileName: file.url.path, tree: file.syntax)
                    convertersByFile[key] = converter
                }
                let offset = converter.position(ofLine: occ.line, column: occ.column).utf8Offset

                // The declaration's own occurrence is renamed by ResolutionPass's decl loop; skipping
                // it here keeps a single edit at the decl and avoids two overlapping edits if the
                // line:col round-trip ever disagrees with `declOffset` by a byte.
                if offset == sym.declOffset { continue }

                let bytes: [UInt8]
                if let b = bytesByFile[key] { bytes = b } else {
                    bytes = Array(file.analysisContents.utf8)
                    bytesByFile[key] = bytes
                }
                guard offset >= 0, offset + nameLen <= bytes.count,
                      Array(bytes[offset ..< offset + nameLen]) == nameBytes else { continue }

                if covered[key]?.contains(offset) == true { continue }          // one edit per position
                renames.append(Rename(file: file, offset: offset, length: nameLen,
                                      original: sym.name, replacement: replacement,
                                      targetSymbolId: sym.id))
                covered[key, default: []].insert(offset)
                emitted += 1
            }
        }
        if emitted > 0 { logger.log("index-driven: \(emitted) use-site edit(s) from compiler occurrences") }
        return Result(renames: renames, coveredOffsetsByFile: covered)
    }
}
