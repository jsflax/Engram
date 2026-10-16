"""Shared bounded learner policy, used by runner and sealed proxy context."""

DEFAULTS = {"min_chars": 400, "max_chars": 24000, "max_scan_bytes": 8 * 1024 * 1024,
            "wall_seconds": 600, "max_tool_calls": 12, "max_writes": 5,
            "max_runs_per_worker": 4, "retry_seconds": 300}


def bounded(value):
    result = {**DEFAULTS, **value}
    for key, low, high in (("min_chars", 0, 10000), ("max_chars", 1000, 48000),
                          ("max_scan_bytes", 4096, 32 * 1024 * 1024),
                          ("wall_seconds", 10, 900), ("max_tool_calls", 1, 20),
                          ("max_writes", 1, 5), ("max_runs_per_worker", 1, 8),
                          ("retry_seconds", 10, 3600)):
        result[key] = max(low, min(high, int(result[key])))
    return result
