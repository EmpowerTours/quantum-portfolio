#!/usr/bin/env python3
"""Fail if any slide's content is clipped by the fixed marp frame.

marp renders each slide into a fixed 1280x720 box and CLIPS whatever does not
fit — it never paginates and it never warns. A slide that grows past the frame
silently loses its last point, which is usually the punchline. On 2026-08-05,
13 of 18 slides in this deck were losing content this way, including one that
had lost 547px, and the only reason anyone noticed was a manual screenshot.

Measures the real rendered geometry in a browser rather than guessing from the
markdown, because overflow depends on fonts, wrapping and the grid.

Usage:  python scripts/check_deck_overflow.py [docs/PITCH_DECK.html]
Exit code is non-zero if anything is clipped, so `make` and CI can gate on it.
"""
from __future__ import annotations

import pathlib
import sys

MEASURE = """() => {
  const out = [];
  document.querySelectorAll('section').forEach((s, i) => {
    const sr = s.getBoundingClientRect();
    let low = 0, who = '';
    s.querySelectorAll('*').forEach(el => {
      // The page number is positioned near the bottom by design.
      if (el.closest('.pagination, footer, header')) return;
      if (el.offsetParent === null) return;
      const r = el.getBoundingClientRect();
      if (!r.height) return;
      const bot = r.bottom - sr.top;
      if (bot > low) {
        low = bot;
        who = el.tagName + ': ' + (el.innerText || '').slice(0, 46).replace(/\\n/g, ' ');
      }
    });
    const h1 = s.querySelector('h1');
    out.push({
      n: i + 1,
      past: Math.round(low - sr.height),
      who,
      title: (h1 ? h1.innerText : '').slice(0, 40).replace(/\\n/g, ' '),
    });
  });
  return out;
}"""


def main() -> int:
    from playwright.sync_api import sync_playwright

    html = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "docs/PITCH_DECK.html")
    if not html.exists():
        print(f"{html} missing — run `make deck` first", file=sys.stderr)
        return 2

    with sync_playwright() as pw:
        b = pw.chromium.launch()
        pg = b.new_page(viewport={"width": 1280, "height": 720})
        pg.goto("file://" + str(html.resolve()), wait_until="networkidle", timeout=120_000)
        pg.wait_for_timeout(4000)
        rows = pg.evaluate(MEASURE)
        b.close()

    clipped = [r for r in rows if r["past"] > 0]
    for r in rows:
        # Slack below zero is headroom; report it so tightening is visible.
        mark = "CLIP" if r["past"] > 0 else "ok  "
        print(f"  {mark} slide {r['n']:>2}  {r['past']:>+5}px  {r['title']}")
    if clipped:
        print(f"\n{len(clipped)} of {len(rows)} slides are CLIPPED — content is being lost:")
        for r in clipped:
            print(f"  slide {r['n']}: +{r['past']}px past the frame | last element {r['who']}")
        return 1
    print(f"\nall {len(rows)} slides fit the frame")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
