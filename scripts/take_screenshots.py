"""Headless-browser screenshot capture for the Streamlit submission package.

Run with the Streamlit app already serving on http://localhost:8501.
Writes PNGs to docs/screenshots/.
"""
from __future__ import annotations

import sys
import time
from pathlib import Path

from playwright.sync_api import sync_playwright

URL = "http://localhost:8501"
OUT_DIR = Path("docs/screenshots")
VIEWPORT = {"width": 1600, "height": 1000}

TABS = [
    ("01-run-optimizer.png",         "Run optimizer"),
    ("02-ai-forecasts.png",          "AI forecasts"),
    ("03-backtest.png",              "Backtest"),
    ("04-hardware-verification.png", "Hardware verification"),
    ("05-pq-signing.png",            "PQ signing"),
    ("06-methodology.png",           "Methodology"),
]


def main() -> int:
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        ctx = browser.new_context(viewport=VIEWPORT, device_scale_factor=2)
        page = ctx.new_page()

        print(f"Opening {URL}...")
        page.goto(URL, wait_until="networkidle", timeout=60_000)
        # Let Streamlit finish its initial heavy compute (DeFiLlama fetch, etc.).
        time.sleep(10)

        for filename, label in TABS:
            print(f"  - {label} -> {filename}")
            # Streamlit tabs are <button role="tab"> with the label as text.
            tab = page.get_by_role("tab", name=label)
            tab.click()
            # Let charts render. Hardware + Backtest tabs have heavy compute.
            time.sleep(6)
            # Scroll back to top so the screenshot captures the tab content header.
            page.evaluate("() => window.scrollTo(0, 0)")
            time.sleep(1)
            page.screenshot(path=str(OUT_DIR / filename), full_page=True)

        browser.close()

    print(f"\nWrote {len(TABS)} screenshots to {OUT_DIR}/")
    for f in sorted(OUT_DIR.glob("*.png")):
        print(f"  {f.name}  {f.stat().st_size:,} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
