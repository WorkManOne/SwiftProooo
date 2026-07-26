import Foundation
import CIndexStore

/// Runtime loader for the toolchain's `libIndexStore.dylib` (SwiftShield-style
/// dlopen/dlsym — see Handoff "SwiftShield"). The binary carries NO link-time
/// dependency on the dylib, so it launches on machines without any Xcode; a
/// toolchain is required only when the index layer is actually engaged
/// (`--index-store-path`), and its absence is a clear fail-closed error there.
///
/// Path resolution, in order:
/// 1. `SWIFTPROF_LIBINDEXSTORE` env var — explicit dylib path (CI escape hatch).
/// 2. `xcrun --find swift` → `<toolchain>/usr/lib/libIndexStore.dylib` — the SAME
///    derivation the old build-time link used, now evaluated at runtime, which
///    keeps the "read the index with the toolchain that produced it" contract
///    (see Handoff "Stability & reproducibility") without baking a machine-local
///    rpath into the binary.
///
/// ABI discipline is unchanged: every entry point is dlsym'd into a typedef from
/// `cindexstore.h` whose signature was verified against `nm -gU` of the real
/// dylib. Do NOT add typedefs from guesses — a wrong return type silently
/// corrupts the heap (`indexstore_unit_reader_get_modification_time` stays
/// undeclared for exactly that reason).
public final class IndexStoreDylib {
    public enum LoadError: Error, CustomStringConvertible {
        case libraryNotFound(detail: String)
        case dlopenFailed(path: String, message: String)
        case symbolMissing(name: String, path: String)

        public var description: String {
            switch self {
            case .libraryNotFound(let detail):
                return "libIndexStore.dylib not found — the index layer (--index-store-path) "
                    + "needs an Xcode/Swift toolchain on this machine (\(detail)). "
                    + "Set SWIFTPROF_LIBINDEXSTORE=/path/to/libIndexStore.dylib to override."
            case .dlopenFailed(let path, let message):
                return "could not load \(path): \(message)"
            case .symbolMissing(let name, let path):
                return "symbol \(name) missing from \(path) — toolchain too old/new for this build?"
            }
        }
    }

    // Entry points, dlsym'd once. Names mirror the dylib symbols minus the prefix.
    let formatVersion: fp_indexstore_format_version
    let storeCreate: fp_indexstore_store_create
    let storeDispose: fp_indexstore_store_dispose
    let errorGetDescription: fp_indexstore_error_get_description
    let errorDispose: fp_indexstore_error_dispose
    let storeUnitsApply: fp_indexstore_store_units_apply_f
    let unitReaderCreate: fp_indexstore_unit_reader_create
    let unitReaderDispose: fp_indexstore_unit_reader_dispose
    let unitReaderGetModuleName: fp_indexstore_unit_reader_get_module_name
    let unitReaderGetMainFile: fp_indexstore_unit_reader_get_main_file
    let unitReaderDependenciesApply: fp_indexstore_unit_reader_dependencies_apply_f
    let unitDependencyGetKind: fp_indexstore_unit_dependency_get_kind
    let unitDependencyGetName: fp_indexstore_unit_dependency_get_name
    let unitDependencyGetFilepath: fp_indexstore_unit_dependency_get_filepath
    let recordReaderCreate: fp_indexstore_record_reader_create
    let recordReaderDispose: fp_indexstore_record_reader_dispose
    let recordReaderOccurrencesApply: fp_indexstore_record_reader_occurrences_apply_f
    let occurrenceGetSymbol: fp_indexstore_occurrence_get_symbol
    let occurrenceGetRoles: fp_indexstore_occurrence_get_roles
    let occurrenceGetLineCol: fp_indexstore_occurrence_get_line_col
    let symbolGetUSR: fp_indexstore_symbol_get_usr

    /// Loaded once per process; the handle is never dlclosed (function pointers
    /// stay valid for the process lifetime, matching the old link-time behavior).
    /// Lock-guarded because Swift 6 forbids bare static mutable state.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cached: Result<IndexStoreDylib, Error>?

    public static func shared() throws -> IndexStoreDylib {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached { return try cached.get() }
        let result = Result { try IndexStoreDylib(path: try locate()) }
        cached = result
        return try result.get()
    }

