# Engram graph contracts

This dependency-free Swift package exposes graph snapshots, scope validation, saved camera state, and the graph wire identifiers shared by native integrations. Its minimum macOS version is 14. It contains no renderer, authentication, Lattice, MCP transport, or subprocess helpers.

`EngramGraphContract` uses Foundation. `EngramHUDContract` adds the system CryptoKit framework for deterministic resource identifiers; that product is for Apple-platform consumers. The optional RealityKit surface and native provider remain separate components with their own deployment requirements.

The standalone package and the root Engram products share these source files without moving them. The root exposes `EngramGraphContract` and `EngramHUDContract` on macOS manifest hosts with its declared macOS 15/iOS 18 minimums; this standalone package retains its macOS 14 minimum. No claim is made that every app consumer has adopted these module identities. Consumers must use one shared package instance when exchanging these Swift values. Native bundles continue to exchange their separately versioned Foundation/Objective-C boundary rather than Swift structs.

The twelve existing tests cover bounded snapshots, scope and identity checks, decoding validation, camera state, and deterministic graph selectors. Standalone package checks do not qualify the root exposure; root consumers require qualification through `EngramGraphContractTests` and `EngramHUDContractTests` in the repository root package. Runtime rendering, binary loading, macOS 14 device behavior, and app deployment require separate qualification.
