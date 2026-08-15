"""Geometry has right answers, so these check answers rather than shapes."""

from __future__ import annotations

import math
from pathlib import Path

import numpy as np
import pytest

from app.library.mesh import Mesh, load
from app.library.transform import (
    OVERHANG_THRESHOLD_DEG,
    Transform,
    TransformError,
    apply,
    auto_orient,
    face_normals,
    fits_on_bed,
    materialise,
    matrix_to_euler_deg,
    place_on_bed,
    rotation_bringing_down,
    score_orientation,
    write_stl,
)


def box(width: float = 10.0, depth: float = 20.0, height: float = 40.0, *, at_z: float = 0.0) -> Mesh:
    """An axis-aligned box, outward normals, sitting at `at_z`."""
    x, y, z0 = width, depth, at_z
    z1 = at_z + height
    corners = {
        "a": [0, 0, z0], "b": [x, 0, z0], "c": [x, y, z0], "d": [0, y, z0],
        "e": [0, 0, z1], "f": [x, 0, z1], "g": [x, y, z1], "h": [0, y, z1],
    }
    faces = [
        # bottom (normals down), top (normals up)
        ("a", "c", "b"), ("a", "d", "c"),
        ("e", "f", "g"), ("e", "g", "h"),
        # sides
        ("a", "b", "f"), ("a", "f", "e"),
        ("b", "c", "g"), ("b", "g", "f"),
        ("c", "d", "h"), ("c", "h", "g"),
        ("d", "a", "e"), ("d", "e", "h"),
    ]
    triangles = np.array(
        [[corners[i], corners[j], corners[k]] for i, j, k in faces],
        dtype=np.float64,
    )
    return Mesh(triangles=triangles)


# --------------------------------------------------------------------------- #
# Transform bookkeeping
# --------------------------------------------------------------------------- #


def test_identity_transform_is_recognised():
    assert Transform().is_identity
    assert not Transform(rotation_deg=(90.0, 0.0, 0.0)).is_identity
    assert not Transform(scale=(2.0, 2.0, 2.0)).is_identity
    assert not Transform(mirror=(True, False, False)).is_identity


def test_a_transform_survives_a_round_trip_through_a_dict():
    original = Transform(
        rotation_deg=(90.0, 0.0, 45.0),
        scale=(2.0, 2.0, 1.5),
        mirror=(True, False, False),
        drop_to_bed=False,
    )
    assert Transform.from_dict(original.as_dict()) == original


def test_a_missing_or_broken_dict_falls_back_to_identity():
    assert Transform.from_dict(None).is_identity
    assert Transform.from_dict({}).is_identity
    # Stored state can be older than the code reading it, so garbage has to
    # produce a usable transform rather than an exception at slice time.
    assert Transform.from_dict({"rotation_deg": "nonsense"}).is_identity
    assert Transform.from_dict({"scale": [1.0]}).is_identity


def test_a_zero_or_absurd_scale_is_refused():
    with pytest.raises(TransformError):
        Transform(scale=(0.0, 1.0, 1.0)).validated()
    with pytest.raises(TransformError):
        Transform(scale=(1e6, 1.0, 1.0)).validated()
    with pytest.raises(TransformError):
        Transform(scale=(float("nan"), 1.0, 1.0)).validated()


# --------------------------------------------------------------------------- #
# Applying
# --------------------------------------------------------------------------- #


def test_scaling_changes_the_size_by_exactly_that_factor():
    result = apply(box(10, 20, 40), Transform(scale=(2.0, 2.0, 2.0)))
    assert result.size == pytest.approx((20.0, 40.0, 80.0))


def test_rotating_ninety_degrees_about_x_swaps_depth_and_height():
    result = apply(box(10, 20, 40), Transform(rotation_deg=(90.0, 0.0, 0.0)))
    assert result.size == pytest.approx((10.0, 40.0, 20.0), abs=1e-9)


