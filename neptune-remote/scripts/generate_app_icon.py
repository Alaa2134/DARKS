#!/usr/bin/env python3
"""Generate the app icon for Neptune 3 Plus Remote.

The icon is drawn rather than shipped as a binary blob so it can be tweaked and
regenerated deterministically, and so the repository carries the recipe rather
than an opaque PNG nobody can edit.

Design: a deep Neptune-blue field, a printed object rising in visible layers off
a bed, and the nozzle above it. It reads at 60px on a home screen because the
silhouette is one solid shape with a lot of contrast against the background.

    python3 scripts/generate_app_icon.py

Writes ios/NeptuneRemote/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png
and the matching widget icon. iOS 17+ only needs the single 1024x1024 source;
Xcode downsamples the rest at build time.
"""
from __future__ import annotations

import json
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
ROOT = Path(__file__).resolve().parent.parent
APPICON = ROOT / "ios/NeptuneRemote/Resources/Assets.xcassets/AppIcon.appiconset"
WIDGET_ASSETS = ROOT / "ios/NeptuneRemoteWidget/Assets.xcassets"

# Neptune: deep ocean blue into a lighter cyan, with a warm nozzle accent.
BG_TOP = (18, 32, 74)
BG_BOTTOM = (10, 16, 38)
ACCENT = (64, 156, 255)
ACCENT_SOFT = (120, 196, 255)
FILAMENT = (255, 143, 64)
BED = (150, 172, 210)


def vertical_gradient(size: int, top: tuple, bottom: tuple) -> Image.Image:
    """A plain top-to-bottom gradient; the base the whole icon sits on."""
    image = Image.new("RGB", (1, size))
    pixels = image.load()
    for y in range(size):
        t = y / max(size - 1, 1)
        pixels[0, y] = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
    return image.resize((size, size), Image.BICUBIC)


def radial_glow(size: int, centre: tuple, radius: float, colour: tuple, strength: float) -> Image.Image:
    """Soft light behind the object, so the layers do not sit on a flat field."""
    glow = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(glow)
    steps = 48
    for i in range(steps, 0, -1):
        r = radius * i / steps
        value = int(255 * strength * (1 - i / steps) ** 1.6)
        draw.ellipse(
            [centre[0] - r, centre[1] - r, centre[0] + r, centre[1] + r],
            fill=value,
        )
    glow = glow.filter(ImageFilter.GaussianBlur(size * 0.03))
    layer = Image.new("RGB", (size, size), colour)
    return Image.composite(layer, Image.new("RGB", (size, size), (0, 0, 0)), glow), glow


