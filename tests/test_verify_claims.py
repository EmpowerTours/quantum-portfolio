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


# One concrete string per registry entry that the pattern must match. Kept
# explicit rather than generated from the regex: a probe derived from the
# pattern would pass even if the pattern stopped describing the real defect.
PROBES: dict[str, str] = {
    r"~?\s*230\s*[k,]\s*(?:-\s*)?gas|230,000\s*gas": "The attest call costs 230k gas.",
    (r"\b105 (?:tests|automated)\b|\b84 tests\b|\b279 tests\b|"
     r"\b110 Python tests\b|Two hundred seventy-nine|\b323 tests\b|\b328 tests\b|\b331 tests\b|\b334 tests\b|\b335 tests\b|\b336 tests\b|Three hundred twenty-three|Three hundred thirty-five"): "The suite has 279 tests.",
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
    assert vc.re.search(pattern, PROBES[pattern], vc.re.I), (
        f"probe for {pattern!r} no longer matches it"
    )


@pytest.mark.parametrize("pattern", list(PROBES))
def test_stale_value_is_caught_in_plain_text(pattern):
    body = f"Some ordinary prose.\n\n{PROBES[pattern]}\n\nMore prose.\n"
    assert vc.find_superseded(body, pattern), (
        f"{pattern!r} not caught in plain text"
    )


@pytest.mark.parametrize("pattern", list(PROBES))
def test_stale_value_is_caught_next_to_a_markdown_heading(pattern):
    """The exact position that defeated this gate: adjacent to a heading.

    A bare "# " in the excuse regex matched the heading and excused everything
    within the context window. 1 of 7 probes was caught in this position.
    """
    body = f"## License\n\n{PROBES[pattern]}\n\nMIT.\n"
    assert vc.find_superseded(body, pattern), (
        f"{pattern!r} escaped next to a heading — the excuse regex is too broad"
    )


@pytest.mark.parametrize("pattern", list(PROBES))
def test_stale_value_is_caught_next_to_a_code_comment(pattern):
    """Comment markers must not excuse either — two of these hid in source."""
    body = f"# module docstring\n\n{PROBES[pattern]}\n\n# trailing\n"
    assert vc.find_superseded(body, pattern), (
        f"{pattern!r} escaped next to a code comment"
    )


@pytest.mark.parametrize("pattern", list(PROBES))
def test_explained_mention_is_excused(pattern):
    """The gate must stay usable: a mention that EXPLAINS the correction is
    legitimate, and flagging it would train people to ignore the gate."""
    body = f"An earlier draft said: {PROBES[pattern]}\n"
    assert not vc.find_superseded(body, pattern), (
        f"{pattern!r} flagged inside its own explanation — false positive"
    )


@pytest.mark.parametrize("pattern", list(PROBES))
def test_historical_details_block_is_excused(pattern):
    body = (
        "<details>\n<summary>Historical</summary>\n\n"
        f"{PROBES[pattern]}\n\n</details>\n"
    )
    assert not vc.find_superseded(body, pattern), (
        f"{pattern!r} flagged inside an explicit historical block"
    )


def test_clean_text_produces_no_hits():
    for pattern, _, _ in vc.SUPERSEDED_VALUES:
        assert not vc.find_superseded(
            "Nothing stale here. The measured cost is 1,196,224 gas.\n", pattern
        ), f"{pattern!r} fires on clean text"
