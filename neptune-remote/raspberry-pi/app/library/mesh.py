"""Mesh loading for STL / OBJ / 3MF, using only the standard library + numpy.

Used to compute real bounding boxes and to render thumbnails on the Pi, so the
phone never has to download a 40 MB STL just to show a picture.
"""

from __future__ import annotations

import re
import struct
import xml.etree.ElementTree as ElementTree
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional, Tuple

try:
    import numpy as np
except ImportError:  # pragma: no cover - numpy is in requirements.txt
    np = None  # type: ignore

SUPPORTED_EXTENSIONS = {".stl", ".obj", ".3mf"}


class MeshError(RuntimeError):
    pass


@dataclass
class Mesh:
    """Triangle soup: ``triangles`` has shape (n, 3, 3)."""

    triangles: "np.ndarray"

    @property
    def triangle_count(self) -> int:
        return int(self.triangles.shape[0])

    @property
    def minimum(self) -> Tuple[float, float, float]:
        values = self.triangles.reshape(-1, 3).min(axis=0)
        return float(values[0]), float(values[1]), float(values[2])

    @property
    def maximum(self) -> Tuple[float, float, float]:
        values = self.triangles.reshape(-1, 3).max(axis=0)
        return float(values[0]), float(values[1]), float(values[2])

    @property
    def size(self) -> Tuple[float, float, float]:
        low = self.minimum
        high = self.maximum
        return (high[0] - low[0], high[1] - low[1], high[2] - low[2])

    @property
    def center(self) -> Tuple[float, float, float]:
        low = self.minimum
        high = self.maximum
        return ((low[0] + high[0]) / 2, (low[1] + high[1]) / 2, (low[2] + high[2]) / 2)


def _require_numpy() -> None:
    if np is None:
        raise MeshError("numpy is required to read meshes (pip install numpy)")


def load(path: Path) -> Mesh:
    _require_numpy()
    path = Path(path)
    if not path.is_file():
        raise MeshError(f"File not found: {path}")

    suffix = path.suffix.lower()
    if suffix == ".stl":
        return load_stl(path)
    if suffix == ".obj":
        return load_obj(path)
    if suffix == ".3mf":
        return load_3mf(path)
    raise MeshError(f"Unsupported model format: {suffix or 'unknown'}")


# --------------------------------------------------------------------------- #
# STL
# --------------------------------------------------------------------------- #


def load_stl(path: Path) -> Mesh:
    _require_numpy()
    data = path.read_bytes()
    if len(data) < 84:
        raise MeshError("STL file is too small")

    count = struct.unpack_from("<I", data, 80)[0]
    looks_binary = len(data) == 84 + count * 50

    if not looks_binary and data[:5].lower().lstrip() .startswith(b"solid"):
        return _load_ascii_stl(data)
    if not looks_binary and count * 50 + 84 > len(data):
        # Header claims more triangles than the file holds: try ASCII.
        return _load_ascii_stl(data)
    return _load_binary_stl(data, count)


def _load_binary_stl(data: bytes, count: int) -> Mesh:
    if count == 0:
        raise MeshError("STL contains no triangles")
    needed = 84 + count * 50
    if len(data) < needed:
        raise MeshError("Truncated binary STL")

    raw = np.frombuffer(data, dtype=np.uint8, count=count * 50, offset=84).reshape(count, 50)
    # Bytes 12..48 of each 50-byte record are the three vertices.
    vertex_bytes = raw[:, 12:48].copy()
    triangles = vertex_bytes.view(np.float32).reshape(count, 3, 3).astype(np.float64)
    return Mesh(triangles=triangles)


