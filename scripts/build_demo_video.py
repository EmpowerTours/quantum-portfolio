"""Build the silent 90-second storyboard mp4 for the Santander X pitch.

Reads the rendered PITCH_DECK.pdf and selected Streamlit screenshots, fits
each onto a 1920x1080 canvas with the deck's dark navy background, and
encodes the timeline through imageio-ffmpeg's bundled binary (no system
ffmpeg, no sudo).

Each scene is a still frame held for N seconds; transitions are 12-frame
crossfades. The output is silent — record narration over it in OBS, iMovie,
or whichever screen-recorder you use, following docs/DEMO_VIDEO_SCRIPT.md.
"""
from __future__ import annotations

import io
import os
import subprocess
import sys
from pathlib import Path

import imageio_ffmpeg
import pypdfium2 as pdfium
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
DECK_PDF = ROOT / "docs" / "PITCH_DECK.pdf"
SHOTS_DIR = ROOT / "docs" / "screenshots"
OUT_MP4 = ROOT / "docs" / "DEMO_VIDEO.mp4"

WIDTH, HEIGHT = 1920, 1080
FPS = 30
BG = (11, 16, 32)  # var(--bg) from the deck CSS — keeps screenshots blending
PDF_RENDER_SCALE = 2.0  # 2x = crisp at 1080p
CROSSFADE_FRAMES = 12   # 0.4 s at 30 fps

# (source_key, hold_seconds)
# source_key: ("slide", N) for PDF page N (1-indexed)
#             ("shot",  filename) for a Streamlit screenshot
TIMELINE: list[tuple[tuple[str, object], float]] = [
    (("slide", 1),  6.0),   # Title
    (("slide", 2),  9.0),   # Threat
    (("slide", 4),  10.0),  # Stack overview
    (("shot",  "01-run-optimizer.png"),       9.0),
    (("shot",  "04-hardware-verification.png"), 10.0),
    (("shot",  "05-pq-signing.png"),          9.0),
    (("slide", 8),  10.0),  # Proof: 6 contracts / 84 tests
    (("slide", 9),  10.0),  # Live demo TX
    (("slide", 12), 8.0),   # The Ask
]


def render_pdf_pages(pdf_path: Path) -> dict[int, Image.Image]:
    """Return {page_number_1indexed: PIL.Image} for every page of the deck."""
    doc = pdfium.PdfDocument(str(pdf_path))
    pages: dict[int, Image.Image] = {}
    for i in range(len(doc)):
        page = doc[i]
        pil = page.render(scale=PDF_RENDER_SCALE).to_pil().convert("RGB")
        pages[i + 1] = pil
    return pages


def fit_onto_canvas(src: Image.Image) -> Image.Image:
    """Resize src to fit (WIDTH, HEIGHT) preserving aspect, then paste on BG."""
    canvas = Image.new("RGB", (WIDTH, HEIGHT), BG)
    sw, sh = src.size
    scale = min(WIDTH / sw, HEIGHT / sh)
    new_w, new_h = int(sw * scale), int(sh * scale)
    resized = src.resize((new_w, new_h), Image.LANCZOS)
    x = (WIDTH - new_w) // 2
    y = (HEIGHT - new_h) // 2
    canvas.paste(resized, (x, y))
    return canvas


def blend(a: Image.Image, b: Image.Image, t: float) -> Image.Image:
    """Linear crossfade. t=0 -> a, t=1 -> b."""
    return Image.blend(a, b, t)


def build_frame_stream() -> list[Image.Image]:
    """Materialize every output frame as a list of PIL images.

    For a 90s @ 30fps deck this is ~2700 frames at 1920x1080. Memory budget
    is ~17 GB if we hold raw RGB — too much. Instead we hold one canvas per
    *scene* (9 PIL objects) and stream frames out to ffmpeg one at a time.
    This function intentionally returns *scene canvases*, not frames; the
    encoder loop expands them inline.
    """
    pages = render_pdf_pages(DECK_PDF)
    canvases: list[tuple[Image.Image, float]] = []
    for (kind, ref), hold in TIMELINE:
        if kind == "slide":
            src = pages[ref]  # type: ignore[index]
        elif kind == "shot":
            src = Image.open(SHOTS_DIR / ref).convert("RGB")  # type: ignore[arg-type]
        else:
            raise ValueError(kind)
        canvases.append((fit_onto_canvas(src), hold))
    return canvases  # type: ignore[return-value]


def encode(scenes: list[tuple[Image.Image, float]], out: Path) -> None:
    ffmpeg = imageio_ffmpeg.get_ffmpeg_exe()
    cmd = [
        ffmpeg, "-y",
        "-f", "rawvideo",
        "-pix_fmt", "rgb24",
        "-s", f"{WIDTH}x{HEIGHT}",
        "-r", str(FPS),
        "-i", "pipe:0",
        "-c:v", "libx264",
        "-preset", "medium",
        "-crf", "20",
        "-pix_fmt", "yuv420p",
        "-movflags", "+faststart",
        str(out),
    ]
    print(f"encoding {len(scenes)} scenes -> {out.name}")
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    assert proc.stdin is not None
    try:
        total_frames = 0
        for idx, (canvas, hold) in enumerate(scenes):
            hold_frames = max(0, int(round(hold * FPS)) - (CROSSFADE_FRAMES if idx < len(scenes) - 1 else 0))
            for _ in range(hold_frames):
                proc.stdin.write(canvas.tobytes())
                total_frames += 1
            if idx < len(scenes) - 1:
                next_canvas = scenes[idx + 1][0]
                for f in range(CROSSFADE_FRAMES):
                    t = (f + 1) / CROSSFADE_FRAMES
                    proc.stdin.write(blend(canvas, next_canvas, t).tobytes())
                    total_frames += 1
            print(f"  scene {idx + 1}/{len(scenes)} done ({total_frames} frames)")
    finally:
        proc.stdin.close()
        proc.wait()
    print(f"done. {total_frames} frames @ {FPS} fps = {total_frames / FPS:.1f} s")


def main() -> int:
    if not DECK_PDF.exists():
        print(f"missing {DECK_PDF}", file=sys.stderr)
        return 1
    scenes = build_frame_stream()
    encode(scenes, OUT_MP4)
    size_mb = OUT_MP4.stat().st_size / (1024 * 1024)
    print(f"wrote {OUT_MP4} ({size_mb:.2f} MB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
