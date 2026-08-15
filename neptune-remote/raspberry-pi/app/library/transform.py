"""Turn a model round, scale it, and stand it on the bed.

The library could read a mesh but never change one, so a model arrived at the
slicer exactly as it was exported - and a model exported lying on its side gets
sliced lying on its side. Every other decision in the app sits downstream of the
orientation: which faces need support, how tall the print is, where the layer
lines run and therefore where it will snap.

Three things live here.

**Transforms.** Rotate, scale, mirror. Applied to a copy; the file in the
library is never touched, and the transform is stored beside the model so the
next slice remembers it.

**Standing it up.** After any rotation the model is dropped so its lowest point
sits at Z=0 and its footprint is centred. This is the step that gets forgotten
and it is the one that decides whether the slicer sees a model on the bed or a
model hovering four centimetres above it.

**Auto-orientation.** Finding the way up that needs the least support. This is a
real search over the mesh's own geometry, not a guess: candidate "down"
directions are the directions the model already has a lot of flat area facing,
because a large flat face is what makes a good base.
"""

from __future__ import annotations

import math
import struct
from dataclasses import dataclass, field
from pathlib import Path
from typing import List, Optional, Sequence, Tuple

try:  # pragma: no cover - exercised by the import guard in mesh.py
    import numpy as np
except Exception:  # pragma: no cover
    np = None  # type: ignore

from .mesh import Mesh, MeshError, load

#: A face is "flat on the bed" when its normal is within this of straight down.
#: Loose enough to include the slight wobble in a triangulated flat surface,
#: tight enough to exclude a shallow slope that would rock.
BASE_NORMAL_TOLERANCE_DEG = 5.0

#: Overhangs steeper than this from vertical need support on most machines.
#: Matches the default the slicer profiles use, so the score the app reports and
#: the support the slicer generates are talking about the same thing.
OVERHANG_THRESHOLD_DEG = 45.0

#: Two candidate directions closer than this are treated as the same idea.
CANDIDATE_MERGE_DEG = 12.0

#: How many candidate directions to score. Every extra one costs a full pass
#: over the mesh, and past this the winner has never changed in practice.
MAX_CANDIDATES = 24

#: Scale below/above this is a mistake rather than an intention - a model
#: entered in metres instead of millimetres, or a stray zero.
MIN_SCALE = 0.001
MAX_SCALE = 1000.0


class TransformError(RuntimeError):
    pass


def _require_numpy() -> None:
    if np is None:  # pragma: no cover
        raise TransformError("numpy is required to transform meshes")


