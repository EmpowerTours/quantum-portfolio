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
# Every LIVE judge-facing document. The AUDIT_*.md files are deliberately
# excluded: they are dated snapshots, and a figure that was correct on the day
# of the audit should stay as written.
#
# This list was five entries long until 2026-08-08, and zk-mldsa/README.md was
# not one of them — so it sat for a week claiming the on-chain proof cost
# "~230k gas" in three places while quoting the measured 1 196 224 in a table
# on the same page. The gas check had been passing the whole time, on the
# files it happened to know about.
DOCS = ["README.md", "SUBMISSION.md", "SECURITY.md",
        "docs/PITCH_DECK.md", "docs/DEMO_VIDEO_SCRIPT.md",
        "DEPLOY_RUNBOOK.md",
        "zk-mldsa/README.md", "zk-mldsa/contracts/README.md"]
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

    docs = text(["README.md", "SUBMISSION.md", "SECURITY.md"])
    for path in ("README.md", "SUBMISSION.md"):
        check(oh[2:] in docs[path], f"{path} documents the real orderHash", oh[:18] + "…")

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


def check_demo_video() -> None:
    """The video's storyboard points at deck slides BY NUMBER, and the docs
    quote its duration. Inserting a slide silently repoints every later scene:
    on 2026-08-05 the closing "Ask" moved from page 12 to page 19 and the video
    kept rendering page 12 — the competitor table — as its call to action.
    Nothing failed, because nothing checked."""
    print("\n[video] storyboard points where it claims, duration matches the docs")
    sys.path.insert(0, str(ROOT / "scripts"))
    try:
        import build_demo_video as bdv                    # noqa: PLC0415
    except ImportError as e:                              # noqa: PERF203
        # A missing build-only dependency is not a false claim. Say so, and
        # do not pretend the storyboard was verified.
        print(f"    storyboard not importable here ({e}) — skipping scene check")
        return
    try:
        bdv.validate_timeline()
        check(True, "every scene points at the slide it names")
    except SystemExit as e:
        check(False, "every scene points at the slide it names", str(e).splitlines()[1:2])

    expected = sum(hold for _src, hold, _l in bdv.TIMELINE)
    mp4 = ROOT / "docs/DEMO_VIDEO.mp4"
    if not mp4.exists():
        check(False, "docs/DEMO_VIDEO.mp4 present"); return
    import struct                                          # noqa: PLC0415
    d = mp4.read_bytes()
    i = d.find(b"mvhd")
    ver = d[i + 4]
    ts, dur = (struct.unpack(">II", d[i + 16:i + 24]) if ver == 0
               else struct.unpack(">IQ", d[i + 24:i + 36]))
    actual = dur / ts
    check(abs(actual - expected) < 1.5, "video duration matches the storyboard",
          f"{actual:.1f}s vs {expected:.1f}s")
    for path, body in text().items():
        for claimed in set(re.findall(r"(\d{2,3})[- ]second", body)):
            check(abs(int(claimed) - actual) < 1.5, f"{path} claims a {claimed}s video",
                  f"actual {actual:.1f}s")


# ---------------------------------------------------------------------------
# Superseded values: the registry that replaces "remember to grep for it".
#
# Every corrected figure goes here, permanently. The check below scans EVERY
# tracked file — not just the docs someone thought to list — so a value cannot
# be fixed in the four files that happen to be open and declared done.
#
# This exists because prose did not work. The rules "after a find-and-replace,
# grep for the TERM" and "changing a shared value means finding EVERY consumer"
# were already written down after a previous session. The 230k gas overclaim was
# then corrected in four markdown files and asserted fixed repo-wide, while it
# survived in zk-mldsa/README.md, MLDSAAttestation.sol and the zkVM guest. A
# rule you have to remember is not a control. A check that runs is.
#
# To add one: append (regex, correct_value, why_it_was_wrong). Never delete.
SUPERSEDED_VALUES: list[tuple[str, str, str]] = [
    (r"~?\s*230\s*[k,]\s*(?:-\s*)?gas|230,000\s*gas",
     "1,196,224 gas", "never measured; the attest receipt says 1196224"),
    (r"\b105 (?:tests|automated)\b|\b84 tests\b|\b279 tests\b|"
     r"\b110 Python tests\b|Two hundred seventy-nine",
     "323 tests (154 Python + 169 Foundry)",
     "counts before the verifier's own 44 self-tests were added"),
    (r"81[- ]second",
     "90-second", "the demo video gained a scene and is now 90.0s"),
    (r"fe44195b",
     "d8bf1551…", "superseded order digest; the shipped order is the mainnet one"),
    (r"not yet on the hardware path|not in current HW path",
     "xy_qaoa IS the hardware path", "the XY mixer produced both shipped runs"),
    (r"depth-2 (?:QAOA|penalty)",
     "reps=3 XY-ring mixer", "both shipped runs are reps=3 XY"),
    (r"lastHash\[(?:deployer|anchorer)\]\s*(?:returns|==)",
     "execCommitmentOf[anchorer][orderHash]",
     "lastHash is last-write-wins and rots; execCommitmentOf is keyed by order"),
]

# A line may legitimately mention a superseded value when it is EXPLAINING the
# correction, or inside a dated snapshot that should stay as written.
# tests/test_verify_claims.py necessarily CONTAINS every superseded value —
# they are the probes. Excused explicitly rather than left to survive on
# incidental excuse words happening to sit nearby, which is what it was
# doing until 2026-08-08.
SUPERSEDED_EXCUSED_FILES = ("AUDIT_", "zk-mldsa/vendor/", "verify_claims.py",
                            "tests/test_verify_claims.py")
