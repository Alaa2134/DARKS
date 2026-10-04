"""Find out what is wrong with a model, and fix what can be fixed safely.

A broken mesh currently fails at slice time, with a message from the slicer that
assumes you know what a manifold is. By then the user has waited for an upload,
picked a profile and pressed Slice, and what they get back is a failure they
cannot act on.

This checks the model first and says, in Arabic, what is actually wrong with it.

The split between what is repaired and what is only reported is deliberate.

**Repaired**: things with one right answer. A triangle with no area contributes
nothing and can go. A normal pointing the wrong way can be turned round, because
the geometry says which way is out. Vertices a micron apart are the same vertex
and can be welded.

**Reported only**: holes. Filling a hole means inventing surface that the
designer did not draw, and where that surface should go is a guess - a guess
that becomes solid plastic. Slicers close small holes themselves at slice time,
per layer, which is a better place to do it because the answer only has to be
right in two dimensions.
"""

from __future__ import annotations

import logging
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Tuple

try:  # pragma: no cover - mirrored from mesh.py
    import numpy as np
except Exception:  # pragma: no cover
    np = None  # type: ignore

from .mesh import Mesh, MeshError, load

log = logging.getLogger("neptune.library.repair")

#: Vertices closer than this are the same vertex. Sized for millimetre models:
#: a printer resolves about 0.01 mm, so anything at a micron is float noise from
#: whatever CAD package exported the file.
WELD_TOLERANCE_MM = 1e-4

#: A triangle whose area is below this puts nothing down and only confuses the
#: slicer's topology.
DEGENERATE_AREA_MM2 = 1e-9

#: Above this fraction of *edges* being open, the mesh is not "slightly broken",
#: it is a surface rather than a solid - a scan, or a sheet exported by mistake.
#:
#: Measured against edges rather than triangles because that is what
#: discriminates: a cube missing one face has 3 open edges of 18 (17%), while a
#: single triangle has 3 of 3 (100%). Against the triangle count those two look
#: almost the same.
NOT_A_SOLID_RATIO = 0.5


class RepairError(RuntimeError):
    pass


def _require_numpy() -> None:
    if np is None:  # pragma: no cover
        raise RepairError("numpy is required to inspect meshes")


# --------------------------------------------------------------------------- #
# Diagnosis
# --------------------------------------------------------------------------- #