@dataclass(frozen=True)
class Transform:
    """How a model is placed, relative to the file on disk.

    Order is fixed and matters: mirror, then scale, then rotate X, Y, Z, then
    drop to the bed. Fixing it means a stored transform always reproduces the
    same result, which is the whole point of storing it.
    """

    rotation_deg: Tuple[float, float, float] = (0.0, 0.0, 0.0)
    #: Per-axis, so a model can be stretched as well as resized.
    scale: Tuple[float, float, float] = (1.0, 1.0, 1.0)
    mirror: Tuple[bool, bool, bool] = (False, False, False)
    #: Sit the model on Z=0 afterwards. Off only for callers doing their own
    #: placement - the app always wants this on.
    drop_to_bed: bool = True
    #: Centre the footprint over the origin. The slicer arranges from there.
    center_on_bed: bool = True
    #: Where on the bed this model goes, in mm from the bed centre.
    #:
    #: Applied last, after centring. PrusaSlicer's command line has no
    #: per-object placement flag - the only way to say "this one goes there" is
    #: to move the mesh before handing it over, which is what this does.
    offset_xy: Tuple[float, float] = (0.0, 0.0)

    @property
    def is_identity(self) -> bool:
        return (
            self.rotation_deg == (0.0, 0.0, 0.0)
            and self.scale == (1.0, 1.0, 1.0)
            and self.mirror == (False, False, False)
            and self.offset_xy == (0.0, 0.0)
        )

    def validated(self) -> "Transform":
        """The same transform, or an error naming what is out of range."""
        for value in self.scale:
            if not math.isfinite(value) or value == 0:
                raise TransformError("مقياس التكبير لازم يكون رقم مش صفر.")
            if abs(value) < MIN_SCALE or abs(value) > MAX_SCALE:
                raise TransformError(
                    f"مقياس التكبير ({value}) خارج المدى المعقول "
                    f"({MIN_SCALE}–{MAX_SCALE})."
                )
        for value in self.rotation_deg:
            if not math.isfinite(value):
                raise TransformError("زاوية التدوير مش رقم صحيح.")
        for value in self.offset_xy:
            if not math.isfinite(value):
                raise TransformError("مكان القطعة على السرير مش رقم صحيح.")
        return self

    def as_dict(self) -> dict:
        return {
            "rotation_deg": list(self.rotation_deg),
            "scale": list(self.scale),
            "mirror": list(self.mirror),
            "drop_to_bed": self.drop_to_bed,
            "center_on_bed": self.center_on_bed,
            "offset_xy": list(self.offset_xy),
        }

    @classmethod
    def from_dict(cls, data: Optional[dict]) -> "Transform":
        if not data:
            return cls()

        def triple(key: str, default: Sequence[float]) -> Tuple[float, float, float]:
            raw = data.get(key) or default
            try:
                values = [float(raw[i]) for i in range(3)]
            except (TypeError, ValueError, IndexError):
                values = list(default)
            return (values[0], values[1], values[2])

        raw_mirror = data.get("mirror") or (False, False, False)
        try:
            mirror = (bool(raw_mirror[0]), bool(raw_mirror[1]), bool(raw_mirror[2]))
        except (TypeError, IndexError):
            mirror = (False, False, False)

        raw_offset = data.get("offset_xy") or (0.0, 0.0)
        try:
            offset = (float(raw_offset[0]), float(raw_offset[1]))
        except (TypeError, ValueError, IndexError):
            offset = (0.0, 0.0)

        return cls(
            rotation_deg=triple("rotation_deg", (0.0, 0.0, 0.0)),
            scale=triple("scale", (1.0, 1.0, 1.0)),
            mirror=mirror,
            drop_to_bed=bool(data.get("drop_to_bed", True)),
            center_on_bed=bool(data.get("center_on_bed", True)),
            offset_xy=offset,
        )


# --------------------------------------------------------------------------- #
# Matrices
# --------------------------------------------------------------------------- #


def _rotation_matrix(rotation_deg: Sequence[float]) -> "np.ndarray":
    """Rotation about X, then Y, then Z, in degrees."""
    rx, ry, rz = (math.radians(float(value)) for value in rotation_deg)

    cx, sx = math.cos(rx), math.sin(rx)
    cy, sy = math.cos(ry), math.sin(ry)
    cz, sz = math.cos(rz), math.sin(rz)

    mx = np.array([[1, 0, 0], [0, cx, -sx], [0, sx, cx]], dtype=np.float64)
    my = np.array([[cy, 0, sy], [0, 1, 0], [-sy, 0, cy]], dtype=np.float64)
    mz = np.array([[cz, -sz, 0], [sz, cz, 0], [0, 0, 1]], dtype=np.float64)
    return mz @ my @ mx


def rotation_bringing_down(normal: Sequence[float]) -> "np.ndarray":
    """Rotation that turns `normal` into straight down (0, 0, -1).

    Rodrigues' formula. Used by auto-orientation: having chosen which face
    should end up on the bed, this is the turn that puts it there.
    """
    _require_numpy()
    source = np.asarray(normal, dtype=np.float64)
    length = float(np.linalg.norm(source))
    if length == 0:
        return np.eye(3)
    source = source / length
    target = np.array([0.0, 0.0, -1.0])

    dot = float(np.clip(np.dot(source, target), -1.0, 1.0))
    if dot > 1.0 - 1e-9:
        return np.eye(3)
    if dot < -1.0 + 1e-9:
        # Exactly opposite: any axis perpendicular to it will do.
        axis = np.array([1.0, 0.0, 0.0])
        if abs(source[0]) > 0.9:
            axis = np.array([0.0, 1.0, 0.0])
        axis = np.cross(source, axis)
        axis /= np.linalg.norm(axis)
        angle = math.pi
    else:
        axis = np.cross(source, target)
        axis /= np.linalg.norm(axis)
        angle = math.acos(dot)

    kx, ky, kz = axis
    k = np.array([[0, -kz, ky], [kz, 0, -kx], [-ky, kx, 0]], dtype=np.float64)
    return np.eye(3) + math.sin(angle) * k + (1 - math.cos(angle)) * (k @ k)


