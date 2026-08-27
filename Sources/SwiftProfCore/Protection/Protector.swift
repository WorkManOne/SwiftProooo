import Foundation
import SwiftSyntax

/// How much of the Objective-C runtime's name sensitivity to assume. Only protections that exist
/// BECAUSE of the ObjC runtime answer to this setting; everything else the Protector does (Codable
/// keys, property wrappers, raw enums, operators, protocol conformances) is unaffected.
public enum ObjCProtectionMode: String, CaseIterable {
    /// Default. A class is name-sensitive if it or any ancestor is annotated `@objc`-ish OR descends
    /// from an ObjC root (`NSObject`, `UIView`, …), and every member of such a class is protected.
    /// On a UIKit project that is nearly every class, so it is also where most over-protection sits.
    case strict
    /// Protect members only where the exposure is DECLARED — an explicit `@objc` / `@objcMembers` /
    /// `@IBDesignable` class, an exposing attribute on the member, a `#selector` reference, an
    /// `@objc extension`, or an `NSManagedObject` descendant (Core Data binds by name). A class
    /// tainted purely by its ancestry keeps its NAME protected (a storyboard `customClass` is a
    /// string) while its members become renameable. Since SE-0160 an unannotated member of an
    /// NSObject subclass is not visible to the ObjC runtime at all, which is what makes this safe;
    /// what it does NOT cover is name-based reflection the compiler cannot see (KVC string keys,
    /// `value(forKey:)`, hand-built selector strings that never appear as `#selector`).
    case relaxed
    /// Drop every ObjC-motivated protection, including exposing attributes, `#selector` names,
    /// `@objc` classes and `NSManagedObject`. For projects with no Objective-C name dependency at
    /// all. Not for a project with Core Data or storyboards.
    case off
}

/// Marks symbols that must never be renamed. Each protection records WHY (a short reason),
/// surfaced in the coverage report so users see which decisions reduced renaming.
public final class Protector {
    public let table: SymbolTable
    public let logger: Logger
    public let stdlibRegistry: StdlibRegistry
    /// How much ObjC-runtime name sensitivity to assume (`--objc-protection`).
    public let objcProtection: ObjCProtectionMode
    /// id → human-readable reason. Presence in this map = protected.
    public private(set) var reasonForId: [Int: String] = [:]

    /// External protocol names this pass MENTIONED in a protection reason without being able to
    /// resolve them to any symbol — vendor and binary-framework names from the client's own
    /// inheritance clauses. They are in no module, so the decisions report's name-membership scrub
    /// cannot find them on its own and would ship them in clear in `Decisions-anon.txt`.
    public private(set) var unknownExternalNames: Set<String> = []

    public init(table: SymbolTable, stdlibRegistry: StdlibRegistry, logger: Logger,
                objcProtection: ObjCProtectionMode = .strict) {
        self.table = table
        self.stdlibRegistry = stdlibRegistry
        self.logger = logger
        self.objcProtection = objcProtection
    }

    /// Mark a symbol as protected with a reason. First reason wins for any id.
    func protect(_ id: Int, reason: String) {
        if reasonForId[id] != nil { return }
        reasonForId[id] = reason
        logger.log("protect id=\(id) — \(reason)", verbose: true)
    }

    public func run(on files: [SourceFile]) {
        var classFacts: [(id: Int, inherited: [String], isObjCAttr: Bool)] = []
        var selectorNames: Set<String> = []
        var wrapperTypeNames: Set<String> = []
        var wrappedCandidates: [(id: Int, attrNames: [String])] = []
        for file in files {
            let visitor = ProtectionVisitor(file: file, table: table,
                                            objcProtection: objcProtection) { [unowned self] id, reason in
                self.protect(id, reason: reason)
            }
            visitor.walk(file.syntax)
            classFacts.append(contentsOf: visitor.classFacts)
            selectorNames.formUnion(visitor.selectorNames)
            wrapperTypeNames.formUnion(visitor.localPropertyWrapperNames)
            wrappedCandidates.append(contentsOf: visitor.wrappedPropertyCandidates)
        }
        // Cross-cutting passes that need the full table.
        runObjCInheritanceProtection(classFacts: classFacts)
        runSelectorNameProtection(selectorNames: selectorNames)
        runPropertyWrapperProtection(wrapperTypeNames: wrapperTypeNames, candidates: wrappedCandidates)
        runOperatorProtection()
        // After per-file structural detectors, run the cross-cutting non-local-conformance pass.
        // It needs the full SymbolTable populated to decide which inherited names are external.
        runNonLocalConformanceProtection()
        // Codable conformers: keep the serialization contract intact (stored-property names + an
        // explicit CodingKeys enum + implicit-raw-value cases of raw-typed Codable enums).
        runCodableProtection()
    }

    private static let codableProtocolNames: Set<String> = ["Codable", "Decodable", "Encodable"]

