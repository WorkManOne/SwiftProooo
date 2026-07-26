// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftProf",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "swiftprof", targets: ["swiftprof"]),
        .library(name: "SwiftProfCore", targets: ["SwiftProfCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "601.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
    ],
    targets: [
        // Hand-declared C shim over the toolchain's libIndexStore.dylib (header not
        // shipped): TYPES ONLY (function-pointer typedefs). Nothing is linked at
        // build time — IndexStoreDylib.swift dlopens the dylib at first index use,
        // resolving its path via xcrun at RUNTIME, so the produced binary is fully
        // portable (launches on machines without Xcode).
        .target(name: "CIndexStore"),
        .target(
            name: "SwiftProfCore",
            dependencies: [
                "CIndexStore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                // ConfigFile.swift (swiftprof.yaml). Lives in core (not the CLI target)
                // so the existing test target covers it.
                .product(name: "Yams", package: "Yams"),
            ]
        ),
        .executableTarget(
            name: "swiftprof",
            dependencies: [
                "SwiftProfCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "SwiftProfCoreTests",
            dependencies: ["SwiftProfCore"]
        ),
    ]
)
