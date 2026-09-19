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

Coverage: 83 learner admission/frontier/router/budget/audit/serialization checks,
29 recall/lifecycle checks, 15 status-reader checks, 8 bootstrap/entry checks, and
20 marketplace-policy checks. The lock-inheritance test starts only a fixed
Python worker and dummy child to verify descriptor lifetime after abrupt worker
exit. Other process/provider operations use explicit fakes or guards. No native
Engram server, Codex provider, memory database, or network service is invoked.

These tests do not replace signed-artifact validation or natural hook/MCP/learner
acceptance in Codex. They preserve the prior rollout regressions while testing
the assembled release source, including manifest-based marketplace policy.
