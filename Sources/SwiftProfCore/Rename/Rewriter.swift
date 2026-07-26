import Foundation

/// Applies Rename edits to SourceFile contents.
/// Edits are applied in descending offset order so earlier offsets remain valid.
public final class Rewriter {
    public let logger: Logger
    public init(logger: Logger) { self.logger = logger }

    public func apply(_ renames: [Rename]) {
        let byFile = Dictionary(grouping: renames, by: { ObjectIdentifier($0.file) })
        for (_, edits) in byFile {
            guard let file = edits.first?.file else { continue }
            var bytes = Array(file.contents.utf8)
            let ordered = edits.sorted { $0.offset > $1.offset }
            // Edits are applied in descending offset order so earlier offsets stay valid. Because a
            // replacement changes the byte count, two edits whose ranges OVERLAP would corrupt the
            // text: the second, applied over already-shifted bytes, eats trailing characters (e.g. a
            // keypath token accidentally emitted twice would consume the following `))`). Guard with
            // a frontier = the lowest offset consumed so far; an edit is applied only if it ends at or
            // before it. A true duplicate is dropped (the first already did the rename); a zero-length
            // insertion sitting exactly at a prior edit's start (the `if let x` → `= <obf>` expansion)
            // is adjacent, not overlapping, so `<=` keeps it.
            var frontier = bytes.count
            for edit in ordered {
                guard edit.offset >= 0, edit.length >= 0, edit.offset + edit.length <= bytes.count else {
                    logger.log("skip out-of-range edit at \(edit.offset) (\(edit.original))", verbose: true)
                    continue
                }
                guard edit.offset + edit.length <= frontier else {
                    logger.log("skip overlapping edit at \(edit.offset) len \(edit.length) (\(edit.original) -> \(edit.replacement))", verbose: true)
                    continue
                }
                let replBytes = Array(edit.replacement.utf8)
                bytes.replaceSubrange(edit.offset..<(edit.offset + edit.length), with: replBytes)
                frontier = edit.offset
            }
            if let newStr = String(bytes: bytes, encoding: .utf8) {
                file.updateContents(newStr)
            } else {
                logger.log("WARNING: rewrite produced invalid UTF-8 for \(file.url.path)")
            }
        }
    }

    public func writeToDisk(_ files: [SourceFile]) throws {
        for file in files where file.module.writable {
            try file.contents.write(to: file.url, atomically: true, encoding: .utf8)
        }
    }
}
