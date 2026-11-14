// swift-tools-version: 6.2

import PackageDescription
import Foundation

let bridgingHeader = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Sources/EngramVisualizer/EngramVisualizer-Bridging-Header.h")
    .path

var engramMetalShaders: PackageDescription.Target {
    #if SWIFT_PACKAGE_TEST
    .target(
        name: "EngramMetalShaders",
        resources: [.process("Shaders")],
        plugins: [.plugin(name: "CompileMetalShaders")]
    )
    #else
    .target(
        name: "EngramMetalShaders",
        resources: [.process("Shaders")]
    )
    #endif
}

let package = Package(
    name: "Engram",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "EngramKit", targets: ["EngramKit"]),
        .library(name: "EngramLattice", targets: ["EngramLattice"]),
        .library(name: "EngramCoreML", targets: ["EngramCoreML"]),
        .library(name: "EngramGraphUI", targets: ["EngramGraphUI"]),
        .library(name: "EngramModels", targets: ["EngramModels"]),
        .library(name: "EngramMemoryCore", targets: ["EngramMemoryCore"]),
        .library(name: "EngramMemoryContract", targets: ["EngramMemoryContract"]),
        .library(name: "EngramFoundationModels", targets: ["EngramFoundationModels"]),
        .library(name: "EngramSceneKit", targets: ["EngramSceneKit"]),
        .library(name: "EngramMetalShaders", targets: ["EngramMetalShaders"]),
        .library(name: "CEngramSceneTypes", targets: ["CEngramSceneTypes"]),
        .library(name: "EngramRealityKit", targets: ["EngramRealityKit"]),
    ],
    dependencies: [
        // Preserve the Codex client-capability decoding fix in the owned SDK.
        .package(url: "https://github.com/jsflax/swift-sdk.git", exact: "0.13.1"),
        // Published protected legacy attachments and shared Linux notification listeners.
        .package(url: "https://github.com/jsflax/lattice.git", exact: "3.1.0"),
        .package(url: "https://github.com/jsflax/LatticeCore.git", from: "3.1.1"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.3"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.0.0"),
        .package(url: "https://github.com/google/GoogleSignIn-iOS.git", from: "7.0.0"),
    ],
    targets: [
        // C target exposing SharedTypes.h (GPU struct definitions) to Swift modules.
        // Keep this header in sync with Sources/EngramVisualizer/Metal/SharedTypes.h.
        .target(
            name: "CEngramSceneTypes"
        ),
        // Pure-logic library for scene frame building — no Metal, no @MainActor.
        .target(
            name: "EngramSceneKit",
            dependencies: ["CEngramSceneTypes"],
            swiftSettings: [
                .interoperabilityMode(.Cxx),
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("Accelerate"),
            ]
        ),
        // Metal shader library. Plugin compiles .metal → metallib at build time.
        engramMetalShaders,
        // Platform-portable memory contract: the MemoryService protocol, its
        // DTOs, Principal/identity, shared ranking + fencing + content-word
        // logic, and the Embedder seam. NO Apple-only frameworks, NO Lattice,
        // NO MCP — this module MUST build on Linux (it is what engram-server
        // consumes for the agents deployment). Apple conformances (CoreML
        // embedder and NLTagger adapters) stay Apple-only; storage lives in EngramLattice.
        .target(
            name: "EngramMemoryCore"
        ),
        .testTarget(
            name: "EngramMemoryCoreTests",
            dependencies: ["EngramMemoryCore", "EngramProcessGuardFixture"]
        ),
        .executableTarget(
            name: "EngramProcessGuardFixture",
            dependencies: ["EngramMemoryCore"],
            path: "Tests/Fixtures/ProcessGuard"
        ),
        // The MemoryService contract: one executable spec both backends must
        // pass — Lattice in-proc (EngramTests) and Postgres (engram-server's
        // suite, increment 5). A LIBRARY, not a test target, because test
        // targets aren't importable across packages; each repo's test target
        // wraps `MemoryServiceContract.run` in its own @Test. Linux-clean
        // like EngramMemoryCore (no Testing import — checks report typed
        // violations).
        .target(
            name: "EngramMemoryContract",
            dependencies: ["EngramMemoryCore"]
        ),
        .target(
            name: "EngramModels",
            dependencies: [
                .product(name: "Lattice", package: "lattice"),
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx),
            ]
        ),
        .target(
            name: "EngramKit",
            dependencies: [
                "EngramLattice",
                "EngramCoreML",
                "EngramModels",
                "EngramMemoryCore",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Lattice", package: "lattice"),
            ],
            resources: [
                .copy("Resources/RecallGateClassifier.mlmodelc"),
                .copy("Resources/session-learner.md"),
                .copy("Resources/memory-maintenance.md"),
                .copy("Resources/sync-reconciliation.md"),
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx),
            ],
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("NaturalLanguage"),
            ]
        ),
        .executableTarget(
            name: "Engram",
            dependencies: [
                "EngramKit",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Lattice", package: "lattice"),
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx),
            ]
        ),
        .executableTarget(
            name: "EngramVisualizer",
            dependencies: [
                "EngramKit",
                "EngramFoundationModels",
                "EngramSceneKit",
                "EngramMetalShaders",
                "CEngramSceneTypes",
                "EngramRealityKit",
                .product(name: "Lattice", package: "lattice"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "GoogleSignIn", package: "GoogleSignIn-iOS"),
                .product(name: "GoogleSignInSwift", package: "GoogleSignIn-iOS"),
            ],
            exclude: [
                "Info.plist",
            ],
            resources: [
                .copy("Resources/under_construction.png"),
                .copy("Resources/mascot_mesh.bin"),
                .copy("Resources/mascot_basecolor.jpg"),
                .copy("Resources/mascot_metalrough.png"),
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .unsafeFlags(["-import-objc-header", bridgingHeader]),
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("RealityKit"),
            ]
        ),
        // Builds on BOTH platforms: macOS gets the local lattice backend
        // (EngramKit — Apple-only by B6); Linux builds only the portable
        // closure (EngramMemoryCore) and runs the REMOTE backend against
        // engram-server. Cxx interop rides the Apple-only deps.
        .executableTarget(
            name: "EngramHooks",
            dependencies: [
                "EngramMemoryCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .target(name: "EngramKit", condition: .when(platforms: [.macOS])),
                .product(name: "Lattice", package: "lattice",
                         condition: .when(platforms: [.macOS])),
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx, .when(platforms: [.macOS])),
            ]
        ),
        .executableTarget(
            name: "EngramDaemon",
            dependencies: [
                "EngramKit",
                .product(name: "Lattice", package: "lattice"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx),
            ]
        ),
        .target(
            name: "EngramFoundationModels",
            dependencies: [
                "EngramKit",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx),
            ]
        ),
        .target(
            name: "EngramRealityKit",
            dependencies: ["EngramSceneKit", "CEngramSceneTypes"],
            resources: [.process("Shaders"), .copy("Resources/mascot.usdz")],
            swiftSettings: [.interoperabilityMode(.Cxx)],
            linkerSettings: [
                .linkedFramework("RealityKit"),
                .linkedFramework("Metal"),
            ]
        ),
        .executableTarget(
            name: "EngramPreview",
            dependencies: [
                "EngramRealityKit", "EngramSceneKit", "EngramMetalShaders",
                "EngramKit",
                .product(name: "Lattice", package: "lattice"),
            ],
            resources: [.copy("Resources/mascot.usdz")],
            swiftSettings: [.interoperabilityMode(.Cxx)],
            linkerSettings: [.linkedFramework("RealityKit")]
        ),
        .testTarget(
            name: "EngramRealityKitTests",
            dependencies: ["EngramRealityKit", "EngramSceneKit", "EngramMetalShaders", "EngramTestSupport"],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
        .testTarget(
            name: "EngramTests",
            dependencies: [
                "EngramKit",
                "EngramLattice",
                "EngramCoreML",
                "EngramTestSupport",
                "EngramMemoryCore",
                "EngramMemoryContract",
                .product(name: "Lattice", package: "lattice"),
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx),
            ]
        ),
        .testTarget(
            name: "EngramSceneKitTests",
            dependencies: ["EngramSceneKit", "EngramMetalShaders"],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
        .testTarget(
            name: "EngramVisualizerTests",
            dependencies: ["EngramSceneKit", "EngramMetalShaders"],
            swiftSettings: [
                .interoperabilityMode(.Cxx),
            ]
        ),
        .testTarget(
            name: "EngramFoundationModelsTests",
            dependencies: [
                "EngramFoundationModels",
                "EngramKit",
                "EngramMemoryCore",
                .product(name: "Lattice", package: "lattice"),
            ],
            resources: [
                .copy("Resources/engram_memory.fmadapter"),
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx),
            ]
        ),
        .plugin(
            name: "CompileMetalShaders",
            capability: .buildTool()
        ),
    ]
)

