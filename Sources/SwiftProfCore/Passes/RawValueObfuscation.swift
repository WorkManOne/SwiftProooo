import Foundation
import SwiftSyntax

/// Mode for the raw-value obfuscation preprocessing pass.
public enum RawValueMode: String, CaseIterable {
    /// Disabled (default). The pass does nothing.
    case off
    /// Obfuscate only String-raw enums that do NOT conform to Codable/Decodable/Encodable, and
    /// only cases that have an EXPLICIT string literal (`case x = "…"`). Conservative — avoids
    /// touching serialized enums and never materializes implicit raw values.
    case safe
    /// Obfuscate every String-raw enum, including Codable conformers and cases with implicit raw
    /// values (rawValue == case name, which is materialized as `case x = "<obf>"`). Maximum
    /// coverage — the caller takes responsibility for serialization/storage compatibility.
    case all
}

/// Info for one eligible enum, gathered from the syntax tree.
private struct EnumInfo {
    let symbolId: Int
    let name: String
    unowned let file: SourceFile
    let node: EnumDeclSyntax
    /// (case name, original raw value, explicit-literal node or nil for implicit).
    let cases: [(name: String, original: String, literal: StringLiteralExprSyntax?)]
}

/// Preprocessing pass (runs BEFORE the main obfuscation pipeline) that hides the human-readable
/// raw values of String-backed enums.
///
/// Raw values live in the binary as *metadata* that the binary string-obfuscator (OMVLL) does
/// NOT touch. So `case whiskey = "Виски"` leaks "Виски" into the shipped app. This pass:
///
///   1. Replaces each case's raw literal with an opaque token (`case whiskey = "w1"`).
///   2. Adds a `displayName` computed property that returns the ORIGINAL strings — these live in
///      normal code, which OMVLL *does* obfuscate well.
///   3. Rewrites resolvable `.rawValue` use-sites to `.displayName`, so code that needs the
///      original value still gets it.
///
/// It text-rewrites `file.contents` in place; the main pipeline then re-parses the transformed
/// source as ordinary input (and may further rename the enum/cases/displayName).
public final class RawValueObfuscationPass {
    public let table: SymbolTable
    public let mode: RawValueMode
    public let debugNames: Bool
    public let logger: Logger
    private let displayName = "displayName"

    public init(table: SymbolTable, mode: RawValueMode, debugNames: Bool, logger: Logger) {
        self.table = table
        self.mode = mode
        self.debugNames = debugNames
        self.logger = logger
    }

