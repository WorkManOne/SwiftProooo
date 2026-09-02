import XCTest
@testable import SwiftProfCore

/// Restoring original identifiers in ERROR TEXT via `ConversionMap` read in reverse.
final class DeobfuscatorTests: XCTestCase {

    private func entry(_ original: String, _ obfuscated: String,
                       kind: String = "class", module: String = "App") -> ConversionEntry {
        ConversionEntry(original: original, obfuscated: obfuscated, kind: kind, module: module)
    }

    // A realistic random obf (32-char). Distinct, ASCII, matches NamePool.mintRandom shape.
    private let randUserService = "saysrsrtdurdfgjdgfjdfgjklmnopqrs"   // 32
    private let randSave        = "qwexklmnopabcdefghijklxyztuvwabcd"   // 32

    // MARK: - Core replacement

    func testReplace_restoresOriginalsInDiagnostic() {
        let d = Deobfuscator(entries: [
            entry("UserService", randUserService),
            entry("save", randSave, kind: "method"),
        ])
        let input = "error: value of type '\(randUserService)' has no member '\(randSave)'"
        XCTAssertEqual(d.deobfuscate(input, mode: .replace),
                       "error: value of type 'UserService' has no member 'save'")
    }

    func testUnknownToken_passesThroughUnchanged() {
        let d = Deobfuscator(entries: [entry("UserService", randUserService)])
        let input = "error: cannot find 'somethingElse' in scope; note: 42 near line"
        XCTAssertEqual(d.deobfuscate(input, mode: .replace), input)
    }

    // MARK: - Token boundaries

    func testTokenBoundary_substringOfAnIdentifierIsNotTouched() {
        let d = Deobfuscator(entries: [entry("save", randSave, kind: "method")])
        // The obf appears as a SUBSTRING of a longer identifier — must NOT be replaced.
        let input = "let my\(randSave)Value = 1 // \(randSave)_suffix and prefix_\(randSave)"
        let out = d.deobfuscate(input, mode: .replace)
        XCTAssertTrue(out.contains("my\(randSave)Value"), "longer identifier must be left intact")
        XCTAssertTrue(out.contains("\(randSave)_suffix"), "underscore keeps it one token")
        XCTAssertTrue(out.contains("prefix_\(randSave)"), "underscore keeps it one token")
        XCTAssertFalse(out.contains("mysaveValue"), "must not have replaced the substring")
    }

    func testWholeIdentifierInQuotes_isReplaced() {
        let d = Deobfuscator(entries: [entry("save", randSave, kind: "method")])
        XCTAssertEqual(d.deobfuscate("has no member '\(randSave)'", mode: .replace),
                       "has no member 'save'")
    }

    // MARK: - Qualified names

    func testQualifiedName_eachSegmentRestoredIndependently() {
        let modType = "Aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"  // 32
        let d = Deobfuscator(entries: [
            entry("UserService", randUserService),
            entry("save", randSave, kind: "method"),
            entry("Model", modType, kind: "struct"),
        ])
        let input = "\(randUserService).\(randSave)(\(modType))"
        XCTAssertEqual(d.deobfuscate(input, mode: .replace), "UserService.save(Model)")
    }

    // MARK: - Annotate

    func testAnnotate_keepsObfAndAppendsOriginal() {
        let d = Deobfuscator(entries: [entry("save", randSave, kind: "method")])
        XCTAssertEqual(d.deobfuscate("member '\(randSave)'", mode: .annotate),
                       "member '\(randSave)⟨→save⟩'")
    }

    // MARK: - Ambiguity (one obf -> several distinct originals)

    func testAmbiguousObf_annotatedWithKindAndModuleEvenInReplaceMode() {
        let shared = "Zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"  // 32
        let d = Deobfuscator(entries: [
            entry("save", shared, kind: "method", module: "App"),
            entry("store", shared, kind: "method", module: "UI"),
        ])
        let out = d.deobfuscate("'\(shared)'", mode: .replace)
        XCTAssertTrue(out.contains("save[method@App]"), out)
        XCTAssertTrue(out.contains("store[method@UI]"), out)
        XCTAssertTrue(out.contains(shared), "obf must be kept when ambiguous")
    }

