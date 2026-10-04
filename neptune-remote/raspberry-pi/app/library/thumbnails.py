"""Server-side thumbnail rendering for 3D models.

A small software rasteriser (numpy z-buffer + flat shading) draws the mesh from
a fixed three-quarter view and writes a PNG with Pillow. No GPU, no OpenGL, no
X server - it runs happily on a headless Raspberry Pi.

Two images are produced per model:

    <id>.png        512x512 thumbnail  (grid cards)
    <id>_hero.png   1024x768 hero shot (detail page)

If numpy or Pillow are missing the renderer reports failure instead of writing
a fake image, and the caller falls back to the neutral generated card.
"""

from __future__ import annotations

import logging
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Optional, Tuple

from .mesh import Mesh, MeshError, load

log = logging.getLogger("neptune.library.thumbnails")

try:
    import numpy as np
except ImportError:  # pragma: no cover
    np = None  # type: ignore

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:  # pragma: no cover
    Image = None  # type: ignore
    ImageDraw = None  # type: ignore
    ImageFont = None  # type: ignore


THUMBNAIL_SIZE = (512, 512)
HERO_SIZE = (1024, 768)

# Neptune Remote accent colours.
MODEL_COLOR = (61, 140, 242)
BACKGROUND_TOP = (28, 32, 40)
BACKGROUND_BOTTOM = (16, 18, 24)
PLATE_COLOR = (48, 54, 66)


def renderer_available() -> bool:
    return np is not None and Image is not None


@dataclass
class RenderResult:
    thumbnail: Optional[Path]
    hero: Optional[Path]
    error: str = ""

    @property
    def ok(self) -> bool:
        return self.thumbnail is not None


# --------------------------------------------------------------------------- #
# Geometry helpers
# --------------------------------------------------------------------------- #


def _rotation_matrix(yaw_degrees: float, pitch_degrees: float) -> "np.ndarray":
    yaw = math.radians(yaw_degrees)
    pitch = math.radians(pitch_degrees)

    # Z-up model space -> camera space.
    rotate_z = np.array([
        [math.cos(yaw), -math.sin(yaw), 0.0],
        [math.sin(yaw), math.cos(yaw), 0.0],
        [0.0, 0.0, 1.0],
    ])
    rotate_x = np.array([
        [1.0, 0.0, 0.0],
        [0.0, math.cos(pitch), -math.sin(pitch)],
        [0.0, math.sin(pitch), math.cos(pitch)],
    ])
    return rotate_x @ rotate_z


def _shade(normals: "np.ndarray") -> "np.ndarray":
    """Lambert shading with a soft ambient term, returns 0..1 per triangle."""
    light = np.array([0.45, -0.6, 0.75])
    light = light / np.linalg.norm(light)
    lengths = np.linalg.norm(normals, axis=1)
    lengths[lengths == 0] = 1.0
    unit = normals / lengths[:, None]
    lambert = np.abs(unit @ light)
    return 0.32 + 0.68 * lambert


# --------------------------------------------------------------------------- #
# Rasteriser
# --------------------------------------------------------------------------- #