# NOTE: do NOT add a bare "# " here. It was present until 2026-08-08 to excuse
# code comments, but in markdown it matches every heading — so a stale value
# within the context window of ANY heading was silently excused. A planted
# "230k gas" two lines under "## License" reported PASS. The explanatory words
# below are what legitimately excuse a mention; a comment marker is not one.
SUPERSEDED_EXCUSED_LINE = re.compile(
    r"earlier draft|was never measured|superseded|historical|as of the|"
    r"no longer|used to|previously|deprecated|do NOT add|reported PASS", re.I)


def find_superseded(text: str, pattern: str) -> list[int]:
    """Return 1-indexed line numbers where `pattern` appears un-excused.

    Pure and filesystem-free so the TEST SUITE can exercise it directly. That
    matters: this gate silently stopped working once already. A bare "# " in
    the excuse regex matched every markdown heading, and because the excuse is
    judged over a context window, any stale value within four lines of any
    heading was waved through — 1 of 7 probes caught. Nothing noticed until a
    human asked what had actually been run. tests/test_verify_claims.py now
    plants every registry value next to a heading and asserts it is caught, so
    the verifier is verified on every commit rather than on request.
    """
    rx = re.compile(pattern, re.I)
    lines = text.splitlines()
    out = []
    for i, line in enumerate(lines, 1):
        if not rx.search(line):
            continue
        # Judge the CONTEXT, not the line: the sentence explaining why a value
        # is superseded usually sits on the following line, and a historical
        # block is marked once at its top.
        window = "\n".join(lines[max(0, i - 4):i + 4])
        if SUPERSEDED_EXCUSED_LINE.search(window) or "<details>" in window:
            continue
        out.append(i)
    return out


def check_superseded_values() -> None:
    """No corrected value may reappear anywhere in the tree."""
    print("\n[superseded] corrected values have not crept back")
    tracked = subprocess.run(["git", "ls-files"], cwd=ROOT,
                             capture_output=True, text=True).stdout.split()
    binary = (".png", ".pdf", ".mp4", ".jsonl", ".json", ".webp", ".ico")
    readable = []
    for f in tracked:
        if f.startswith(SUPERSEDED_EXCUSED_FILES) or f.endswith(binary):
            continue
        try:
            readable.append((f, (ROOT / f).read_text(errors="ignore")))
        except (OSError, IsADirectoryError):
            continue
    for pattern, correct, why in SUPERSEDED_VALUES:
        hits = [f"{f}:{n}" for f, body in readable
                for n in find_superseded(body, pattern)]
        check(not hits, f"superseded {pattern[:34]!r} -> {correct}",
              f"{why}; found at {', '.join(hits[:3])}" if hits else why)


def check_doc_coverage() -> None:
    """Every live .md must be under the gate, or explicitly excused.

    The gas check cannot catch a stale figure in a file it never opens. Rather
    than trust that DOCS stays complete, enumerate what git tracks and fail on
    anything unaccounted for."""
    print("\n[coverage] every live document is under the gate")
    tracked = subprocess.run(["git", "ls-files", "*.md"], cwd=ROOT,
                             capture_output=True, text=True).stdout.split()
    excused_prefix = ("AUDIT_",)          # dated snapshots, frozen on purpose
    excused_dir = ("zk-mldsa/vendor/",)   # third-party
    for f in tracked:
        if f.startswith(excused_prefix) or f.startswith(excused_dir):
            continue
        check(f in DOCS, f"{f} is checked by this script",
              "" if f in DOCS else "add it to DOCS or excuse it explicitly")


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
                # Only figures presented as the ATTEST cost. A deploy-cost
                # estimate or a block gas limit is a different, legitimate
                # number, and flagging those trained the reader to ignore this
                # check — the same failure as the test-count false positive.
                ctx = re.compile(r"(attest|groth16|zk|proof|on-chain (?:pq|post-quantum|"
                                 r"signature|verification)|ml-dsa verification)", re.I)
                # Match BOTH "1,196,224 gas" and abbreviated "~230k gas" /
                # "1.2M gas". The original defect was written in the
                # abbreviated form, so a checker that only understood full
                # figures would have sailed straight past the very bug it
                # exists to catch. Verified by mutation.
                num = re.compile(r"([\d,\s]{3,12}|\d+(?:\.\d+)?\s*[kKmM])\s*gas")
                for path, body in text().items():
                    for m in re.finditer(num, body):
                        raw = m.group(1).strip().replace(",", "")
                        if raw[-1] in "kK":
                            v = str(int(float(raw[:-1].strip()) * 1_000))
                        elif raw[-1] in "mM":
                            v = str(int(float(raw[:-1].strip()) * 1_000_000))
                        else:
                            v = raw.replace(" ", "")
                        if not (v.isdigit() and 100_000 < int(v) < 10_000_000):
                            continue
                        window = body[max(0, m.start() - 260):m.end() + 120]
                        # Negative guard first: a deployment cost or a block
                        # gas limit is a different number that legitimately
                        # sits near attest vocabulary — including in a label
                        # that exists precisely to say "this is NOT that".
                        if re.search(r"deploy\w*\s+cost|block gas limit|"
                                     r"not the attest|deployment estimate|"
                                     r"nativ\w+|literature|estimated at|"
                                     r"pure-solidity|would cost",
                                     window, re.I):
                            continue
                        if not ctx.search(window):
                            continue
                        check(abs(int(v) - gas) < 1000,
                              f"{path} attest gas figure {v}", f"actual {gas}")


def main() -> int:
    print("Verifying documented claims against chain, artefacts and tests.")
    check_artifact_metrics()
    check_execution_binding()
    check_reviewer_commands()
    check_demo_video()
    check_doc_coverage()
    check_superseded_values()
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
