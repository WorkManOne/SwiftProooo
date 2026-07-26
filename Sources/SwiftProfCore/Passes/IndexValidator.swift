import Foundation
import SwiftSyntax

/// A6: cross-checks each rename's edit position against the compiler's occurrence set (USR ground
/// truth) and reports the symbols whose renames must be reverted. This catches the DANGEROUS
/// cross-target wrong-rename class — we are about to edit a position the compiler attributes to a
/// symbol in a *different module* — which RollbackPass canNOT catch (a wrong rename leaves no
/// surviving original name to detect).
///
/// Deliberately high-precision and fail-closed: it flags ONLY when the index positively disagrees
/// on the defining MODULE at an edit position. When the index records no occurrence at an edit
/// (memberwise-init label edits, synthesized insertions), or the USR differs only *within the same
/// module* (e.g. a constructor's `init`-vs-type USR), it does NOT flag — a false-positive revert
/// would crater coverage for no safety gain. Within-module mis-resolution is out of scope (rare;
/// the syntactic resolver is reliable inside one module). Same-named cross-target types — the class
/// this exists for — are always in distinct modules, so the module check pins them exactly.
public final class IndexValidator {
    let usrIndex: USRIndex
    let usrBySymbolId: [Int: String]
    let logger: Logger
    private let symbolsById: [Int: Symbol]

    public init(table: SymbolTable, usrIndex: USRIndex, usrBySymbolId: [Int: String], logger: Logger) {
        self.usrIndex = usrIndex
        self.usrBySymbolId = usrBySymbolId
        self.logger = logger
        var byId: [Int: Symbol] = [:]
        for s in table.symbols { byId[s.id] = s }
        self.symbolsById = byId
    }

    /// Symbol ids whose renames the compiler contradicts (an edit lands on a different-module
    /// symbol). The caller drops every rename targeting these ids and reverts them in the map.
    public func findDesyncs(in renames: [Rename]) -> Set<Int> {
        var converters: [ObjectIdentifier: SourceLocationConverter] = [:]
        var paths: [ObjectIdentifier: String] = [:]
        var bad: Set<Int> = []

        for r in renames {
            guard r.targetSymbolId >= 0, r.length > 0 else { continue }  // skip inserts / non-symbol edits
            guard let sym = symbolsById[r.targetSymbolId],
                  let symUSR = usrBySymbolId[sym.id] else { continue }    // no USR ⇒ A5 should have gated
            if bad.contains(sym.id) { continue }

            let key = ObjectIdentifier(r.file)
            let converter: SourceLocationConverter
            if let c = converters[key] {
                converter = c
            } else {
                converter = SourceLocationConverter(fileName: r.file.url.path, tree: r.file.syntax)
                converters[key] = converter
                paths[key] = USRIndex.normalize(r.file.url.path)
            }
            let path = paths[key]!
            let loc = converter.location(for: AbsolutePosition(utf8Offset: r.offset))
            guard let idxUSR = usrIndex.usr(atFile: path, line: loc.line, column: loc.column) else {
                continue  // compiler records nothing here → conservative, don't flag
            }
            if idxUSR == symUSR { continue }  // exact agreement
            // USRs differ — only a POSITIVE cross-module disagreement is a wrong rename. Compare the
            // REAL module of each USR (both from the index), NEVER `sym.module.name`: that is the
            // arbitrary `--module` label, which need not match the compiled module name (e.g.
            // `--module App:./Pulse/...` → real module "Pulse"). Comparing real-vs-real avoids
            // false-reverting every rename in a mislabeled module. If either module is unknown,
            // don't flag (fail-closed → keep the rename, A4/syntax stand).
            guard let symMod = usrIndex.module(ofUSR: symUSR),
                  let idxMod = usrIndex.module(ofUSR: idxUSR) else { continue }
            if idxMod != symMod {
                bad.insert(sym.id)
                logger.log("A6 desync: \(symMod) symbol edited at "
                    + "\(path):\(loc.line):\(loc.column) — compiler attributes it to module \(idxMod); reverting")
            }
        }
        return bad
    }
}