    /// A type conforming (directly or transitively, e.g. `protocol Model: Codable`) to
    /// Codable/Decodable/Encodable serializes by NAME: the synthesized `CodingKeys` are its STORED
    /// property names, so renaming a stored property silently changes the JSON contract (a green
    /// build but broken networking/persistence) — and, with an explicit `CodingKeys` enum, a renamed
    /// property desynced from its un-renamed case is a hard "does not conform to Codable" red build.
    /// Protect the contract: stored properties, the `CodingKeys` enum + its cases, and (for a
    /// raw-typed Codable enum) cases whose implicit raw value is the case name. Computed properties
    /// are NOT serialized → left renameable (no coverage loss).
    private func runCodableProtection() {
        for sym in table.symbols where isTypeKind(sym.kind) && sym.kind != .protocol {
            guard let parent = sym.scope,
                  let inner = parent.children.first(where: { $0.owner?.id == sym.id }) else { continue }
            let (known, _) = reachableExternalProtocols(from: sym)
            guard known.contains(where: { Self.codableProtocolNames.contains($0) }) else { continue }

            // Struct/class: stored-property names are the keys; computed properties stay renameable.
            // (Raw-typed Codable ENUMS need no handling here — the `EnumDeclSyntax` detector already
            // protects every raw-type enum's name + cases, which covers their serialization values.)
            for member in inner.symbols
            where member.kind == .property && table.storedPropertyIds.contains(member.id) {
                protect(member.id, reason: "Codable stored property (serialization key)")
            }
            // An explicit `CodingKeys` enum + its cases must stay matching the (protected) properties.
            for member in inner.symbols where member.kind == .enum && member.name == "CodingKeys" {
                protect(member.id, reason: "Codable CodingKeys enum")
                if let csScope = inner.children.first(where: { $0.owner?.id == member.id }) {
                    for c in csScope.symbols where c.kind == .enumCase {
                        protect(c.id, reason: "Codable CodingKeys case")
                    }
                }
            }
        }
    }

    /// Operator-named callables (`==`, `+`, `<`, custom operators) must NEVER be renamed:
    /// 1. their use-sites are operator EXPRESSIONS (`a == b`), not `DeclReference`-by-name, so
    ///    ResolutionPass never rewrites a use-site — renaming the decl is an unconditional desync;
    /// 2. they are almost always protocol-operator witnesses (`Equatable.==`, `Comparable.<`, …)
    ///    whose exact spelling the conformance requires.
    /// Fail-closed and project-wide — there is no scenario where renaming an operator decl is safe.
    private func runOperatorProtection() {
        for sym in table.symbols
        where (sym.kind == .method || sym.kind == .function) && Self.isOperatorName(sym.name) {
            protect(sym.id, reason: "operator method (use-sites are operator syntax, not by-name)")
        }
    }

    /// A Swift identifier starts with a Unicode letter or `_`; anything else is an operator
    /// (`==`, `+`, `<>`, `|>`, `...`). Backtick-escaped identifiers (`` `default` ``) are stripped
    /// first so they are correctly treated as identifiers, not operators.
    static func isOperatorName(_ raw: String) -> Bool {
        var name = raw
        if name.hasPrefix("`") && name.hasSuffix("`") && name.count >= 2 {
            name = String(name.dropFirst().dropLast())
        }
        guard let first = name.unicodeScalars.first else { return false }
        if first == "_" { return false }
        return !first.properties.isAlphabetic
    }

    /// @objc taint is TRANSITIVE: a class is name-sensitive if it (or any ancestor) is `@objc` /
    /// `@objcMembers` / `@IBDesignable`, or if any transitive superclass is an Objective-C root
    /// (`NSObject`, `UIView`, `UIViewController`, …). The old shallow rule only caught DIRECT
    /// subclasses of a literal root name, so `class Base: UIViewController {}` then
    /// `class Leaf: Base {}` left `Leaf`'s `@objc` members renamable → dead `#selector` /
    /// `addTarget` / KVC strings at runtime (B-FIX-4). Protect every tainted class + its members
    /// (including extension members).
    private func runObjCInheritanceProtection(classFacts: [(id: Int, inherited: [String], isObjCAttr: Bool)]) {
        guard objcProtection != .off else { return }
        guard !classFacts.isEmpty else { return }
        // Index classes by simple name for module-aware-ish superclass resolution.
        var classesByName: [String: [Symbol]] = [:]
        for sym in table.symbols where sym.kind == .class {
            classesByName[sym.name, default: []].append(sym)
        }
        // Seeds kept APART by origin, because that is the only thing `relaxed` needs to know: an
        // annotation is a DECLARED exposure, an ancestor is merely an inherited possibility.
        var attrSeed = Set<Int>()        // @objc / @objcMembers / @IBDesignable written on the class
        var managedSeed = Set<Int>()     // NSManagedObject — Core Data binds properties by NAME
        var rootSeed = Set<Int>()        // any ObjC root class (NSObject, UIView, …)
        for f in classFacts {
            if f.isObjCAttr { attrSeed.insert(f.id) }
            if f.inherited.contains("NSManagedObject") { managedSeed.insert(f.id) }
            if f.inherited.contains(where: { Self.objcRootClassNames.contains($0) }) { rootSeed.insert(f.id) }
        }
        let tainted = propagateTaint(seed: attrSeed.union(rootSeed),
                                     classFacts: classFacts, classesByName: classesByName)
        // Under `relaxed`, members stay protected only where the exposure was DECLARED (an
        // annotation — `@objcMembers` propagates to subclasses, so the taint does too) or where a
        // framework binds them by name regardless of annotation (Core Data). A class tainted only by
        // ancestry keeps its NAME (storyboards name it as a string) and gives up its members.
        let memberTainted = objcProtection == .relaxed
            ? propagateTaint(seed: attrSeed.union(managedSeed),
                             classFacts: classFacts, classesByName: classesByName)
            : tainted
        // Precompute owner → scopes (primary inner + extensions) ONCE so applying protection to
        // many tainted classes stays linear, not O(tainted × scopes).
        var scopesByOwner: [Int: [Scope]] = [:]
        for (_, fileScope) in table.fileScopes {
            collectScopes(fileScope) { scope in
                if let ownerId = scope.owner?.id { scopesByOwner[ownerId, default: []].append(scope) }
            }
        }
        for id in tainted {
            let protectsMembers = memberTainted.contains(id)
            protect(id, reason: protectsMembers
                    ? "@objc / transitive objc-class"
                    : "objc-descendant class name (relaxed: members renameable)")
            guard protectsMembers else { continue }
            for scope in scopesByOwner[id] ?? [] {
                for member in scope.symbols { protect(member.id, reason: "@objc class member (transitive)") }
            }
        }
    }

