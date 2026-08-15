"""Turn a sliced G-code file into something you can look at.

Until now slicing produced a number - four hours, ninety grams - and nothing to
see. That is the difference between the app and a slicer: you cannot tell
whether the first layer covers the bed, where the supports landed, or whether
the part you thought you were printing is the part that got sliced.

This reads the file the slicer already wrote and turns each layer into a set of
polylines, classified by what the nozzle was doing: outer wall, inner wall,
infill, support, or a travel move with nothing coming out.

Three decisions shape everything here.

**One layer at a time.** A 50 MB G-code file holds millions of coordinates and
no phone wants them all. Layers are extracted individually and on demand, so
opening the preview costs one layer's worth of work rather than the file's.

**The index is built once and cached.** Finding where layer 300 starts means
scanning to it, so the first pass records the byte offset of every layer. After
that any layer is a seek, and scrubbing the slider is instant.

**Feature type comes from the slicer's own comments.** PrusaSlicer writes
`;TYPE:External perimeter`, Orca and Cura write their own spellings. Guessing
from geometry would be inventing information the file already contains - so
where the comment is missing, the answer is "unknown" rather than a guess.
"""

from __future__ import annotations

import json
import logging
import re
import struct
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple

log = logging.getLogger("neptune.gcode.preview")

#: Bump when the on-disk format changes, so a stale cache is regenerated rather
#: than decoded as though it were current.
CACHE_VERSION = 1

#: Coordinates are rounded to this many decimals before being sent. A printer
#: positions to about 0.01 mm and a phone screen shows rather less, so more
#: precision than this is bytes with no picture in them.
COORDINATE_DECIMALS = 3

#: Refuse to index anything larger. A file past this is not a print somebody is
#: about to run on a Neptune; it is a mistake, and scanning it would tie up the
#: Pi for minutes.
MAX_FILE_BYTES = 600 * 1024 * 1024


class PreviewError(RuntimeError):
    pass


# --------------------------------------------------------------------------- #
# Feature types
# --------------------------------------------------------------------------- #


class Feature:
    """What the nozzle was doing, in the app's own vocabulary.

    Deliberately a small set. Slicers distinguish a dozen kinds of perimeter and
    the difference matters to a slicer; on a phone screen it is five colours or
    it is a mess.
    """

    OUTER_WALL = "outer_wall"
    INNER_WALL = "inner_wall"
    INFILL = "infill"
    SOLID = "solid"
    SUPPORT = "support"
    SKIRT = "skirt"
    BRIDGE = "bridge"
    TRAVEL = "travel"
    UNKNOWN = "unknown"

    #: Everything that puts plastic down. Travel is the odd one out and the app
    #: hides it by default, because a layer with its travels drawn is a
    #: scribble.
    EXTRUDING = frozenset({
        OUTER_WALL, INNER_WALL, INFILL, SOLID, SUPPORT, SKIRT, BRIDGE, UNKNOWN
    })


#: `;TYPE:` values, lower-cased, mapped to the app's vocabulary.
#:
#: Covers PrusaSlicer/SuperSlicer, OrcaSlicer/Bambu Studio and Cura, because all
#: three are plausible sources for a file that lands on this printer - the app's
#: own slicer is only one of them.
_TYPE_MAP: Dict[str, str] = {
    # PrusaSlicer / SuperSlicer
    "external perimeter": Feature.OUTER_WALL,
    "perimeter": Feature.INNER_WALL,
    "overhang perimeter": Feature.BRIDGE,
    "internal infill": Feature.INFILL,
    "solid infill": Feature.SOLID,
    "top solid infill": Feature.SOLID,
    "bridge infill": Feature.BRIDGE,
    "gap fill": Feature.SOLID,
    "skirt": Feature.SKIRT,
    "skirt/brim": Feature.SKIRT,
    "brim": Feature.SKIRT,
    "support material": Feature.SUPPORT,
    "support material interface": Feature.SUPPORT,
    "wipe tower": Feature.SKIRT,
    "custom": Feature.UNKNOWN,
    # OrcaSlicer / Bambu Studio
    "outer wall": Feature.OUTER_WALL,
    "inner wall": Feature.INNER_WALL,
    "sparse infill": Feature.INFILL,
    "internal solid infill": Feature.SOLID,
    "top surface": Feature.SOLID,
    "bottom surface": Feature.SOLID,
    "bridge": Feature.BRIDGE,
    "overhang wall": Feature.BRIDGE,
    "support": Feature.SUPPORT,
    "support interface": Feature.SUPPORT,
    "prime tower": Feature.SKIRT,
    # Cura
    "wall-outer": Feature.OUTER_WALL,
    "wall-inner": Feature.INNER_WALL,
    "fill": Feature.INFILL,
    "skin": Feature.SOLID,
    "support-interface": Feature.SUPPORT,
    "prime-tower": Feature.SKIRT,
}


