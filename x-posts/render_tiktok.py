"""
Vertical (9:16, 1080x1920) version of the Monday counter video, for TikTok.
Same figures as the X video (render_video.py), laid out for a phone screen.

  python render_tiktok.py --total 13722000000000 --gps 36321 --per-person 251600 \
      --debt-to-gdp 72.4 --as-of "Live estimate, 6 Nov 2026, 09:00 EAT" --out tiktok.mp4
"""
from __future__ import annotations

import argparse
import shutil
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw

from render_video import (CREAM, DARK, DEEP_GREEN, FPS, GREY, IEA_GREEN, WHITE, draw_fixed, ffmpeg_exe,
                          fit_size, fmt_int, font, load_logo)

TW, TH = 1080, 1920


def _base(site: str) -> Image.Image:
    im = Image.new("RGB", (TW, TH), WHITE)
    d = ImageDraw.Draw(im)
    d.rectangle([0, 0, TW, 330], fill=IEA_GREEN)
    d.rectangle([0, 330, TW, 346], fill=CREAM)
    d.text((TW / 2, 125), "KENYA'S PUBLIC DEBT", font=font("bold", 78), fill=WHITE, anchor="mm")
    d.text((TW / 2, 225), "RIGHT NOW", font=font("bold", 78), fill=CREAM, anchor="mm")
    # TikTok covers the bottom ~20% (caption) and the right edge (buttons), so
    # everything that matters sits above y = 1560 and away from the right edge.
    logo = load_logo("iea-kenya.png", 120)
    if logo is not None:
        im.paste(logo, ((TW - logo.width) // 2, 370), logo)
    d.rectangle([0, 1420, TW, 1560], fill=IEA_GREEN)
    d.rectangle([0, 1560, TW, TH], fill=(236, 248, 240))  # caption area: light tint, nothing important
    d.text((TW / 2, 1462), "Watch it live:", font=font("regular", 38), fill=WHITE, anchor="mm")
    d.text((TW / 2, 1516), site, font=font("bold", 46), fill=WHITE, anchor="mm")
    return im


def render_vertical(total: float, gps: float, per_person: float, out_mp4: Path, seconds: float = 10.0,
                    site: str = "kenyadebtcounter.vercel.app", as_of: str = "",
                    debt_to_gdp: float | None = None) -> Path:
    ffmpeg = ffmpeg_exe()
    per_person = round(per_person, -2)
    n = int(seconds * FPS)
    tmp = Path(tempfile.mkdtemp(prefix="tiktok_frames_"))
    base = _base(site)
    d0 = ImageDraw.Draw(base)
    big = fit_size(d0, fmt_int(total + gps * seconds), "bold", TW - 90, 140)
    ksh = font("bold", 90)
    mid = font("bold", 60)
    small = font("regular", 50)
    note = font("regular", 38)
    for i in range(n):
        t = i / FPS
        im = base.copy()
        d = ImageDraw.Draw(im)
        d.text((TW / 2, 560), "KSh", font=ksh, fill=DEEP_GREEN, anchor="mm")
        draw_fixed(d, fmt_int(total + gps * t), TW // 2, 620, big, DEEP_GREEN)
        pulse = IEA_GREEN if int(t * 2) % 2 == 0 else DARK
        d.text((TW / 2, 860), f"+ KSh {fmt_int(gps)}", font=mid, fill=pulse, anchor="mm")
        d.text((TW / 2, 935), "every second", font=small, fill=pulse, anchor="mm")
        d.line([(160, 1020), (TW - 160, 1020)], fill=CREAM, width=6)
        d.text((TW / 2, 1100), f"About KSh {fmt_int(per_person)}", font=mid, fill=DARK, anchor="mm")
        d.text((TW / 2, 1170), "for every Kenyan", font=small, fill=DARK, anchor="mm")
        if debt_to_gdp:
            d.text((TW / 2, 1265), f"{debt_to_gdp:.1f}% of Kenya's GDP", font=mid, fill=DARK, anchor="mm")
        if as_of:
            d.text((TW / 2, 1350), as_of, font=note, fill=GREY, anchor="mm")
        im.save(tmp / f"f{i:04d}.png")
    out_mp4 = Path(out_mp4)
    subprocess.run([
        ffmpeg, "-y", "-loglevel", "error", "-framerate", str(FPS), "-i", str(tmp / "f%04d.png"),
        "-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=44100", "-shortest",
        "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-pix_fmt", "yuv420p",
        "-c:a", "aac", "-b:a", "64k", "-movflags", "+faststart", str(out_mp4)], check=True)
    shutil.rmtree(tmp, ignore_errors=True)
    return out_mp4


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--total", type=float, required=True)
    ap.add_argument("--gps", type=float, required=True)
    ap.add_argument("--per-person", type=float, required=True)
    ap.add_argument("--as-of", default="")
    ap.add_argument("--debt-to-gdp", type=float, default=None)
    ap.add_argument("--out", default="tiktok.mp4")
    a = ap.parse_args()
    print(render_vertical(a.total, a.gps, a.per_person, Path(a.out), as_of=a.as_of, debt_to_gdp=a.debt_to_gdp))