    /// Fixpoint over the class graph: a class joins the set when a superclass name resolves to a
    /// class already in it. Conservative on same-named ambiguity (join if ANY namesake is in).
    private func propagateTaint(seed: Set<Int>,
                                classFacts: [(id: Int, inherited: [String], isObjCAttr: Bool)],
                                classesByName: [String: [Symbol]]) -> Set<Int> {
        var tainted = seed
        var changed = true
        while changed {
            changed = false
            for f in classFacts where !tainted.contains(f.id) {
                for name in f.inherited {
                    let supers = classesByName[name] ?? []
                    if supers.contains(where: { tainted.contains($0.id) }) {
                        tainted.insert(f.id); changed = true; break
                    }
                }
            }
        }
        return tainted
    }

    /// Protect every member whose name is referenced by a `#selector` / `Selector("…")` anywhere
    /// in the project. The runtime binds these by name, so a rename would point at a dead string.
    /// Coarse by design (protects same-named members project-wide) — fail closed (B-FIX-4).
    /// Protect properties annotated with a CUSTOM local `@propertyWrapper` (known SwiftUI/Combine
    /// wrappers are handled inline during the walk). The wrapper type may be declared in a different
    /// file than the use, so this runs after every file has contributed its wrapper-type names.
    private func runPropertyWrapperProtection(wrapperTypeNames: Set<String>,
                                              candidates: [(id: Int, attrNames: [String])]) {
        guard !wrapperTypeNames.isEmpty else { return }
        for c in candidates {
            if let w = c.attrNames.first(where: { wrapperTypeNames.contains($0) }) {
                protect(c.id, reason: "@\(w) property wrapper (creates _x/$x synonyms)")
            }
        }
    }

    private func runSelectorNameProtection(selectorNames: Set<String>) {
        guard objcProtection != .off else { return }
        guard !selectorNames.isEmpty else { return }
        for sym in table.symbols
        where (sym.kind == .method || sym.kind == .function || sym.kind == .property)
           && selectorNames.contains(sym.name) {
            protect(sym.id, reason: "referenced by #selector/Selector")
        }
    }

    private func collectScopes(_ scope: Scope, _ visit: (Scope) -> Void) {
        visit(scope)
        for c in scope.children { collectScopes(c, visit) }
    }

    /// Objective-C root class names whose (transitive) subclasses are runtime-name-sensitive.
    private static let objcRootClassNames: Set<String> = [
        "NSObject", "NSManagedObject", "NSDocument", "NSWindowController", "NSViewController", "NSView",
        "UIResponder", "UIView", "UIViewController", "UIControl", "UIButton", "UILabel", "UIWindow",
        "UITableViewCell", "UICollectionViewCell", "UITableViewController", "UICollectionViewController",
        "UINavigationController", "UITabBarController", "UIScrollView", "UIApplication",
        "UICollectionReusableView", "UIGestureRecognizer", "UIPageViewController",
    ]

    /// For each type that conforms to an unknown (external) protocol, protect only the members
    /// whose names match documented requirements of that protocol (View→body, Identifiable→id,
    /// etc). Other members of the type stay renameable. The type name itself is renameable too
    /// — stdlib protocols don't care about the conformer's name.
    ///
    /// For unknown protocols not in the registry, we fall back to protecting everything in the
    /// conformer — safest option until that protocol is added to the registry.
    private func runNonLocalConformanceProtection() {
        for sym in table.symbols where isTypeKind(sym.kind) {
            guard let parent = sym.scope else { continue }
            guard let inner = parent.children.first(where: { $0.owner?.id == sym.id }) else { continue }

            // External protocols this type conforms to — INCLUDING ones reached only THROUGH a
            // local protocol (`class C: Widget`, `protocol Widget: Hashable`). The conformer's
            // witness for such a requirement (`hash(into:)`) satisfies a stdlib protocol that is
            // NOT in our table, so WitnessLinker (local-only) never links it; without this
            // transitive walk it gets renamed and the build breaks ("does not conform to Hashable").
            let (knownExternal, unknownExternal) = reachableExternalProtocols(from: sym)
            guard !knownExternal.isEmpty || !unknownExternal.isEmpty else { continue }

            if !unknownExternal.isEmpty {
                // Unknown external protocol — we don't know its requirements, so any member COULD be
                // its witness ⇒ protect, fail-closed. EXCEPT members already explained by a LOCAL
                // protocol the type conforms to: those are that protocol's witnesses (WitnessLinker
                // renames them as a coordinated group) and are unrelated to the unknown external.
                // Blanket-protecting them was pure over-protection — a `QLPreviewControllerDataSource`
                // conformer lost its unrelated local-protocol method `f1`.
                unknownExternalNames.formUnion(unknownExternal)
                let reason = "conforms to unknown external '\(unknownExternal.joined(separator: ","))'"
                protect(sym.id, reason: reason)
                protectAllMembers(of: sym, in: inner, reason: reason,
                                  except: localProtocolRequirements(for: sym))
                continue
            }

            if !knownExternal.isEmpty {
                // Known external protocols — protect only their documented requirements.
                var allReqs: Set<String> = []
                for protoName in knownExternal {
                    if let reqs = stdlibRegistry.requirements(for: protoName) {
                        for r in reqs { allReqs.insert(r) }
                    }
                }
                for member in inner.symbols where allReqs.contains(member.name) {
                    protect(member.id,
                            reason: "stdlib requirement (\(knownExternal.joined(separator: ",")).\(member.name))")
                }
                // Also: for representable/coordinator-style protocols, the nested Coordinator type
                // is part of the contract (associated type). Protect it if present.
                if knownExternal.contains(where: { $0.hasSuffix("Representable") }) {
                    if let coord = inner.symbols.first(where: { $0.name == "Coordinator" && isTypeKind($0.kind) }) {
                        protect(coord.id, reason: "stdlib requirement (Coordinator nested type)")
                        if let coordScope = inner.children.first(where: { $0.owner?.id == coord.id }) {
                            // Coordinator's protocol-driven methods (delegate callbacks) are typically
                            // @objc-driven. Protector's @objc rule handles this; if not @objc,
                            // explicit declaration of conformance to e.g. PHPickerViewControllerDelegate
                            // surfaces via the same NonLocalConformanceProtector pass — it'll handle Coordinator's
                            // members when it walks Coordinator as a type symbol.
                            _ = coordScope
                        }
                    }
                }
            }
        }
    }

