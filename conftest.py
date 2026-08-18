"""Put the repo root on sys.path for every test invocation.

`python -m pytest` inserts the working directory into sys.path; a bare
`pytest` does not. The Makefile uses the former and CI uses the latter, so a
test module importing `src.*` without its own bootstrap passes locally and
fails in CI — which is exactly what tests/test_cvar_qaoa.py did, leaving the
suite red for three pushes while local runs stayed green.

Every other module in tests/ carries a two-line sys.path preamble. This makes
that unnecessary rather than merely conventional: a new test file cannot
reintroduce the bug by forgetting it.
"""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
