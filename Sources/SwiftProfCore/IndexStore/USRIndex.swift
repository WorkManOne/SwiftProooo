import Foundation
import SwiftSyntax
import CIndexStore

/// A resolved source position as libIndexStore reports it: 1-based line/column
/// (UTF-8 byte column) in an absolute, symlink-resolved file path.
public struct IndexLocation: Hashable {
    public let file: String
    public let line: Int
    public let column: Int

    public init(file: String, line: Int, column: Int) {
        self.file = file
        self.line = line
        self.column = column
    }
}

public enum USRIndexError: Error, CustomStringConvertible {
    case formatVersionMismatch(found: UInt32, expected: UInt32)
    case storeOpenFailed(path: String, message: String)

    public var description: String {
        switch self {
        case .formatVersionMismatch(let found, let expected):
            return "index store format version \(found) != expected \(expected) — "
                + "rebuild the index with the current toolchain"
        case .storeOpenFailed(let path, let message):
            return "could not open index store at \(path): \(message)"
        }
    }
}

/// Compiler ground-truth, read from a libIndexStore record store. Maps source
/// positions to USRs and back. Advisory + fail-closed by construction: anything
/// the index does not contain is simply absent (→ under-obfuscation upstream),
/// never a wrong answer.
///
/// On open it asserts `indexstore_format_version()` equals the major it was built
/// against (`expectedFormatVersion`); a mismatch throws rather than risk reading
/// a layout it doesn't understand. The index is always read with the SAME
/// toolchain that produced it (the dylib is dlopen'd at RUNTIME, path resolved
/// via `xcrun` — see `IndexStoreDylib`), so USRs are never compared across
/// versions, and the binary itself carries no link-time toolchain dependency.
///
/// Staleness uses the unit *file's* on-disk mtime rather than libIndexStore's
/// `..._get_modification_time` accessor: the latter returns a non-`int64`
/// composite whose exact ABI we don't hand-declare safely, and the unit file's
/// filesystem mtime is the same signal in directly-comparable (epoch-seconds)
/// units. (See Handoff "Weak spots": coarse mtime is the sanctioned check.)
public final class USRIndex {
    /// The libIndexStore record-format major this code is written against. The
    /// toolchain in use today reports 5.
    public static let expectedFormatVersion: UInt32 = 5

    /// occurrence position → USR (definitions and references alike).
    private var usrByLocation: [IndexLocation: String] = [:]
    /// USR → every occurrence position (the full use-site set; what A6 validates).
    private var occurrencesByUSR: [String: [IndexLocation]] = [:]
    /// USR → defining module, taken from the unit whose record holds the
    /// symbol's DEFINITION occurrence (robust; avoids parsing USR mangling).
    private var definitionModuleByUSR: [String: String] = [:]
    /// resolved source file path → newest indexing time (epoch seconds) of a unit
    /// that has it as its main file. Compared against the source's own mtime.
    private var indexedModTimeByFile: [String: Int64] = [:]

    public init(storePath: String) throws {
        let lib = try IndexStoreDylib.shared()
        let version = lib.formatVersion()
        guard version == Self.expectedFormatVersion else {
            throw USRIndexError.formatVersionMismatch(
                found: version, expected: Self.expectedFormatVersion)
        }

        var errorPtr: indexstore_error_t?
        guard let store = storePath.withCString({ lib.storeCreate($0, &errorPtr) }) else {
            let message = errorPtr.flatMap { e in
                lib.errorGetDescription(e).map { String(cString: $0) }
            } ?? "unknown error"
            if let e = errorPtr { lib.errorDispose(e) }
            throw USRIndexError.storeOpenFailed(path: storePath, message: message)
        }
        defer { lib.storeDispose(store) }

        let walker = IndexWalker(lib: lib, store: store, storePath: storePath)
        walker.run()

        usrByLocation = walker.usrByLocation
        occurrencesByUSR = walker.occurrencesByUSR
        definitionModuleByUSR = walker.definitionModuleByUSR
        indexedModTimeByFile = walker.indexedModTimeByFile
    }

    // MARK: - Queries (A3)

    public func usr(atFile file: String, line: Int, column: Int) -> String? {
        usrByLocation[IndexLocation(file: Self.normalize(file), line: line, column: column)]
    }

    public func definitionModule(ofUSR usr: String) -> String? {
        definitionModuleByUSR[usr]
    }

