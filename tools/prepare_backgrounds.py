#!/usr/bin/env python3
"""Turn personal photographs into Qulex app backgrounds.

    python tools/prepare_backgrounds.py --src <folder> --out assets/backgrounds

Two jobs, and the second one is the reason this is a script rather than a few
minutes in an image editor: it has to be reproducible. If a face ever turns out
to be more legible than intended, the fix should be a number in a config here
and a re-run, not a hunt for whatever settings were used by hand at the time.

1. ANONYMITY. The people in these photos are the author and his partner, and
   they should not be identifiable in a shipped app. Three mechanisms, applied
   per photo by the config below:
     - `silhouette`: crushes a region's luminance toward black with a soft
       radial falloff, so figures read as shapes against a bright sky. This is
       the strongest option and the one that looks the most deliberate — a
       backlit silhouette is a photographic idiom, not an obvious redaction.
     - `blur`: a heavy gaussian over a region, for anything the crush leaves
       readable.
     - `darken`: a plain multiply, for toning down a bright distraction.
   Some photos need none of it: in the buggy shots both riders are already
   behind goggles and a full face covering.

2. FIT. The existing eight backgrounds are dark, warm and low-contrast — mean
   RGB in the 45-99 range, because they sit behind cream text that has to stay
   readable. Tropical daylight is the opposite of that, so every photo is
   desaturated, warmed, tone-crushed, vignetted, and finally exposure-matched
   to a target mean. Dropping these in untreated would be the single fastest
   way to make the whole app hard to read.

Output is JPEG, not PNG. The eight originals are PNGs averaging 2MB each; the
same images as quality-84 JPEG are ~250KB with no visible difference at these
tones, because photographic gradients are exactly what JPEG is good at. See
--convert-existing.
"""
from __future__ import annotations

import argparse
import math
import os
from pathlib import Path

from PIL import Image, ImageEnhance, ImageFilter, ImageOps

try:
    import pillow_heif

    pillow_heif.register_heif_opener()
except ImportError:  # pragma: no cover - only needed for iPhone originals
    pass

# Matches the existing backgrounds exactly. 9:16-ish, portrait.
OUT_W, OUT_H = 768, 1376

# Mean HSV value the graded image is pushed to. The existing set runs 50-100;
# aiming at the low-middle keeps new photos from being the bright ones.
TARGET_VALUE = 60.0

# Regions are (x0, y0, x1, y1) as fractions of the cropped frame.
#
# `focus` is the point kept centred when cropping to portrait — without it, a
# centre crop of a wide photo cuts the subject in half.
PLAN = [
    # --- no people at all: grade only ---
    {"src": "4c31390b-7d25-4f55-b824-6dc5b84a2bcf.JPG", "out": "bg_09.jpg",
     "focus": (0.5, 0.45), "note": "cave mouth and boat — already the mood"},
    {"src": "IMG_4117.JPG", "out": "bg_10.jpg", "focus": (0.42, 0.5),
     "note": "waterfall in the gorge"},
    {"src": "IMG_3961.HEIC", "out": "bg_11.jpg", "focus": (0.5, 0.5),
     "note": "cave petroglyph — pure texture"},
    {"src": "IMG_3764.heic", "out": "bg_12.jpg", "focus": (0.5, 0.42),
     "note": "sunset road from the car"},
    {"src": "ea931e9d-5b18-4099-9519-b78410c9a0ca.JPG", "out": "bg_13.jpg",
     "focus": (0.5, 0.55), "note": "river jetty"},

    # --- people present, faces already hidden by the photograph itself ---
    {"src": "IMG_3805.heic", "out": "bg_14.jpg", "focus": (0.45, 0.45),
     "note": "Ada from behind at the rail. No treatment: there is no face in "
             "frame, and a blur here made a smudge where the photograph was "
             "already anonymous."},
    {"src": "WhatsApp_Image_20240129_at_5.32.15_PM.jpeg", "out": "bg_15.jpg",
     "focus": (0.45, 0.42),
     "note": "buggy in the mud. No treatment: goggles and a full face "
             "covering on both riders already do the job, and blurring them "
             "only drew the eye to the fact that something was hidden."},

    # --- people present, faces visible: silhouette them ---
    {"src": "WhatsApp_Image_20240129_at_5.34.34_PM.jpeg", "out": "bg_16.jpg",
     "focus": (0.47, 0.55),
     "note": "the beach shot — the only one where a face is both visible and "
             "identifiable, and the only one that needed real work.",
     "contre_jour": (0.80, 15.0),
     # A last touch over the two heads. It is invisible as an edit because the
     # figures are already near-black by this point; it exists so that the
     # anonymity does not depend on the exact luminance of one afternoon.
     "darken": [(0.44, 0.34, 0.72, 0.46, 0.55)]},
]