    private func protectAllMembers(of sym: Symbol, in inner: Scope, reason: String,
                                   except localReqs: [Symbol] = []) {
        for member in inner.symbols {
            // A member that WITNESSES a local protocol requirement is that protocol's business —
            // WitnessLinker renames it as a coordinated group — so the unknown-external protect-all
            // net must not swallow it. The match is by KIND (and, for a method, argument labels),
            // NOT by bare name (B-FIX-89, the B-FIX-33/34 family): a local `var webView` PROPERTY
            // requirement must NOT release the same-BASE-NAMED methods `webView(_:start:)` /
            // `webView(_:stop:)` that witness the UNKNOWN external protocol — releasing those renamed
            // the witnesses and broke the conformance ("does not conform to 'WKURLSchemeHandler'").
            if witnessesLocalRequirement(member, localReqs) { continue }
            protect(member.id, reason: reason)
            if isTypeKind(member.kind),
               let nested = inner.children.first(where: { $0.owner?.id == member.id }) {
                for nm in nested.symbols { protect(nm.id, reason: reason) }
            }
        }
    }

    /// Does `member` witness one of the local protocol requirements `reqs`? Mirrors
    /// `WitnessLinker.matchRequirement` (B-FIX-34), the reason a bare-name test is wrong here: a
    /// property witnesses a property, a method a method with a COMPATIBLE SIGNATURE (labels + known
    /// parameter types via the shared `SignatureMatch` — B-FIX-90 — AND a compatible RETURN type,
    /// B-FIX-91), a nested type or typealias an associatedtype/typealias. A member whose base name
    /// merely COLLIDES with a requirement of another kind (the reported `var webView` property vs the
    /// `webView(_:start:)` methods), of DIFFERENT known parameter types, or — for a method with no
    /// distinguishing parameters — of a DIFFERENT return type (a `snapshot() -> UIImage` external
    /// @objc witness against a local `snapshot() -> Data` requirement), does NOT witness it and must
    /// stay protected. Erring toward "not a witness" is the safe direction: a missed local witness is
    /// force-protected, so WitnessLinker reverts its group (green under-obf), whereas a wrongly-
    /// released external witness is a red build.
    private func witnessesLocalRequirement(_ member: Symbol, _ reqs: [Symbol]) -> Bool {
        for req in reqs where req.name == member.name {
            switch member.kind {
            case .method:
                if req.kind == .method,
                   SignatureMatch.compatibleParameters(member, req, in: table, arityMismatch: false),
                   returnsCompatibleForExemption(member, req) {
                    return true
                }
            case .property:
                if req.kind == .property { return true }
            case .typealias_, .struct, .enum, .class:
                if req.kind == .associatedtype_ || req.kind == .typealias_ { return true }
            default:
                break
            }
        }
        return false
    }

    /// Return-type half of the method-witness test (B-FIX-91). A witness's return may be the
    /// requirement's return OR a SUBTYPE of it (covariant witness — `func make() -> Dog` legally
    /// witnesses `func make() -> Animal`), so both count as "still the local witness → exempt". A
    /// DIFFERENT return (not equal, not a subtype) means the member witnesses something ELSE — for a
    /// method with no distinguishing parameters that "something else" is the UNKNOWN external @objc
    /// protocol (`snapshot() -> UIImage` vs a local `snapshot() -> Data`), which must stay protected.
    ///
    /// Fail-SAFE toward the green direction, both readings deliberate:
    ///   - an UNTRACKED return on either side (a `Void`/tuple/function return, or one `WrittenTypeName`
    ///     could not reduce) is a WILDCARD → treat as compatible, so a witness whose return we cannot
    ///     compare is still exempted (obfuscatable) rather than force-protected;
    ///   - `TypeSubtyping.isSubtype` is LOCAL-only, so an EXTERNAL return that is not textually equal
    ///     is treated as DIFFERENT (protect). That is what closes the residual — the external @objc
    ///     witness returns an external type, textually unequal to the local requirement's return — at
    ///     the cost of protecting the astronomically rare BOTH-external genuine covariant pair we
    ///     cannot see the hierarchy of (green over-protection).
    private func returnsCompatibleForExemption(_ member: Symbol, _ req: Symbol) -> Bool {
        guard let mRet = table.functionReturnType[member.id],
              let rRet = table.functionReturnType[req.id] else { return true }   // wildcard
        if TypeNameEquivalence.sameType(mRet, inScope: member.scope, module: member.module.name,
                                        rRet, inScope: req.scope, module: req.module.name, table: table) {
            return true
        }
        return TypeSubtyping.isSubtype(mRet, inScope: member.scope, module: member.module.name,
                                       of: rRet, inScope: req.scope, module: req.module.name, in: table)
    }