// Reusable storage and embedding products share the desktop's model contracts.
// Keep the desktop executables and their existing test graph at the root.
package.targets.append(contentsOf: [
    .target(name: "EngramLattice", dependencies: [
        "EngramModels", "EngramMemoryCore",
        .product(name: "MCP", package: "swift-sdk"),
        .product(name: "Lattice", package: "lattice"),
    ], swiftSettings: [.interoperabilityMode(.Cxx)],
        linkerSettings: [.linkedFramework("NaturalLanguage", .when(platforms: [.macOS, .iOS]))]),
    .target(name: "EngramCoreML", dependencies: [
        "EngramMemoryCore",
        .product(name: "Tokenizers", package: "swift-transformers"),
        .product(name: "Hub", package: "swift-transformers"),
    ], resources: [
        .copy("Resources/paraphrase-MiniLM-L6-v2_Embedding.mlmodelc"),
        .copy("Resources/paraphrase-MiniLM-L6-v2_tokenizer"),
        .copy("Resources/NOTICE.txt"),
        .copy("Resources/Apache-2.0.txt"),
        .copy("Resources/SwiftLM-MIT.txt"),
    ]),
    .target(name: "EngramGraphUI", dependencies: [
        "EngramRealityKit", "EngramSceneKit", "EngramMetalShaders",
    ], swiftSettings: [.interoperabilityMode(.Cxx)]),
    .testTarget(name: "EngramLatticeTests", dependencies: [
        "EngramLattice", "EngramMemoryContract", "EngramTestSupport",
    ], swiftSettings: [.interoperabilityMode(.Cxx)]),
    .testTarget(name: "EngramCoreMLTests", dependencies: [
        "EngramCoreML", "EngramLattice", "EngramTestSupport",
    ], swiftSettings: [.interoperabilityMode(.Cxx)]),
    .testTarget(name: "EngramCoreMLParityTests", dependencies: ["EngramCoreML", "EngramKit"],
        swiftSettings: [.interoperabilityMode(.Cxx)]),
    .testTarget(name: "EngramGraphUITests", dependencies: ["EngramGraphUI", "EngramTestSupport"],
        swiftSettings: [.interoperabilityMode(.Cxx)]),
    .target(name: "EngramTestSupport", path: "Tests/EngramTestSupport"),
    .testTarget(name: "EngramTestSupportTests", dependencies: ["EngramTestSupport"],
        path: "Tests/EngramTestSupportTests"),
])

