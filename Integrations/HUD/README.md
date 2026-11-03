# Engram native project graph provider

This optional integration reuses `EngramGraphSurface`, `EngramGraphSession`, RealityKit, the existing camera/input bridge, and scoped force layout. The ordinary Engram app has no HUD dependency. It contains no authentication, network client, Lattice handle, credential, effect executor, or alternative graph renderer.

The Swift package is the testable in-process adapter. `project.yml` builds those same Swift sources plus `Bundle/Principal.m` into a separate macOS 15 `MH_BUNDLE` with `NSPrincipalClass=EngramHUDProvider`. It does not link the adapter package again. Only the standalone Objective-C `HUDNativeViewABI` protocols, Foundation values, and AppKit controllers/views cross the binary boundary. Swift package types remain private to each executable's side.

## Wire version one

The externally admitted ABI descriptor declares provider `engram`, view `projectGraph`, snapshot schema `io.jsflax.engram.project-graph` version 1, and state schema `io.jsflax.engram.project-graph-state` version 1. It declares no effects.

Every snapshot has the ABI envelope `schemaIdentifier`, `schemaVersion`, monotonically increasing `revision`, and `values`. Values contain exactly:

- `scope`: `workspaceID`, `project`, and canonical sorted `topics` (empty means every topic).
- `phase`: `loading`, `ready`, or `failed`.
- `graphJSON`: only for `ready`, immutable binary JSON encoding of `EngramGraphSnapshot`.

The context's workspace must match the scope. Its resource identifier is `EngramHUDGraphWire.resourceIdentifier(for:)`, a domain-separated SHA-256 of length-prefixed workspace/project/sorted-topic UTF-8 strings. This selector does **not** authorize access. The trusted Connect host must authorize the exact export before handing it to the provider, retain the instance lease, and compare every exact optional context field. The instance captures the canonical context once and checks the original context against it before every operation, asynchronous publication, and state callback.

`applySnapshot` success means **validated-envelope admission**, not completed graph decoding. Heavy JSON decoding runs on one actor, with at most one active decode and one replaceable successor. No decoding starts while suspended/hidden. Graph scope is revalidated after decoding. The envelope revision fences all phases; the graph's own revision must independently increase beyond the last valid graph. A loading/failed envelope or failed/stale/mismatched decoded graph preserves the last valid graph and shows its loading/failure status. A host retry needs a newer envelope revision. Revocation/invalidation is terminal and clears the graph. A nil initial snapshot displays a waiting state without constructing a graph session or widening scope.

**The native transfer limit is 4 MiB of graph JSON**, below the portable export DTO's 8 MiB bound. Oversized snapshots fail explicitly; the provider never truncates them. A future trusted host/export negotiation must select a compatible export budget. This is not a parity-complete 8 MiB transport.

Saved state has the declared ABI envelope and `values={scope,camera}`. Camera is the existing bounded 2 KiB `EngramGraphViewState` JSON object, containing selection and camera scalars only. It has no filters, credentials, memory content, or paths. The host keys it by the exact document lifetime/instance and owns persistence. The provider signals `viewStateDidChangeForContext`; it never writes a document/store. State capture validates current context and scope again.

Instances start suspended. Visibility gates Engram's frame subscription, force preparation, input and gestures. Primary-input focus is unsupported. Content focus returns the directly retained Engram container only when mounted/visible/current; the host still checks exact subtree/window membership and owns activation and `makeFirstResponder`. Appearance version 1 maps scheme, semantic text/base/accent colors, headline/caption font tokens and card radius to the existing surface. Presentation remains an unframed graph; the host chooses panel or embedded containment. Existing direct Engram callers retain their dark defaults.

## Source and dependency delivery

The canonical manifests use repository-relative Engram and shared-contract paths. The only HUD dependency is the standalone, dependency-free `HUDNativeViewABI` package at `../../../hud/Packages/HUDNativeViewABI`. For that path to resolve, retain a reviewed HUD checkout beside the Engram checkout. Do not substitute the HUD root repository URL: its root package does not expose the nested ABI product.

This runtime delivery requires publication of the exact ABI 1.2 header and implementation used by the qualified provider. The older HUD checkout ABI is not equivalent. No published HUD revision containing those exact bytes has been established yet; an immutable companion revision and its source checks must be bound before clean-source qualification or release. The full HUD connector SDK and host implementations are not provider dependencies. This publication prerequisite does not authorize copying credentials, stores, host packages, or scratch-built binaries into Engram.

## Qualification boundaries

The retained macOS provider qualification compiled the real graph, renderer, adapter and ABI sources through a local test projection. Earlier graph coverage passed 27 methods and 33 cases; the appearance and automatic-camera corrections passed four new methods and 11 cases. The prior 37 methods were compiled but left unselected in that correction run. The original provider3 bundle build passed and its actual resources, arm64 bundle header, macOS 15 minimum, system-only linkage, absence of rpaths, and Objective-C principal symbol were inspected. Signing and hosted installation are separate delivery steps. These receipts do not qualify every root-package target or the future upstream checkout.

In particular, the original whole-package test build failed in `EngramProjectGraphExporter` because the pinned Lattice SDK does not expose `storedSchemaVersion`. That existing-store schema guard is retained. The local graph projection avoids the unrelated exporter target for focused renderer qualification; it does not resolve the root-package SDK compatibility prerequisite. A clean-source build must address that prerequisite through a separately reviewed compatible SDK or source correction before claiming full Engram acceptance.

The provider target retains the tested strict-link settings (`LD_RUNPATH_SEARCH_PATHS` empty and `DISABLE_SWIFT_SPAN_COMPATIBILITY_RPATH=YES`) and the actual provider3 identity (`CFBundleVersion=3`, short version `0.1.2`). Inspection must still verify the resulting artifact rather than infer linkage from settings. Code-signing identity and team remain supplied by the authorized build environment. The ordinary Engram app keeps its default graph appearance and has no HUD ABI dependency.

The focused adapter test target is `EngramHUDAdapterTests`. Keep build/cache/temp paths under `~/localdev` and use the existing prepared dependency closure and bounded lifecycle. A clean checkout must re-establish its own source/dependency/build evidence; do not reuse scratch receipt hashes as evidence for different source bytes. Generate the provider project from this canonical `project.yml` using the established XcodeGen route. Loading requires externally trusted release metadata, signature/platform/dependency admission, and runtime descriptor equality before obtaining the principal class. MCP authentication does not authorize native loading. Loaded native code is trusted in-process code and cannot be safely hot-unloaded.

The `EngramHUDContract` product now belongs to `Packages/EngramGraphContracts`, a macOS 14 pure package alongside the original graph DTO implementation in `EngramGraphContract`. The adapter imports that product; its existing `EngramHUDGraphWire` alias remains. `EngramMemoryCore` retains seven aliases to the same DTO types for existing exporters and views. Contract consumers do not link GraphSurface, RealityKit or this native provider, which still requires macOS 15. Provider identity is the Connect identifier `engram`; bundle and schema identifiers remain namespaced. The shared-contract package is the separate PR69 publication; its contract-only CI does not qualify the additional native runtime delivery. Historical Engram35 and other frozen snapshots remain unchanged.
