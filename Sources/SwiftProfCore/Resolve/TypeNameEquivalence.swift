import Foundation

/// Do two WRITTEN type-name strings denote the SAME type? (B-FIX-27)
///
/// Signature matching (WitnessLinker, OverrideLinker) compares parameter types that were recorded
/// as the text the author wrote, in two DIFFERENT lexical positions — a protocol requirement and
/// its witness, a base method and its override. The same type is routinely written differently on
/// the two sides: bare vs qualified (`Inner` / `Outer.Inner`), or through a typealias
/// (`typealias T1 = E3.S2.E1`).
///
/// **Invariant: two written type names denote the same type when they match STRUCTURALLY — the
/// composite wrappers (optional / array / dictionary) peel identically on both sides and each LEAF
/// resolves to the same Symbol (typealias-unwrapped) — never by comparing the whole string.**
///
/// Why this exists: the leaf resolver (`TypeResolver.typeSymbol(forQualifiedName:)`) refuses any
/// name carrying a top-level `:` (a dictionary is not a nameable Symbol), so handing it the WHOLE
/// string `[T1: E3.S4]` returned nil and the caller concluded "different type" — the typealias
/// unwrap that lives further down that function was never reached. A witness with a dictionary
/// parameter therefore never linked to its requirement, both sides minted their own obf, and the
/// conformance broke ("does not conform to protocol") — a wrong-rename red RollbackPass cannot
/// catch, since no original name survives.
///
/// Fail-closed and strictly ADDITIVE: the whole-name resolve is tried FIRST (so everything that
/// matched before still matches, including a typealias whose target is itself composite —
/// `typealias Items = [Item]` vs `[Item]`), and the structural decomposition only ADDS matches for
/// same-shaped composites. Anything else stays "different", because a false MATCH is the dangerous
/// direction: it collapses two genuine overloads onto one obf ⇒ "invalid redeclaration".
enum TypeNameEquivalence {

    /// `a` written at `scopeA` (module `moduleA`) and `b` written at `scopeB` (module `moduleB`).
    /// Each side resolves in its OWN declaring scope — a nested type written unqualified is only
    /// visible from where it was written (B-FIX-23 discipline).
    static func sameType(_ a: String, inScope scopeA: Scope?, module moduleA: String,
                         _ b: String, inScope scopeB: Scope?, module moduleB: String,
                         table: SymbolTable, depth: Int = 0) -> Bool {
        let na = normalize(a)
        let nb = normalize(b)
        if na == nb { return true }
        guard depth < 8 else { return false }   // pathological/cyclic alias chain — fail closed

        // 1. Whole-name resolve: handles bare-vs-qualified, typealias-to-a-NAMED-type unwrap, and
        //    generic-base stripping (`Box<Int>` → `Box`).
        if let sa = resolve(na, in: scopeA, module: moduleA, table: table),
           let sb = resolve(nb, in: scopeB, module: moduleB, table: table),
           sa.id == sb.id {
            return true
        }

        // 2. Structural: only when BOTH sides carry the SAME composite shape. Recursion lands on
        //    leaves, which go through the resolve above.
        switch (shape(of: na), shape(of: nb)) {
        case let (.array(ea), .array(eb)):
            return sameType(ea, inScope: scopeA, module: moduleA,
                            eb, inScope: scopeB, module: moduleB, table: table, depth: depth + 1)
        case let (.dictionary(ka, va), .dictionary(kb, vb)):
            return sameType(ka, inScope: scopeA, module: moduleA,
                            kb, inScope: scopeB, module: moduleB, table: table, depth: depth + 1)
                && sameType(va, inScope: scopeA, module: moduleA,
                            vb, inScope: scopeB, module: moduleB, table: table, depth: depth + 1)
        default:
            break
        }

        // 3. A LEAF may be a typealias whose TARGET is composite (`typealias Items = [Item]` against
        //    a spelled-out `[Item]`): the shapes disagree, and `unwrapTypealias` cannot bridge them
        //    because a collection name resolves to no Symbol (B-FIX-28). Expand the alias TEXTUALLY
        //    and retry. Each expansion changes the string and `depth` bounds the chain.
        if let ea = aliasTarget(of: na, in: scopeA, module: moduleA, table: table), ea != na {
            return sameType(ea, inScope: scopeA, module: moduleA,
                            nb, inScope: scopeB, module: moduleB, table: table, depth: depth + 1)
        }
        if let eb = aliasTarget(of: nb, in: scopeB, module: moduleB, table: table), eb != nb {
            return sameType(na, inScope: scopeA, module: moduleA,
                            eb, inScope: scopeB, module: moduleB, table: table, depth: depth + 1)
        }
        return false
    }

    /// The written target of a typealias named `name`, or nil when `name` doesn't name a typealias.
    private static func aliasTarget(of name: String, in scope: Scope?, module: String,
                                    table: SymbolTable) -> String? {
        guard let sym = resolve(name, in: scope, module: module, table: table),
              sym.kind == .typealias_ else { return nil }
        return table.typealiasTarget[sym.id]
    }

    // MARK: - Internals

    private enum Shape {
        case array(String)
        case dictionary(String, String)
        case leaf
    }

    /// Both sugar and generic spellings, so `[K: V]` and `Dictionary<K, V>` compare equal.
    private static func shape(of name: String) -> Shape {
        if name.hasPrefix("[") && name.hasSuffix("]") {
            let inner = String(name.dropFirst().dropLast())
            if let idx = TypeResolver.topLevelIndex(of: ":", in: inner) {
                let k = String(inner[..<idx]).trimmingCharacters(in: .whitespaces)
                let v = String(inner[inner.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
                return (k.isEmpty || v.isEmpty) ? .leaf : .dictionary(k, v)
            }
            let e = inner.trimmingCharacters(in: .whitespaces)
            return e.isEmpty ? .leaf : .array(e)
        }
        if let inner = genericArguments(of: name, base: "Dictionary"),
           let idx = TypeResolver.topLevelIndex(of: ",", in: inner) {
            let k = String(inner[..<idx]).trimmingCharacters(in: .whitespaces)
            let v = String(inner[inner.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            return (k.isEmpty || v.isEmpty) ? .leaf : .dictionary(k, v)
        }
        if let inner = genericArguments(of: name, base: "Array"),
           TypeResolver.topLevelIndex(of: ",", in: inner) == nil {
            let e = inner.trimmingCharacters(in: .whitespaces)
            return e.isEmpty ? .leaf : .array(e)
        }
        return .leaf
    }

    /// `Dictionary<K, V>` + base `"Dictionary"` → `"K, V"`; nil when the name isn't that generic.
    private static func genericArguments(of name: String, base: String) -> String? {
        let prefix = "\(base)<"
        guard name.hasPrefix(prefix), name.hasSuffix(">") else { return nil }
        return String(name.dropFirst(prefix.count).dropLast())
    }

    private static func normalize(_ s: String) -> String {
        var n = s.trimmingCharacters(in: .whitespaces)
        while n.hasSuffix("?") || n.hasSuffix("!") {
            n = String(n.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return n
    }

    private static func resolve(_ name: String, in scope: Scope?, module: String,
                                table: SymbolTable) -> Symbol? {
        guard let scope else { return nil }
        return TypeResolver(table: table, preferredModule: module)
            .typeSymbol(forQualifiedName: name, in: scope)
    }
}
