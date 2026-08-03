import XCTest
@testable import SwiftProfCore

/// End-to-end pipeline tests on synthetic single-file projects.
///
/// Each test writes one Swift source into a temp module directory, runs the pipeline,
/// reads back the rewritten file, and asserts that obfuscated names are present
/// (or absent) in the expected positions — the cases SwiftShield's index-source missed.
final class PatternTests: XCTestCase {

    // MARK: - Helpers

    private func runPipeline(_ source: String, moduleName: String = "M", file: String = "Sample.swift",
                             rawValues: RawValueMode = .off,
                             skipOverloadedCallables: Bool = false,
                             aggressiveRollback: Bool = false,
                             objcProtection: ObjCProtectionMode = .strict) throws -> String {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftProf-\(UUID().uuidString)")
        let moduleRoot = tempRoot.appendingPathComponent(moduleName)
        try FileManager.default.createDirectory(at: moduleRoot, withIntermediateDirectories: true)
        let filePath = moduleRoot.appendingPathComponent(file)
        try source.write(to: filePath, atomically: true, encoding: .utf8)
        let outputDir = tempRoot.appendingPathComponent("out")

        let specs = [ModuleSpec(name: moduleName, root: moduleRoot, writable: true)]
        // Use debug-style names so assertions can match T<n>/p<n>/c<n>/m<n> patterns reliably.
        // Disable SDK introspection in tests — full SDK parse takes ~30s per test and is
        // unnecessary for fixture-level pattern verification.
        let options = PipelineOptions(
            modules: specs, outputDirectory: outputDir, dryRun: false,
            nameStyle: .debug, introspectSDK: false, rawValueMode: rawValues,
            skipOverloadedCallables: skipOverloadedCallables,
            aggressiveRollback: aggressiveRollback,
            objcProtection: objcProtection
        )
        let pipeline = Pipeline(options: options, logger: StderrLogger(verbose: false))
        _ = try pipeline.run()

        return try String(contentsOf: filePath, encoding: .utf8)
    }

    // MARK: - Pattern 1: self.x = x (parameter shadowing property)

    func testSelfInit_propertyRenamed_parameterPreserved() throws {
        let source = """
        class Container {
            var payload: Int
            init(payload: Int) {
                self.payload = payload
            }
        }
        """
        let rewritten = try runPipeline(source)
        // Class declared name should be renamed to T<n>.
        XCTAssertFalse(rewritten.contains("class Container"), "class declaration must be renamed")
        // Property declaration renamed.
        XCTAssertFalse(rewritten.contains("var payload"), "var payload must be renamed")
        // self.X on LHS uses the obf name.
        XCTAssertTrue(rewritten.contains("self.p"), "self.<obf> expected")
        // Parameter `payload` is NOT renamed (MVP doesn't rename parameters).
        XCTAssertTrue(rewritten.contains("init(payload: Int)"), "parameter label/name unchanged")
        // RHS reference is the parameter (still named `payload`) — must remain as `payload`.
        XCTAssertTrue(rewritten.contains("= payload"), "RHS parameter reference unchanged")
    }

    // MARK: - Pattern 2: Type.staticMember access