    func testSameObfSameOriginal_isNotAmbiguous_replacedCleanly() {
        // A witness group maps requirement + witness (same name) to one obf — one original.
        let shared = "Bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"  // 32
        let d = Deobfuscator(entries: [
            entry("render", shared, kind: "method", module: "App"),
            entry("render", shared, kind: "method", module: "App"),
        ])
        XCTAssertEqual(d.deobfuscate("'\(shared)'", mode: .replace), "'render'")
    }

    // MARK: - Style detection & default mode

    func testStyleDetection_randomMapDefaultsToReplace() {
        let d = Deobfuscator(entries: [entry("UserService", randUserService)])
        XCTAssertEqual(d.style, .random)
        XCTAssertEqual(d.defaultMode, .replace)
    }

    func testStyleDetection_debugMapDefaultsToAnnotate() {
        let d = Deobfuscator(entries: [
            entry("UserService", "T0", kind: "class"),
            entry("save", "m0", kind: "method"),
            entry("count", "p0", kind: "property"),
        ])
        XCTAssertEqual(d.style, .debug)
        XCTAssertEqual(d.defaultMode, .annotate)
    }

    func testDebugName_annotateDoesNotDestroyPossiblyRealIdentifier() {
        // 'p0' is a debug obf but could be a real variable in the text; annotate keeps it.
        let d = Deobfuscator(entries: [entry("count", "p0", kind: "property")])
        XCTAssertEqual(d.deobfuscate("value 'p0' here", mode: .annotate), "value 'p0⟨→count⟩' here")
    }

    // MARK: - Multiple maps (merge)

    func testMultipleMaps_mergeAndConflictBecomesAmbiguity() throws {
        // Two ConversionMap.json files, one obf reused across them with different originals.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deobf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let shared = "Cccccccccccccccccccccccccccccccc"  // 32
        let m1 = dir.appendingPathComponent("m1.json")
        let m2 = dir.appendingPathComponent("m2.json")
        try #"{"entries":[{"original":"alpha","obfuscated":"\#(shared)","kind":"method","module":"A"}]}"#
            .write(to: m1, atomically: true, encoding: .utf8)
        try #"{"entries":[{"original":"beta","obfuscated":"\#(shared)","kind":"method","module":"B"}]}"#
            .write(to: m2, atomically: true, encoding: .utf8)

        let d = try Deobfuscator.load(mapPaths: [m1.path, m2.path])
        let out = d.deobfuscate("'\(shared)'", mode: .replace)
        XCTAssertTrue(out.contains("alpha[method@A]"), out)
        XCTAssertTrue(out.contains("beta[method@B]"), out)
    }

    func testLoad_missingFile_throws() {
        XCTAssertThrowsError(try Deobfuscator.load(mapPaths: ["/nonexistent/ConversionMap.json"]))
    }

    func testLoad_realConversionMapJSON_roundTrips() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deobf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let map = dir.appendingPathComponent("ConversionMap.json")
        try #"""
        {"entries":[
          {"original":"UserService","obfuscated":"\#(randUserService)","kind":"class","module":"App"},
          {"original":"save","obfuscated":"\#(randSave)","kind":"method","module":"App"} ]}
        """#.write(to: map, atomically: true, encoding: .utf8)

        let d = try Deobfuscator.load(mapPaths: [map.path])
        XCTAssertEqual(d.deobfuscate("type '\(randUserService)' member '\(randSave)'", mode: .replace),
                       "type 'UserService' member 'save'")
    }

    // MARK: - Multi-line & passthrough integrity

    func testMultiline_onlyKnownTokensChange_restIsByteIdentical() {
        let d = Deobfuscator(entries: [entry("UserService", randUserService)])
        let input = """
        file.swift:12:5: error: value of type '\(randUserService)' has no member 'foo'
        file.swift:12:5: note: in expansion here
        """
        let expected = """
        file.swift:12:5: error: value of type 'UserService' has no member 'foo'
        file.swift:12:5: note: in expansion here
        """
        XCTAssertEqual(d.deobfuscate(input, mode: .replace), expected)
    }
}
