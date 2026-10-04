"""Is this printer calibrated? Answered from its own config.

The distinction the whole file turns on is between a number a person typed and
a number Klipper wrote. Both sit in printer.cfg and both are used; only the
second one is evidence that anything was measured.
"""

from __future__ import annotations

import time

from app.klipper.calibration_status import SCREWS_STALE_SECONDS, build_status
from app.klipper.model import parse_config

BASE = """
[stepper_x]
position_min: -8.3
position_max: 330

[stepper_y]
position_min: -1.3
position_max: 330

[probe]
z_offset: 2.0

[bed_mesh]
mesh_min: 15, 15
mesh_max: 315, 315

[screws_tilt_adjust]
screw1: 30, 30
"""

SAVED = """
#*# <---------------------- SAVE_CONFIG
#*# DO NOT EDIT THIS BLOCK OR BELOW.
#*#
#*# [probe]
#*# z_offset = 1.802
#*#
#*# [bed_mesh default]
#*# version = 1
#*# points =
#*# \t0.1, 0.2
"""

PRINT_START_WITH_MESH = """
[gcode_macro PRINT_START]
gcode:
    G28
    BED_MESH_PROFILE LOAD=default
    M109 S200
"""


def item(status, item_id):
    return next(entry for entry in status["items"] if entry["id"] == item_id)


# --------------------------------------------------------------------------- #
# Z offset
# --------------------------------------------------------------------------- #


def test_a_hand_written_z_offset_is_not_a_calibrated_one():
    """The number the printer shipped with, reported as what it is.

    Klipper uses it, so it looks like a working setting - and a printer whose
    first layer has never come out right is usually in exactly this state.
    Showing a green tick here would be the most misleading thing this could do.
    """
    status = build_status(parse_config(BASE))
    entry = item(status, "z_offset")
    assert entry["state"] == "missing"
    assert entry["value"] == 2.0
    assert "بالإيد" in entry["detail_ar"]


def test_a_saved_z_offset_counts_and_wins_over_the_written_one():
    status = build_status(parse_config(BASE + SAVED))
    entry = item(status, "z_offset")
    assert entry["state"] == "done"
    # SAVE_CONFIG's value, not the 2.0 written above it - which is also the
    # order Klipper itself resolves them in.
    assert abs(entry["value"] - 1.802) < 1e-6


def test_a_printer_with_no_probe_is_not_marked_uncalibrated():
    status = build_status(parse_config("[stepper_x]\nposition_max: 220\n"))
    entry = item(status, "z_offset")
    assert entry["state"] == "not_applicable"
    assert entry["ok"]


# --------------------------------------------------------------------------- #
# Bed screws - the part the config records nothing about
# --------------------------------------------------------------------------- #


def test_never_measured_screws_are_unknown_rather_than_fine():
    entry = item(build_status(parse_config(BASE)), "screws_tilt")
    assert entry["state"] == "unknown"
    assert not entry["ok"]


def test_a_level_measurement_counts():
    measurement = {"level": True, "measured_at": time.time(), "worst": ""}
    entry = item(build_status(parse_config(BASE), measurement), "screws_tilt")
    assert entry["state"] == "done"


def test_an_old_measurement_stops_counting():
    """Beds move. A year-old 'level' is not a fact about today's bed."""
    measurement = {
        "level": True,
        "measured_at": time.time() - SCREWS_STALE_SECONDS - 60,
        "worst": "",
    }
    entry = item(build_status(parse_config(BASE), measurement), "screws_tilt")
    assert entry["state"] == "unknown"
    assert entry["warnings_ar"]


def test_screws_that_needed_turning_name_the_worst_one():
    measurement = {"level": False, "measured_at": time.time(), "worst": "rear left"}
    entry = item(build_status(parse_config(BASE), measurement), "screws_tilt")
    assert entry["state"] == "missing"
    assert "rear left" in entry["detail_ar"]


# --------------------------------------------------------------------------- #
# Mesh
# --------------------------------------------------------------------------- #


def test_no_saved_mesh_is_missing():
    assert item(build_status(parse_config(BASE)), "bed_mesh")["state"] == "missing"


def test_a_saved_mesh_nothing_loads_is_flagged():
    """The quietest failure in the whole bed story.

    Everything reads as calibrated and none of it reaches the nozzle, because
    no macro ever applies the profile.
    """
    entry = item(build_status(parse_config(BASE + SAVED)), "bed_mesh")
    assert entry["state"] == "done"
    assert any("مفيش حاجة بتحمّلها" in w for w in entry["warnings_ar"])


def test_a_mesh_that_print_start_loads_has_no_warning():
    config = parse_config(BASE + PRINT_START_WITH_MESH + SAVED)
    assert item(build_status(config), "bed_mesh")["warnings_ar"] == []


# --------------------------------------------------------------------------- #
# The order, which is the actual advice
# --------------------------------------------------------------------------- #


def test_screws_come_first_because_a_mesh_over_a_tilted_bed_is_wasted():
    status = build_status(parse_config(BASE))
    assert [entry["id"] for entry in status["items"]] == [
        "screws_tilt",
        "z_offset",
        "bed_mesh",
    ]
    assert status["next_id"] == "screws_tilt"


def test_a_fully_calibrated_printer_says_so():
    measurement = {"level": True, "measured_at": time.time(), "worst": ""}
    status = build_status(parse_config(BASE + PRINT_START_WITH_MESH + SAVED), measurement)
    assert status["all_done"]
    assert status["next_id"] is None
