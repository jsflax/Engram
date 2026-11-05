# Codex learner gateway HTTPS compatibility transport

The shipped `codex/plugins/engram/scripts/codex_learner/memory_proxy.py` can use an explicitly configured HTTPS MCP endpoint for **read-only** access. It retains the same policy callbacks, tool budgets, request correlation and metadata-only audit as its stdio path. Discovery and dispatch are capped to `recall`, `graph`, `list_topics`, `stats` and `timeline`, regardless of configured write budgets or advertised remote tools.

This is a transport foundation, not a qualified hosted learner contribution path. HTTP configurations carrying native sealed `execution` are rejected before network access. Native execution manifests bind a native runtime, store/principal scope and operation journal; hosted publication must acquire its own reviewed binding and durable receipt contract before writes can be admitted. No timeout, expired session, redirect or transport failure triggers a POST replay or a fallback to stdio, another endpoint or engramdb.io.

The standard learner `memory_config` resolver, sealed runner, per-fact router and pending queue are not converted to HTTP by this change. The configuration below is for the gateway entry point; it is not a new installation or a drop-in replacement for Codex's global MCP declaration.

## Explicit endpoint and credential binding

The gateway JSON must be an absolute private file (mode 0600):

```json
{
  "transport": {
    "type": "http",
    "url": "https://your-approved-company-host.example/mcp",
    "credential_file": "/absolute/private/employee-mcp-credential.json",
    "request_timeout_sec": 30,
    "initialize_timeout_sec": 10,
    "max_inflight": 8,
    "max_response_bytes": 1048576
  },
  "provenance": "codex-session:your-session-id",
  "max_tool_calls": 20,
  "max_writes": 0,
  "audit_path": "/absolute/private/mcp-audit.jsonl"
}
```

The separate credential file is an owned, single-link regular file with no group/other permissions and no symlink path components:

```json
{
  "version": 1,
  "endpoint": "https://your-approved-company-host.example/mcp",
  "bearer_token": "issued-token-for-this-endpoint"
}
```

Its endpoint must exactly match the configured URL. Query strings, fragments, URL user-info, plain HTTP and custom transport/header/environment fields are refused. The token is read once into the isolated adapter and never placed in argv, URLs or audits. TLS uses hostname verification and system trust. An optional `tls_ca_pem` certificate in the same private credential record can explicitly bind a dedicated trust root (used by the isolated TLS regression fixture); there is no verification-disable switch. Credential issuance and installation are separate authorized operations.

## Protocol and resource limits

This adapter implements the initialize/session compatibility lifecycle for MCP `2025-03-26` and `2025-06-18`. The negotiated version must match the supported requested version. The 2026 per-request-metadata lifecycle is not implemented. See the [2025 transport specification](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports) and [current transport lifecycle](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports).

Each message uses a fresh POST to the exact endpoint, accepting UTF-8 JSON or a bounded request-scoped SSE stream. Session and protocol headers are checked and retained; response IDs preserve JSON type and must match their request. Server-initiated requests pass through the existing learner policy, which rejects them and returns that rejection over HTTP. Cancellations are forwarded while reads remain in flight; a cancellation racing a completed read is ignored. HTTP status errors, malformed responses, expired sessions and stream interruption end the gateway session. No GET stream, SSE resumption, automatic reinitialization or background session deletion is attempted.

Hard maxima: 1 MiB per input/response, 8 simultaneous client requests, 2 additional control jobs, 128 SSE messages per response, bounded HTTP headers, and a 4 MiB relay output queue. Request deadlines default to 30 seconds (maximum 120); initialization defaults to 10 (maximum 30). The existing relay supervises a separate adapter process, so DNS/TLS stalls, slow bytes, output backpressure, cancellation and client disconnect cannot leave an unbounded adapter lifetime. No HTTP library/environment proxy or redirect handling is used.

Run `Tests/codex_plugin/test_http_memory_proxy.py` for actual local TLS/server and gateway-process coverage. Fixtures use synthetic credentials and repository-owned temporary storage; they do not contact a live Engram service.
