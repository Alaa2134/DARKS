"""Generated calibration prints.

These are G-code that a real nozzle will follow, so the tests are mostly about
not crashing it: every coordinate inside the configured travel, nothing
negative, no extrusion before the hotend is hot, and no pattern generated at
all when the config cannot say where the bed is.

The fixtures are two different machines on purpose. A generator that only works
on the config it was written against has hardcoded that config.
"""

from __future__ import annotations

import re

import pytest

from app.klipper.model import parse_config
from app.klipper.patterns import (
    available,
    flow_cube,
    flow_from_measurement,
    pressure_advance_from_height,
    pressure_advance_tower,
    read_geometry,
    retraction_tower,
    temperature_tower,
)

NEPTUNE = """
[stepper_x]
position_min: -8.3
position_max: 330

[stepper_y]
position_min: -1.3
position_max: 330

[stepper_z]
position_max: 410

[extruder]
nozzle_diameter: 0.4
filament_diameter: 1.750
min_extrude_temp: 170
max_temp: 250

[heater_bed]
max_temp: 110

[firmware_retraction]
retract_length: 0.5

[bed_mesh]
mesh_min: 22,22
mesh_max: 290,300

#*# <---------------------- SAVE_CONFIG ---------------------->
#*# [bed_mesh default]
#*# version = 1
"""

# A small machine with a wide nozzle and no bed heater.
TINY = """
[stepper_x]
position_max: 120

[stepper_y]
position_max: 120

[stepper_z]
position_max: 120

[extruder]
nozzle_diameter: 0.6
filament_diameter: 2.85
max_temp: 260
"""


def coordinates(gcode: str, axis: str):
    return [float(value) for value in re.findall(rf"{axis}(-?\d+\.?\d*)", gcode)]


def moves(gcode: str):
    return [line for line in gcode.splitlines() if line.startswith("G1 ")]


# --------------------------------------------------------------------------- #
# Geometry
# --------------------------------------------------------------------------- #


class TestGeometry:
    def test_it_reads_the_machine_from_the_config(self):
        geometry = read_geometry(parse_config(NEPTUNE))
        assert geometry.nozzle == 0.4
        assert geometry.filament == 1.75
        assert geometry.centre_x == pytest.approx(165.0)

    def test_a_negative_position_min_is_not_printable_surface(self):
        """position_min is homing overtravel; the bed starts at 0."""
        geometry = read_geometry(parse_config(NEPTUNE))
        assert geometry.min_x == 0.0
        assert geometry.min_y == 0.0

    def test_a_config_without_travel_limits_produces_nothing(self):
        assert read_geometry(parse_config("[extruder]\nnozzle_diameter: 0.4\n")) is None

    def test_a_config_without_an_extruder_produces_nothing(self):
        assert read_geometry(parse_config("[stepper_x]\nposition_max: 200\n")) is None

    def test_extrusion_follows_the_filament_diameter(self):
        """2.85 mm filament needs far less length for the same volume."""
        thin = read_geometry(parse_config(NEPTUNE))
        thick = read_geometry(parse_config(TINY))
        # Same deposited volume per mm of travel would be a fair comparison, so
        # compare the area ratio directly.
        assert thick.filament_area > thin.filament_area * 2

    def test_the_extrusion_maths_is_volume_conserving(self):
        geometry = read_geometry(parse_config(NEPTUNE))
        length = 100.0
        e = geometry.extrusion_for(length)
        deposited = length * geometry.width * geometry.layer_height
        consumed = e * geometry.filament_area
        assert consumed == pytest.approx(deposited, rel=1e-9)


# --------------------------------------------------------------------------- #
# Safety of the generated motion
# --------------------------------------------------------------------------- #


