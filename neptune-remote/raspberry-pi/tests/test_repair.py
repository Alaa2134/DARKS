"""Telling a broken model apart from a whole one, and fixing what is safe."""

from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from app.library.mesh import Mesh, load
from app.library.repair import (
    MeshReport,
    RepairError,
    inspect,
    inspect_file,
    repair,
    repair_file,
)
from app.library.transform import face_normals, write_stl


def cube(size: float = 10.0, *, offset: tuple = (0.0, 0.0, 0.0)) -> np.ndarray:
    """A closed cube with consistent outward normals."""
    x, y, z = size, size, size
    ox, oy, oz = offset
    c = {
        "a": (ox, oy, oz), "b": (ox + x, oy, oz), "c": (ox + x, oy + y, oz), "d": (ox, oy + y, oz),
        "e": (ox, oy, oz + z), "f": (ox + x, oy, oz + z), "g": (ox + x, oy + y, oz + z), "h": (ox, oy + y, oz + z),
    }
    faces = [
        ("a", "c", "b"), ("a", "d", "c"),      # bottom, facing down
        ("e", "f", "g"), ("e", "g", "h"),      # top, facing up
        ("a", "b", "f"), ("a", "f", "e"),
        ("b", "c", "g"), ("b", "g", "f"),
        ("c", "d", "h"), ("c", "h", "g"),
        ("d", "a", "e"), ("d", "e", "h"),
    ]
    return np.array([[c[i], c[j], c[k]] for i, j, k in faces], dtype=np.float64)


# --------------------------------------------------------------------------- #
# A whole model
# --------------------------------------------------------------------------- #


def test_a_closed_cube_is_reported_as_sound():
    report = inspect(Mesh(triangles=cube()))

    assert report.is_watertight
    assert report.is_clean
    assert report.open_edges == 0
    assert report.overlapping_edges == 0
    assert report.shells == 1
    assert report.degenerate == 0
    assert report.flipped == 0


def test_a_sound_model_says_so_rather_than_finding_something_to_report():
    lines = inspect(Mesh(triangles=cube())).summary_ar()

    assert len(lines) == 1
    assert "سليم" in lines[0]


def test_the_loose_triangles_of_a_cube_are_welded_into_shared_vertices():
    # STL has no shared vertices - every triangle carries its own three points.
    # Without welding, every edge looks open and every model looks broken.
    report = inspect(Mesh(triangles=cube()))

    # 12 triangles x 3 corners = 36, of which only 8 are distinct.
    assert report.welded == 28


# --------------------------------------------------------------------------- #
# Holes
# --------------------------------------------------------------------------- #


def test_a_cube_missing_a_face_is_reported_as_open():
    holed = cube()[:-1]                       # drop one triangle
    report = inspect(Mesh(triangles=holed))

    assert not report.is_watertight
    assert report.open_edges == 3
    assert any("ضلع مفتوح" in line for line in report.summary_ar())


def test_a_single_triangle_is_recognised_as_not_a_solid():
    # A sheet, not a part. Slicing it produces something nobody wants, and
    # saying "3 open edges" would understate it.
    sheet = np.array([[[0, 0, 0], [10, 0, 0], [0, 10, 0]]], dtype=np.float64)
    report = inspect(Mesh(triangles=sheet))

    assert report.is_probably_not_a_solid
    assert any("مش مجسم مقفول" in line for line in report.summary_ar())


def test_a_cube_with_one_face_missing_is_still_treated_as_a_solid():
    # One hole in twelve triangles is a repairable model, not a scan.
    report = inspect(Mesh(triangles=cube()[:-1]))

    assert not report.is_probably_not_a_solid


# --------------------------------------------------------------------------- #
# Degenerate triangles
# --------------------------------------------------------------------------- #


def test_zero_area_triangles_are_counted():
    zero = np.array([[[1.0, 1.0, 1.0]] * 3], dtype=np.float64)
    report = inspect(Mesh(triangles=np.concatenate([cube(), zero])))

    assert report.degenerate == 1


def test_a_degenerate_triangle_does_not_make_a_whole_cube_look_holed():
    # It has no real edges, so counting them as boundary would invent 3 holes
    # in a model that has none.
    zero = np.array([[[1.0, 1.0, 1.0]] * 3], dtype=np.float64)
    report = inspect(Mesh(triangles=np.concatenate([cube(), zero])))

    assert report.open_edges == 0
    assert report.is_watertight


def test_repair_removes_degenerate_triangles():
    zero = np.array([[[1.0, 1.0, 1.0]] * 3], dtype=np.float64)
    result = repair(Mesh(triangles=np.concatenate([cube(), zero])))

    assert result.removed_triangles == 1
    assert result.mesh.triangle_count == 12
    assert result.after.degenerate == 0
    assert result.changed


