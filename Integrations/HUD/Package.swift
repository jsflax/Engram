// swift-tools-version: 6.2
import PackageDescription

// Optional integration: the ordinary Engram app/package does not depend on HUD.
let package = Package(
    name: "EngramHUDAdapter", platforms: [.macOS(.v15)],
    products: [.library(name: "EngramHUDAdapter", targets: ["EngramHUDAdapter"])],
    dependencies: [
        .package(name: "Engram", path: "../.."),
        .package(path: "../../Packages/EngramGraphContracts"),
        .package(path: "../../../hud/Packages/HUDNativeViewABI"),
    ],
    targets: [
        .target(name: "EngramHUDAdapter", dependencies: [
            .product(name: "EngramHUDContract", package: "EngramGraphContracts"),
            .product(name: "EngramGraphSurface", package: "Engram"),
            .product(name: "EngramMemoryCore", package: "Engram"),
            .product(name: "HUDNativeViewABI", package: "HUDNativeViewABI"),
        ], swiftSettings: [.interoperabilityMode(.Cxx)]),
        .testTarget(name: "EngramHUDAdapterTests", dependencies: ["EngramHUDAdapter"],
                    swiftSettings: [.interoperabilityMode(.Cxx)]),
    ]
)
