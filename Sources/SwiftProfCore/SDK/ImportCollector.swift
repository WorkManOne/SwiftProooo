import SwiftSyntax
import SwiftParser

/// Collects the top-level module names imported by the project's source files. Used to widen the
/// set of SDK `.swiftinterface` files loaded into the `StdlibRegistry`: a framework the project
/// actually imports (e.g. `QuickLook`) must contribute its protocol requirements so a conformer to
/// one of its protocols gets SURGICAL protection (only the real requirements) instead of the
/// fail-closed "unknown external → protect (almost) everything" net that craters coverage.
///
/// `import QuickLook` → "QuickLook"; `import struct Foundation.Date` → "Foundation" (the first path
/// component is the module). Submodule/clang-submodule forms collapse to their root module.
public final class ImportCollector: SyntaxVisitor {
    public private(set) var modules: Set<String> = []

    public init() { super.init(viewMode: .sourceAccurate) }

    public override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        if let first = node.path.first {
            modules.insert(first.name.text)
        }
        return .skipChildren
    }

    /// Union of every module imported by any of `files`.
    public static func modules(in files: [SourceFile]) -> Set<String> {
        var out: Set<String> = []
        for f in files {
            let collector = ImportCollector()
            collector.walk(f.syntax)
            out.formUnion(collector.modules)
        }
        return out
    }

    /// Parse `source` and return its imported module names. Test/convenience entry point.
    public static func modules(inSource source: String) -> Set<String> {
        let collector = ImportCollector()
        collector.walk(Parser.parse(source: source))
        return collector.modules
    }
}
