import SwiftSyntax

/// A protocol/class COMPOSITION type (`A & B`, e.g. `LocalProto & UIViewController`). Like a tuple
/// (B-FIX-78), `WrittenTypeName.of` deliberately returns nil for it — a composition string in
/// `declaredType` / `functionParamTypes` would reach witness linking and overload disambiguation,
/// whose nil-as-wildcard semantics it must not disturb (B-FIX-27) — so a composition is carried
/// SEPARATELY (a binding's flow-sensitive type, or `SymbolTable.compositionDeclaredType`) and read
/// ONLY by member resolution, which tries each component (B-FIX-93).
///
/// The canonical string is the components joined by " & " (each reduced through `WrittenTypeName.of`,
/// so `some P & AnyObject` → "P & AnyObject"); member resolution splits it back with `components(_:)`.
enum CompositionTypeName {
    /// "A & B & …" for a `CompositionTypeSyntax`, else nil. Fewer than two resolvable components → nil
    /// (a lone element is not a composition).
    static func of(_ type: TypeSyntax) -> String? {
        var t = type
        var changed = true
        while changed {
            changed = false
            if let attr = t.as(AttributedTypeSyntax.self) { t = attr.baseType; changed = true }
            if let opt = t.as(OptionalTypeSyntax.self) { t = opt.wrappedType; changed = true }
        }
        guard let comp = t.as(CompositionTypeSyntax.self) else { return nil }
        let names = comp.elements.compactMap { WrittenTypeName.of($0.type) }
        return names.count >= 2 ? names.joined(separator: " & ") : nil
    }

    /// The component names of a stored "A & B" string, else nil when `name` is not a composition.
    static func components(_ name: String) -> [String]? {
        guard name.contains(" & ") else { return nil }
        let parts = name.components(separatedBy: " & ").map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.count >= 2 && !parts.contains(where: \.isEmpty) ? parts : nil
    }
}
