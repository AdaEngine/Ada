#!/usr/bin/env python3
"""Entry point for contributor checks; all ordinary execution is deterministic, without an LLM."""

from contribution.cli import main

if __name__ == "__main__":
    raise SystemExit(main())