@dataclass
class MeshReport:
    """What is wrong with a model, in numbers and in Arabic."""

    triangle_count: int = 0
    #: Triangles with no area.
    degenerate: int = 0
    #: Edges belonging to exactly one triangle - the boundary of a hole.
    open_edges: int = 0
    #: Edges shared by three or more triangles. Usually two shells fused at a
    #: seam, and a slicer cannot decide which side is inside.
    overlapping_edges: int = 0
    #: Separate connected pieces. More than one is not itself a fault - a model
    #: can legitimately be several parts - but it is worth saying, because it
    #: is also what a mis-exported assembly looks like.
    shells: int = 1
    #: Faces whose winding disagrees with their neighbours.
    flipped: int = 0
    #: Duplicate vertices that were welded together. An artefact of the STL
    #: format rather than a defect - every STL has three loose corners per
    #: triangle - so it is counted but never reported as a finding.
    welded: int = 0
    #: Every undirected edge in the mesh, for the open-edge ratio.
    total_edges: int = 0
    #: The surface is consistent but wound inwards throughout. A slicer given
    #: this prints the negative of the part, and it is invisible to a
    #: neighbour-agreement check: every face agrees with every other one.
    inside_out: bool = False

    @property
    def is_watertight(self) -> bool:
        return self.open_edges == 0 and self.overlapping_edges == 0

    @property
    def is_clean(self) -> bool:
        return (
            self.is_watertight
            and self.degenerate == 0
            and self.flipped == 0
            and not self.inside_out
        )

    @property
    def is_probably_not_a_solid(self) -> bool:
        """Too many open edges to be a solid with a few holes in it."""
        if self.triangle_count == 0:
            return True
        if self.total_edges == 0:
            return True
        return self.open_edges > self.total_edges * NOT_A_SOLID_RATIO

    def summary_ar(self) -> List[str]:
        """What to tell the user, worst first, in plain Arabic."""
        lines: List[str] = []

        if self.triangle_count == 0:
            return ["الملف مفيهوش أي مثلثات — غالبًا تالف."]

        if self.is_probably_not_a_solid:
            lines.append(
                f"الموديل ده مش مجسم مقفول: فيه {self.open_edges} ضلع مفتوح من "
                f"{self.triangle_count} مثلث. غالبًا سطح أو سكان مش قطعة كاملة، "
                "والتقطيع هيطلع نتيجة غريبة."
            )
        elif self.open_edges:
            lines.append(
                f"فيه {self.open_edges} ضلع مفتوح — يعني خروم صغيرة في السطح. "
                "أغلب السلايسرات بتقفلها لوحدها وقت التقطيع."
            )

        if self.overlapping_edges:
            lines.append(
                f"فيه {self.overlapping_edges} ضلع متشارك في أكتر من وشين. "
                "ده بيحصل لما جسمين يتلحموا، والسلايسر ساعتها مش عارف إيه جوه وإيه بره."
            )

        if self.degenerate:
            lines.append(f"فيه {self.degenerate} مثلث مساحته صفر — اتشالوا.")

        if self.inside_out:
            lines.append(
                "الموديل كله مقلوب من بره لجوه. السلايسر كده بيطبع العكس — "
                "اتظبط."
            )

        if self.flipped:
            lines.append(
                f"فيه {self.flipped} وش كان مقلوب — اتظبطوا. "
                "الوش المقلوب بيخلي السلايسر يطبع العكس."
            )

        if self.shells > 1:
            lines.append(
                f"الموديل فيه {self.shells} أجزاء منفصلة. "
                "لو المفروض قطعة واحدة، غالبًا التصدير غلط."
            )

        if not lines:
            lines.append("الموديل سليم — مقفول ومفيهوش أي مشاكل.")
        return lines


def _welded_indices(triangles: "np.ndarray") -> Tuple["np.ndarray", int]:
    """Map every corner onto a shared vertex id, and count what that merged.

    Meshes are stored as loose triangles - three points each, with no shared
    vertices - so every topology question is unanswerable until identical
    corners are recognised as one. Rounding to the weld tolerance and taking
    unique rows does that in one pass, which matters on a mesh with a million
    corners.
    """
    _require_numpy()
    corners = triangles.reshape(-1, 3)
    quantised = np.round(corners / WELD_TOLERANCE_MM).astype(np.int64)
    _, inverse, counts = np.unique(
        quantised, axis=0, return_inverse=True, return_counts=True
    )
    welded = int((counts - 1).sum())
    return inverse.reshape(-1, 3), welded


def _edge_table(faces: "np.ndarray") -> Dict[Tuple[int, int], List[int]]:
    """Every undirected edge, and which triangles use it."""
    table: Dict[Tuple[int, int], List[int]] = defaultdict(list)
    for index, (a, b, c) in enumerate(faces):
        for start, end in ((a, b), (b, c), (c, a)):
            key = (int(start), int(end)) if start < end else (int(end), int(start))
            table[key].append(index)
    return table


def _count_shells(faces: "np.ndarray", edges: Dict[Tuple[int, int], List[int]]) -> int:
    """Connected components, by walking triangle neighbours.

    Iterative rather than recursive: a 200k-triangle mesh would blow the
    interpreter's stack on the first deep model.
    """
    neighbours: Dict[int, List[int]] = defaultdict(list)
    for owners in edges.values():
        for i in owners:
            for j in owners:
                if i != j:
                    neighbours[i].append(j)

    seen = set()
    shells = 0
    for start in range(len(faces)):
        if start in seen:
            continue
        shells += 1
        stack = [start]
        seen.add(start)
        while stack:
            current = stack.pop()
            for neighbour in neighbours.get(current, ()):
                if neighbour not in seen:
                    seen.add(neighbour)
                    stack.append(neighbour)
    return shells