def _rasterise(mesh: Mesh, width: int, height: int) -> "np.ndarray":
    """Return an (height, width, 3) uint8 image of the mesh."""
    triangles = mesh.triangles
    rotation = _rotation_matrix(yaw_degrees=35.0, pitch_degrees=-62.0)

    points = triangles.reshape(-1, 3) @ rotation.T
    rotated = points.reshape(-1, 3, 3)

    minimum = points.min(axis=0)
    maximum = points.max(axis=0)
    extent = maximum - minimum
    span = float(max(extent[0], extent[1]))
    if span <= 0:
        span = 1.0

    margin = 0.10
    scale = (1.0 - 2 * margin) * min(width, height) / span
    center_x = (minimum[0] + maximum[0]) / 2
    center_y = (minimum[1] + maximum[1]) / 2

    screen_x = (rotated[:, :, 0] - center_x) * scale + width / 2
    # Screen y grows downwards.
    screen_y = height / 2 - (rotated[:, :, 1] - center_y) * scale
    depth = rotated[:, :, 2]

    # Flat-shade using the geometric normal of each triangle.
    edge1 = rotated[:, 1, :] - rotated[:, 0, :]
    edge2 = rotated[:, 2, :] - rotated[:, 0, :]
    normals = np.cross(edge1, edge2)
    shade = _shade(normals)

    # Background gradient.
    image = np.zeros((height, width, 3), dtype=np.float32)
    gradient = np.linspace(0.0, 1.0, height, dtype=np.float32)[:, None]
    for channel in range(3):
        image[:, :, channel] = (
            BACKGROUND_TOP[channel] * (1 - gradient) + BACKGROUND_BOTTOM[channel] * gradient
        )

    z_buffer = np.full((height, width), -np.inf, dtype=np.float64)

    # Painter order helps a little, the z-buffer does the real work.
    order = np.argsort(depth.mean(axis=1))

    base = np.array(MODEL_COLOR, dtype=np.float32)

    for index in order:
        xs = screen_x[index]
        ys = screen_y[index]
        zs = depth[index]

        min_x = int(math.floor(max(0, xs.min())))
        max_x = int(math.ceil(min(width - 1, xs.max())))
        min_y = int(math.floor(max(0, ys.min())))
        max_y = int(math.ceil(min(height - 1, ys.max())))
        if min_x > max_x or min_y > max_y:
            continue

        x0, y0 = xs[0], ys[0]
        x1, y1 = xs[1], ys[1]
        x2, y2 = xs[2], ys[2]
        area = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0)
        if abs(area) < 1e-9:
            continue

        grid_y, grid_x = np.mgrid[min_y:max_y + 1, min_x:max_x + 1]
        px = grid_x + 0.5
        py = grid_y + 0.5

        w0 = ((x1 - px) * (y2 - py) - (x2 - px) * (y1 - py)) / area
        w1 = ((x2 - px) * (y0 - py) - (x0 - px) * (y2 - py)) / area
        w2 = 1.0 - w0 - w1

        inside = (w0 >= 0) & (w1 >= 0) & (w2 >= 0)
        if not inside.any():
            continue

        pixel_depth = w0 * zs[0] + w1 * zs[1] + w2 * zs[2]
        window = z_buffer[min_y:max_y + 1, min_x:max_x + 1]
        visible = inside & (pixel_depth > window)
        if not visible.any():
            continue

        window[visible] = pixel_depth[visible]
        colour = base * float(shade[index])
        target = image[min_y:max_y + 1, min_x:max_x + 1]
        target[visible] = colour

    return np.clip(image, 0, 255).astype(np.uint8)


# --------------------------------------------------------------------------- #
# Public API
# --------------------------------------------------------------------------- #


def render_model(
    model_path: Path,
    output_dir: Path,
    identifier: str,
    *,
    hero: bool = True,
) -> RenderResult:
    """Render ``model_path`` into ``output_dir`` as ``<identifier>.png``."""
    if not renderer_available():
        return RenderResult(None, None, "numpy and Pillow are required for thumbnails")

    try:
        mesh = load(Path(model_path))
    except (MeshError, OSError, ValueError) as exc:
        return RenderResult(None, None, str(exc))

    if mesh.triangle_count == 0:
        return RenderResult(None, None, "model contains no triangles")

    # Very dense meshes are decimated by sampling: a thumbnail does not need
    # 2 million triangles, and this keeps rendering well under a second.
    working = mesh
    max_triangles = 120_000
    if mesh.triangle_count > max_triangles:
        step = mesh.triangle_count // max_triangles + 1
        working = Mesh(triangles=mesh.triangles[::step])

    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    try:
        thumbnail_pixels = _rasterise(working, *THUMBNAIL_SIZE)
        thumbnail_path = output_dir / f"{identifier}.png"
        Image.fromarray(thumbnail_pixels, mode="RGB").save(thumbnail_path, format="PNG", optimize=True)

        hero_path: Optional[Path] = None
        if hero:
            hero_pixels = _rasterise(working, *HERO_SIZE)
            hero_path = output_dir / f"{identifier}_hero.png"
            Image.fromarray(hero_pixels, mode="RGB").save(hero_path, format="PNG", optimize=True)
    except Exception as exc:  # rendering must never take the API down
        log.exception("Thumbnail rendering failed for %s", model_path)
        return RenderResult(None, None, f"render failed: {exc}")

    return RenderResult(thumbnail=thumbnail_path, hero=hero_path)