def matrix_to_euler_deg(matrix: "np.ndarray") -> Tuple[float, float, float]:
    """The X-then-Y-then-Z angles that reproduce this matrix.

    Auto-orientation works in matrices; the app and the stored transform work in
    angles, so the answer has to come back in the form everything else speaks.
    """
    _require_numpy()
    # matrix = Rz @ Ry @ Rx, so element [2][0] is -sin(ry).
    sy = -float(np.clip(matrix[2][0], -1.0, 1.0))
    cy = math.sqrt(max(0.0, 1.0 - sy * sy))

    if cy > 1e-6:
        rx = math.atan2(matrix[2][1], matrix[2][2])
        ry = math.asin(sy)
        rz = math.atan2(matrix[1][0], matrix[0][0])
    else:
        # Gimbal lock: pitch is +/-90 and roll and yaw are the same rotation.
        rx = math.atan2(-matrix[1][2], matrix[1][1])
        ry = math.asin(sy)
        rz = 0.0

    return (math.degrees(rx), math.degrees(ry), math.degrees(rz))


# --------------------------------------------------------------------------- #
# Applying
# --------------------------------------------------------------------------- #


def apply(mesh: Mesh, transform: Transform) -> Mesh:
    """A new mesh with the transform applied. The input is not modified."""
    _require_numpy()
    transform.validated()

    points = mesh.triangles.reshape(-1, 3).astype(np.float64, copy=True)

    scale = np.array(transform.scale, dtype=np.float64)
    mirror = np.array([-1.0 if flag else 1.0 for flag in transform.mirror])
    points *= scale * mirror

    if transform.rotation_deg != (0.0, 0.0, 0.0):
        points = points @ _rotation_matrix(transform.rotation_deg).T

    triangles = points.reshape(-1, 3, 3)

    # A mirror or a negative scale turns every triangle inside out. Reversing
    # the winding puts the normals back on the outside, and a slicer given
    # inward-facing normals prints the negative of the part.
    flips = sum(1 for flag in transform.mirror if flag)
    flips += sum(1 for value in transform.scale if value < 0)
    if flips % 2 == 1:
        triangles = triangles[:, ::-1, :]

    result = Mesh(triangles=triangles)
    if transform.drop_to_bed or transform.center_on_bed:
        result = place_on_bed(
            result,
            center=transform.center_on_bed,
            drop=transform.drop_to_bed,
        )

    # Placement goes last, on top of the centring, so a position always means
    # the same thing regardless of where the model happened to be exported.
    if transform.offset_xy != (0.0, 0.0):
        shift = np.array(
            [transform.offset_xy[0], transform.offset_xy[1], 0.0], dtype=np.float64
        )
        result = Mesh(triangles=result.triangles + shift)

    return result


def place_on_bed(mesh: Mesh, *, center: bool = True, drop: bool = True) -> Mesh:
    """Sit the model on Z=0, centred over the origin in X and Y.

    The step that gets forgotten. A rotation about X moves the model off the
    bed as a side effect, and a slicer handed a model floating above the plate
    either refuses it or silently prints the first layer in mid-air.
    """
    _require_numpy()
    low = np.array(mesh.minimum, dtype=np.float64)
    high = np.array(mesh.maximum, dtype=np.float64)

    offset = np.zeros(3, dtype=np.float64)
    if center:
        offset[0] = -(low[0] + high[0]) / 2
        offset[1] = -(low[1] + high[1]) / 2
    if drop:
        offset[2] = -low[2]

    if not offset.any():
        return mesh
    return Mesh(triangles=mesh.triangles + offset)


# --------------------------------------------------------------------------- #
# Measuring
# --------------------------------------------------------------------------- #


def face_normals(mesh: Mesh) -> Tuple["np.ndarray", "np.ndarray"]:
    """Unit normals and areas, one per triangle.

    Degenerate triangles - zero area, which real exports are full of - come back
    with a zero normal and zero area, so they contribute nothing to any score
    rather than poisoning it with a division by zero.
    """
    _require_numpy()
    triangles = mesh.triangles
    edge1 = triangles[:, 1, :] - triangles[:, 0, :]
    edge2 = triangles[:, 2, :] - triangles[:, 0, :]
    cross = np.cross(edge1, edge2)
    lengths = np.linalg.norm(cross, axis=1)

    areas = lengths / 2.0
    safe = np.where(lengths > 1e-12, lengths, 1.0)
    normals = cross / safe[:, None]
    normals[lengths <= 1e-12] = 0.0
    return normals, areas