def _flipped_faces(faces: "np.ndarray", edges: Dict[Tuple[int, int], List[int]]) -> int:
    """Count faces whose winding disagrees with a neighbour's.

    Two triangles sharing an edge agree when they traverse that edge in
    opposite directions. Counted rather than corrected here; the correction
    happens in `repair`, which can rebuild the whole winding consistently.
    """
    directed = set()
    for a, b, c in faces:
        directed.add((int(a), int(b)))
        directed.add((int(b), int(c)))
        directed.add((int(c), int(a)))

    disagreements = 0
    for (low, high), owners in edges.items():
        if len(owners) != 2:
            continue
        # Both directions present means both triangles walk the edge the same
        # way round, which they cannot do if their normals agree.
        if (low, high) in directed and (high, low) in directed:
            continue
        disagreements += 1
    return disagreements


def signed_volume(triangles: "np.ndarray") -> float:
    """Volume enclosed by a closed surface, signed by its winding.

    Positive when the faces wind outwards. This is the only way to catch a mesh
    that is consistently inside-out: every face agrees with every neighbour, so
    a neighbour-agreement check sees nothing wrong at all.
    """
    _require_numpy()
    if len(triangles) == 0:
        return 0.0
    a, b, c = triangles[:, 0, :], triangles[:, 1, :], triangles[:, 2, :]
    return float(np.einsum("ij,ij->i", a, np.cross(b, c)).sum() / 6.0)


def inspect(mesh: Mesh) -> MeshReport:
    """Everything that can be said about a mesh without changing it."""
    _require_numpy()

    report = MeshReport(triangle_count=mesh.triangle_count)
    if report.triangle_count == 0:
        return report

    from .transform import face_normals

    _, areas = face_normals(mesh)
    report.degenerate = int((areas <= DEGENERATE_AREA_MM2).sum())

    faces, welded = _welded_indices(mesh.triangles)
    report.welded = welded

    # Degenerate triangles have no real edges and would be counted as holes.
    keep = areas > DEGENERATE_AREA_MM2
    solid_faces = faces[keep]
    if len(solid_faces) == 0:
        report.open_edges = 0
        report.shells = 0
        return report

    edges = _edge_table(solid_faces)
    report.total_edges = len(edges)
    report.open_edges = sum(1 for owners in edges.values() if len(owners) == 1)
    report.overlapping_edges = sum(1 for owners in edges.values() if len(owners) > 2)
    report.shells = _count_shells(solid_faces, edges)
    report.flipped = _flipped_faces(solid_faces, edges)

    # Only meaningful for a closed surface: an open one encloses nothing, and
    # its "volume" is whatever the hole happens to make it.
    if report.is_watertight and report.flipped == 0:
        report.inside_out = signed_volume(mesh.triangles[keep]) < 0

    return report


def inspect_file(path: Path) -> MeshReport:
    try:
        return inspect(load(Path(path)))
    except MeshError as error:
        raise RepairError(str(error)) from error


# --------------------------------------------------------------------------- #
# Repair
# --------------------------------------------------------------------------- #


@dataclass
class RepairResult:
    """What was actually changed."""

    before: MeshReport
    after: MeshReport
    mesh: Mesh
    removed_triangles: int = 0
    reoriented: bool = False
    notes_ar: List[str] = field(default_factory=list)

    @property
    def changed(self) -> bool:
        return self.removed_triangles > 0 or self.reoriented


