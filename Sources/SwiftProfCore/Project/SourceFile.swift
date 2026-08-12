import Foundation
import SwiftSyntax
import SwiftParser

public final class SourceFile {
    public let url: URL
    public let module: Module
    public private(set) var contents: String
    private var cachedTree: SourceFileSyntax?

    /// The file's ANALYSIS INPUT: the text the passes parsed, and therefore the text every byte
    /// offset they recorded is a position IN — `Symbol.declOffset`, `UseSiteRecord.offset`,
    /// `Rename.offset`. `contents` moves on to the OUTPUT text the moment `Rewriter` applies the
    /// edits, and a rename changes byte lengths, so from that point on an offset converted against
    /// `contents` names the wrong place: it drifts progressively further down each file and clamps
    /// at EOF once the drift exceeds the remaining text. Anything that turns a recorded offset into
    /// a line:column AFTER the rewrite — today `DecisionReport`, the `--explain` surface — must go
    /// through `analysisLocation(atUTF8Offset:)`, which reads this string and not `contents`.
    ///
    /// Initially the file as loaded from disk. A PREPROCESSING pass that rewrites the input before
    /// the main pipeline re-parses it (`RawValueObfuscationPass`) advances it with
    /// `pinAnalysisInput()`, because from then on its transformed text is what the passes parse.
    public private(set) var analysisContents: String

    /// Built lazily: only a reporting run asks for a location, and only for the files it names.
    private var cachedAnalysisConverter: SourceLocationConverter?

    public init(url: URL, module: Module) throws {
        self.url = url
        self.module = module
        let text = try String(contentsOf: url, encoding: .utf8)
        self.contents = text
        self.analysisContents = text
    }

    public var syntax: SourceFileSyntax {
        if let tree = cachedTree { return tree }
        let tree = Parser.parse(source: contents)
        cachedTree = tree
        return tree
    }

    /// Replace the OUTPUT text. Deliberately leaves `analysisContents` where it is: the offsets the
    /// passes recorded are positions in the text that was parsed, not in the text being written.
    public func updateContents(_ newContents: String) {
        contents = newContents
        cachedTree = nil
    }

    /// Declare the current `contents` to be the analysis input — the text the passes below will
    /// parse and record offsets against. Called by a preprocessing pass that rewrote the source
    /// before the main pipeline runs; without it the report would convert offsets taken from the
    /// transformed text against the pre-transform text.
    public func pinAnalysisInput() {
        analysisContents = contents
        cachedAnalysisConverter = nil
    }

    /// The line:column an offset recorded by an analysis pass names. The ONE way to convert one,
    /// so no caller can reach for a converter over the rewritten `contents` by accident.
    public func analysisLocation(atUTF8Offset offset: Int) -> SourceLocation {
        let converter: SourceLocationConverter
        if let cached = cachedAnalysisConverter {
            converter = cached
        } else {
            // Re-parsing costs one parse per REPORTED file. Holding the pass's own tree instead
            // would keep every file's tree alive for the whole run — the trees `Rewriter` drops
            // today — which is the more expensive half of the trade on a large project.
            converter = SourceLocationConverter(fileName: url.path,
                                                tree: Parser.parse(source: analysisContents))
            cachedAnalysisConverter = converter
        }
        return converter.location(for: AbsolutePosition(utf8Offset: offset))
    }
}