def load(path: Path) -> Image.Image:
    im = Image.open(path)
    im = ImageOps.exif_transpose(im)  # iPhone photos are rotated by tag
    return im.convert("RGB")


def crop_portrait(im: Image.Image, focus: tuple[float, float]) -> Image.Image:
    """Crops to the output aspect around [focus], then resizes."""
    target = OUT_W / OUT_H
    w, h = im.size
    if w / h > target:
        nw, nh = int(h * target), h
    else:
        nw, nh = w, int(w / target)
    cx, cy = focus[0] * w, focus[1] * h
    x0 = int(min(max(cx - nw / 2, 0), w - nw))
    y0 = int(min(max(cy - nh / 2, 0), h - nh))
    return im.crop((x0, y0, x0 + nw, y0 + nh)).resize(
        (OUT_W, OUT_H), Image.LANCZOS)


def _falloff_mask(size: tuple[int, int], box, feather: float = 0.35):
    """A soft-edged elliptical mask over [box], 255 inside, 0 outside.

    Built by hand rather than with a drawn ellipse + blur because the falloff
    needs to be wide and smooth: a hard-edged patch of darkness reads as
    censorship, and the whole point is that this should look like lighting.
    """
    w, h = size
    x0, y0, x1, y1 = box
    cx, cy = (x0 + x1) / 2 * w, (y0 + y1) / 2 * h
    rx, ry = max((x1 - x0) / 2 * w, 1), max((y1 - y0) / 2 * h, 1)
    mask = Image.new("L", size, 0)
    px = mask.load()
    for y in range(h):
        dy = (y - cy) / ry
        for x in range(w):
            dx = (x - cx) / rx
            d = math.sqrt(dx * dx + dy * dy)
            if d >= 1 + feather:
                continue
            if d <= 1 - feather:
                px[x, y] = 255
            else:
                t = (1 + feather - d) / (2 * feather)
                px[x, y] = int(255 * t * t * (3 - 2 * t))  # smoothstep
    return mask


def apply_blur(im: Image.Image, regions) -> Image.Image:
    for (x0, y0, x1, y1, radius) in regions:
        blurred = im.filter(ImageFilter.GaussianBlur(radius))
        im = Image.composite(blurred, im, _falloff_mask(im.size, (x0, y0, x1, y1)))
    return im


def apply_silhouette(im: Image.Image, regions) -> Image.Image:
    """Crushes a region toward black, keeping enough shape to read as a figure."""
    for (x0, y0, x1, y1, strength) in regions:
        dark = ImageEnhance.Brightness(im).enhance(1.0 - strength)
        dark = ImageEnhance.Color(dark).enhance(0.15)
        im = Image.composite(dark, im,
                             _falloff_mask(im.size, (x0, y0, x1, y1), 0.45))
    return im


def contre_jour(im: Image.Image, pivot: float, steep: float,
                floor: float = 0.02) -> Image.Image:
    """Pushes highlights up and crushes everything below [pivot] toward black.

    This is what actually solved the beach photograph, after two attempts that
    did not. A blurred patch over the faces read as censorship; a plain global
    darkening left the faces perfectly legible, only dimmer. Neither looked
    like a photograph.

    Working on LUMINANCE instead does: sky, sea and sand sit above the pivot
    and stay bright, the figures sit below it and collapse into shape. That is
    contre-jour, an ordinary thing for a beach photo to be, and it takes the
    faces with it. RGB is scaled by a factor derived from L rather than curved
    per channel, so colour darkens without shifting hue.
    """
    import numpy as np
    a = np.asarray(im).astype("float32") / 255.0
    lum = 0.2126 * a[..., 0] + 0.7152 * a[..., 1] + 0.0722 * a[..., 2]
    s_curve = 1.0 / (1.0 + np.exp(-steep * (lum - pivot)))
    s_curve = floor + (1.0 - floor) * s_curve
    scale = np.clip(s_curve / np.maximum(lum, 1e-4), 0, 4.0)[..., None]
    return Image.fromarray((np.clip(a * scale, 0, 1) * 255).astype("uint8"))


def apply_darken(im: Image.Image, regions) -> Image.Image:
    for (x0, y0, x1, y1, amount) in regions:
        dark = ImageEnhance.Brightness(im).enhance(1.0 - amount)
        im = Image.composite(dark, im, _falloff_mask(im.size, (x0, y0, x1, y1)))
    return im