def classify(raw: str) -> str:
    """Map a slicer's `;TYPE:` value onto the app's vocabulary."""
    key = raw.strip().lower()
    if key in _TYPE_MAP:
        return _TYPE_MAP[key]
    # Unseen spellings are common - every slicer release adds one - so fall back
    # to the words rather than to "unknown", which would lose a whole feature.
    if "support" in key:
        return Feature.SUPPORT
    if "bridge" in key or "overhang" in key:
        return Feature.BRIDGE
    if "skirt" in key or "brim" in key or "tower" in key:
        return Feature.SKIRT
    if "external" in key or "outer" in key:
        return Feature.OUTER_WALL
    if "perimeter" in key or "wall" in key:
        return Feature.INNER_WALL
    if "solid" in key or "skin" in key or "surface" in key:
        return Feature.SOLID
    if "infill" in key or "fill" in key:
        return Feature.INFILL
    return Feature.UNKNOWN


# --------------------------------------------------------------------------- #
# The index
# --------------------------------------------------------------------------- #


_LAYER_MARKERS = (
    re.compile(rb"^;LAYER_CHANGE"),                 # PrusaSlicer / Orca
    re.compile(rb"^;LAYER:\s*-?\d+"),               # Cura
    re.compile(rb"^;\s*layer\s+\d+", re.IGNORECASE),
)

_Z_COMMENT = re.compile(rb"^;Z:\s*([0-9.]+)")


@dataclass
class LayerIndexEntry:
    """Where a layer starts in the file, and how high it is."""

    offset: int
    z: Optional[float] = None

    def as_dict(self) -> dict:
        return {"offset": self.offset, "z": self.z}


@dataclass
class PreviewIndex:
    """Everything the app needs before it asks for a single layer."""

    layers: List[LayerIndexEntry] = field(default_factory=list)
    #: Bounding box of every extruding move, so the view can frame the print
    #: rather than the bed - a 20 mm part on a 320 mm bed is otherwise a dot.
    min_x: float = 0.0
    min_y: float = 0.0
    max_x: float = 0.0
    max_y: float = 0.0
    #: Layers at which the file stops for a filament swap, so the scrubber can
    #: mark them. Ties the preview to the colour feature already built.
    color_change_layers: List[int] = field(default_factory=list)
    file_size: int = 0
    version: int = CACHE_VERSION

    @property
    def layer_count(self) -> int:
        return len(self.layers)

    def as_dict(self) -> dict:
        return {
            "version": self.version,
            "file_size": self.file_size,
            "layer_count": self.layer_count,
            "layers": [entry.as_dict() for entry in self.layers],
            "bounds": {
                "min_x": self.min_x, "min_y": self.min_y,
                "max_x": self.max_x, "max_y": self.max_y,
            },
            "color_change_layers": self.color_change_layers,
        }

    @classmethod
    def from_dict(cls, data: dict) -> "PreviewIndex":
        bounds = data.get("bounds") or {}
        return cls(
            layers=[
                LayerIndexEntry(offset=int(entry["offset"]), z=entry.get("z"))
                for entry in data.get("layers", [])
            ],
            min_x=float(bounds.get("min_x", 0.0)),
            min_y=float(bounds.get("min_y", 0.0)),
            max_x=float(bounds.get("max_x", 0.0)),
            max_y=float(bounds.get("max_y", 0.0)),
            color_change_layers=[int(value) for value in data.get("color_change_layers", [])],
            file_size=int(data.get("file_size", 0)),
            version=int(data.get("version", 0)),
        )