    /// The requirement SYMBOLS of the LOCAL protocols `sym` conforms to (directly or via extensions).
    /// A member of `sym` that WITNESSES one (matched by kind + labels in `witnessesLocalRequirement`,
    /// NOT by bare name) is a witness of a protocol we DO understand — WitnessLinker renames it as a
    /// coordinated group — so the unknown-external protect-all net must not swallow it.
    /// ConformanceVisibility (runs before Protector) has already folded inherited requirements into
    /// each local protocol's scope, so inner-scope members cover transitively-inherited requirements
    /// too. Returning the SYMBOLS (not bare names) is what lets the exemption be kind/signature-aware
    /// instead of colliding on a shared base name (B-FIX-89).
    private func localProtocolRequirements(for sym: Symbol) -> [Symbol] {
        var reqs: [Symbol] = []
        for name in conformanceNames(for: sym) {
            guard let proto = ConformanceVisibility.preferredProtocol(in: table, named: name, forModule: sym.module.name),
                  let protoParent = proto.scope,
                  let protoScope = protoParent.children.first(where: { $0.owner?.id == proto.id })
            else { continue }
            for m in protoScope.symbols
            where m.kind == .method || m.kind == .property || m.kind == .typealias_ || m.kind == .associatedtype_ {
                reqs.append(m)
            }
        }
        return reqs
    }

    private func isTypeKind(_ k: SymbolKind) -> Bool {
        switch k { case .class, .struct, .enum, .protocol: return true; default: return false }
    }

    /// We don't bother protecting against names we know are pure-value built-ins
    /// (would otherwise force-protect any enum with a raw type which Protector already handles).
    private var knownStdlibTypes: Set<String> {
        ["String","Int","UInt","Int8","Int16","Int32","Int64","UInt8","UInt16","UInt32","UInt64",
         "Double","Float","Bool","Character","Void","Never","AnyObject","AnyHashable","Any"]
    }

    /// Best-effort re-walk: find the type declaration node for `sym` in its file's syntax and
    /// return inherited identifier names. Memoized by symbol id — the transitive walk below revisits
    /// the same local protocols across many conformers.
    private var inheritanceCache: [Int: [String]] = [:]
    private func inheritanceNames(for sym: Symbol) -> [String] {
        if let cached = inheritanceCache[sym.id] { return cached }
        let names = InheritanceClause.names(atOffset: sym.declOffset, in: sym.file.syntax)
        inheritanceCache[sym.id] = names
        return names
    }

    /// EVERY protocol/superclass name `sym` conforms to: the primary declaration's inheritance
    /// clause PLUS the conformances declared on its extensions (`extension Model: Codable {}`).
    /// `InheritanceClause.names` reads only the primary decl by design, so any consumer that asks
    /// "what does this type conform to" must add the extension half itself — this helper is the
    /// Protector's single answer, so no consumer can be left reading half the picture again (G2).
    /// Memoized: the transitive walk revisits the same local protocols across many conformers.
    private var conformanceCache: [Int: [String]] = [:]
    private func conformanceNames(for sym: Symbol) -> [String] {
        if let cached = conformanceCache[sym.id] { return cached }
        let names = (inheritanceNames(for: sym) + table.extensionConformanceNames(ownerId: sym.id))
            .map(simpleBaseName)
        conformanceCache[sym.id] = names
        return names
    }

    /// Collect the EXTERNAL (stdlib/SDK, not-in-our-table) protocols `sym` conforms to, following
    /// inherited LOCAL protocols transitively. `protocol Widget: Hashable` + `class C: Widget` ⇒
    /// `C` reaches external `Hashable`, so its `hash(into:)` witness must be protected even though
    /// `Hashable` lives in the stdlib and `Widget` is local. Returns the reachable external names
    /// split into (known-in-registry → protect by requirement name, unknown → protect everything).
    ///
    /// Only LOCAL PROTOCOLS are followed — NOT local base classes. A member inherited/overridden
    /// from a local base class is the OverrideLinker's concern; expanding through base classes here
    /// would over-protect every subclass for no correctness gain.
    ///
    /// Both the seed and the transitive step read `conformanceNames`, so a conformance declared in
    /// an EXTENSION counts exactly like one on the primary declaration (G2). It used to read the
    /// primary clause only, which silently unprotected `extension Model: Codable {}` (changed JSON
    /// contract, no compile error) and `extension C: SomeVendorProtocol {}` ("does not conform" red).
    private func reachableExternalProtocols(from sym: Symbol) -> (known: [String], unknown: [String]) {
        var known: Set<String> = []
        var unknown: Set<String> = []
        var visitedLocal: Set<Int> = []          // local protocol ids already expanded
        var seenNames: Set<String> = []
        var queue = conformanceNames(for: sym)
        while let name = queue.popLast() {
            guard seenNames.insert(name).inserted else { continue }
            if knownStdlibTypes.contains(name) { continue }              // value type — not a protocol
            if externalClassNotProtocol(name) { continue }
            let locals = table.types(named: name)
            if locals.isEmpty {
                // External protocol (or unmodeled external type).
                if stdlibRegistry.requirements(for: name) != nil { known.insert(name) }
                else { unknown.insert(name) }
            } else {
                // Local — recurse into its OWN conformances, protocols only.
                for t in locals where t.kind == .protocol {
                    if visitedLocal.insert(t.id).inserted {
                        queue.append(contentsOf: conformanceNames(for: t))
                    }
                }
            }
        }
        return (Array(known), Array(unknown))
    }

