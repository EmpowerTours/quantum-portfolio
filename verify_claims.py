#!/usr/bin/env python3
"""Verify every hard claim in the judge-facing docs against its source.

Written because the same failure kept recurring: a number would be corrected in
one document and left stale in three others, or a figure would be asserted that
no artefact supported. Each was found by chance. This finds them on demand.

Sources of truth, in order of authority:
  1. the chain          (contract code, transaction receipts)
  2. shipped artefacts  (outputs/*.json — raw counts recompute the metrics)
  3. the test suites    (actual pass counts)

Usage:  python verify_claims.py            (add --chain to include RPC checks)
Exit code is non-zero if any claim fails, so CI can gate on it.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DOCS = ["README.md", "SUBMISSION.md", "SECURITY.md",
        "docs/PITCH_DECK.md", "docs/DEMO_VIDEO_SCRIPT.md"]
RPC = "https://rpc.monad.xyz"

LIVE = {
    "AuditAnchorV2":       "0x8422b555DCE11913A4657C2f47C839637FC71ffd",
    "UniswapRoutingVault": "0x06F233062eE23590e5CC873df511024f3d981e56",
    "MorphoSupplyAdapter": "0x8d5AE2f23E5d20bFb7915168d6b2a3Ce753fE49E",
    "MLDSAAttestation":    "0xb0aADaFe68647578520E988b4444e556c300b4Da",
}
SUPERSEDED = ["0x4cb79cc36b367a6fd7363bc6a8553a7a270da27c",
              "0xe2fcada067227c817b8a47b850d727ba065e16dd",
              "0xB1a4341403DA395760561B85C4C96696C0D15958",
              "0xc1a82D8C4D28Eca8B318D1bac8DCc2Ab963b3839"]
TXS = {
    "attest":          "0x3ec51f366d7d7944742f808cef8f897a750be881bddda6aa7a171880377d56de",
    "anchor(route)":   "0x8702d6a99fa070ed97032e73351e7167f8ef278da20b7b9ce3d1730866d40a7d",
    "executeAndRoute": "0xf3696f0f2d461caf4bcb2d555551460b2016ed264730a055ea34c78a9b38a706",
    "supply":          "0xbfd90ffdefea2fa91f0cd2a1e3b7ae178a7ad67e24af882e8d1eb13eb619fd4f",
}

fails: list[str] = []
def check(ok: bool, label: str, detail: str = "") -> None:
    print(f"  {'PASS' if ok else 'FAIL'}  {label}{('  — ' + detail) if detail else ''}")
    if not ok:
        fails.append(label)


def text(paths=DOCS) -> dict[str, str]:
    return {p: (ROOT / p).read_text() for p in paths if (ROOT / p).exists()}


def check_artifact_metrics() -> None:
    """Recompute P(optimal) and feasible fraction from the raw counts and
    assert the stored summaries match. If these drift, every downstream
    document is quoting a number the artefact does not support."""
    print("\n[artefacts] stored summaries vs raw counts")
    for f in ("outputs/hardware_run.json", "outputs/hardware_run_defi.json"):
        p = ROOT / f
        if not p.exists():
            check(False, f"{f} missing"); continue
        d = json.loads(p.read_text())
        n, k = len(d["tickers"]), d["budget"]
        opt = set(d["optimal"]["selection"])
        for r in d["results"]:
            c = r.get("counts")
            if not c:
                continue
            tot = sum(c.values())
            pop = sum(v for bs, v in c.items()
                      if {i for i in range(n) if bs[::-1][i] == "1"} == opt) / tot
            fea = sum(v for bs, v in c.items()
                      if sum(1 for ch in bs if ch == "1") == k) / tot
            check(abs(pop - r["p_optimal"]) < 1e-9,
                  f"{Path(f).stem}:{r['method']} P(opt)", f"{pop:.6f} vs {r['p_optimal']:.6f}")
            check(abs(fea - r["feasible_fraction"]) < 1e-9,
                  f"{Path(f).stem}:{r['method']} feasible", f"{fea:.4f}")


def check_test_counts() -> None:
    """The documented totals must equal what the suites actually report."""
    print("\n[tests] documented counts vs actual")
    py = subprocess.run([sys.executable, "-m", "pytest", "tests/", "-q"],
                        cwd=ROOT, capture_output=True, text=True, timeout=900).stdout
    m = re.search(r"(\d+) passed", py)
    npy = int(m.group(1)) if m else -1
    if not shutil.which("forge", path=f"{Path.home()}/.foundry/bin:{os.environ.get('PATH','')}"):
        print("    forge not found — cannot verify the combined test count")
        check(False, "forge available for test-count verification",
              "install foundry, or run this where forge is on PATH")
        return
    env = {"PATH": f"{Path.home()}/.foundry/bin:{os.environ.get('PATH','')}",
           "MONAD_RPC_URL": RPC,
           "FORK_TOKEN_OUT": "0x754704Bc059F8C67012fEd69BC8A327a5aafb603",
           "FORK_FEE": "3000"}
    fo = subprocess.run(["forge", "test"], cwd=ROOT / "contracts",
                        capture_output=True, text=True, env=env, timeout=1800).stdout
    m = re.search(r"(\d+) tests passed", fo)
    nfo = int(m.group(1)) if m else -1
    total = npy + nfo
    print(f"    actual: {npy} Python + {nfo} Foundry = {total}")
    # A document may legitimately cite a per-suite count ("169 tests, 0
    # skipped" next to `forge test`) as well as the combined total. Only a
    # number matching none of the three is a stale claim. Without this the
    # checker flags true statements, which trains people to ignore it.
    valid = {total, npy, nfo}
    for path, s in text().items():
        for claimed in set(int(x) for x in re.findall(r"(\d{2,4}) tests(?:,| passing| total)", s)):
            check(claimed in valid, f"{path} test count {claimed}",
                  f"expected one of {sorted(valid)} (total {total})")


def check_execution_binding() -> None:
    """The shipped order must still be the order anchored on mainnet.

    Added after `python run_pq_demo.py` silently overwrote signed_orders.json
    with a fresh unexecuted order. Nothing failed: the file was well-formed,
    every signature verified, the app rendered. It just no longer had anything
    to do with the transaction it was linked to. This recomputes both
    committed values and compares them against the executed calldata, so that
    class of drift is a test failure rather than a coincidence.
    """
    print("\n[binding] shipped order vs the anchor executed on mainnet")
    ex_path = ROOT / "outputs/executed_anchor_tx.json"
    if not ex_path.exists():
        check(False, "outputs/executed_anchor_tx.json present"); return
    sys.path.insert(0, str(ROOT))
    from src import monad_tx, orders as _o          # noqa: PLC0415

    ex = json.loads(ex_path.read_text())
    dec = ex["decoded"]
    so = _o.load_signed_orders()[-1]
    oh = "0x" + monad_tx.order_sha256(so).hex()
    cm = "0x" + monad_tx.route_commitment(
        so.order.execution, monad_tx.order_sha256(so)).hex()
    check(dec["orderHash"] == oh, "anchored orderHash == SHA-256(shipped order)",
          f"{dec['orderHash'][:18]}… vs {oh[:18]}…")
    check(dec["execCommitment"] == cm, "anchored execCommitment recomputes",
          f"{dec['execCommitment'][:18]}… vs {cm[:18]}…")
    check(ex["chainId"] == 143, "anchor executed on Monad mainnet",
          f"chainId {ex['chainId']}")
    check(ex["status"] == 1, "anchor transaction succeeded")

    # The calldata must decode to exactly what the JSON claims it decodes to.
    d = ex["data"]
    check(d[:10] == "0x15954b2c" and "0x" + d[10:74] == dec["orderHash"]
          and "0x" + d[74:138] == dec["execCommitment"],
          "executed calldata matches its own decoded block")

    # Unsigned artefacts must not quietly carry a testnet chain id while the
    # docs say mainnet. unsigned_alloc_tx is testnet ON PURPOSE (the vault has
    # no mainnet code) and is the single documented exception.
    for name, want in (("unsigned_monad_tx.json", 143),
                       ("unsigned_anchor_tx.json", 143),
                       ("unsigned_alloc_tx.json", 10143)):
        f = ROOT / "outputs" / name
        if not f.exists():
            continue
        got = json.loads(f.read_text()).get("chainId")
        check(got == want, f"{name} chainId", f"{got} (expected {want})")


ANCHORER   = "0x8df64bacf6b70f7787f8d14429b258b3ff958ec1"
STALE_HASH = "fe44195b36463e33da7156285383a4fe735093ecadb1abb87684435552814ba9"


def check_reviewer_commands() -> None:
    """Run the commands the docs tell a reviewer to run, and diff the outputs.

    Every other check here verifies the artefacts. None of them verified the
    INSTRUCTIONS, and that is where the damage was: SUBMISSION.md and README.md
    told reviewers to expect `fe44195b...`, the shipped order hashed to
    `d8bf1551...`, and following the documented steps produced a mismatch
    against a system that was working correctly. A reviewer who did as asked
    would conclude the artefacts do not reconcile.

    The deeper cause was the accessor, not the value: the docs compared against
    `lastHash[anchorer]`, which is last-write-wins and legitimately moved on as
    soon as a second order was anchored. `execCommitmentOf[anchorer][orderHash]`
    is keyed by the order and cannot be overwritten, so it is what the docs now
    use and what this check exercises.
    """
    print("\n[reviewer] the documented commands, executed")
    sys.path.insert(0, str(ROOT))
    from src import monad_tx, orders as _o          # noqa: PLC0415

    so = _o.load_signed_orders()[0]
    oh = "0x" + monad_tx.order_sha256(so).hex()
    cm = "0x" + monad_tx.route_commitment(
        so.order.execution, monad_tx.order_sha256(so)).hex()

    docs = text(["README.md", "SUBMISSION.md"])
    for path, body in docs.items():
        check(oh[2:] in body, f"{path} documents the real orderHash", oh[:18] + "…")

    # The stale digest may appear ONLY inside the explicitly historical block.
    for path, body in docs.items():
        if STALE_HASH not in body:
            check(True, f"{path} free of the superseded digest"); continue
        before = body.split(STALE_HASH)[0][-1500:]
        ok = "<details>" in before and "Historical" in before
        check(ok, f"{path} quarantines the superseded digest",
              "" if ok else "appears outside the historical block")

    # Modules using pytest fixtures silently do nothing when run as scripts.
    for path, body in docs.items():
        check("python tests/test_" not in body,
              f"{path} does not tell reviewers to run test modules as scripts")

    # Placeholders must never reach a judge. A slide that reads
    # "FOUNDER_NAME_TBD" is worse than no team slide, and the only reliable way
    # to guarantee it is filled in is to fail the build while it is not.
    for f in ("docs/PITCH_DECK.md", "README.md", "SUBMISSION.md"):
        body = (ROOT / f).read_text()
        for token in ("_TBD", "TODO:", "FIXME", "XXX_"):
            check(token not in body, f"{f} free of placeholder {token!r}",
                  "" if token not in body else "unfilled placeholder would ship")

    # The deck pins a commit; it may lag HEAD but must exist in this history.
    deck = (ROOT / "docs/PITCH_DECK.md").read_text()
    m = re.search(r"commit <code>([0-9a-f]{7,40})</code>", deck)
    if m:
        sha = m.group(1)
        # A shallow clone genuinely does not contain the parent commit, and
        # "absent" must not be reported as "bogus" — CI checks out depth 1 by
        # default, which failed this check for lack of history rather than for
        # a bad pin. Distinguish the two instead of silently passing either.
        present = subprocess.run(["git", "cat-file", "-e", f"{sha}^{{commit}}"],
                                 cwd=ROOT, capture_output=True).returncode == 0
        shallow = subprocess.run(["git", "rev-parse", "--is-shallow-repository"],
                                 cwd=ROOT, capture_output=True,
                                 text=True).stdout.strip() == "true"
        if not present and shallow:
            print(f"    deck commit {sha}: shallow clone, cannot verify "
                  "(CI fetches full history for this job)")
        else:
            r = subprocess.run(["git", "merge-base", "--is-ancestor", sha, "HEAD"],
                               cwd=ROOT, capture_output=True)
            check(r.returncode == 0, f"deck commit {sha} is in this history")

    if "--chain" not in sys.argv:
        print("    (skipping the on-chain half; pass --chain to run it)")
        return

    fo = f"{Path.home()}/.foundry/bin"
    r = subprocess.run(
        [f"{fo}/cast", "call", LIVE["AuditAnchorV2"],
         "execCommitmentOf(address,bytes32)(bytes32)", ANCHORER, oh,
         "--rpc-url", RPC], capture_output=True, text=True, timeout=120)
    onchain = r.stdout.strip()
    check(onchain == cm, "documented cast call returns the recomputed commitment",
          f"{onchain[:18]}… vs {cm[:18]}…")
    check(cm in docs["README.md"] and cm in docs["SUBMISSION.md"],
          "both docs publish that expected commitment")


def check_addresses() -> None:
    """Superseded contracts may appear ONLY inside an explicit superseded block."""
    print("\n[addresses] live present, superseded quarantined")
    for path, s in text().items():
        for name, addr in LIVE.items():
            if path in ("README.md", "SUBMISSION.md", "docs/PITCH_DECK.md"):
                check(addr.lower() in s.lower(), f"{path} lists {name}")
        for old in SUPERSEDED:
            if old.lower() in s.lower():
                near = s.lower().split(old.lower())[0][-1200:]   # blocks can be long
                ok = any(w in near for w in ("supersed", "retired", "earlier", "v1", "legacy"))
                check(ok, f"{path} contextualises superseded {old[:10]}…",
                      "" if ok else "appears without a superseded marker")


def check_chain() -> None:
    print("\n[chain] contracts carry code, transactions succeeded")
    fo = f"{Path.home()}/.foundry/bin"
    for name, addr in LIVE.items():
        r = subprocess.run([f"{fo}/cast", "codesize", addr, "--rpc-url", RPC],
                           capture_output=True, text=True, timeout=120)
        size = int(r.stdout.strip() or 0)
        check(size > 0, f"{name} has code", f"{size} bytes")
    for name, tx in TXS.items():
        r = subprocess.run([f"{fo}/cast", "receipt", tx, "--rpc-url", RPC],
                           capture_output=True, text=True, timeout=120)
        st = re.search(r"^status\s+(\d)", r.stdout, re.M)
        check(bool(st) and st.group(1) == "1", f"tx {name} succeeded")
        if name == "attest":
            g = re.search(r"^gasUsed\s+(\d+)", r.stdout, re.M)
            if g:
                gas = int(g.group(1))
                for path, s in text().items():
                    for c in re.findall(r"([\d,\s]{3,12})\s*gas", s):
                        v = c.replace(",", "").replace(" ", "")
                        if v.isdigit() and 100_000 < int(v) < 10_000_000:
                            check(abs(int(v) - gas) < 1000,
                                  f"{path} gas figure {v}", f"actual {gas}")


def main() -> int:
    print("Verifying documented claims against chain, artefacts and tests.")
    check_artifact_metrics()
    check_execution_binding()
    check_reviewer_commands()
    check_addresses()
    check_test_counts()
    if "--chain" in sys.argv:
        check_chain()
    print(f"\n{'ALL CLAIMS VERIFIED' if not fails else f'{len(fails)} FAILED:'}")
    for f in fails:
        print(f"  - {f}")
    return 1 if fails else 0


if __name__ == "__main__":
    raise SystemExit(main())
