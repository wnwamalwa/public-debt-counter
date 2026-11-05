"""
Render a short MP4 (and a GIF copy) of the Kenya Debt Counter for X.

Two styles:
  counter     the total public debt ticking up in real time (value + gps * t)
  per_person  debt per Kenyan counting up from zero, then holding

Usage (for a local preview):
  python render_video.py --style counter --total 13051000000000 --gps 38370 \
      --per-person 241000 --out preview.mp4
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
W, H = 1280, 720
FPS = 30
# IEA Kenya brand colours (taken from the logo)
IEA_GREEN = (24, 170, 79)     # #18AA4F
DEEP_GREEN = (14, 120, 58)    # #0E783A, darker shade for the big figure (reads well on white)
CREAM = (239, 228, 143)       # #EFE48F
DARK = (35, 31, 32)           # #231F20, the logo's black
GREY = (100, 100, 100)
WHITE = (255, 255, 255)
RED = DEEP_GREEN  # main accent

FONT_CANDIDATES = {
    "bold": [
        "/usr/share/fonts/opentype/inter/Inter-Bold.otf",
        "/usr/share/fonts/truetype/inter/Inter-Bold.ttf",
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
        "/Library/Fonts/Arial Bold.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    ],
    "regular": [
        "/usr/share/fonts/opentype/inter/Inter-Regular.otf",
        "/usr/share/fonts/truetype/inter/Inter-Regular.ttf",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/Library/Fonts/Arial.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    ],
}


def font(kind: str, size: int) -> ImageFont.FreeTypeFont:
    for path in FONT_CANDIDATES[kind]:
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    return ImageFont.load_default(size)


def ffmpeg_exe() -> str:
    """System ffmpeg if installed, otherwise the copy bundled with imageio-ffmpeg."""
    exe = shutil.which("ffmpeg")
    if exe:
        return exe
    try:
        import imageio_ffmpeg
        return imageio_ffmpeg.get_ffmpeg_exe()
    except Exception:
        raise RuntimeError("ffmpeg not found: run 'pip install imageio-ffmpeg' or install ffmpeg")


def fmt_int(x: float) -> str:
    return f"{int(round(x)):,}"


def draw_fixed(draw: ImageDraw.ImageDraw, text: str, centre_x: int, y: int, f, fill) -> None:
    """Draw digits in fixed-width cells so the number does not jitter as it ticks."""
    digit_w = max(draw.textlength(d, font=f) for d in "0123456789")
    widths = [digit_w if ch.isdigit() else draw.textlength(ch, font=f) for ch in text]
    x = centre_x - sum(widths) / 2
    for ch, w in zip(text, widths):
        cw = draw.textlength(ch, font=f)
        draw.text((x + (w - cw) / 2, y), ch, font=f, fill=fill)
        x += w


def fit_size(draw, text: str, kind: str, max_w: int, start: int) -> ImageFont.FreeTypeFont:
    size = start
    while size > 20:
        f = font(kind, size)
        digit_w = max(draw.textlength(d, font=f) for d in "0123456789")
        w = sum(digit_w if ch.isdigit() else draw.textlength(ch, font=f) for ch in text)
        if w <= max_w:
            return f
        size -= 4
    return font(kind, size)


def load_logo(name: str, height: int):
    p = HERE / "assets" / name
    if not p.exists():
        return None
    im = Image.open(p).convert("RGBA")
    return im.resize((int(im.width * height / im.height), height), Image.LANCZOS)


def base_frame(title: str, footer_left: str, logos) -> Image.Image:
    im = Image.new("RGB", (W, H), WHITE)
    d = ImageDraw.Draw(im)
    d.rectangle([0, 0, W, 92], fill=IEA_GREEN)
    d.rectangle([0, 92, W, 100], fill=CREAM)
    tf = font("bold", 40)
    d.text((W / 2, 46), title, font=tf, fill=WHITE, anchor="mm")
    x = 40
    for lg in logos:
        if lg is not None:
            y = H - 96 + (96 - lg.height) // 2
            d.rounded_rectangle([x - 8, y - 4, x + lg.width + 8, y + lg.height + 4], 8, fill=WHITE)
            im.paste(lg, (x, y), lg)
            x += lg.width + 28
    d.text((W / 2, H - 48), footer_left, font=font("bold", 30), fill=DARK, anchor="mm")
    return im


def render(style: str, total: float, gps: float, per_person: float, out_mp4: Path,
           seconds: float = 7.0, site: str = "kenyadebtcounter.vercel.app",
           as_of: str = "", debt_to_gdp: float | None = None) -> tuple[Path, Path]:
    ffmpeg = ffmpeg_exe()
    logos = [load_logo("iea-kenya.png", 80)]  # IEA Kenya only
    per_person = round(per_person, -2)  # same rounding as the tweet text
    n = int(seconds * FPS)
    tmp = Path(tempfile.mkdtemp(prefix="xpost_frames_"))

    if style == "per_person":
        title = "KENYA'S PUBLIC DEBT PER PERSON"
    else:
        title = "KENYA'S PUBLIC DEBT RIGHT NOW"
    base = base_frame(title, site, logos)
    d0 = ImageDraw.Draw(base)

    if style == "per_person":
        sample = "KSh " + fmt_int(per_person)
        big = fit_size(d0, sample, "bold", W - 160, 150)
    else:
        sample = "KSh " + fmt_int(total + gps * seconds)
        big = fit_size(d0, sample, "bold", W - 120, 120)
    small = font("regular", 34)
    note = font("regular", 24)

    for i in range(n):
        t = i / FPS
        im = base.copy()
        d = ImageDraw.Draw(im)
        if style == "per_person":
            ramp = min(1.0, t / 3.0)
            ramp = 1 - (1 - ramp) ** 3  # ease out
            value = per_person * ramp
            draw_fixed(d, "KSh " + fmt_int(value), W // 2, 210, big, RED)
            d.text((W / 2, 420), "owed for every man, woman and child in Kenya",
                   font=small, fill=DARK, anchor="mm")
            d.text((W / 2, 475), f"Total public debt: KSh {total / 1e12:.2f} trillion",
                   font=small, fill=GREY, anchor="mm")
            if debt_to_gdp:
                d.text((W / 2, 530), f"That is {debt_to_gdp:.1f}% of Kenya's GDP",
                       font=small, fill=DARK, anchor="mm")
        else:
            value = total + gps * t
            draw_fixed(d, "KSh " + fmt_int(value), W // 2, 220, big, RED)
            pulse = IEA_GREEN if int(t * 2) % 2 == 0 else DARK
            d.text((W / 2, 420), f"+ KSh {fmt_int(gps)} every second",
                   font=font("bold", 40), fill=pulse, anchor="mm")
            d.text((W / 2, 475), f"About KSh {fmt_int(per_person)} for every Kenyan",
                   font=small, fill=DARK, anchor="mm")
            if debt_to_gdp:
                d.text((W / 2, 530), f"Equal to {debt_to_gdp:.1f}% of Kenya's GDP",
                       font=small, fill=DARK, anchor="mm")
        if as_of:
            d.text((W / 2, H - 130), as_of, font=note, fill=GREY, anchor="mm")
        im.save(tmp / f"f{i:04d}.png")

    out_mp4 = Path(out_mp4)
    subprocess.run([
        ffmpeg, "-y", "-loglevel", "error", "-framerate", str(FPS), "-i", str(tmp / "f%04d.png"),
        "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-pix_fmt", "yuv420p",
        "-movflags", "+faststart", str(out_mp4)], check=True)
    out_gif = out_mp4.with_suffix(".gif")
    subprocess.run([
        ffmpeg, "-y", "-loglevel", "error", "-i", str(out_mp4), "-vf",
        "fps=12,scale=640:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse",
        str(out_gif)], check=True)
    shutil.rmtree(tmp, ignore_errors=True)
    return out_mp4, out_gif


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--style", default="counter", choices=["counter", "per_person"])
    ap.add_argument("--total", type=float, required=True)
    ap.add_argument("--gps", type=float, required=True)
    ap.add_argument("--per-person", type=float, required=True)
    ap.add_argument("--as-of", default="")
    ap.add_argument("--debt-to-gdp", type=float, default=None)
    ap.add_argument("--out", default="preview.mp4")
    a = ap.parse_args()
    print(render(a.style, a.total, a.gps, a.per_person, Path(a.out), as_of=a.as_of,
                 debt_to_gdp=a.debt_to_gdp))