def build_index(path: Path) -> PreviewIndex:
    """Scan the file once, recording where every layer starts.

    Reads bytes rather than decoded text: a G-code file is ASCII with the
    occasional stray byte in a comment, and decoding 50 MB to find newlines is
    work with no product.
    """
    path = Path(path)
    if not path.is_file():
        raise PreviewError("ملف الجي كود مش موجود.")

    size = path.stat().st_size
    if size > MAX_FILE_BYTES:
        raise PreviewError(
            f"الملف أكبر من {MAX_FILE_BYTES // (1024 * 1024)} ميجا - كبير جدًا على المعاينة."
        )

    index = PreviewIndex(file_size=size)
    min_x = min_y = float("inf")
    max_x = max_y = float("-inf")

    x = y = 0.0
    absolute = True
    pending_z: Optional[float] = None

    with path.open("rb") as handle:
        offset = 0
        for line in handle:
            length = len(line)
            stripped = line.lstrip()

            if stripped.startswith(b";"):
                if any(marker.match(stripped) for marker in _LAYER_MARKERS):
                    index.layers.append(LayerIndexEntry(offset=offset, z=pending_z))
                    pending_z = None
                else:
                    match = _Z_COMMENT.match(stripped)
                    if match:
                        try:
                            z = float(match.group(1))
                        except ValueError:
                            z = None
                        if z is not None:
                            # PrusaSlicer writes ;Z: *after* ;LAYER_CHANGE, so
                            # it belongs to the layer just opened.
                            if index.layers and index.layers[-1].z is None:
                                index.layers[-1].z = z
                            else:
                                pending_z = z
                    elif b"COLOR_CHANGE" in stripped:
                        index.color_change_layers.append(max(0, len(index.layers)))
                offset += length
                continue

            upper = stripped[:4].upper()
            if upper.startswith(b"G90"):
                absolute = True
            elif upper.startswith(b"G91"):
                absolute = False
            elif upper.startswith(b"G0") or upper.startswith(b"G1"):
                new_x, new_y, extruding = _parse_move(stripped)
                if new_x is not None:
                    x = new_x if absolute else x + new_x
                if new_y is not None:
                    y = new_y if absolute else y + new_y
                # Only extruding moves define the print's extent. Travels go out
                # to the purge line and the parking corner, and letting those
                # set the bounds frames the whole bed around an empty middle.
                if extruding:
                    min_x = min(min_x, x)
                    max_x = max(max_x, x)
                    min_y = min(min_y, y)
                    max_y = max(max_y, y)

            offset += length

    if min_x <= max_x:
        index.min_x, index.max_x = min_x, max_x
        index.min_y, index.max_y = min_y, max_y

    if not index.layers:
        raise PreviewError(
            "مفيش علامات طبقات في الملف ده، فمش هينفع أعرضه طبقة طبقة."
        )

    return index


_COORD = {
    b"X": "x", b"Y": "y", b"Z": "z", b"E": "e",
}


def _parse_move(line: bytes) -> Tuple[Optional[float], Optional[float], bool]:
    """X, Y and whether anything was extruded, from one G0/G1 line.

    Hand-rolled rather than regex: this runs on every line of a file that can
    hold two million of them, and on a Pi the difference is seconds.
    """
    x: Optional[float] = None
    y: Optional[float] = None
    extruding = False

    for token in line.split():
        if not token:
            continue
        letter = token[0:1].upper()
        if letter not in _COORD:
            continue
        raw = token[1:]
        # A trailing comment can be glued to the last token.
        semicolon = raw.find(b";")
        if semicolon >= 0:
            raw = raw[:semicolon]
        try:
            value = float(raw)
        except ValueError:
            continue
        if letter == b"X":
            x = value
        elif letter == b"Y":
            y = value
        elif letter == b"E":
            # Negative E is a retraction, which lays nothing down.
            if value > 0:
                extruding = True

    return x, y, extruding


# --------------------------------------------------------------------------- #
# One layer
# --------------------------------------------------------------------------- #


@dataclass
class Segment:
    """A run of moves of one kind, as a flat [x, y, x, y, ...] list."""

    feature: str
    points: List[float] = field(default_factory=list)

    def as_dict(self) -> dict:
        return {"feature": self.feature, "points": self.points}


@dataclass
class LayerPreview:
    index: int
    z: Optional[float]
    segments: List[Segment] = field(default_factory=list)

    def as_dict(self) -> dict:
        return {
            "index": self.index,
            "z": self.z,
            "segments": [segment.as_dict() for segment in self.segments],
        }