def test_a_rotated_model_is_put_back_on_the_bed():
    # The step that gets forgotten: rotating about X moves the model off the
    # plate as a side effect, and a slicer handed a floating model prints the
    # first layer in mid-air.
    result = apply(box(10, 20, 40), Transform(rotation_deg=(90.0, 0.0, 0.0)))
    assert result.minimum[2] == pytest.approx(0.0, abs=1e-9)


def test_a_model_exported_far_from_the_origin_is_brought_home():
    far = Mesh(triangles=box(10, 20, 40).triangles + np.array([500.0, -300.0, 75.0]))
    result = apply(far, Transform())

    assert result.minimum[2] == pytest.approx(0.0, abs=1e-9)
    assert result.center[0] == pytest.approx(0.0, abs=1e-9)
    assert result.center[1] == pytest.approx(0.0, abs=1e-9)


def test_placement_can_be_turned_off_for_a_caller_doing_its_own():
    far = Mesh(triangles=box().triangles + np.array([0.0, 0.0, 60.0]))
    result = apply(far, Transform(drop_to_bed=False, center_on_bed=False))
    assert result.minimum[2] == pytest.approx(60.0)


def test_mirroring_turns_the_triangles_back_the_right_way_out():
    # A mirror inverts every triangle. Left uncorrected the normals point
    # inwards and the slicer prints the negative of the part.
    source = box()
    mirrored = apply(source, Transform(mirror=(True, False, False)))

    normals, areas = face_normals(mirrored)
    # The bottom face must still face downwards after the flip.
    lowest = mirrored.minimum[2]
    on_bed = np.isclose(mirrored.triangles[:, :, 2].max(axis=1), lowest, atol=1e-9)
    assert on_bed.any()
    assert (normals[on_bed][:, 2] < 0).all()


def test_two_mirrors_cancel_and_leave_the_winding_alone():
    source = box()
    twice = apply(source, Transform(mirror=(True, True, False)))
    normals, _ = face_normals(twice)
    lowest = twice.minimum[2]
    on_bed = np.isclose(twice.triangles[:, :, 2].max(axis=1), lowest, atol=1e-9)
    assert (normals[on_bed][:, 2] < 0).all()


def test_the_source_mesh_is_never_modified():
    source = box()
    before = source.triangles.copy()
    apply(source, Transform(rotation_deg=(90.0, 45.0, 30.0), scale=(3.0, 3.0, 3.0)))
    assert np.array_equal(source.triangles, before)


# --------------------------------------------------------------------------- #
# Rotation maths
# --------------------------------------------------------------------------- #


@pytest.mark.parametrize(
    "direction",
    [
        (0.0, 0.0, -1.0),   # already down
        (0.0, 0.0, 1.0),    # exactly opposite - the degenerate case
        (1.0, 0.0, 0.0),
        (0.0, 1.0, 0.0),
        (0.577, 0.577, 0.577),
    ],
)
def test_rotation_bringing_down_actually_points_the_direction_down(direction):
    matrix = rotation_bringing_down(direction)
    source = np.array(direction, dtype=np.float64)
    source /= np.linalg.norm(source)
    turned = matrix @ source
    assert turned == pytest.approx([0.0, 0.0, -1.0], abs=1e-9)


@pytest.mark.parametrize(
    "angles",
    [(0, 0, 0), (90, 0, 0), (0, 90, 0), (0, 0, 90), (30, 45, 60), (-15, 80, 170)],
)
def test_euler_angles_round_trip_through_a_matrix(angles):
    # Auto-orientation works in matrices while everything else works in angles,
    # so the conversion has to be exact or the stored transform does not
    # reproduce the orientation that was chosen.
    source = box(7.0, 11.0, 13.0)
    from app.library.transform import _rotation_matrix

    matrix = _rotation_matrix(angles)
    recovered = matrix_to_euler_deg(matrix)

    direct = apply(source, Transform(rotation_deg=angles, drop_to_bed=False, center_on_bed=False))
    again = apply(source, Transform(rotation_deg=recovered, drop_to_bed=False, center_on_bed=False))
    assert direct.triangles == pytest.approx(again.triangles, abs=1e-6)


