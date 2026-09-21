#!/usr/bin/env python3
"""Guarded, explicit selected-task identity migration. See --help."""
import sys

sys.dont_write_bytecode = True

from codex_learner.migration import main

if __name__ == "__main__":
    raise SystemExit(main())
