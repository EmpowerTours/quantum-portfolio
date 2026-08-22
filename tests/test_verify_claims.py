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
     r"\b110 Python tests\b|Two hundred seventy-nine|\b323 tests\b|\b328 tests\b|\b331 tests\b|\b334 tests\b|\b335 tests\b|\b336 tests\b|\b342 tests\b|\b154 tests\b|\b355 tests\b|\b161 Python tests\b|\b174 Python tests\b|Three hundred twenty-three|Three hundred thirty-five|Three hundred forty-two|Three hundred fifty-five"): (
        "The suite has 279 tests.",
        "**Proof — live on Monad mainnet, 342 tests** | 10 s |",
        "pytest tests/ -q                    # 154 tests",
        "Three hundred forty-two tests across Python and Foundry.",
        "161 Python tests plus 181 Foundry tests.",
        "Live on Monad MAINNET.<br>355 tests. ZK-verified.",
        "Three hundred fifty-five tests across Python and Foundry.",
        "174 Python tests plus 181 Foundry tests.",
    ),
    r"81[- ]second": "Watch the 81-second walkthrough.",
    r"fe44195b|d8bf1551": "orderHash 0xd8bf15515669ef1f1d912c6d505d056b1f4ccd5cc6aebcae1b223c05cb8915f9",
    (r"0x5caf7a40|executeAndRoute\(bytes32,address\[\],uint24\[\],uint16\[\],"
     r"uint256\[\],uint256\)"): "Call executeAndRoute(bytes32,address[],uint24[],uint16[],uint256[],uint256).",
    r"not yet on the hardware path|not in current HW path": (
        "src/xy_qaoa.py is not yet on the hardware path."),
    r"depth-2 (?:QAOA|penalty)": "A depth-2 QAOA runs on IBM Heron.",
    r"lastHash\[(?:deployer|anchorer)\]\s*(?:returns|==)": (
        "Confirm AuditAnchor.lastHash[deployer] returns the same hash."),
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
])
def test_escaped_count_shapes_are_now_seen(shape, text, expected):
    assert expected in vc.scan_counts(text), (
        f"{shape}: {expected} still invisible in {text!r}")


def test_old_pattern_really_was_blind_to_all_three():
    """Guards the reason these patterns exist, not just their current output."""
    old = vc.re.compile(r"(\d{2,4})[- ]tests?\b")
    for text in ("# 1. Python tests (155).",
                 '<div class="big">279<small>tests passing</small></div>',
                 "154 Python + 181 Foundry</small>"):
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
    assert len(vc.COUNT_PATTERNS) == 3


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