def test_a_mesh_of_nothing_but_degenerate_triangles_is_refused():
    zero = np.array([[[0.0, 0.0, 0.0]] * 3] * 4, dtype=np.float64)
    with pytest.raises(RepairError):
        repair(Mesh(triangles=zero))


# --------------------------------------------------------------------------- #
# Flipped faces
# --------------------------------------------------------------------------- #


def test_a_flipped_face_is_detected():
    triangles = cube()
    triangles[3] = triangles[3][::-1]         # turn one face inside out
    report = inspect(Mesh(triangles=triangles))

    assert report.flipped > 0
    assert not report.is_clean


def test_repair_turns_a_flipped_face_back_round():
    triangles = cube()
    triangles[3] = triangles[3][::-1]

    result = repair(Mesh(triangles=triangles))

    assert result.reoriented
    assert result.after.flipped == 0
    assert any("مقلوبين" in note for note in result.notes_ar)


def test_a_wholly_inside_out_cube_is_turned_outwards():
    # Consistent but backwards: every normal agrees with its neighbours and
    # every one of them points inwards. A slicer given this prints the
    # negative of the part.
    inverted = cube()[:, ::-1, :]
    result = repair(Mesh(triangles=inverted))

    normals, _ = face_normals(result.mesh)
    lowest = result.mesh.minimum[2]
    on_bed = np.isclose(result.mesh.triangles[:, :, 2].max(axis=1), lowest, atol=1e-9)
    assert (normals[on_bed][:, 2] < 0).all(), "the bottom face must face down"


def test_repair_leaves_a_sound_model_alone():
    result = repair(Mesh(triangles=cube()))

    assert not result.changed
    assert result.mesh.triangle_count == 12
    assert any("مفيش حاجة" in note for note in result.notes_ar)


# --------------------------------------------------------------------------- #
# Holes are reported, never invented
# --------------------------------------------------------------------------- #


def test_repair_does_not_fill_holes():
    # Filling one means inventing surface the designer did not draw, and that
    # invention becomes solid plastic.
    result = repair(Mesh(triangles=cube()[:-1]))

    assert result.after.open_edges == 3
    assert any("الخروم مش بتتقفل" in note for note in result.notes_ar)


# --------------------------------------------------------------------------- #
# Shells
# --------------------------------------------------------------------------- #


def test_two_separate_cubes_are_counted_as_two_shells():
    two = np.concatenate([cube(), cube(offset=(50.0, 0.0, 0.0))])
    report = inspect(Mesh(triangles=two))

    assert report.shells == 2
    assert report.is_watertight            # both are closed
    assert any("أجزاء منفصلة" in line for line in report.summary_ar())


def test_counting_shells_survives_a_deep_mesh_without_recursing():
    # A long strip of triangles: recursion here would blow the stack on any
    # real model, which is why the walk is iterative.
    strip = []
    for i in range(2000):
        x = float(i)
        strip.append([[x, 0, 0], [x + 1, 0, 0], [x, 1, 0]])
        strip.append([[x + 1, 0, 0], [x + 1, 1, 0], [x, 1, 0]])
    report = inspect(Mesh(triangles=np.array(strip, dtype=np.float64)))

    assert report.shells == 1


# --------------------------------------------------------------------------- #
# Files
# --------------------------------------------------------------------------- #


def test_inspecting_a_file_reads_it_from_disk(tmp_path: Path):
    path = write_stl(Mesh(triangles=cube()), tmp_path / "cube.stl")

    assert inspect_file(path).is_clean


def test_an_unreadable_file_reports_a_repair_error(tmp_path: Path):
    broken = tmp_path / "broken.stl"
    broken.write_bytes(b"not an stl")

    with pytest.raises(RepairError):
        inspect_file(broken)


def test_repairing_a_file_writes_a_new_one_and_leaves_the_original(tmp_path: Path):
    triangles = cube()
    triangles[3] = triangles[3][::-1]
    source = write_stl(Mesh(triangles=triangles), tmp_path / "in.stl")
    before = source.read_bytes()

    result = repair_file(source, tmp_path / "out.stl")

    assert (tmp_path / "out.stl").is_file()
    assert source.read_bytes() == before
    assert result.after.flipped == 0
    assert load(tmp_path / "out.stl").triangle_count == 12


def test_an_empty_report_describes_a_corrupt_file():
    lines = MeshReport(triangle_count=0).summary_ar()

    assert len(lines) == 1
    assert "تالف" in lines[0]