    public func run(on files: [SourceFile]) {
        guard mode != .off else { return }

        // 1. Enum-side: find eligible enums.
        var infos: [EnumInfo] = []
        for file in files where file.module.writable {
            let collector = EnumCollector(table: table, mode: mode, displayName: displayName, file: file)
            collector.walk(file.syntax)
            infos.append(contentsOf: collector.found)
        }
        guard !infos.isEmpty else {
            logger.log("rawValue: no eligible enums (mode \(mode.rawValue))")
            return
        }
        let eligibleIds = Set(infos.map { $0.symbolId })
        let eligibleNames = Set(infos.map { $0.name })

        // 2. Use-site scan: collect rewrite edits per enum, AND classify any `.rawValue` site we
        //    CANNOT rewrite. B-FIX-3 (fail closed): if an eligible enum has a `.rawValue` use we
        //    can't redirect to `.displayName`, that use would return the OPAQUE token at runtime —
        //    a silent behaviour change. So drop that enum's obfuscation entirely. When a `.rawValue`
        //    base type is wholly unresolvable, it could be ANY eligible enum → drop them all.
        var rewriteEditsByEnum: [Int: [Rename]] = [:]
        var dangerousNames: Set<String> = []
        var hasUnknownBase = false
        for file in files where file.module.writable {
            guard let fileScope = table.fileScopes[ObjectIdentifier(file)] else { continue }
            let visitor = RawValueUseVisitor(
                file: file, table: table, fileScope: fileScope,
                eligibleEnumIds: eligibleIds, eligibleEnumNames: eligibleNames, displayName: displayName
            )
            visitor.walk(file.syntax)
            for (id, edits) in visitor.rewriteEditsByEnum {
                rewriteEditsByEnum[id, default: []].append(contentsOf: edits)
            }
            dangerousNames.formUnion(visitor.dangerousNames)
            if visitor.hasUnknownBase { hasUnknownBase = true }
        }

        // 3. Decide which eligible enums to abort.
        let abortedIds: Set<Int>
        if hasUnknownBase {
            abortedIds = eligibleIds
        } else {
            abortedIds = Set(infos.filter { dangerousNames.contains($0.name) }.map { $0.symbolId })
        }
        if !abortedIds.isEmpty {
            logger.log("rawValue: aborted \(abortedIds.count) enum(s) — unresolvable .rawValue use-site (fail closed)")
        }

        // 4. Build enum-side + use-site edits for the SURVIVING enums only.
        var editsByFile: [ObjectIdentifier: [Rename]] = [:]
        var rawGen = RawTokenGenerator(debug: debugNames)
        var enumCount = 0
        var rewrittenUses = 0
        for info in infos where !abortedIds.contains(info.symbolId) {
            enumCount += 1
            editsByFile[ObjectIdentifier(info.file), default: []]
                .append(contentsOf: makeEnumEdits(info, file: info.file, gen: &rawGen))
            for edit in rewriteEditsByEnum[info.symbolId] ?? [] {
                editsByFile[ObjectIdentifier(edit.file), default: []].append(edit)
                rewrittenUses += 1
            }
        }
        guard enumCount > 0 else {
            logger.log("rawValue: all eligible enums aborted (mode \(mode.rawValue))")
            return
        }

        // 5. Apply all edits and persist to disk so the main pipeline re-parses the result.
        let rewriter = Rewriter(logger: logger)
        var touched: [SourceFile] = []
        for file in files where file.module.writable {
            if let edits = editsByFile[ObjectIdentifier(file)], !edits.isEmpty {
                rewriter.apply(edits)
                touched.append(file)
            }
        }
        do {
            try rewriter.writeToDisk(touched)
        } catch {
            logger.log("rawValue: failed to write \(touched.count) files: \(error)")
        }
        logger.log("rawValue: obfuscated \(enumCount) enums, rewrote \(rewrittenUses) .rawValue use-sites (mode \(mode.rawValue))")
    }

    // MARK: - Enum-side edits

    private func makeEnumEdits(_ info: EnumInfo, file: SourceFile, gen: inout RawTokenGenerator) -> [Rename] {
        var edits: [Rename] = []
        var caseToOriginal: [(name: String, original: String)] = []

        for c in info.cases {
            let token = gen.next()
            caseToOriginal.append((name: c.name, original: c.original))
            if let lit = c.literal {
                // Replace the existing string-literal expression with "<token>".
                let off = lit.positionAfterSkippingLeadingTrivia.utf8Offset
                let len = lit.trimmedLength.utf8Length
                edits.append(Rename(file: file, offset: off, length: len,
                                    original: c.original, replacement: "\"\(token)\""))
            } else if let anchor = caseNameToken(named: c.name, in: info.node) {
                // Implicit raw value (mode .all) — materialize `= "<token>"` after the case name.
                let off = anchor.endPositionBeforeTrailingTrivia.utf8Offset
                edits.append(Rename(file: file, offset: off, length: 0,
                                    original: "", replacement: " = \"\(token)\""))
            }
        }

        // Insert the displayName property just before the enum's closing brace.
        let brace = info.node.memberBlock.rightBrace
        let insertOff = brace.positionAfterSkippingLeadingTrivia.utf8Offset
        edits.append(Rename(file: file, offset: insertOff, length: 0,
                            original: "", replacement: buildDisplayName(caseToOriginal)))
        return edits
    }

