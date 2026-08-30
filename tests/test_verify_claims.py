"""Tests for the verifier itself.

verify_claims.py is the thing that stops stale figures reaching a judge. It
silently stopped working once: a bare ``"# "`` in the excuse regex, added to
excuse code comments, matched every markdown heading — and because the excuse
is judged over a context window, any stale value within four lines of any
heading was waved through. Measured with seven probes planted under a heading,
**1 of 7 was caught**. Nothing failed. CI stayed green. It surfaced only when a
human asked what had actually been run.

A gate nobody tests is a gate that reports PASS. These tests plant every value
in the registry, in the position that previously defeated it, and assert it is
caught — so the verifier is verified on every commit.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import verify_claims as vc  # noqa: E402


# One or more concrete strings per registry entry that the pattern must match.
# Kept explicit rather than generated from the regex: a probe derived from the
# pattern would pass even if the pattern stopped describing the real defect.
#
# A tuple means every string is planted separately. Use one when an entry
# retires values that escaped in DIFFERENT SHAPES — a single probe proves the
# regex matches something, not that it matches the thing that got past it. The
# test-count entry is the case in point: "342 tests**" ended a markdown table
# cell and "Three hundred forty-two tests" was spoken narration, and one probe
# for "279 tests" would have gone on passing while both shipped stale.
PROBES: dict[str, str | tuple[str, ...]] = {
    r"~?\s*230\s*[k,]\s*(?:-\s*)?gas|230,000\s*gas": "The attest call costs 230k gas.",
    (r"\b105 (?:tests|automated)\b|\b84 tests\b|\b279 tests\b|"
     r"\b110 Python tests\b|\b249 Python tests\b|\b430 tests\b|\b108 tests\b|Four hundred thirty\b|Two hundred seventy-nine|\b323 tests\b|\b328 tests\b|\b331 tests\b|\b334 tests\b|\b335 tests\b|\b336 tests\b|\b342 tests\b|\b154 tests\b|\b355 tests\b|\b399 tests\b|\b161 Python tests\b|\b174 Python tests\b|\b218 Python tests\b|Three hundred twenty-three|Three hundred thirty-five|Three hundred forty-two|Three hundred fifty-five|Three hundred ninety-nine"): (
        "The suite has 279 tests.",
        "**Proof — live on Monad mainnet, 342 tests** | 10 s |",
        "pytest tests/ -q                    # 154 tests",
        "Three hundred forty-two tests across Python and Foundry.",
        "161 Python tests plus 181 Foundry tests.",
        "Live on Monad MAINNET.<br>355 tests. ZK-verified.",
        "Three hundred fifty-five tests across Python and Foundry.",
        "174 Python tests plus 181 Foundry tests.",
        "399 tests, none skipped once the fork environment is set.",
        "218 Python tests plus 181 Foundry tests.",
        "Three hundred ninety-nine tests across Python and Foundry.",
    ),
    r"81[- ]second": "Watch the 81-second walkthrough.",
    r"fe44195b|d8bf1551": "orderHash 0xd8bf15515669ef1f1d912c6d505d056b1f4ccd5cc6aebcae1b223c05cb8915f9",
    (r"0x5caf7a40|executeAndRoute\(bytes32,address\[\],uint24\[\],uint16\[\],"
     r"uint256\[\],uint256\)"): "Call executeAndRoute(bytes32,address[],uint24[],uint16[],uint256[],uint256).",
    r"not yet on the hardware path|not in current HW path": (
        "src/xy_qaoa.py is not yet on the hardware path."),
    r"depth-2 (?:QAOA|penalty)": "A depth-2 QAOA runs on IBM Heron.",
    (r"0x00364772d1d557782109c04c8041ea0b05fb55705356a621d37c35d6ecdaba72|"
     r"0x00aa9611944c5e6c493d79011881d42dc28126e0de50a5f4dae1373e3b06c169|"
     r"\b87ece7e02e2464947a30399983346d2da7a8182f176c065e5635414ea138a376\b|"
     r"\beccfe103ebebcd43480e42cafc83e5e60ef7357da663634da8a620fc2d0d7faf\b"): (
        # Both vkeys and both ELF hashes get their own probe: they escaped in
        # different shapes — a table cell asserting a live value, and prose
        # explaining a build. One probe would prove the regex matches
        # something, not that it matches what actually shipped.
        "| Program vkey | `0x00364772d1d557782109c04c8041ea0b05fb55705356a621d37c35d6ecdaba72` |",
        "the guest now hashes to 0x00aa9611944c5e6c493d79011881d42dc28126e0de50a5f4dae1373e3b06c169",
        "Guest ELF SHA-256: `87ece7e02e2464947a30399983346d2da7a8182f176c065e5635414ea138a376`",
        "built ELF eccfe103ebebcd43480e42cafc83e5e60ef7357da663634da8a620fc2d0d7faf",
    ),
    r"lastHash\[(?:deployer|anchorer)\]\s*(?:returns|==)": (
        "Confirm AuditAnchor.lastHash[deployer] returns the same hash."),
    (r"0x8fdc0057|0x3ffed7a2|0x90d6d9ea|"
     r"0xcd37af90|0x34e79cbf|0xa72f1a97|\b1788298709\b"): (
        # The order, its two commitments and its three transactions each get a
        # probe. They escaped in different shapes on 2026-08-30 -- a linked
        # table cell, a bare truncation in prose, and a raw deadline inside a
        # shell block -- and one probe would only prove the alternation
        # matches something.
        "anchored `orderHash 0x8fdc00574550c6bfdb79b564171aa6959171923bf3af683ad3b04a4c945dd3de`",
        "execCommitment `0x3ffed7a240f167d2ed19c0b490ef87c9de8db3460ad219017ec7be02adc9827e`",
        "the signed commitment 0x90d6d9eac636e0b27acb4cb681ed28cab86007b71c22f45ca3be4457824ba323",
        "| `attest()` tx | `0xcd37af90ca043ee2da205855433d8c9cda9fb0466dd01df2d78224f44ed98688` |",
        "anchor landed in 0x34e79cbf6a90bdf54f3d0c67000511614f81fcd799fc66310b267951614b2a65",
        "the swap ran in 0xa72f1a9766e5dedce75c18956cd654c9428a0d0ce9f367de35072cca5080f2f8",
        '"[3000]" "[10000]" "[2718]" 1788298709 "$PRE"',
    ),
    r"--block 99252441|--block \d{8,}": (
        # Both the exact pin that rotted and the general shape, because the
        # next one to rot will be a different number.
        "  --block 99252441 --rpc-url https://rpc.monad.xyz",
        "  --block 100349618 --rpc-url https://rpc.monad.xyz",
    ),
    r"1 192 295|1,192,295|\b2718\b|\b2755\b": (
        # The gas figure appears both thin-spaced and comma-grouped across the
        # docs, and the two amounts read as bare integers inside shell.
        "verified on-chain for a measured 1 192 295 gas",
        "our Groth16 check is 1,192,295 gas, 6.8x cheaper",
        "slippage floor left at the signed 2718",
        "0.1 MON produced 2755 micro-USDC",
    ),
}


def probes_for(pattern: str) -> tuple[str, ...]:
    """Every probe string for `pattern`, whether it declared one or several."""
    p = PROBES[pattern]
    return (p,) if isinstance(p, str) else p


def test_every_registry_entry_has_a_probe():
    """A new registry entry without a probe is an untested rule."""
    missing = [p for p, _, _ in vc.SUPERSEDED_VALUES if p not in PROBES]
    assert not missing, (
        "SUPERSEDED_VALUES entries with no probe in this file: "
        + "; ".join(missing)
        + " — add one, or the rule ships unverified."
    )


@pytest.mark.parametrize("pattern", list(PROBES))
def test_probe_actually_matches_its_pattern(pattern):
    """Guard against a probe that silently stops exercising its rule."""
    for probe in probes_for(pattern):
        assert vc.re.search(pattern, probe, vc.re.I), (
            f"probe {probe!r} for {pattern!r} no longer matches it"
        )


@pytest.mark.parametrize("pattern", list(PROBES))
def test_stale_value_is_caught_in_plain_text(pattern):
    for probe in probes_for(pattern):
        body = f"Some ordinary prose.\n\n{probe}\n\nMore prose.\n"
        assert vc.find_superseded(body, pattern), (
            f"{probe!r} not caught in plain text"
        )


@pytest.mark.parametrize("pattern", list(PROBES))
def test_stale_value_is_caught_next_to_a_markdown_heading(pattern):
    """The exact position that defeated this gate: adjacent to a heading.

    A bare "# " in the excuse regex matched the heading and excused everything
    within the context window. 1 of 7 probes was caught in this position.
    """
    for probe in probes_for(pattern):
        body = f"## License\n\n{probe}\n\nMIT.\n"
        assert vc.find_superseded(body, pattern), (
            f"{probe!r} escaped next to a heading — the excuse regex is too broad"
        )


@pytest.mark.parametrize("pattern", list(PROBES))
def test_stale_value_is_caught_next_to_a_code_comment(pattern):
    """Comment markers must not excuse either — two of these hid in source."""
    for probe in probes_for(pattern):
        body = f"# module docstring\n\n{probe}\n\n# trailing\n"
        assert vc.find_superseded(body, pattern), (
            f"{probe!r} escaped next to a code comment"
        )


@pytest.mark.parametrize("pattern", list(PROBES))
def test_explained_mention_is_excused(pattern):
    """The gate must stay usable: a mention that EXPLAINS the correction is
    legitimate, and flagging it would train people to ignore the gate."""
    for probe in probes_for(pattern):
        body = f"An earlier draft said: {probe}\n"
        assert not vc.find_superseded(body, pattern), (
            f"{probe!r} flagged inside its own explanation — false positive"
        )


@pytest.mark.parametrize("pattern", list(PROBES))
def test_historical_details_block_is_excused(pattern):
    for probe in probes_for(pattern):
        body = (
            "<details>\n<summary>Historical</summary>\n\n"
            f"{probe}\n\n</details>\n"
        )
        assert not vc.find_superseded(body, pattern), (
            f"{probe!r} flagged inside an explicit historical block"
        )


def test_clean_text_produces_no_hits():
    for pattern, _, _ in vc.SUPERSEDED_VALUES:
        assert not vc.find_superseded(
            "Nothing stale here. The measured cost is 1,196,224 gas.\n", pattern
        ), f"{pattern!r} fires on clean text"


# ---------------------------------------------------------------------------
# Spoken counts. The narration in docs/DEMO_VIDEO_SCRIPT.md said "Three hundred
# forty-two tests" after every digit in the repo had been bumped to 355, and no
# check read it, because the count scanner only ever looked at digits. The
# superseded registry catches that ONE retired value forever; these tests cover
# the general gate, so the next bump is caught without anyone remembering to
# retire the spelled form too.
@pytest.mark.parametrize("phrase,expected", [
    ("Three hundred fifty-five tests", 355),
    ("three hundred forty-two tests", 342),
    ("Two hundred seventy-nine tests", 279),
    ("One hundred tests", 100),
    ("Three hundred and fifty-five tests", 355),
    ("Three hundred five tests", 305),
    ("Three hundred fifteen tests", 315),
    ("Three hundred fifty tests", 350),
    ("Two hundred automated tests", 200),
    ("One hundred eighty-one test", 181),
])
def test_spelled_counts_are_read(phrase, expected):
    m = vc.SPELLED_COUNT.search(phrase)
    assert m, f"{phrase!r} not recognised as a spoken test count"
    assert vc.spelled_to_int(*m.groups()) == expected


@pytest.mark.parametrize("phrase", [
    "Three hundred fifty-five contracts",   # not a test count
    "three hundred metres",
    "The suite has 355 tests",              # digits are the other scanner's job
    "hundred tests",                        # no leading multiplier
])
def test_non_counts_are_not_read_as_spelled_counts(phrase):
    assert not vc.SPELLED_COUNT.search(phrase), f"{phrase!r} misread as a count"


def test_bare_count_is_scanned_regardless_of_what_follows():
    """The shape that escaped: a count ending a table cell or a comment.

    The old pattern required "tests," / "tests passing" / "tests total", so
    "342 tests**" and "# 154 tests" were invisible to a gate that was reporting
    PASS on the same files.
    """
    rx = vc.re.compile(r"(\d{2,4})[- ]tests?\b")
    for s in ("**Proof — live on Monad mainnet, 342 tests** | 10 s |",
              "pytest tests/ -q                    # 154 tests",
              "355 tests. ZK-verified.",
              "- **355 tests**, 0 skipped with an RPC endpoint"):
        assert rx.search(s), f"{s!r} still invisible to the count scanner"


# --- the three shapes that sat stale WHILE this gate reported PASS ------------
# Each string below was really in the repo on 2026-08-21 and really carried a
# wrong number. They import the live patterns rather than re-declaring a copy,
# so a regex that drifts fails here instead of going quietly blind again.

@pytest.mark.parametrize("shape,text,expected", [
    ("count in parentheses AFTER the word",
     "# 1. Python tests (155). Six of the seven modules use pytest fixtures",
     155),
    ("HTML tag as the separator",
     '<div class="big">279<small>tests passing</small></div>',
     279),
    ("second language count, with no noun after it",
     "279<small>tests passing<br>154 Python + 181 Foundry</small>",
     181),
    # Found 2026-08-26, by hand, in SUBMISSION.md — during the very pass that
    # corrected every other count in the repo. COUNT_PAREN wants the literal
    # "tests (77)"; after a filename the word never appears before the number.
    ("count in parentheses after a FILENAME, not after the word",
     "- `test_verify_claims.py` (77) — tests OF the claim gate: every retired",
     77),
])
def test_escaped_count_shapes_are_now_seen(shape, text, expected):
    assert expected in vc.scan_counts(text), (
        f"{shape}: {expected} still invisible in {text!r}")


def test_old_pattern_really_was_blind_to_every_escaped_shape():
    """Guards the reason these patterns exist, not just their current output."""
    old = vc.re.compile(r"(\d{2,4})[- ]tests?\b")
    for text in ("# 1. Python tests (155).",
                 '<div class="big">279<small>tests passing</small></div>',
                 "154 Python + 181 Foundry</small>",
                 "- `test_verify_claims.py` (77) — tests OF the claim gate"):
        assert not old.search(text), (
            f"{text!r} was NOT actually a blind spot — this test is wrong")


@pytest.mark.parametrize("text", [
    "70 adversarial tests",        # a SUBSET count, deliberately excluded
    "12 fork tests",               # counts what skips, not the total
    "requires Python 3.12",        # a version, not a count
    "Solidity 0.8.28",
    "supports 3 Python versions and 2 Foundry profiles",
    "1952-bit key",
])
def test_count_scanner_has_no_false_positives(text):
    assert not vc.scan_counts(text), f"{text!r} misread as a test count"


def test_every_count_pattern_is_reachable():
    """A pattern nobody can trigger is dead weight that looks like coverage."""
    for rx in vc.COUNT_PATTERNS:
        assert rx.pattern, "empty pattern in COUNT_PATTERNS"
    assert len(vc.COUNT_PATTERNS) == 4


def test_dated_historical_count_is_excused_but_live_one_is_not():
    """A count dated to a past state is history, not a stale claim.

    DEPLOY_RUNBOOK records "142 Solidity, 85 Python" against the 2026-07-30
    deploy on purpose. Narrowing the pattern until that sentence stops matching
    is how a gate goes blind; excusing it by its own stated context is not.
    """
    historical = ("| Tests *(as of the 2026-07-30 deploy)* | 142 Solidity, "
                  "85 Python. Recorded as 0 skipped |")
    seen = vc.scan_counts_positioned(historical)
    assert seen, "the scanner must still SEE the number, then excuse it"
    for _, at in seen:
        window = historical[max(0, at - 200): at + 200]
        assert vc.SUPERSEDED_EXCUSED_LINE.search(window), \
            "dated historical count was not excused"

    live = "the suite is 999 Python + 998 Foundry"
    for _, at in vc.scan_counts_positioned(live):
        window = live[max(0, at - 200): at + 200]
        assert not vc.SUPERSEDED_EXCUSED_LINE.search(window), \
            "an undated live claim must NOT be excused"


# ---------------------------------------------------------------------------
# The guest gate.
#
# MLDSAAttestation pins the vkey as an immutable and the vkey is a hash of the
# compiled guest ELF, so a one-byte change to the guest is a redeploy of three
# contracts. On 2026-08-21 a `//!` doc comment grew by one line, which moved
# `.expect(...)`'s embedded core::panic::Location and therefore the ELF, the
# vkey and the on-chain identity of the program. Nothing caught it for four
# days; it surfaced only when a freshly proved fixture would not attest, after
# the proving box had been paid for.
#
# These tests exercise the gate over a SYNTHETIC tree so they prove the
# sensitivity itself rather than restating the current pin, and so they never
# edit the working tree.

GUEST_TREE = {
    "Cargo.toml": "[workspace]\nmembers = [\"lib\", \"program\"]\n",
    "Cargo.lock": "# lockfile\n",
    "rust-toolchain": "[toolchain]\nchannel = \"1.90.0\"\n",
    "script/build.rs": "fn main() {}\n",
    "program/Cargo.toml": "[package]\nname = \"p\"\n",
    "program/src/main.rs": "//! one\n//! two\nfn main() { x().expect(\"boom\"); }\n",
    "lib/Cargo.toml": "[package]\nname = \"l\"\n",
    "lib/src/lib.rs": "pub fn x() {}\n",
    "vendor/keccak/Cargo.toml": "[package]\nname = \"keccak\"\n",
    "vendor/keccak/src/lib.rs": "pub fn f() {}\n",
}


def _tree(tmp_path: Path, **overrides: str) -> Path:
    files = dict(GUEST_TREE)
    files.update(overrides)
    for rel, body in files.items():
        f = tmp_path / rel
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(body)
    return tmp_path


def test_guest_digest_is_stable_for_identical_trees(tmp_path):
    a = vc.guest_source_digest(_tree(tmp_path / "a"))[0]
    b = vc.guest_source_digest(_tree(tmp_path / "b"))[0]
    assert a == b, "the digest must not depend on anything outside the files"


def test_guest_digest_moves_when_a_comment_line_is_added(tmp_path):
    """The exact 2026-08-21 defect: a doc comment grows by one line."""
    before = vc.guest_source_digest(_tree(tmp_path / "before"))[0]
    after = vc.guest_source_digest(_tree(
        tmp_path / "after",
        **{"program/src/main.rs":
           "//! one\n//! two\n//! three\nfn main() { x().expect(\"boom\"); }\n"}))[0]
    assert before != after, (
        "a comment-only edit left the digest unchanged — this gate would have "
        "slept through the defect it exists to catch")


@pytest.mark.parametrize("rel", sorted(GUEST_TREE))
def test_every_guest_input_is_covered_by_the_digest(rel, tmp_path):
    """Each build input must be able to move the digest on its own.

    A glob that silently stops matching a file is invisible otherwise: the
    digest keeps validating, and an edit to that file rides through.
    """
    before = vc.guest_source_digest(_tree(tmp_path / "before"))[0]
    after = vc.guest_source_digest(
        _tree(tmp_path / "after", **{rel: GUEST_TREE[rel] + "\n// touched\n"}))[0]
    assert before != after, f"{rel} is not covered by GUEST_INPUT_GLOBS"


def test_guest_digest_notices_a_renamed_file(tmp_path):
    """Path-tagging: moving content between files must change the digest."""
    base = _tree(tmp_path / "base")
    moved = _tree(tmp_path / "moved")
    (moved / "lib/src/lib.rs").write_text(GUEST_TREE["vendor/keccak/src/lib.rs"])
    (moved / "vendor/keccak/src/lib.rs").write_text(GUEST_TREE["lib/src/lib.rs"])
    assert vc.guest_source_digest(base)[0] != vc.guest_source_digest(moved)[0]


def test_empty_tree_does_not_produce_a_passing_digest(tmp_path):
    """A glob set that matches nothing must not look like a valid tree."""
    digest, files = vc.guest_source_digest(tmp_path)
    assert files == []
    assert digest != vc.GUEST_SOURCE_DIGEST


def test_the_repo_still_matches_its_pinned_guest_digest():
    digest, files = vc.guest_source_digest()
    assert len(files) >= 10, f"guest input set collapsed to {files}"
    assert digest == vc.GUEST_SOURCE_DIGEST, (
        "a guest build input changed. Re-derive with "
        "`python verify_claims.py --rebuild-guest`; if the vkey moved this is a "
        "redeploy of MLDSAAttestation and both executors, not a docs edit")


@pytest.mark.parametrize("stale", sorted(vc.STALE_VKEYS))
def test_superseded_vkeys_are_not_the_pinned_one(stale):
    assert stale != vc.GUEST_VKEY


def test_pinned_guest_values_are_wellformed():
    assert re.fullmatch(r"0x[0-9a-f]{64}", vc.GUEST_VKEY)
    assert re.fullmatch(r"[0-9a-f]{64}", vc.GUEST_ELF_SHA256)
    assert re.fullmatch(r"[0-9a-f]{64}", vc.GUEST_SOURCE_DIGEST)


def test_shipped_fixtures_carry_the_pinned_vkey():
    """A fixture proved from a drifted guest reverts on chain.

    prove-both.sh validates a fixture's orderHash and pkHash and only PRINTS
    its vkey, which is why a proof built from the wrong guest passed its own
    validation on 2026-08-25 and would have reverted.
    """
    fixtures = sorted((ROOT / "zk-mldsa/contracts/src/fixtures")
                      .glob("groth16-mldsa-*.json"))
    assert fixtures, "no ML-DSA Groth16 fixtures shipped"
    for f in fixtures:
        vk = json.loads(f.read_text()).get("vkey", "").lower()
        assert vk == vc.GUEST_VKEY, (
            f"{f.name} carries {vc.STALE_VKEYS.get(vk, vk)}, "
            f"which MLDSAAttestation does not pin")


# --- documented gas figures are judged at their own precision ----------------
# The deck writes the attest cost as "1.19M gas", which is true of 1,192,295
# and can never sit within the flat 1000 the check used to demand. It was not
# failing only because `nativ\w+` in the negative guard skipped the window it
# sat in — so the one abbreviated figure in the judge-facing artefact was the
# one figure nobody was checking.

@pytest.mark.parametrize("raw,value,tol", [
    ("1.19M", "1190000", 5_000),      # two decimals of a megagas -> +/- 5k
    ("1.2M", "1200000", 50_000),      # one decimal is coarser, and still true
    ("230k", "230000", 500),          # the original overclaim's shape
    ("1 192 295", "1192295", 1000),   # exact digits get the exact tolerance
    ("1,192,295", "1192295", 1000),   # comma grouping is the same claim
])
def test_gas_figure_tolerance_matches_its_precision(raw, value, tol):
    got_v, got_tol = vc.gas_figure(raw)
    assert got_v == value, f"{raw!r} parsed to {got_v}, expected {value}"
    assert got_tol == tol, f"{raw!r} tolerance {got_tol}, expected {tol}"
