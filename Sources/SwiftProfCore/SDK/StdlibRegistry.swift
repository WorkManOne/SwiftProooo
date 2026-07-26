import Foundation

/// Merges protocol requirements discovered by parsing real `.swiftinterface` files with a
/// curated hardcoded fallback. The loaded data is authoritative when present; the hardcoded
/// fallback covers cases the parser couldn't process (or when SDK introspection is disabled).
public final class StdlibRegistry {
    /// protocol name → set of required member names
    private var requirementsByProtocol: [String: Set<String>] = [:]
    /// All publicly-declared member names across all loaded interfaces. Used as a shielding
    /// set during rollback — when a name from this set appears in user code, it's assumed to
    /// be a legitimate call to an Apple API (`view.cornerRadius`, `Color.primary`, etc.) and
    /// should NOT trigger rollback of a similarly-named local symbol.
    public private(set) var allKnownMemberNames: Set<String> = []
    public private(set) var loadedModules: [String] = []

    public init() {}

    /// Seed with the hardcoded baseline. Loaded data later overlays / extends.
    public func seedWithHardcoded() {
        for (name, members) in HardcodedFallback.requirements {
            requirementsByProtocol[name] = members
            allKnownMemberNames.formUnion(members)
        }
        // Add common Apple ObjC API names — they aren't in .swiftinterface but are widely
        // used at call sites and would otherwise trigger rollback false-positives.
        allKnownMemberNames.formUnion(CommonAppleAPINames.names)
    }

    public func merge(_ interfaces: [LoadedInterface]) {
        for iface in interfaces {
            for (protoName, members) in iface.protocols {
                requirementsByProtocol[protoName] = requirementsByProtocol[protoName, default: []].union(members)
            }
            allKnownMemberNames.formUnion(iface.allMemberNames)
            loadedModules.append(iface.module)
        }
    }

    public func requirements(for protocolName: String) -> Set<String>? {
        requirementsByProtocol[protocolName]
    }

    public var totalProtocols: Int { requirementsByProtocol.count }
}

/// Minimal hardcoded fallback for offline / SDK-less runs. Compared to the previous
/// StdlibProtocolRequirements catalog this is intentionally short — anything more comprehensive
/// should come from the actual `.swiftinterface` parsing path.
enum HardcodedFallback {
    static let requirements: [String: Set<String>] = [
        "View":          ["body"],
        "Shape":         ["path", "sizeThatFits"],
        "ViewModifier":  ["body"],
        "Identifiable":  ["id", "ID"],
        // Equatable/Comparable's ONLY requirements are operators (`==`, `<`) — those are protected
        // by Protector.runOperatorProtection (by name SHAPE), NOT here. The keys are kept (value =
        // the NON-operator requirements, i.e. none) purely so a local protocol inheriting them
        // classifies as KNOWN external → surgical protection, instead of UNKNOWN → protect-all
        // (coverage crater). Listing the operators here too would be redundant double-protection.
        "Equatable":     [],
        "Comparable":    [],
        "Hashable":      ["hash", "hashValue"],
        "Codable":       ["init", "encode", "CodingKeys"],
        "Decodable":     ["init", "CodingKeys"],
        "Encodable":     ["encode", "CodingKeys"],
        "RawRepresentable": ["rawValue", "init", "RawValue"],
        "CaseIterable":  ["allCases", "AllCases"],
        "Error":         [],
        "CustomStringConvertible":      ["description"],
        "CustomDebugStringConvertible": ["debugDescription"],
        "ObservableObject": ["objectWillChange"],
        "UIViewRepresentable":           ["makeUIView", "updateUIView", "makeCoordinator", "Coordinator", "UIViewType"],
        "UIViewControllerRepresentable": ["makeUIViewController", "updateUIViewController", "makeCoordinator", "Coordinator", "UIViewControllerType"],
        "NSViewRepresentable":           ["makeNSView", "updateNSView", "makeCoordinator", "Coordinator", "NSViewType"],
        "NSViewControllerRepresentable": ["makeNSViewController", "updateNSViewController", "makeCoordinator", "Coordinator", "NSViewControllerType"],
        // Objective-C frameworks ship NO `.swiftinterface` (their API is clang headers + apinotes),
        // so SDK introspection can't learn their protocol requirements — curate the common ones here.
        // Witnesses of these @objc protocols must keep their names; everything ELSE on the conformer
        // (e.g. unrelated local-protocol methods, private helpers) stays obfuscatable. Without an
        // entry the protocol is "unknown external" → near-total protect-all on every conformer.
        "QLPreviewControllerDataSource":  ["numberOfPreviewItems", "previewController"],
        "QLPreviewControllerDelegate":    ["previewController"],
        "Sequence":      ["makeIterator", "Iterator", "Element"],
        "Collection":    ["startIndex", "endIndex", "subscript", "index", "Element", "Index"],
        "IteratorProtocol": ["next", "Element"],
    ]
}