def test_euler_recovery_survives_gimbal_lock():
    from app.library.transform import _rotation_matrix

    matrix = _rotation_matrix((0.0, 90.0, 0.0))
    recovered = matrix_to_euler_deg(matrix)
    source = box(7.0, 11.0, 13.0)

    direct = apply(source, Transform(rotation_deg=(0.0, 90.0, 0.0), drop_to_bed=False, center_on_bed=False))
    again = apply(source, Transform(rotation_deg=recovered, drop_to_bed=False, center_on_bed=False))
    assert direct.triangles == pytest.approx(again.triangles, abs=1e-6)


# --------------------------------------------------------------------------- #
# Scoring
# --------------------------------------------------------------------------- #


def test_a_box_on_its_base_reports_that_base_and_no_overhang():
    score = score_orientation(box(10, 20, 40))

    assert score.base_area == pytest.approx(200.0)   # 10 x 20
    assert score.overhang_area == pytest.approx(0.0)
    assert score.height == pytest.approx(40.0)
    assert not score.needs_support


def test_vertical_walls_are_not_counted_as_overhangs():
    # A wall at exactly 90 degrees prints fine and must not be reported as
    # needing support - getting this wrong makes every box look impossible.
    score = score_orientation(box(10, 10, 10))
    assert score.overhang_area == pytest.approx(0.0)


def test_a_downward_facing_slope_is_counted_as_overhang():
    # A single triangle tilted 30 degrees off horizontal, facing down.
    tilt = math.radians(30.0)
    triangles = np.array([[
        [0.0, 0.0, 0.0],
        [10.0, 0.0, 0.0],
        [0.0, 10.0 * math.cos(tilt), 10.0 * math.sin(tilt)],
    ]], dtype=np.float64)
    mesh = Mesh(triangles=triangles)
    normals, _ = face_normals(mesh)
    if normals[0][2] > 0:                      # make sure it faces downwards
        mesh = Mesh(triangles=triangles[:, ::-1, :])

    score = score_orientation(mesh, threshold_deg=OVERHANG_THRESHOLD_DEG)
    assert score.overhang_area > 0


def test_degenerate_triangles_contribute_nothing_instead_of_breaking_the_score():
    # Real exports are full of zero-area triangles. They used to be a division
    # by zero waiting to happen.
    good = box(10, 10, 10).triangles
    zero = np.array([[[1.0, 1.0, 1.0]] * 3], dtype=np.float64)
    mesh = Mesh(triangles=np.concatenate([good, zero]))

    normals, areas = face_normals(mesh)
    assert areas[-1] == pytest.approx(0.0)
    assert normals[-1] == pytest.approx([0.0, 0.0, 0.0])
    assert math.isfinite(score_orientation(mesh).base_area)


# --------------------------------------------------------------------------- #
# Auto-orientation
# --------------------------------------------------------------------------- #


def test_a_box_lying_on_its_side_is_stood_on_its_largest_face():
    # The case that motivated the whole module: a model exported lying down
    # gets sliced lying down. 10 x 20 x 40 laid flat should end up resting on
    # the 20 x 40 face, which is the biggest one it has.
    lying = apply(box(10, 20, 40), Transform(rotation_deg=(0.0, 90.0, 0.0)))

    transform, score = auto_orient(lying)
    result = apply(lying, transform)

    assert result.size[2] == pytest.approx(10.0, abs=1e-6)
    assert score.base_area == pytest.approx(800.0, rel=1e-6)   # 20 x 40


def test_auto_orientation_always_leaves_the_model_on_the_bed():
    lying = apply(box(8, 30, 55), Transform(rotation_deg=(90.0, 0.0, 0.0)))
    transform, _ = auto_orient(lying)
    result = apply(lying, transform)

    assert result.minimum[2] == pytest.approx(0.0, abs=1e-6)