    /// True when `name` is an external name we KNOW names a CLASS, not a protocol — and the caller
    /// should therefore not treat it as an unknown external protocol.
    ///
    /// Why this exists: `reachableExternalProtocols` cannot tell an external class from an external
    /// protocol, so `class Screen: UIViewController` looked like a conformance to an unknown
    /// protocol and every member was protected fail-closed as a possible witness. Under `strict`
    /// that is invisible (the objc-descendant rule protects the same members anyway), but it
    /// silently CANCELS `relaxed`: the members it releases are immediately re-protected by the
    /// conformance rule, with only the reason string changing. Measured on the fixtures: relaxed
    /// moved 0 symbols before this, because that is exactly what happened.
    ///
    /// Gated on the mode so `strict` stays bit-identical rather than merely equivalent. The names
    /// are `objcRootClassNames`, which is a curated list of CLASSES — no guessing about whether an
    /// arbitrary unknown name is a class or a protocol, because guessing wrong in that direction
    /// drops a real conformance and produces a "does not conform" red build. An ObjC-rooted class's
    /// name sensitivity is `runObjCInheritanceProtection`'s job, which is what the flag governs;
    /// its OTHER inherited names (`UIImagePickerControllerDelegate`, …) are still protocols and
    /// still protect fail-closed.
    private func externalClassNotProtocol(_ name: String) -> Bool {
        objcProtection != .strict
            && Self.objcRootClassNames.contains(name)
            && table.types(named: name).isEmpty
    }

    /// Strip a trailing generic argument clause and surrounding whitespace so an inherited entry
    /// like `Foo<Bar>` resolves against `table.types(named: "Foo")`.
    private func simpleBaseName(_ s: String) -> String {
        var n = s
        if let lt = n.firstIndex(of: "<") { n = String(n[..<lt]) }
        return n.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func isProtected(_ sym: Symbol) -> Bool {
        reasonForId[sym.id] != nil
    }

    public func reason(for sym: Symbol) -> String? {
        reasonForId[sym.id]
    }
}

private final class ProtectionVisitor: SyntaxVisitor {
    let file: SourceFile
    let table: SymbolTable
    /// `.off` disables the ObjC-motivated detectors in this visitor (exposing attributes, `@objc
    /// extension`, `#selector` collection). `.relaxed` keeps them all — a written annotation is a
    /// declared exposure, which is exactly what `relaxed` still honours.
    let objcProtection: ObjCProtectionMode
    let protect: (Int, String) -> Void

    /// Class inheritance + @objc-attribute facts collected during the walk, consumed by the
    /// transitive @objc-taint pass (B-FIX-4). `id` is the class symbol; `inherited` its clause.
    var classFacts: [(id: Int, inherited: [String], isObjCAttr: Bool)] = []
    /// Names referenced by `#selector(...)` / `Selector("…")` anywhere in the file. The runtime
    /// resolves these by name, so any member of that name must be protected (B-FIX-4).
    var selectorNames: Set<String> = []
    /// Names of LOCAL types declared `@propertyWrapper` (struct/class/enum). A property annotated
    /// with one of these gets `$x`/`_x` synonyms — protect it (cross-file pass in Protector).
    var localPropertyWrapperNames: Set<String> = []
    /// Properties carrying an attribute, with the attribute names. The cross-file pass protects any
    /// whose attribute is a known SwiftUI/Combine wrapper OR a local `@propertyWrapper` type.
    var wrappedPropertyCandidates: [(id: Int, attrNames: [String])] = []

    init(file: SourceFile, table: SymbolTable, objcProtection: ObjCProtectionMode,
         protect: @escaping (Int, String) -> Void) {
        self.file = file
        self.table = table
        self.objcProtection = objcProtection
        self.protect = protect
        super.init(viewMode: .sourceAccurate)
    }

    private func hasAttribute(_ attributes: AttributeListSyntax, named name: String) -> Bool {
        for attr in attributes {
            if let a = attr.as(AttributeSyntax.self),
               a.attributeName.trimmedDescription == name {
                return true
            }
        }
        return false
    }

    /// Resolve the type symbol DECLARED at `token` in THIS file. The visitor is sitting on a
    /// specific decl node, so the precise symbol is the one whose decl position matches — never a
    /// same-named type from another module/file. `table.types(named:).first` was registration-order
    /// dependent and could protect the wrong-module namesake while leaving the real decl renameable
    /// (B-FIX-5 — module-aware invariant).
    private func typeSymbol(declaredAt token: TokenSyntax) -> Symbol? {
        let offset = token.positionAfterSkippingLeadingTrivia.utf8Offset
        for sym in table.symbols
        where sym.file === file && sym.declOffset == offset && sym.kind.isTypeLike {
            return sym
        }
        return nil
    }

