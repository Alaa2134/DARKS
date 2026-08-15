"""Where each part goes on the bed, and when it will not work."""

from __future__ import annotations

import pytest

from app.slicer.arrange import (
    DEFAULT_MARGIN_MM,
    DEFAULT_SPACING_MM,
    ArrangeError,
    Placement,
    auto_arrange,
    bed_size_from_limits,
    check,
)

BED = 320.0


def arrange(*footprints, width: float = BED, depth: float = BED):
    return auto_arrange(list(footprints), bed_width=width, bed_depth=depth)


# --------------------------------------------------------------------------- #
# Checking
# --------------------------------------------------------------------------- #


def test_one_part_in_the_middle_is_fine():
    problems = check(
        [Placement("a", 50, 50, x=0, y=0)], bed_width=BED, bed_depth=BED
    )
    assert problems == []


def test_two_parts_far_apart_are_fine():
    problems = check(
        [Placement("a", 40, 40, x=-60, y=0), Placement("b", 40, 40, x=60, y=0)],
        bed_width=BED, bed_depth=BED,
    )
    assert problems == []


def test_two_parts_touching_are_reported():
    problems = check(
        [Placement("a", 40, 40, x=-20, y=0), Placement("b", 40, 40, x=20, y=0)],
        bed_width=BED, bed_depth=BED,
    )
    assert len(problems) == 1
    assert "متلاصقين" in problems[0]


def test_parts_closer_than_the_spacing_are_reported_even_without_overlap():
    # 2 mm apart: they do not intersect, but the nozzle has to travel between
    # them and two skirts at that distance fuse.
    problems = check(
        [Placement("a", 40, 40, x=-21, y=0), Placement("b", 40, 40, x=21, y=0)],
        bed_width=BED, bed_depth=BED,
    )
    assert len(problems) == 1


def test_a_part_over_the_bed_edge_is_reported():
    problems = check(
        [Placement("a", 40, 40, x=BED / 2, y=0)], bed_width=BED, bed_depth=BED
    )
    assert any("حدود السرير" in problem for problem in problems)


def test_a_part_inside_the_edge_margin_is_reported():
    # The outermost millimetres of any bed are the least reliable part of it.
    just_over = BED / 2 - DEFAULT_MARGIN_MM - 20 + 1
    problems = check(
        [Placement("a", 40, 40, x=just_over, y=0)], bed_width=BED, bed_depth=BED
    )
    assert len(problems) == 1


def test_every_touching_pair_is_named_not_just_the_first():
    problems = check(
        [
            Placement("a", 40, 40, x=-10, y=0),
            Placement("b", 40, 40, x=10, y=0),
            Placement("c", 40, 40, x=30, y=0),
        ],
        bed_width=BED, bed_depth=BED,
    )
    assert len(problems) >= 2


# --------------------------------------------------------------------------- #
# Arranging
# --------------------------------------------------------------------------- #


def test_a_single_part_lands_in_the_middle():
    result = arrange(("a", 50, 50))

    assert result.ok
    assert result.placements[0].x == pytest.approx(0.0)
    assert result.placements[0].y == pytest.approx(0.0)


def test_two_parts_are_placed_side_by_side_without_touching():
    result = arrange(("a", 50, 50), ("b", 50, 50))

    assert result.ok
    assert check(result.placements, bed_width=BED, bed_depth=BED) == []


def test_a_full_plate_is_arranged_without_a_single_problem():
    result = arrange(*[(f"m{i}", 45, 45) for i in range(9)])

    assert result.ok
    assert len(result.placements) == 9
    assert check(result.placements, bed_width=BED, bed_depth=BED) == []


def test_the_arrangement_is_centred_rather_than_pushed_to_one_edge():
    result = arrange(("a", 40, 40), ("b", 40, 40), ("c", 40, 40))

    xs = [placement.x for placement in result.placements]
    ys = [placement.y for placement in result.placements]
    # A half-full plate belongs in the middle of the bed.
    assert sum(xs) / len(xs) == pytest.approx(0.0, abs=1e-6)
    assert sum(ys) / len(ys) == pytest.approx(0.0, abs=1e-6)


def test_the_same_parts_always_come_out_the_same_way():
    # Stability matters more than optimality: an arrangement that reshuffles
    # itself every time the screen opens is one nobody can work with.
    parts = [("a", 40, 60), ("b", 80, 30), ("c", 20, 90)]
    first = arrange(*parts)
    second = arrange(*parts)

    assert [p.as_dict() for p in first.placements] == [p.as_dict() for p in second.placements]


def test_the_input_order_does_not_change_the_result():
    forward = arrange(("a", 40, 60), ("b", 80, 30), ("c", 20, 90))
    backward = arrange(("c", 20, 90), ("b", 80, 30), ("a", 40, 60))

    by_id = lambda result: sorted((p.model_id, p.x, p.y) for p in result.placements)
    assert by_id(forward) == by_id(backward)


def test_rows_are_grouped_by_depth_so_the_plate_is_not_wasted():
    # Tall next to short wastes the whole strip above the short one.
    result = arrange(("tall", 40, 100), ("short", 40, 20), ("tall2", 40, 100))

    rows = {}
    for placement in result.placements:
        rows.setdefault(round(placement.y, 3), []).append(placement.model_id)

    tall_row = next(ids for ids in rows.values() if "tall" in ids)
    assert "tall2" in tall_row


# --------------------------------------------------------------------------- #
# When it will not fit
# --------------------------------------------------------------------------- #


def test_a_part_bigger_than_the_bed_is_named_and_left_out():
    result = arrange(("huge", 400, 400), ("small", 30, 30))

    assert not result.ok
    assert result.unplaced == ["huge"]
    assert any("أكبر من مساحة السرير" in problem for problem in result.problems_ar)
    # The one that does fit is still placed.
    assert [p.model_id for p in result.placements] == ["small"]


def test_a_part_that_only_just_exceeds_the_margin_is_refused():
    # 320 mm bed with an 8 mm margin each side leaves 304 usable.
    assert arrange(("a", 304, 50)).ok
    assert not arrange(("a", 305, 50)).ok


def test_too_many_parts_leaves_the_extras_unplaced_and_says_so():
    result = arrange(*[(f"m{i}", 100, 100) for i in range(12)])

    assert not result.ok
    assert result.unplaced
    assert len(result.placements) < 12
    assert any("مفيش مكان" in problem for problem in result.problems_ar)


def test_everything_that_was_placed_is_still_a_valid_arrangement():
    # Running out of room must not corrupt what did fit.
    result = arrange(*[(f"m{i}", 100, 100) for i in range(12)])

    assert check(result.placements, bed_width=BED, bed_depth=BED) == []


def test_an_empty_plate_arranges_to_nothing():
    result = arrange()

    assert result.ok
    assert result.placements == []


def test_a_bed_smaller_than_its_own_margins_is_refused():
    with pytest.raises(ArrangeError):
        auto_arrange([("a", 10, 10)], bed_width=10, bed_depth=10)


# --------------------------------------------------------------------------- #
# Bed size
# --------------------------------------------------------------------------- #


def test_bed_size_ignores_homing_overtravel():
    # position_min is negative on X here: that is overtravel for homing, not
    # printable space, so the usable width is 320 and not 325.
    width, depth = bed_size_from_limits({"x": (-5.0, 320.0), "y": (0.0, 320.0)})

    assert width == pytest.approx(320.0)
    assert depth == pytest.approx(320.0)


def test_an_axis_with_no_maximum_reports_zero_rather_than_guessing():
    width, _ = bed_size_from_limits({"x": (0.0, None), "y": (0.0, 320.0)})
    assert width == 0.0
