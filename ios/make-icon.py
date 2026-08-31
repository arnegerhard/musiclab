#!/usr/bin/env python3
"""Turn source artwork into the app icon.

    python make-icon.py musiclab-icon.png

App icons cannot be dropped in as-is. iOS masks every icon with its own
superellipse and shows no transparency, so the source has to be square,
full-bleed, opaque, and free of any border of its own -- otherwise you get a
dark frame around a smaller icon, or corners rounded twice.

The artwork here arrived as a rounded square letterboxed in black, so this:

  1. crops to the artwork, squared and centred;
  2. repaints the black surround, and the rim where it faded into the frame,
     in the frame's own colour;
  3. resizes to 1024 and saves without an alpha channel.
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

DESTINATION = Path("Musiclab/Assets.xcassets/AppIcon.appiconset/icon-1024.png")
BACKGROUND_MAX = 60   # sum of RGB below this is the black surround
DILATE = 15           # swallows the anti-aliased rim, which a threshold cannot
RING = 4              # outermost pixels, uniformly the frame colour


def build(source: Path, destination: Path = DESTINATION) -> None:
    image = Image.open(source).convert("RGB")
    pixels = np.asarray(image).astype(float)

    # Square crop centred on whatever is not background.
    ys, xs = np.where(pixels.sum(axis=2) > 40)
    if not len(xs):
        raise SystemExit(f"{source} looks empty")
    centre_x = (xs.min() + xs.max()) / 2
    centre_y = (ys.min() + ys.max()) / 2
    side = max(xs.max() - xs.min(), ys.max() - ys.min()) + 1
    left = max(0, int(round(centre_x - side / 2)))
    top = max(0, int(round(centre_y - side / 2)))
    side = int(min(side, pixels.shape[1] - left, pixels.shape[0] - top))
    crop = pixels[top:top + side, left:left + side].copy()

    # The frame colour, sampled just inside the left edge at mid height.
    frame = crop[side // 2, min(side - 1, 20)].copy()

    mask = Image.fromarray(((crop.sum(axis=2) < BACKGROUND_MAX) * 255).astype(np.uint8), "L")
    fill = (np.asarray(mask.filter(ImageFilter.MaxFilter(DILATE))).astype(float) / 255)[..., None]
    flat = crop * (1 - fill) + frame * fill

    # At the bounding box the outer ring is either the frame's edge or a
    # rounded-corner gap; both are the frame colour, so say so directly.
    flat[:RING, :] = frame
    flat[-RING:, :] = frame
    flat[:, :RING] = frame
    flat[:, -RING:] = frame

    icon = Image.fromarray(flat.round().astype(np.uint8), "RGB").resize(
        (1024, 1024), Image.LANCZOS
    )
    destination.parent.mkdir(parents=True, exist_ok=True)
    icon.save(destination, format="PNG")

    edges = np.asarray(icon).astype(int).sum(axis=2)
    darkest = min(edges[0].min(), edges[-1].min(), edges[:, 0].min(), edges[:, -1].min())
    print(f"{source} -> {destination}  (1024x1024, no alpha)")
    print(f"frame colour {frame.astype(int).tolist()}, darkest edge {darkest}")


if __name__ == "__main__":
    build(Path(sys.argv[1] if len(sys.argv) > 1 else "musiclab-icon.png"))
