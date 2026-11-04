# Engram graph contracts

This dependency-free Swift package exposes graph snapshots, scope validation, saved camera state, and the graph wire identifiers shared by native integrations. Its minimum macOS version is 14. It contains no renderer, authentication, Lattice, MCP transport, or subprocess helpers.

`EngramGraphContract` uses Foundation. `EngramHUDContract` adds the system CryptoKit framework for deterministic resource identifiers; that product is for Apple-platform consumers. The optional RealityKit surface and native provider remain separate components with their own deployment requirements.

The package preserves the implementations used by the HUD connector candidate. Publishing it does not change Engram's root package, move its existing targets, or claim that every app consumer has adopted these module identities. Consumers must use one shared package instance when exchanging these Swift values. Native bundles continue to exchange their separately versioned Foundation/Objective-C boundary rather than Swift structs.

The twelve existing tests cover bounded snapshots, scope and identity checks, decoding validation, camera state, and deterministic graph selectors. The native validation workflow runs them with `swift test --package-path Packages/EngramGraphContracts`. Runtime rendering, binary loading, macOS 14 device behavior, and app deployment require separate qualification.
