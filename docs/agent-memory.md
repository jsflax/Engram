# Embedded per-agent memory

`EngramLattice` is the existing Lattice `MemoryTools` backend extracted from
`EngramKit`. It shares the `EngramMemoryCore.MemoryService` contract with the
hosted backend. `EngramKit` re-exports the moved implementation, preserving the
existing desktop MCP, hook, and CoreML embedding APIs.

```swift
import EngramLattice

let binding = AgentMemoryBinding(agentId: durableAgentID, displayName: "Astra")
let memory = try AgentMemoryStore.open(binding: binding, directory: graphsDirectory)
let saved = try await memory.remember(RememberRequest(content: "A durable fact"))
let advice = try await memory.advise(AdviseRequest(prompt: userMessage))
```

The default embedder is explicitly unavailable: memory writes persist locally
with `embeddingPending`, and recall uses Lattice full-text search. Inject an
`Embedder` to enable semantic search. Apple hosts can depend on `EngramCoreML`
and inject `CoreMLMemoryEmbedder()`: it ships the same MiniLM model/tokenizer as
desktop Engram, loads off the main actor, and never downloads resources. Optional
`try await embedder.load()` warms up; the first embed call otherwise loads it.
The model card identifies the bundled model/tokenizer as Apache 2.0; notices and
licenses ship in the resource bundle. The desktop `EmbeddingService` also conforms; hosts must start/load it as before. `backfillPendingEmbeddings(limit:)`
indexes a bounded batch after the same compatible embedding model is available.
Pending content updates clear the old vector rather than returning semantically
stale results. Cancellation does not turn into an offline successful write.

The graph filename derives from `graphId`, defaulting to the durable agent UUID.
`AgentMemoryGraph` persists and validates ownership in the graph itself. Renaming
or moving an agent does not create another memory identity. Hosts synchronize
`await memory.privateGraphReference` through Lattice; publishing must carry this
binding and graph together.

Shared sources require explicit `AgentMemorySource` values containing a graph
UUID, display name, existing Lattice reference, and file URL. All mutations stay
inside the agent's graph: direct and query-based edits, bulk deletes, merge,
forced consolidation, organization, episode updates, relationship creation and
removal, indexing, and maintenance. Shared access counters are not changed.
Removing a source file removes it from the next recall. Authenticated grants
and synchronization remain the embedding host's responsibility.

Before registering a selected collection, call
`try AgentMemorySourceValidation.validate(fileURL:)`. It checks the actual
Memory/Edge schema through a read-only dynamic Lattice handle. It accepts older
collections without migrating them and rejects unrelated databases or missing
files without creating replacements.

`RecallHit.sourceGraphId` and `.sourceGraphName` describe provenance. Advise also
returns the exact `.query` and source-attributed `.hits`, alongside the existing
injection-ready block and memory IDs. These new optional DTO fields preserve
compatibility with older remote backends. Private agent content does not enter
the legacy personal `~/.claude` hook diagnostic logs.

## Build boundaries

The repository root is the portable Swift package consumed through the normal
Engram Git URL. It exports `EngramLattice`, `EngramMemoryCore`, `EngramModels`, and
`EngramMemoryContract` with no environment flag. It does not resolve SwiftLM,
Sparkle, sign-in, or desktop UI. The Apple-only optional `EngramCoreML` product
uses the existing Tokenizers/Hub library for local JSON tokenization; its runtime
never invokes Hub network loading. NaturalLanguage is used when available;
Linux uses the portable content-word extractor. iOS does not expose the desktop
subprocess launcher in the core module. Linux retains the remote `EngramHooks` CLI.

The desktop package is `Desktop/Package.swift`. Its Sources, Tests, and Plugins
symlinks keep one canonical implementation. Build desktop commands from the repo
root with `swift build --package-path Desktop --scratch-path .build`; the install
script, release workflow, and Xcode project use this boundary. Installed executable names are unchanged; desktop packaging includes the
`Engram_EngramCoreML.bundle` shared model resources alongside EngramKit resources. `Portable/Package.swift`
remains a compatibility path for development consumers already using it.
Signed apps place the resource bundle under `Contents/Resources`; standalone
helpers can place it beside the executable. Resource lookup checks those paths
for either `Engram_EngramCoreML.bundle` or `EngramPortable_EngramCoreML.bundle`
before evaluating SwiftPM's generated bundle accessor. App-root resource links
are unnecessary.

