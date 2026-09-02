import ArgumentParser
import Foundation
import SwiftProfCore

/// `swiftprof deobfuscate` — restore original identifiers in an ERROR LOG produced from
/// obfuscated code. A Unix filter: reads the error text from stdin (or a file), rewrites every
/// known obfuscated token back to its original via `ConversionMap.json` read in reverse, and
/// writes the readable log to stdout (or a file). Everything that is not a known obfuscated
/// identifier passes through unchanged.
struct Deobfuscate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "deobfuscate",
        abstract: "Restore original names in an error log produced from obfuscated code.",
        discussion: """
        Reads error text (compiler / Xcode diagnostics) from stdin or a FILE argument and rewrites \
        any obfuscated identifier back to its original, using ConversionMap.json in reverse. Only \
        whole identifier tokens that are known obfuscated names are touched; the diagnostic words, \
        quotes, line numbers and paths pass through unchanged.

          pbpaste | swiftprof deobfuscate | pbcopy      # via the clipboard on macOS
          xcodebuild ... 2>&1 | swiftprof deobfuscate   # a whole build log
          swiftprof deobfuscate error.txt               # from a file

        Random 32-char names are substituted in place. Short debug names (T0/m0/p0) can collide \
        with real identifiers, so they are annotated instead (the obf is kept, the original \
        appended). --replace / --annotate force either mode.

        Not covered: mangled linker symbols ($s…) do not contain obfuscated names verbatim, and \
        the anonymized --explain reports (-anon.txt) use one-way hashes that no map can reverse.
        """
    )

    @Argument(help: "Error-log file to read. Omit to read from stdin.")
    var inputFile: String?

    @Option(name: .long,
            help: "Path to a ConversionMap.json. Repeatable for multi-module runs. Default: ./out/ConversionMap.json")
    var map: [String] = []

    @Option(name: [.short, .long],
            help: "Write the result to this file instead of stdout.")
    var output: String?

    @Flag(help: "Force output mode. --replace substitutes the original in place; --annotate keeps the obfuscated token and appends the original. Default: replace for random-name maps, annotate for debug-name maps.")
    var mode: RenderMode?

    @Flag(name: .long,
          help: "Refuse to process a debug-name map — only random-name maps are unambiguously safe to substitute.")
    var strict: Bool = false

    enum RenderMode: String, EnumerableFlag {
        case replace
        case annotate
    }

    func run() throws {
        let mapPaths = map.isEmpty ? ["./out/ConversionMap.json"] : map
        for path in mapPaths where !FileManager.default.fileExists(atPath: path) {
            throw ValidationError("""
            conversion map not found: \(path)
            Pass --map <path> (repeatable), or run from a directory that has ./out/ConversionMap.json.
            """)
        }

        let deob: Deobfuscator
        do {
            deob = try Deobfuscator.load(mapPaths: mapPaths)
        } catch {
            throw ValidationError(String(describing: error))
        }

        if deob.isEmpty {
            warn("the conversion map is empty; input will pass through unchanged")
        }
        if strict && deob.style != .random {
            throw ValidationError("""
            --strict refuses a non-random map (style: \(deob.style)); short debug names collide \
            with real identifiers. Rerun without --strict to annotate them instead.
            """)
        }

        let effective: Deobfuscator.Mode
        switch mode {
        case .replace:  effective = .replace
        case .annotate: effective = .annotate
        case nil:       effective = deob.defaultMode
        }
        if mode == nil, deob.style == .debug || deob.style == .mixed {
            warn("map uses short debug names (\(deob.style)); annotating rather than replacing "
                 + "(a token like 'p0' may be a real identifier). Use --replace to force substitution.")
        }

        let input: String
        if let inputFile {
            input = try String(contentsOfFile: inputFile, encoding: .utf8)
        } else {
            input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        }

        let result = deob.deobfuscate(input, mode: effective)

        if let output {
            try result.write(toFile: output, atomically: true, encoding: .utf8)
        } else {
            FileHandle.standardOutput.write(Data(result.utf8))
        }
    }

    private func warn(_ message: String) {
        FileHandle.standardError.write(Data("swiftprof deobfuscate: warning: \(message)\n".utf8))
    }
}