    private func buildDisplayName(_ cases: [(name: String, original: String)]) -> String {
        var s = "\n    var \(displayName): String {\n        switch self {\n"
        for c in cases {
            s += "        case .\(c.name): return \"\(escape(c.original))\"\n"
        }
        s += "        }\n    }\n    "
        return s
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func caseNameToken(named name: String, in node: EnumDeclSyntax) -> TokenSyntax? {
        for member in node.memberBlock.members {
            guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
            for elem in caseDecl.elements where Self.strip(elem.name.text) == name {
                return elem.name
            }
        }
        return nil
    }

    fileprivate static func strip(_ s: String) -> String {
        guard s.count >= 2, s.hasPrefix("`"), s.hasSuffix("`") else { return s }
        return String(s.dropFirst().dropLast())
    }
}

// MARK: - Short opaque raw-value token generator

private struct RawTokenGenerator {
    let debug: Bool
    private var counter = 0
    private var used = Set<String>()
    private static let alpha = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

    init(debug: Bool) { self.debug = debug }

    mutating func next() -> String {
        if debug {
            defer { counter += 1 }
            return "rv\(counter)"
        }
        while true {
            var s = ""
            for _ in 0..<6 { s.append(Self.alpha.randomElement()!) }
            if used.insert(s).inserted { return s }
        }
    }
}

// MARK: - Eligible-enum collector

private final class EnumCollector: SyntaxVisitor {
    let table: SymbolTable
    let mode: RawValueMode
    let displayName: String
    unowned let file: SourceFile
    var found: [EnumInfo] = []

    init(table: SymbolTable, mode: RawValueMode, displayName: String, file: SourceFile) {
        self.table = table
        self.mode = mode
        self.displayName = displayName
        self.file = file
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        if let info = eligible(node) { found.append(info) }
        return .visitChildren  // allow nested enums
    }

    private func eligible(_ node: EnumDeclSyntax) -> EnumInfo? {
        guard let inherited = node.inheritanceClause?.inheritedTypes else { return nil }
        let names = Set(inherited.compactMap { $0.type.as(IdentifierTypeSyntax.self)?.name.text })
        // Raw type must be String (we only handle String-backed enums).
        guard names.contains("String") else { return nil }
        // safe mode: skip serialized enums.
        if mode == .safe, !Set(["Codable", "Decodable", "Encodable"]).isDisjoint(with: names) {
            return nil
        }
        // Skip if a `displayName` member already exists (avoid redeclaration).
        for member in node.memberBlock.members {
            if let v = member.decl.as(VariableDeclSyntax.self) {
                for b in v.bindings where b.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == displayName {
                    return nil
                }
            }
        }
        guard let sym = table.innerScope[node.id]?.owner, sym.kind == .enum else { return nil }
        let enumName = sym.name

        var cases: [(name: String, original: String, literal: StringLiteralExprSyntax?)] = []
        for member in node.memberBlock.members {
            guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
            for elem in caseDecl.elements {
                if elem.parameterClause != nil { return nil }  // not a raw-value enum
                let name = RawValueObfuscationPass.strip(elem.name.text)
                if let lit = elem.rawValue?.value.as(StringLiteralExprSyntax.self),
                   let original = lit.representedLiteralValue {
                    cases.append((name, original, lit))
                } else if elem.rawValue != nil {
                    return nil  // non-string-literal raw value (interpolation, #-literal) — skip
                } else {
                    if mode == .safe { continue }  // implicit: only obfuscated in .all
                    cases.append((name, name, nil))
                }
            }
        }
        guard !cases.isEmpty else { return nil }
        return EnumInfo(symbolId: sym.id, name: enumName, file: file, node: node, cases: cases)
    }
}

// MARK: - `.rawValue` use-site rewriter (scope-aware)

private final class RawValueUseVisitor: SyntaxVisitor {
    let file: SourceFile
    let table: SymbolTable
    let eligibleEnumIds: Set<Int>
    let eligibleEnumNames: Set<String>
    let displayName: String
    let typeResolver: TypeResolver
    var scopeStack: [Scope]
    /// `.rawValue` → `.displayName` edits, keyed by the eligible enum they belong to. The pass drops
    /// edits for enums it decides to abort.
    var rewriteEditsByEnum: [Int: [Rename]] = [:]
    /// Eligible enum NAMES whose `.rawValue` we saw used but could NOT rewrite (resolved to that
    /// name but not as a precise Symbol). Those enums must be aborted (B-FIX-3).
    var dangerousNames: Set<String> = []
    /// A `.rawValue` use whose base type is wholly unresolvable — could be any eligible enum.
    var hasUnknownBase = false