`ENGRAM_LATTICE_PATH` and `ENGRAM_LATTICECORE_PATH` are optional local dependency
overrides for coordinated development. They are not required by the public API.
The current implementation needs the accompanying Lattice checked-transaction,
immutable synchronization, and readonly legacy-schema attachment changes. Before
publishing a consumer release: publish LatticeCore, publish Lattice pinned to that
Core release, update Engram's minimum Lattice version and release Engram, then pin
Orbital/engram-server to that actual Engram release. No placeholder commit or tag
is a valid remote pin; the isolated local workspace is the verified integration
until that release train is committed and published.

This library does not enroll devices, discover personal credentials, mount hooks,
start servers, or migrate a production database. Those are host integration tasks.

## Verification

The final portable run passed **42 tests in 12 suites (0.854 s)**. A separately
compiled focused run passed **11 tests in 3 suites (1.312 s)**, including actual
Lattice audit-event transport and appended current-row snapshots: distant-future
dates, microsecond timestamps and all 384 vector values retain an exact matching
transfer fingerprint. Source validation also verifies byte-identical legacy and
current read-only collections. The [verification record](verification-2026-09-09.json)
contains exact source and test-log SHA-256 hashes. These are local, uncommitted
implementation results; the recorded base Git HEAD is not a release revision.

The portable suite covers the existing MemoryService
contract, offline persistence and backfill, graph identity, mutation isolation,
and opening an older writable graph through the versioned migration. A separate
readonly legacy-source fixture verifies that recall leaves its bytes unchanged.
The LatticeCore attachment suite passes ten tests, including legacy projection
and write rejection. The bundled CoreML tests exercise real vectors, semantic recall, pending-vector
backfill, and missing-asset failure without network fallback. The portable and
existing desktop embedders agree at cosine ≥0.999 on the established six-text
corpus (`EngramCoreMLParityTests`). The exact CoreML product dependency closure
also compiles against the iPhoneOS 18 SDK; full native iOS integration is
validated by Orbital's app build.

## Verifying a transferred graph (schema 6)

An `AgentMemoryGraph` owner row proves identity, not that its history has arrived.
Before assigning a turn to a device that received another host's graph, obtain an
`AgentMemoryTransferSeal` from the current graph authority and call
`AgentMemoryTransfer.verify(in:expected:)` on the receiving Lattice. Start only
when `isReady` is true. Do not select an arbitrary cached receiver manifest as the
expected descriptor for a new assignment.

The authority calls `AgentMemoryTransfer.seal(in:binding:)` on a coherent checked
transaction. The immutable `AgentMemoryTransferManifest` row contains a SHA-256
fingerprint and per-table counts. The fingerprint includes sorted durable record
IDs, every portable stored field, vector bits, tombstones, relationships,
checkpoints and metadata. Actual memory content has only its existing Lattice
representation. Transfer metadata is excluded from its own fingerprint.

A phone publishing its own graph sends its descriptor through an authenticated
owner command while its graph rows upload normally. The coordinator checks that
the authenticated device owns that graph and calls
`AgentMemoryTransfer.accept(in:expected:)`. It persists the matching manifest only
when all content matches; a partial replica cannot certify itself by locally
calling `seal`. Replica write policies must reject manifest insert/update/delete.

Verification is exact, including absence of stale rows after hard deletions.
Owner-first delivery, an existing partial prefix, different sync batches and
stale manifests remain pending. Reseal after subsequent writes and use that new
descriptor for the next assignment. Defaults bound verification to 100,000 records
and 256 MiB of canonical content. Hosts should cache successful verification for
a particular immutable assignment/descriptor and invalidate on graph changes,
rather than hashing the graph during every UI render. The portable format covers
`AgentMemoryStore.schema`; server-only import bookkeeping has its separate archive
verification and is not a portable recall field.

### Process-shared writer fencing

Schema 6 adds `AgentMemoryWriterFence`, a graph-local authority row keyed by graph and coordinator. Coordinators update it from the existing `beforeSnapshot`/`onReady` callbacks; relay authorization reads it inside the same SQLite write transaction. This prevents a different process from retaining an obsolete in-memory writer grant. The row is excluded from the memory fingerprint and must be excluded from both upload and download transport filters. It is never writable by an agent or replica. Historical schema 5 files gain the table through the additive migration.