@pytest.mark.parametrize(
    "builder", [flow_cube, pressure_advance_tower, temperature_tower, retraction_tower]
)
class TestGeneratedMotionIsSafe:
    def test_no_coordinate_is_negative(self, builder):
        gcode = builder(parse_config(NEPTUNE)).gcode
        assert "X-" not in gcode
        assert "Y-" not in gcode
        assert "Z-" not in gcode

    def test_every_move_is_inside_the_configured_travel(self, builder):
        gcode = builder(parse_config(NEPTUNE)).gcode
        assert max(coordinates(gcode, "X")) <= 330
        assert max(coordinates(gcode, "Y")) <= 330

    def test_it_homes_before_it_moves(self, builder):
        gcode = builder(parse_config(NEPTUNE)).gcode
        assert gcode.index("G28") < gcode.index("G1 X")

    def test_the_bed_is_hot_before_homing_on_a_probed_machine(self, builder):
        gcode = builder(parse_config(NEPTUNE)).gcode
        assert gcode.index("M190") < gcode.index("G28")

    def test_nothing_extrudes_before_the_hotend_is_at_temperature(self, builder):
        gcode = builder(parse_config(NEPTUNE)).gcode
        first_extrusion = next(
            index for index, line in enumerate(gcode.splitlines())
            if line.startswith("G1 ") and " E" in line
        )
        heat = next(
            index for index, line in enumerate(gcode.splitlines())
            if line.startswith("M109")
        )
        assert heat < first_extrusion

    def test_it_ends_cold_and_released(self, builder):
        gcode = builder(parse_config(NEPTUNE)).gcode
        for command in ("TURN_OFF_HEATERS", "M107", "M84"):
            assert command in gcode

    def test_it_fits_a_much_smaller_bed(self, builder):
        gcode = builder(parse_config(TINY)).gcode
        assert gcode
        assert max(coordinates(gcode, "X")) <= 120
        assert max(coordinates(gcode, "Y")) <= 120
        assert "X-" not in gcode

    def test_a_config_that_cannot_place_it_is_refused_not_guessed(self, builder):
        result = builder(parse_config("[extruder]\nnozzle_diameter: 0.4\n"))
        assert not result.ok
        assert result.gcode == ""


# --------------------------------------------------------------------------- #
# Flow
# --------------------------------------------------------------------------- #


class TestFlow:
    def test_the_expected_wall_is_the_extrusion_width(self):
        """The whole measurement rests on this being a single wall."""
        result = flow_cube(parse_config(NEPTUNE))
        assert result.parameters["expected_wall_mm"] == pytest.approx(0.48, abs=0.001)

    def test_the_wide_nozzle_machine_expects_a_wider_wall(self):
        result = flow_cube(parse_config(TINY))
        assert result.parameters["expected_wall_mm"] == pytest.approx(0.72, abs=0.001)

    def test_a_thick_wall_means_too_much_flow(self):
        assert flow_from_measurement(0.48, 0.52, 1.0) == pytest.approx(0.923, abs=0.001)

    def test_a_thin_wall_means_too_little(self):
        assert flow_from_measurement(0.48, 0.44, 1.0) == pytest.approx(1.0909, abs=0.001)

    def test_an_existing_flow_is_compounded_not_replaced(self):
        assert flow_from_measurement(0.48, 0.52, 0.95) == pytest.approx(0.8769, abs=0.001)

    def test_an_absurd_measurement_is_refused(self):
        """Half or double the expected width is a mismeasurement, not flow."""
        assert flow_from_measurement(0.48, 1.5) is None
        assert flow_from_measurement(0.48, 0.1) is None
        assert flow_from_measurement(0.48, 0) is None

    def test_no_bed_commands_on_a_machine_without_a_heated_bed(self):
        gcode = flow_cube(parse_config(TINY)).gcode
        assert "M190" not in gcode
        assert "M140" not in gcode


# --------------------------------------------------------------------------- #
# Pressure advance
# --------------------------------------------------------------------------- #