@dataclass
class OrientationScore:
    """What an orientation would cost, in the units that decide it."""

    #: Area of the faces that would sit flat on the bed, in mm².
    base_area: float
    #: Area of the faces that would need support, in mm².
    overhang_area: float
    #: How tall the model stands this way up, in mm.
    height: float
    #: Footprint, in mm.
    footprint: Tuple[float, float]
    rotation_deg: Tuple[float, float, float]

    @property
    def needs_support(self) -> bool:
        return self.overhang_area > 1e-6


def score_orientation(mesh: Mesh, *, threshold_deg: float = OVERHANG_THRESHOLD_DEG) -> OrientationScore:
    """Measure a mesh as it currently stands."""
    _require_numpy()
    normals, areas = face_normals(mesh)

    downwards = normals[:, 2]
    base_cos = math.cos(math.radians(BASE_NORMAL_TOLERANCE_DEG))
    base_area = float(areas[downwards <= -base_cos].sum())

    # A face overhangs when it faces downwards by more than the threshold
    # allows. Faces already counted as the base are excluded: they are on the
    # bed, not hanging over it.
    overhang_cos = math.cos(math.radians(90.0 - threshold_deg))
    overhanging = (downwards < -overhang_cos) & (downwards > -base_cos)
    overhang_area = float(areas[overhanging].sum())

    size = mesh.size
    return OrientationScore(
        base_area=base_area,
        overhang_area=overhang_area,
        height=float(size[2]),
        footprint=(float(size[0]), float(size[1])),
        rotation_deg=(0.0, 0.0, 0.0),
    )


# --------------------------------------------------------------------------- #
# Auto-orientation
# --------------------------------------------------------------------------- #


def _candidate_directions(mesh: Mesh, limit: int = MAX_CANDIDATES) -> List["np.ndarray"]:
    """Directions worth trying as "down", best first.

    A good base is a large flat face, so the directions the model already has
    the most area facing are the directions worth testing. Normals are pooled
    by direction and weighted by area, which means a thousand tiny triangles
    tiling one flat surface count once - as that surface - instead of a
    thousand times.

    The six axis directions are always included, because a model exported
    upright should be tested upright even if its base is small.
    """
    _require_numpy()
    normals, areas = face_normals(mesh)
    keep = areas > 1e-9
    normals, areas = normals[keep], areas[keep]

    order = np.argsort(areas)[::-1]
    merge_cos = math.cos(math.radians(CANDIDATE_MERGE_DEG))

    chosen: List["np.ndarray"] = []
    for index in order:
        normal = normals[index]
        if any(float(np.dot(normal, existing)) > merge_cos for existing in chosen):
            continue
        chosen.append(normal)
        if len(chosen) >= limit:
            break

    for axis in (
        np.array([0.0, 0.0, -1.0]), np.array([0.0, 0.0, 1.0]),
        np.array([-1.0, 0.0, 0.0]), np.array([1.0, 0.0, 0.0]),
        np.array([0.0, -1.0, 0.0]), np.array([0.0, 1.0, 0.0]),
    ):
        if not any(float(np.dot(axis, existing)) > merge_cos for existing in chosen):
            chosen.append(axis)

    return chosen