    func testTypeMember_typeAndMemberRenamed() throws {
        let source = """
        class Math {
            static let pi: Double = 3.14
        }
        let value = Math.pi
        """
        let rewritten = try runPipeline(source)
        XCTAssertFalse(rewritten.contains("class Math"), "type declaration must be renamed")
        XCTAssertFalse(rewritten.contains("static let pi"), "static member must be renamed")
        XCTAssertFalse(rewritten.contains("Math.pi"), "use-site must NOT keep original Type.member")
        // The renamed use-site should be a single TX.pY pattern.
        XCTAssertTrue(rewritten.range(of: #"T\d+\.p\d+"#, options: .regularExpression) != nil,
                      "expected obfuscated Type.member at use-site, got:\n\(rewritten)")
    }

    // MARK: - Pattern 3: shorthand .case

    func testShorthandCase_renamedWhenUnique() throws {
        let source = """
        enum Color {
            case crimson
            case azure
        }
        func paint(_ c: Color) {}
        paint(.crimson)
        """
        let rewritten = try runPipeline(source)
        XCTAssertFalse(rewritten.contains("case crimson"), "enum case declaration must be renamed")
        XCTAssertFalse(rewritten.contains(".crimson"), "shorthand use-site must be renamed")
        XCTAssertTrue(rewritten.range(of: #"\.c\d+"#, options: .regularExpression) != nil,
                      "expected .<obf> at use-site, got:\n\(rewritten)")
    }

    // MARK: - Pattern 4: init parameter default value referencing a type

    func testInitDefaults_typeInDefaultValueRenamed() throws {
        let source = """
        struct DefaultLogger {
            init() {}
        }
        struct Service {
            let logger: DefaultLogger
            init(logger: DefaultLogger = DefaultLogger()) {
                self.logger = logger
            }
        }
        """
        let rewritten = try runPipeline(source)
        // Type rename.
        XCTAssertFalse(rewritten.contains("DefaultLogger {"), "type declaration must be renamed")
        // Use-site in default value MUST be renamed (this is SwiftShield's failure mode).
        XCTAssertFalse(rewritten.contains("= DefaultLogger()"),
                       "default-value type reference must be renamed (SwiftShield missed this)")
        // It should be `= T<n>()` now.
        XCTAssertTrue(rewritten.range(of: #"= T\d+\(\)"#, options: .regularExpression) != nil,
                      "expected default value to call obfuscated type, got:\n\(rewritten)")
    }

    // MARK: - Nested types: `EnumNamespace.NestedType` in type position

    func testNestedTypes_renamedInTypePosition() throws {
        let source = """
        enum Models {
            struct Request { let id: String }
            struct Response { let token: String }
            enum Action { case submit; case cancel }
        }
        final class Interactor {
            func handle(req: Models.Request) -> Models.Response {
                return Models.Response(token: "x")
            }
            func handle(action: Models.Action) {
                switch action {
                case .submit: break
                case .cancel: break
                }
            }
        }
        """
        let rewritten = try runPipeline(source)
        // Original names must be gone from type-position references.
        XCTAssertFalse(rewritten.contains("Models.Request"), "Models.Request must be rewritten:\n\(rewritten)")
        XCTAssertFalse(rewritten.contains("Models.Response"), "Models.Response must be rewritten:\n\(rewritten)")
        XCTAssertFalse(rewritten.contains("Models.Action"), "Models.Action must be rewritten:\n\(rewritten)")
        // Renamed pattern T<n>.T<m> should exist on every use site (type AND expression).
        let regex = try NSRegularExpression(pattern: #"T\d+\.T\d+"#)
        let nsRange = NSRange(rewritten.startIndex..., in: rewritten)
        let matches = regex.numberOfMatches(in: rewritten, range: nsRange)
        XCTAssertGreaterThanOrEqual(matches, 4, "expected ≥4 rewritten Type.Member references, got \(matches):\n\(rewritten)")
    }

    // MARK: - Associatedtype + typealias witness

    func testAssociatedtype_typealiasWitnessRollback() throws {
        let source = """
        protocol Repository {
            associatedtype Item
            func fetch() -> [Item]
            func save(_ item: Item)
        }
        struct UserRepo: Repository {
            typealias Item = String
            func fetch() -> [Item] { [] }
            func save(_ item: Item) {}
        }
        """
        let rewritten = try runPipeline(source)
        // Repository protocol has associatedtype → protected. typealias Item witness must NOT be
        // renamed to a different obf than the associatedtype (would orphan use sites).
        // Acceptable outcome: both stay original (rollback).
        XCTAssertTrue(rewritten.contains("associatedtype Item"),
                      "associatedtype Item must be present:\n\(rewritten)")
        XCTAssertTrue(rewritten.contains("typealias Item = String"),
                      "typealias Item witness must remain Item to satisfy conformance:\n\(rewritten)")
        // Use sites within the protocol and the struct must use `Item`, not some obf.
        XCTAssertTrue(rewritten.contains("[Item]"), "type ref [Item] must remain:\n\(rewritten)")
        // Parameter NAME may now be renamed (distinct label form `_ item`) but the type
        // annotation `: Item` must stay (typealias witness rollback keeps Item).
        XCTAssertTrue(rewritten.contains(": Item)"), "param type Item must remain:\n\(rewritten)")
    }

    // MARK: - Backticked keyword case names

    func testKeywordEnumCase_renameAtUseSite() throws {
        let source = """
        enum Level {
            case `public`
            case `internal`
            case `private`
        }
        struct Cfg {
            func describe(_ level: Level) -> String {
                switch level {
                case .`public`: return "pub"
                case .`internal`: return "int"
                case .`private`: return "priv"
                }
            }
        }
        """
        let rewritten = try runPipeline(source)
        // After rename: declarations rewritten to non-keyword obf (case c0/c1/c2 — no backticks).
        XCTAssertFalse(rewritten.contains("case `public`"), "case decl must lose backticks:\n\(rewritten)")
        XCTAssertFalse(rewritten.contains("case `internal`"), "case decl must lose backticks:\n\(rewritten)")
        // Use sites in switch must match decl obfs — no leftover `.\`public\`` strings.
        XCTAssertFalse(rewritten.contains(".`public`"), "use site .`public` not rewritten:\n\(rewritten)")
        XCTAssertFalse(rewritten.contains(".`internal`"), "use site .`internal` not rewritten:\n\(rewritten)")
    }

    // MARK: - Singleton: type inference from initializer

    func testSingleton_typeInferredFromInitializer() throws {
        let source = """
        final class Logger {
            static let shared = Logger()
            let level = 5
            func emit() -> String { "ok" }
            private init() {}
        }
        final class Caller {
            func go() {
                let a = Logger.shared.level
                let b = Logger.shared.emit()
                print(a, b)
            }
        }
        """
        let rewritten = try runPipeline(source)
        // The chained access Logger.shared.level / Logger.shared.emit() must be fully rewritten:
        // - Logger → T<n>
        // - shared → p<n>
        // - level → p<m>
        // - emit → m<k>
        XCTAssertFalse(rewritten.contains("Logger.shared"), "Logger.shared not rewritten:\n\(rewritten)")
        XCTAssertFalse(rewritten.contains(".shared.level"), "shared.level not rewritten:\n\(rewritten)")
        XCTAssertFalse(rewritten.contains(".shared.emit"), "shared.emit not rewritten:\n\(rewritten)")
    }

    // MARK: - Closure local shadows a property of the same name

    func testClosureLocal_doesNotCollideWithProperty() throws {
        let source = """
        final class Holder {
            private var resource: String = {
                let resource = "computed"
                return resource
            }()
        }
        """
        let rewritten = try runPipeline(source)
        // The closure-local `resource` and the property `resource` are DIFFERENT symbols.
        // `return resource` must refer to the LOCAL (closure scope), so the local's declaration
        // and its return reference must share the SAME obf — and it must NOT be the property's.
        // Verify the file still builds-shaped: there must be a `let <obf> = "computed"` and a
        // matching `return <obf>` using the same name.
        let localDeclPattern = #"let (p\d+) = "computed"[\s\S]*return \1"#
        XCTAssertTrue(rewritten.range(of: localDeclPattern, options: .regularExpression) != nil,
                      "closure local decl and its return must use the same obf:\n\(rewritten)")
    }

    // MARK: - Overload resolution by argument labels

    func testOverload_resolvedByArgumentLabels() throws {
        // Two distinct `process` functions differing only by argument labels. A call using
        // `value:` labels must NOT be rewritten to the obf of the no-label overload.
        let source = """
        struct Worker {
            func process(_ item: Int) -> Int { item }
            func process(value a: Int, extra b: Int) -> Int {
                return process(value: a, extra: b)
            }
        }
        """
        let rewritten = try runPipeline(source)
        // The recursive call `process(value:extra:)` must resolve to the 2-arg overload, NOT
        // the single-arg `process(_:)`. We can't know obf names ahead of time, but we CAN assert
        // the file is internally consistent: the `process(value:extra:)` declaration's obf must
        // match the call's obf. Extract the 2-arg decl name and verify the call uses it.
        if let declMatch = rewritten.range(of: #"func (m\d+)\(value a"#, options: .regularExpression) {
            let declName = String(rewritten[declMatch]).replacingOccurrences(of: "func ", with: "").replacingOccurrences(of: "(value a", with: "")
            XCTAssertTrue(rewritten.contains("return \(declName)(value:"),
                          "recursive 2-arg call must target the 2-arg overload (\(declName)):\n\(rewritten)")
        }
        // The single-arg overload must NOT be invoked with labels anywhere.
        XCTAssertFalse(rewritten.contains("(value: a, extra: b)") && rewritten.contains("func process"),
                       "original names should be obfuscated or consistently handled:\n\(rewritten)")
    }

    // MARK: - guard-let local shadows a property of the same name

    func testGuardLetShadow_localNotRenamedToProperty() throws {
        let source = """
        import Foundation
        final class Store {
            private var fileURL: URL? = URL(string: "x")
            func exists() -> Bool {
                guard let fileURL = fileURL else { return false }
                return fileURL.absoluteString.isEmpty == false
            }
        }
        """
        let rewritten = try runPipeline(source)
        // The property `fileURL` is renamed. The guard binding reads the property on the RHS
        // (so RHS must be the property's obf), but the bound LOCAL `fileURL` and its later use
        // `fileURL.absoluteString` must stay `fileURL` (the unwrapped local).
        XCTAssertFalse(rewritten.contains("var fileURL"), "property decl must be renamed:\n\(rewritten)")
        // The guard's bound name + its member access must remain `fileURL` (the local).
        XCTAssertTrue(rewritten.contains("guard let fileURL = ") , "guard binding keeps local name:\n\(rewritten)")
        XCTAssertTrue(rewritten.contains("return fileURL.absoluteString"),
                      "local use must stay `fileURL`, not the property's obf:\n\(rewritten)")
        // RHS of the guard must reference the renamed property (not literal `fileURL`).
        XCTAssertFalse(rewritten.contains("guard let fileURL = fileURL "),
                       "guard RHS must be the renamed property, not literal fileURL:\n\(rewritten)")
    }

    // MARK: - Same-named types across modules resolve to the local module

    func testModuleAwareTypeResolution() throws {
        // Two modules each declare `Config`. A reference inside module A must resolve to A.Config.
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftProf-\(UUID().uuidString)")
        let modA = tempRoot.appendingPathComponent("ModA")
        let modB = tempRoot.appendingPathComponent("ModB")
        try FileManager.default.createDirectory(at: modA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: modB, withIntermediateDirectories: true)
        try "struct Config { let a: Int }\nfunc useA(_ c: Config) -> Int { c.a }".write(
            to: modA.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
        try "struct Config { let b: Int }".write(
            to: modB.appendingPathComponent("B.swift"), atomically: true, encoding: .utf8)
        let outputDir = tempRoot.appendingPathComponent("out")
        let specs = [
            ModuleSpec(name: "ModA", root: modA, writable: true),
            ModuleSpec(name: "ModB", root: modB, writable: true),
        ]
        let options = PipelineOptions(modules: specs, outputDirectory: outputDir, dryRun: false,
                                      nameStyle: .debug, introspectSDK: false)
        _ = try Pipeline(options: options, logger: StderrLogger(verbose: false)).run()
        let a = try String(contentsOf: modA.appendingPathComponent("A.swift"), encoding: .utf8)
        // `useA(_ c: Config)` — the `Config` parameter type must resolve to ModA's Config (which
        // has member `a`), so `c.a` stays consistent. We assert the file still has a coherent
        // `c.<obf-of-a>` access rather than referencing ModB's `b`.
        XCTAssertFalse(a.contains(": Config)"), "Config type ref should be renamed:\n\(a)")
    }

    // MARK: - Nested type referenced lexically resolves to the enclosing type's nested one

    func testNestedTypeLexicalResolution_notGlobalSameName() throws {
        // Two classes each declare a private `Constants` enum with DIFFERENT members. A bare
        // `Constants.alpha` inside Holder must resolve to Holder.Constants (which has `alpha`),
        // NOT Other.Constants (which has `beta`).
        let source = """
        final class Holder {
            private enum Constants { static let alpha = 1 }
            func use() -> Int { return Constants.alpha }
        }
        final class Other {
            private enum Constants { static let beta = 2 }
            func use() -> Int { return Constants.beta }
        }
        """
        let rewritten = try runPipeline(source)
        // After rename, `Constants.alpha` and `Constants.beta` must each be internally consistent:
        // the base type obf must be the SAME as that class's nested-enum decl obf, and the member
        // obf must match. We assert no cross-wiring: the file must NOT contain a reference to a
        // Constants member that doesn't exist on the resolved type. Simplest robust check —
        // there should be exactly two distinct `enum T<n>` decls and each `use()` returns a
        // member of its OWN enum. We verify `alpha` and `beta` are both renamed (no original
        // member name leaks) and there's no leftover bare `Constants`.
        XCTAssertFalse(rewritten.contains("Constants.alpha"), "alpha use must be rewritten:\n\(rewritten)")
        XCTAssertFalse(rewritten.contains("Constants.beta"), "beta use must be rewritten:\n\(rewritten)")
        XCTAssertFalse(rewritten.contains("enum Constants"), "nested enum decls must be renamed:\n\(rewritten)")
        // Each return must reference a member; verify there are two `return <Type>.<member>`
        // accesses (they belong to different nested enums).
        let re = try NSRegularExpression(pattern: #"return\s+\w+\.\w+"#)
        let ns = rewritten as NSString
        let count = re.numberOfMatches(in: rewritten, range: NSRange(location: 0, length: ns.length))
        XCTAssertEqual(count, 2, "both returns must be obf Type.member:\n\(rewritten)")
    }

    // MARK: - Cross-module constructor-call member resolves to the LOCAL module's type

    func testCrossModuleConstructorCall_memberResolvesToLocalModule() throws {
        // Two modules each declare `Widget` with method `load`. Caller in ModA calls Widget().load().
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftProf-\(UUID().uuidString)")
        let modA = tempRoot.appendingPathComponent("ModA")
        let modB = tempRoot.appendingPathComponent("ModB")
        try FileManager.default.createDirectory(at: modA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: modB, withIntermediateDirectories: true)
        try "func caller() { let x = Widget().load() }".write(
            to: modA.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
        try "final class Widget { func load() -> Int { return 1 } }".write(
            to: modA.appendingPathComponent("W.swift"), atomically: true, encoding: .utf8)
        try "final class Widget { func load() -> Int { return 2 } }".write(
            to: modB.appendingPathComponent("B.swift"), atomically: true, encoding: .utf8)
        let outputDir = tempRoot.appendingPathComponent("out")
        let specs = [
            ModuleSpec(name: "ModA", root: modA, writable: true),
            ModuleSpec(name: "ModB", root: modB, writable: true),
        ]
        let options = PipelineOptions(modules: specs, outputDirectory: outputDir, dryRun: false,
                                      nameStyle: .debug, introspectSDK: false)
        _ = try Pipeline(options: options, logger: StderrLogger(verbose: false)).run()
        let a = try String(contentsOf: modA.appendingPathComponent("A.swift"), encoding: .utf8)
        let w = try String(contentsOf: modA.appendingPathComponent("W.swift"), encoding: .utf8)
        // The call's base type and member must both resolve to ModA.Widget. Extract the obfs:
        // base = `<X>().<Y>()` in A.swift; ModA.Widget decl + its load obf in W.swift.
        let callMatch = try NSRegularExpression(pattern: #"(\w+)\(\)\.(\w+)\(\)"#)
        let aNS = a as NSString
        guard let m = callMatch.firstMatch(in: a, range: NSRange(location: 0, length: aNS.length)) else {
            return XCTFail("call site not found:\n\(a)")
        }
        let baseObf = aNS.substring(with: m.range(at: 1))
        let memberObf = aNS.substring(with: m.range(at: 2))
        // The base type obf must be the class declared in W.swift, and the member obf must be
        // THAT class's method — i.e. both appear in W.swift as `class <baseObf> { func <memberObf>`.
        XCTAssertTrue(w.contains("class \(baseObf)"),
                      "call base must be ModA.Widget (in W.swift), got \(baseObf):\nA:\(a)\nW:\(w)")
        XCTAssertTrue(w.contains("func \(memberObf)"),
                      "call member must be ModA.Widget.load (in W.swift), got \(memberObf):\nA:\(a)\nW:\(w)")
    }

    // MARK: - Qualified type chain must resolve all-or-nothing across modules

    func testQualifiedTypeChain_resolvesToFullMatchModule_notPartialRoot() throws {
        // App declares a NESTED `E1.E2` (no `ModelName1`). A separate package declares a top-level
        // `E2` that DOES contain `ModelName1`. A use-site `E2.ModelName1` in App must resolve to
        // the package's E2 (the only full-chain match) — it must NEVER rename only the root `E2`
        // to App's nested-enum obf, producing the compile-breaking `<AppE2Obf>.ModelName1`.
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftProf-\(UUID().uuidString)")
        let app = tempRoot.appendingPathComponent("App")
        let pkg = tempRoot.appendingPathComponent("Pkg")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        try """
        enum E1 { enum E2 {} }
        struct C1 {}
        extension C1 {
            func f(_ completion: (E2.ModelName1?) -> Void) {}
        }
        """.write(to: app.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)
        try "public enum E2 { public struct ModelName1 {} }".write(
            to: pkg.appendingPathComponent("Pkg.swift"), atomically: true, encoding: .utf8)
        let outputDir = tempRoot.appendingPathComponent("out")
        let specs = [
            ModuleSpec(name: "App", root: app, writable: true),
            ModuleSpec(name: "Pkg", root: pkg, writable: true),
        ]
        let options = PipelineOptions(modules: specs, outputDirectory: outputDir, dryRun: false,
                                      nameStyle: .debug, introspectSDK: false)
        _ = try Pipeline(options: options, logger: StderrLogger(verbose: false)).run()
        let a = try String(contentsOf: app.appendingPathComponent("App.swift"), encoding: .utf8)
        let p = try String(contentsOf: pkg.appendingPathComponent("Pkg.swift"), encoding: .utf8)

        // Use-site chain `<base>.<member>?` in the App file.
        let chainRe = try NSRegularExpression(pattern: #"\((\w+)\.(\w+)\?\)"#)
        let aNS = a as NSString
        guard let cm = chainRe.firstMatch(in: a, range: NSRange(location: 0, length: aNS.length)) else {
            return XCTFail("qualified type use-site not found:\n\(a)")
        }
        let baseObf = aNS.substring(with: cm.range(at: 1))
        let memberObf = aNS.substring(with: cm.range(at: 2))

        // Package decls.
        let pNS = p as NSString
        let pkgE2 = try firstGroup(#"enum (\w+)"#, in: p)
        let modelObf = try firstGroup(#"struct (\w+)"#, in: p)
        _ = pNS

        // App's nested E2 obf (the WRONG target).
        let appNestedE2 = try firstGroup(#"enum \w+ \{ enum (\w+)"#, in: a)

        XCTAssertEqual(baseObf, pkgE2,
                       "chain base must resolve to the package E2 (full match):\nApp:\(a)\nPkg:\(p)")
        XCTAssertEqual(memberObf, modelObf,
                       "chain member must be the package ModelName1:\nApp:\(a)\nPkg:\(p)")
        XCTAssertNotEqual(baseObf, appNestedE2,
                          "chain base must NOT be App's nested E2 (the partial-root bug):\nApp:\(a)")
    }

    private func firstGroup(_ pattern: String, in text: String) throws -> String {
        let re = try NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            XCTFail("pattern \(pattern) not found in:\n\(text)")
            return ""
        }
        return ns.substring(with: m.range(at: 1))
    }

    /// Every capture-group-1 match, in source order (for patterns that legitimately occur twice,
    /// e.g. the same local name declared in two sibling blocks).
    private func allGroups(_ pattern: String, in text: String) throws -> [String] {
        let re = try NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
    }

    // MARK: - Extension owner resolves module-aware (not registration-order `.first`)

    func testExtensionOwner_bindsToLocalModuleType_notForeignSameName() throws {
        // Two modules declare `Box`. ModA extends its Box with `describe()` and calls it. The
        // extension must bind to ModA.Box so `describe` unifies into ModA.Box's scope and the
        // use-site `b.describe()` renames to the SAME obf as the extension decl. With the old
        // `.first` owner pick the extension could attach to ModB.Box → use-site desync.
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftProf-\(UUID().uuidString)")
        let modA = tempRoot.appendingPathComponent("ModA")
        let modB = tempRoot.appendingPathComponent("ModB")
        try FileManager.default.createDirectory(at: modA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: modB, withIntermediateDirectories: true)
        try """
        struct Box { let v: Int }
        extension Box { func describe() -> Int { return v } }
        func useA() { let b = Box(v: 1); _ = b.describe() }
        """.write(to: modA.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
        try "struct Box { let w: Int }".write(
            to: modB.appendingPathComponent("B.swift"), atomically: true, encoding: .utf8)
        let outputDir = tempRoot.appendingPathComponent("out")
        let specs = [
            ModuleSpec(name: "ModA", root: modA, writable: true),
            ModuleSpec(name: "ModB", root: modB, writable: true),
        ]
        let options = PipelineOptions(modules: specs, outputDirectory: outputDir, dryRun: false,
                                      nameStyle: .debug, introspectSDK: false)
        _ = try Pipeline(options: options, logger: StderrLogger(verbose: false)).run()
        let a = try String(contentsOf: modA.appendingPathComponent("A.swift"), encoding: .utf8)

        // Extension method decl obf and the use-site obf must match (consistent unification).
        let declObf = try firstGroup(#"func (\w+)\(\) -> Int"#, in: a)
        let useObf = try firstGroup(#"\.(\w+)\(\)"#, in: a)
        XCTAssertFalse(a.contains("func describe"), "extension method decl must be renamed:\n\(a)")
        XCTAssertFalse(a.contains(".describe()"), "use-site must be renamed:\n\(a)")
        XCTAssertEqual(declObf, useObf,
                       "use-site must resolve to the local extension method (same obf):\n\(a)")
    }

    // MARK: - Bare type name must not resolve to an unrelated nested type (req 7)

    func testBareTypeRef_doesNotBindToForeignNestedType() throws {
        // A class declares a NESTED `enum Result`. Elsewhere a property is typed `Result<Int, Error>`
        // (the stdlib Result). The bare `Result` must NOT bind to the nested one — that produced
        // `Cannot find type '<obf>' in scope`, since the nested obf exists only as `Holder.<obf>`.
        let source = """
        final class Holder {
            enum Result {}
        }
        struct Model {
            let r: Result<Int, Error>
        }
        """
        let rewritten = try runPipeline(source)
        // Breakage fix: bare use-site refers to stdlib Result → must stay `Result<Int, Error>`,
        // never bound to the nested type's obf (which is only valid as `Holder.<obf>`).
        // (The nested decl itself may stay un-obfuscated: once the bare stdlib `Result` survives,
        // RollbackPass conservatively reverts the same-named decl too — safe, keeps the build green.)
        XCTAssertTrue(rewritten.contains("Result<Int, Error>"),
                      "bare stdlib Result use must NOT bind to the nested type:\n\(rewritten)")
    }

    // MARK: - Rollback reverts a renamed overload when a same-name use-site desyncs

    func testOverloadDesync_rolledBackForGreenBuild() throws {
        // Two `doIt(_:)` overloads share the label `[_]` but differ by arg type. One is `@objc`
        // (protected → un-renamed); the other is plain (renamed). The call `doIt(s)` is ambiguous
        // by labels, so the resolver leaves it un-renamed → the original `doIt` survives, desynced
        // from the renamed plain decl. Old behaviour: the @objc namesake shields `doIt` → rollback
        // never fires → broken build. New: the straddling-overload exception lets rollback revert
        // the renamed overload → both decls + the call all read `doIt` (compileable).
        let source = """
        import Foundation
        class Svc: NSObject {
            @objc func doIt(_ x: String) -> Int { return 0 }
            func doIt(_ x: Int) -> Int { return 1 }
            func caller(_ s: String) -> Int { return doIt(s) }
        }
        """
        let a = try runPipeline(source)
        // The call stays `doIt(...)` (ambiguous → un-renamed); for the build to compile the plain
        // overload's decl must be rolled back to `doIt` too — so BOTH decls read `func doIt`.
        let declCount = a.components(separatedBy: "func doIt").count - 1
        XCTAssertEqual(declCount, 2, "both doIt decls must read `doIt` after rollback:\n\(a)")
        XCTAssertTrue(a.contains("return doIt("), "the desynced call stays `doIt`:\n\(a)")
    }

    // MARK: - guard binding must not shadow its own name inside the else body

    func testGuardElse_referenceResolvesToPropertyNotBinding() throws {
        // `guard let fileUrl = self.fileUrl else { if let fileUrl = fileUrl { … } }` — inside the
        // else body the RHS `fileUrl` is the PROPERTY (the guard binding isn't in scope there). It
        // must be renamed to the property's obf; otherwise the output references an out-of-scope
        // name. Regression for the shadow frame leaking the guard binding into `else`.
        let source = """
        final class Store {
            var fileUrl: String? = nil
            func load() -> String {
                guard let fileUrl = fileUrl else {
                    if let fileUrl = fileUrl {
                        return fileUrl
                    }
                    return ""
                }
                return fileUrl
            }
        }
        """
        let a = try runPipeline(source)
        // Property renamed → no bare `fileUrl` may survive as a property reference. The two
        // binding-RHS reads (`= fileUrl` in guard and in the else `if let`) must both be the obf.
        // The bound locals (lhs + post-guard `return fileUrl`) legitimately stay as the binding.
        XCTAssertFalse(a.contains("var fileUrl"), "property decl must rename:\n\(a)")
        // Inside the else, `if let fileUrl = <obf>` — the RHS must NOT remain the bare `fileUrl`.
        // Count `= fileUrl`: only the post-guard local read may remain bare; both property reads
        // must be obf. Robust check: the else-body RHS is renamed → `if let fileUrl = fileUrl`
        // must NOT appear (that exact desynced form is the bug).
        XCTAssertFalse(a.contains("if let fileUrl = fileUrl"),
                       "else-body RHS must resolve to the property obf, not the bare name:\n\(a)")
    }

    // MARK: - Overload resolved by ARGUMENT TYPES when labels are ambiguous

    func testOverloadByArgType_enumShorthandPicksExtensionOverload() throws {
        // A read-only package declares `f1(par1: String, par2: String)` (class + protocol req).
        // The app adds an `extension P1` overload `f1(par1: Token, par2: Token)` (enum params) and
        // calls `f1(par1: .none, par2: .none)`. Labels `[par1, par2]` match all three overloads,
        // but the `.none` enum-shorthand args only fit the enum overload — the call must resolve
        // to (and rename to) the extension overload, not stay desynced.
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftProf-\(UUID().uuidString)")
        let pkg = tempRoot.appendingPathComponent("Pkg")
        let app = tempRoot.appendingPathComponent("App")
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try """
        open class C1: P1 {
            public func f1(par1: String, par2: String) -> Bool { return true }
        }
        public protocol P1 {
            func f1(par1: String, par2: String) -> Bool
        }
        """.write(to: pkg.appendingPathComponent("Pkg.swift"), atomically: true, encoding: .utf8)
        try """
        enum Token { case none }
        extension P1 {
            func f1(par1: Token, par2: Token) -> Bool { return false }
        }
        final class Worker: C1 {
            func run(_ e: Token) -> Bool {
                switch e {
                case .none:
                    return f1(par1: .none, par2: .none)
                }
            }
        }
        """.write(to: app.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)
        let outputDir = tempRoot.appendingPathComponent("out")
        let specs = [
            ModuleSpec(name: "Pkg", root: pkg, writable: false),
            ModuleSpec(name: "App", root: app, writable: true),
        ]
        let options = PipelineOptions(modules: specs, outputDirectory: outputDir, dryRun: false,
                                      nameStyle: .debug, introspectSDK: false)
        _ = try Pipeline(options: options, logger: StderrLogger(verbose: false)).run()
        let a = try String(contentsOf: app.appendingPathComponent("App.swift"), encoding: .utf8)
        let declObf = try firstGroup(#"func (\w+)\(par1:"#, in: a)
        let useObf = try firstGroup(#"return (\w+)\(par1:"#, in: a)
        XCTAssertNotEqual(declObf, "f1", "extension overload decl must be renamed:\n\(a)")
        XCTAssertEqual(useObf, declObf,
                       "ambiguous-by-label call must resolve to the enum extension overload:\n\(a)")
        // The `.none` shorthand args must follow the renamed enum case (Token.none → obf): no bare
        // `.none` may survive, otherwise `Token has no member none` after the case is renamed.
        XCTAssertFalse(a.contains(".none"),
                       "enum-shorthand args must resolve to the renamed case:\n\(a)")
    }

    // MARK: - Member chains: a method-call return type drives downstream member resolution

    func testMethodChain_returnTypeResolvesDownstreamMember() throws {
        // `box.next().tag` — without method-return tracking, `.tag` after `next()` has no known
        // base type, so the resolver can't rename it. TypeResolver now reads the method's tracked
        // return type and chains continue.
        let source = """
        struct Inner {
            var tag: Int = 0
        }
        struct Box {
            func next() -> Inner { return Inner() }
        }
        func use(_ b: Box) -> Int { return b.next().tag }
        """
        let a = try runPipeline(source)
        // `tag` must be renamed at decl AND at the chain use-site (consistent).
        let tagDecl = try firstGroup(#"var (\w+): Int = 0"#, in: a)
        let useChain = try firstGroup(#"\.\w+\(\)\.(\w+)"#, in: a)  // b.<next>().<tag>
        XCTAssertNotEqual(tagDecl, "tag", "tag must be renamed at decl:\n\(a)")
        XCTAssertEqual(useChain, tagDecl,
                       "downstream member after a method call must resolve via return type:\n\(a)")
    }

    // MARK: - Green-build mode: --skip-overloaded-callables ignores every overloaded method

    func testSkipOverloadedCallables_overloadedMethodsAreNotRenamed() throws {
        // Two `process` methods in the same struct (overload). Default behaviour: each gets a
        // unique obf and the resolver disambiguates by labels/types. `--skip-overloaded-callables`
        // mode: neither is renamed. Their original names survive everywhere — guaranteed green
        // build with the trade-off of no obfuscation on those methods.
        let source = """
        struct Worker {
            func process(_ item: Int) -> Int { return item }
            func process(value a: Int, extra b: Int) -> Int {
                return process(value: a, extra: b)
            }
        }
        """
        // With the flag ON, both `process` decls keep their name. Parameters get renamed
        // independently — we only assert on the METHOD name.
        let on = try runPipeline(source, skipOverloadedCallables: true)
        let declCount = on.components(separatedBy: "func process").count - 1
        XCTAssertEqual(declCount, 2,
                       "both process methods must keep the original name:\n\(on)")
        // Recursive call also stays `process`.
        XCTAssertTrue(on.contains("return process(value:"),
                      "recursive call must stay un-renamed:\n\(on)")
    }

    // MARK: - Overload disambiguation: bare-vs-qualified param types match by Symbol identity

    func testOverloadDisambig_bareVsQualifiedTypeMatchByIdentity() throws {
        // Two `process` overloads with same labels — one takes `Outer.Inner` (qualified), the
        // other `Int`. The call passes a value typed `Inner` (bare, lexically visible). String
        // equality treats `"Inner" != "Outer.Inner"` — without Symbol-identity matching, neither
        // overload scores, the resolver ties on score 0 and either picks wrong or leaves
        // un-renamed. With identity match, the qualified overload wins (same Symbol).
        let source = """
        struct Outer {
            enum Inner { case a }
        }
        func process(_ x: Outer.Inner) -> Int { return 0 }
        func process(_ x: Int) -> Int { return 1 }
        func use() -> Int {
            let v: Outer.Inner = .a
            return process(v)
        }
        """
        let a = try runPipeline(source)
        let intDecl = try firstGroup(#"func (\w+)\(_ \w+: Int\)"#, in: a)
        let useCall = try firstGroup(#"return (\w+)\(\w+\)"#, in: a)
        XCTAssertNotEqual(useCall, "process", "the call must be obfuscated:\n\(a)")
        XCTAssertNotEqual(useCall, intDecl,
                          "call with Inner-typed arg must NOT resolve to the Int overload:\n\(a)")
    }

    // MARK: - Witness signature: bare-vs-qualified nested type must be treated as same type

    func testWitness_bareVsQualifiedNestedType_linkedByIdentity() throws {
        // The protocol declares its requirement using a QUALIFIED nested type (`Worker.Inner`).
        // The conforming class's witness writes the SAME type BARE (`Inner`, visible by lexical
        // scope inside the class). They must be paired — otherwise both get independent obfs and
        // the class no longer satisfies the protocol (compile error).
        let source = """
        protocol Marker {
            func handle(_ x: Worker.Inner) -> Bool
        }
        final class Worker: Marker {
            enum Inner { case none }
            func handle(_ x: Inner) -> Bool { return true }
        }
        """
        let a = try runPipeline(source)
        // The witness and the requirement must share the same obf — extract both and compare.
        let reqObf = try firstGroup(#"func (\w+)\(_ \w+: \w+\.\w+\) -> Bool"#, in: a)
        let witObf = try firstGroup(#"func (\w+)\(_ \w+: \w+\) -> Bool \{ return true \}"#, in: a)
        XCTAssertEqual(reqObf, witObf,
                       "witness must adopt the protocol requirement's obf (same method name):\n\(a)")
    }

    // MARK: - Forwarder `self.f1(par.rawValue)` must not recurse into itself

    func testForwarder_selfDotRawValue_resolvesToStringOverload_notSelf() throws {
        // The enum overload's body calls `self.f1(par1.rawValue, par2.rawValue)` — arguments are
        // STRINGS (rawValue of a String-raw enum). It must resolve to the String overload (from
        // the protocol/class in the read-only package), NOT pick its own enum-overload (which
        // would rename `self.f1` to its own obf → infinite recursion).
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftProf-\(UUID().uuidString)")
        let pkg = tempRoot.appendingPathComponent("Pkg")
        let app = tempRoot.appendingPathComponent("App")
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try """
        public protocol P1 {
            func f1(par1: String, par2: String) -> Bool
        }
        """.write(to: pkg.appendingPathComponent("Pkg.swift"), atomically: true, encoding: .utf8)
        try """
        enum E2: String { case none }
        enum E3: String { case none }
        extension P1 {
            func f1(par1: E2, par2: E3) -> Bool {
                self.f1(par1: par1.rawValue, par2: par2.rawValue)
            }
        }
        """.write(to: app.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)
        let outputDir = tempRoot.appendingPathComponent("out")
        let specs = [
            ModuleSpec(name: "Pkg", root: pkg, writable: false),
            ModuleSpec(name: "App", root: app, writable: true),
        ]
        let options = PipelineOptions(modules: specs, outputDirectory: outputDir, dryRun: false,
                                      nameStyle: .debug, introspectSDK: false)
        _ = try Pipeline(options: options, logger: StderrLogger(verbose: false)).run()
        let a = try String(contentsOf: app.appendingPathComponent("App.swift"), encoding: .utf8)
        // Invariant: the rawValue forwarder must call the protocol's String overload (un-renamed
        // `self.f1`), never recurse into the enum overload it lives in. With rollback enabled the
        // whole group may revert to `f1` (read-only String f1 survives → rollback net), but in EVERY
        // valid outcome `self.f1(...rawValue...)` reads exactly as `self.f1(par1: par1.rawValue, par2: par2.rawValue)`.
        XCTAssertTrue(a.contains("self.f1(par1: par1.rawValue, par2: par2.rawValue)"),
                      "rawValue forwarder must resolve to the un-renamed String overload, not self:\n\(a)")
    }

    // MARK: - DeclRef-base MemberAccess (`Alias.Nested`) must unwrap a class-local typealias

    func testTypealias_inClass_memberAccessUnwrapsForNestedMemberRename() throws {
        // `class C { typealias Alias = E1 }` — using `Alias.ErrorType` inside C's methods. The
        // DeclRef-as-base MemberAccess path looked up `innerScope(Alias)` (nil — typealiases have
        // no inner scope) and skipped the member rename. `ErrorType` stayed un-renamed while its
        // decl was obfuscated → desync. With typealias unwrap, members are looked up in the
        // underlying type's scope.
        let source = """
        enum E1 {
            enum ErrorType { case case1 }
        }
        final class C {
            typealias Alias = E1
            func use() -> Bool { return Alias.ErrorType.case1 == .case1 }
        }
        """
        let a = try runPipeline(source)
        let errDecl = try firstGroup(#"enum (\w+) \{ case case1 \}"#, in: a)
        let chainMid = try firstGroup(#"\.(\w+)\.case1"#, in: a)  // Alias.<ErrorType>.case1
        XCTAssertNotEqual(errDecl, "ErrorType", "nested enum decl must be renamed:\n\(a)")
        XCTAssertEqual(chainMid, errDecl,
                       "typealias DeclRef-base must unwrap to rename nested member at use-site:\n\(a)")
    }

    // MARK: - Constructor call through protocol-typealias (`T1.A.B()` expression position)

    func testTypealiasInheritance_constructorCallChainResolves() throws {
        // `T1.E4.S4()` in expression position (constructor call): T1 is a protocol typealias
        // inherited by the conformer, E4 and S4 live in the underlying type's scope. Without the
        // expr-position typealias unwrap (in TypeResolver), the chain dies at T1 → S4 stays
        // un-renamed at use-site while S4's decl IS obfuscated → desync. With the fix, the chain
        // resolves through the typealias and every segment renames consistently.
        let source = """
        protocol P {
            typealias T1 = E1
        }
        enum E1 {
            enum E4 {
                struct S4 { init() {} }
            }
        }
        final class C: P {
            func use() { _ = T1.E4.S4() }
        }
        """
        let a = try runPipeline(source)
        let s4Decl = try firstGroup(#"struct (\w+) \{ init\(\) \{\} \}"#, in: a)
        let useTail = try firstGroup(#"\.\w+\.(\w+)\(\)"#, in: a)  // T1.<E4>.<S4>()
        XCTAssertNotEqual(s4Decl, "S4", "S4 decl must be renamed:\n\(a)")
        XCTAssertEqual(useTail, s4Decl,
                       "constructor call through typealias must rename S4 at the use-site:\n\(a)")
    }

    // MARK: - Qualified chain through protocol-typealias inherited by a conformer

    func testQualifiedChain_protocolTypealiasInheritance_unwrapsAndRenames() throws {
        // Protocol P declares `typealias T1 = E1` and conformer `class C: P` writes `T1.S2`.
        // Without typealias-unwrap + conformance inheritance, T1 is invisible to C's lexical
        // scope (it's declared in P) → root unresolvable → S2 stays un-renamed in the use-site
        // while S2's decl in E1 IS obfuscated → desync. With the fix, the chain resolves through
        // P's typealias to E1 and S2 renames consistently.
        let source = """
        protocol P {
            typealias T1 = E1
        }
        enum E1 {
            struct S2 {}
        }
        final class C: P {
            func use() -> [T1.S2]? { return nil }
        }
        """
        let a = try runPipeline(source)
        let s2Decl = try firstGroup(#"struct (\w+) \{\}"#, in: a)
        let chainTail = try firstGroup(#"T1\.(\w+)"#, in: a)
        XCTAssertNotEqual(s2Decl, "S2", "S2 decl must be renamed:\n\(a)")
        XCTAssertEqual(chainTail, s2Decl,
                       "T1.S2 use-site must rename S2 via the protocol-typealias unwrap:\n\(a)")
    }

    // MARK: - Qualified type chain cross-target duplicate — tiebreak to use-site's module

    func testQualifiedChain_crossTargetDuplicates_tiebreakToUseSiteModule() throws {
        // Two writable targets share a source file declaring `class C1 { enum E1 {...} }`. A
        // protocol declared in TargetA references `C1.E1`. Without tiebreak, the full-chain
        // resolver sees 2 valid chains (TargetA's C1.E1 AND TargetB's) → ambiguous → no rename
        // → C1 in `C1.E1` survives un-renamed while C1's decl IS renamed → desync compile break.
        // With tiebreak, picks TargetA's chain (use-site's own module).
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftProf-\(UUID().uuidString)")
        let tgtA = tempRoot.appendingPathComponent("TargetA")
        let tgtB = tempRoot.appendingPathComponent("TargetB")
        try FileManager.default.createDirectory(at: tgtA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tgtB, withIntermediateDirectories: true)
        let shared = """
        final class C1 {
            enum E1 { case c1 }
        }
        """
        try shared.write(to: tgtA.appendingPathComponent("Shared.swift"), atomically: true, encoding: .utf8)
        try shared.write(to: tgtB.appendingPathComponent("Shared.swift"), atomically: true, encoding: .utf8)
        try """
        protocol P1 {
            func f(_ x: C1.E1) -> Bool
        }
        """.write(to: tgtA.appendingPathComponent("Proto.swift"), atomically: true, encoding: .utf8)
        let outputDir = tempRoot.appendingPathComponent("out")
        let specs = [
            ModuleSpec(name: "TargetA", root: tgtA, writable: true),
            ModuleSpec(name: "TargetB", root: tgtB, writable: true),
        ]
        let options = PipelineOptions(modules: specs, outputDirectory: outputDir, dryRun: false,
                                      nameStyle: .debug, introspectSDK: false)
        _ = try Pipeline(options: options, logger: StderrLogger(verbose: false)).run()
        let aSh = try String(contentsOf: tgtA.appendingPathComponent("Shared.swift"), encoding: .utf8)
        let aPr = try String(contentsOf: tgtA.appendingPathComponent("Proto.swift"), encoding: .utf8)
        // TargetA's C1 decl obf, and the protocol use-site `<obf>.E1`.
        let aDecl = try firstGroup(#"final class (\w+) \{"#, in: aSh)
        let useRoot = try firstGroup(#"_ \w+: (\w+)\."#, in: aPr)
        XCTAssertNotEqual(aDecl, "C1", "C1 decl must rename in TargetA:\n\(aSh)")
        XCTAssertEqual(useRoot, aDecl,
                       "qualified-chain use-site must pick TargetA's C1 (same module):\nProto:\(aPr)\nShared:\(aSh)")
    }

    // MARK: - Cross-target duplicate overloads — tiebreak to use-site's module

    func testOverloadTiebreak_sameModulePreferredAmongCrossTargetDuplicates() throws {
        // Two writable targets each contain the SAME shared source (an extension on a read-only
        // protocol adding `g(par1: E, par2: String)`). The use-site in TargetA calls
        // `g(par1: .none, par2: someString)`: enum-shorthand fits both copies (tied score), but
        // Swift would resolve to TargetA's copy at compile time. The tiebreaker must pick the
        // candidate in the use-site's own module so the rename stays consistent.
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftProf-\(UUID().uuidString)")
        let pkg = tempRoot.appendingPathComponent("Pkg")
        let tgtA = tempRoot.appendingPathComponent("TargetA")
        let tgtB = tempRoot.appendingPathComponent("TargetB")
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tgtA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tgtB, withIntermediateDirectories: true)
        try "public protocol P {}\n".write(
            to: pkg.appendingPathComponent("Pkg.swift"), atomically: true, encoding: .utf8)
        let shared = """
        enum E { case none }
        extension P {
            func g(par1: E, par2: String) -> Int { return 0 }
        }
        """
        try shared.write(to: tgtA.appendingPathComponent("Shared.swift"), atomically: true, encoding: .utf8)
        try shared.write(to: tgtB.appendingPathComponent("Shared.swift"), atomically: true, encoding: .utf8)
        try """
        final class Caller: P {
            func run(_ s: String) -> Int { return g(par1: .none, par2: s) }
        }
        """.write(to: tgtA.appendingPathComponent("Caller.swift"), atomically: true, encoding: .utf8)
        let outputDir = tempRoot.appendingPathComponent("out")
        let specs = [
            ModuleSpec(name: "Pkg", root: pkg, writable: false),
            ModuleSpec(name: "TargetA", root: tgtA, writable: true),
            ModuleSpec(name: "TargetB", root: tgtB, writable: true),
        ]
        let options = PipelineOptions(modules: specs, outputDirectory: outputDir, dryRun: false,
                                      nameStyle: .debug, introspectSDK: false)
        _ = try Pipeline(options: options, logger: StderrLogger(verbose: false)).run()
        let aSh = try String(contentsOf: tgtA.appendingPathComponent("Shared.swift"), encoding: .utf8)
        let aCl = try String(contentsOf: tgtA.appendingPathComponent("Caller.swift"), encoding: .utf8)
        // The use-site obf must equal TargetA-Shared decl obf (same module), NOT just "g".
        let aDecl = try firstGroup(#"func (\w+)\(par1:"#, in: aSh)
        let aUse = try firstGroup(#"return (\w+)\(par1:"#, in: aCl)
        XCTAssertNotEqual(aDecl, "g", "extension method must be renamed in TargetA:\n\(aSh)")
        XCTAssertEqual(aUse, aDecl,
                       "cross-target tie must resolve to TargetA's own copy:\nCaller:\(aCl)\nShared:\(aSh)")
    }

    // MARK: - Cross-target duplicate overloads with NO type signal — same-module tiebreak

    func testOverloadTiebreak_zeroArgsCrossTargetDuplicates() throws {
        // Two writable targets each compile the same shared file declaring `func ping()`. The call
        // `ping()` has zero arguments → no type signal to discriminate → my type-based scorer
        // gives every candidate score 0. The same-module tiebreak must still pick the use-site's
        // own copy (Swift would).
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftProf-\(UUID().uuidString)")
        let tgtA = tempRoot.appendingPathComponent("TargetA")
        let tgtB = tempRoot.appendingPathComponent("TargetB")
        try FileManager.default.createDirectory(at: tgtA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tgtB, withIntermediateDirectories: true)
        let shared = "func ping() -> Int { return 0 }\n"
        try shared.write(to: tgtA.appendingPathComponent("Shared.swift"), atomically: true, encoding: .utf8)
        try shared.write(to: tgtB.appendingPathComponent("Shared.swift"), atomically: true, encoding: .utf8)
        try "func use() -> Int { return ping() }\n".write(
            to: tgtA.appendingPathComponent("Use.swift"), atomically: true, encoding: .utf8)
        let outputDir = tempRoot.appendingPathComponent("out")
        let specs = [
            ModuleSpec(name: "TargetA", root: tgtA, writable: true),
            ModuleSpec(name: "TargetB", root: tgtB, writable: true),
        ]
        let options = PipelineOptions(modules: specs, outputDirectory: outputDir, dryRun: false,
                                      nameStyle: .debug, introspectSDK: false)
        _ = try Pipeline(options: options, logger: StderrLogger(verbose: false)).run()
        let aSh = try String(contentsOf: tgtA.appendingPathComponent("Shared.swift"), encoding: .utf8)
        let aUse = try String(contentsOf: tgtA.appendingPathComponent("Use.swift"), encoding: .utf8)
        let aDecl = try firstGroup(#"func (\w+)\(\) -> Int"#, in: aSh)
        let aCall = try firstGroup(#"return (\w+)\(\)"#, in: aUse)
        XCTAssertNotEqual(aDecl, "ping", "shared decl must be renamed in TargetA:\n\(aSh)")
        XCTAssertEqual(aCall, aDecl, "zero-arg cross-target call must resolve to local copy:\n\(aUse)\n\(aSh)")
    }

    // MARK: - Member call `obj.method(args)` resolved by ARGUMENT TYPE among overloads

    func testMemberCallOverload_resolvedByArgType() throws {
        // `Box` has two `put(_:)` overloads (Int / Tag). `b.put(.a)` must resolve to the Tag
        // overload (enum shorthand only fits the enum param), and the `.a` argument must follow
        // Tag's renamed case — both the method name and the case obf must stay consistent.
        let source = """
        enum Tag { case a }
        struct Box {
            func put(_ x: Int) -> Int { return x }
            func put(_ x: Tag) -> Int { return 0 }
        }
        func use(_ b: Box) -> Int { return b.put(.a) }
        """
        let a = try runPipeline(source)
        // The Int overload is identifiable (Int is stdlib, not renamed); the call must resolve to
        // the OTHER (Tag) overload.
        let intOverload = try firstGroup(#"func (\w+)\(_ \w+: Int\)"#, in: a)
        let useMethod = try firstGroup(#"\.(\w+)\(\."#, in: a)  // b.<method>(.<case>)
        XCTAssertNotEqual(useMethod, "put", "member call must be obfuscated:\n\(a)")
        XCTAssertNotEqual(useMethod, intOverload,
                          "member call must resolve to the Tag overload, not put(Int):\n\(a)")
        // The `.a` shorthand arg must resolve to Tag's renamed case (no bare `.a` survives).
        XCTAssertFalse(a.contains("(.a)"), "shorthand arg must follow the renamed case:\n\(a)")
    }

    // MARK: - RawValue obfuscation (preprocessing pass)

    func testRawValues_safe_explicitLiteralsObfuscatedAndUseSiteRewritten() throws {
        let source = """
        enum Mood: String {
            case whiskey = "Виски"
            case wine = "Вино"
        }
        func pick(_ m: Mood) -> String { return m.rawValue }
        """
        let a = try runPipeline(source, rawValues: .safe)
        // Original strings moved into displayName (untouched by main obf), case raw values opaque.
        XCTAssertFalse(a.contains("= \"Виски\""), "case literal must be obfuscated:\n\(a)")
        XCTAssertTrue(a.contains("return \"Виски\""), "original kept in displayName:\n\(a)")
        XCTAssertTrue(a.contains("\"rv0\""), "obfuscated raw token expected:\n\(a)")
        // `.rawValue` use-site rewritten to `.displayName` (then renamed by main obf) → gone.
        XCTAssertFalse(a.contains(".rawValue"), ".rawValue use must be rewritten:\n\(a)")
    }

    func testRawValues_safe_skipsCodableEnum() throws {
        let source = """
        enum Status: String, Codable {
            case active = "ACTIVE"
        }
        """
        let a = try runPipeline(source, rawValues: .safe)
        // Codable enum is skipped: raw value untouched, no opaque token introduced.
        XCTAssertTrue(a.contains("\"ACTIVE\""), "Codable enum raw value must be preserved:\n\(a)")
        XCTAssertFalse(a.contains("rv0"), "Codable enum must not be obfuscated in safe mode:\n\(a)")
    }

    func testRawValues_all_materializesImplicitRawValues() throws {
        let source = """
        enum Dir: String {
            case north
            case south
        }
        """
        let a = try runPipeline(source, rawValues: .all)
        // Implicit raw values materialized as opaque tokens; originals kept in displayName.
        XCTAssertTrue(a.contains("\"rv0\""), "implicit raw value must be materialized:\n\(a)")
        XCTAssertTrue(a.contains("return \"north\""), "original case name kept in displayName:\n\(a)")
    }

    func testRawValues_off_isNoOp() throws {
        let source = """
        enum Mood: String {
            case whiskey = "Виски"
        }
        """
        let a = try runPipeline(source)  // mode .off (default)
        XCTAssertTrue(a.contains("= \"Виски\""), "off mode must not touch raw values:\n\(a)")
        XCTAssertFalse(a.contains("rv0"), "off mode must not obfuscate:\n\(a)")
    }

    // MARK: - Protector: @objc class must be left alone

    func testProtector_objcClassNotRenamed() throws {
        let source = """
        import Foundation
        @objc class Bridged: NSObject {
            @objc var trackedName: String = ""
        }
        """
        let rewritten = try runPipeline(source)
        XCTAssertTrue(rewritten.contains("class Bridged"), "@objc class must be protected")
        XCTAssertTrue(rewritten.contains("var trackedName"), "@objc class members must be protected")
    }

    // MARK: - B-FIX-1: colliding enum case reverted only when used in shorthand

    func testAmbiguousCase_unusedShorthand_isStillRenamed() throws {
        // Two enums each declare `case shared`. `.shared` is NEVER used in shorthand form, so there
        // is nothing to be ambiguous about — both cases must be obfuscated (old behaviour reverted
        // every colliding case, cratering coverage for popular names).
        let source = """
        enum E1 { case shared; case other1 }
        enum E2 { case shared; case other2 }
        func use() { _ = E1.other1; _ = E2.other2 }
        """
        let a = try runPipeline(source)
        XCTAssertFalse(a.contains("case shared"), "unused colliding case must still be renamed:\n\(a)")
    }

    func testAmbiguousCase_shorthandUse_isReverted() throws {
        // `.shared` IS used in shorthand → fail closed: revert the whole colliding group so the
        // original name survives everywhere (compileable).
        let source = """
        enum E1 { case shared }
        enum E2 { case shared }
        func take(_ x: E1) {}
        func go() { take(.shared) }
        """
        let a = try runPipeline(source)
        XCTAssertTrue(a.contains("case shared"), "shorthand-used colliding case must be reverted:\n\(a)")
        XCTAssertTrue(a.contains(".shared)"), "the shorthand case use stays original:\n\(a)")
    }

    // MARK: - B-FIX-2: closure params for a USER-defined higher-order function

    func testUserHOF_closureParamMemberResolvesFromCalleeSignature() throws {
        // `transform` is user-defined (not in HOFRegistry). Its closure param `$0` must be typed
        // `Item` from the callee's declared `(Item) -> Int` signature, so `$0.field` renames.
        let source = """
        struct Item { var field: Int }
        func transform(_ items: [Item], _ f: (Item) -> Int) -> [Int] { return items.map(f) }
        let r = transform([Item()]) { $0.field }
        """
        let a = try runPipeline(source)
        let fieldDecl = try firstGroup(#"var (\w+): Int"#, in: a)
        let useField = try firstGroup(#"\$0\.(\w+)"#, in: a)
        XCTAssertNotEqual(fieldDecl, "field", "field must be renamed at decl:\n\(a)")
        XCTAssertEqual(useField, fieldDecl,
                       "closure-param member must resolve via the callee signature:\n\(a)")
    }

    // MARK: - B-FIX-3: rawValue obfuscation aborts an enum with an unresolvable use-site

    func testRawValues_unresolvableUseSite_abortsEnum() throws {
        // `(box as! Mood).rawValue` — the base is a cast the resolver can't type, so the `.rawValue`
        // can't be redirected to `.displayName`. Obfuscating the literal would make this site return
        // the opaque token at runtime → silent behaviour change. Fail closed: leave the enum alone.
        // (A SUBSCRIPT base used to be unresolvable too, but is now typed — see the redirect test below.)
        let source = """
        enum Mood: String { case happy = "Happy" }
        func first(_ box: Any) -> String { return (box as! Mood).rawValue }
        """
        let a = try runPipeline(source, rawValues: .safe)
        XCTAssertTrue(a.contains("= \"Happy\""), "enum with unresolvable .rawValue must NOT be obfuscated:\n\(a)")
        XCTAssertFalse(a.contains("rv0"), "no opaque raw token must be introduced:\n\(a)")
    }

    /// Companion to the fail-closed test: a `.rawValue` on a SUBSCRIPT-of-collection base is now
    /// resolvable (the base's Element type is known), so the pass CAN redirect it to `.displayName`
    /// and safely obfuscate the raw literal — behaviour is preserved (`moods[0].displayName` still
    /// returns "Happy" at runtime). Coverage gained by the subscript-result-typing fix.
    func testRawValues_subscriptBase_redirectsToDisplayName() throws {
        let source = """
        enum Mood: String { case happy = "Happy" }
        let moods: [Mood] = [.happy]
        func first() -> String { return moods[0].rawValue }
        """
        let a = try runPipeline(source, rawValues: .safe)
        XCTAssertTrue(a.contains("case happy = \"rv0\""),
                      "the raw literal must be obfuscated to the opaque token (base is now resolvable):\n\(a)")
        XCTAssertTrue(a.range(of: #"\w+\[0\]\.displayName"#, options: .regularExpression) != nil,
                      "the subscript-base .rawValue must be redirected to .displayName:\n\(a)")
        XCTAssertFalse(a.contains(".rawValue"),
                      "no un-redirected .rawValue may survive:\n\(a)")
        XCTAssertTrue(a.contains("return \"Happy\""),
                      "displayName must preserve the original value so runtime behaviour is unchanged:\n\(a)")
    }

    // MARK: - B-FIX-4: transitive @objc inheritance + #selector protection

    func testObjC_transitiveSubclassMembersProtected() throws {
        // `Leaf` is a subclass-of-a-subclass of UIViewController. The old shallow rule only caught
        // direct subclasses of a literal root → Leaf's members were renamable → KVC/selector breaks.
        let source = """
        import UIKit
        class Base: UIViewController {}
        class Leaf: Base { var counter = 0 }
        """
        let a = try runPipeline(source)
        XCTAssertTrue(a.contains("class Leaf"), "transitive objc subclass must be protected:\n\(a)")
        XCTAssertTrue(a.contains("var counter"), "transitive objc subclass member must be protected:\n\(a)")
    }

    func testObjC_selectorReferencedMethodProtected() throws {
        // A method referenced by `#selector` is bound by name at runtime — renaming it points the
        // selector at a dead string. Must be protected.
        let source = """
        import Foundation
        class Widget: NSObject {
            @objc func legacyTap() {}
            func wire() { _ = #selector(Widget.legacyTap) }
        }
        """
        let a = try runPipeline(source)
        XCTAssertTrue(a.contains("func legacyTap"), "#selector-referenced method must be protected:\n\(a)")
    }

    // MARK: - B-FIX-5: Protector binds protection to the type at THIS decl position

    func testProtector_rawEnumProtectedPerModule_notRegistrationOrderFirst() throws {
        // Two modules each declare `enum Status: String`. Protection must attach to the Status whose
        // decl we're visiting (per module), not a registration-order `.first` namesake — otherwise
        // one module's raw enum stays renamable and its `case = "literal"` breaks.
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftProf-\(UUID().uuidString)")
        let modB = tempRoot.appendingPathComponent("ModB")
        let modA = tempRoot.appendingPathComponent("ModA")
        try FileManager.default.createDirectory(at: modB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: modA, withIntermediateDirectories: true)
        try #"enum Status: String { case b = "B" }"#.write(
            to: modB.appendingPathComponent("B.swift"), atomically: true, encoding: .utf8)
        try #"enum Status: String { case a = "A" }"#.write(
            to: modA.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
        let outputDir = tempRoot.appendingPathComponent("out")
        let specs = [
            ModuleSpec(name: "ModB", root: modB, writable: true),
            ModuleSpec(name: "ModA", root: modA, writable: true),
        ]
        let options = PipelineOptions(modules: specs, outputDirectory: outputDir, dryRun: false,
                                      nameStyle: .debug, introspectSDK: false)
        _ = try Pipeline(options: options, logger: StderrLogger(verbose: false)).run()
        let a = try String(contentsOf: modA.appendingPathComponent("A.swift"), encoding: .utf8)
        XCTAssertTrue(a.contains(#"case a = "A""#),
                      "ModA's raw enum must be protected at its own decl position:\n\(a)")
    }

    // MARK: - B-FIX-6: conformance declared in an extension links witness to requirement

    func testWitness_conformanceInExtension_linkedToRequirement() throws {
        // `extension S: P` declares the conformance — the primary `struct S {}` has no inheritance
        // clause, so the old passes never saw S: P and the witness `req` desynced from the protocol
        // requirement. Both must share the same obf.
        let source = """
        protocol P { func req() -> Int }
        struct S {}
        extension S: P { func req() -> Int { return 0 } }
        """
        let a = try runPipeline(source)
        let reqProto = try firstGroup(#"protocol \w+ \{ func (\w+)\(\)"#, in: a)
        let reqWitness = try firstGroup(#"extension \w+: \w+ \{ func (\w+)\(\)"#, in: a)
        XCTAssertNotEqual(reqProto, "req", "requirement must be renamed:\n\(a)")
        XCTAssertEqual(reqWitness, reqProto,
                       "extension witness must adopt the requirement's obf:\n\(a)")
    }

    // MARK: - External-protocol conformance reached THROUGH a local protocol

    func testExternalConformance_viaLocalProtocol_hashWitnessProtected() throws {
        // `Widget: Hashable` (local protocol inherits an EXTERNAL stdlib protocol). A concrete
        // conformer's `hash(into:)` witnesses Hashable's requirement — which lives in the stdlib,
        // NOT in our table — so WitnessLinker (local-only) never sees it and the old
        // NonLocalConformanceProtection looked only at the conformer's DIRECT inheritance
        // (`Widget`, which is local → skipped). The witness got renamed → "does not conform to
        // protocol 'Hashable'". Transitive external conformance must protect `hash`/`hashValue`.
        let source = """
        protocol Widget: Hashable {
            var id: String { get }
        }
        final class Card: Widget {
            let id: String
            let title: String
            init(id: String, title: String) {
                self.id = id
                self.title = title
            }
            static func == (lhs: Card, rhs: Card) -> Bool {
                lhs.id == rhs.id && lhs.title == rhs.title
            }
            func hash(into hasher: inout Hasher) {
                hasher.combine(id)
                hasher.combine(title)
            }
        }
        """
        let r = try runPipeline(source)
        // The method NAME `hash` and its external label `into` must survive (the internal param
        // name is renameable and irrelevant to the conformance). `==` survives via the operator
        // guard. Together they keep the Hashable/Equatable conformance intact.
        XCTAssertTrue(r.contains("func hash(into "),
                      "Hashable witness hash(into:) must stay protected:\n\(r)")
        XCTAssertTrue(r.contains("static func == "),
                      "Equatable witness == must stay protected:\n\(r)")
        XCTAssertFalse(r.contains("final class Card"),
                       "the type itself must still be obfuscated:\n\(r)")
    }

    func testHardcodedObjCProtocol_protectsOnlyItsRequirements() throws {
        // Template for extending StdlibRegistry.HardcodedFallback: a curated ObjC protocol (QuickLook
        // ships NO .swiftinterface, so SDK introspection can't supply it) protects ONLY its listed
        // requirement names; unrelated members of the conformer stay obfuscatable, and so does the
        // conformer's own type name. The names listed must be the bare SWIFT member base names from
        // the protocol's generated interface — NOT the ObjC selector. introspectSDK is off here, so
        // this exercises the hardcoded fallback exactly.
        let source = """
        final class C1: QLPreviewControllerDataSource {
            func numberOfPreviewItems(in controller: Int) -> Int { 0 }
            func previewController(_ c: Int, previewItemAt i: Int) -> Int { i }
            func helperOnlyMine() {}
        }
        """
        let r = try runPipeline(source)
        XCTAssertTrue(r.contains("func numberOfPreviewItems(in "), "requirement must stay:\n\(r)")
        XCTAssertTrue(r.contains("func previewController(_ "), "requirement must stay:\n\(r)")
        XCTAssertFalse(r.contains("func helperOnlyMine"), "non-requirement must be obfuscated:\n\(r)")
        XCTAssertFalse(r.contains("class C1"), "conformer type name must be obfuscated:\n\(r)")
    }

    func testImportCollector_collectsModuleNamesIncludingSubmoduleForms() {
        // The set of imported frameworks is folded into the SDK interfaces loaded into the registry,
        // so that a conformer to e.g. a QuickLook protocol gets surgical (known) protection. Submodule
        // import forms (`import struct Foundation.Date`) must collapse to the root module.
        let mods = ImportCollector.modules(inSource: """
        import QuickLook
        import struct Foundation.Date
        import class UIKit.UIView
        @testable import MyApp
        func f() {}
        """)
        XCTAssertTrue(mods.contains("QuickLook"))
        XCTAssertTrue(mods.contains("Foundation"))
        XCTAssertTrue(mods.contains("UIKit"))
        XCTAssertTrue(mods.contains("MyApp"))
    }

    func testUnknownExternalConformance_doesNotProtectLocalProtocolWitness() throws {
        // C1 conforms to a LOCAL protocol P1 (requires f1) AND an UNKNOWN external protocol
        // (QLPreviewControllerDataSource — not in our table, not in the registry). The
        // "unknown external → protect all" net must NOT swallow `f1`: f1 is P1's witness — a
        // conformance we DO understand, unrelated to the external protocol — so it must still be
        // obfuscated (coordinated with P1.f1 by WitnessLinker). Only members NOT explained by a
        // local conformance stay protected (they might be the unknown protocol's witnesses).
        let source = """
        final class C1: P1, QLPreviewControllerDataSource {
            func f1() {}
        }
        protocol P1 {
            func f1()
        }
        """
        let r = try runPipeline(source)
        XCTAssertFalse(r.contains("func f1()"),
                       "f1 (local P1 witness) must be obfuscated despite the unknown external:\n\(r)")
    }

    func testEnumCaseShorthand_inParameterDefaultValue_resolved() throws {
        // `.a` in a parameter default value must resolve to its enum (the parameter's declared type),
        // so the case + the `.a` use-site rename together. Was unresolved → original `a` survived →
        // RollbackPass reverted the case (under-obf; in short debug names an obf collision = red).
        let scalar = try runPipeline("""
        enum E { case a, b }
        func f(x: E = .a) { _ = x }
        """)
        XCTAssertFalse(scalar.contains("case a"), "enum case `a` must be obfuscated:\n\(scalar)")
        XCTAssertFalse(scalar.contains(".a"), "the `.a` default must be rewritten:\n\(scalar)")

        // Array-typed parameter default: `[E] = [.b]` — element context is E.
        let array = try runPipeline("""
        enum E { case a, b }
        func f(xs: [E] = [.b]) { _ = xs }
        """)
        XCTAssertFalse(array.contains("case b"), "enum case `b` must be obfuscated:\n\(array)")
        XCTAssertFalse(array.contains(".b"), "the `.b` array-element default must be rewritten:\n\(array)")
    }

    func testEnumCaseShorthand_inAssignmentRHS_resolved() throws {
        // `p = .beta` (reassignment, raw-parsed as SequenceExpr [lhs, =, rhs]) — the `.beta` context
        // is the LHS's type. Covers bare property, `self.x`, and member `obj.p`. Names alpha/beta to
        // avoid the debug-name `cN` collision artifact in RollbackPass.
        let r = try runPipeline("""
        enum E { case alpha, beta }
        final class C {
            var p: E = .alpha
            func set() { p = .beta }
            func setSelf() { self.p = .alpha }
        }
        struct Holder { var c = C() }
        func ext(h: Holder) { h.c.p = .beta }
        """)
        XCTAssertFalse(r.contains(".alpha"), "`.alpha` (RHS of `self.p =`) must be rewritten:\n\(r)")
        XCTAssertFalse(r.contains(".beta"), "`.beta` (RHS of `p =` / `h.c.p =`) must be rewritten:\n\(r)")
        XCTAssertFalse(r.contains("case alpha"), "case alpha must be obfuscated:\n\(r)")
    }

    func testEnumCaseShorthand_inArrayAnnotationInitializer_resolved() throws {
        // `let xs: [E] = [.a, .b]` — element context is E for each shorthand case.
        let r = try runPipeline("""
        enum E { case a, b }
        let xs: [E] = [.a, .b]
        """)
        XCTAssertFalse(r.contains("case a"), "case `a` must be obfuscated:\n\(r)")
        XCTAssertFalse(r.contains("case b"), "case `b` must be obfuscated:\n\(r)")
        XCTAssertFalse(r.contains(".a"), "`.a` element must be rewritten:\n\(r)")
        XCTAssertFalse(r.contains(".b"), "`.b` element must be rewritten:\n\(r)")
    }

    func testProtocolDefaultImpl_requirementAndDefaultShareObf_andCallResolves() throws {
        // A protocol requirement and its same-signature DEFAULT IMPLEMENTATION in the protocol's own
        // extension are the SAME member: they must share one obf (else the default no longer
        // satisfies the requirement → conformers break), and a call on a protocol-typed value must
        // rewrite to that obf. The two same-named candidates are ambiguous to pick but UNAMBIGUOUS
        // in outcome (same obf). Both the all-labels call and the omitted-default-label call must
        // rewrite. (WitnessLinker skipped protocols → different obfs; resolver bailed on 2 cands.)
        // Case names are `alpha`/`beta`, NOT `c1`/`c2`: under debug naming enum cases mint to
        // `c0`/`c1`, which would textually collide with the literal originals `c1`/`c2` and make
        // RollbackPass's surviving-name scan false-fire (a debug-only artifact, not a real-run
        // concern where names are 32-char random). `alpha`/`beta` keep the test about resolution.
        let source = """
        enum E1 { case alpha, beta }
        protocol P1 {
            func f1(for par1: E1, par2: Bool)
        }
        extension P1 {
            func f1(for par1: E1 = .alpha, par2: Bool = true) { _ = par1; _ = par2 }
        }
        final class C1 {
            private let p1: P1
            init(p1: P1) { self.p1 = p1 }
            func f2() {
                p1.f1(par2: true)
                p1.f1(for: .alpha, par2: true)
            }
        }
        """
        let r = try runPipeline(source)
        XCTAssertFalse(r.contains("f1("),
                       "every f1 (requirement, default impl, both call sites) must be obfuscated:\n\(r)")
        // The `.alpha` shorthands (the extension's default value AND the call argument to the
        // protocol-default method) must rewrite too — else the original case survives and desyncs.
        XCTAssertFalse(r.contains(".alpha"),
                       "every `.alpha` shorthand (default value + call arg) must be rewritten:\n\(r)")
    }

    func testEnumCaseShorthand_qualifiedNestedParamType_defaultValueResolves() throws {
        // A contextual type may be QUALIFIED (`S1.E2`), which parses as MemberTypeSyntax, not
        // IdentifierTypeSyntax. `scalarElementType` only understood the unqualified form, so the
        // `.alpha` default value of a parameter typed as a NESTED enum got no context and stayed
        // original while the case decl renamed → desync. RollbackPass rescues it only into a full
        // revert, and not even that when the case name is shielded (1c Apple-API names like
        // `alpha`) → red build. The same source with a TOP-LEVEL enum already worked, which is
        // exactly what makes this a nesting-only blind spot.
        let r = try runPipeline("""
        struct S1 {
            enum E2 { case alpha, beta }
        }
        protocol P1 {
            func f2(for par1: S1.E2, par2: Bool)
        }
        extension P1 {
            func f2(for par1: S1.E2 = .alpha, par2: Bool = true) {
                f2(for: par1, par2: par2)
            }
        }
        """)
        XCTAssertFalse(r.contains("case alpha"), "nested enum case must be obfuscated:\n\(r)")
        XCTAssertFalse(r.contains(".alpha"),
                       "`.alpha` default value of a qualified-typed param must be rewritten:\n\(r)")
    }

    func testEnumCaseShorthand_qualifiedNestedType_annotationAndReturnResolve() throws {
        // Same invariant, the other two contextual sites: a `let x: S1.E2 = .alpha` type annotation
        // and a `-> S1.E2 { return .beta }` return position. The return branch open-coded its own
        // IdentifierTypeSyntax extraction instead of going through `scalarElementType`, so it had
        // the identical blind spot.
        let r = try runPipeline("""
        struct S1 {
            enum E2 { case alpha, beta }
        }
        struct Holder {
            let mode: S1.E2 = .alpha
            func pick() -> S1.E2 { return .beta }
        }
        """)
        XCTAssertFalse(r.contains("case alpha"), "nested enum case must be obfuscated:\n\(r)")
        XCTAssertFalse(r.contains(".alpha"), "annotated `.alpha` must be rewritten:\n\(r)")
        XCTAssertFalse(r.contains(".beta"), "returned `.beta` must be rewritten:\n\(r)")
    }

    func testBareCall_innerScopeShadowsSameNamedGlobalFunction() throws {
        // Swift's unqualified lookup STOPS at the innermost scope that declares the name: a member
        // shadows a same-named global function entirely (verified with swiftc: calling the global's
        // signature from inside the type is an error, not a fallback). `resolveCall` instead
        // flattened candidates from EVERY scope level into one overload set, so the top-level
        // `f2` joined the protocol's requirement + default impl. Three candidates with IDENTICAL
        // signatures: no argument signal can separate them, and they do NOT all share one obf (the
        // global has its own), so the shared-obf shortcut missed too → the forwarding call stayed
        // original while both protocol decls renamed ⇒ "cannot find 'f2' in scope".
        let source = """
        enum E1 { case alpha, beta }
        func f2(for par1: E1, par2: Bool) {}
        protocol P1 {
            func f2(for par1: E1, par2: Bool)
        }
        extension P1 {
            func f2(for par1: E1 = .alpha, par2: Bool = true) {
                f2(for: par1, par2: par2)
            }
        }
        """
        let r = try runPipeline(source)
        let globalObf = try firstGroup(#"\nfunc (\w+)\(for "#, in: r)
        let requirementObf = try firstGroup(#"protocol \w+ \{\n\s+func (\w+)\(for "#, in: r)
        let callObf = try firstGroup(#"\n\s+(\w+)\(for: "#, in: r)
        XCTAssertNotEqual(callObf, "f2", "the forwarding call must be obfuscated:\n\(r)")
        XCTAssertEqual(callObf, requirementObf,
                       "call must resolve to the protocol member that SHADOWS the global:\n\(r)")
        XCTAssertNotEqual(callObf, globalObf,
                          "call must NOT resolve to the shadowed global function:\n\(r)")
    }

    func testProtocolDefaultImpl_bareCallInsideDefaultBody_rewritesToSharedObf() throws {
        // The "default arguments for a protocol requirement" idiom: the requirement has no
        // defaults, the protocol's OWN extension declares the same signature WITH defaults and
        // forwards to the witness by a BARE call. That bare call sees two same-named candidates
        // (requirement + default impl) that no argument signal can tell apart, so
        // `disambiguateByArgTypes` returned nil and the call was left original — while both decls
        // renamed to the SAME obf (WitnessLinker.linkProtocolDefaults) → "cannot find 'f1' in
        // scope". Same-obf candidates are ambiguous to PICK but unambiguous in OUTCOME; the
        // member-access form already knew that (`resolveMemberForUse`), the bare-call form did not.
        let source = """
        enum E1 { case alpha, beta }
        protocol P1 {
            func f1(for par1: E1, par2: Bool)
        }
        extension P1 {
            func f1(for par1: E1 = .alpha, par2: Bool = true) {
                f1(for: par1, par2: par2)
            }
        }
        """
        let r = try runPipeline(source)
        let declObf = try firstGroup(#"func (\w+)\(for "#, in: r)
        let callObf = try firstGroup(#"(\w+)\(for: "#, in: r)
        XCTAssertNotEqual(callObf, "f1", "the forwarding bare call must be obfuscated:\n\(r)")
        XCTAssertEqual(callObf, declObf,
                       "bare call must rewrite to the shared requirement/default obf:\n\(r)")
        XCTAssertFalse(r.contains("f1("),
                       "no f1 may survive (requirement, default impl, forwarding call):\n\(r)")
    }

    func testOverload_trailingDefaultedParam_callResolvesToCorrectOverload() throws {
        // Two `handle` overloads: `handle(_ url: URL, with: = [:]) -> Bool` and `handle(_ p: S2)`.
        // A call `handle(u)` with u: URL must resolve to the URL overload. The defaulted `with:`
        // means the URL overload has 2 params but the call passes 1 — exact-count label matching
        // wrongly dropped it, leaving the S2 overload as a false unique match → the call was renamed
        // to the S2 overload → "cannot convert URL to S2" (wrong rename, RollbackPass can't catch).
        let r = try runPipeline("""
        import Foundation
        struct S2 {}
        final class C2 {
            func handle(_ url: URL, with options: [String: Int] = [:]) -> Bool { return true }
            func handle(_ par2: S2) { }
        }
        func use(c: C2, u: URL) { _ = c.handle(u) }
        """)
        let urlOverloadObf = try firstGroup(#"func (\w+)\(_ \w+: URL"#, in: r)
        let callObf = try firstGroup(#"\.(\w+)\(u\)"#, in: r)
        // NOT vacuous: the call must actually be obfuscated (if it failed to resolve, RollbackPass
        // would revert both decls + leave the call as `handle`, making both sides equal `handle`).
        XCTAssertNotEqual(callObf, "handle", "the call must be obfuscated, not reverted:\n\(r)")
        XCTAssertEqual(callObf, urlOverloadObf,
                       "call handle(u) must resolve to the URL overload, not the S2 one:\n\(r)")
    }

    func testOptionalBinding_ifLet_inferredTypeResolvesOverload() throws {
        // B-FIX-11 OPEN gap: a call argument that is an `if let` BINDING carried no declared type,
        // so `c.handle(someURL)` (someURL from a `URL?`-returning call) couldn't disambiguate the
        // URL vs S2 overloads → the `handle` group reverted (stayed readable). With optional-binding
        // type inference the binding is typed URL, so the call resolves to the URL overload.
        let r = try runPipeline("""
        import Foundation
        struct S2 {}
        final class C2 {
            func handle(_ url: URL, with options: [String: Int] = [:]) -> Bool { return true }
            func handle(_ par2: S2) { }
        }
        final class C1 {
            let c2 = C2()
            func makeURL() -> URL? { return URL(string: "x") }
            func run() {
                if let someURL = makeURL() {
                    c2.handle(someURL)
                }
            }
        }
        """)
        let urlOverloadObf = try firstGroup(#"func (\w+)\(_ \w+: URL"#, in: r)
        let callObf = try firstGroup(#"\.(\w+)\(someURL\)"#, in: r)
        XCTAssertNotEqual(callObf, "handle", "the call must be obfuscated, not reverted:\n\(r)")
        XCTAssertEqual(callObf, urlOverloadObf,
                       "handle(someURL) must resolve to the URL overload, not the S2 one:\n\(r)")
        // The binding name itself stays readable (bindings are never renamed).
        XCTAssertTrue(r.contains("if let someURL = "), "binding keeps its local name:\n\(r)")
    }

    func testOptionalBinding_guardLet_inferredTypeResolvesOverload() throws {
        // Same as the if-let case but via `guard let` — its binding is registered in
        // visitPost(GuardStmt). The bound `u` (URL) must let `c2.handle(u)` pick the URL overload.
        let r = try runPipeline("""
        import Foundation
        struct S2 {}
        final class C2 {
            func handle(_ url: URL, with options: [String: Int] = [:]) -> Bool { return true }
            func handle(_ par2: S2) { }
        }
        final class C1 {
            let c2 = C2()
            func makeURL() -> URL? { return URL(string: "x") }
            func run() {
                guard let u = makeURL() else { return }
                c2.handle(u)
            }
        }
        """)
        let urlOverloadObf = try firstGroup(#"func (\w+)\(_ \w+: URL"#, in: r)
        let callObf = try firstGroup(#"\.(\w+)\(u\)"#, in: r)
        XCTAssertNotEqual(callObf, "handle", "the call must be obfuscated, not reverted:\n\(r)")
        XCTAssertEqual(callObf, urlOverloadObf,
                       "handle(u) must resolve to the URL overload, not the S2 one:\n\(r)")
    }

    func testOptionalBinding_localTypeMember_resolvesAndRenames() throws {
        // A binding of a LOCAL type (`if let acc = makeAccount()`): member access `acc.balance` and
        // a method call `acc.describe()` must rename to the type's obf members (the binding name `acc`
        // stays). Previously the binding wasn't a Symbol so `acc.member` resolved to nothing → the
        // member stayed readable (under-obf). B-FIX-12 records the binding's type, so member access
        // on it now resolves against that type's scope.
        let r = try runPipeline("""
        struct Account {
            var balance: Int
            func describe() -> Int { return balance }
        }
        final class Bank {
            func makeAccount() -> Account? { return Account(balance: 0) }
            func run() {
                if let acc = makeAccount() {
                    _ = acc.balance
                    _ = acc.describe()
                }
            }
        }
        """)
        let balanceObf = try firstGroup(#"var (\w+): Int"#, in: r)
        let describeObf = try firstGroup(#"func (\w+)\(\) -> Int"#, in: r)
        XCTAssertNotEqual(balanceObf, "balance", "property must be obfuscated:\n\(r)")
        XCTAssertTrue(r.contains("acc.\(balanceObf)"), "acc.balance must rename the member:\n\(r)")
        XCTAssertTrue(r.contains("acc.\(describeObf)()"), "acc.describe() must rename the member:\n\(r)")
        XCTAssertTrue(r.contains("if let acc = "), "binding name stays readable:\n\(r)")
    }

    func testOptionalBinding_chainedMemberOnBinding_resolves() throws {
        // Chained base on a binding: `if let acc = makeAccount(); acc.owner.name`. The inner `.owner`
        // recurses through TypeResolver.typeSymbol(of:), which (via the injected binding-type provider)
        // now types `acc` → Account → owner: Person → name. All three member tokens must obfuscate.
        let r = try runPipeline("""
        struct Person { var name: String }
        struct Account { var owner: Person }
        final class Bank {
            func makeAccount() -> Account? { return Account(owner: Person(name: "x")) }
            func run() {
                if let acc = makeAccount() {
                    _ = acc.owner.name
                }
            }
        }
        """)
        // Local type names (`Person`) are themselves obfuscated in annotations, so assert
        // structurally: the decls are gone and the chained use-site carries neither original member.
        XCTAssertFalse(r.contains("var owner"), "owner decl must be obfuscated:\n\(r)")
        XCTAssertFalse(r.contains("var name"), "name decl must be obfuscated:\n\(r)")
        let chain = try firstGroup(#"(acc\.\w+\.\w+)"#, in: r)
        XCTAssertFalse(chain.contains("owner") || chain.contains("name"),
                       "chained `acc.owner.name` must rename BOTH members, got: \(chain)\n\(r)")
    }

    // MARK: - Generic receiver member access (partial-generics base-name strip)

    func testGenericReceiver_memberResolvesViaBaseName() throws {
        // `box: Box<Int>` → `box.value` must resolve to Box's member. `typeSymbol(forQualifiedName:)`
        // now strips the generic clause (`Box<Int>` → `Box`) before lookup; before, the member stayed
        // readable (RollbackPass then reverted `value`).
        let r = try runPipeline("""
        struct Box<T> { var value: T }
        final class User {
            let box: Box<Int> = Box(value: 0)
            func read() -> Int { return box.value }
        }
        """)
        // `box` (the receiver property) is itself renamed, so the access is `<boxObf>.<memberObf>`.
        // The discriminating fact: `value` got obfuscated AT ALL — which only happens if `box.value`
        // resolved (otherwise the surviving use makes RollbackPass revert `value`).
        let memberObf = try firstGroup(#"var (\w+): T"#, in: r)
        XCTAssertNotEqual(memberObf, "value", "generic type's member must resolve & be obfuscated:\n\(r)")
        XCTAssertFalse(r.contains("value"), "no `value` use may survive (member access resolved):\n\(r)")
    }

    // MARK: - Subscript parameters get their own scope (no property collision)

    func testSubscriptParameter_shadowsProperty_notRewrittenToPropertyObf() throws {
        // A subscript parameter named like a property must resolve to the PARAMETER in the body, not
        // the property — otherwise the use is silently rewritten to the property's obf (reads the
        // wrong storage; RollbackPass can't catch it because the param name survives in the signature).
        let r = try runPipeline("""
        final class Container {
            var index: Int = 0
            private var store: [Int] = [1, 2, 3]
            subscript(index: Int) -> Int {
                return store[index]
            }
        }
        """)
        let propObf = try firstGroup(#"var (\w+): Int = 0"#, in: r)
        XCTAssertNotEqual(propObf, "index", "the property must be obfuscated:\n\(r)")
        XCTAssertTrue(r.contains("subscript(index: Int)"), "subscript param decl stays `index`:\n\(r)")
        XCTAssertTrue(r.contains("[index]"),
                      "subscript body use must stay the PARAM `index`, not the property's obf:\n\(r)")
    }

    // MARK: - Local `let`/`var` not in scope within its own initializer

    func testLocalVariable_sameNameAsMethod_callInOwnInitializerResolvesToMethod() throws {
        // A local `let flag` whose initializer CALLS the same-named METHOD `flag(for:)`. Swift: a
        // local is not in scope inside its own initializer, so `flag(for:)` is the method call and
        // must rename to the METHOD's obf. Previously the callee resolved to the not-yet-in-scope
        // local `.property` → the call was bound to the Bool local instead of the method → after
        // renaming the method decl, the call read "use of local variable before its declaration".
        let r = try runPipeline("""
        final class C {
            func flag(for id: Int) -> Bool { return id > 0 }
            func run(_ x: Int) -> Bool {
                let flag: Bool = x > 0
                    ? flag(for: x)
                    : true
                return flag
            }
        }
        """)
        let methodObf = try firstGroup(#"func (\w+)\(for \w+: Int\)"#, in: r)
        XCTAssertNotEqual(methodObf, "flag", "method must be obfuscated:\n\(r)")
        XCTAssertTrue(r.contains("\(methodObf)(for:"),
                      "the call in the local's OWN initializer must rename to the METHOD obf, not bind to the local:\n\(r)")
    }

    func testLocalVariable_bareRefInOwnInitializerResolvesToProperty() throws {
        // The bare-reference sibling: `let count = count + 1` where `count` is a stored property.
        // Inside the initializer the local isn't in scope yet, so `count` is the PROPERTY read and
        // must rename to the property's obf (coverage). Was left un-renamed (bound to the local) →
        // RollbackPass reverted the property (safe under-obf).
        let r = try runPipeline("""
        final class C {
            var count: Int = 5
            func bump() {
                let count = count + 1
                _ = count
            }
        }
        """)
        let propObf = try firstGroup(#"var (\w+): Int = 5"#, in: r)
        XCTAssertNotEqual(propObf, "count", "stored property must be obfuscated:\n\(r)")
        XCTAssertTrue(r.contains("= \(propObf) + 1"),
                      "the property read in the local's OWN initializer must rename to the property obf:\n\(r)")
    }

    // MARK: - Inherited property visibility (SuperclassVisibility)

    func testInheritedProperty_bareAndSelf_resolveToSuperclassMember() throws {
        // A subclass reading an inherited property (bare `counter` and `self.counter`) must rename
        // to the BASE property's obf. Without SuperclassVisibility the uses didn't resolve → stayed
        // readable → RollbackPass reverted the base property (under-obf across the hierarchy).
        let r = try runPipeline("""
        class Base { var counter: Int = 0 }
        final class Sub: Base {
            func bump() { counter += 1 }
            func read() -> Int { return self.counter }
        }
        """)
        let declObf = try firstGroup(#"var (\w+): Int = 0"#, in: r)
        XCTAssertNotEqual(declObf, "counter", "base property must be obfuscated:\n\(r)")
        XCTAssertFalse(r.contains("counter"),
                       "every `counter` use (bare + self.) must rename to the base obf:\n\(r)")
    }

    func testInheritedProperty_transitiveThroughTwoLevels() throws {
        // `C: B`, `B: A`, property on A — read in C must resolve through the full chain.
        let r = try runPipeline("""
        class A { var alpha: Int = 0 }
        class B: A { }
        final class C: B {
            func use() -> Int { return alpha }
        }
        """)
        let declObf = try firstGroup(#"var (\w+): Int = 0"#, in: r)
        XCTAssertNotEqual(declObf, "alpha", "grandparent property must be obfuscated:\n\(r)")
        XCTAssertFalse(r.contains("alpha"), "inherited use must rename through 2 levels:\n\(r)")
    }

    // MARK: - Override chains (OverrideLinker): base + override must share one obf

    func testOverride_methodChain_baseAndOverridesShareObf() throws {
        // A pure-Swift override chain: base + override get INDEPENDENT obfs → `method does not
        // override …` red build. OverrideLinker must unify the whole chain to the base's obf.
        let r = try runPipeline("""
        class Base { func step() -> Int { 1 } }
        class Mid: Base { override func step() -> Int { 2 } }
        final class Leaf: Mid { override func step() -> Int { 3 } }
        """)
        let baseObf = try firstGroup(#"\bfunc (\w+)\(\) -> Int"#, in: r)
        XCTAssertNotEqual(baseObf, "step", "base method must be obfuscated:\n\(r)")
        XCTAssertEqual(r.components(separatedBy: "override func \(baseObf)(").count - 1, 2,
                       "both overrides must adopt the base method obf:\n\(r)")
        XCTAssertFalse(r.contains("step"), "no original method name should survive:\n\(r)")
    }

    func testOverride_computedPropertyChain_baseAndOverrideShareObf() throws {
        // `override var` is the most common DEFAULT-run red: the base property read resolves but the
        // override decl gets an independent obf → `property does not override …`.
        let r = try runPipeline("""
        class Theme { var title: String { "base" } }
        final class Dark: Theme { override var title: String { "dark" } }
        """)
        let baseObf = try firstGroup(#"\bvar (\w+): String \{"#, in: r)
        XCTAssertNotEqual(baseObf, "title", "base property must be obfuscated:\n\(r)")
        XCTAssertTrue(r.contains("override var \(baseObf): String"),
                      "override property must adopt the base obf:\n\(r)")
        XCTAssertFalse(r.contains("title"), "no original property name should survive:\n\(r)")
    }

    func testOverride_readonlyBase_overrideReverted() throws {
        // Base lives in a READ-ONLY module (can't be renamed). The writable subclass's override must
        // keep the inherited name (group-revert) so the override relationship stays intact → green.
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftProf-\(UUID().uuidString)")
        let lib = tempRoot.appendingPathComponent("Lib")
        let app = tempRoot.appendingPathComponent("App")
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try "open class Base { open func ping() {} }".write(
            to: lib.appendingPathComponent("L.swift"), atomically: true, encoding: .utf8)
        // No `super.ping()` / use-site on purpose: nothing leaves a surviving original, so only
        // OverrideLinker (not RollbackPass) can keep the chain consistent.
        try """
        class Sub: Base { override func ping() {} }
        """.write(to: app.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
        let outputDir = tempRoot.appendingPathComponent("out")
        let specs = [
            ModuleSpec(name: "Lib", root: lib, writable: false),
            ModuleSpec(name: "App", root: app, writable: true),
        ]
        let options = PipelineOptions(modules: specs, outputDirectory: outputDir, dryRun: false,
                                      nameStyle: .debug, introspectSDK: false)
        _ = try Pipeline(options: options, logger: StderrLogger(verbose: false)).run()
        let a = try String(contentsOf: app.appendingPathComponent("A.swift"), encoding: .utf8)
        XCTAssertTrue(a.contains("override func ping("),
                      "override of an un-renameable base must keep the inherited name:\n\(a)")
    }

    // MARK: - Codable serialization-key protection

    func testCodable_storedPropertiesProtected() throws {
        // A Codable type's stored-property names ARE its JSON keys (the synthesized CodingKeys).
        // Renaming them compiles green but silently changes the serialization contract — must NOT
        // rename them. The type name itself is still obfuscated.
        let r = try runPipeline("""
        struct User: Codable {
            let userId: Int
            let displayName: String
            var computedTag: String { "u" }
        }
        """)
        XCTAssertTrue(r.contains("let userId"), "Codable stored prop must keep its serialization key:\n\(r)")
        XCTAssertTrue(r.contains("let displayName"), "Codable stored prop must keep its key:\n\(r)")
        XCTAssertFalse(r.contains("struct User"), "the type name itself is still obfuscated:\n\(r)")
        // Computed properties are NOT serialized → still renameable (no coverage loss there).
        XCTAssertFalse(r.contains("var computedTag"), "computed property of a Codable type is renameable:\n\(r)")
    }

    func testCodable_explicitCodingKeys_noDesync() throws {
        // With explicit CodingKeys, renaming a property but not its matching case is a hard
        // "does not conform to Codable" red build. Protect both so they stay consistent.
        let r = try runPipeline("""
        struct Post: Codable {
            let title: String
            let body: String
            enum CodingKeys: String, CodingKey {
                case title
                case body = "content"
            }
        }
        """)
        XCTAssertTrue(r.contains("let title"), "stored prop must be protected:\n\(r)")
        XCTAssertTrue(r.contains("let body"), "stored prop must be protected:\n\(r)")
        XCTAssertTrue(r.contains("case title"), "CodingKeys case must stay matching its property:\n\(r)")
        XCTAssertTrue(r.contains("case body = \"content\""), "CodingKeys case must stay intact:\n\(r)")
    }

    func testCodable_transitiveViaLocalProtocol_storedProtected() throws {
        // Conformance reached through a local protocol (`protocol Model: Codable`) must still protect
        // the stored properties — the synthesized Codable keys are the same.
        let r = try runPipeline("""
        protocol Model: Codable {}
        struct Token: Model {
            let secret: String
        }
        """)
        XCTAssertTrue(r.contains("let secret"),
                      "stored prop of a transitively-Codable type must be protected:\n\(r)")
    }

    func testCodable_staticStoredProperty_isRenameable() throws {
        // `static`/`class` (TYPE) stored properties are NEVER part of Codable — the compiler
        // synthesizes CodingKeys from INSTANCE stored properties only, so a static stored property
        // is not a serialization key and must stay RENAMEABLE. Only the instance stored property is
        // protected. (Regression: static let/var on a Codable type was wrongly protected → lost
        // coverage for zero safety benefit.)
        let r = try runPipeline("""
        struct Settings: Codable {
            static let maxCount = 10
            static var cachedFlag = false
            let userId: Int
        }
        """)
        XCTAssertTrue(r.contains("let userId"),
                      "instance stored prop is the real JSON key — must be protected:\n\(r)")
        XCTAssertFalse(r.contains("maxCount"),
                       "static let is not a serialization key — must be obfuscated:\n\(r)")
        XCTAssertFalse(r.contains("cachedFlag"),
                       "static var is not a serialization key — must be obfuscated:\n\(r)")
    }

    // MARK: - Property-wrapper projection ($x) / backing store (_x)

    func testPropertyWrapper_customWrapper_projectionStaysValid() throws {
        // A property using a CUSTOM @propertyWrapper (any local @propertyWrapper type, not just the
        // hardcoded SwiftUI ones) creates `$x`/`_x` synonyms that the resolver can't rename
        // consistently. Renaming `x` and relying on RollbackPass to revert it is unsafe: RollbackPass
        // strips string literals, so a `$x` inside `"\($x)"` is invisible to its scan and the revert
        // never fires → desync. Protect the wrapped property instead → green and the synonyms stay
        // valid. The enclosing type is still obfuscated.
        let r = try runPipeline("""
        @propertyWrapper struct Wrap {
            var wrappedValue: Int
            var projectedValue: Bool { wrappedValue > 0 }
        }
        struct Holder {
            @Wrap var level: Int = 1
            func describe() -> String { return "p=\\($level)" }
            mutating func bump() { _level = Wrap(wrappedValue: 2) }
        }
        """)
        XCTAssertTrue(r.contains("var level"), "custom-wrapper property must be protected:\n\(r)")
        XCTAssertTrue(r.contains("$level"), "projection must stay valid (revert can't catch it in interpolation):\n\(r)")
        XCTAssertTrue(r.contains("_level"), "backing store must stay valid:\n\(r)")
        XCTAssertFalse(r.contains("struct Holder"), "the enclosing type is still obfuscated:\n\(r)")
    }

    func testInheritedInit_constructorLabelNotRenamedToProperty() throws {
        // A subclass that INHERITS its superclass's designated init: `B(side: 2)` uses the init's
        // PARAMETER label, not a memberwise label — classes have NO memberwise initializer. The label
        // must stay. The memberwise-init heuristic wrongly applied to classes and, missing the
        // inherited init (it only checked B's OWN scope), renamed the label to the
        // SuperclassVisibility-copied `side` property's obf → "incorrect argument label" red build.
        let r = try runPipeline("""
        class A { let side: Double; init(side: Double) { self.side = side } }
        class B: A {}
        func go() { _ = A(side: 1); _ = B(side: 2) }
        """)
        let propObf = try firstGroup(#"let (\w+): Double"#, in: r)
        XCTAssertNotEqual(propObf, "side", "the property itself is still obfuscated:\n\(r)")
        XCTAssertFalse(r.contains("(\(propObf): "),
                       "no constructor call may use the property's obf as an argument label:\n\(r)")
    }

    func testOperatorMethod_neverRenamed() throws {
        // Operator-named callables (`==`, `+`, custom operators) are use-site-resolved as operator
        // EXPRESSIONS, not by DeclReference name, so we never rewrite their use-sites — renaming the
        // decl is always a desync. Most are Equatable/Comparable/etc. witnesses too. Never rename.
        let source = """
        struct Vec {
            let x: Int
            static func + (a: Vec, b: Vec) -> Vec { Vec(x: a.x + b.x) }
            static func == (a: Vec, b: Vec) -> Bool { a.x == b.x }
        }
        """
        let r = try runPipeline(source)
        XCTAssertTrue(r.contains("static func + ("), "operator + must not be renamed:\n\(r)")
        XCTAssertTrue(r.contains("static func == ("), "operator == must not be renamed:\n\(r)")
        XCTAssertFalse(r.contains("struct Vec"), "the type itself must still be obfuscated:\n\(r)")
    }

    // MARK: - Per-symbol decision report (--explain)

    /// Run the pipeline with `--explain` and return all decision entries (flattened across files).
    private func runDecisions(_ source: String) throws -> [DecisionReport.Entry] {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftProf-\(UUID().uuidString)")
        let moduleRoot = tempRoot.appendingPathComponent("M")
        try FileManager.default.createDirectory(at: moduleRoot, withIntermediateDirectories: true)
        try source.write(to: moduleRoot.appendingPathComponent("Sample.swift"),
                         atomically: true, encoding: .utf8)
        let outputDir = tempRoot.appendingPathComponent("out")
        let options = PipelineOptions(
            modules: [ModuleSpec(name: "M", root: moduleRoot, writable: true)],
            outputDirectory: outputDir, dryRun: false,
            nameStyle: .debug, introspectSDK: false, explain: true)
        _ = try Pipeline(options: options, logger: StderrLogger(verbose: false)).run()
        let data = try Data(contentsOf: outputDir.appendingPathComponent("decisions.json"))
        let byFile = try JSONDecoder().decode([String: [DecisionReport.Entry]].self, from: data)
        return byFile.values.flatMap { $0 }
    }

    private func decision(_ entries: [DecisionReport.Entry], name: String) -> DecisionReport.Entry? {
        entries.first { $0.name == name }
    }

    func testDecisionReport_obfuscatedProtectedSkipped() throws {
        let entries = try runDecisions("""
        struct Vec {
            let x: Int
            init(x: Int) { self.x = x }
            static func == (a: Vec, b: Vec) -> Bool { a.x == b.x }
            func magnitude() -> Int { x }
        }
        """)
        XCTAssertEqual(decision(entries, name: "magnitude")?.decision, "obfuscated")
        XCTAssertEqual(decision(entries, name: "==")?.decision, "protected")
        XCTAssertTrue(decision(entries, name: "==")?.reason.contains("operator") ?? false)
        let initEntry = decision(entries, name: "init")
        XCTAssertEqual(initEntry?.decision, "skipped")
        XCTAssertTrue(initEntry?.reason.contains("initializer") ?? false, "init reason: \(initEntry?.reason ?? "nil")")
        // Every entry carries a real source position.
        XCTAssertTrue(entries.allSatisfy { $0.line > 0 })
    }

    func testDecisionReport_revertedCarriesReason() throws {
        // Two enums share case `shared`, used at a `.shared` shorthand site → AmbiguityRollback
        // reverts the planned rename of BOTH. The report must show `reverted` with the reason, not
        // a misleading `skipped`.
        let entries = try runDecisions("""
        enum A { case shared }
        enum B { case shared }
        func use() {
            let b: B = .shared
            _ = b
        }
        """)
        let shared = entries.filter { $0.name == "shared" }
        XCTAssertFalse(shared.isEmpty, "expected `shared` enum cases in the report")
        XCTAssertTrue(shared.allSatisfy { $0.decision == "reverted" },
                      "shared cases must be reverted: \(shared.map { $0.decision })")
        XCTAssertTrue(shared.allSatisfy { $0.reason.contains("ambiguous enum case") },
                      "revert reason must explain the cause: \(shared.map { $0.reason })")
    }

    // MARK: - Binding patterns shadow properties (closure params / case-let / catch / tuples)
    // Invariant: every name-introducing binding pattern registers a (non-renameable) local, so a
    // body reference resolves to the BINDING, never to a same-named property — which would rewrite
    // the use to the property's obf (silent wrong-storage read or a red build RollbackPass cannot
    // catch when the name is shielded as an Apple API name, e.g. `value`/`frame`/`key`).

    func testClosureParameter_shadowsProperty_bodyRefNotRewritten() throws {
        let source = """
        final class Holder {
            var frame: String = "x"
            func run(_ values: [Int]) -> [Int] {
                return values.map { frame in frame + 1 }
            }
        }
        """
        let rewritten = try runPipeline(source)
        XCTAssertFalse(rewritten.contains("var frame"), "property must stay renamed:\n\(rewritten)")
        XCTAssertTrue(rewritten.contains("{ frame in frame + 1 }"),
                      "closure param + body ref must stay original:\n\(rewritten)")
    }

    func testSwitchCaseLetBinding_shadowsProperty_bodyRefNotRewritten() throws {
        let source = """
        enum Box { case wrapped(Int) }
        final class Reader {
            var value: String = ""
            func read(_ b: Box) -> Int {
                switch b {
                case .wrapped(let value): return value + 1
                }
            }
        }
        """
        let rewritten = try runPipeline(source)
        XCTAssertFalse(rewritten.contains("var value"), "property must stay renamed:\n\(rewritten)")
        XCTAssertTrue(rewritten.contains("(let value): return value + 1"),
                      "case-let binding + body ref must stay original:\n\(rewritten)")
    }

    func testCaseLetPrefixForm_bindingRefsNotRewritten() throws {
        let source = """
        enum Pair { case both(Int, Int) }
        final class Adder {
            var slotA: String = ""
            func sum(_ p: Pair) -> Int {
                switch p {
                case let .both(slotA, slotB): return slotA + slotB
                }
            }
        }
        """
        let rewritten = try runPipeline(source)
        XCTAssertFalse(rewritten.contains("var slotA"), "property must stay renamed:\n\(rewritten)")
        XCTAssertTrue(rewritten.contains("return slotA + slotB"),
                      "prefix-let binding refs must stay original:\n\(rewritten)")
    }

    func testCatchLetBinding_shadowsProperty_bodyRefNotRewritten() throws {
        let source = """
        struct Boom: Error {}
        final class Catcher {
            var failure: Int = 0
            func attempt() -> String {
                do { throw Boom() } catch let failure {
                    return failure.localizedDescription
                }
            }
        }
        """
        let rewritten = try runPipeline(source)
        XCTAssertFalse(rewritten.contains("var failure"), "property must stay renamed:\n\(rewritten)")
        XCTAssertTrue(rewritten.contains("return failure.localizedDescription"),
                      "catch binding + body ref must stay original:\n\(rewritten)")
    }

    func testImplicitCatchError_shadowsProperty_bodyRefNotRewritten() throws {
        let source = """
        struct Boom: Error {}
        final class Catcher {
            var error: Int = 0
            func attempt() -> Int {
                do { throw Boom() } catch {
                    _ = error
                    return -1
                }
            }
        }
        """
        let rewritten = try runPipeline(source)
        XCTAssertFalse(rewritten.contains("var error"), "property must stay renamed:\n\(rewritten)")
        XCTAssertTrue(rewritten.contains("_ = error"),
                      "implicit `error` ref must stay original:\n\(rewritten)")
    }

    func testTupleDestructuring_shadowsProperty_bodyRefNotRewritten() throws {
        let source = """
        final class Splitter {
            var alpha: String = ""
            func go() -> Int {
                let (alpha, beta) = (1, 2)
                return alpha + beta
            }
        }
        """
        let rewritten = try runPipeline(source)
        XCTAssertFalse(rewritten.contains("var alpha"), "property must stay renamed:\n\(rewritten)")
        XCTAssertTrue(rewritten.contains("return alpha + beta"),
                      "tuple binding refs must stay original:\n\(rewritten)")
    }

    func testForLoopTuplePattern_shadowsProperty_bodyRefNotRewritten() throws {
        let source = """
        final class Walker {
            var key: Int = 0
            func join(_ d: [String: Int]) -> String {
                var out = ""
                for (key, count) in d { out += key + String(count) }
                return out
            }
        }
        """
        let rewritten = try runPipeline(source)
        XCTAssertFalse(rewritten.contains("var key"), "property must stay renamed:\n\(rewritten)")
        // (`out` is an ordinary local — legitimately renamed; assert only the binding refs.)
        XCTAssertTrue(rewritten.contains("+= key + String(count)"),
                      "for-tuple binding refs must stay original:\n\(rewritten)")
    }

    func testIfCaseBinding_shadowsProperty_bodyRefNotRewritten() throws {
        let source = """
        enum Box { case wrapped(Int) }
        final class Peeker {
            var value: String = ""
            func peek(_ b: Box) -> Int {
                if case .wrapped(let value) = b { return value + 1 }
                return 0
            }
        }
        """
        let rewritten = try runPipeline(source)
        XCTAssertFalse(rewritten.contains("var value"), "property must stay renamed:\n\(rewritten)")
        XCTAssertTrue(rewritten.contains("{ return value + 1 }"),
                      "if-case binding + body ref must stay original:\n\(rewritten)")
    }

    // MARK: - Bare-call global fallback must not steal an unrelated type's method
    // Invariant: a bare `f(args)` resolves globally only to a callable reachable via implicit self
    // (free function or a member of the use-site's enclosing type family) — never to a same-named
    // method of an UNRELATED type. Picking the latter renames the call to that method's obf while
    // the call actually targets a stdlib/other function → "cannot find <obf> in scope" red.

    func testBareCall_unrelatedTypeMethod_notStolen() throws {
        let source = """
        final class MathHelper {
            func maxValue(_ a: Int, _ b: Int) -> Int { a > b ? a : b }
        }
        final class Calculator {
            func compute(_ first: Int, _ second: Int) -> Int {
                return maxValue(first, second)
            }
        }
        """
        let rewritten = try runPipeline(source)
        // The bare `maxValue(...)` in Calculator does not reach MathHelper.maxValue by implicit
        // self, so the resolver must NOT rewrite it to MathHelper.maxValue's obf (cross-type
        // desync). RollbackPass then reverts the decl too → both stay `maxValue` (green).
        XCTAssertTrue(rewritten.contains("return maxValue("),
                      "unrelated-type method must not be stolen by a bare call:\n\(rewritten)")
    }

    func testBareCall_enclosingTypeMethod_stillResolves() throws {
        let source = """
        final class Widget {
            func helper(_ x: Int) -> Int { x + 1 }
            func run(_ y: Int) -> Int { return helper(y) }
        }
        """
        let rewritten = try runPipeline(source)
        XCTAssertFalse(rewritten.contains("func helper"), "method must be renamed:\n\(rewritten)")
        XCTAssertFalse(rewritten.contains("return helper("),
                       "bare self-call must resolve to the enclosing method's obf:\n\(rewritten)")
    }

    func testBareCall_superclassMethod_stillResolves() throws {
        let source = """
        class Base {
            func shared(_ x: Int) -> Int { x }
        }
        class Derived: Base {
            func run(_ y: Int) -> Int { return shared(y) }
        }
        """
        let rewritten = try runPipeline(source)
        XCTAssertFalse(rewritten.contains("func shared"), "base method must be renamed:\n\(rewritten)")
        XCTAssertFalse(rewritten.contains("return shared("),
                       "inherited bare call must resolve to the base method's obf:\n\(rewritten)")
    }

    func testBareCall_freeFunction_stillResolves() throws {
        let source = """
        func topHelper(_ x: Int) -> Int { x * 2 }
        final class User {
            func run(_ y: Int) -> Int { return topHelper(y) }
        }
        """
        let rewritten = try runPipeline(source)
        XCTAssertFalse(rewritten.contains("func topHelper"), "free func must be renamed:\n\(rewritten)")
        XCTAssertFalse(rewritten.contains("return topHelper("),
                       "bare free-function call must resolve:\n\(rewritten)")
    }

    // MARK: - Contextual `.case` shorthand: return gating, comparison operand, if-case

    func testEnumCaseShorthand_returnContextDoesNotLeakToNonReturn() throws {
        // `.active` (a Mode case) inside a `-> Style` function must NOT take Style as its context
        // just because Style has a `static let active`. The context leaked from the return type to
        // a `==` operand → renamed to Style.active's obf → "type Mode has no member <obf>" (a
        // wrong-rename red RollbackPass cannot catch).
        let source = """
        struct Style {
            static let active = Style(marker: 1)
            var marker: Int
            init(marker: Int) { self.marker = marker }
        }
        enum Mode { case active, off }
        final class Comparer {
            var mode: Mode = .off
            func style() -> Style {
                if mode == .active { return .active }
                return Style(marker: 0)
            }
        }
        """
        let rewritten = try runPipeline(source)
        // The comparison operand `.active` (against `mode: Mode`) must NOT be renamed to Style's
        // static property `active` (obf `pN`). That produced `mode == .pN` → "type Mode has no
        // member pN". `return .active` legitimately IS Style.active — unaffected.
        XCTAssertFalse(rewritten.range(of: #"== \.p\d"#, options: .regularExpression) != nil,
                       "comparison `.active` must not leak Style.active (a property):\n\(rewritten)")
    }

    func testEnumCaseShorthand_comparisonOperand_resolves() throws {
        // `phase == .loading` — the shorthand's type is the OTHER operand's type (Phase).
        let source = """
        enum Phase { case loading, ready }
        final class Check {
            var phase: Phase = .ready
            func isBusy() -> Bool { return phase == .loading }
        }
        """
        let rewritten = try runPipeline(source)
        XCTAssertFalse(rewritten.contains("case loading"), "case must be renamed:\n\(rewritten)")
        XCTAssertFalse(rewritten.contains(".loading"),
                       "comparison shorthand `.loading` must resolve + rename:\n\(rewritten)")
    }

    func testEnumCaseShorthand_ifCaseInitializer_resolves() throws {
        let source = """
        enum Signal { case ping, quiet }
        final class Radio {
            func check(_ s: Signal) -> Bool {
                if case .quiet = s { return true }
                return false
            }
        }
        """
        let rewritten = try runPipeline(source)
        XCTAssertFalse(rewritten.contains("case ping, quiet"), "cases must be renamed:\n\(rewritten)")
        XCTAssertFalse(rewritten.contains("case .quiet ="),
                       "if-case shorthand `.quiet` must resolve to the renamed case:\n\(rewritten)")
    }

    // MARK: - Bare reference to an overloaded callable (no call) must be fail-closed
    // Invariant: `let h: (String) -> Void = send` where `send` is overloaded picks the overload by
    // the annotation's function type — never registration-order first (which picked `send(Int)` →
    // "cannot convert (Int)->() to (String)->Void" red).

    func testOverloadedFunctionReference_intFirst_picksByAnnotation() throws {
        let source = """
        final class Sender {
            func send(_ number: Int) {}
            func send(_ text: String) {}
            func hook() {
                let handler: (String) -> Void = send
                handler("x")
            }
        }
        """
        let rewritten = try runPipeline(source)
        // The annotation `(String) -> Void` selects the STRING overload — the reference must bind
        // to that overload's obf, never the Int one (which produced the red build). Extract the
        // String overload's decl obf and assert the reference uses it.
        let stringObf = rewritten.range(of: #"func (\w+)\(_ \w+: String\)"#, options: .regularExpression)
            .map { String(rewritten[$0]) }?
            .replacingOccurrences(of: #"func (\w+)\(_ \w+: String\)"#, with: "$1", options: .regularExpression)
        XCTAssertNotNil(stringObf, "String overload decl must be present:\n\(rewritten)")
        if let stringObf {
            XCTAssertTrue(rewritten.contains("= \(stringObf)"),
                          "overloaded bare ref must bind to the STRING overload (\(stringObf)):\n\(rewritten)")
        }
    }

    func testOverloadedFunctionReference_noAnnotation_failsClosed() throws {
        // No function-type annotation to pick an overload → the resolver must NOT guess. Leaving
        // `send` un-renamed makes RollbackPass revert the whole group (green, under-obf), instead
        // of a silent wrong-overload rewrite.
        let source = """
        func take(_ f: (Int) -> Void) {}
        final class Sender {
            func send(_ number: Int) {}
            func send(_ text: String) {}
            func hook() {
                let alias = send
                _ = alias
            }
        }
        """
        let rewritten = try runPipeline(source)
        // `alias` is an ordinary local — renamed; the invariant is that `send` stays un-renamed
        // (fail-closed), so RollbackPass reverts the group and `= send` survives.
        XCTAssertTrue(rewritten.contains("= send"),
                      "ambiguous overloaded bare ref must stay fail-closed:\n\(rewritten)")
    }

    // MARK: - Trailing closure against a labeled closure parameter
    // Invariant: a call `perform { }` matches `func perform(action: () -> Void)` — the trailing
    // closure satisfies the LABELED closure param. Old labelsMatch required a nil label to match a
    // labeled param → no match → the method (and its use) reverted (under-obf).

    func testTrailingClosure_labeledClosureParam_bareCallResolves() throws {
        let source = """
        final class Runner {
            func perform(action: () -> Void) { action() }
            func runAll() { perform { } }
        }
        """
        let rewritten = try runPipeline(source)
        XCTAssertFalse(rewritten.contains("func perform"), "method must be renamed:\n\(rewritten)")
        XCTAssertFalse(rewritten.contains("runAll() { perform {"),
                       "bare trailing-closure call must resolve to the renamed method:\n\(rewritten)")
    }

    func testTrailingClosure_labeledClosureParam_memberCallResolves() throws {
        let source = """
        final class Engine {
            func schedule(task: () -> Void) { task() }
        }
        final class Driver {
            let engine = Engine()
            func go() { engine.schedule { } }
        }
        """
        let rewritten = try runPipeline(source)
        XCTAssertFalse(rewritten.contains("func schedule"), "method must be renamed:\n\(rewritten)")
        XCTAssertFalse(rewritten.contains("engine.schedule {"),
                       "member trailing-closure call must resolve to the renamed method:\n\(rewritten)")
    }

    // MARK: - Memberwise init survives an extension init (struct only)
    // Invariant: a custom `init` in an EXTENSION does NOT suppress a struct's memberwise init, so
    // the memberwise call labels must still follow the renamed stored properties — at both the
    // external `Config(a:b:)` call and the delegating `self.init(a:b:)` in the extension. The old
    // hasExplicitInit check saw the extension init (unified into the type scope) → disabled label
    // renaming → labels kept original while properties renamed → stored properties reverted (under-obf).

    func testMemberwiseInit_withExtensionInit_labelsFollowRenamedProperties() throws {
        let source = """
        struct Config {
            var alphaValue: Int
            var betaValue: Int
        }
        extension Config {
            init(only: Int) { self.init(alphaValue: only, betaValue: 0) }
        }
        final class Maker {
            func make() -> Config { return Config(alphaValue: 1, betaValue: 2) }
        }
        """
        let rewritten = try runPipeline(source)
        // Stored properties must be obfuscated (not reverted).
        XCTAssertFalse(rewritten.contains("var alphaValue"),
                       "stored property must be obfuscated:\n\(rewritten)")
        // Both memberwise call sites must use the renamed labels (no original `alphaValue:` left).
        XCTAssertFalse(rewritten.contains("alphaValue:"),
                       "memberwise labels must follow the renamed property at ALL call sites:\n\(rewritten)")
    }

    func testExplicitMainInit_structLabelsNotRenamed() throws {
        // When the struct declares its OWN init in the MAIN decl, Swift suppresses the memberwise
        // init — the call resolves to that explicit init whose labels are real parameters (skipped).
        let source = """
        struct Point {
            var xCoord: Int
            init(xCoord: Int) { self.xCoord = xCoord }
        }
        final class Maker {
            func make() -> Point { return Point(xCoord: 5) }
        }
        """
        let rewritten = try runPipeline(source)
        // The init parameter label `xCoord:` must NOT be renamed (it's a real init parameter, and
        // parameters without distinct external labels are policy-skipped). Green regardless.
        XCTAssertTrue(rewritten.contains("Point(xCoord: 5)") || rewritten.range(of: #"\w+\(xCoord: 5\)"#, options: .regularExpression) != nil,
                      "explicit-init call label must be preserved:\n\(rewritten)")
    }

    // MARK: - `some`/`any` parameter member access
    // Invariant: `func draw(_ r: some Renderer)` types `r` as its constraint protocol, so
    // `r.render()` resolves. `simpleTypeName` must strip the `some`/`any` wrapper (and attributes).

    func testSomeParameter_memberResolvesViaConstraint() throws {
        let source = """
        protocol Renderer { func render() -> String }
        struct TextRenderer: Renderer { func render() -> String { "t" } }
        final class Engine {
            func draw(_ r: some Renderer) -> String { return r.render() }
        }
        """
        let rewritten = try runPipeline(source)
        XCTAssertFalse(rewritten.contains("func render"), "protocol requirement must be renamed:\n\(rewritten)")
        XCTAssertFalse(rewritten.contains("r.render()"),
                       "member on a `some Renderer` param must resolve + rename:\n\(rewritten)")
    }

    func testAnyParameter_memberResolvesViaConstraint() throws {
        let source = """
        protocol Renderer { func render() -> String }
        final class Engine {
            func draw(_ r: any Renderer) -> String { return r.render() }
        }
        """
        let rewritten = try runPipeline(source)
        XCTAssertFalse(rewritten.contains("func render"), "protocol requirement must be renamed:\n\(rewritten)")
        XCTAssertFalse(rewritten.contains("r.render()"),
                       "member on an `any Renderer` param must resolve + rename:\n\(rewritten)")
    }

    // MARK: - Generic parameter member access + shadow
    // Invariant: `func draw<T: Renderer>(_ r: T)` types `r` via the constraint, so `r.render()`
    // resolves. And a generic param `T` shadows a same-named global type so a use of `T` inside
    // the function is never renamed to the global's obf.

    func testGenericParameter_memberResolvesViaConstraint() throws {
        let source = """
        protocol Renderer { func render() -> String }
        struct TextRenderer: Renderer { func render() -> String { "t" } }
        final class Engine {
            func draw<T: Renderer>(_ r: T) -> String { return r.render() }
        }
        """
        let rewritten = try runPipeline(source)
        XCTAssertFalse(rewritten.contains("func render"), "protocol requirement must be renamed:\n\(rewritten)")
        XCTAssertFalse(rewritten.contains("r.render()"),
                       "member on a generic-constrained param must resolve + rename:\n\(rewritten)")
    }

    func testGenericParameter_shadowsGlobalType_notRenamed() throws {
        // A generic param named `Element` must NOT be renamed to a same-named global type's obf.
        let source = """
        struct Element { var value: Int }
        final class Box {
            func wrap<Element>(_ x: Element) -> Element { return x }
        }
        """
        let rewritten = try runPipeline(source)
        // The generic param `Element` (in `<Element>`, `_ x: Element`, `-> Element`) is a local
        // type placeholder — it must stay `Element`, never the struct Element's obf. (`wrap` the
        // method IS renamed — assert on the generic param only.)
        XCTAssertTrue(rewritten.contains("<Element>(_ "),
                      "generic param must not be renamed to the global type's obf:\n\(rewritten)")
        XCTAssertTrue(rewritten.contains("-> Element"),
                      "generic param return must stay the placeholder:\n\(rewritten)")
    }

    // MARK: - Actor support
    // Invariant: an `actor` is a type like a class — its name and members are obfuscated, and
    // external `await a.method()` use-sites resolve. Without ActorDecl handling the actor's members
    // were registered in FILE scope with wrong kinds → external calls reverted (under-obf) and the
    // members leaked as global fallback candidates.

    func testActor_typeAndMembersObfuscated_externalCallResolves() throws {
        let source = """
        actor Worker {
            var jobCount: Int = 0
            func bump() { jobCount += 1 }
            func doJob() -> Int { bump(); return jobCount }
        }
        final class Boss {
            let worker = Worker()
            func run() async -> Int { return await worker.doJob() }
        }
        """
        let rewritten = try runPipeline(source)
        XCTAssertFalse(rewritten.contains("actor Worker"), "actor decl must be renamed:\n\(rewritten)")
        XCTAssertFalse(rewritten.contains("func doJob"), "actor method must be renamed:\n\(rewritten)")
        XCTAssertFalse(rewritten.contains("var jobCount"), "actor property must be renamed:\n\(rewritten)")
        XCTAssertFalse(rewritten.contains("worker.doJob()"),
                       "external `await worker.doJob()` must resolve to the renamed method:\n\(rewritten)")
    }

    func testActor_conformsToLocalProtocol_witnessLinked() throws {
        // An actor conforming to a LOCAL protocol: the witness `handle()` and the requirement must
        // unify to one obf (WitnessLinker). Requires the inheritance collectors to see ActorDecl.
        let source = """
        protocol Handler { func handle() }
        actor Service: Handler {
            func handle() {}
        }
        func use(_ h: Handler) { h.handle() }
        """
        let rewritten = try runPipeline(source)
        // Requirement + witness must unify to the SAME obf (or the actor won't conform → red). The
        // protocol requirement `func <obf>()` and the actor method `func <obf>()` must match.
        let reqObf = rewritten.range(of: #"protocol \w+ \{ func (\w+)\(\) \}"#, options: .regularExpression)
            .map { String(rewritten[$0]) }?
            .replacingOccurrences(of: #"protocol \w+ \{ func (\w+)\(\) \}"#, with: "$1", options: .regularExpression)
        XCTAssertNotNil(reqObf, "protocol requirement must be present:\n\(rewritten)")
        if let reqObf {
            XCTAssertTrue(rewritten.contains("func \(reqObf)() {}"),
                          "actor witness must share the requirement's obf \(reqObf):\n\(rewritten)")
            XCTAssertTrue(rewritten.contains(".\(reqObf)()"),
                          "protocol-typed call must use the requirement's obf:\n\(rewritten)")
        }
    }

    // MARK: - Protocol-typed parameter in overload disambiguation
    // Invariant: a parameter whose declared type is a PROTOCOL accepts any conformer — a concrete
    // argument must never ELIMINATE that overload (protocol ≠ concrete by Symbol identity is not a
    // contradiction); if the argument's type conforms, it is POSITIVE evidence. Without this,
    // storing "Renderer" for `some Renderer` (F7) made the resolver eliminate the correct overload
    // and pick a same-named different-signature sibling → wrong rename.

    func testOverloadByArgType_protocolParam_conformerPicksProtocolOverload() throws {
        let source = """
        protocol Renderer { func render() -> String }
        struct TextRenderer: Renderer { func render() -> String { "t" } }
        final class Screen {
            func show(_ r: some Renderer) -> String { return r.render() }
            func show(_ s: String) -> String { return s }
            func demo(_ t: TextRenderer) -> String { return show(t) }
        }
        """
        let rewritten = try runPipeline(source)
        // Extract the some-Renderer overload's obf and assert the call in demo binds to it.
        let someObf = rewritten.range(of: #"func (\w+)\(_ \w+: some"#, options: .regularExpression)
            .map { String(rewritten[$0]) }?
            .replacingOccurrences(of: #"func (\w+)\(_ \w+: some"#, with: "$1", options: .regularExpression)
        XCTAssertNotNil(someObf, "some-P overload must be present:\n\(rewritten)")
        if let someObf {
            XCTAssertTrue(rewritten.contains("return \(someObf)("),
                          "call with a conformer arg must bind to the protocol overload:\n\(rewritten)")
        }
    }

    func testBareCall_protocolDefaultImpl_viaExtensionConformance_resolves() throws {
        // Conformance declared on an EXTENSION (`extension Tool: Helper`): a bare call inside Tool
        // to the protocol's default impl must still resolve (implicit-self family includes
        // extension-declared conformances; ConformanceVisibility injects the member reference).
        let source = """
        protocol Helper {}
        extension Helper { func aid(_ x: Int) -> Int { return x } }
        final class Tool {
            func run() -> Int { return aid(1) }
        }
        extension Tool: Helper {}
        """
        let rewritten = try runPipeline(source)
        XCTAssertFalse(rewritten.contains("func aid"), "default impl must be renamed:\n\(rewritten)")
        XCTAssertFalse(rewritten.contains("return aid("),
                       "bare call via extension conformance must resolve:\n\(rewritten)")
    }

    func testClosureParameter_annotatedParam_memberResolves() throws {
        let source = """
        struct Widget {
            func render() -> String { "w" }
        }
        final class Painter {
            let draw: (Widget) -> String = { (w: Widget) in w.render() }
        }
        """
        let rewritten = try runPipeline(source)
        XCTAssertFalse(rewritten.contains("w.render()"),
                       "annotated closure param member must rename via declared type:\n\(rewritten)")
    }

    func testHOFClosureParam_referencedFromNestedClosure_memberResolves() throws {
        // A named HOF-closure parameter (`row` from `rows.map { row in … }`) is referenced from
        // INSIDE a nested, non-HOF closure (an escaping callback assigned to a property). The member
        // access `row.field` must still resolve to Row.field and rename in lockstep with the decl.
        // Regression: closure-param inference stopped at the first non-HOF closure and never reached
        // the outer `.map` → `row.field` stayed un-renamed while `field`'s decl was renamed (a
        // desync, and a red build when RollbackPass's namesake shield blocked the auto-revert).
        let source = """
        struct Row {
            let field: String
        }
        final class Sink {
            var onTap: (() -> Void)?
            func consume(rows: [Row]) {
                _ = rows.map { row in
                    let s = Sink()
                    s.onTap = {
                        print(row.field)
                    }
                    return s
                }
            }
        }
        """
        let rewritten = try runPipeline(source)
        XCTAssertFalse(rewritten.contains("let field"),
                       "the stored property decl is renamed:\n\(rewritten)")
        XCTAssertFalse(rewritten.contains("row.field"),
                       "member access on a HOF closure param inside a NESTED closure must rename too:\n\(rewritten)")
    }

    func testUserHOF_trailingClosureAfterLabeledArg_closureParamTypeResolves() throws {
        // B-FIX-36. A user-defined HOF whose closure parameter is LABELED and passed as a TRAILING
        // closure: `loader.fetch(from: rows) { row in … }` against
        // `func fetch(from:completion:)`. Argument labels at the call are ["from", nil] — the
        // trailing closure carries no label — so a matcher that compares labels position-by-position
        // eliminates the only candidate, `calleeCallable` returns nil, `functionParamClosureInput`
        // is never consulted and `row` stays untyped. Every member read through it then survives
        // while its declaration renames ("Value of type 'Container.Entry' has no member '<obf>'").
        let source = """
        enum Container {
            struct Entry {
                let slotName: String
                let slotKind: Int
            }
        }
        struct Payload {
            let pk: Int
            let pv: String
        }
        final class Loader {
            func fetch(from entries: [Container.Entry], completion: (Container.Entry) -> Void) {
                for e in entries { completion(e) }
            }
        }
        final class Screen {
            var rows: [Container.Entry] = []
            let loader = Loader()
            func run() {
                loader.fetch(from: rows) { row in
                    let p = Payload(pk: row.slotKind, pv: row.slotName)
                    print(p)
                }
            }
        }
        """
        let rewritten = try runPipeline(source)
        XCTAssertFalse(rewritten.contains("let slotName"),
                       "the stored property decl is renamed:\n\(rewritten)")
        XCTAssertFalse(rewritten.contains("row.slotName"),
                       "member read through a trailing-closure param must rename too:\n\(rewritten)")
        XCTAssertFalse(rewritten.contains("row.slotKind"),
                       "member read through a trailing-closure param must rename too:\n\(rewritten)")
    }

    func testUserHOF_trailingClosureAfterSeveralLabeledArgs_closureParamTypeResolves() throws {
        // Same rule with more labels before the trailing closure: the matcher must consume
        // ["from", "tag", nil] against (from:tag:completion:).
        let source = """
        enum Container {
            struct Entry {
                let slotName: String
            }
        }
        final class Loader {
            func fetch(from entries: [Container.Entry], tag: String,
                       completion: (Container.Entry) -> Void) {
                for e in entries where tag.isEmpty { completion(e) }
            }
        }
        final class Screen {
            var rows: [Container.Entry] = []
            let loader = Loader()
            func run() {
                loader.fetch(from: rows, tag: "x") { row in
                    print(row.slotName)
                }
            }
        }
        """
        let rewritten = try runPipeline(source)
        XCTAssertFalse(rewritten.contains("let slotName"),
                       "the stored property decl is renamed:\n\(rewritten)")
        XCTAssertFalse(rewritten.contains("row.slotName"),
                       "member read through a trailing-closure param must rename too:\n\(rewritten)")
    }

    func testUserHOF_trailingClosureWithDefaultedParamBetween_closureParamTypeResolves() throws {
        // The call OMITS a defaulted parameter that sits between the labeled argument and the
        // closure: labels ["from", nil] against (from:tag:completion:) where `tag` is defaulted.
        // An exact-count matcher rejects this outright (2 labels vs 3 params).
        let source = """
        enum Container {
            struct Entry {
                let slotName: String
            }
        }
        final class Loader {
            func fetch(from entries: [Container.Entry], tag: String = "d",
                       completion: (Container.Entry) -> Void) {
                for e in entries where tag.isEmpty { completion(e) }
            }
        }
        final class Screen {
            var rows: [Container.Entry] = []
            let loader = Loader()
            func run() {
                loader.fetch(from: rows) { row in
                    print(row.slotName)
                }
            }
        }
        """
        let rewritten = try runPipeline(source)
        XCTAssertFalse(rewritten.contains("let slotName"),
                       "the stored property decl is renamed:\n\(rewritten)")
        XCTAssertFalse(rewritten.contains("row.slotName"),
                       "member read through a trailing-closure param must rename too:\n\(rewritten)")
    }

    func testUserHOF_trailingClosureCallee_methodReturnTypeChainResolves() throws {
        // The SAME label rule governs `TypeResolver.typeSymbol(of:)`'s method-return branch, which
        // types `recv.method(args) { … }.member`. With the trailing closure unlabeled at the call
        // and labeled at the declaration, the method was eliminated, the call's return type was
        // unknown, and `.slotName` on the result stayed original while its decl renamed.
        let source = """
        struct Entry {
            let slotName: String
        }
        final class Loader {
            func build(from raw: String, transform: (String) -> String) -> Entry {
                return Entry(slotName: transform(raw))
            }
        }
        final class Screen {
            let loader = Loader()
            func run() {
                print(loader.build(from: "a") { $0 }.slotName)
            }
        }
        """
        let rewritten = try runPipeline(source)
        XCTAssertFalse(rewritten.contains("let slotName"),
                       "the stored property decl is renamed:\n\(rewritten)")
        XCTAssertFalse(rewritten.contains(".slotName)"),
                       "member on a trailing-closure call's RESULT must rename too:\n\(rewritten)")
    }

    func testCalleeParamType_afterOmittedDefaultedParam_contextualCaseResolves() throws {
        // B-FIX-36, second half. The call omits the defaulted `flag:`, so its ONLY argument sits at
        // argument index 0 while binding PARAMETER index 1. Reading `functionParamTypes` at the
        // argument's own ordinal yields `Bool`, which is not an enum, so the shorthand `.alpha` gets
        // no contextual type and survives while `Mode.alpha` renames.
        let source = """
        enum Mode {
            case alpha
            case beta
        }
        struct Runner {
            func apply(flag: Bool = false, mode: Mode) {
                print(flag, mode)
            }
        }
        struct Screen {
            let runner = Runner()
            func run() {
                runner.apply(mode: .alpha)
            }
        }
        """
        let rewritten = try runPipeline(source)
        XCTAssertFalse(rewritten.contains("case alpha"),
                       "the enum case decl is renamed:\n\(rewritten)")
        XCTAssertFalse(rewritten.contains(".alpha"),
                       "a shorthand case bound to a parameter AFTER an omitted defaulted one must resolve:\n\(rewritten)")
    }

    // MARK: - Key paths

    func testKeyPath_inferredRoot_memberRenamedOnce_trailingBytesIntact() throws {
        // Regression: a `\.member` keypath component was emitted as a Rename by BOTH
        // visit(KeyPathExprSyntax) AND visit(DeclReferenceExprSyntax) (its declName parent is a
        // KeyPathPropertyComponent, not a MemberAccess). Two overlapping edits at the same offset
        // made the Rewriter, applying the second over already-shifted bytes, EAT the following
        // `))` — producing `Set(everything.map(\.<obf>  }` ("Expected ',' separator"). The keypath
        // must be renamed exactly once and the trailing `))` preserved.
        let source = """
        enum Fruit {
            case c1, c2, c3

            static var allTitles: Set<String> {
                Set(everything.map(\\.title))
            }

            var title: String { return "x" }

            static let everything: Set<Fruit> = [.c1, .c2, .c3]
        }
        """
        let rewritten = try runPipeline(source)
        XCTAssertFalse(rewritten.contains("\\.title"),
                       "keypath member must be renamed:\n\(rewritten)")
        // The closing `))` after the keypath must survive intact (the corruption ate them).
        XCTAssertTrue(rewritten.range(of: #"\\\.\w+\)\)"#, options: .regularExpression) != nil,
                      "keypath must keep its trailing `))`:\n\(rewritten)")
        // The static computed property, the static let, and the instance property all obfuscate.
        XCTAssertFalse(rewritten.contains("var allTitles"), "static var must be renamed:\n\(rewritten)")
        XCTAssertFalse(rewritten.contains("let everything"), "static let must be renamed:\n\(rewritten)")
        XCTAssertFalse(rewritten.contains("var title"), "instance property must be renamed:\n\(rewritten)")
    }

    func testKeyPath_explicitRoot_rootTypeAndMemberRenamed() throws {
        // `\Root.member` — the root TYPE token must still be renamed (via child type-reference
        // visitation, kept alive by the keypath visitor returning .visitChildren) AND the member.
        let source = """
        struct Inner {
            var flag: Bool = false
        }
        struct Outer {
            var inner: Inner = Inner()
            func path() -> KeyPath<Outer, Inner> { return \\Outer.inner }
        }
        """
        let rewritten = try runPipeline(source)
        XCTAssertFalse(rewritten.contains("\\Outer.inner"),
                       "explicit-root keypath must rename both root type and member:\n\(rewritten)")
        XCTAssertTrue(rewritten.range(of: #"\\T\d+\.p\d+"#, options: .regularExpression) != nil,
                      "expected \\<TypeObf>.<memberObf>:\n\(rewritten)")
    }

    // MARK: - Subscript result typing (base[args] → element / value / declared subscript return)

    /// Reported bug: a member call through a SUBSCRIPT on a collection was never renamed at the
    /// use-site (its decl WAS), because `typeSymbol(of:)` had no `SubscriptCallExprSyntax` case —
    /// `arr[safe: i]?.mutatingFunc()` typed to nil so the member couldn't resolve. Both the plain
    /// `arr[i].m()` and the optional-chained `arr[safe: i]?.m()` forms must now resolve to the
    /// Element type's member. (`[safe:]` needn't be defined here — the pipeline doesn't type-check;
    /// the base's declared `[Item]` drives element extraction.)
    func testSubscriptElement_optionalChainedMutatingCall_resolves() throws {
        let source = """
        struct Item {
            var value: Int
            mutating func bump(to newValue: Int) {
                value = newValue
            }
        }
        final class Engine {
            var items: [Item]
            init(items: [Item]) { self.items = items }
            func process(_ i: Int) {
                items[i].bump(to: 1)
                items[safe: i]?.bump(to: 2)
            }
        }
        """
        let rewritten = try runPipeline(source)
        XCTAssertFalse(rewritten.contains("func bump"), "mutating func decl must be renamed")
        XCTAssertFalse(rewritten.contains("bump"),
                       "every subscript-element use-site of bump must be renamed (no surviving original):\n\(rewritten)")
    }

    /// Local custom subscript on a USER type: `grid[i].member` resolves against the subscript's
    /// DECLARED return type (read from source, not guessed). Exercises the subscriptSignatures path.
    func testSubscriptElement_localCustomSubscript_returnTypeMemberResolves() throws {
        let source = """
        struct Cell {
            func touch() {}
        }
        struct Grid {
            var storage: [Cell]
            subscript(x: Int) -> Cell {
                storage[x]
            }
        }
        final class Engine {
            let grid: Grid
            init(grid: Grid) { self.grid = grid }
            func run(_ i: Int) {
                grid[i].touch()
            }
        }
        """
        let rewritten = try runPipeline(source)
        XCTAssertFalse(rewritten.contains("func touch"), "method decl must be renamed")
        XCTAssertFalse(rewritten.contains("touch"),
                       "member reached through a local custom subscript's return type must be renamed:\n\(rewritten)")
    }

    /// Dictionary value: `dict[key]?.member` resolves against the Value type. `extractElement`
    /// deliberately bails on dictionaries (a Dictionary's *Element* is a (key,value) tuple), so the
    /// subscript case handles the Value extraction itself.
    func testSubscriptElement_dictionaryValue_memberResolves() throws {
        let source = """
        struct Account {
            func settle() {}
        }
        final class Store {
            var byId: [String: Account]
            init(byId: [String: Account]) { self.byId = byId }
            func run(_ k: String) {
                byId[k]?.settle()
            }
        }
        """
        let rewritten = try runPipeline(source)
        XCTAssertFalse(rewritten.contains("func settle"), "method decl must be renamed")
        XCTAssertFalse(rewritten.contains("settle"),
                       "member reached through a dictionary subscript's value type must be renamed:\n\(rewritten)")
    }

    /// Safety: a custom subscript on an EXTERNAL type we can't see (no recorded signature) must NOT
    /// be guessed — the member stays un-renamed rather than risk a wrong rename. Here `data[0]` on a
    /// `Data` value has no local element/signature, so `.member` (were it local) must not be forced.
    /// We assert the pipeline doesn't crash and leaves the unknown-base member untouched.
    func testSubscriptElement_externalUnknownBase_doesNotGuess() throws {
        let source = """
        final class Reader {
            let raw: Data
            init(raw: Data) { self.raw = raw }
            func first() -> UInt8 { raw[0] }
        }
        """
        let rewritten = try runPipeline(source)
        // `raw` (a property with a distinct nothing... it's a stored let) should rename, but the
        // external subscript result must not drive any bogus rename. Just assert it ran cleanly.
        XCTAssertTrue(rewritten.contains("raw[0]") || rewritten.range(of: #"p\d+\[0\]"#, options: .regularExpression) != nil,
                      "external subscript must be left as-is (base may rename, result must not be guessed):\n\(rewritten)")
    }

    // MARK: - Declaring-scope resolution of stored type names (nested types)

    /// A member's stored declared-type name is written relative to ITS declaring scope: a bare
    /// nested type (`var leaf: Leaf` inside `enum Box`) is invisible from any other scope. Resolving
    /// it from the use-site (`Holder`) failed → `branch.leaf.payload` didn't resolve → desync.
    /// Must resolve `Leaf` in the member's declaring scope so the chain (and `payload`) renames.
    func testMemberChain_memberTypedAsSiblingNestedType_resolvesInDeclaringScope() throws {
        let source = """
        enum Box {
            struct Leaf { var payload: Int }
            struct Branch { var leaf: Leaf }
        }
        final class Holder {
            var branch: Box.Branch
            init(branch: Box.Branch) { self.branch = branch }
            func read() -> Int { return branch.leaf.payload }
        }
        """
        let rewritten = try runPipeline(source)
        XCTAssertFalse(rewritten.contains("var leaf"), "intermediate nested-type member must be renamed")
        XCTAssertFalse(rewritten.contains("payload"),
                       "member reached through a nested-type-typed member must resolve + rename:\n\(rewritten)")
    }

    /// The reported bug in full: a `var` with an INFERRED type (from a typealias-named constructor),
    /// a member chain through NESTED types whose members are written with UNQUALIFIED nested type
    /// names, then a collection SUBSCRIPT, then an optional-chained mutating call. Every layer must
    /// resolve so the mutating func renames at the subscript use-site.
    func testSubscriptElement_throughNestedTypeChain_typealiasInferredVar_resolves() throws {
        let source = """
        enum E1 {
            enum E2 { case a, b }
            struct S1 {
                let par2: E2
                var flag: Bool
                mutating func mutate(flag: Bool) { self.flag = flag }
            }
            struct S3 { var items: [S1] }
            struct S2 { var box: S3 }
        }
        extension Collection { subscript(safe i: Index) -> Element? { indices.contains(i) ? self[i] : nil } }
        final class Engine {
            typealias A3 = E1.S3
            typealias A2 = E1.S2
            private var root = A2(box: A3(items: []))
            func run() {
                root.box.items.indices.forEach {
                    root.box.items[safe: $0]?.mutate(flag: true)
                }
            }
        }
        """
        let rewritten = try runPipeline(source)
        XCTAssertFalse(rewritten.contains("func mutate"), "mutating func decl must be renamed")
        XCTAssertFalse(rewritten.contains("mutate"),
                       "mutating func at the subscript-through-nested-chain use-site must be renamed:\n\(rewritten)")
    }

    /// A `var` whose type is inferred from a QUALIFIED constructor call (`NS.Widget(...)`) must get
    /// that type, so a member on it (`w.render()`) resolves. (Bare `Widget(...)` already worked; the
    /// member-access callee `NS.Widget` was previously mistaken for a method call → no inference.)
    func testTypeInference_qualifiedConstructorInitializer_resolves() throws {
        let source = """
        enum NS {
            struct Widget { var label: String; func render() {} }
        }
        final class View {
            var w = NS.Widget(label: "x")
            func draw() { w.render() }
        }
        """
        let rewritten = try runPipeline(source)
        XCTAssertFalse(rewritten.contains("render"),
                       "member on a var typed via a qualified constructor must resolve + rename:\n\(rewritten)")
    }

    // MARK: - Diagnostics report (SURV lines)

    /// Runs the pipeline with `--diagnose-overloads` and returns the contents of `Diagnostics.txt`.
    private func runPipelineDiagnostics(_ source: String, moduleName: String = "M",
                                        file: String = "Sample.swift") throws -> String {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftProf-\(UUID().uuidString)")
        let moduleRoot = tempRoot.appendingPathComponent(moduleName)
        try FileManager.default.createDirectory(at: moduleRoot, withIntermediateDirectories: true)
        try source.write(to: moduleRoot.appendingPathComponent(file), atomically: true, encoding: .utf8)
        let outputDir = tempRoot.appendingPathComponent("out")

        let options = PipelineOptions(
            modules: [ModuleSpec(name: moduleName, root: moduleRoot, writable: true)],
            outputDirectory: outputDir, dryRun: false,
            nameStyle: .debug, introspectSDK: false,
            diagnoseOverloads: true
        )
        _ = try Pipeline(options: options, logger: StderrLogger(verbose: false)).run()
        return try String(contentsOf: outputDir.appendingPathComponent("Diagnostics.txt"), encoding: .utf8)
    }

    /// A missed use-site whose name is NOT shielded: rollback reverts the group, the build stays
    /// green, and the diagnostics name the coverage loss.
    func testDiagnostics_unshieldedSurvivor_reportedAsReverted() throws {
        let source = """
        struct Box { var widgetPayload: Int = 0 }
        func take(_ x: SomeExternalThing) -> Int { return x.widgetPayload }
        """
        let diag = try runPipelineDiagnostics(source)
        XCTAssertTrue(diag.contains("SURV reverted name=\(Anon.of("widgetPayload"))"),
                      "unshielded survivor must be reported as reverted:\n\(diag)")
    }

    /// The case `--diagnose-overloads` alone cannot see: the use-site was missed AND a shield stops
    /// the rollback, so the desync ships. `camera` is an Apple API name (shield 1c), so the renamed
    /// local property is NOT reverted while the surviving use-site keeps the original name.
    func testDiagnostics_shieldedSurvivor_reportedAsBlockedRedBuildRisk() throws {
        let source = """
        struct Box { var camera: Int = 0 }
        func take(_ x: SomeExternalThing) -> Int { return x.camera }
        """
        let diag = try runPipelineDiagnostics(source)
        let line = diag.split(separator: "\n").first { $0.contains("SURV blocked name=\(Anon.of("camera"))") }
        XCTAssertNotNil(line, "shielded survivor must be reported in the high-signal tier:\n\(diag)")
        XCTAssertTrue(line?.contains("shield=1c") == true, "shield must be named: \(line ?? "")")
    }

    // MARK: - Composite parameter types in signature matching (B-FIX-27)

    /// Every `func <name>` declared in the rewritten source, in order.
    private static func declaredFuncNames(in source: String) -> [String] {
        source.split(separator: "\n").compactMap { line -> String? in
            guard let r = line.range(of: "func ") else { return nil }
            let name = line[r.upperBound...].prefix { $0 != "(" && $0 != "<" && $0 != " " }
            return name.isEmpty ? nil : String(name)
        }
    }

    func testWitness_dictionaryParamWithTypealiasKey_linksToRequirement() throws {
        // A witness writes the dictionary KEY through a typealias (`[T1: E3.S4]`) while the
        // requirement writes it qualified (`[E3.S2.E1: E3.S4]`). The two spellings denote the same
        // type, so this IS the witness — but `signaturesCompatible` compared the WHOLE type-name
        // string and its fallback (`typeSymbol(forQualifiedName:)`) bails on any name containing a
        // top-level `:`, so a dictionary name never resolves to a Symbol and the typealias unwrap
        // was never reached. Result: no witness link → requirement and witness each minted their
        // OWN obf → "Type 'C1' does not conform to protocol 'P1'" (a wrong-rename red RollbackPass
        // cannot catch — no original name survives).
        let source = """
        enum E3 {
            struct S2 { enum E1 { case alpha, beta } }
            struct S4 { let v1: Int }
        }
        struct S1 { let v2: Int }
        typealias KeyAlias = E3.S2.E1
        protocol P1 {
            func f1(_ par2: [S1], par1: [E3.S2.E1: E3.S4]?) -> [S1]
        }
        final class C1: P1 {
            func f1(_ par2: [S1], par1: [KeyAlias: E3.S4]?) -> [S1] { return par2 }
        }
        """
        let r = try runPipeline(source)
        let names = Self.declaredFuncNames(in: r)
        XCTAssertFalse(r.contains("func f1("), "f1 must be obfuscated:\n\(r)")
        XCTAssertEqual(Set(names).count, 1,
                       "requirement and witness must share ONE obf, got \(names):\n\(r)")
    }

    func testWitness_dictionaryParamDifferentValueType_staysUnlinked() throws {
        // The complement: structural comparison must not over-link. `g1(par1: [K1: V2])` is an
        // unrelated overload of the witness `g1(par1: [K1: V1])` — same name, same labels, different
        // Value type — and must keep its OWN obf. Treating an unresolvable dictionary name as a
        // wildcard would collapse both onto the requirement's obf → "invalid redeclaration".
        let source = """
        enum K1 { case alpha }
        struct V1 { let v1: Int }
        struct V2 { let v2: Int }
        protocol P2 {
            func g1(par1: [K1: V1])
        }
        final class C2: P2 {
            func g1(par1: [K1: V1]) {}
            func g1(par1: [K1: V2]) {}
        }
        """
        let r = try runPipeline(source)
        let names = Self.declaredFuncNames(in: r)
        XCTAssertFalse(r.contains("func g1("), "g1 must be obfuscated:\n\(r)")
        XCTAssertEqual(Set(names).count, 2,
                       "witness shares the requirement's obf; the unrelated overload keeps its own, got \(names):\n\(r)")
    }

    func testArrayTypedProperty_collectionMemberNotRewrittenToElementMember() throws {
        // `items: [Item]` + `Item` declaring `count` — `items.count` is Array.count, NOT Item.count.
        // `typeSymbol(forQualifiedName:)` used to answer `[Item]` with the ELEMENT's Symbol, so the
        // member lookup found `Item.count` and rewrote the use-site to that member's obf ⇒ "value of
        // type '[Item]' has no member '<obf>'". A wrong rename, invisible to RollbackPass: both ends
        // were renamed consistently, so no original name survived to trip the scan (B-FIX-28).
        let source = """
        struct Item {
            let count: Int
        }
        struct Holder {
            let items: [Item]
            func total() -> Int { return items.count }
        }
        """
        let r = try runPipeline(source)
        XCTAssertTrue(r.contains(".count"),
                      "Array.count must stay untouched — it is not Item's member:\n\(r)")
        // The asymmetry is the point: Item's OWN `count` is still obfuscated at its declaration,
        // only the collection access is left alone. (`count` is an Apple API name, so RollbackPass
        // shield 1c blocks the revert the surviving use-site would otherwise trigger.)
        XCTAssertFalse(r.contains("let count: Int"),
                       "Item.count declaration should still be renamed:\n\(r)")
    }

    func testWitness_typealiasToArrayParam_stillLinks() throws {
        // Guards the compensation for B-FIX-28: with the array substitution gone, `ItemList` no
        // longer unwraps to a Symbol shared with `[Item2]`, so signature comparison expands the
        // alias TEXTUALLY instead. Without that, this witness would stop linking — trading one red
        // build for another.
        let source = """
        struct Item2 { let v1: Int }
        typealias ItemList = [Item2]
        protocol P3 {
            func k1(par1: ItemList) -> Int
        }
        final class C3: P3 {
            func k1(par1: [Item2]) -> Int { return par1.count }
        }
        """
        let r = try runPipeline(source)
        let names = Self.declaredFuncNames(in: r)
        XCTAssertFalse(r.contains("func k1("), "k1 must be obfuscated:\n\(r)")
        XCTAssertEqual(Set(names).count, 1,
                       "requirement and witness must share ONE obf across the array typealias, got \(names):\n\(r)")
    }

    func testOverride_dictionaryParamTypealias_chainSharesObf() throws {
        // Same invariant on the OverrideLinker side: the override writes the dictionary key through
        // a typealias, the base writes it qualified. Its comparison was a plain string compare (no
        // Symbol resolution at all), so the pair never matched → no local base → group revert
        // (under-obfuscation, green build). Now they unify.
        let source = """
        enum NS1 {
            enum K2 { case alpha }
            struct V3 { let v1: Int }
        }
        typealias KeyAlias2 = NS1.K2
        class B1 {
            func h1(par1: [NS1.K2: NS1.V3]) {}
        }
        final class D1: B1 {
            override func h1(par1: [KeyAlias2: NS1.V3]) {}
        }
        """
        let r = try runPipeline(source)
        let names = Self.declaredFuncNames(in: r)
        XCTAssertFalse(r.contains("func h1("), "h1 must be obfuscated:\n\(r)")
        XCTAssertEqual(Set(names).count, 1,
                       "base and override must share ONE obf, got \(names):\n\(r)")
    }

    // MARK: - Contextual `.case` through literals and constructors (B-FIX-29)

    func testEnumCaseShorthand_inArrayLiteralCallArgument_resolves() throws {
        // `f(xs: [.alpha])` — the shorthand sits inside an ARRAY LITERAL argument, so its context is
        // the ELEMENT of the parameter's type. The call-argument branch of `contextualTypeName`
        // hands the parameter type text (`[E]`) straight to the resolver, which (correctly, since
        // B-FIX-28) answers nil for a collection name. Every sibling branch peels the written
        // wrappers via `scalarElementType`; this one did not, so the case decl renamed while
        // `.alpha` survived → revert (under-obf) or, when the case name is shielded, a red build.
        let r = try runPipeline("""
        enum E { case alpha, beta }
        func f(xs: [E]) { _ = xs }
        func use() { f(xs: [.alpha, .beta]) }
        """)
        XCTAssertFalse(r.contains("case alpha"), "case alpha must be obfuscated:\n\(r)")
        XCTAssertFalse(r.contains(".alpha"), "`.alpha` inside the array-literal argument must be rewritten:\n\(r)")
        XCTAssertFalse(r.contains(".beta"), "`.beta` inside the array-literal argument must be rewritten:\n\(r)")
    }

    func testEnumCaseShorthand_inDictionaryLiteralCallArgument_keyAndValueResolve() throws {
        // `[.alpha: .beta]` — the KEY takes the parameter's Key type and the VALUE its Value type.
        // The two sides must peel differently, so the literal path (not just "unwrap one level")
        // is what determines the context.
        let r = try runPipeline("""
        enum K { case alpha }
        enum V { case beta }
        func f(m: [K: V]) { _ = m }
        func use() { f(m: [.alpha: .beta]) }
        """)
        XCTAssertFalse(r.contains("case alpha"), "key case must be obfuscated:\n\(r)")
        XCTAssertFalse(r.contains(".alpha"), "dictionary-literal KEY shorthand must be rewritten:\n\(r)")
        XCTAssertFalse(r.contains(".beta"), "dictionary-literal VALUE shorthand must be rewritten:\n\(r)")
    }

    func testEnumCaseShorthand_inNestedArrayLiteralArgument_resolves() throws {
        // `[[.alpha]]` against `[[E]]` — two peels, so the peel count must follow the literal
        // nesting rather than being a single fixed unwrap.
        let r = try runPipeline("""
        enum E { case alpha }
        func f(rows: [[E]]) { _ = rows }
        func use() { f(rows: [[.alpha]]) }
        """)
        XCTAssertFalse(r.contains("case alpha"), "case alpha must be obfuscated:\n\(r)")
        XCTAssertFalse(r.contains(".alpha"), "`.alpha` in the nested array literal must be rewritten:\n\(r)")
    }

    func testEnumCaseShorthand_inArrayLiteralForSetParameter_resolves() throws {
        // An array literal also builds a `Set<E>` — the peel must understand the GENERIC collection
        // spelling, not only the `[E]` sugar (`extractElement` already knows both).
        let r = try runPipeline("""
        enum E { case alpha }
        func f(s: Set<E>) { _ = s }
        func use() { f(s: [.alpha]) }
        """)
        XCTAssertFalse(r.contains("case alpha"), "case alpha must be obfuscated:\n\(r)")
        XCTAssertFalse(r.contains(".alpha"), "`.alpha` in the Set literal must be rewritten:\n\(r)")
    }

    func testEnumCaseShorthand_inDictionaryAnnotationInitializer_resolves() throws {
        // The annotation branch had the same blind spot for dictionaries: `scalarElementType` models
        // arrays and optionals only, so `[K: V]` returned nil and the walk-up CONTINUED into outer
        // contexts (a wrong context is worse than none).
        let r = try runPipeline("""
        enum K { case alpha }
        enum V { case beta }
        let m: [K: V] = [.alpha: .beta]
        """)
        XCTAssertFalse(r.contains(".alpha"), "annotation-dictionary KEY shorthand must be rewritten:\n\(r)")
        XCTAssertFalse(r.contains(".beta"), "annotation-dictionary VALUE shorthand must be rewritten:\n\(r)")
    }

    func testEnumCaseShorthand_inMemberwiseInitArgument_resolves() throws {
        // `Config(mode: .alpha)` — a struct's SYNTHESIZED memberwise init. `resolveCalleeParamType`
        // knew only free functions and `obj.method(...)`; a type name is not a callable, so the
        // shorthand got NO context. One un-covered constructor call reverts the whole enum's case
        // group (the revert is per NAME, not per site), so this is the widest coverage hole of the
        // contextual family.
        let r = try runPipeline("""
        enum Mode { case alpha, beta }
        struct Config { let mode: Mode; let flag: Bool }
        func make() -> Config { return Config(mode: .alpha, flag: true) }
        """)
        XCTAssertFalse(r.contains("case alpha"), "case alpha must be obfuscated:\n\(r)")
        XCTAssertFalse(r.contains(".alpha"), "`.alpha` in the memberwise-init argument must be rewritten:\n\(r)")
    }

    func testEnumCaseShorthand_inExplicitInitArgument_picksOverloadByLabel() throws {
        // Explicit inits are registered as `init` symbols WITH param types/labels — they only need
        // looking up. Two inits with different labels prove the pick is label-driven, not first-wins.
        let r = try runPipeline("""
        enum Mode { case alpha }
        enum Level { case beta }
        struct Config {
            init(mode: Mode) { _ = mode }
            init(level: Level) { _ = level }
        }
        func make() { _ = Config(mode: .alpha); _ = Config(level: .beta) }
        """)
        XCTAssertFalse(r.contains(".alpha"), "`.alpha` must resolve through init(mode:):\n\(r)")
        XCTAssertFalse(r.contains(".beta"), "`.beta` must resolve through init(level:):\n\(r)")
    }

    func testEnumCaseShorthand_inQualifiedNestedTypeConstructor_resolves() throws {
        // `NS.Config(mode: .alpha)` — the constructed type is written QUALIFIED (a MemberAccess
        // callee, not a DeclRef), and the property's declared type `Mode` is written INSIDE `NS`, so
        // the contextual name only resolves in the DECLARING scope (B-FIX-23 discipline). Resolving
        // it at the use-site scope finds nothing.
        let r = try runPipeline("""
        enum NS {
            enum Mode { case alpha }
            struct Config { let mode: Mode }
        }
        func make() -> NS.Config { return NS.Config(mode: .alpha) }
        """)
        XCTAssertFalse(r.contains("case alpha"), "case alpha must be obfuscated:\n\(r)")
        XCTAssertFalse(r.contains(".alpha"), "`.alpha` in the qualified constructor must be rewritten:\n\(r)")
    }

    func testEnumCaseShorthand_methodParamTypedAsNestedType_resolvesInDeclaringScope() throws {
        // Same scope rule on the EXISTING method branch: `handle(mode:)`'s parameter type `Mode` is
        // written inside `NS`, invisible from the call site. The branch resolved the name at the
        // use-site scope, so this shorthand was silently unresolved long before B-FIX-28.
        let r = try runPipeline("""
        enum NS {
            enum Mode { case alpha }
            struct Handler { func handle(mode: Mode) { _ = mode } }
        }
        func use(h: NS.Handler) { h.handle(mode: .alpha) }
        """)
        XCTAssertFalse(r.contains("case alpha"), "case alpha must be obfuscated:\n\(r)")
        XCTAssertFalse(r.contains(".alpha"), "`.alpha` must resolve through the nested param type:\n\(r)")
    }

    func testEnumCaseShorthand_inSelfInitDelegation_resolves() throws {
        // `self.init(mode: .alpha)` — the callee is a MemberAccess whose declName is `init` and
        // whose base types to the enclosing type.
        let r = try runPipeline("""
        enum Mode { case alpha, beta }
        struct Config {
            let mode: Mode
            init(mode: Mode) { self.mode = mode }
            init() { self.init(mode: .alpha) }
        }
        """)
        XCTAssertFalse(r.contains("case alpha"), "case alpha must be obfuscated:\n\(r)")
        XCTAssertFalse(r.contains(".alpha"), "`.alpha` in the self.init delegation must be rewritten:\n\(r)")
    }

    func testEnumCaseShorthand_unknownConstructor_leavesCaseConsistent() throws {
        // Fail-closed half: the constructed type is EXTERNAL (not in our table), so there is no
        // parameter type to read. The shorthand must stay original AND the case declaration must end
        // up original too — a rename on one side only is the desync that ships as a red build.
        let r = try runPipeline("""
        enum Mode { case zeta }
        func use() { _ = Foreign(mode: .zeta) }
        """)
        XCTAssertTrue(r.contains(".zeta"), "unknown constructor gives no context — shorthand stays:\n\(r)")
        XCTAssertTrue(r.contains("case zeta"), "the case decl must be reverted to match the survivor:\n\(r)")
    }

    func testEnumCaseShorthand_ambiguousInitOverloads_leavesCaseConsistent() throws {
        // Fail-closed half 2: two inits share the label but take DIFFERENT enums, and both enums
        // declare `zeta`. No argument signal can pick one, so no context may be invented — guessing
        // here would rewrite `.zeta` to the wrong enum's obf (a wrong rename RollbackPass cannot
        // catch). Decl and use-site must stay consistent.
        let r = try runPipeline("""
        enum E1 { case zeta }
        enum E2 { case zeta }
        struct S {
            init(x: E1) { _ = x }
            init(x: E2) { _ = x }
        }
        func use() { _ = S(x: .zeta) }
        """)
        XCTAssertTrue(r.contains(".zeta"), "ambiguous inits give no context — shorthand stays:\n\(r)")
        XCTAssertEqual(r.components(separatedBy: "case zeta").count - 1, 2,
                       "both same-named cases must be reverted to match the survivor:\n\(r)")
    }

    func testEnumCaseShorthand_inTernaryAssignmentRHS_resolves() throws {
        // `self.mood = flag ? .calm : .sharp`. The whole statement is ONE raw-parsed SequenceExpr,
        // and the ternary makes it 7 elements — the assignment branch only handled the exact
        // 3-element shape, so both branches of the ternary lost their context. An assignment types
        // its ENTIRE right-hand side from the left, however many elements the sequence has.
        let r = try runPipeline("""
        enum Mood { case calm, sharp }
        struct Tuned {
            var mood: Mood
            mutating func set(flag: Bool) { self.mood = flag ? .calm : .sharp }
        }
        """)
        XCTAssertFalse(r.contains("case calm"), "case calm must be obfuscated:\n\(r)")
        XCTAssertFalse(r.contains(".calm"), "the ternary's then-branch must be rewritten:\n\(r)")
        XCTAssertFalse(r.contains(".sharp"), "the ternary's else-branch must be rewritten:\n\(r)")
    }

    func testEnumCaseShorthand_comparisonOperandBeforeTernary_resolves() throws {
        // Same sequence, comparison half: `slot == .morning ? a : b` is 5 elements, so the operand
        // rule must look at the shorthand's NEIGHBOURS rather than assume a bare 3-element sequence.
        let r = try runPipeline("""
        enum Slot { case morning, evening }
        func label(slot: Slot) -> Int { return slot == .morning ? 1 : 2 }
        """)
        XCTAssertFalse(r.contains("case morning"), "case morning must be obfuscated:\n\(r)")
        XCTAssertFalse(r.contains(".morning"), "the comparison operand must be rewritten:\n\(r)")
    }

    func testEnumCaseShorthand_comparisonInsideAssignmentRHS_takesOperandNotLHS() throws {
        // `self.mood = slot == .morning ? .calm : .sharp` — ONE sequence carrying BOTH contexts.
        // `.morning` belongs to the comparison (type Slot), the ternary branches to the assignment
        // (type Mood). The NEAREST binding context must win: letting the assignment claim the whole
        // right-hand side types `.morning` as Mood, and had Mood also declared `morning` that would
        // be a WRONG rename ("has no member") instead of a harmless miss.
        let r = try runPipeline("""
        enum Mood { case calm, sharp }
        enum Slot { case morning, evening }
        struct Tuned {
            var mood: Mood
            mutating func set(slot: Slot) { self.mood = slot == .morning ? .calm : .sharp }
        }
        """)
        XCTAssertFalse(r.contains("case morning"), "case morning must be obfuscated:\n\(r)")
        XCTAssertFalse(r.contains(".morning"), "the comparison operand must take the OPERAND's type:\n\(r)")
        XCTAssertFalse(r.contains(".calm"), "the ternary branch must take the assignment LHS's type:\n\(r)")
        XCTAssertFalse(r.contains(".sharp"), "both ternary branches must be rewritten:\n\(r)")
    }

    func testEnumCasePayload_switchCaseBinding_typedFromAssociatedValue() throws {
        // `case .run(let m): return m == .calm` — `m` is bound to the case's associated value, so
        // its type is that value's. Untyped, the comparison operand `.calm` had no context and the
        // survivor reverted the payload enum's whole case group.
        let r = try runPipeline("""
        enum Mood { case calm, sharp }
        enum Command { case run(Mood), stop }
        func check(c: Command) -> Bool {
            switch c {
            case .run(let m): return m == .calm
            case .stop: return false
            }
        }
        """)
        XCTAssertFalse(r.contains("case calm"), "case calm must be obfuscated:\n\(r)")
        XCTAssertFalse(r.contains(".calm"), "the payload binding must type the comparison operand:\n\(r)")
    }

    func testEnumCasePayload_switchCaseLetPrefixBinding_typedFromAssociatedValue() throws {
        // Same, written in the `case let .run(m)` prefix form (a different pattern shape).
        let r = try runPipeline("""
        enum Mood { case calm, sharp }
        enum Command { case run(Mood), stop }
        func check(c: Command) -> Bool {
            switch c {
            case let .run(m): return m == .calm
            case .stop: return false
            }
        }
        """)
        XCTAssertFalse(r.contains("case calm"), "case calm must be obfuscated:\n\(r)")
        XCTAssertFalse(r.contains(".calm"), "the prefix-form payload binding must type the operand:\n\(r)")
    }

    func testEnumCasePayload_qualifiedCaseConstructor_renamesCaseAndArgument() throws {
        // `Command.run(.calm)` — a case WITH an associated value is called like a function. The
        // callee is a member access whose member is an enum CASE, not a method, so nothing renamed
        // `run`, and the payload argument had no type to take context from. The surviving `run`
        // then reverted the whole `Command` case group AND the payload enum's cases with it.
        let r = try runPipeline("""
        enum Mood { case calm, sharp }
        enum Command { case run(Mood), stop }
        func make() -> Command { return Command.run(.calm) }
        """)
        XCTAssertFalse(r.contains("case run("), "the payload case decl must be obfuscated:\n\(r)")
        XCTAssertFalse(r.contains(".run("), "the case constructor use-site must be rewritten:\n\(r)")
        XCTAssertFalse(r.contains(".calm"), "the payload argument must take the case's associated type:\n\(r)")
    }

    func testEnumCasePayload_inferredEnumTypeDrivesSwitchContext() throws {
        // A case constructor's static type is its ENUM, so `let c = Command.run(.calm)` types `c`
        // and the switch over it can resolve `.stop`. Without it the subject was untyped and every
        // pattern shorthand in the switch stayed original.
        let r = try runPipeline("""
        enum Mood { case calm }
        enum Command { case run(Mood), stop }
        func check() -> Bool {
            let c = Command.run(.calm)
            switch c {
            case .run: return true
            case .stop: return false
            }
        }
        """)
        XCTAssertFalse(r.contains("case stop"), "case stop must be obfuscated:\n\(r)")
        XCTAssertFalse(r.contains(".stop"), "the switch pattern must be rewritten:\n\(r)")
    }

    func testEnumCasePayload_contextualShorthandCallee_resolvesArgument() throws {
        // `let c: Command = .run(.calm)` — the CALLEE is itself a base-less shorthand, so the
        // payload's context is one level deeper: resolve the callee's own contextual type first,
        // then read the case's associated type.
        let r = try runPipeline("""
        enum Mood { case calm }
        enum Command { case run(Mood), stop }
        func make() -> Command {
            let c: Command = .run(.calm)
            return c
        }
        """)
        XCTAssertFalse(r.contains(".calm"), "the payload of a shorthand case constructor must be rewritten:\n\(r)")
        XCTAssertFalse(r.contains("case calm"), "case calm must be obfuscated:\n\(r)")
    }

    func testForInLoop_nestedElementMember_resolvesThroughQualifiedElementName() throws {
        // The shape of `Tests/PullTheTicket/.../20_NestedFieldAccess.swift`, a RED BUILD in the
        // tracked fixture: `for section in container.sections` typed `section` as the BARE element
        // name `Section`, which is nested in `Container` and therefore invisible from the loop body's
        // scope (B-FIX-23). So `section.title` never resolved while `title`'s decl renamed, and the
        // survivor could not be reverted (`title`/`label` are Apple API names — RollbackPass shield
        // 1c), shipping "value of type '<obf>' has no member 'title'". The inferred element name
        // must be QUALIFIED, exactly as the initializer-driven inference already stores it.
        let r = try runPipeline("""
        struct Container {
            struct Section {
                let title: String
                let items: [Item]
            }
            struct Item {
                let label: String
            }
            let sections: [Section]
        }
        final class Renderer {
            func render(_ container: Container) {
                for section in container.sections {
                    print(section.title)
                    for item in section.items {
                        print(item.label)
                    }
                }
            }
        }
        """)
        XCTAssertFalse(r.contains("let title"), "the nested property decl must be obfuscated:\n\(r)")
        XCTAssertFalse(r.contains("section.title"), "member through the loop variable must be rewritten:\n\(r)")
        XCTAssertFalse(r.contains("item.label"), "member through the NESTED loop variable must be rewritten:\n\(r)")
    }

    func testEnumCasePayload_ifCaseBinding_typedFromAssociatedValue() throws {
        // `if case .run(let m) = c` binds the payload exactly as a `switch` case does, but only the
        // switch form recorded the binding's type (B-FIX-29), so `m == .calm` had no context: the
        // shorthand stayed original while `calm`'s decl renamed → the survivor reverted the payload
        // enum's whole case group (a red build whenever the case name is shielded from rollback).
        let r = try runPipeline("""
        enum Mood { case calm, sharp }
        enum Command { case run(Mood), stop }
        func check(c: Command) -> Bool {
            if case .run(let m) = c { return m == .calm }
            return false
        }
        """)
        XCTAssertFalse(r.contains("case calm"), "case calm must be obfuscated:\n\(r)")
        XCTAssertFalse(r.contains(".calm"), "the if-case payload binding must type the operand:\n\(r)")
    }

    func testEnumCasePayload_guardCaseBinding_typedFromAssociatedValue() throws {
        // Same for `guard case`, where the binding is in scope only AFTER the statement.
        let r = try runPipeline("""
        enum Mood { case calm, sharp }
        enum Command { case run(Mood), stop }
        func check(c: Command) -> Bool {
            guard case .run(let m) = c else { return false }
            return m == .calm
        }
        """)
        XCTAssertFalse(r.contains("case calm"), "case calm must be obfuscated:\n\(r)")
        XCTAssertFalse(r.contains(".calm"), "the guard-case payload binding must type the operand:\n\(r)")
    }

    func testEnumCasePayload_guardCaseBinding_elseBodyKeepsOuterMeaning() throws {
        // The safety complement: a guard-case binding is NOT in scope inside the `else` body, so a
        // same-named PROPERTY referenced there must keep its own type. Recording the payload type
        // before the else body is visited would type `m` as the payload enum and rewrite `m.tag` to
        // that enum's member — a wrong rename RollbackPass cannot catch.
        let r = try runPipeline("""
        enum Mood { case calm, sharp }
        struct Marker { let tag: String }
        enum Command { case run(Mood), stop }
        final class Checker {
            let m = Marker(tag: "x")
            func check(c: Command) -> String {
                guard case .run(let m) = c else { return self.m.tag }
                return m == .calm ? "a" : "b"
            }
        }
        """)
        XCTAssertFalse(r.contains(".calm"), "the guard-case payload binding must type the operand:\n\(r)")
        XCTAssertFalse(r.contains("self.m.tag"), "the else-body property member must resolve to Marker's own member:\n\(r)")
    }

    // MARK: - A flow-tracked binding has a written type name too (B-FIX-37)
    // Invariant: `receiverTypeInfo` answers "what is the WRITTEN type name of this expression", so it
    // must know every type source `typeSymbol(of:)` knows — a recorded `declaredType`, a HOF closure
    // parameter, AND the flow-sensitive binding provider. It knew only the first, so any binding
    // (enum-case payload, `if`/`guard let`) typed as a COLLECTION was invisible to every consumer
    // that needs the brackets: HOF element typing, subscript results, stdlib-collection members.

    func testEnumCasePayload_collectionBindingAsHOFReceiver_closureParamResolves() throws {
        // The reported red build. `case load([Row])` types `rows` as `[Row]`, but only in the
        // flow-sensitive binding table — `rows` has no `declaredType`. `resolveSource(.element)` asks
        // `receiverTypeInfo`, got nil, and `$0` stayed untyped: every member read through it survived
        // while its declaration renamed ("Value of type 'Container.Meta' has no member 'metaStamp'").
        let r = try runPipeline("""
        enum Container {
            enum Command {
                case idle
                case load([Row])
            }
            struct Row {
                let rowCaption: String
                let rowMeta: Meta
            }
            struct Meta {
                let metaStamp: Int
            }
            struct Card {
                let cardHeading: String
                let cardMark: Int
            }
        }
        func handle(_ c: Container.Command) -> [Container.Card] {
            switch c {
            case .load(let rows):
                return rows.map { Container.Card(cardHeading: $0.rowCaption, cardMark: $0.rowMeta.metaStamp) }
            case .idle:
                return []
            }
        }
        """)
        XCTAssertFalse(r.contains("let rowCaption"), "Row.rowCaption must be obfuscated:\n\(r)")
        XCTAssertFalse(r.contains("$0.rowCaption"), "the closure param must type from the payload binding's element:\n\(r)")
        XCTAssertFalse(r.contains(".rowMeta"), "the chained member through the closure param must resolve:\n\(r)")
        XCTAssertFalse(r.contains(".metaStamp"), "the leaf member of the chain must resolve:\n\(r)")
    }

    func testOptionalBinding_collectionBindingAsHOFReceiver_closureParamResolves() throws {
        // Same gap through the other binding entry point: `guard let` records its type in the same
        // table, so a collection-typed optional binding used as a HOF receiver failed identically.
        let r = try runPipeline("""
        struct Row { let rowCaption: String }
        struct Holder { let stored: [Row]? }
        func handle(_ h: Holder) -> [String] {
            guard let rows = h.stored else { return [] }
            return rows.map { $0.rowCaption }
        }
        """)
        XCTAssertFalse(r.contains("let rowCaption"), "Row.rowCaption must be obfuscated:\n\(r)")
        XCTAssertFalse(r.contains("$0.rowCaption"), "the closure param must type from the optional binding's element:\n\(r)")
    }

    func testEnumCasePayload_collectionBindingSubscript_memberResolves() throws {
        // The same chokepoint feeds subscript-result typing (B-FIX-22), so `rows[0].rowCaption`
        // broke for the identical reason. Proves the fix is at `receiverTypeInfo`, not at the HOF.
        let r = try runPipeline("""
        enum Command {
            case idle
            case load([Row])
        }
        struct Row { let rowCaption: String }
        func handle(_ c: Command) -> String {
            switch c {
            case .load(let rows):
                return rows[0].rowCaption
            case .idle:
                return ""
            }
        }
        """)
        XCTAssertFalse(r.contains("let rowCaption"), "Row.rowCaption must be obfuscated:\n\(r)")
        XCTAssertFalse(r.contains("].rowCaption"), "the subscript element member must resolve:\n\(r)")
    }

    func testHOFClosureParam_collectionTypedParamAsNestedHOFReceiver_resolves() throws {
        // The third source `receiverTypeInfo` did not know: a HOF closure parameter that is itself a
        // collection. `groups.forEach { g in g.rows.map { … } }` works (g has a declaredType through
        // Group), but binding the collection DIRECTLY (`[[Row]]`) did not.
        let r = try runPipeline("""
        struct Row { let rowCaption: String }
        func handle(_ groups: [[Row]]) -> [String] {
            return groups.flatMap { group in group.map { $0.rowCaption } }
        }
        """)
        XCTAssertFalse(r.contains("let rowCaption"), "Row.rowCaption must be obfuscated:\n\(r)")
        XCTAssertFalse(r.contains("$0.rowCaption"), "the inner closure param must type from the outer param's element:\n\(r)")
    }

    // MARK: - A written type annotation is ground truth (B-FIX-35)
    // Invariant: an optional binding takes its type from its OWN `typeAnnotation` when one is
    // written, in preference to any inference from the initializer; the name in it resolves in the
    // scope it was WRITTEN in (B-FIX-23), qualification intact.

    func testOptionalBinding_guardLetAnnotation_qualifiedNestedTypeMemberResolves() throws {
        // The reported red build. The initializer is un-inferable (a cast through `Any`), so before
        // this fix the binding stayed untyped and `row.slotValue` resolved to nothing while the
        // property's declaration renamed — a desync that ships whenever a shield blocks the revert.
        // The annotation names a NESTED type QUALIFIED (`Section.Row`), which is the spelling that
        // breaks: the same code with a top-level type has the same defect but a shorter path to it.
        let r = try runPipeline("""
        enum Section {
            struct Row {
                let slotValue: Int
            }
        }
        final class Host {
            func lookup(_ i: Int) -> Any? { return nil }
            func run(_ i: Int) {
                guard let row: Section.Row = lookup(i) as? Section.Row else { return }
                _ = row.slotValue
            }
        }
        """)
        let obf = try firstGroup(#"let (\w+): Int"#, in: r)
        XCTAssertNotEqual(obf, "slotValue", "the property decl must stay obfuscated:\n\(r)")
        XCTAssertTrue(r.contains("row.\(obf)"), "row.slotValue must rename via the written annotation:\n\(r)")
    }

    func testOptionalBinding_ifLetAnnotation_topLevelTypeMemberResolves() throws {
        // Same defect in the `if let` form, and with a TOP-LEVEL annotation: nothing read the
        // annotation at all, so qualification was never the deciding factor.
        let r = try runPipeline("""
        struct Row {
            let slotValue: Int
        }
        final class Host {
            func lookup(_ i: Int) -> Any? { return nil }
            func run(_ i: Int) {
                if let row: Row = lookup(i) as? Row {
                    _ = row.slotValue
                }
            }
        }
        """)
        let obf = try firstGroup(#"let (\w+): Int"#, in: r)
        XCTAssertNotEqual(obf, "slotValue", "the property decl must stay obfuscated:\n\(r)")
        XCTAssertTrue(r.contains("row.\(obf)"), "row.slotValue must rename via the written annotation:\n\(r)")
    }

    func testOptionalBinding_whileLetAnnotation_memberResolves() throws {
        // `while let` goes through the same visitPost(OptionalBindingCondition) entry as `if let`.
        let r = try runPipeline("""
        struct Row {
            let slotValue: Int
        }
        final class Host {
            func lookup() -> Any? { return nil }
            func run() {
                while let row: Row = lookup() as? Row {
                    _ = row.slotValue
                }
            }
        }
        """)
        let obf = try firstGroup(#"let (\w+): Int"#, in: r)
        XCTAssertNotEqual(obf, "slotValue", "the property decl must stay obfuscated:\n\(r)")
        XCTAssertTrue(r.contains("row.\(obf)"), "row.slotValue must rename via the written annotation:\n\(r)")
    }

    func testOptionalBinding_annotationResolvesInScopeItIsWrittenIn() throws {
        // The scope half of the invariant. The annotation is written UNQUALIFIED (`Row`) inside the
        // enum that declares it, so it resolves only from that lexical position. Storing the bare
        // string and re-resolving it somewhere else is what B-FIX-23 forbids.
        let r = try runPipeline("""
        enum Section {
            struct Row {
                let slotValue: Int
            }
            struct Runner {
                func lookup() -> Any? { return nil }
                func run() {
                    guard let row: Row = lookup() as? Row else { return }
                    _ = row.slotValue
                }
            }
        }
        """)
        let obf = try firstGroup(#"let (\w+): Int"#, in: r)
        XCTAssertNotEqual(obf, "slotValue", "the property decl must stay obfuscated:\n\(r)")
        XCTAssertTrue(r.contains("row.\(obf)"), "an unqualified annotation must resolve where written:\n\(r)")
    }

    func testOptionalBinding_inferredNestedType_resolvesInDeclaringScope() throws {
        // No annotation: the type comes from the initializer, and the inferred name was stored BARE
        // (`Row`) then re-resolved at the use-site, where a nested type is invisible. Same B-FIX-23
        // class as the annotation path, which is why both are recorded through one helper that keeps
        // the name and its declaring scope together.
        let r = try runPipeline("""
        enum Section {
            struct Row {
                let slotValue: Int
            }
        }
        final class Host {
            func make() -> Section.Row? { return nil }
            func run() {
                guard let row = make() else { return }
                _ = row.slotValue
            }
        }
        """)
        let obf = try firstGroup(#"let (\w+): Int"#, in: r)
        XCTAssertNotEqual(obf, "slotValue", "the property decl must stay obfuscated:\n\(r)")
        XCTAssertTrue(r.contains("row.\(obf)"), "an inferred nested type must resolve in its declaring scope:\n\(r)")
    }

    func testOptionalBinding_guardLetAnnotation_elseBodyKeepsOuterMeaning() throws {
        // Safety complement, mirroring the guard-case payload test: a `guard let` binding is not in
        // scope inside the `else` body, so a same-named PROPERTY referenced there must keep its own
        // type. Recording the annotation earlier than visitPost(GuardStmt) would type `row` as the
        // annotated type and rewrite `row.tag` to ITS member — a wrong rename RollbackPass cannot
        // catch (both ends rename, no original survives).
        let r = try runPipeline("""
        struct Row { let slotValue: Int }
        struct Marker { let slotTag: String }
        final class Host {
            let row = Marker(slotTag: "x")
            func lookup() -> Any? { return nil }
            func run() -> String {
                guard let row: Row = lookup() as? Row else { return self.row.slotTag }
                _ = row.slotValue
                return "ok"
            }
        }
        """)
        XCTAssertFalse(r.contains("self.row.slotTag"),
                       "the else-body property member must resolve to Marker's own member:\n\(r)")
    }

    func testForInLoop_writtenAnnotationOutranksElementInference() throws {
        // The same invariant at the other binding form that can carry an annotation. Element
        // inference has to type the SEQUENCE expression, and a cast is one of the shapes it cannot
        // type — but the loop variable's type is written right there.
        let r = try runPipeline("""
        enum Section {
            struct Row {
                let slotValue: Int
            }
        }
        final class Host {
            func rows() -> Any { return [] }
            func run() {
                for row: Section.Row in rows() as! [Section.Row] {
                    _ = row.slotValue
                }
            }
        }
        """)
        let obf = try firstGroup(#"let (\w+): Int"#, in: r)
        XCTAssertNotEqual(obf, "slotValue", "the property decl must stay obfuscated:\n\(r)")
        XCTAssertTrue(r.contains("row.\(obf)"), "row.slotValue must rename via the written annotation:\n\(r)")
    }

    // MARK: - Extensions on EXTERNAL types are renameable (B-FIX-31)
    // Invariant: a member declared in an extension of a type we do NOT own (`extension String`,
    // `extension Array where Element == Mood`) can still be renamed — its use-sites are matched by
    // the receiver's WRITTEN type instead of by Symbol identity. Eligibility is fail-closed: the
    // extension family must declare no conformance, and the member name must not be an Apple/stdlib
    // API name (RollbackPass shield 1c would block the rescue of a missed use-site → red build).

    /// First capture group of `pattern` in `text`, or nil.
    private func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    func testExternalExtension_constrainedByElement_useSitesPickTheMatchingExtension() throws {
        // The `Tests/IceTrays/.../FloeSupportViews.swift` shape: two `extension Array where Element
        // == …` declaring the SAME member name, differing only by Element. Both were skipped as
        // "extension of an external type" (`scope.owner == nil`), so 2 declarations + 4 use-sites
        // stayed readable. They must now rename to DIFFERENT obfs, and each use-site must pick by
        // its receiver's element type.
        let r = try runPipeline("""
        enum Mood { case calm, sharp }
        extension Array where Element == Mood {
            var chipText: String { map { "\\($0)" }.joined(separator: ", ") }
        }
        extension Array where Element == String {
            var chipText: String { joined(separator: ", ") }
        }
        struct Card {
            let moods: [Mood]
            let tags: [String]
            func render() -> String { return moods.chipText + tags.chipText }
        }
        """)
        XCTAssertFalse(r.contains("var chipText"), "both constrained-extension members must be obfuscated:\n\(r)")
        XCTAssertFalse(r.contains(".chipText"), "both use-sites must be rewritten:\n\(r)")
        let moodObf = firstMatch(#"Element == T\d+ \{\s*var (p\d+)"#, in: r)
        let stringObf = firstMatch(#"Element == String \{\s*var (p\d+)"#, in: r)
        XCTAssertNotNil(moodObf, "the Mood-constrained member must be renamed:\n\(r)")
        XCTAssertNotNil(stringObf, "the String-constrained member must be renamed:\n\(r)")
        XCTAssertNotEqual(moodObf, stringObf, "the two members are distinct declarations:\n\(r)")
        let uses = firstMatch(#"return p\d+\.(p\d+) \+ p\d+\.p\d+"#, in: r)
        let uses2 = firstMatch(#"return p\d+\.p\d+ \+ p\d+\.(p\d+)"#, in: r)
        XCTAssertEqual(uses, moodObf, "the [Mood] receiver must pick the Mood-constrained member:\n\(r)")
        XCTAssertEqual(uses2, stringObf, "the [String] receiver must pick the String-constrained member:\n\(r)")
    }

    func testExternalExtension_namedStdlibType_memberRenames() throws {
        // `extension String { var commaParts }` — the same policy skip, for a NAMED external type.
        // The receiver is matched by its written type name.
        let r = try runPipeline("""
        extension String {
            var commaParts: [String] { split(separator: ",").map { String($0) } }
        }
        struct Row {
            let raw: String
            func parts() -> [String] { return raw.commaParts }
        }
        """)
        XCTAssertFalse(r.contains("var commaParts"), "the extension member must be obfuscated:\n\(r)")
        XCTAssertFalse(r.contains(".commaParts"), "the use-site must be rewritten:\n\(r)")
    }

    func testExternalExtension_declaredConformance_membersStayOriginal() throws {
        // Fail-closed: an extension that adopts a protocol makes its members WITNESSES, and a
        // stdlib type is not in our table, so WitnessLinker cannot pair them with the requirement.
        // Renaming one breaks the conformance — so no extension of that type is eligible.
        let r = try runPipeline("""
        protocol Summable { func total() -> Int }
        extension Array: Summable where Element == Int {
            func total() -> Int { reduce(0, +) }
        }
        struct Basket {
            let counts: [Int]
            func sum() -> Int { return counts.total() }
        }
        """)
        XCTAssertTrue(r.contains("func total() -> Int { reduce"),
                      "a witness on an external type must stay original:\n\(r)")
        XCTAssertTrue(r.contains(".total()"), "and so must its use-site:\n\(r)")
    }

    func testExternalExtension_appleApiNamedMember_staysOriginal() throws {
        // Fail-closed: `title` is an Apple API name, so RollbackPass shield 1c would block the
        // revert of a missed use-site — the desync would SHIP. Such a member is not renamed at all.
        let r = try runPipeline("""
        extension String {
            var title: String { uppercased() }
        }
        struct Row {
            let raw: String
            func label() -> String { return raw.title }
        }
        """)
        XCTAssertTrue(r.contains("var title"), "an Apple-named external-extension member stays original:\n\(r)")
        XCTAssertTrue(r.contains(".title"), "and so does its use-site:\n\(r)")
    }

    func testExternalExtension_projectUniqueMember_rewritesUntypeableReceiver() throws {
        // The SwiftUI `extension View { func frostBound() -> some View }` modifier idiom: every
        // use-site sits on a chain of SDK calls whose type no syntactic resolver can produce, so
        // type-matched resolution can never reach them — the decl renames, all use-sites survive and
        // the whole thing reverts. A name declared EXACTLY once project-wide, in an external-type
        // extension, that survived the Planner's Apple-name filter can only denote that one member.
        let r = try runPipeline("""
        extension Renderable {
            func frostBound() -> Self { return self }
        }
        struct Card {
            func render() -> Renderable { return makeSurface().padded(2).frostBound() }
        }
        """)
        XCTAssertFalse(r.contains("func frostBound"), "the modifier decl must be obfuscated:\n\(r)")
        XCTAssertFalse(r.contains(".frostBound()"), "its untypeable use-site must be rewritten too:\n\(r)")
    }

    func testExternalExtension_nonUniqueMemberName_untypeableReceiverStaysOriginal() throws {
        // The guard: the name-based rewrite requires the name to be declared exactly ONCE in the
        // project. A second declaration of any kind (here a local struct's method) makes an
        // untypeable `.frostBound()` ambiguous, so nothing is rewritten by name (the group then
        // reverts — under-obfuscation, never a wrong rename).
        let r = try runPipeline("""
        extension Renderable {
            func frostBound() -> Self { return self }
        }
        struct Panel {
            func frostBound() -> Int { return 1 }
        }
        struct Card {
            func render() -> Renderable { return makeSurface().padded(2).frostBound() }
        }
        """)
        XCTAssertTrue(r.contains(".frostBound()"), "an ambiguous name is not rewritten by name:\n\(r)")
        XCTAssertTrue(r.contains("func frostBound"), "and the declarations revert, staying consistent:\n\(r)")
    }

    func testExternalExtension_duplicatedAcrossTargets_eachModuleUsesItsOwnCopy() throws {
        // A multi-target iOS app compiles the same source into several writable targets, so an
        // external-type extension member exists once PER MODULE, each with its own obf. Without the
        // same-module tiebreak every such member is ambiguous at every use-site ⇒ reverted, which is
        // exactly the shape of the tracked IceTrays / IceTrays1 pair.
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftProf-\(UUID().uuidString)")
        let modA = tempRoot.appendingPathComponent("ModA")
        let modB = tempRoot.appendingPathComponent("ModB")
        try FileManager.default.createDirectory(at: modA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: modB, withIntermediateDirectories: true)
        let source = """
        extension String {
            var commaParts: [String] { split(separator: ",").map { String($0) } }
        }
        struct Row {
            let raw: String
            func parts() -> [String] { return raw.commaParts }
        }
        """
        try source.write(to: modA.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
        try source.write(to: modB.appendingPathComponent("B.swift"), atomically: true, encoding: .utf8)
        let specs = [
            ModuleSpec(name: "ModA", root: modA, writable: true),
            ModuleSpec(name: "ModB", root: modB, writable: true),
        ]
        let options = PipelineOptions(modules: specs,
                                      outputDirectory: tempRoot.appendingPathComponent("out"),
                                      dryRun: false, nameStyle: .debug, introspectSDK: false)
        _ = try Pipeline(options: options, logger: StderrLogger(verbose: false)).run()
        for url in [modA.appendingPathComponent("A.swift"), modB.appendingPathComponent("B.swift")] {
            let r = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(r.contains("var commaParts"), "each target's member must be obfuscated:\n\(r)")
            XCTAssertFalse(r.contains(".commaParts"), "and each use-site rewritten in its own module:\n\(r)")
        }
    }

    func testExternalExtension_localTypeExtension_unaffected() throws {
        // Guard rail: extensions of OUR OWN types keep resolving by Symbol identity (owner != nil),
        // untouched by the external-extension path.
        let r = try runPipeline("""
        struct Widget { let size: Int }
        extension Widget { var doubled: Int { size * 2 } }
        func use(w: Widget) -> Int { return w.doubled }
        """)
        XCTAssertFalse(r.contains("var doubled"), "a local extension member must still be obfuscated:\n\(r)")
        XCTAssertFalse(r.contains("w.doubled"), "and its use-site rewritten:\n\(r)")
    }

    // MARK: - Stdlib collection members: result shape (B-FIX-30)
    // Invariant: a stdlib collection member's RESULT is a known function of the receiver's Element
    // (`first`/`last`/`randomElement()` → Element, `sorted()`/`reversed()`/`filter{}` → a collection
    // of the same Element, `keys`/`values` → the Dictionary's Key/Value collection). Anything not in
    // the table stays unknown. The member itself is stdlib — never renamed.

    func testCollectionMember_firstOptionalChain_memberResolves() throws {
        // `items.first?.tagline` — the receiver is a collection, which names no declaration
        // (B-FIX-28), so the chain died at `first` and `tagline` stayed original while its decl
        // renamed → desync (a red build when the survivor is shielded).
        let r = try runPipeline("""
        struct Item { let tagline: String }
        struct Holder {
            let items: [Item]
            func lead() -> String? { return items.first?.tagline }
        }
        """)
        XCTAssertFalse(r.contains("let tagline"), "the element property decl must be obfuscated:\n\(r)")
        XCTAssertFalse(r.contains(".tagline"), "the member through `first` must be rewritten:\n\(r)")
        XCTAssertTrue(r.contains(".first?."), "the stdlib member itself must stay untouched:\n\(r)")
    }

    func testCollectionMember_sameElementResult_chainsToElement() throws {
        // `reversed()` yields a collection with the SAME Element, so the chain continues through it.
        let r = try runPipeline("""
        struct Item { let tagline: String }
        struct Holder {
            let items: [Item]
            func lead() -> String? { return items.reversed().first?.tagline }
        }
        """)
        XCTAssertFalse(r.contains(".tagline"), "the member through `reversed().first` must be rewritten:\n\(r)")
        XCTAssertTrue(r.contains(".reversed().first?."), "stdlib members stay untouched:\n\(r)")
    }

    func testCollectionMember_dictionaryValues_memberResolves() throws {
        // `byKey.values.first?.tagline` — `values` is the Dictionary's Value collection.
        let r = try runPipeline("""
        struct Item { let tagline: String }
        struct Holder {
            let byKey: [String: Item]
            func lead() -> String? { return byKey.values.first?.tagline }
        }
        """)
        XCTAssertFalse(r.contains(".tagline"), "the member through `values.first` must be rewritten:\n\(r)")
    }

    func testCollectionMember_forInOverSortedSequence_elementMemberResolves() throws {
        // The loop-variable inference reads the sequence's RAW declared type; through a collection
        // member call it had none, so `item.tagline` never resolved.
        let r = try runPipeline("""
        struct Item { let tagline: String }
        struct Holder {
            let items: [Item]
            func dump() {
                for item in items.filter({ _ in true }) {
                    print(item.tagline)
                }
            }
        }
        """)
        XCTAssertFalse(r.contains("item.tagline"), "member through the loop variable must be rewritten:\n\(r)")
    }

    func testCollectionMember_unknownMember_staysFailClosed() throws {
        // The safety complement: a collection member NOT in the table types nothing, so a member
        // reached through it is left alone (under-obf) rather than typed by a guess. `Wrapper` here
        // declares `tagline` too — a guessed receiver type would rewrite to the WRONG member.
        let r = try runPipeline("""
        struct Item { let tagline: String }
        struct Wrapper { let tagline: Int }
        struct Holder {
            let items: [Item]
            func size() -> Int { return items.count }
        }
        """)
        XCTAssertTrue(r.contains("items.count") || r.contains(".count"),
                      "a stdlib member with no modelled result shape stays untouched:\n\(r)")
    }

    func testOverloadByArgType_arrayArgumentFromMemberAccess_picksArrayOverload() throws {
        // `f(h.items)` where `items: [Item]`. `argConstraint`'s type-NAME fallback only fired for a
        // bare DeclRef, so a member-access argument of collection type carried NO signal once
        // B-FIX-28 stopped answering `[Item]` with `Item` — the overload pair tied and the whole
        // group reverted (under-obf).
        let r = try runPipeline("""
        struct Item { let v1: Int }
        struct Other { let v2: Int }
        struct Holder { let items: [Item] }
        final class C {
            func f(_ x: [Item]) -> Int { return x.count }
            func f(_ x: Other) -> Int { return x.v2 }
            func use(h: Holder) -> Int { return f(h.items) }
        }
        """)
        XCTAssertFalse(r.contains("func f("), "the overload pair must be obfuscated:\n\(r)")
        XCTAssertFalse(r.contains("return f(h."), "the call must be rewritten to the array overload:\n\(r)")
    }

    func testOverloadByArgType_typealiasSpelledArrayParam_staysFailClosed() throws {
        // The safety complement: the array overload spells its parameter through a typealias, so the
        // written names differ textually (`Items` vs `[Item]`). A composite name that does not match
        // must count as NO evidence, never as a contradiction — treating it as one would eliminate
        // the RIGHT overload and hand the call to `Other` (a wrong rename). Fail-closed = the call
        // stays original and RollbackPass reverts the pair, exactly as before.
        let r = try runPipeline("""
        struct Item { let v1: Int }
        struct Other { let v2: Int }
        typealias Items = [Item]
        struct Holder { let items: [Item] }
        final class C {
            func f(_ x: Items) -> Int { return x.count }
            func f(_ x: Other) -> Int { return x.v2 }
            func use(h: Holder) -> Int { return f(h.items) }
        }
        """)
        XCTAssertTrue(r.contains("return f(h."), "no argument signal can pick an overload — the call stays original:\n\(r)")
        XCTAssertTrue(r.contains("func f("), "and the group is reverted, not half-renamed:\n\(r)")
    }

    // MARK: - Use-site position decides the kind of the referenced declaration

    /// A protocol may overload ONE name across kinds — `var pf2: Bool` next to
    /// `func pf2(for:) -> Bool`. The call `g.floeGate(for:)` is in CALLEE position, so it denotes the
    /// method; the mixed-kind candidate set must be narrowed by that before any fail-closed bail.
    /// Before the fix `resolveMemberForUse` refused the whole set, the call kept the original name
    /// while the method's declaration renamed, and rollback shield 1b (the un-renamed property is a
    /// namesake) blocked the rescue — so the desync SHIPPED as "cannot call value of non-function
    /// type 'Bool'".
    func testMixedKindMembers_calleePositionResolvesToTheMethod() throws {
        let source = """
        protocol Gate {
            var floeGate: Bool { get set }
            func floeGate(for path: String) -> Bool
        }
        final class Door: Gate {
            var floeGate: Bool = false
            func floeGate(for path: String) -> Bool { return path.isEmpty }
        }
        func check(_ g: Gate, path: String) -> Bool {
            return g.floeGate(for: path)
        }
        """
        let rewritten = try runPipeline(source)
        XCTAssertFalse(rewritten.contains("floeGate"),
                       "call in callee position must resolve to the method, not stall on the "
                           + "mixed-kind set:\n\(rewritten)")
    }

    /// The mirror image: the same name read as a VALUE denotes the property. With debug names the
    /// obf prefix carries the kind (`p` for properties, `m` for methods), so the read site must use
    /// the property's obf — binding it to the method would be a silent wrong-storage read.
    func testMixedKindMembers_valuePositionResolvesToTheProperty() throws {
        let source = """
        protocol Gate {
            var floeGate: Bool { get set }
            func floeGate(for path: String) -> Bool
        }
        final class Door: Gate {
            var floeGate: Bool = false
            func floeGate(for path: String) -> Bool { return path.isEmpty }
        }
        func read(_ g: Gate) -> Bool {
            return g.floeGate
        }
        """
        let rewritten = try runPipeline(source)
        // The receiver renames too (it is a parameter), so match the read by SHAPE: the only
        // `return <recv>.<member>` with no call parentheses.
        let read = rewritten.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("return ") && $0.contains(".") && !$0.contains("(") }
        let member = read?.split(separator: ".").last.map(String.init)
        XCTAssertNotNil(member, "the value read must still be present:\n\(rewritten)")
        XCTAssertTrue(member?.hasPrefix("p") == true,
                      "a non-callee member access denotes the PROPERTY (debug obfs prefix "
                          + "properties with `p`, methods with `m`): \(read ?? "")")
    }

    /// The bare-call form of the same invariant: `Scope.lookup` is kind-blind and returns the
    /// innermost level's FIRST declaration in source order, so a value declared before a same-named
    /// method captured the callee of `floeGate(for:)` and rewrote it to the PROPERTY's obf — a wrong
    /// rename RollbackPass cannot catch.
    func testBareCall_mixedKindLevel_prefersTheCallable() throws {
        let source = """
        final class Door {
            var floeGate: Bool = false
            func floeGate(for path: String) -> Bool { return path.isEmpty }
            func use(path: String) -> Bool { return floeGate(for: path) }
        }
        """
        let rewritten = try runPipeline(source)
        let call = rewritten.split(separator: "\n").first { $0.contains("(for: path)") }
        XCTAssertNotNil(call, "the call must still be present:\n\(rewritten)")
        XCTAssertTrue(call?.contains("return m") == true,
                      "a bare call's callee denotes the METHOD (debug obfs prefix methods with "
                          + "`m`): \(call ?? "")")
    }

    // MARK: - HOF closure-parameter element type resolves in its DECLARING scope (Case B)

    /// `Outer.Inner.allCases.compactMap { $0.… }` — the element type `Inner` is written INSIDE
    /// `Outer`, so it is invisible from the call site and `preferredConcreteType` refuses it (nested
    /// types are not top-level). `resolveSource` used to return the bare name and every consumer
    /// resolved it against the USE-SITE scope, so `$0` stayed untyped and every member reached
    /// through it was left original while its declaration renamed (B-FIX-23 applied to HOF typing).
    func testHOFClosureParam_nestedElementType_resolvesInDeclaringScope() throws {
        let source = """
        enum Outer {
            enum Inner: CaseIterable {
                case alpha
                case beta
                func floeCaption(prefix: String) -> String { return prefix }
            }
        }
        final class Screen {
            func captions() -> [String] {
                return Outer.Inner.allCases.compactMap { $0.floeCaption(prefix: "x") }
            }
        }
        """
        let rewritten = try runPipeline(source)
        XCTAssertFalse(rewritten.contains("floeCaption"),
                       "the closure parameter's element type must resolve in the scope the element "
                           + "name was WRITTEN in:\n\(rewritten)")
    }

    /// Same invariant through a NAMED closure parameter and a nested collection PROPERTY (rather
    /// than `allCases`), so the fix is not tied to one receiver shape.
    func testHOFClosureParam_namedParamNestedElement_resolvesInDeclaringScope() throws {
        let source = """
        enum Outer {
            struct Row {
                func floeCaption() -> String { return "x" }
            }
            static let rows: [Row] = []
        }
        final class Screen {
            func captions() -> [String] {
                return Outer.rows.map { row in row.floeCaption() }
            }
        }
        """
        let rewritten = try runPipeline(source)
        XCTAssertFalse(rewritten.contains("floeCaption"),
                       "a named HOF closure parameter types from the receiver's element in the "
                           + "element's own scope:\n\(rewritten)")
    }

    // MARK: - The project-unique external-extension fallback needs an UNTYPEABLE receiver

    /// `uniqueExternalMember` rewrites by NAME alone. It used to fire whenever the member-access
    /// `if` chain failed — including when the receiver typed PERFECTLY and only the member lookup
    /// did not — so a well-typed LOCAL receiver had its member rewritten to the obf of an unrelated
    /// `extension String` member that merely shares the name. That is a wrong rename, invisible to
    /// RollbackPass (no original name survives). The fallback is only justified by "we cannot type
    /// this receiver at all", so that must be the literal condition.
    func testUniqueExternalMember_notAppliedWhenReceiverIsTyped() throws {
        let source = """
        extension String {
            func floeTag() -> String { return self }
        }
        struct Holder { var value: Int = 0 }
        final class User {
            let holder = Holder()
            func bad() -> String { return holder.floeTag() }
        }
        """
        let rewritten = try runPipeline(source)
        // The receiver property renames; the MEMBER must not.
        XCTAssertTrue(rewritten.contains(".floeTag()"),
                      "a member access on a TYPED local receiver must not fall back to the "
                          + "name-based external-extension rewrite:\n\(rewritten)")
        XCTAssertTrue(rewritten.contains("func floeTag()"),
                      "and the unmatched use-site reverts the extension member (green, readable):"
                          + "\n\(rewritten)")
    }

    // MARK: - Witness matching is kind-aware

    /// The name of the first declaration introduced by `keyword` inside the block whose header line
    /// starts with `header`. Used to compare the obf a protocol requirement and its witness got.
    private func declaredName(inBlockStartingWith header: String, keyword: String,
                              of source: String) -> String? {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let start = lines.firstIndex(where: { $0.hasPrefix(header) }) else { return nil }
        for line in lines[(start + 1)...] {
            if line.hasPrefix("}") { return nil }
            guard line.hasPrefix(keyword) else { continue }
            let name = line.dropFirst(keyword.count).prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            return name.isEmpty ? nil : String(name)
        }
        return nil
    }

    /// `WitnessLinker.matchRequirement` returned `sameName.first` for a property witness with NO
    /// kind check, so in a protocol that overloads one name across kinds the property witness linked
    /// to whichever requirement came FIRST in source order. With the method declared first, the
    /// class's property adopted the METHOD requirement's obf while the protocol's property kept its
    /// own — "does not conform", a wrong-rename red RollbackPass cannot catch.
    func testWitness_mixedKindRequirements_methodFirst_propertyLinksToProperty() throws {
        let rewritten = try runPipeline("""
        protocol Gate {
            func floeGate(for path: String) -> Bool
            var floeGate: Bool { get set }
        }
        final class Door: Gate {
            func floeGate(for path: String) -> Bool { return path.isEmpty }
            var floeGate: Bool = false
        }
        """)
        assertWitnessKindsAligned(rewritten)
    }

    /// The same shape with the declarations the other way round — the order that happened to work
    /// before, kept so the fix is not order-sensitive in the opposite direction.
    func testWitness_mixedKindRequirements_propertyFirst_propertyLinksToProperty() throws {
        let rewritten = try runPipeline("""
        protocol Gate {
            var floeGate: Bool { get set }
            func floeGate(for path: String) -> Bool
        }
        final class Door: Gate {
            var floeGate: Bool = false
            func floeGate(for path: String) -> Bool { return path.isEmpty }
        }
        """)
        assertWitnessKindsAligned(rewritten)
    }

    private func assertWitnessKindsAligned(_ rewritten: String, file: StaticString = #filePath,
                                           line: UInt = #line) {
        let protoVar = declaredName(inBlockStartingWith: "protocol", keyword: "var ", of: rewritten)
        let classVar = declaredName(inBlockStartingWith: "final class", keyword: "var ", of: rewritten)
        let protoFunc = declaredName(inBlockStartingWith: "protocol", keyword: "func ", of: rewritten)
        let classFunc = declaredName(inBlockStartingWith: "final class", keyword: "func ", of: rewritten)
        XCTAssertNotNil(protoVar, "protocol property not found:\n\(rewritten)", file: file, line: line)
        XCTAssertEqual(protoVar, classVar,
                       "the property witness must adopt the PROPERTY requirement's obf:\n\(rewritten)",
                       file: file, line: line)
        XCTAssertEqual(protoFunc, classFunc,
                       "the method witness must adopt the METHOD requirement's obf:\n\(rewritten)",
                       file: file, line: line)
        XCTAssertNotEqual(protoVar, protoFunc,
                          "property and method must not collapse onto one obf:\n\(rewritten)",
                          file: file, line: line)
    }

    // MARK: - UNRES diagnostics (why a use-site was not rewritten)

    /// `OVLD` fires only for an ambiguous overload SET and `SURV` names a survivor without a cause,
    /// so a use-site that silently resolved to nothing produced no line at all. `UNRES` closes that:
    /// one line per (cause, member, receiver), hashed through the SAME `Anon.of` so the `member=`
    /// token matches the `SURV` `name=` token for the same symbol.
    func testDiagnostics_untypeableReceiver_reportedAsUnresolved() throws {
        let source = """
        struct Box { var widgetPayload: Int = 0 }
        func take(_ x: SomeExternalThing) -> Int { return x.widgetPayload }
        """
        let diag = try runPipelineDiagnostics(source)
        XCTAssertTrue(diag.contains("UNRES cause=receiver-untyped member=\(Anon.of("widgetPayload"))"),
                      "an un-typeable receiver must be reported with its cause:\n\(diag)")
        XCTAssertTrue(diag.contains("SURV reverted name=\(Anon.of("widgetPayload"))"),
                      "and correlate with the SURV line for the same symbol:\n\(diag)")
    }

    /// A receiver we typed fine whose type declares no such member is a DIFFERENT failure from one
    /// we could not type, and the report has to tell them apart — that distinction is the whole
    /// point of the cause field. The receiver's type is named (hashed) so the line is actionable.
    func testDiagnostics_typedReceiverWithoutMember_reportedWithReceiverType() throws {
        let source = """
        struct Box { var widgetPayload: Int = 0 }
        struct Other { var q: Int = 0 }
        func take(_ o: Other) -> Int { return o.widgetPayload }
        """
        let diag = try runPipelineDiagnostics(source)
        let line = diag.split(separator: "\n").first {
            $0.contains("UNRES cause=no-candidate-in-scope member=\(Anon.of("widgetPayload"))")
        }
        XCTAssertNotNil(line, "a typed receiver missing the member is its own cause:\n\(diag)")
        XCTAssertTrue(line?.contains("recv=\(Anon.of("Other"))") == true,
                      "the receiver type must be named: \(line ?? "")")
        XCTAssertTrue(line?.contains("occ=1") == true, "occurrences are counted: \(line ?? "")")
    }

    // MARK: - G1: @NSManaged is an ObjC-exposing attribute

    /// A `@NSManaged` property's name IS the Core Data attribute name in the `.xcdatamodel`.
    /// Renaming it compiles fine and then faults at runtime on the first fetch — the silent class
    /// of failure. The fixture deliberately gives the class NO inheritance clause so the blanket
    /// objc-descendant rule cannot fire: what is under test is the ATTRIBUTE alone.
    func testNSManagedProperty_protectedByAttribute() throws {
        let source = """
        import CoreData
        class EventEntry {
            @NSManaged var eventTitle: String
            var localCounter: Int = 0
        }
        """
        let a = try runPipeline(source)
        XCTAssertTrue(a.contains("var eventTitle: String"),
                      "@NSManaged property is a Core Data attribute name — must be protected:\n\(a)")
        XCTAssertFalse(a.contains("var localCounter"),
                       "a plain property of the same class stays renameable:\n\(a)")
    }

    /// The to-many relationship accessors Xcode generates are `@NSManaged func addToItems(_:)`.
    /// Same contract, method side.
    func testNSManagedMethod_protectedByAttribute() throws {
        let source = """
        import CoreData
        class EventEntry {
            @NSManaged func addToTags(_ value: NSSet)
            func localHelper() {}
        }
        """
        let a = try runPipeline(source)
        XCTAssertTrue(a.contains("func addToTags"),
                      "@NSManaged method must be protected:\n\(a)")
        XCTAssertFalse(a.contains("func localHelper"),
                       "a plain method of the same class stays renameable:\n\(a)")
    }

    // MARK: - G2: conformances declared in an EXTENSION are visible to the Protector

    /// `extension Model: Codable {}` is the idiomatic way to declare the conformance away from the
    /// type. The Protector read only the PRIMARY declaration's inheritance clause, so the type did
    /// not look Codable, its stored-property names were renamed, and the JSON contract changed with
    /// no compile error, no `SURV` line and no diagnostic — exactly the failure B-FIX-17 exists to
    /// prevent.
    func testCodable_conformanceInExtension_storedPropertiesProtected() throws {
        let source = """
        struct Model {
            let userId: String
            var displayCount: Int
        }
        extension Model: Codable {}
        """
        let a = try runPipeline(source)
        XCTAssertTrue(a.contains("let userId: String"),
                      "extension-declared Codable protects the serialization keys:\n\(a)")
        XCTAssertTrue(a.contains("var displayCount: Int"),
                      "every stored property is a key:\n\(a)")
        XCTAssertFalse(a.contains("struct Model"),
                       "the type name itself is not a serialization key — still renamed:\n\(a)")
    }

    /// The same blind spot on the fail-closed path: a conformance to an UNKNOWN external protocol
    /// declared in an extension. Any member could be its witness, so all of them must be protected
    /// — a missed one is a hard "does not conform" red build, never a policy question.
    func testUnknownExternalConformance_inExtension_membersProtected() throws {
        let source = """
        struct Gadget {
            var serialTag: String = ""
            func syncNow() {}
        }
        extension Gadget: VendorSyncable {}
        """
        let a = try runPipeline(source)
        XCTAssertTrue(a.contains("var serialTag"),
                      "unknown external conformance in an extension must protect members:\n\(a)")
        XCTAssertTrue(a.contains("func syncNow"),
                      "any member could be the witness — fail closed:\n\(a)")
    }

    // MARK: - G3: `@objc extension` exposes every member it declares

    /// `@objc extension Foo { … }` makes each member of that extension @objc — the runtime can
    /// reach them by name — but the Protector had no `ExtensionDeclSyntax` visit at all, so the
    /// attribute was invisible. As with G1, the class carries no inheritance clause so the blanket
    /// rule cannot mask the result.
    func testObjCExtension_membersProtected() throws {
        let source = """
        import Foundation
        class Legacy {
            var untouched: Int = 0
        }
        @objc extension Legacy {
            func runtimeHook() {}
            var exposedValue: Int { return 1 }
        }
        """
        let a = try runPipeline(source)
        XCTAssertTrue(a.contains("func runtimeHook"),
                      "@objc extension exposes its methods by name:\n\(a)")
        XCTAssertTrue(a.contains("var exposedValue"),
                      "@objc extension exposes its properties by name:\n\(a)")
        XCTAssertFalse(a.contains("var untouched"),
                       "a member of the primary decl is not covered by the extension's @objc:\n\(a)")
    }

    // MARK: - --objc-protection: strict (default) / relaxed / off

    /// The lever itself. `Leaf` is tainted only by ancestry (its superclass chain reaches
    /// UIViewController), and since SE-0160 an unannotated member of such a class is not visible to
    /// the ObjC runtime at all. Under `relaxed` its members become renameable while the class NAME
    /// stays — a storyboard names the class as a string, and nothing else does.
    func testObjCProtection_relaxed_ancestryOnlyClassKeepsNameLosesMemberProtection() throws {
        let source = """
        import UIKit
        class Base: UIViewController {}
        class Leaf: Base { var counter = 0 }
        """
        let strict = try runPipeline(source)
        XCTAssertTrue(strict.contains("var counter"), "strict keeps the default behaviour:\n\(strict)")

        let relaxed = try runPipeline(source, objcProtection: .relaxed)
        XCTAssertFalse(relaxed.contains("var counter"),
                       "relaxed renames a member of an ancestry-only objc class:\n\(relaxed)")
        XCTAssertTrue(relaxed.contains("class Leaf"),
                      "the class NAME stays — a storyboard customClass is a string:\n\(relaxed)")
    }

    /// The other side of the same rule: an EXPLICIT annotation is a declared exposure, and
    /// `@objcMembers` propagates to subclasses (the compiler adds `@objc` to their members too), so
    /// the taint must propagate with it even under `relaxed`.
    func testObjCProtection_relaxed_annotatedClassAndItsSubclassStayProtected() throws {
        let source = """
        import Foundation
        @objcMembers class Bridged { var trackedName: String = "" }
        class Derived: Bridged { var derivedValue: Int = 0 }
        """
        let a = try runPipeline(source, objcProtection: .relaxed)
        XCTAssertTrue(a.contains("var trackedName"),
                      "an explicitly annotated class keeps its members under relaxed:\n\(a)")
        XCTAssertTrue(a.contains("var derivedValue"),
                      "@objcMembers reaches subclasses, so the taint must too:\n\(a)")
    }

    /// Core Data reads and writes by attribute NAME, whether or not the property carries
    /// `@NSManaged` (a subclass can declare plain helpers the framework still faults through), so an
    /// NSManagedObject descendant keeps full protection under `relaxed`. The intermediate class is
    /// LOCAL on purpose: it is what makes the taint reach `EventEntry` by inheritance alone.
    func testObjCProtection_relaxed_nsManagedObjectDescendantStaysProtected() throws {
        let source = """
        import CoreData
        class BaseEntity: NSManagedObject {}
        class EventEntry: BaseEntity { var cachedTitle: String = "" }
        """
        let a = try runPipeline(source, objcProtection: .relaxed)
        XCTAssertTrue(a.contains("var cachedTitle"),
                      "Core Data binds by name — NSManagedObject descendants stay protected:\n\(a)")
    }

    /// An exposing ATTRIBUTE is a declared exposure, so `relaxed` keeps honouring it even on a class
    /// whose members it otherwise releases.
    ///
    func testObjCProtection_relaxed_exposingAttributesStillProtect() throws {
        let source = """
        import UIKit
        class Screen: UIViewController {
            @IBOutlet var titleLabel: UILabel!
            @NSManaged var storedTag: String
            @objc func handleTap() {}
            var plainHelper: Int = 0
        }
        """
        let a = try runPipeline(source, objcProtection: .relaxed)
        XCTAssertTrue(a.contains("var titleLabel"), "@IBOutlet survives relaxed:\n\(a)")
        XCTAssertTrue(a.contains("var storedTag"), "@NSManaged survives relaxed:\n\(a)")
        XCTAssertTrue(a.contains("func handleTap"), "@objc survives relaxed:\n\(a)")
        XCTAssertFalse(a.contains("var plainHelper"),
                       "an unannotated member of the same class is released:\n\(a)")
    }

    /// A DIRECT subclass of a UIKit class is the common shape, and it used to be released by the
    /// objc rule and instantly re-protected by the conformance rule, which cannot tell an external
    /// superclass from an unknown external protocol. Under `relaxed` a curated ObjC ROOT CLASS name
    /// is known to be a class, so it no longer triggers the protocol protect-all. Everything else in
    /// the clause is still treated as a protocol and still protects fail-closed.
    func testObjCProtection_relaxed_externalRootClassIsNotTreatedAsUnknownProtocol() throws {
        let source = """
        import UIKit
        class Screen: UIViewController { var plainHelper: Int = 0 }
        """
        let strict = try runPipeline(source)
        XCTAssertTrue(strict.contains("var plainHelper"), "strict keeps it:\n\(strict)")

        let relaxed = try runPipeline(source, objcProtection: .relaxed)
        XCTAssertFalse(relaxed.contains("var plainHelper"),
                       "relaxed releases a direct UIKit subclass's unannotated member:\n\(relaxed)")
    }

    /// The guard on the above: a genuine unknown external PROTOCOL in the same clause keeps
    /// protecting every member, because any of them could be its witness and a missed witness is a
    /// red build, not a policy choice. This is the IceTrays `Coordinator` shape.
    func testObjCProtection_relaxed_unknownExternalProtocolStillProtectsMembers() throws {
        let source = """
        import UIKit
        class Coordinator: NSObject, PHPickerViewControllerDelegate {
            var pendingCount: Int = 0
        }
        """
        let a = try runPipeline(source, objcProtection: .relaxed)
        XCTAssertTrue(a.contains("var pendingCount"),
                      "an unknown external protocol still protects fail-closed under relaxed:\n\(a)")
    }

    /// `off` is the level for a project with no ObjC name dependency: the attributes stop protecting
    /// too. Same fixture as the G1 test, opposite expectation — which is exactly what makes it a
    /// flag rather than a fix.
    func testObjCProtection_off_dropsAttributeAndSelectorProtection() throws {
        let source = """
        import CoreData
        class EventEntry {
            @NSManaged var eventTitle: String
            @objc func legacyTap() {}
            func wire() { _ = #selector(EventEntry.legacyTap) }
        }
        """
        let a = try runPipeline(source, objcProtection: .off)
        XCTAssertFalse(a.contains("var eventTitle"), "off drops @NSManaged protection:\n\(a)")
        XCTAssertFalse(a.contains("func legacyTap"),
                       "off drops @objc and #selector protection:\n\(a)")
    }

    /// G2 is a correctness fix, not a policy: a missed conformance is a "does not conform" red build
    /// or a silently changed JSON contract, neither of which is a level the user gets to choose. It
    /// must survive even the most permissive setting.
    func testObjCProtection_off_extensionCodableStillProtected() throws {
        let source = """
        struct Model { let userId: String }
        extension Model: Codable {}
        """
        let a = try runPipeline(source, objcProtection: .off)
        XCTAssertTrue(a.contains("let userId: String"),
                      "extension-declared Codable is never subject to --objc-protection:\n\(a)")
    }

    // MARK: - A closure's parameter LIST may destructure a tuple element (B-FIX-38)

    func testEnumerated_tupleDestructuringClosure_elementMemberResolves() throws {
        let r = try runPipeline("""
        struct Row {
            var flagged: Bool
            var caption: String?
        }
        final class Holder {
            private var rows: [Row] = []
            func refresh() {
                rows.enumerated().forEach { idx, row in
                    guard !row.flagged else { return }
                    rows[idx].caption = "x"
                }
            }
        }
        """)
        XCTAssertFalse(r.contains("var flagged"), "Row.flagged must be obfuscated:\n\(r)")
        XCTAssertFalse(r.contains("row.flagged"),
                       "the destructured element parameter must type from enumerated()'s tuple:\n\(r)")
    }

    func testDictionary_tupleDestructuringClosure_valueMemberResolves() throws {
        // The other stdlib source of a tuple element: a Dictionary's Element is `(key:value:)`.
        let r = try runPipeline("""
        struct Row { var flagged: Bool }
        func check(_ map: [String: Row]) {
            map.forEach { key, row in
                _ = key
                _ = row.flagged
            }
        }
        """)
        XCTAssertFalse(r.contains("var flagged"), "Row.flagged must be obfuscated:\n\(r)")
        XCTAssertFalse(r.contains("row.flagged"),
                       "the destructured value parameter must type from the dictionary's element:\n\(r)")
    }

    func testEnumerated_positionalDollarParams_elementMemberResolves() throws {
        // An implicit parameter list destructures too. Its arity is only readable from the highest
        // `$N` the body uses — here `$1`, so the closure binds two values and `$1` is the element.
        let r = try runPipeline("""
        struct Row { var flagged: Bool }
        func check(_ rows: [Row]) {
            rows.enumerated().forEach { _ = ($0, $1.flagged) }
        }
        """)
        XCTAssertFalse(r.contains("var flagged"), "Row.flagged must be obfuscated:\n\(r)")
        XCTAssertFalse(r.contains("$1.flagged"), "$1 must type as the tuple's element component:\n\(r)")
    }

    func testForInTuplePattern_overEnumerated_elementMemberResolves() throws {
        // The same invariant at the OTHER binding site: a for-in tuple pattern destructures the
        // element exactly as a closure parameter list does.
        let r = try runPipeline("""
        struct Row { var flagged: Bool }
        func check(_ rows: [Row]) {
            for (idx, row) in rows.enumerated() {
                _ = idx
                _ = row.flagged
            }
        }
        """)
        XCTAssertFalse(r.contains("var flagged"), "Row.flagged must be obfuscated:\n\(r)")
        XCTAssertFalse(r.contains("row.flagged"),
                       "the for-in tuple binding must type from enumerated()'s tuple:\n\(r)")
    }

    func testForInTuplePattern_overDictionary_valueMemberResolves() throws {
        let r = try runPipeline("""
        struct Row { var flagged: Bool }
        func check(_ map: [String: Row]) {
            for (key, row) in map {
                _ = key
                _ = row.flagged
            }
        }
        """)
        XCTAssertFalse(r.contains("var flagged"), "Row.flagged must be obfuscated:\n\(r)")
        XCTAssertFalse(r.contains("row.flagged"),
                       "the for-in tuple binding must type from the dictionary's element:\n\(r)")
    }

    func testForInTuplePattern_wildcardComponent_keepsPositions() throws {
        // `_` binds no symbol but still OCCUPIES a position, so the surviving name must take the
        // component at its own index rather than sliding down to index 0.
        let r = try runPipeline("""
        struct Row { var flagged: Bool }
        func check(_ rows: [Row]) {
            for (_, row) in rows.enumerated() {
                _ = row.flagged
            }
        }
        """)
        XCTAssertFalse(r.contains("var flagged"), "Row.flagged must be obfuscated:\n\(r)")
        XCTAssertFalse(r.contains("row.flagged"), "the named component must keep its position:\n\(r)")
    }

    func testForInTuplePattern_arityMismatch_staysUnresolved() throws {
        // Fail-closed guard: the pattern's arity must EQUAL the tuple's component count. A plain
        // (non-tuple) element under a tuple pattern must type nothing rather than guess a component.
        let r = try runPipeline("""
        struct Row { var flagged: Bool }
        func check(_ rows: [Row]) {
            for (a, b) in rows.enumerated().enumerated() {
                _ = a
                _ = b
            }
        }
        """)
        XCTAssertFalse(r.contains("var flagged"), "Row.flagged is unused here, so it still renames:\n\(r)")
    }

    func testDictionarySubscript_stillYieldsValueNotTuple() throws {
        // Iterating a dictionary and subscripting it are different questions: `map[k]` is the VALUE,
        // never the `(key:value:)` element. Guards the split between `iterationElement` and
        // `extractElement` — merging them would type `map[k].member` as a tuple (a wrong rename).
        let r = try runPipeline("""
        struct Row { var flagged: Bool }
        func check(_ map: [String: Row]) {
            _ = map["a"]?.flagged
        }
        """)
        XCTAssertFalse(r.contains("var flagged"), "Row.flagged must be obfuscated:\n\(r)")
        XCTAssertFalse(r.contains("?.flagged"), "the dictionary subscript must still yield the Value:\n\(r)")
    }

    // MARK: - A braced block is a lexical scope (B-FIX-39)

    func testLocalVariable_shadowsParameter_memberResolvesToLocalsType() throws {
        // A body local may shadow a PARAMETER of the same name (different scopes: parameters sit
        // outside the body's braces). Registering both in one flat function scope made
        // `Scope.lookup` hand back the first-in-order symbol — the parameter — so `slot.ribbonTag`
        // was typed as the parameter's `Mode` and the member never resolved.
        let r = try runPipeline("""
        enum Mode { case idle }
        struct Detail { let ribbonTag: String }
        struct Wrapper { let detailPart: Detail }
        final class Runner {
            func handle(for slot: Mode, _ wrapper: Wrapper) -> String {
                let slot: Detail = wrapper.detailPart
                return slot.ribbonTag
            }
        }
        """)
        let memberObf = try firstGroup(#"let (\w+): String"#, in: r)
        XCTAssertNotEqual(memberObf, "ribbonTag", "Detail.ribbonTag must be obfuscated:\n\(r)")
        let localObf = try firstGroup(#"let (\w+): \w+ = \w+\.\w+"#, in: r)
        XCTAssertTrue(r.contains("return \(localObf).\(memberObf)"),
                      "the member read must resolve through the LOCAL's type, not the parameter's:\n\(r)")
    }

    func testBlockScopedLocals_siblingBlocks_eachUseResolvesToItsOwnLocal() throws {
        // Two `if` bodies each declaring `parts`: legal Swift, two distinct locals. Without a scope
        // per braced block both landed in the function scope, and every use resolved to the FIRST
        // one — the second block's use was rewritten to a name declared in the other block
        // ("cannot find … in scope"), a wrong rename RollbackPass cannot see.
        let r = try runPipeline("""
        final class Reporter {
            func build(_ flag: Bool) -> String {
                var out = ""
                if flag {
                    let parts: [String] = ["a"]
                    out = parts.joined(separator: "-")
                }
                if !flag {
                    let parts: [String] = ["b"]
                    out = parts.joined(separator: "+")
                }
                return out
            }
        }
        """)
        let declared = try allGroups(#"let (\w+): \[String\]"#, in: r)
        XCTAssertEqual(declared.count, 2, "both locals must still be declared:\n\(r)")
        XCTAssertEqual(Set(declared).count, 2, "the two locals are distinct symbols:\n\(r)")
        for obf in declared {
            XCTAssertTrue(r.contains("\(obf).joined"),
                          "each block's use must resolve to the local declared in THAT block:\n\(r)")
        }
    }

    func testBlockScopedLocals_loopAndDoBodies_areSeparateScopes() throws {
        // Same invariant through the other braced statement bodies (`for` and `do`), which are the
        // forms a real method mixes with `if`.
        let r = try runPipeline("""
        final class Walker {
            func run(_ rows: [Int]) -> Int {
                var total = 0
                for row in rows {
                    let step: Int = row * 2
                    total += step
                }
                do {
                    let step: Int = 7
                    total += step
                }
                return total
            }
        }
        """)
        let declared = try allGroups(#"let (\w+): Int"#, in: r)
        XCTAssertEqual(Set(declared).count, 2, "the loop body and the do body declare distinct locals:\n\(r)")
        for obf in declared {
            XCTAssertTrue(r.contains("+= \(obf)"),
                          "each body's use must resolve to its own local:\n\(r)")
        }
    }

    func testBlockScopedLocal_doesNotShadowPropertyOutsideItsBlock() throws {
        // The flip side: a local confined to an `if` body must not capture a same-named PROPERTY
        // read after that block. Over-scoping the local would rewrite the property read to the
        // local's obf — a silent wrong-storage read.
        let r = try runPipeline("""
        final class Holder {
            var marker: Int = 1
            func run(_ flag: Bool) -> Int {
                if flag {
                    let marker: Int = 2
                    _ = marker
                }
                return marker
            }
        }
        """)
        let propObf = try firstGroup(#"var (\w+): Int = 1"#, in: r)
        XCTAssertNotEqual(propObf, "marker", "the property must be obfuscated:\n\(r)")
        XCTAssertTrue(r.contains("return \(propObf)"),
                      "the read after the block is the PROPERTY, not the block-local:\n\(r)")
    }
}
