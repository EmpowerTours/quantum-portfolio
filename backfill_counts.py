#!/usr/bin/env python3
"""Backfill raw measurement counts into a hardware-run artefact.

Qiskit Runtime job results are retrievable by ID, so counts from a completed
run can be recovered without spending new QPU time.

Why this exists: the artefacts previously stored only summary scalars, so a
reviewer could not recompute P(optimal), the feasible fraction, or the
approximation ratio. SUBMISSION.md claimed the runs were "verifiable on
quantum.ibm.com" — but Runtime results are scoped to the owning IBM account,
so a third party clicking that link gets an auth wall, not a verification.
Shipping the counts is what makes the claim true.

Usage:
    python backfill_counts.py outputs/hardware_run_defi.json
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

from src.hardware import get_service


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    path = Path(sys.argv[1])
    doc = json.loads(path.read_text())

    svc = get_service()
    changed = 0
    for r in doc["results"]:
        jid = r.get("job_id")
        if not jid:
            continue
        if r.get("counts"):
            print(f"  {r['method']}: already has counts, skipping")
            continue
        try:
            job = svc.job(jid)
            counts = job.result()[0].data.meas.get_counts()
        except Exception as exc:
            print(f"  {r['method']}: could NOT retrieve {jid} — {exc}")
            continue
        r["counts"] = counts
        total = sum(counts.values())
        # Recompute P(optimal) from the retrieved counts and check it against
        # the stored value. If they disagree, the artefact is not describing
        # the job it names.
        opt = set(doc["optimal"]["selection"])
        n = len(doc["tickers"])
        p = sum(c for bs, c in counts.items()
                if {i for i in range(n) if bs[::-1][i] == "1"} == opt) / total
        ok = abs(p - r["p_optimal"]) < 1e-9
        print(f"  {r['method']}: {len(counts)} distinct states, {total} shots, "
              f"recomputed P(opt)={p:.6f} {'MATCHES' if ok else 'MISMATCH vs stored'}")
        changed += 1

    if changed:
        path.write_text(json.dumps(doc, indent=2) + "\n")
        print(f"\nwrote {path} with counts for {changed} run(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