def draw_icon() -> Image.Image:
    canvas = vertical_gradient(SIZE, BG_TOP, BG_BOTTOM).convert("RGBA")

    glow_rgb, glow_mask = radial_glow(
        SIZE, (SIZE * 0.5, SIZE * 0.62), SIZE * 0.42, ACCENT, 0.55
    )
    canvas = Image.alpha_composite(canvas, Image.merge("RGBA", (*glow_rgb.split(), glow_mask)))

    layer = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)

    # --- The printed object: a stack of extruded layers, widest at the base.
    # Slight taper and per-layer inset is what makes it read as "3D print"
    # rather than "stack of bars".
    # The object is one solid silhouette with layer lines drawn across it.
    # Stacking separate rounded rectangles instead makes it read as a pile of
    # coins, because every layer edge gets outlined against the background.
    base_y = SIZE * 0.745
    top_y = SIZE * 0.355
    layer_h = SIZE * 0.030
    max_half = SIZE * 0.225
    cx = SIZE * 0.5

    def half_width(y: float) -> float:
        """Vase profile: wide base, gentle waist, small flare at the rim."""
        t = (base_y - y) / (base_y - top_y)
        return max_half * (1.0 - 0.17 * math.sin(t * math.pi) - 0.12 * t)

    samples = 200
    left, right = [], []
    for i in range(samples + 1):
        y = base_y - (base_y - top_y) * i / samples
        half = half_width(y)
        left.append((cx - half, y))
        right.append((cx + half, y))

    body = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    ImageDraw.Draw(body).polygon(left + list(reversed(right)), fill=(*ACCENT_SOFT, 255))
    mask = body.split()[3]

    # Layer lines: thin seams across the body at print-layer spacing. Drawn on
    # top of the solid shape, then clipped back to it.
    seams = ImageDraw.Draw(body)
    y = base_y - layer_h
    while y > top_y:
        half = half_width(y)
        seams.rectangle(
            [cx - half, y - SIZE * 0.0035, cx + half, y], fill=(26, 66, 132, 95)
        )
        seams.rectangle(
            [cx - half, y, cx + half, y + SIZE * 0.0035], fill=(255, 255, 255, 42)
        )
        y -= layer_h

    # A single horizontal gradient across the body gives it volume. Drawing
    # per-row side bars instead produced visible vertical banding.
    columns = Image.new("L", (SIZE, 1))
    pixels = columns.load()
    for x in range(SIZE):
        # 0 at the centre, 1 at either edge of the object.
        d = min(abs(x - cx) / max_half, 1.0)
        pixels[x, 0] = int(150 * d ** 1.7)
    shade = Image.new("RGBA", (SIZE, SIZE), (10, 38, 88, 255))
    shade.putalpha(columns.resize((SIZE, SIZE), Image.BICUBIC))
    body = Image.alpha_composite(body, shade)

    body.putalpha(mask)
    layer = Image.alpha_composite(layer, body)
    draw = ImageDraw.Draw(layer)

    # --- The bed the object is printed on.
    bed_y = base_y + SIZE * 0.028
    draw.rounded_rectangle(
        [SIZE * 0.19, bed_y, SIZE * 0.81, bed_y + SIZE * 0.038],
        radius=SIZE * 0.019,
        fill=(*BED, 255),
    )
    draw.rounded_rectangle(
        [SIZE * 0.19, bed_y, SIZE * 0.81, bed_y + SIZE * 0.013],
        radius=SIZE * 0.007,
        fill=(255, 255, 255, 70),
    )

    # --- The hotend above, with filament coming out of it.
    nozzle_cx = SIZE * 0.5
    body_top = SIZE * 0.145
    body_bottom = SIZE * 0.262
    draw.rounded_rectangle(
        [nozzle_cx - SIZE * 0.105, body_top, nozzle_cx + SIZE * 0.105, body_bottom],
        radius=SIZE * 0.030,
        fill=(232, 240, 255, 255),
    )
    # Tip: a tapered nozzle down to a point.
    draw.polygon(
        [
            (nozzle_cx - SIZE * 0.052, body_bottom),
            (nozzle_cx + SIZE * 0.052, body_bottom),
            (nozzle_cx + SIZE * 0.017, body_bottom + SIZE * 0.062),
            (nozzle_cx - SIZE * 0.017, body_bottom + SIZE * 0.062),
        ],
        fill=(206, 219, 242, 255),
    )
    # A bead of hot filament between the nozzle and the top layer.
    draw.rounded_rectangle(
        [
            nozzle_cx - SIZE * 0.012,
            body_bottom + SIZE * 0.055,
            nozzle_cx + SIZE * 0.012,
            SIZE * 0.352,
        ],
        radius=SIZE * 0.012,
        fill=(*FILAMENT, 255),
    )

    canvas = Image.alpha_composite(canvas, layer)
    return canvas.convert("RGB")


def write_contents(directory: Path, filename: str) -> None:
    payload = {
        "images": [
            {
                "filename": filename,
                "idiom": "universal",
                "platform": "ios",
                "size": "1024x1024",
            }
        ],
        "info": {"author": "xcode", "version": 1},
    }
    (directory / "Contents.json").write_text(json.dumps(payload, indent=2) + "\n")


def main() -> None:
    icon = draw_icon()

    APPICON.mkdir(parents=True, exist_ok=True)
    icon.save(APPICON / "icon-1024.png", "PNG")
    write_contents(APPICON, "icon-1024.png")
    print(f"wrote {APPICON / 'icon-1024.png'}")

    widget_icon = WIDGET_ASSETS / "AppIcon.appiconset"
    if WIDGET_ASSETS.exists():
        widget_icon.mkdir(parents=True, exist_ok=True)
        icon.save(widget_icon / "icon-1024.png", "PNG")
        write_contents(widget_icon, "icon-1024.png")
        print(f"wrote {widget_icon / 'icon-1024.png'}")

    preview = ROOT / "docs/app-icon.png"
    icon.resize((512, 512), Image.LANCZOS).save(preview, "PNG")
    print(f"wrote {preview}")


if __name__ == "__main__":
    main()
