// swift-tools-version: 6.2
import PackageDescription

// Pure contracts only. The optional provider, RealityKit surface and ordinary Engram app retain
// their macOS 15 deployment floor and do not become dependencies of a contract consumer.
let package = Package(
    name: "EngramGraphContracts",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "EngramGraphContract", targets: ["EngramGraphContract"]),
        .library(name: "EngramHUDContract", targets: ["EngramHUDContract"]),
    ],
    targets: [
        .target(name: "EngramGraphContract"),
        .target(name: "EngramHUDContract", dependencies: ["EngramGraphContract"]),
        .testTarget(name: "EngramGraphContractTests", dependencies: ["EngramGraphContract"]),
        .testTarget(name: "EngramHUDContractTests", dependencies: ["EngramHUDContract", "EngramGraphContract"]),
    ]
)