def test_an_orientation_taller_than_the_machine_is_rejected():
    tall = box(10, 10, 300)
    transform, score = auto_orient(tall, max_height=100.0)
    result = apply(tall, transform)

    # It cannot stand up in a 100 mm machine, so it has to be laid down.
    assert result.size[2] <= 100.0 + 1e-6
    assert score.height <= 100.0 + 1e-6


def test_a_model_that_fits_no_way_up_says_so_rather_than_guessing():
    with pytest.raises(TransformError):
        auto_orient(box(200, 200, 200), max_height=50.0)


def test_an_empty_mesh_is_refused():
    empty = Mesh(triangles=np.zeros((0, 3, 3), dtype=np.float64))
    with pytest.raises(TransformError):
        auto_orient(empty)


def test_a_mesh_of_only_degenerate_triangles_is_refused():
    zero = Mesh(triangles=np.array([[[0.0, 0.0, 0.0]] * 3] * 5, dtype=np.float64))
    with pytest.raises(TransformError):
        auto_orient(zero)


# --------------------------------------------------------------------------- #
# Writing
# --------------------------------------------------------------------------- #


def test_a_written_stl_reads_back_as_the_same_geometry(tmp_path: Path):
    source = box(10, 20, 40)
    target = write_stl(source, tmp_path / "out.stl")

    reloaded = load(target)
    assert reloaded.triangle_count == source.triangle_count
    assert reloaded.size == pytest.approx(source.size, abs=1e-4)


def test_a_written_stl_carries_recomputed_normals(tmp_path: Path):
    # Normals are recomputed rather than carried over, because a transform may
    # have flipped them and a slicer that trusts a stale normal prints the
    # inside of the part.
    source = apply(box(10, 20, 40), Transform(mirror=(True, False, False)))
    target = write_stl(source, tmp_path / "mirrored.stl")

    data = target.read_bytes()
    count = int.from_bytes(data[80:84], "little")
    assert count == source.triangle_count

    first_normal = np.frombuffer(data, dtype="<f4", count=3, offset=84)
    expected = face_normals(source)[0][0]
    assert first_normal == pytest.approx(expected, abs=1e-5)


def test_writing_an_empty_mesh_is_refused(tmp_path: Path):
    empty = Mesh(triangles=np.zeros((0, 3, 3), dtype=np.float64))
    with pytest.raises(TransformError):
        write_stl(empty, tmp_path / "empty.stl")


def test_materialise_writes_a_transformed_copy_and_measures_it(tmp_path: Path):
    original = write_stl(box(10, 20, 40), tmp_path / "source.stl")

    target, score = materialise(
        original,
        tmp_path / "turned.stl",
        Transform(rotation_deg=(90.0, 0.0, 0.0)),
    )

    assert target.is_file()
    assert load(target).size == pytest.approx((10.0, 40.0, 20.0), abs=1e-4)
    assert score.height == pytest.approx(20.0, abs=1e-4)


def test_materialise_leaves_the_source_file_untouched(tmp_path: Path):
    original = write_stl(box(10, 20, 40), tmp_path / "source.stl")
    before = original.read_bytes()

    materialise(original, tmp_path / "turned.stl", Transform(scale=(3.0, 3.0, 3.0)))

    assert original.read_bytes() == before


# --------------------------------------------------------------------------- #
# Bed limits
# --------------------------------------------------------------------------- #


def test_a_model_within_the_bed_fits():
    ok, problems = fits_on_bed(box(100, 100, 100).size, width=320, depth=320, height=400)
    assert ok
    assert problems == []


def test_a_model_over_the_bed_names_every_axis_that_is_over():
    ok, problems = fits_on_bed(box(400, 400, 500).size, width=320, depth=320, height=400)

    assert not ok
    assert len(problems) == 3
    assert any("العرض" in problem for problem in problems)
    assert any("الارتفاع" in problem for problem in problems)


def test_a_model_exactly_the_size_of_the_bed_fits():
    ok, _ = fits_on_bed(box(320, 320, 400).size, width=320, depth=320, height=400)
    assert ok