    /// Protect the members of `typeSym`. `kinds`, when given, restricts protection to those member
    /// KINDS — used by the raw-type-enum rule, whose contract ties only the CASES to their names: a
    /// computed property / method / nested type of a raw enum has nothing to do with the raw value
    /// and is freely renameable, so protecting it is pure coverage loss. This became visible once
    /// ExtensionOwnerResolver folds an `extension E.Raw { var p }` member into the enum's scope
    /// (B-FIX-58): before that the extension member lived in an external scope this pass never saw.
    private func protectMembers(of typeSym: Symbol, reason: String, kinds: Set<SymbolKind>? = nil) {
        guard let scope = typeSym.scope else { return }
        // Find the child scope owned by this type symbol.
        for child in scope.children where child.owner?.id == typeSym.id {
            for member in child.symbols {
                if let kinds, !kinds.contains(member.kind) { continue }
                protect(member.id, reason)
            }
        }
    }

    /// Member symbol (property/method/function) declared at `token` in THIS file.
    private func memberSymbol(declaredAt token: TokenSyntax) -> Symbol? {
        let offset = token.positionAfterSkippingLeadingTrivia.utf8Offset
        for sym in table.symbols
        where sym.file === file && sym.declOffset == offset
           && (sym.kind == .property || sym.kind == .method || sym.kind == .function) {
            return sym
        }
        return nil
    }

    // @objc / @objcMembers / @IBDesignable — record the class as an @objc-taint SEED. The actual
    // protection (this class + every transitive subclass + their members) is applied by the
    // cross-cutting transitive pass in Protector, because a subclass-of-a-subclass of an @objc root
    // is otherwise missed (B-FIX-4). Also record the inheritance clause for taint propagation.
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        let isObjCAttr = hasAttribute(node.attributes, named: "objc")
            || hasAttribute(node.attributes, named: "objcMembers")
            || hasAttribute(node.attributes, named: "IBDesignable")
        if hasAttribute(node.attributes, named: "propertyWrapper") {
            localPropertyWrapperNames.insert(node.name.text)
        }
        if let sym = typeSymbol(declaredAt: node.name) {
            let inherited = node.inheritanceClause?.inheritedTypes.map { $0.type.trimmedDescription } ?? []
            classFacts.append((id: sym.id, inherited: inherited, isObjCAttr: isObjCAttr))
        }
        return .visitChildren
    }