def repair(mesh: Mesh, *, fix_normals: bool = True) -> RepairResult:
    """Remove what is meaningless and turn round what is backwards.

    Holes are left alone. Filling one means inventing surface the designer did
    not draw, and that invention becomes solid plastic; slicers close small
    holes per layer at slice time, where the answer only has to be right in two
    dimensions.
    """
    _require_numpy()
    before = inspect(mesh)

    from .transform import face_normals

    _, areas = face_normals(mesh)
    keep = areas > DEGENERATE_AREA_MM2
    removed = int((~keep).sum())
    triangles = mesh.triangles[keep]

    if len(triangles) == 0:
        raise RepairError("مفيش أي مثلث ليه مساحة في الموديل ده.")

    result_mesh = Mesh(triangles=triangles)
    reoriented = False

    if fix_normals and (before.flipped > 0 or before.inside_out):
        result_mesh = _reorient(result_mesh)
        reoriented = True

    after = inspect(result_mesh)

    notes: List[str] = []
    if removed:
        notes.append(f"اتشال {removed} مثلث مساحته صفر.")
    if reoriented:
        if before.inside_out and before.flipped == 0:
            notes.append("الموديل كان مقلوب من بره لجوه بالكامل — اتظبط.")
        else:
            notes.append(f"اتظبط اتجاه {before.flipped} وش كانوا مقلوبين.")
    if after.open_edges:
        notes.append(
            f"لسه فيه {after.open_edges} ضلع مفتوح — الخروم مش بتتقفل تلقائيًا، "
            "لأن ده معناه اختراع سطح المصمم مارسمهوش."
        )
    if not notes:
        notes.append("مفيش حاجة محتاجة إصلاح.")

    return RepairResult(
        before=before,
        after=after,
        mesh=result_mesh,
        removed_triangles=removed,
        reoriented=reoriented,
        notes_ar=notes,
    )


def _reorient(mesh: Mesh) -> Mesh:
    """Make every face wind the same way as its neighbours, then face outwards.

    Two passes. The first spreads one triangle's winding across everything
    connected to it, which makes the surface internally consistent. The second
    decides whether that consistent surface is inside-out, using the signed
    volume it encloses: a solid wound outwards has positive volume.
    """
    _require_numpy()
    faces, _ = _welded_indices(mesh.triangles)
    triangles = mesh.triangles.copy()

    edges = _edge_table(faces)
    neighbours: Dict[int, List[int]] = defaultdict(list)
    for owners in edges.values():
        if len(owners) == 2:
            neighbours[owners[0]].append(owners[1])
            neighbours[owners[1]].append(owners[0])

    flipped = np.zeros(len(faces), dtype=bool)
    visited = np.zeros(len(faces), dtype=bool)

    def directed_edges(index: int) -> set:
        a, b, c = faces[index]
        if flipped[index]:
            a, c = c, a
        return {(int(a), int(b)), (int(b), int(c)), (int(c), int(a))}

    for start in range(len(faces)):
        if visited[start]:
            continue
        visited[start] = True
        stack = [start]
        while stack:
            current = stack.pop()
            current_edges = directed_edges(current)
            for neighbour in neighbours.get(current, ()):
                if visited[neighbour]:
                    continue
                visited[neighbour] = True
                # Agreeing neighbours traverse the shared edge in opposite
                # directions; if any directed edge is shared, this one is
                # wound the wrong way.
                if directed_edges(neighbour) & current_edges:
                    flipped[neighbour] = True
                stack.append(neighbour)

    if flipped.any():
        triangles[flipped] = triangles[flipped][:, ::-1, :]

    # Signed volume of the whole surface. Negative means the consistent
    # surface is consistently inside-out.
    a = triangles[:, 0, :]
    b = triangles[:, 1, :]
    c = triangles[:, 2, :]
    volume = float(np.einsum("ij,ij->i", a, np.cross(b, c)).sum() / 6.0)
    if volume < 0:
        triangles = triangles[:, ::-1, :]

    return Mesh(triangles=triangles)


def repair_file(source: Path, destination: Path) -> RepairResult:
    """Repair `source` into `destination`. The original is never modified."""
    from .transform import write_stl

    try:
        mesh = load(Path(source))
    except MeshError as error:
        raise RepairError(str(error)) from error

    result = repair(mesh)
    write_stl(result.mesh, Path(destination), name=Path(source).stem)
    return result
