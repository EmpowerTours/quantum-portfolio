#!/usr/bin/env python3
"""Verify every hard claim in the judge-facing docs against its source.

Written because the same failure kept recurring: a number would be corrected in
one document and left stale in three others, or a figure would be asserted that
no artefact supported. Each was found by chance. This finds them on demand.

Sources of truth, in order of authority:
  1. the chain          (contract code, transaction receipts)
  2. shipped artefacts  (outputs/*.json — raw counts recompute the metrics)
  3. the test suites    (actual pass counts)

Usage:  python verify_claims.py            (add --chain to include RPC checks,
                                            --rebuild-guest to rebuild the SP1
                                            guest and re-derive its vkey)
Exit code is non-zero if any claim fails, so CI can gate on it.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from collections import Counter
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

# 2026-08-25: MLDSAAttestationV2 replaced the v1 attestation, and because PQ()
# is immutable on both executors they had to move with it. AuditAnchorV2 is the
# only contract that survived unchanged.
#
# NOTE THE GAP THIS MAP CANNOT SEE. The six TXS below are the provenance trail,
# and they ran against the PREVIOUS executors under the v1 attestation — only
# the two anchor() calls hit a contract still in this map. So "live" here means
# "this is what a new order would execute against", NOT "this is what the cited
# proofs demonstrate". Both facts are true and the documents must state which is
# which; a reader who conflates them has been misled.
LIVE = {
    "AuditAnchorV2":       "0x8422b555DCE11913A4657C2f47C839637FC71ffd",
    "UniswapRoutingVault": "0xcC60db5E123Cb3150d5F11CA5526a79B4f31113F",
    "MorphoSupplyAdapter": "0x6D42fA32880aDd1d794abBF98c5Cd104Fe332D89",
    "MLDSAAttestationV2":  "0xFeEf24A5dBF43E9dE8AC0d0EaB0f0141E980A52c",
}
SUPERSEDED = ["0x4cb79cc36b367a6fd7363bc6a8553a7a270da27c",
              "0xe2fcada067227c817b8a47b850d727ba065e16dd",
              "0xB1a4341403DA395760561B85C4C96696C0D15958",
              "0xc1a82D8C4D28Eca8B318D1bac8DCc2Ab963b3839",
              # Retired 2026-08-10: these two accept an execution the PQ
              # signature never authorised (RT12). They are immutable with no
              # upgrade path, which is why shipping the fix meant new
              # addresses rather than a patch.
              "0x06F233062eE23590e5CC873df511024f3d981e56",
              "0x8d5AE2f23E5d20bFb7915168d6b2a3Ce753fE49E",
              # Retired 2026-08-25 by the MLDSAAttestationV2 migration. These
              # still hold the provenance trail, so unlike the pairs above they
              # are cited on purpose — but every citation has to say they are
              # the retired ones, which is exactly what this gate enforces.
              "0xDaEa22D6DCB37FBF1462d6d08ADE40A8fAc05144",
              "0xE3de921790d04656F2640fA1eDD75492e911Ffa6",
              "0xb0aADaFe68647578520E988b4444e556c300b4Da"]
# Two orders, not one. AuditAnchorV2 stores exactly one execution commitment
# per (user, orderHash) and refuses to re-anchor, and both executors read that
# same slot expecting to find THEIR OWN commitment — so the routing leg and the
# yield leg cannot share an orderHash. Each therefore needs its own ML-DSA
# signature, its own Groth16 proof and its own attestation. That is the direct
# cost of the M-6 fix, and it is the honest shape of the system.
TXS = {
    "attest(route)":   "0x12b7cd0cdda7b4d2c2a5b049e71265e6464c286e643a5524ee3825ef1f277429",
    "anchor(route)":   "0xcf0cdd9f8790eebf1522bb4b36c445d46e15b4e5aa3377038bae941cd5f5a8e7",
    "executeAndRoute": "0xb6970f574b9e9f95f55c80707869c017244a87467023c1a4181687b2cac0e85e",
    "attest(supply)":  "0xc6ff8b7c7c8e83f07cd015b5f353eb4cd0af9f4bf2ddee4b200138a5968a2a57",
    "anchor(supply)":  "0x5698683a27b6d6a202d5d73c016c6fe65432693ae9e7f1913815c40b8e455552",
    "supply":          "0x6a221f1176a5364381de994452af8bac4546aacc981ebaabd24699d370e0b3eb",
}

# ---------------------------------------------------------------------------
# The SP1 guest is consensus-critical bytes, not source.
#
# MLDSAAttestation pins `mldsaProgramVKey` as an IMMUTABLE and the vkey is a
# hash of the compiled guest ELF, so any change that moves the ELF by one byte
# silently invalidates every proof the deployed contract will ever accept.
# attest() reverts, and the only remedy is redeploying the attestation AND both
# executors, because PQ() is immutable on those too.
#
# Not theoretical. Commit 1e2ec67 rewrote a `//!` doc comment in
# program/src/main.rs from three lines to four to correct a gas figure. It
# changed no logic and no string that any code reads. But
# `.expect("ML-DSA-65 verification failed")` embeds a
# core::panic::Location{file, line, col} as static data, so shifting every line
# below it down by one changed the ELF, the vkey, and therefore the on-chain
# identity of the program. It went unnoticed for four days and surfaced only
# when a freshly proved fixture would not attest — after the proving box had
# already been paid for.
#
# GUEST_SOURCE_DIGEST covers every file the guest build reads. It is
# deliberately a SUPERSET of what can move the vkey: an edit that leaves the
# ELF alone still trips it. A false alarm costs one --rebuild-guest run. A miss
# costs a redeploy.
GUEST_VKEY = "0x00ed29f3eb27b863b25c2619776ecc56c8c84e90b7da27250c8317cc2758cbd5"
GUEST_ELF_SHA256 = "d82d45eed9f1388d20079446be4acc695cfe99f9ab168b9847c26188ac61c902"
GUEST_SOURCE_DIGEST = "35d0fdbac7de5a4272251c34baa2a7ffeae5c4e3ae3d5544147611a65af1b99d"
GUEST_INPUT_GLOBS = ("Cargo.toml", "Cargo.lock", "rust-toolchain",
                     "script/build.rs",
                     "program/Cargo.toml", "program/src/**/*.rs",
                     "lib/Cargo.toml", "lib/src/**/*.rs",
                     "vendor/keccak/Cargo.toml", "vendor/keccak/src/**/*.rs")
# Superseded guest builds. Each is a different SOURCE state — NOT a toolchain
# difference. The build reproduces byte-for-byte across machines and across
# docker/non-docker, which is the opposite of what 1183bbc concluded when it
# added `docker: true` to fix a non-existent nondeterminism.
STALE_VKEYS = {
    "0x00364772d1d557782109c04c8041ea0b05fb55705356a621d37c35d6ecdaba72":
        "pre-7ea4020 guest, ELF 87ece7e0... (2026-07-28)",
    "0x00aa9611944c5e6c493d79011881d42dc28126e0de50a5f4dae1373e3b06c169":
        "post-1e2ec67 guest, ELF eccfe103... (the four-day comment drift)",
}
# v1 is retired but pins the SAME vkey, so it is a second independent witness
# that the repo and the chain still agree.
VKEY_PINNED_BY = {
    "MLDSAAttestationV2":   LIVE["MLDSAAttestationV2"],
    "MLDSAAttestation(v1)": "0xb0aADaFe68647578520E988b4444e556c300b4Da",
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
    # GLOB, not a hardcoded pair. The list named exactly two files, so the
    # 2026-08-17 CVaR/mean hardware pair was quoted in SUBMISSION.md while
    # sitting outside the only check that recomputes P(optimal) from raw
    # counts. Any artefact this repo cites has to be inside the gate, and a
    # new filename must not be able to opt itself out by existing.
    found = sorted(ROOT.glob("outputs/hardware_run*.json"))
    check(bool(found), "hardware artefacts present")
    for p in found:
        f = p.relative_to(ROOT).as_posix()
        d = json.loads(p.read_text())
        n, k = len(d["tickers"]), d["budget"]
        opt = set(d["optimal"]["selection"])

        # Is the stated optimum ACTUALLY optimal? Everything below measures
        # P(optimal) *relative to* this selection, so if it is wrong every
        # quantum number in the submission is measuring the wrong bitstring.
        # Brute-force it from the problem inputs when they are shipped.
        if "mu" in d and "sigma" in d:
            import itertools                                  # noqa: PLC0415
            mu, sig = d["mu"], d["sigma"]
            q = d.get("risk_factor", 0.5)
            def obj(sel):
                return (q * sum(sig[i][j] for i in sel for j in sel)
                        - sum(mu[i] for i in sel))
            best = min(itertools.combinations(range(n), k), key=obj)
            check(set(best) == opt, f"{Path(f).stem}: stated optimum IS optimal",
                  f"brute force says {sorted(best)}, artefact says {sorted(opt)}")
            check(abs(obj(best) - d["optimal"]["objective"]) < 1e-6,
                  f"{Path(f).stem}: optimal objective recomputes",
                  f"{obj(best):.6f} vs {d['optimal']['objective']:.6f}")
        else:
            print(f"    {Path(f).stem}: mu/sigma NOT shipped — the stated "
                  "optimum cannot be checked, only trusted")
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


# Spelled-out counts are claims too. The narration in docs/DEMO_VIDEO_SCRIPT.md
# said "Three hundred forty-two tests" for a day after every digit in the repo
# had been bumped to 355, because the scanner only ever read digits and the
# recording instructions are prose by nature. A number a human will SPEAK is
# exactly the kind that gets missed, so it gets read here.
_ONES = {"one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
         "seven": 7, "eight": 8, "nine": 9}
_TEENS = {"ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
          "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
          "eighteen": 18, "nineteen": 19}
_TENS = {"twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
         "seventy": 70, "eighty": 80, "ninety": 90}
SPELLED_COUNT = re.compile(
    r"\b(?:(%s)\s+hundred)(?:\s+(?:and\s+)?((?:%s)(?:[- ](?:%s))?|(?:%s)|(?:%s)))?"
    r"\s+(?:automated\s+)?tests?\b"
    % ("|".join(_ONES), "|".join(_TENS), "|".join(_ONES),
       "|".join(_TEENS), "|".join(_ONES)), re.I)


def spelled_to_int(hundreds: str, rest: str | None) -> int:
    """Parse the "three hundred fifty-five" forms SPELLED_COUNT captures."""
    n = _ONES[hundreds.lower()] * 100
    if not rest:
        return n
    for word in re.split(r"[- ]", rest.lower()):
        n += _ONES.get(word) or _TEENS.get(word) or _TENS.get(word, 0)
    return n


def check_cited_artefacts_are_shipped() -> None:
    """Every outputs/ file a document names must be TRACKED, not just present.

    `outputs/*` is gitignored with an explicit allowlist, which is the right
    default — but it means a new artefact is invisible to git unless someone
    remembers to admit it. On 2026-08-17 both hardware artefacts behind the
    CVaR reversal were cited by name in SUBMISSION.md and would have shipped
    to nobody: present on the author's disk, absent from every clone. A local
    existence check would have passed. Only `git ls-files` catches it.
    """
    print("\n[evidence] artefacts cited by the docs are tracked")
    cited: dict[str, set[str]] = {}
    for path, s in text().items():
        # `jsonl` BEFORE `json`, plus \b: the greedy class swallows the whole
        # name and backtracks, so a "json"-first alternation matches
        # outputs/audit_log.json inside the real outputs/audit_log.jsonl and
        # reports a tracked file as missing.
        for m in re.findall(r"outputs/[A-Za-z0-9_.\-]+\.(?:jsonl|json|png)\b", s):
            cited.setdefault(m, set()).add(path)
    if not cited:
        check(False, "docs cite at least one artefact"); return
    r = subprocess.run(["git", "ls-files"], cwd=ROOT, capture_output=True, text=True)
    tracked = set(r.stdout.split())
    for art in sorted(cited):
        where = ", ".join(sorted(cited[art]))
        check(art in tracked, f"{art} tracked (cited by {where})",
              "cited by a document but not tracked — it would be missing from "
              "every clone. Add a `!` allowlist line to .gitignore.")


# A gate that dies with a raw TimeoutExpired traceback reports a red build for
# an unhelpful reason: on a loaded machine this printed "103 PASS, 0 FAIL" and
# then crashed with exit 1, which reads as a broken checker rather than a slow
# one. A timeout is a FAILED CHECK with a name, like every other outcome here.
def _run_or_fail(cmd, *, cwd, timeout, what, env=None):
    """Run `cmd`; on timeout or launch failure record a FAIL and return None."""
    try:
        return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True,
                              env=env, timeout=timeout).stdout
    except subprocess.TimeoutExpired:
        check(False, f"{what} completed within {timeout}s",
              "the suite did not finish — re-run on an idle machine, or raise "
              "the timeout; the counts were NOT verified")
        return None
    except OSError as e:
        check(False, f"{what} could be launched", str(e))
        return None


# The count scanner, as named patterns so tests can import and attack them
# rather than re-declaring a copy that drifts from the real one.
#
# Three shapes escaped the original `(\d{2,4})[- ]tests?\b`, and all three were
# stale in the repo while this gate reported PASS:
#   1. The count in PARENTHESES AFTER the word — "# 1. Python tests (155)."
#      A number-before-word scanner structurally cannot see it.
#   2. An HTML TAG as the separator — "<div>279<small>tests passing" in the
#      pitch deck, whose PDF is the judge-facing artefact.
#   3. Language counts JOINED, with "tests" appearing only once for the pair —
#      "189 Python + 181 Foundry". The second number has no noun after it.
COUNT_BARE = re.compile(r"(\d{2,4})(?:[-\s]|<[^>]{1,24}>)*tests?\b")
COUNT_PAREN = re.compile(r"tests?\s*\((\d{2,4})\)")
COUNT_LANG = re.compile(
    r"(\d{2,4})[-\s](?:Python|Foundry|Solidity)\b"
    r"(?=[-\s]tests?\b|\s*[+&]|\s*<|\s*\)|\s*,)")
COUNT_PATTERNS = (COUNT_BARE, COUNT_PAREN, COUNT_LANG)


def scan_counts(s: str) -> set:
    """Every test-count claim in `s`, by any of the shapes above."""
    return {v for v, _ in scan_counts_positioned(s)}


def scan_counts_positioned(s: str):
    """(value, offset) for each count, so callers can inspect its context."""
    return [(int(m.group(1)), m.start())
            for rx in COUNT_PATTERNS for m in rx.finditer(s)]


def check_test_counts() -> None:
    """The documented totals must equal what the suites actually report."""
    print("\n[tests] documented counts vs actual")
    py = _run_or_fail([sys.executable, "-m", "pytest", "tests/", "-q"],
                      cwd=ROOT, timeout=900, what="pytest")
    if py is None:
        return
    m = re.search(r"(\d+) passed", py)
    npy = int(m.group(1)) if m else -1
    if not shutil.which("forge", path=f"{Path.home()}/.foundry/bin:{os.environ.get('PATH','')}"):
        print("    forge not found — cannot verify the combined test count")
        check(False, "forge available for test-count verification",
              "install foundry, or run this where forge is on PATH")
        return
    # Count the SUITE, not one run of it. This used to read "(\d+) tests
    # passed" from a forge run carrying the full fork env, which made the
    # documented total a function of live RPC behaviour: locally every fork
    # test ran and it reported 181, in CI three did not and it reported 178,
    # so every count claim in every document failed at once for a network
    # reason. "(N total tests)" is the same number bare, with an RPC only, and
    # with the full fork env — which is what "181 Foundry tests" actually
    # means. No fork env is passed, so this neither needs nor touches a chain.
    env = {"PATH": f"{Path.home()}/.foundry/bin:{os.environ.get('PATH','')}"}
    fo = _run_or_fail(["forge", "test"], cwd=ROOT / "contracts",
                      timeout=1800, what="forge test", env=env)
    if fo is None:
        return
    m = re.search(r"\((\d+) total tests\)", fo)
    nfo = int(m.group(1)) if m else -1
    total = npy + nfo
    print(f"    actual: {npy} Python + {nfo} Foundry = {total}")
    # A document may legitimately cite a per-suite count ("169 tests, 0
    # skipped" next to `forge test`) as well as the combined total. Only a
    # number matching none of the three is a stale claim. Without this the
    # checker flags true statements, which trains people to ignore it.
    #
    # Per-FILE counts are legitimate for the same reason: README annotates the
    # tree with "test_verify_claims.py  50 tests OF THE VERIFIER". Those are
    # collected rather than hardcoded, so adding a test to a file that a doc
    # counts fails here instead of quietly making the annotation a lie.
    coll = _run_or_fail([sys.executable, "-m", "pytest", "tests/", "-q",
                         "--collect-only"],
                        cwd=ROOT, timeout=900, what="pytest --collect-only")
    if coll is None:
        return
    per_file = Counter(line.split("::", 1)[0] for line in coll.splitlines()
                       if "::" in line)
    valid = {total, npy, nfo} | set(per_file.values())
    # The old pattern required "tests," / "tests passing" / "tests total", so
    # "# 154 tests" at the end of a reviewer command line and "342 tests**" in
    # a markdown table cell both sat stale through every run of this gate. A
    # count is a count wherever the sentence happens to end.
    for path, s in text().items():
        # Two shapes. The bare one, plus SUITE TOTALS that name their language:
        # the repo said "154 Python tests" while the suite reported 189, and a
        # bare `(\d+) tests` scanner cannot see a word in between.
        #
        # Deliberately NOT any word: "70 adversarial tests" and "11 guard
        # tests" are SUBSET counts, and "12 fork tests" counts what skips.
        # Those are true statements about parts, so admitting them here would
        # force every subset into `valid` and license any number at all.
        for claimed, at in scan_counts_positioned(s):
            # A count explicitly dated to a past state is a true statement
            # about history, not a stale claim. DEPLOY_RUNBOOK records "142
            # Solidity, 85 Python (as of the 2026-07-30 deploy)" on purpose.
            # This reuses the same excuse the superseded-value gate already
            # applies, rather than narrowing the pattern until the sentence
            # stops matching — which is how a gate goes quietly blind.
            window = s[max(0, at - 200): at + 200]
            if SUPERSEDED_EXCUSED_LINE.search(window) or "<details>" in window:
                continue
            check(claimed in valid, f"{path} test count {claimed}",
                  f"expected one of {sorted(valid)} (total {total})")
        for hundreds, rest in set(SPELLED_COUNT.findall(s)):
            claimed = spelled_to_int(hundreds, rest)
            check(claimed in valid, f"{path} spelled test count {claimed}",
                  f"'{hundreds} hundred {rest}'.strip() — expected one of "
                  f"{sorted(valid)} (total {total})")
    check_skip_claims_are_qualified()


# "0 skipped" is true only with a Monad RPC endpoint. Without one the 11 fork
# tests skip, and an unqualified claim reads as full coverage to a reviewer who
# ran `forge test` bare and saw 170/11. The counts above were already gated;
# this sentence was not, so it survived the commit that made fork tests skip
# honestly and had to be corrected by hand afterwards.
_SKIP_ANY = re.compile(r"(?:\b0\b|none|nothing)\s+skip(?:s|ped)?", re.I)
# The qualifier may sit on either side of the claim ("0 skipped with an RPC
# endpoint", "with MONAD_RPC_URL set, nothing skips"), so match the window
# rather than a fixed order — a one-sided regex fails the correct phrasings.
# Naming an RPC endpoint is NOT enough, and accepting it is why every "0
# skipped with an RPC endpoint" claim in the repo was wrong at once: with
# MONAD_RPC_URL alone the fork suites used to fail outright, and after the
# self-skip fix they still leave 10 skipped. A "0 skipped" claim is only true
# when the pool parameters are set too, so the qualifier has to name them.
_SKIP_QUALIFIER = re.compile(
    r"FORK_TOKEN_OUT|FORK_FEE|fork env(?:ironment)?|pool param", re.I)


def check_skip_claims_are_qualified() -> None:
    """A "0 skipped" claim must name the condition under which it is true."""
    print("\n[skips] every '0 skipped' claim names its precondition")
    for path, s in text().items():
        for m in _SKIP_ANY.finditer(s):
            window = s[max(0, m.start() - 160): m.end() + 160]
            check(bool(_SKIP_QUALIFIER.search(window)),
                  f"{path} '{m.group(0)}' qualified",
                  "name the fork env (MONAD_RPC_URL + FORK_TOKEN_OUT + FORK_FEE) "
                  "— bare `forge test` skips 12 fork tests, and an RPC endpoint "
                  "on its own still leaves 10")


def check_replication() -> None:
    """Recompute the replication's headline numbers from its raw counts.

    The negative result gets the same treatment as the positive ones it
    corrects: every figure in the write-up must recompute from shipped data,
    or it is just an assertion with a table around it.
    """
    print("\n[replication] the negative result recomputes from raw counts")
    f = ROOT / "outputs/replication_marrakesh_interleaved.json"
    if not f.exists():
        check(False, "outputs/replication_marrakesh.json present"); return
    import statistics as st                                   # noqa: PLC0415
    from scipy.stats import wilcoxon                           # noqa: PLC0415
    d = json.loads(f.read_text())
    pairs = d["pairs"]
    check(len(pairs) == 10, "10 paired runs shipped", f"{len(pairs)}")
    raw = [p["raw_hits"] for p in pairs]
    mit = [p["mit_hits"] for p in pairs]

    # hits must agree with the raw counts, not just be asserted
    n_assets, k = len(d["tickers"]), d["budget"]
    opt = set(d["optimal_selection"])
    for arm, key in (("raw", "raw_counts"), ("mit", "mit_counts")):
        for i, p in enumerate(pairs):
            c = p.get(key)
            if not c:
                continue
            hits = sum(v for bs, v in c.items()
                       if {j for j in range(n_assets) if bs[::-1][j] == "1"} == opt)
            if hits != p[f"{arm}_hits"]:
                check(False, f"{arm} hits recompute (pair {i+1})",
                      f"{hits} vs {p[f'{arm}_hits']}")
                return
    check(True, "every pair's hit count recomputes from its raw counts")

    _, pw = wilcoxon(mit, raw)
    md = sum(m - r for r, m in zip(raw, mit)) / len(pairs)
    check(pw < 0.05 and md < 0,
          "mitigation significantly HARMS, not helps",
          f"Wilcoxon p = {pw:.4f}, mean diff {md:+.2f}")
    worse = sum(1 for r, m in zip(raw, mit) if m < r)
    check(worse == 8, "mitigation worse in 8 of 10 interleaved pairs", f"{worse}/10")
    phi = st.variance(raw) / (st.mean(raw) * (1 - st.mean(raw) / d["shots"]))
    check(phi > 2.0, "run-to-run variance exceeds shot noise",
          f"dispersion x{phi:.1f}")
    for path, body in text().items():
        if "0.0094" in body:
            check(abs(pw - 0.0098) < 0.002, f"{path} quotes a real Wilcoxon p",
                  f"session-B p = {pw:.4f}")
            break


# The single-run mitigation lift is NOT a superseded value. It was really
# measured, and every document is supposed to keep showing it — deleting it
# would hide the correction rather than publish it. What it must never appear
# as again is a LIVE claim. So the rule here is proximity, not absence:
# wherever the figure is quoted, the reversal has to be in view.
#
# This exists because on 2026-08-10 the README, SUBMISSION and deck were all
# corrected within hours of the replication, while docs/DEMO_VIDEO_SCRIPT.md
# kept narrating "error mitigation tripled how often it found the optimum" and
# app.py's hardware tab kept calling replicated runs a future funded line item.
# Nothing failed, because every existing gate scanned markdown and the two
# stale surfaces were a narration table and a Streamlit caption.
RETRACTED_LIFT = re.compile(
    r"0\.00039|13\s*(?:→|->|to)\s*39|thirteen hits|"
    r"tripl(?:ed|ing) (?:how often|the hit)", re.I)
# Deliberately narrow. A loose pattern here (e.g. a bare "does not") would
# excuse almost any surrounding prose and make the gate decorative.
REVERSAL = re.compile(
    r"revers|replicat|0\.0094|0\.024|15 of 20|worse in|used to lead|"
    r"no longer|n\s*=\s*1", re.I)
RETRACTION_WINDOW = 700


def check_retracted_lift() -> None:
    """Every quote of the retracted lift must sit beside its reversal."""
    print("\n[retraction] the single-run lift never appears as a live claim")
    surfaces = dict(text())
    # The non-markdown surfaces are the ones that actually went stale.
    for extra in ("app.py", "run_replication.py"):
        if (ROOT / extra).exists():
            surfaces[extra] = (ROOT / extra).read_text()
    bad = 0
    for path, body in surfaces.items():
        for m in RETRACTED_LIFT.finditer(body):
            window = body[max(0, m.start() - RETRACTION_WINDOW):
                          m.end() + RETRACTION_WINDOW]
            if REVERSAL.search(window):
                continue
            bad += 1
            check(False,
                  f"{path}:{body[:m.start()].count(chr(10)) + 1} states the "
                  "retracted lift with no reversal in view", m.group(0))
    if not bad:
        check(True, "every mention of the retracted lift sits beside its "
                    f"reversal ({len(surfaces)} surfaces scanned)")


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

    # THE NEGATIVE PROOF. This is the block that silently died: it ran against
    # HEAD, the signed order's deadline passed, and both arms started returning
    # DeadlinePassed instead of the documented selectors. Nothing noticed for
    # ~10 hours. It is now pinned to the anchor block and CHECKED here, because
    # the document claims this block is executed on every commit.
    import re as _re                                            # noqa: PLC0415
    doc = (ROOT / "SUBMISSION.md").read_text()
    m = _re.search(r"--block (\d+) --rpc-url", doc)
    if not m:
        check(False, "reviewer block pins a historical block"); return
    blk = m.group(1)
    from src import pq_signing as _pq                            # noqa: PLC0415
    pre = "0x" + _pq.canonical_bytes(so.order.to_dict()).hex()
    ex = so.order.execution
    sig = ("executeAndRoute(bytes32,address[],uint24[],uint16[],"
           "uint256[],uint256,bytes)")
    base = [f"{fo}/cast", "call", ex.vault, sig, oh,
            "[" + ",".join(ex.token_outs) + "]",
            "[" + ",".join(map(str, ex.fee_tiers)) + "]",
            "[" + ",".join(map(str, ex.weights_bps)) + "]"]
    tail = [str(ex.deadline), pre, "--from", ex.user,
            "--value", str(ex.amount_in_wei), "--block", blk, "--rpc-url", RPC]

    ok_signed = subprocess.run(
        base + ["[" + ",".join(map(str, ex.amount_out_min)) + "]"] + tail,
        capture_output=True, text=True, timeout=180)
    tampered = subprocess.run(base + ["[1]"] + tail,
                              capture_output=True, text=True, timeout=180)
    blob = (tampered.stderr or "") + (tampered.stdout or "")

    # ARCHIVE DEPTH, NOT A BROKEN CLAIM. These two calls need the STATE at the
    # pinned block, and the public RPC prunes it — by 2026-08-25 the pin was
    # ~4.4M blocks back and both arms returned -32602. Reporting that as a
    # failed claim is worse than useless: the claim is fine, the endpoint
    # cannot answer, and a gate that cries wolf for environmental reasons is a
    # gate people learn to ignore.
    #
    # But it must not go quietly blind either. So the requirement TRANSFERS: if
    # the state is unreachable, the document must TELL the reader they need an
    # archive node, because otherwise they run a published command and get a
    # bare RPC error with no explanation. That is enforced, and the skip is
    # printed loudly.
    pruned = "historical state that is not available"
    if pruned in ((ok_signed.stderr or "") + blob):
        print(f"    SKIP  steps 5A/5B: block {blk} is past this RPC's pruning "
              f"horizon — NOT verified here; needs an archive endpoint")
        doc_warns = any(
            w in doc.lower() for w in ("archive node", "archive rpc",
                                       "archive endpoint", "pruning horizon"))
        check(doc_warns,
              "SUBMISSION.md warns that steps 5A/5B need an archive endpoint",
              "the pinned block's state is pruned on the public RPC, so a "
              "reviewer following these commands gets -32602 and no reason why")
    else:
        check(ok_signed.returncode == 0,
              "reviewer step 5A: the SIGNED execution succeeds at the pinned block",
              (ok_signed.stderr or "")[:90])
        check("0x1f9e3c96" in blob,
              "reviewer step 5B: the TAMPERED execution reverts ExecCommitmentMismatch",
              blob[:90])
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
    # Only durations presented as THE VIDEO's. "a ~12-second window" between
    # two QPU jobs is not a video claim, and flagging it teaches the reader to
    # ignore this check — the same false-positive failure as the gas figures.
    vid = re.compile(r"(video|walkthrough|storyboard|DEMO_VIDEO)", re.I)
    for path, body in text().items():
        for m in re.finditer(r"(\d{2,3})[- ]second", body):
            window = body[max(0, m.start() - 120):m.end() + 120]
            if not vid.search(window):
                continue
            check(abs(int(m.group(1)) - actual) < 1.5,
                  f"{path} claims a {m.group(1)}s video", f"actual {actual:.1f}s")


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
     r"\b110 Python tests\b|Two hundred seventy-nine|\b323 tests\b|\b328 tests\b|\b331 tests\b|\b334 tests\b|\b335 tests\b|\b336 tests\b|\b342 tests\b|\b154 tests\b|\b355 tests\b|\b399 tests\b|\b161 Python tests\b|\b174 Python tests\b|\b218 Python tests\b|Three hundred twenty-three|Three hundred thirty-five|Three hundred forty-two|Three hundred fifty-five|Three hundred ninety-nine",
     "424 tests (243 Python + 181 Foundry)",
     "counts before tests/test_cvar_qaoa.py added the CVaR tuning arm and the "
     "spoken-count probes grew tests/test_verify_claims.py; 154 and 342 "
     "outlived the first bump because the count scanner only read digits "
     "followed by a comma, and never read the spoken narration at all"),
    (r"81[- ]second",
     "90-second", "the demo video gained a scene and is now 90.0s"),
    (r"fe44195b|d8bf1551",
     "aee5fdf0… (route) / 051a10f5… (supply)",
     "digests of orders anchored on the RETIRED executors; the shipped orders "
     "are the ones bound under PQExecBinding on 2026-08-10"),
    (r"0x5caf7a40|executeAndRoute\(bytes32,address\[\],uint24\[\],uint16\[\],uint256\[\],uint256\)",
     "0x0a2c848a / executeAndRoute(…,uint256,bytes)",
     "the six-argument form predates the order-preimage binding and is the "
     "signature the deployed vault rejects"),
    (r"not yet on the hardware path|not in current HW path",
     "xy_qaoa IS the hardware path", "the XY mixer produced both shipped runs"),
    (r"depth-2 (?:QAOA|penalty)",
     "reps=3 XY-ring mixer", "both shipped runs are reps=3 XY"),
    (r"0x00364772d1d557782109c04c8041ea0b05fb55705356a621d37c35d6ecdaba72|"
     r"0x00aa9611944c5e6c493d79011881d42dc28126e0de50a5f4dae1373e3b06c169|"
     r"\b87ece7e02e2464947a30399983346d2da7a8182f176c065e5635414ea138a376\b|"
     r"\beccfe103ebebcd43480e42cafc83e5e60ef7357da663634da8a620fc2d0d7faf\b",
     "vkey 0x00ed29f3... / guest ELF d82d45ee...",
     "vkeys and ELF hashes of guest SOURCE STATES the chain does not pin; "
     "attest() reverts on every one of them, so a doc that quotes one is "
     "telling a reviewer to expect a proof that cannot verify"),
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


def check_relative_links() -> None:
    """Every relative link and image in a doc must resolve to a TRACKED file.

    Existing on disk is not enough: outputs/ is gitignored with an explicit
    allowlist, and outputs/hardware_vs_noise_stocks.png was generated by
    `make charts`, embedded in README.md, and never allowlisted. It rendered
    locally and 404'd on GitHub — so the README's only chart, showing the
    headline mitigation result, was broken for every reader of the repository
    while every other check passed.
    """
    print("\n[links] relative references resolve to tracked files")
    tracked = set(subprocess.run(["git", "ls-files"], cwd=ROOT,
                                 capture_output=True, text=True).stdout.split())
    rx = re.compile(r"!?\[[^\]]*\]\(([^)#]+?)\)")
    bad = []
    for f in DOCS:
        fp = ROOT / f
        if not fp.exists():
            continue
        base = Path(f).parent
        for m in rx.finditer(fp.read_text()):
            t = m.group(1).strip()
            if t.startswith(("http://", "https://", "mailto:")):
                continue
            rel = str((base / t)).replace("\\", "/").replace("./", "")
            if rel not in tracked:
                why = ("exists locally but is NOT TRACKED — 404 on GitHub"
                       if (ROOT / rel).exists() else "missing")
                bad.append(f"{f} -> {t} ({why})")
    check(not bad, "every relative link resolves to a tracked file",
          "; ".join(bad[:3]) if bad else "")


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


def guest_source_digest(root: Path | None = None) -> tuple[str, list[str]]:
    """SHA-256 over every file the SP1 guest build reads, path-tagged.

    Path-tagged so that renaming a file changes the digest, and NUL-delimited
    so that concatenation cannot be gamed by moving bytes across a boundary.

    `root` exists so the TEST SUITE can run this over a synthetic tree and
    prove the digest actually moves when a comment line is added — the defect
    it was written for. A test that could only read the real repo would have to
    edit it in place, which is unsafe with concurrent sessions and proves
    nothing on a clean checkout.
    """
    z = root if root is not None else ROOT / "zk-mldsa"
    files: list[Path] = []
    for pat in GUEST_INPUT_GLOBS:
        if "*" in pat:
            files.extend(sorted(z.glob(pat)))
        elif (z / pat).exists():
            files.append(z / pat)
    files = sorted(set(files))
    h = hashlib.sha256()
    for f in files:
        rel = f.relative_to(z).as_posix()
        h.update(rel.encode()); h.update(b"\0")
        h.update(f.read_bytes()); h.update(b"\0")
    return h.hexdigest(), [f.relative_to(z).as_posix() for f in files]


def check_guest_vkey() -> None:
    print("\n[guest] the SP1 guest still hashes to the vkey the chain pins")
    digest, files = guest_source_digest()
    # An empty or truncated input set would make the digest a constant that
    # matches nothing real, so assert the set is populated before trusting it.
    check(len(files) >= 10, "guest input set is populated", f"{len(files)} files")
    same = digest == GUEST_SOURCE_DIGEST
    check(same, "guest source digest unchanged",
          f"{len(files)} files" if same
          else f"{digest[:16]}... != pinned {GUEST_SOURCE_DIGEST[:16]}...")
    if not same:
        print("        A guest build input changed. If that was deliberate:")
        print("          python verify_claims.py --rebuild-guest")
        print("        and if the vkey moved, this is a REDEPLOY of the")
        print("        attestation and both executors, not a docs edit.")

    # The check that was missing on 2026-08-25. prove-both.sh validates a
    # fixture's orderHash and pkHash, PRINTS its vkey, and asserts nothing
    # about it — so a proof built from the drifted guest passed its own
    # validation, looked correct, and would have reverted on chain.
    fixdir = ROOT / "zk-mldsa/contracts/src/fixtures"
    fixtures = sorted(fixdir.glob("groth16-mldsa-*.json"))
    check(bool(fixtures), "groth16 ML-DSA fixtures present", str(fixdir))
    for f in fixtures:
        vk = json.loads(f.read_text()).get("vkey", "").lower()
        check(vk == GUEST_VKEY, f"fixture {f.name} carries the pinned vkey",
              "" if vk == GUEST_VKEY else STALE_VKEYS.get(vk, vk or "absent"))

    # A stale vkey or ELF hash in a document tells a reviewer to expect a value
    # that no build produces — the failure that stood for 24 days.
    # Superseded vkeys and ELF hashes are policed tree-wide by the
    # SUPERSEDED_VALUES registry. What that cannot see is a NEW wrong hash it
    # has never been told about, so assert directly that whatever a document
    # presents as the guest ELF is the one this source actually builds.
    for path, body in text().items():
        for m in re.finditer(r"[Gg]uest ELF SHA-?256\D{0,12}([0-9a-f]{64})", body):
            check(m.group(1) == GUEST_ELF_SHA256, f"{path} guest ELF hash",
                  f"documents {m.group(1)[:16]}..., built {GUEST_ELF_SHA256[:16]}...")

    if "--chain" in sys.argv:
        fo = f"{Path.home()}/.foundry/bin"
        for name, addr in VKEY_PINNED_BY.items():
            r = subprocess.run([f"{fo}/cast", "call", addr,
                                "mldsaProgramVKey()(bytes32)", "--rpc-url", RPC],
                               capture_output=True, text=True, timeout=120)
            onchain = r.stdout.strip().lower()
            check(onchain == GUEST_VKEY, f"{name} pins the repo vkey",
                  "" if onchain == GUEST_VKEY
                  else (onchain or r.stderr.strip()[:80] or "no response"))

    if "--rebuild-guest" in sys.argv:
        # Ground truth, and the only check here that can DERIVE the vkey rather
        # than compare pinned copies of it. Needs the SP1 toolchain and Docker,
        # which is why it is opt-in rather than part of every run.
        script = ROOT / "zk-mldsa/script"
        env = dict(os.environ)
        env["PATH"] = (f"{Path.home()}/.cargo/bin:{Path.home()}/.sp1/bin:"
                       + env.get("PATH", ""))
        protoc = Path.home() / ".local/protoc/bin/protoc"
        if protoc.exists():
            env["PROTOC"] = str(protoc)
        env.pop("SP1_SKIP_PROGRAM_BUILD", None)
        out = _run_or_fail(["cargo", "run", "--release", "--bin", "vkey"],
                           cwd=script, timeout=1800, what="guest rebuild", env=env)
        if out is not None:
            got = next((l.strip() for l in reversed(out.splitlines())
                        if re.fullmatch(r"0x[0-9a-f]{64}", l.strip())), "")
            check(got == GUEST_VKEY, "rebuilt guest derives the pinned vkey",
                  "" if got == GUEST_VKEY else STALE_VKEYS.get(got, got or "no vkey printed"))
            # Hash the ELF `include_elf!` actually embedded, not whatever is
            # lying around under target/ — a leftover from an earlier build
            # sits in a sibling directory and would fail this spuriously,
            # which is how a gate teaches people to ignore it.
            # Cargo keeps a build directory per build-script fingerprint, so
            # several `fibonacci-script-*/output` files coexist and all but the
            # newest are dead — the one just written by this rebuild is the one
            # whose path `include_elf!` embedded. Taking the newest rather than
            # asserting there is only one keeps the check from firing on
            # ordinary cargo housekeeping.
            outs = sorted((ROOT / "zk-mldsa/target/release/build")
                          .glob("fibonacci-script-*/output"),
                          key=lambda f: f.stat().st_mtime, reverse=True)
            embedded = next(
                (m.group(1) for out in outs
                 for m in [re.search(r"SP1_ELF_fibonacci-program=(\S+)",
                                     out.read_text(errors="ignore"))] if m), None)
            check(embedded is not None, "build script names the guest ELF",
                  f"{len(outs)} build outputs scanned")
            if embedded:
                e = Path(embedded)
                check(e.exists(), "embedded guest ELF exists", embedded)
                if e.exists():
                    sha = hashlib.sha256(e.read_bytes()).hexdigest()
                    check(sha == GUEST_ELF_SHA256, "embedded guest ELF sha256",
                          "" if sha == GUEST_ELF_SHA256
                          else f"{sha[:16]}... != {GUEST_ELF_SHA256[:16]}...")


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
    check_replication()
    check_retracted_lift()
    check_execution_binding()
    check_reviewer_commands()
    check_demo_video()
    check_relative_links()
    check_doc_coverage()
    check_superseded_values()
    check_addresses()
    check_test_counts()
    check_cited_artefacts_are_shipped()
    check_guest_vkey()
    if "--chain" in sys.argv:
        check_chain()
    print(f"\n{'ALL CLAIMS VERIFIED' if not fails else f'{len(fails)} FAILED:'}")
    for f in fails:
        print(f"  - {f}")
    return 1 if fails else 0


if __name__ == "__main__":
    raise SystemExit(main())
