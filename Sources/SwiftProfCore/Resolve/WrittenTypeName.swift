import SwiftSyntax

/// The single reducer from WRITTEN type syntax to the type-name STRING the table stores and the
/// resolver parses. Every `declaredType` / `functionParamTypes` / `functionReturnType` /
/// `enumCaseAssociatedTypes` entry is produced here, and so is the type of an annotated optional
/// binding (B-FIX-35), which lives outside the table.
///
/// It used to be private to `DeclarationPass`'s visitor. It moved here when a second pass needed it:
/// duplicating the reduction would let the two copies drift, and a name string produced by a
/// slightly different reducer is read by consumers that assume this one's exact output shape.
///
/// Every string it returns is relative to the scope it was WRITTEN in and must be resolved there,
/// never at a use-site (B-FIX-23) — `Foo.Bar` keeps its qualification precisely so that a consumer
/// holding the declaring scope can walk it.
enum WrittenTypeName {
    /// Cheap textual representation of a declared type.
    /// - `Foo`              → "Foo"
    /// - `Foo?` / `Foo??`   → "Foo" (optionals are unwrapped)
    /// - `Array<Foo>`       → "Array<Foo>"
    /// - `[Foo]`            → "[Foo]"
    /// - `Foo.Bar`          → "Foo.Bar" (qualification preserved)
    /// - tuples / functions / composition → nil (not modelled)
    static func of(_ type: TypeSyntax) -> String? {
        var t = type
        // Peel attribute (`@escaping (X)->Y`), `inout`, and opaque/existential wrappers
        // (`some P` / `any P`) so `r: some Renderer` types `r` as `Renderer` and its members
        // resolve. Repeated because they can nest (`inout some P`).
        var changed = true
        while changed {
            changed = false
            if let attr = t.as(AttributedTypeSyntax.self) { t = attr.baseType; changed = true }
            if let opaque = t.as(SomeOrAnyTypeSyntax.self) { t = opaque.constraint; changed = true }
            if let opt = t.as(OptionalTypeSyntax.self) { t = opt.wrappedType; changed = true }
        }
        if let ident = t.as(IdentifierTypeSyntax.self) {
            if ident.genericArgumentClause == nil { return ident.name.text }
            return ident.trimmedDescription
        }
        if let arr = t.as(ArrayTypeSyntax.self) {
            return "[\(arr.element.trimmedDescription)]"
        }
        // `[K: V]` — keep the dictionary form so a subscript on it (`dict[k]`) can extract the Value
        // type. Consumers that only understand arrays bail on the `:` (extractElement,
        // typeSymbol(forQualifiedName:)) — which is NOT automatically harmless: a consumer that
        // treats a nil entry as a WILDCARD reads this string as "a type I can't resolve" and flips
        // from "matches anything" to "matches nothing". That is exactly how witness linking broke
        // into a red build (B-FIX-27); signature comparison now decomposes the form structurally
        // (`TypeNameEquivalence.sameType`). Check nil semantics at EVERY consumer before widening
        // what this function returns.
        if let dict = t.as(DictionaryTypeSyntax.self) {
            return "[\(dict.key.trimmedDescription): \(dict.value.trimmedDescription)]"
        }
        // `Foo.Bar` — store full qualified text; TypeResolver walks dotted names.
        if let member = t.as(MemberTypeSyntax.self) {
            return member.trimmedDescription
        }
        return nil
    }
}