    init(file: SourceFile, table: SymbolTable, fileScope: Scope,
         eligibleEnumIds: Set<Int>, eligibleEnumNames: Set<String>, displayName: String) {
        self.file = file
        self.table = table
        self.eligibleEnumIds = eligibleEnumIds
        self.eligibleEnumNames = eligibleEnumNames
        self.displayName = displayName
        self.typeResolver = TypeResolver(table: table, preferredModule: file.module.name)
        self.scopeStack = [fileScope]
        super.init(viewMode: .sourceAccurate)
    }

    private var currentScope: Scope { scopeStack.last! }
    private func enter(_ node: some SyntaxProtocol) { if let s = table.innerScope[node.id] { scopeStack.append(s) } }
    private func exit(_ node: some SyntaxProtocol) { if table.innerScope[node.id] != nil { scopeStack.removeLast() } }

    override func visit(_ n: ClassDeclSyntax) -> SyntaxVisitorContinueKind { enter(n); return .visitChildren }
    override func visitPost(_ n: ClassDeclSyntax) { exit(n) }
    override func visit(_ n: StructDeclSyntax) -> SyntaxVisitorContinueKind { enter(n); return .visitChildren }
    override func visitPost(_ n: StructDeclSyntax) { exit(n) }
    override func visit(_ n: EnumDeclSyntax) -> SyntaxVisitorContinueKind { enter(n); return .visitChildren }
    override func visitPost(_ n: EnumDeclSyntax) { exit(n) }
    override func visit(_ n: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind { enter(n); return .visitChildren }
    override func visitPost(_ n: ProtocolDeclSyntax) { exit(n) }
    override func visit(_ n: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind { enter(n); return .visitChildren }
    override func visitPost(_ n: ExtensionDeclSyntax) { exit(n) }
    override func visit(_ n: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { enter(n); return .visitChildren }
    override func visitPost(_ n: FunctionDeclSyntax) { exit(n) }
    override func visit(_ n: InitializerDeclSyntax) -> SyntaxVisitorContinueKind { enter(n); return .visitChildren }
    override func visitPost(_ n: InitializerDeclSyntax) { exit(n) }
    override func visit(_ n: ClosureExprSyntax) -> SyntaxVisitorContinueKind { enter(n); return .visitChildren }
    override func visitPost(_ n: ClosureExprSyntax) { exit(n) }
    // The remaining block scopes (`ScopeNodes.kinds`). A mirror that skips one resolves a base
    // declared under it against an outer same-named symbol instead of the local binding.
    override func visit(_ n: SwitchCaseSyntax) -> SyntaxVisitorContinueKind { enter(n); return .visitChildren }
    override func visitPost(_ n: SwitchCaseSyntax) { exit(n) }
    override func visit(_ n: CatchClauseSyntax) -> SyntaxVisitorContinueKind { enter(n); return .visitChildren }
    override func visitPost(_ n: CatchClauseSyntax) { exit(n) }
    override func visit(_ n: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind { enter(n); return .visitChildren }
    override func visitPost(_ n: SubscriptDeclSyntax) { exit(n) }
    override func visit(_ n: ActorDeclSyntax) -> SyntaxVisitorContinueKind { enter(n); return .visitChildren }
    override func visitPost(_ n: ActorDeclSyntax) { exit(n) }
    override func visit(_ n: CodeBlockSyntax) -> SyntaxVisitorContinueKind { enter(n); return .visitChildren }
    override func visitPost(_ n: CodeBlockSyntax) { exit(n) }

    override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        guard strip(node.declName.baseName.text) == "rawValue", let base = node.base else {
            return .visitChildren
        }
        if let typeSym = eligibleEnumType(of: base) {
            // Base resolved to a concrete type Symbol.
            if eligibleEnumIds.contains(typeSym.id) {
                let off = node.declName.baseName.positionAfterSkippingLeadingTrivia.utf8Offset
                let len = node.declName.baseName.trimmedLength.utf8Length
                rewriteEditsByEnum[typeSym.id, default: []].append(
                    Rename(file: file, offset: off, length: len,
                           original: "rawValue", replacement: displayName))
            }
            // else: resolved to a non-eligible type → its raw values are untouched → safe.
        } else if let typeName = baseTypeName(of: base) {
            // Type name known but no precise Symbol. Dangerous only if it names an eligible enum:
            // its literals changed but this site won't be rewritten.
            if eligibleEnumNames.contains(typeName) { dangerousNames.insert(typeName) }
            // else external/other type → safe.
        } else {
            // Wholly unresolvable base — could be any eligible enum.
            hasUnknownBase = true
        }
        return .visitChildren
    }

    /// Resolve the static enum type of `base`, covering `EnumName.case` directly (TypeResolver
    /// doesn't follow an enum-case member to its enum) plus any value whose type TypeResolver can
    /// determine (var/param/property typed as the enum, `self`, etc.).
    private func eligibleEnumType(of base: ExprSyntax) -> Symbol? {
        if let m = base.as(MemberAccessExprSyntax.self), let inner = m.base,
           let typeSym = bareTypeSymbol(of: inner), eligibleEnumIds.contains(typeSym.id) {
            return typeSym  // `EnumName.case`
        }
        return typeResolver.typeSymbol(of: base, in: currentScope)
    }

    /// Best-effort STATIC TYPE NAME of a `.rawValue` base, used only to classify danger when the
    /// precise Symbol resolution failed. Returns nil for shapes whose type we can't read off the
    /// syntax (calls, casts, subscripts, tuples, literals) — those are the "unknown base" case.
    private func baseTypeName(of expr: ExprSyntax) -> String? {
        var e = expr
        if let opt = e.as(OptionalChainingExprSyntax.self) { e = opt.expression }
        if let force = e.as(ForceUnwrapExprSyntax.self) { e = force.expression }
        if let tryE = e.as(TryExprSyntax.self) { e = tryE.expression }
        if let awaitE = e.as(AwaitExprSyntax.self) { e = awaitE.expression }
        if let ref = e.as(DeclReferenceExprSyntax.self) {
            var n = strip(ref.baseName.text)
            if n.hasPrefix("$") || n.hasPrefix("_") { n = String(n.dropFirst()) }
            if n == "self" || n == "Self" { return TypeResolver.enclosingTypeScope(of: currentScope)?.owner?.name }
            if let s = currentScope.lookup(name: n, at: ref.positionAfterSkippingLeadingTrivia.utf8Offset) {
                return s.kind.isTypeLike ? s.name : table.declaredType[s.id]
            }
            return typeResolver.resolveType(named: n)?.name
        }
        if let m = e.as(MemberAccessExprSyntax.self), let b = m.base {
            // `EnumName.case` → the enum's name.
            if let bt = bareTypeSymbol(of: b) { return bt.name }
            // `obj.prop` → prop's declared type name.
            let memberName = strip(m.declName.baseName.text)
            if let recv = typeResolver.typeSymbol(of: b, in: currentScope),
               let inner = typeResolver.canonicalInnerScope(of: recv),
               let mem = inner.member(named: memberName) {
                return mem.kind.isTypeLike ? mem.name : table.declaredType[mem.id]
            }
            return nil
        }
        return nil
    }

    private func bareTypeSymbol(of expr: ExprSyntax) -> Symbol? {
        guard let ref = expr.as(DeclReferenceExprSyntax.self) else { return nil }
        let name = strip(ref.baseName.text)
        if let s = currentScope.lookup(name: name), s.kind.isTypeLike { return s }
        return typeResolver.resolveType(named: name)
    }

    private func strip(_ s: String) -> String {
        guard s.count >= 2, s.hasPrefix("`"), s.hasSuffix("`") else { return s }
        return String(s.dropFirst().dropLast())
    }
}
