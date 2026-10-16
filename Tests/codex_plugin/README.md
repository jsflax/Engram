# Codex plugin regressions

From the repository root, run with Python 3.11 or newer:

```sh
python3 -B Tests/codex_plugin/run_suite.py
```

The suite loads **this repository's `codex/plugins/engram`**, not an installed
cache or a previous rollout overlay. Temporary fixtures remain under the ignored
`Tests/codex_plugin/.tmp` directory; `results.json` records the tested source
hashes and results.

Each group runs in a separate Python process to prevent shared import aliases
from binding a test to a previous group's module. Default `HOME` and `CODEX_HOME`
are also private fixtures, including for shared provider-lock tests.

Coverage includes admission, frontier preservation, routing, budgets, audits,
recall/lifecycle hooks, bounded health reads, bootstrap, identity migration and
marketplace policy. Durable execution checks cover immutable inputs, writer
fencing, native operation receipts, recovery lookups, settlement and cursor/queue
publication, including forced process termination. Results list the exact test
counts and tested source hashes.

Provider and native exchanges use controlled subprocess fixtures. No real Codex
provider, installed Engram server, live memory database or network service is
invoked. Native fence tests may use an explicitly supplied compiled fixture;
without it, those checks report skips and require separate native qualification.

These tests do not replace signed-artifact validation or natural hook/MCP/learner
acceptance in Codex. They preserve the prior rollout regressions while testing
the assembled release source, including manifest-based marketplace policy.