    // Protocol with associatedtype — generic resolution depends on declared names.
    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        var hasAssoc = false
        for member in node.memberBlock.members {
            if member.decl.is(AssociatedTypeDeclSyntax.self) { hasAssoc = true; break }
        }
        if hasAssoc, let sym = typeSymbol(declaredAt: node.name) {
            protect(sym.id, "protocol with associatedtype")
            protectMembers(of: sym, reason: "member of assoc-type protocol")
        }
        return .visitChildren
    }

    // Enum with raw-type (String/Int/...) — rawValue strings/literals tie cases to names.
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        let rawTypes: Set<String> = ["String", "Int", "UInt", "Int8", "Int16", "Int32", "Int64",
                                     "UInt8", "UInt16", "UInt32", "UInt64", "Double", "Float", "Bool"]
        var hasRaw = false
        if let inh = node.inheritanceClause {
            for entry in inh.inheritedTypes {
                if rawTypes.contains(entry.type.trimmedDescription) {
                    hasRaw = true; break
                }
            }
        }
        if hasRaw, let sym = typeSymbol(declaredAt: node.name) {
            protect(sym.id, "enum with raw type")
            // Only the CASES carry the raw-value contract; a computed property / method / nested type
            // of the enum (including one added in an `extension E.Raw { … }`, now folded in by
            // ExtensionOwnerResolver — B-FIX-58) is freely renameable.
            protectMembers(of: sym, reason: "raw-type enum case", kinds: [.enumCase])
        }
        return .visitChildren
    }

    // @propertyWrapper — projected/wrappedValue contract.
    // @resultBuilder — buildBlock contract.
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        if hasAttribute(node.attributes, named: "propertyWrapper") || hasAttribute(node.attributes, named: "resultBuilder") {
            if hasAttribute(node.attributes, named: "propertyWrapper") {
                localPropertyWrapperNames.insert(node.name.text)
            }
            if let sym = typeSymbol(declaredAt: node.name) {
                let reason = hasAttribute(node.attributes, named: "propertyWrapper") ? "@propertyWrapper" : "@resultBuilder"
                protect(sym.id, reason)
                protectMembers(of: sym, reason: "\(reason) member")
            }
        }
        return .visitChildren
    }

    /// Property wrappers (`@State`/`@Binding`/`@Published` and any CUSTOM `@propertyWrapper` type)
    /// create hidden synonyms `_x` / `$x` at the use-site that we can't rename consistently — and
    /// relying on RollbackPass to revert `x` is unsafe (it strips string literals, so a `$x` inside
    /// `"\($x)"` is invisible to it). Protect the wrapped property. Known SwiftUI/Combine wrappers are
    /// protected here immediately (their type isn't in our source); custom local wrappers are matched
    /// cross-file by `runPropertyWrapperProtection` against `localPropertyWrapperNames`.
    private static let knownWrapperNames: Set<String> = [
        "State", "Binding", "Published", "StateObject", "ObservedObject", "EnvironmentObject",
        "Environment", "AppStorage", "SceneStorage", "FocusState", "FocusedBinding",
        "FocusedValue", "GestureState", "Namespace", "ScaledMetric", "FetchRequest",
        "SectionedFetchRequest", "Bindable", "Default",
    ]
    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        var attrNames: [String] = []
        for attr in node.attributes {
            if let a = attr.as(AttributeSyntax.self) { attrNames.append(a.attributeName.trimmedDescription) }
        }
        guard !attrNames.isEmpty else { return .visitChildren }
        let knownWrapper = attrNames.first { Self.knownWrapperNames.contains($0) }
        for binding in node.bindings {
            guard let ident = binding.pattern.as(IdentifierPatternSyntax.self),
                  let sym = memberSymbol(declaredAt: ident.identifier), sym.kind == .property else { continue }
            if let wrapper = knownWrapper {
                protect(sym.id, "@\(wrapper) property wrapper (creates _x/$x synonyms)")
            }
            // Defer custom-@propertyWrapper matching to the cross-file pass (the wrapper type may be
            // declared in another file we haven't walked yet).
            wrappedPropertyCandidates.append((id: sym.id, attrNames: attrNames))
        }
        return .visitChildren
    }

    // @IBOutlet / @IBInspectable / @objc / @NSManaged properties — the runtime / Interface Builder /
    // Core Data reference these by name (KVC, storyboard outlets, `.xcdatamodel` attribute names),
    // so renaming orphans them (B-FIX-4). `@NSManaged` is the quietest of the four: the name IS the
    // Core Data attribute, a mismatch compiles and then faults on the first fetch (G1).
    override func visitPost(_ node: VariableDeclSyntax) {
        guard objcProtection != .off,
              let attr = firstAttribute(node.attributes, in: Self.objcExposingAttributes) else { return }
        for binding in node.bindings {
            guard let ident = binding.pattern.as(IdentifierPatternSyntax.self),
                  let sym = memberSymbol(declaredAt: ident.identifier) else { continue }
            protect(sym.id, "@\(attr) (runtime/IB name-sensitive)")
        }
    }

    // @IBAction / @objc / @NSManaged methods — referenced by selector string at runtime; protect by
    // name. The `@NSManaged` case is Core Data's generated to-many accessors (`addToItems(_:)`),
    // whose names the framework builds from the relationship name (G1).
    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if objcProtection != .off,
           let attr = firstAttribute(node.attributes, in: Self.objcExposingAttributes),
           let sym = memberSymbol(declaredAt: node.name) {
            protect(sym.id, "@\(attr) (selector/runtime name-sensitive)")
        }
        return .visitChildren
    }

    /// Attributes that publish a member's NAME to a runtime outside the Swift compiler: the ObjC
    /// runtime (`@objc`), Interface Builder (`@IBOutlet` / `@IBInspectable` / `@IBAction` /
    /// `@IBSegueAction`) and Core Data (`@NSManaged`). One set for properties and methods — every
    /// one of them is valid on both, and keeping two hand-maintained lists is how `@NSManaged` went
    /// missing from both in the first place.
    static let objcExposingAttributes: Set<String> = [
        "objc", "IBOutlet", "IBInspectable", "IBAction", "IBSegueAction", "NSManaged",
    ]

    /// `@objc extension Foo { … }` marks EVERY member it declares as `@objc`, so the runtime can
    /// reach each one by name — the same exposure as writing `@objc` on each member. The Protector
    /// had no `ExtensionDeclSyntax` visit at all, so this whole form was invisible (G3). Protect the
    /// members the extension declares; the extended TYPE is untouched here (an `@objc extension`
    /// says nothing about the type's own members, which sit in another decl).
    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        guard objcProtection != .off,
              hasAttribute(node.attributes, named: "objc") else { return .visitChildren }
        for member in node.memberBlock.members {
            if let fn = member.decl.as(FunctionDeclSyntax.self),
               let sym = memberSymbol(declaredAt: fn.name) {
                protect(sym.id, "@objc extension member (runtime name-sensitive)")
            } else if let v = member.decl.as(VariableDeclSyntax.self) {
                for binding in v.bindings {
                    guard let ident = binding.pattern.as(IdentifierPatternSyntax.self),
                          let sym = memberSymbol(declaredAt: ident.identifier) else { continue }
                    protect(sym.id, "@objc extension member (runtime name-sensitive)")
                }
            }
        }
        return .visitChildren
    }

    // `#selector(Foo.bar)` / `#selector(getter: bar)` — collect the referenced member name(s).
    override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
        if node.macroName.text == "selector" {
            for arg in node.arguments { collectSelectorName(from: arg.expression) }
        }
        return .visitChildren
    }

    // `Selector("doThing:withOther:")` — protect the method base name (`doThing`).
    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let callee = node.calledExpression.as(DeclReferenceExprSyntax.self),
           callee.baseName.text == "Selector",
           let firstArg = node.arguments.first,
           let str = firstArg.expression.as(StringLiteralExprSyntax.self),
           let value = str.representedLiteralValue {
            let base = value.split(separator: ":").first.map(String.init) ?? value
            if !base.isEmpty { selectorNames.insert(base) }
        }
        return .visitChildren
    }

    /// Extract the referenced identifier from a `#selector` argument expression: `Foo.bar` →
    /// `bar`, bare `bar` → `bar`.
    private func collectSelectorName(from expr: ExprSyntax) {
        if let member = expr.as(MemberAccessExprSyntax.self) {
            selectorNames.insert(strip(member.declName.baseName.text))
        } else if let ref = expr.as(DeclReferenceExprSyntax.self) {
            selectorNames.insert(strip(ref.baseName.text))
        }
    }

    private func firstAttribute(_ attributes: AttributeListSyntax, in names: Set<String>) -> String? {
        for attr in attributes {
            if let a = attr.as(AttributeSyntax.self) {
                // `@objc(custom)` keeps the base name `objc`.
                let name = a.attributeName.trimmedDescription
                if names.contains(name) { return name }
            }
        }
        return nil
    }

    private func strip(_ s: String) -> String {
        guard s.count >= 2, s.hasPrefix("`"), s.hasSuffix("`") else { return s }
        return String(s.dropFirst().dropLast())
    }
}
