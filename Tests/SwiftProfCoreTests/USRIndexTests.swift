import XCTest
@testable import SwiftProfCore

/// Isolation tests for the libIndexStore reader (`USRIndex`). Each builds a real
/// index with `swiftc -index-store-path` over a tiny fixture, then asserts the
/// reader recovers known USRs, occurrence counts, and defining modules — and that
/// SwiftProf `Symbol` decl positions map onto the index's line:column convention.
///
/// These are the only tests that exercise the index path; the rest of the suite
/// runs with no `indexStorePath` (the syntactic baseline).
final class USRIndexTests: XCTestCase {

    /// Build an index from `files` (name → source) into a temp dir; return the
    /// store path plus the module root holding the sources. Skips the test if the
    /// toolchain can't produce a store (keeps the suite green off the dev box).
    private func buildIndex(files: [String: String], moduleName: String = "Demo")
        throws -> (storePath: String, moduleRoot: URL)
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("USRIndex-\(UUID().uuidString)")
        let src = root.appendingPathComponent(moduleName)
        let build = root.appendingPathComponent("build")
        let idx = root.appendingPathComponent("idx")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)

        var sourcePaths: [String] = []
        for (name, body) in files.sorted(by: { $0.key < $1.key }) {
            let url = src.appendingPathComponent(name)
            try body.write(to: url, atomically: true, encoding: .utf8)
            sourcePaths.append(url.path)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        proc.arguments = ["swiftc", "-index-store-path", idx.path,
                          "-index-ignore-system-modules", "-module-name", moduleName,
                          "-c"] + sourcePaths
        proc.currentDirectoryURL = build   // .o files land here, not in the source dir
        let err = Pipe()
        proc.standardError = err
        proc.standardOutput = Pipe()
        try proc.run()
        proc.waitUntilExit()

        let storeExists = FileManager.default.fileExists(atPath: idx.appendingPathComponent("v5").path)
        if proc.terminationStatus != 0 || !storeExists {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw XCTSkip("could not build index store (rc=\(proc.terminationStatus)): \(msg)")
        }
        return (idx.path, src)
    }

    /// Returns the table AND the project — the caller must retain the project for
    /// as long as it touches the table, because `Symbol.file` is `unowned` and the
    /// project owns the `SourceFile`s.
    private func symbolTable(forSourcesIn root: URL, moduleName: String = "Demo")
        throws -> (table: SymbolTable, project: LoadedProject)
    {
        let logger = StderrLogger(verbose: false)
        let specs = [ModuleSpec(name: moduleName, root: root, writable: true)]
        let project = try ProjectLoader(logger: logger).load(specs: specs)
        let table = SymbolTable()
        DeclarationPass(table: table, logger: logger).run(on: project.files)
        return (table, project)
    }

    func testFormatVersionIsExpected() {
        // The whole stability contract rests on this matching what we coded against.
        XCTAssertEqual(USRIndex.expectedFormatVersion, 5)
    }

    func testReadsUSRsOccurrencesAndDefiningModule() throws {
        let model = """
        struct Gadget {
            var width: Int
            func area() -> Int { width * width }
        }
        """
        let use = """
        func makeGadget() -> Int {
            let g = Gadget(width: 4)
            return g.area()
        }
        """
        let (storePath, moduleRoot) =
            try buildIndex(files: ["Model.swift": model, "Use.swift": use])

        let idx = try USRIndex(storePath: storePath)
        let (table, project) = try symbolTable(forSourcesIn: moduleRoot)
        let usrMap = idx.usrBySymbol(in: table)
        withExtendedLifetime(project) {}  // keep SourceFiles alive past the unowned reads

        func symbol(_ name: String, _ kind: SymbolKind) -> Symbol? {
            table.symbols.first { $0.name == name && $0.kind == kind }
        }

        // Gadget: decl position must map to a USR (proves byte-offset → line:col
        // → index column convention all line up). That USR is defined in "Demo"
        // and occurs at least twice: the struct decl and the `Gadget(width:)` call.
        guard let gadget = symbol("Gadget", .struct), let gadgetUSR = usrMap[gadget.id] else {
            return XCTFail("Gadget decl did not map to a USR (column/offset mismatch?)")
        }
        XCTAssertEqual(idx.definitionModule(ofUSR: gadgetUSR), "Demo")
        XCTAssertGreaterThanOrEqual(idx.occurrences(ofUSR: gadgetUSR).count, 2,
                                    "Gadget should occur at its decl + the constructor call")

        // area(): decl + the `g.area()` reference.
        guard let area = symbol("area", .method), let areaUSR = usrMap[area.id] else {
            return XCTFail("area decl did not map to a USR")
        }
        XCTAssertEqual(idx.definitionModule(ofUSR: areaUSR), "Demo")
        XCTAssertGreaterThanOrEqual(idx.occurrences(ofUSR: areaUSR).count, 2,
                                    "area should occur at its decl + the call site")

        // Distinct symbols get distinct USRs.
        XCTAssertNotEqual(gadgetUSR, areaUSR)

        // A made-up position resolves to nothing (fail-closed, no false positives).
        XCTAssertNil(idx.usr(atFile: moduleRoot.appendingPathComponent("Model.swift").path,
                             line: 999, column: 999))
    }

    func testFreshIndexIsNotStale() throws {
        // mtime calibration: a just-built index records each source's mtime; the
        // file on disk is not newer, so the staleness check (IndexStoreProvider)
        // must treat it as fresh. Here we assert the recorded mtime exists and is
        // not in the future relative to the file's own mtime in the same scale.
        let (storePath, moduleRoot) =
            try buildIndex(files: ["A.swift": "struct A { var x: Int }\n"])
        let idx = try USRIndex(storePath: storePath)
        let filePath = moduleRoot.appendingPathComponent("A.swift").path
        guard let recorded = idx.indexedModTime(forFile: filePath) else {
            return XCTFail("no recorded modification time for indexed file")
        }
        XCTAssertGreaterThan(recorded, 0)
        // The provider compares recorded-vs-filesystem; just assert the file is not
        // reported newer than the index when nothing changed.
        XCTAssertFalse(IndexStaleness.isStale(filePath: filePath, recordedModTime: recorded),
                       "a freshly indexed, untouched file must not read as stale")
    }
}
