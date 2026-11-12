// swift-tools-version: 6.2
import PackageDescription
import Foundation

let latticeDependency: Package.Dependency = .package(
    url: "https://github.com/jsflax/lattice.git",
    from: "3.0.0")

let package = Package(
    name: "Engram",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "EngramLattice", targets: ["EngramLattice"]),
        .library(name: "EngramMemoryCore", targets: ["EngramMemoryCore"]),
        .library(name: "EngramModels", targets: ["EngramModels"]),
        .library(name: "EngramMemoryContract", targets: ["EngramMemoryContract"]),
    ],
    dependencies: [
        latticeDependency,
        // Compatible read-only legacy attachments require the 3.1.0 core.
        .package(url: "https://github.com/jsflax/LatticeCore.git", from: "3.1.0"),
        .package(url: "https://github.com/jsflax/swift-sdk.git", exact: "0.13.1"),
    ],
    targets: [
        .target(name: "EngramMemoryCore"),
        .target(name: "EngramMemoryContract", dependencies: ["EngramMemoryCore"]),
        .target(name: "EngramModels",
                dependencies: [.product(name: "Lattice", package: "lattice")],
                swiftSettings: [.interoperabilityMode(.Cxx)]),
        .target(name: "EngramLattice",
                dependencies: ["EngramModels", "EngramMemoryCore",
                               .product(name: "Lattice", package: "lattice"),
                               .product(name: "MCP", package: "swift-sdk")],
                swiftSettings: [.interoperabilityMode(.Cxx)],
                linkerSettings: [.linkedFramework("NaturalLanguage", .when(platforms: [.macOS, .iOS]))]),
        .testTarget(name: "EngramMemoryCoreTests", dependencies: ["EngramMemoryCore"]),
        .testTarget(name: "EngramLatticeTests", dependencies: ["EngramLattice", "EngramMemoryContract"],
                    swiftSettings: [.interoperabilityMode(.Cxx)]),
    ]
)


// Keep the existing remote hook executable available on Linux. macOS desktop
// hooks and the visualizer are built from Desktop/Package.swift.
#if os(Linux)
package.dependencies.append(.package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"))
package.products.append(.executable(name: "EngramHooks", targets: ["EngramHooks"]))
package.targets.append(.executableTarget(name: "EngramHooks", dependencies: [
    "EngramMemoryCore", .product(name: "ArgumentParser", package: "swift-argument-parser"),
]))
#endif

// Native semantic memory uses the same bundled MiniLM assets as desktop Engram.
// Only Apple products resolve the tokenizer dependency; Linux remains portable.
#if !os(Linux)
package.dependencies.append(.package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.3"))
package.products.append(.library(name: "EngramCoreML", targets: ["EngramCoreML"]))
package.targets.append(.target(name: "EngramCoreML", dependencies: [
    "EngramMemoryCore",
    .product(name: "Tokenizers", package: "swift-transformers"),
    .product(name: "Hub", package: "swift-transformers"),
], resources: [.copy("Resources/paraphrase-MiniLM-L6-v2_Embedding.mlmodelc"),
               .copy("Resources/paraphrase-MiniLM-L6-v2_tokenizer"),
               .copy("Resources/NOTICE.txt"), .copy("Resources/Apache-2.0.txt"),
               .copy("Resources/SwiftLM-MIT.txt")]))
package.targets.append(.testTarget(name: "EngramCoreMLTests",
    dependencies: ["EngramCoreML", "EngramLattice"],
    swiftSettings: [.interoperabilityMode(.Cxx)]))
#endif

// SHA-256 transfer seals use CryptoKit on Apple and Swift Crypto on Linux.
#if os(Linux)
package.dependencies.append(.package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"))
if let target = package.targets.first(where: { $0.name == "EngramLattice" }) {
    target.dependencies.append(.product(name: "Crypto", package: "swift-crypto"))
}
// Share the portable fixture's system SQLite module with the root test target.
if let target = package.targets.first(where: { $0.name == "EngramLatticeTests" }) {
    target.dependencies.append(.target(name: "CEngramLedgerSQLite"))
}
package.targets.append(.systemLibrary(name: "CEngramLedgerSQLite",
    path: "Portable/SystemLibraries/CEngramLedgerSQLite", pkgConfig: "sqlite3",
    providers: [.apt(["libsqlite3-dev"])]))
#endif

// The same renderer sources/resources as Engram Desktop. Evaluated on macOS for
// both native Mac and iOS destinations; never enters the portable Linux graph.
#if os(macOS)
for name in ["CEngramSceneTypes", "EngramSceneKit", "EngramMetalShaders", "EngramRealityKit", "EngramGraphUI"] {
    package.products.append(.library(name: name, targets: [name]))
}
package.targets.append(contentsOf: [
    .target(name: "CEngramSceneTypes"),
    .target(name: "EngramSceneKit", dependencies: ["CEngramSceneTypes"],
            swiftSettings: [.interoperabilityMode(.Cxx)],
            linkerSettings: [.linkedFramework("Metal"), .linkedFramework("Accelerate")]),
    .target(name: "EngramMetalShaders", resources: [.process("Shaders")]),
    .target(name: "EngramRealityKit", dependencies: ["EngramSceneKit", "CEngramSceneTypes"],
            resources: [.process("Shaders"), .copy("Resources/mascot.usdz")],
            swiftSettings: [.interoperabilityMode(.Cxx)],
            linkerSettings: [.linkedFramework("RealityKit"), .linkedFramework("Metal")]),
    .target(name: "EngramGraphUI", dependencies: ["EngramRealityKit", "EngramSceneKit", "EngramMetalShaders"],
            swiftSettings: [.interoperabilityMode(.Cxx)]),
    .testTarget(name: "EngramRealityKitTests", dependencies: ["EngramRealityKit", "EngramSceneKit", "EngramMetalShaders"],
                swiftSettings: [.interoperabilityMode(.Cxx)]),
    .testTarget(name: "EngramGraphUITests", dependencies: ["EngramGraphUI"],
                swiftSettings: [.interoperabilityMode(.Cxx)]),
])
#endif