def render_placeholder(
    output_dir: Path,
    identifier: str,
    label: str,
    *,
    size: Tuple[int, int] = THUMBNAIL_SIZE,
) -> Optional[Path]:
    """Neutral fallback card used when a model cannot be rendered.

    It is clearly a placeholder - it never pretends to be a render of the model.
    """
    if Image is None:
        return None

    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    path = output_dir / f"{identifier}_placeholder.png"

    width, height = size
    image = Image.new("RGB", size, BACKGROUND_TOP)
    draw = ImageDraw.Draw(image)

    for y in range(height):
        ratio = y / max(1, height - 1)
        colour = tuple(
            int(BACKGROUND_TOP[channel] * (1 - ratio) + BACKGROUND_BOTTOM[channel] * ratio)
            for channel in range(3)
        )
        draw.line([(0, y), (width, y)], fill=colour)

    # Simple isometric cube outline so the card still reads as "a 3D model".
    cx, cy = width / 2, height / 2
    unit = min(width, height) * 0.18
    top = [(cx, cy - unit), (cx + unit, cy - unit / 2), (cx, cy), (cx - unit, cy - unit / 2)]
    left = [(cx - unit, cy - unit / 2), (cx, cy), (cx, cy + unit), (cx - unit, cy + unit / 2)]
    right = [(cx + unit, cy - unit / 2), (cx, cy), (cx, cy + unit), (cx + unit, cy + unit / 2)]
    draw.polygon(top, fill=(78, 150, 235))
    draw.polygon(left, fill=(48, 104, 180))
    draw.polygon(right, fill=(62, 126, 210))

    if label:
        try:
            font = ImageFont.load_default()
            text = label[:28]
            box = draw.textbbox((0, 0), text, font=font)
            draw.text(
                ((width - (box[2] - box[0])) / 2, cy + unit * 1.8),
                text,
                fill=(200, 208, 220),
                font=font,
            )
        except Exception:
            pass

    image.save(path, format="PNG", optimize=True)
    return path


def extract_gcode_thumbnail(gcode_path: Path, output_dir: Path, identifier: str) -> Optional[Path]:
    """Pull the base64 PNG that PrusaSlicer embeds in the G-code header."""
    if Image is None:
        return None

    import base64

    gcode_path = Path(gcode_path)
    if not gcode_path.is_file():
        return None

    collecting = False
    chunks: list[str] = []
    best: Optional[bytes] = None

    try:
        with gcode_path.open("r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                if not line.startswith(";"):
                    if chunks or collecting:
                        continue
                    # Thumbnails live in the header; stop once real G-code starts.
                    if line.strip() and not line.startswith(";"):
                        break
                    continue
                stripped = line[1:].strip()
                if stripped.lower().startswith("thumbnail begin"):
                    collecting = True
                    chunks = []
                    continue
                if stripped.lower().startswith("thumbnail end"):
                    collecting = False
                    try:
                        candidate = base64.b64decode("".join(chunks))
                    except (ValueError, TypeError):
                        candidate = b""
                    if candidate and (best is None or len(candidate) > len(best)):
                        best = candidate
                    chunks = []
                    continue
                if collecting:
                    chunks.append(stripped)
    except OSError:
        return None

    if not best:
        return None

    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    path = output_dir / f"{identifier}_gcode.png"
    try:
        path.write_bytes(best)
        # Validate it really is an image before returning it.
        with Image.open(path) as image:
            image.verify()
    except Exception:
        path.unlink(missing_ok=True)
        return None
    return path
