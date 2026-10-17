# Native operation canonical payload checks

This small harness compiles the real `MemoryOperationCanonicalPayload.swift`
against a previously built `EngramMemoryCore` module. It needs macOS CryptoKit,
but no Lattice, MCP, model downloads, live store, or full app build.

```sh
bash Tests/operation_canonical_payload/run.sh \
  /absolute/path/to/core/build/out/Products/Debug \
  /absolute/path/under/localdev/canonical-payload-tests
```

The second directory contains the executable, compiler module cache, and scratch
files. `reference_vector.py` independently constructs a fixed binary fixture
using Python's standard library; the Swift harness compares its SHA-256 with
native preparation. The checks cover identity/set normalization, all current
mutation fields, scope and provenance binding, relative expiration semantics,
exact append bytes, default equivalence, invalid mutations, unsupported
versions, and the content-free public receipt schema.

## Execution contract

Preparation is an internal backend boundary. It returns the immutable semantic
mutation that a later transaction executor must apply, together with its native
digest. It does not accept a caller digest and does not implement mutation,
authorization, ledger persistence, status lookup, or recovery on its own.

The future executor must:

1. Check the requested store/principal scope and lookup the existing operation
   receipt before starting expensive work. Preparation needs no current row
   content, wall clock, or mutable project configuration.
2. Recheck authenticated scope after suspension and inside the owning-store
   transaction. The expected scope in a request is never authentication.
3. Execute the **prepared** mutation; do not pass it back through the old request
   decoder or choose defaults again. For example, omitted remember importance
   prepares to internal zero, whereas explicit zero in a remember request is
   invalid. Append/prepend add the existing single LF separator and preserve the
   argument bytes exactly. Find/replace uses the existing replacement semantics.
4. Resolve a relative expiration once in the original committed transaction.
   Receipt replay must not extend expiration or reapply append/prepend.
5. Commit the mutation and receipt in the same owning-store transaction. Public
   receipts expose only operation/scope/digest/result metadata, never canonical
   bytes or full content. An absent ledger entry is not a license to replay an
   older writer that has not been fenced.

### Version 1 semantics

The source documents the exact binary format and ordered fields. It uses a
domain/version prefix, 64-bit big-endian lengths/integers, presence tags, and
unmodified UTF-8 mutation strings. It does not use JSON object order, Swift's
randomized `Hasher`, trimming, newline conversion, or Unicode normalization of
memory content. UUID case and unordered principal collections normalize.
Principal scope labels use NFC before deduplication/sorting, matching Swift
`String` equality; scope case remains significant. Provenance strings retain
their original UTF-8 bytes.

Remember defaults are fixed: `general` topic, `global` project, empty source,
internal zero importance, false privacy, no parent, permanent expiration.
Absent and nonpositive remember TTLs are equivalent. Explicit empty topic and
project remain explicit values. Update nil means no edit; empty strings and
false are explicit edits. Zero update TTL clears expiration, positive and
negative update TTLs retain signed relative-day semantics. Undelete and unknown
relations are rejected before hashing; local/foreign target ownership remains
the transaction executor's responsibility. Update `source` is an optional exact
metadata edit: omission preserves it, while an empty string clears it. The
operation DTO deliberately excludes legacy query-based targeting.

Future dynamic defaults must have an explicit durable resolution contract.
Changing field layout or defaults requires a new canonical format and a
compatibility decision for existing receipts. Passing this harness is only
foundation coverage: it does not permit advertising the durable-operation
capability or claim same-transaction correctness.

`MemoryOperationCanonicalPayload.principalKey(_:)` supplies the ledger's stable
principal hash. It uses its own versioned domain and the same principal binary
encoder as payloads, so reordering or canonically equivalent Unicode scopes
cannot disagree with receipt scope equality. Pair this key with the store UUID
and operation UUID for uniqueness; it does not replace full scope validation.