#if os(Linux)
package.dependencies.append(.package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"))
package.targets.append(.systemLibrary(name: "CEngramLedgerSQLite",
    path: "SystemLibraries/CEngramLedgerSQLite", pkgConfig: "sqlite3",
    providers: [.apt(["libsqlite3-dev"]), .brew(["sqlite"])]))
if let tests = package.targets.first(where: { $0.name == "EngramLatticeTests" }) {
    tests.dependencies.append(.target(name: "CEngramLedgerSQLite"))
}
if let storage = package.targets.first(where: { $0.name == "EngramLattice" }) {
    storage.dependencies.append(.product(name: "Crypto", package: "swift-crypto"))
    storage.dependencies.append(.target(name: "CEngramLedgerSQLite"))
}
#endif

// Pure graph contracts retain their shared implementation and Apple-hosted exposure.
#if os(macOS)
package.products.append(contentsOf: [
    .library(name: "EngramGraphContract", targets: ["EngramGraphContract"]),
    .library(name: "EngramHUDContract", targets: ["EngramHUDContract"]),
])
package.targets.append(contentsOf: [
    .target(name: "EngramGraphContract",
        path: "Packages/EngramGraphContracts/Sources/EngramGraphContract"),
    .target(name: "EngramHUDContract", dependencies: ["EngramGraphContract"],
        path: "Packages/EngramGraphContracts/Sources/EngramHUDContract"),
    .testTarget(name: "EngramGraphContractTests", dependencies: ["EngramGraphContract"],
        path: "Packages/EngramGraphContracts/Tests/EngramGraphContractTests"),
    .testTarget(name: "EngramHUDContractTests", dependencies: ["EngramHUDContract", "EngramGraphContract"],
        path: "Packages/EngramGraphContracts/Tests/EngramHUDContractTests"),
])
#endif