    public func occurrences(ofUSR usr: String) -> [IndexLocation] {
        occurrencesByUSR[usr] ?? []
    }

    /// Newest indexing time (epoch seconds) recorded for `file`, or nil if no unit
    /// claims it as a main file (i.e. it wasn't part of the indexed build).
    public func indexedModTime(forFile file: String) -> Int64? {
        indexedModTimeByFile[Self.normalize(file)]
    }

    // MARK: - Symbol → USR mapping (A3)

    /// Map each SwiftProf `Symbol` to its USR by decl position. `Symbol.declOffset`
    /// is the UTF-8 byte offset of the *identifier* token (post-trivia) — exactly
    /// where the index records the definition occurrence. We convert that offset to
    /// line:column with SwiftSyntax and look it up. Symbols with no occurrence at
    /// their decl position map to nothing (their absence is meaningful — A5 gate).
    public func usrBySymbol(in table: SymbolTable) -> [Int: String] {
        var result: [Int: String] = [:]
        var convertersByFile: [ObjectIdentifier: SourceLocationConverter] = [:]
        var pathByFile: [ObjectIdentifier: String] = [:]

        for sym in table.symbols {
            let fileKey = ObjectIdentifier(sym.file)
            let converter: SourceLocationConverter
            if let cached = convertersByFile[fileKey] {
                converter = cached
            } else {
                converter = SourceLocationConverter(
                    fileName: sym.file.url.path, tree: sym.file.syntax)
                convertersByFile[fileKey] = converter
                pathByFile[fileKey] = Self.normalize(sym.file.url.path)
            }
            let path = pathByFile[fileKey]!
            let loc = converter.location(for: AbsolutePosition(utf8Offset: sym.declOffset))
            if let usr = usrByLocation[IndexLocation(file: path, line: loc.line, column: loc.column)] {
                result[sym.id] = usr
            }
        }
        return result
    }

    // MARK: - Helpers

    /// Resolve symlinks + standardize so index-recorded paths and SwiftProf's
    /// `SourceFile.url.path` compare equal (notably `/tmp` → `/private/tmp`).
    static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Defining module parsed from a Swift USR's mangling. Swift USRs are `s:` followed by a
    /// length-prefixed module name (`s:4Lib16WidgetV` → `Lib1`; `s:4Lib16WidgetVACycfc`, the
    /// `Widget.init` USR, → `Lib1` too). This lets a constructor use-site — whose USR is the
    /// init's, not the type's — still name its module. Returns nil for non-Swift (`c:`…) USRs.
    static func swiftModule(ofUSR usr: String) -> String? {
        guard usr.hasPrefix("s:") else { return nil }
        var rest = usr.dropFirst(2)
        let digits = rest.prefix { $0.isNumber }
        guard let len = Int(digits), len > 0 else { return nil }
        rest = rest.dropFirst(digits.count)
        guard rest.count >= len else { return nil }
        return String(rest.prefix(len))
    }

    /// Best-effort defining module of a USR: the index's recorded definition module if known,
    /// else parsed from the Swift mangling.
    public func module(ofUSR usr: String) -> String? {
        definitionModuleByUSR[usr] ?? Self.swiftModule(ofUSR: usr)
    }
}

// MARK: - Index traversal

/// Walks the store with the C `*_apply_f` callbacks. libIndexStore hands a plain
/// `void *` context to each callback, so we pass an unretained pointer to this
/// object and reconstruct it inside the (non-capturing) `@convention(c)` closures.
/// Traversal is strictly synchronous and depth-first — units → record deps →
/// occurrences — so the transient `current*` fields are safe to reuse.
private final class IndexWalker {
    let lib: IndexStoreDylib
    let store: indexstore_t
    let storePath: String

    var usrByLocation: [IndexLocation: String] = [:]
    var occurrencesByUSR: [String: [IndexLocation]] = [:]
    var definitionModuleByUSR: [String: String] = [:]
    var indexedModTimeByFile: [String: Int64] = [:]

    /// Records already drained (a record may be a dependency of several units).
    private var processedRecords: Set<String> = []

    // Transient per-record state set before draining a record's occurrences.
    private var currentModule: String = ""
    private var currentFile: String = ""

    init(lib: IndexStoreDylib, store: indexstore_t, storePath: String) {
        self.lib = lib
        self.store = store
        self.storePath = storePath
    }