def auto_orient(
    mesh: Mesh,
    *,
    threshold_deg: float = OVERHANG_THRESHOLD_DEG,
    max_height: Optional[float] = None,
) -> Tuple[Transform, OrientationScore]:
    """Find the way up that needs the least support.

    Scored, not guessed. For each candidate the model is actually turned and
    measured, and the winner is the one with the least overhang area, with a
    large base and a low height breaking ties - a tall model on a small base is
    the one that gets knocked over by the gantry at layer 400.

    `max_height` rejects orientations that will not fit under the machine's own
    Z limit, so the answer is always one this printer can print.
    """
    _require_numpy()
    if mesh.triangle_count == 0:
        raise TransformError("الموديل مفيهوش أي مثلثات.")

    total_area = float(face_normals(mesh)[1].sum())
    if total_area <= 0:
        raise TransformError("مساحة الموديل صفر — الملف غالبًا تالف.")

    best: Optional[Tuple[float, Transform, OrientationScore]] = None

    for direction in _candidate_directions(mesh):
        matrix = rotation_bringing_down(direction)
        rotation = matrix_to_euler_deg(matrix)
        candidate = Transform(rotation_deg=rotation)
        turned = apply(mesh, candidate)
        score = score_orientation(turned, threshold_deg=threshold_deg)
        score.rotation_deg = rotation

        if max_height is not None and score.height > max_height + 1e-6:
            continue

        # Normalised so the weights mean something across models of any size.
        overhang = score.overhang_area / total_area
        base = score.base_area / total_area
        footprint_span = max(score.footprint[0], score.footprint[1], 1e-6)
        slenderness = score.height / footprint_span

        cost = (
            overhang * 10.0        # support is the thing being avoided
            - base * 3.0           # a real flat base is worth a lot
            + slenderness * 0.5    # tall and narrow falls over
        )

        if best is None or cost < best[0]:
            best = (cost, candidate, score)

    if best is None:
        raise TransformError(
            "مفيش أي اتجاه بيخلي الموديل يدخل في ارتفاع الطابعة. "
            "صغّر الموديل الأول."
        )

    return best[1], best[2]


# --------------------------------------------------------------------------- #
# Writing
# --------------------------------------------------------------------------- #


def write_stl(mesh: Mesh, path: Path, *, name: str = "neptune") -> Path:
    """Write a binary STL the slicer can read.

    Binary rather than ASCII: a 200k-triangle model is 10 MB binary and 60 MB
    as text, and the Pi has to write it, hash it and hand it to the slicer.

    Normals are recomputed from the geometry rather than carried over, because
    the transform may have flipped them and a slicer that trusts a stale normal
    prints the inside of the part.
    """
    _require_numpy()
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)

    triangles = np.asarray(mesh.triangles, dtype=np.float32)
    count = int(triangles.shape[0])
    if count == 0:
        raise TransformError("مش هينفع نكتب موديل من غير مثلثات.")

    normals, _ = face_normals(mesh)
    normals = np.asarray(normals, dtype=np.float32)

    header = name.encode("ascii", errors="replace")[:80].ljust(80, b"\0")

    # One contiguous buffer rather than 200k separate writes: each record is
    # 12 floats (normal + three vertices) followed by a 2-byte attribute count.
    record = np.zeros((count, 50), dtype=np.uint8)
    floats = np.empty((count, 12), dtype=np.float32)
    floats[:, 0:3] = normals
    floats[:, 3:12] = triangles.reshape(count, 9)
    record[:, 0:48] = floats.view(np.uint8).reshape(count, 48)
    # Bytes 48..50 stay zero - the attribute byte count, unused.

    with path.open("wb") as handle:
        handle.write(header)
        handle.write(struct.pack("<I", count))
        handle.write(record.tobytes())

    return path


def materialise(
    source: Path,
    destination: Path,
    transform: Transform,
    *,
    name: str = "neptune",
) -> Tuple[Path, OrientationScore]:
    """Write a transformed copy of `source` for the slicer to read.

    An identity transform still produces a file, because the caller wants one
    path to hand onwards rather than two code paths - but nothing is recomputed
    beyond the load, so it costs a read and a write.
    """
    mesh = load(Path(source))
    turned = apply(mesh, transform)
    write_stl(turned, destination, name=name)
    return destination, score_orientation(turned)


def fits_on_bed(
    size: Sequence[float],
    *,
    width: float,
    depth: float,
    height: float,
) -> Tuple[bool, List[str]]:
    """Whether a model of this size fits, and what is over if it does not.

    Takes the size rather than the mesh: every caller already has the
    measurements, and asking for the whole mesh would mean holding a hundred
    megabytes of triangles to compare three numbers.
    """
    problems: List[str] = []
    if size[0] > width + 1e-6:
        problems.append(f"العرض {size[0]:.0f} مم أكبر من {width:.0f} مم.")
    if size[1] > depth + 1e-6:
        problems.append(f"العمق {size[1]:.0f} مم أكبر من {depth:.0f} مم.")
    if size[2] > height + 1e-6:
        problems.append(f"الارتفاع {size[2]:.0f} مم أكبر من {height:.0f} مم.")
    return (not problems), problems