    /// Resolve the dylib path at runtime (env override, then xcrun).
    static func locate() throws -> String {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["SWIFTPROF_LIBINDEXSTORE"],
           !override.isEmpty {
            guard fm.fileExists(atPath: override) else {
                throw LoadError.libraryNotFound(detail: "SWIFTPROF_LIBINDEXSTORE points to a missing file: \(override)")
            }
            return override
        }
        // xcrun --find swift → <toolchain>/usr/bin/swift → <toolchain>/usr/lib/libIndexStore.dylib
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        proc.arguments = ["--find", "swift"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            throw LoadError.libraryNotFound(detail: "xcrun could not be launched: \(error)")
        }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard proc.terminationStatus == 0, !out.isEmpty else {
            throw LoadError.libraryNotFound(detail: "`xcrun --find swift` failed (status \(proc.terminationStatus))")
        }
        let dylib = URL(fileURLWithPath: out)
            .deletingLastPathComponent()   // .../usr/bin
            .deletingLastPathComponent()   // .../usr
            .appendingPathComponent("lib/libIndexStore.dylib").path
        guard fm.fileExists(atPath: dylib) else {
            throw LoadError.libraryNotFound(detail: "no dylib at the toolchain path \(dylib)")
        }
        return dylib
    }

    init(path: String) throws {
        guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else {
            throw LoadError.dlopenFailed(path: path, message: String(cString: dlerror()))
        }
        func sym<T>(_ name: String, as type: T.Type) throws -> T {
            guard let p = dlsym(handle, name) else {
                throw LoadError.symbolMissing(name: name, path: path)
            }
            return unsafeBitCast(p, to: T.self)
        }
        formatVersion = try sym("indexstore_format_version", as: fp_indexstore_format_version.self)
        storeCreate = try sym("indexstore_store_create", as: fp_indexstore_store_create.self)
        storeDispose = try sym("indexstore_store_dispose", as: fp_indexstore_store_dispose.self)
        errorGetDescription = try sym("indexstore_error_get_description", as: fp_indexstore_error_get_description.self)
        errorDispose = try sym("indexstore_error_dispose", as: fp_indexstore_error_dispose.self)
        storeUnitsApply = try sym("indexstore_store_units_apply_f", as: fp_indexstore_store_units_apply_f.self)
        unitReaderCreate = try sym("indexstore_unit_reader_create", as: fp_indexstore_unit_reader_create.self)
        unitReaderDispose = try sym("indexstore_unit_reader_dispose", as: fp_indexstore_unit_reader_dispose.self)
        unitReaderGetModuleName = try sym("indexstore_unit_reader_get_module_name", as: fp_indexstore_unit_reader_get_module_name.self)
        unitReaderGetMainFile = try sym("indexstore_unit_reader_get_main_file", as: fp_indexstore_unit_reader_get_main_file.self)
        unitReaderDependenciesApply = try sym("indexstore_unit_reader_dependencies_apply_f", as: fp_indexstore_unit_reader_dependencies_apply_f.self)
        unitDependencyGetKind = try sym("indexstore_unit_dependency_get_kind", as: fp_indexstore_unit_dependency_get_kind.self)
        unitDependencyGetName = try sym("indexstore_unit_dependency_get_name", as: fp_indexstore_unit_dependency_get_name.self)
        unitDependencyGetFilepath = try sym("indexstore_unit_dependency_get_filepath", as: fp_indexstore_unit_dependency_get_filepath.self)
        recordReaderCreate = try sym("indexstore_record_reader_create", as: fp_indexstore_record_reader_create.self)
        recordReaderDispose = try sym("indexstore_record_reader_dispose", as: fp_indexstore_record_reader_dispose.self)
        recordReaderOccurrencesApply = try sym("indexstore_record_reader_occurrences_apply_f", as: fp_indexstore_record_reader_occurrences_apply_f.self)
        occurrenceGetSymbol = try sym("indexstore_occurrence_get_symbol", as: fp_indexstore_occurrence_get_symbol.self)
        occurrenceGetRoles = try sym("indexstore_occurrence_get_roles", as: fp_indexstore_occurrence_get_roles.self)
        occurrenceGetLineCol = try sym("indexstore_occurrence_get_line_col", as: fp_indexstore_occurrence_get_line_col.self)
        symbolGetUSR = try sym("indexstore_symbol_get_usr", as: fp_indexstore_symbol_get_usr.self)
    }
}
