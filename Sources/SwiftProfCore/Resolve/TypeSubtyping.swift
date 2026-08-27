import Foundation

/// "Is the LOCAL type `subName` a subtype of the LOCAL type `superName`" — equal, a subclass, or a
/// conformer of a protocol. Built on the two chains that already model the hierarchy
/// (`SuperclassChain` for classes, `ConformanceChain` for protocols), so there is one view of
/// subtyping and no third private copy of a chain walk.
///
/// LOCAL-only by design: an external hierarchy (UIKit class tree, an ObjC protocol) is not in our
/// table, so `isSubtype` answers `false` for any name that does not resolve to a local type — the
/// caller must treat external/unresolvable types separately (textual equality or a wildcard), NEVER
/// guessing a hierarchy we cannot see. Getting that wrong in the "too permissive" direction is a
/// wrong rename no safety net catches, so absence of knowledge is `false` here.
///
/// The one consumer today is the Protector's unknown-external protect-all exemption (B-FIX-91): a
/// method witness may return a SUBTYPE of the local requirement's return (covariant witness —
/// `func make() -> Dog` legally witnesses `func make() -> Animal`), so it must still be exempted;
/// this is what tells such a covariant witness apart from a genuinely-different return (the external
/// @objc witness) without over-protecting the former.
public enum TypeSubtyping {
    public static func isSubtype(_ subName: String, inScope subScope: Scope?, module subModule: String,
                                 of superName: String, inScope superScope: Scope?, module superModule: String,
                                 in table: SymbolTable) -> Bool {
        guard let subScope, let superScope,
              let sub = resolve(subName, in: subScope, module: subModule, table: table),
              let sup = resolve(superName, in: superScope, module: superModule, table: table)
        else { return false }
        if sub.id == sup.id { return true }
        if SuperclassChain.ancestors(of: sub, in: table).contains(where: { $0.id == sup.id }) { return true }
        if ConformanceChain.protocols(of: sub, in: table).contains(where: { $0.id == sup.id }) { return true }
        return false
    }

    private static func resolve(_ name: String, in scope: Scope, module: String, table: SymbolTable) -> Symbol? {
        TypeResolver(table: table, preferredModule: module).typeSymbol(forQualifiedName: name, in: scope)
    }
}