def _load_ascii_stl(data: bytes) -> Mesh:
    text = data.decode("utf-8", errors="replace")
    vertices: List[List[float]] = []
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped.lower().startswith("vertex"):
            continue
        parts = stripped.split()
        if len(parts) < 4:
            continue
        try:
            vertices.append([float(parts[1]), float(parts[2]), float(parts[3])])
        except ValueError:
            continue
    if len(vertices) < 3:
        raise MeshError("ASCII STL contains no triangles")
    usable = (len(vertices) // 3) * 3
    array = np.asarray(vertices[:usable], dtype=np.float64).reshape(-1, 3, 3)
    return Mesh(triangles=array)


# --------------------------------------------------------------------------- #
# OBJ
# --------------------------------------------------------------------------- #

FACE_INDEX = re.compile(r"^(-?\d+)")


def load_obj(path: Path) -> Mesh:
    _require_numpy()
    vertices: List[List[float]] = []
    faces: List[List[int]] = []

    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            if line.startswith("v "):
                parts = line.split()
                if len(parts) >= 4:
                    try:
                        vertices.append([float(parts[1]), float(parts[2]), float(parts[3])])
                    except ValueError:
                        continue
            elif line.startswith("f "):
                indices: List[int] = []
                for token in line.split()[1:]:
                    match = FACE_INDEX.match(token)
                    if not match:
                        continue
                    value = int(match.group(1))
                    indices.append(value - 1 if value > 0 else len(vertices) + value)
                if len(indices) >= 3:
                    faces.append(indices)

    if not vertices or not faces:
        raise MeshError("OBJ contains no geometry")

    points = np.asarray(vertices, dtype=np.float64)
    triangles: List[List[List[float]]] = []
    for face in faces:
        for index in range(1, len(face) - 1):
            triple = (face[0], face[index], face[index + 1])
            if any(i < 0 or i >= len(points) for i in triple):
                continue
            triangles.append([points[triple[0]].tolist(), points[triple[1]].tolist(), points[triple[2]].tolist()])

    if not triangles:
        raise MeshError("OBJ produced no triangles")
    return Mesh(triangles=np.asarray(triangles, dtype=np.float64))


# --------------------------------------------------------------------------- #
# 3MF
# --------------------------------------------------------------------------- #


def load_3mf(path: Path) -> Mesh:
    _require_numpy()
    try:
        with zipfile.ZipFile(path) as archive:
            names = archive.namelist()
            model_name = next(
                (name for name in names if name.lower() == "3d/3dmodel.model"),
                next((name for name in names if name.lower().endswith(".model")), None),
            )
            if model_name is None:
                raise MeshError("3MF has no model part")
            payload = archive.read(model_name)
    except zipfile.BadZipFile as exc:
        raise MeshError(f"Not a valid 3MF/zip container: {exc}") from exc

    try:
        root = ElementTree.fromstring(payload)
    except ElementTree.ParseError as exc:
        raise MeshError(f"Invalid 3MF XML: {exc}") from exc

    vertices: List[List[float]] = []
    triangles: List[List[int]] = []

    for element in root.iter():
        tag = element.tag.rsplit("}", 1)[-1].lower()
        if tag == "vertex":
            try:
                vertices.append([
                    float(element.get("x", 0.0)),
                    float(element.get("y", 0.0)),
                    float(element.get("z", 0.0)),
                ])
            except (TypeError, ValueError):
                continue
        elif tag == "triangle":
            try:
                triangles.append([
                    int(element.get("v1", -1)),
                    int(element.get("v2", -1)),
                    int(element.get("v3", -1)),
                ])
            except (TypeError, ValueError):
                continue

    if not vertices or not triangles:
        raise MeshError("3MF contains no mesh")

    points = np.asarray(vertices, dtype=np.float64)
    valid = [
        triple for triple in triangles
        if all(0 <= index < len(points) for index in triple)
    ]
    if not valid:
        raise MeshError("3MF triangle indices are out of range")
    index_array = np.asarray(valid, dtype=np.int64)
    return Mesh(triangles=points[index_array])


# --------------------------------------------------------------------------- #
# Summary helper
# --------------------------------------------------------------------------- #


@dataclass
class MeshSummary:
    triangle_count: int
    size_x: float
    size_y: float
    size_z: float

    def as_dict(self) -> dict:
        return {
            "triangle_count": self.triangle_count,
            "dimensions_x": round(self.size_x, 3),
            "dimensions_y": round(self.size_y, 3),
            "dimensions_z": round(self.size_z, 3),
        }


def summarise(path: Path) -> Optional[MeshSummary]:
    try:
        mesh = load(path)
    except (MeshError, OSError, ValueError):
        return None
    size = mesh.size
    return MeshSummary(
        triangle_count=mesh.triangle_count,
        size_x=size[0],
        size_y=size[1],
        size_z=size[2],
    )