def read_layer(
    path: Path,
    index: PreviewIndex,
    layer: int,
    *,
    include_travel: bool = False,
) -> LayerPreview:
    """Extract one layer's toolpath.

    Seeks straight to the layer using the index, so this costs the size of one
    layer rather than the size of the file.

    The position at the start of the layer is not known without replaying
    everything before it, so the first move of each segment is treated as a
    starting point rather than as a line from wherever the previous layer
    ended - which would otherwise draw a stripe across the part.
    """
    if not index.layers:
        raise PreviewError("مفيش فهرس للطبقات.")
    if layer < 0 or layer >= len(index.layers):
        raise PreviewError(f"الطبقة {layer} مش موجودة.")

    start = index.layers[layer].offset
    end = (
        index.layers[layer + 1].offset
        if layer + 1 < len(index.layers)
        else index.file_size
    )

    segments: List[Segment] = []
    current: Optional[Segment] = None
    feature = Feature.UNKNOWN

    x = y = 0.0
    absolute = True
    have_position = False

    with Path(path).open("rb") as handle:
        handle.seek(start)
        remaining = end - start
        for line in handle:
            if remaining <= 0:
                break
            remaining -= len(line)
            stripped = line.lstrip()

            if stripped.startswith(b";"):
                lowered = stripped.lower()
                if lowered.startswith(b";type:"):
                    feature = classify(stripped[6:].decode("ascii", "replace"))
                    current = None          # a new kind starts a new segment
                continue

            upper = stripped[:4].upper()
            if upper.startswith(b"G90"):
                absolute = True
                continue
            if upper.startswith(b"G91"):
                absolute = False
                continue
            if not (upper.startswith(b"G0") or upper.startswith(b"G1")):
                continue

            new_x, new_y, extruding = _parse_move(stripped)
            if new_x is None and new_y is None:
                continue      # a Z-only or E-only move draws nothing

            previous = (x, y)
            if new_x is not None:
                x = new_x if absolute else x + new_x
            if new_y is not None:
                y = new_y if absolute else y + new_y

            kind = feature if extruding else Feature.TRAVEL
            if kind == Feature.TRAVEL and not include_travel:
                current = None                     # break the line, keep the pen up
                have_position = True
                continue

            if current is None or current.feature != kind:
                current = Segment(feature=kind)
                segments.append(current)
                # Start from where the nozzle already was, so the segment is a
                # line rather than a point - unless this is the very first move
                # of the layer, whose start is genuinely unknown.
                if have_position:
                    current.points.extend(
                        [round(previous[0], COORDINATE_DECIMALS),
                         round(previous[1], COORDINATE_DECIMALS)]
                    )

            current.points.extend(
                [round(x, COORDINATE_DECIMALS), round(y, COORDINATE_DECIMALS)]
            )
            have_position = True

    # A segment of one point draws nothing and only costs bytes.
    segments = [segment for segment in segments if len(segment.points) >= 4]

    return LayerPreview(index=layer, z=index.layers[layer].z, segments=segments)


# --------------------------------------------------------------------------- #
# Caching
# --------------------------------------------------------------------------- #


def cache_path_for(gcode_path: Path, cache_dir: Path) -> Path:
    """Where this file's index lives.

    Keyed by name and size rather than by a hash of the contents: hashing a
    50 MB file to decide whether to read it defeats the point, and a re-slice
    that produces the same name and the same byte count is the same file for
    every purpose here.
    """
    stem = Path(gcode_path).name
    size = Path(gcode_path).stat().st_size if Path(gcode_path).is_file() else 0
    return Path(cache_dir) / f"{stem}.{size}.preview.json"


def load_or_build_index(gcode_path: Path, cache_dir: Path) -> PreviewIndex:
    """The index, from cache when it is still valid.

    An index whose recorded size no longer matches the file is stale - the file
    was replaced under the same name - and is rebuilt rather than trusted, which
    would seek to offsets that no longer mean anything.
    """
    gcode_path = Path(gcode_path)
    cache_dir = Path(cache_dir)
    cache_dir.mkdir(parents=True, exist_ok=True)
    cache = cache_path_for(gcode_path, cache_dir)

    if cache.is_file():
        try:
            data = json.loads(cache.read_text(encoding="utf-8"))
            index = PreviewIndex.from_dict(data)
            if (
                index.version == CACHE_VERSION
                and index.file_size == gcode_path.stat().st_size
                and index.layers
            ):
                return index
        except Exception as error:                          # noqa: BLE001
            log.warning("Discarding unreadable preview cache %s: %s", cache.name, error)

    index = build_index(gcode_path)
    try:
        cache.write_text(json.dumps(index.as_dict()), encoding="utf-8")
    except OSError as error:
        # A full disk must not stop the preview - it just means the next open
        # pays for the scan again.
        log.warning("Could not write preview cache: %s", error)
    return index