def vignette(im: Image.Image, strength: float = 0.55) -> Image.Image:
    w, h = im.size
    mask = Image.new("L", (w, h))
    px = mask.load()
    cx, cy = w / 2, h / 2
    maxd = math.sqrt(cx * cx + cy * cy)
    for y in range(h):
        for x in range(w):
            d = math.sqrt((x - cx) ** 2 + (y - cy) ** 2) / maxd
            px[x, y] = int(255 * min(1.0, max(0.0, 1.0 - (d ** 2) * strength)))
    black = Image.new("RGB", (w, h), (0, 0, 0))
    return Image.composite(im, black, mask)


def grade(im: Image.Image) -> Image.Image:
    """Desaturate, warm, crush, vignette, then exposure-match to TARGET_VALUE."""
    im = ImageEnhance.Color(im).enhance(0.52)
    im = ImageEnhance.Contrast(im).enhance(0.92)

    # Warm it the way the existing set is warm (R > G > B), and lift the blacks
    # a little so shadows stay grey rather than going to a dead flat black.
    r, g, b = im.split()
    r = r.point(lambda v: min(255, int(10 + v * 1.02)))
    g = g.point(lambda v: min(255, int(8 + v * 0.97)))
    b = b.point(lambda v: min(255, int(6 + v * 0.88)))
    im = Image.merge("RGB", (r, g, b))

    im = vignette(im)

    # Final exposure match. Doing this last, against the measured mean, is what
    # keeps a noon beach and a cave interior sitting at the same weight behind
    # the type — matching by eye photo-by-photo is exactly how a set drifts.
    from PIL import ImageStat
    for _ in range(8):
        mean = ImageStat.Stat(im.convert("HSV")).mean[1 + 1]
        if abs(mean - TARGET_VALUE) < 1.5:
            break
        im = ImageEnhance.Brightness(im).enhance(
            max(0.4, min(1.6, TARGET_VALUE / max(mean, 1))))
    return im


def process(src_dir: Path, out_dir: Path) -> None:
    from PIL import ImageStat
    out_dir.mkdir(parents=True, exist_ok=True)
    for item in PLAN:
        src = src_dir / item["src"]
        if not src.exists():
            print(f"  MISSING {item['src']}")
            continue
        im = crop_portrait(load(src), item.get("focus", (0.5, 0.5)))
        if "contre_jour" in item:
            pivot, steep = item["contre_jour"]
            im = contre_jour(im, pivot, steep)
            im = ImageEnhance.Color(im).enhance(0.30)
        if "silhouette" in item:
            im = apply_silhouette(im, item["silhouette"])
        if "blur" in item:
            im = apply_blur(im, item["blur"])
        if "darken" in item:
            im = apply_darken(im, item["darken"])
        im = grade(im)
        dst = out_dir / item["out"]
        im.save(dst, "JPEG", quality=84, optimize=True, progressive=True)
        st = ImageStat.Stat(im.convert("RGB"))
        hs = ImageStat.Stat(im.convert("HSV"))
        print(f"  {item['out']:<12} {dst.stat().st_size // 1024:>5}KB  "
              f"mean RGB {[round(x) for x in st.mean]}  "
              f"sat {round(hs.mean[1])}  val {round(hs.mean[2])}   {item['note']}")


def convert_existing(out_dir: Path) -> None:
    """Re-encodes the eight original PNG backgrounds as JPEG.

    Saves roughly 14MB of app bundle for no visible change — these are
    photographs, and PNG stores photographic gradients about as badly as a
    format can.
    """
    from PIL import ImageStat
    total_before = total_after = 0
    for p in sorted(out_dir.glob("bg_*.png")):
        im = Image.open(p).convert("RGB")
        dst = p.with_suffix(".jpg")
        im.save(dst, "JPEG", quality=84, optimize=True, progressive=True)
        before, after = p.stat().st_size, dst.stat().st_size
        total_before += before
        total_after += after
        st = ImageStat.Stat(im)
        print(f"  {p.name} {before // 1024}KB -> {dst.name} {after // 1024}KB  "
              f"mean {[round(x) for x in st.mean]}")
    if total_before:
        print(f"  total {total_before // 1024}KB -> {total_after // 1024}KB "
              f"({(total_before - total_after) // 1024}KB saved)")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--src", type=Path, required=True)
    ap.add_argument("--out", type=Path,
                    default=Path(__file__).resolve().parent.parent /
                    "assets" / "backgrounds")
    ap.add_argument("--convert-existing", action="store_true",
                    help="also re-encode the original bg_*.png as JPEG")
    args = ap.parse_args()
    print(f"writing to {args.out}")
    process(args.src, args.out)
    if args.convert_existing:
        print("converting the originals:")
        convert_existing(args.out)


if __name__ == "__main__":
    main()