    func run() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        _ = lib.storeUnitsApply(store, /*sorted=*/0, ctx) { rawCtx, unitNameRef in
            let walker = Unmanaged<IndexWalker>.fromOpaque(rawCtx!).takeUnretainedValue()
            walker.handleUnit(String(unitNameRef))
            return true // keep iterating units
        }
    }

    private func handleUnit(_ unitName: String) {
        var errorPtr: indexstore_error_t?
        guard let reader = unitName.withCString({
            lib.unitReaderCreate(store, $0, &errorPtr)
        }) else {
            if let e = errorPtr { lib.errorDispose(e) }
            return
        }
        defer { lib.unitReaderDispose(reader) }

        currentModule = String(lib.unitReaderGetModuleName(reader))
        let mainFile = USRIndex.normalize(String(lib.unitReaderGetMainFile(reader)))
        if !mainFile.isEmpty, let unitMTime = unitFileModTime(unitName) {
            indexedModTimeByFile[mainFile] = max(indexedModTimeByFile[mainFile] ?? Int64.min, unitMTime)
        }

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        _ = lib.unitReaderDependenciesApply(reader, ctx) { rawCtx, dep in
            guard let dep else { return true }
            let walker = Unmanaged<IndexWalker>.fromOpaque(rawCtx!).takeUnretainedValue()
            if walker.lib.unitDependencyGetKind(dep) == INDEXSTORE_UNIT_DEPENDENCY_RECORD {
                let recordName = String(walker.lib.unitDependencyGetName(dep))
                let filePath = String(walker.lib.unitDependencyGetFilepath(dep))
                walker.handleRecord(recordName, filePath: filePath)
            }
            return true // keep iterating dependencies
        }
    }

    private func handleRecord(_ recordName: String, filePath: String) {
        guard !recordName.isEmpty, processedRecords.insert(recordName).inserted else { return }
        var errorPtr: indexstore_error_t?
        guard let reader = recordName.withCString({
            lib.recordReaderCreate(store, $0, &errorPtr)
        }) else {
            if let e = errorPtr { lib.errorDispose(e) }
            return
        }
        defer { lib.recordReaderDispose(reader) }

        currentFile = USRIndex.normalize(filePath)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        _ = lib.recordReaderOccurrencesApply(reader, ctx) { rawCtx, occ in
            guard let occ else { return true }
            let walker = Unmanaged<IndexWalker>.fromOpaque(rawCtx!).takeUnretainedValue()
            walker.handleOccurrence(occ)
            return true // keep iterating occurrences
        }
    }

    private func handleOccurrence(_ occ: indexstore_occurrence_t) {
        guard let symbol = lib.occurrenceGetSymbol(occ) else { return }
        let usr = String(lib.symbolGetUSR(symbol))
        guard !usr.isEmpty else { return }

        var line: UInt32 = 0, column: UInt32 = 0
        lib.occurrenceGetLineCol(occ, &line, &column)
        let loc = IndexLocation(file: currentFile, line: Int(line), column: Int(column))

        usrByLocation[loc] = usr
        occurrencesByUSR[usr, default: []].append(loc)

        let roles = lib.occurrenceGetRoles(occ)
        if roles & UInt64(INDEXSTORE_SYMBOL_ROLE_DEFINITION) != 0
            || roles & UInt64(INDEXSTORE_SYMBOL_ROLE_DECLARATION) != 0 {
            // First definition wins; module comes from the owning unit.
            if definitionModuleByUSR[usr] == nil, !currentModule.isEmpty {
                definitionModuleByUSR[usr] = currentModule
            }
        }
    }

    /// Filesystem mtime (epoch seconds) of the unit record on disk, used as the
    /// "index was generated at" timestamp for staleness. Format-version dir is
    /// fixed for this run (asserted == 5 on open).
    private func unitFileModTime(_ unitName: String) -> Int64? {
        let unitPath = (storePath as NSString)
            .appendingPathComponent("v\(USRIndex.expectedFormatVersion)/units/\(unitName)")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: unitPath),
              let date = attrs[.modificationDate] as? Date else { return nil }
        return Int64(date.timeIntervalSince1970)
    }
}

// MARK: - indexstore_string_ref_t → String

extension String {
    /// Copy a libIndexStore {ptr,len} UTF-8 view into a Swift String.
    init(_ ref: indexstore_string_ref_t) {
        if let data = ref.data, ref.length > 0 {
            self = String(decoding: UnsafeRawBufferPointer(start: data, count: ref.length),
                          as: UTF8.self)
        } else {
            self = ""
        }
    }
}