class TestPressureAdvance:
    def test_it_uses_klippers_own_tuning_tower(self):
        gcode = pressure_advance_tower(parse_config(NEPTUNE)).gcode
        assert "TUNING_TOWER" in gcode
        assert "SET_PRESSURE_ADVANCE" in gcode

    def test_each_layer_changes_speed_so_the_corners_are_the_test(self):
        gcode = pressure_advance_tower(parse_config(NEPTUNE)).gcode
        feedrates = set(re.findall(r"F(\d+)", gcode))
        assert len(feedrates) >= 3

    def test_a_height_converts_back_to_a_value(self):
        # 12 mm at 0.2 mm layers is 60 layers, 60 * 0.005 = 0.30
        assert pressure_advance_from_height(
            12.0, start=0.0, step=0.005, layer_height=0.2
        ) == pytest.approx(0.30, abs=0.0001)

    def test_zero_height_gives_the_starting_value(self):
        assert pressure_advance_from_height(
            0.0, start=0.02, step=0.005, layer_height=0.2
        ) == pytest.approx(0.02)

    def test_an_impossible_value_is_refused(self):
        """Above 2.0 the height was misread, not the extruder made exotic."""
        assert pressure_advance_from_height(
            500.0, start=0.0, step=0.005, layer_height=0.2
        ) is None
        assert pressure_advance_from_height(
            -1.0, start=0.0, step=0.005, layer_height=0.2
        ) is None

    def test_the_tower_resets_the_value_when_it_finishes(self):
        """Otherwise the tuning value silently stays on the next print."""
        gcode = pressure_advance_tower(parse_config(NEPTUNE)).gcode
        tail = gcode[gcode.rindex("TUNING_TOWER"):]
        assert "SET_PRESSURE_ADVANCE" in tail


# --------------------------------------------------------------------------- #
# Temperature
# --------------------------------------------------------------------------- #


class TestTemperature:
    def test_the_bands_step_downwards(self):
        gcode = temperature_tower(parse_config(NEPTUNE)).gcode
        temperatures = [int(value) for value in re.findall(r"M104 S(\d+)", gcode)]
        # The first M104 is the standby heat in the preamble.
        bands = temperatures[1:]
        assert bands == sorted(bands, reverse=True)

    def test_it_refuses_to_ask_for_more_than_max_temp(self):
        result = temperature_tower(parse_config(NEPTUNE), start_temp=300.0)
        assert not result.ok
        assert "max_temp" in result.blockers[0]

    def test_no_band_is_below_the_minimum_extrude_temperature(self):
        """A band the hotend would refuse to extrude at prints nothing and
        stalls the tower."""
        gcode = temperature_tower(
            parse_config(NEPTUNE), start_temp=200.0, step_temp=-20.0, bands=5
        ).gcode
        temperatures = [int(value) for value in re.findall(r"M10[49] S(\d+)", gcode)]
        printing = [t for t in temperatures if t > 150]
        assert min(printing) >= 175

    def test_the_temperatures_are_listed_for_the_user(self):
        result = temperature_tower(parse_config(NEPTUNE))
        assert "220" in result.instructions_ar[0]


# --------------------------------------------------------------------------- #
# Retraction
# --------------------------------------------------------------------------- #


class TestRetraction:
    def test_it_travels_between_two_towers(self):
        gcode = retraction_tower(parse_config(NEPTUNE)).gcode
        xs = coordinates(gcode, "X")
        assert max(xs) - min(xs) > 30, "the gap is where stringing shows"

    def test_it_uses_firmware_retraction(self):
        gcode = retraction_tower(parse_config(NEPTUNE)).gcode
        assert "G10" in gcode and "G11" in gcode
        assert "SET_RETRACTION" in gcode

    def test_a_printer_without_firmware_retraction_is_told_why(self):
        without = parse_config(NEPTUNE.replace("[firmware_retraction]", "[unused_section]"))
        entry = next(item for item in available(without) if item["id"] == "retraction")
        assert entry["ok"] is False
        assert "firmware_retraction" in entry["blockers"][0]


# --------------------------------------------------------------------------- #
# Catalogue
# --------------------------------------------------------------------------- #


class TestCatalogue:
    def test_this_printer_can_run_all_four(self):
        entries = available(parse_config(NEPTUNE))
        assert len(entries) == 4
        assert all(entry["ok"] for entry in entries), [
            (entry["id"], entry["blockers"]) for entry in entries
        ]

    def test_an_unusable_config_reports_a_reason_for_each(self):
        entries = available(parse_config("[extruder]\nnozzle_diameter: 0.4\n"))
        assert all(not entry["ok"] and entry["blockers"] for entry in entries)

    def test_every_test_estimates_how_long_it_takes(self):
        for entry in available(parse_config(NEPTUNE)):
            assert entry["estimated_minutes"] > 0
