"""PRINT_START / PRINT_END generation.

The fixtures are deliberately different machines. A generator that only works
on the config it was written against is a generator that has hardcoded that
config.
"""

from app.klipper.macros import suggest, suggest_print_end, suggest_print_start
from app.klipper.model import parse_config

# The reported printer: negative position_min on both X and Y, probed Z, a
# saved mesh, and safe_z_home.
NEPTUNE = """
[stepper_x]
position_min: -8.3
position_max: 330

[stepper_y]
position_min: -1.3
position_max: 330

[stepper_z]
endstop_pin: probe:z_virtual_endstop
position_min: -5
position_max: 410

[extruder]
min_temp: 0
max_temp: 250
min_extrude_temp: 170

[heater_bed]
max_temp: 110

[probe]
x_offset: -28.5
y_offset: 22

[safe_z_home]
home_xy_position: 160,160

[bed_mesh]
mesh_min: 22,22
mesh_max: 290,300

#*# <---------------------- SAVE_CONFIG ---------------------->
#*# [bed_mesh default]
#*# version = 1
"""

# No heated bed, no probe, no mesh, positive origins.
MINIMAL = """
[stepper_x]
position_max: 120

[stepper_y]
position_max: 120

[stepper_z]
position_max: 120

[extruder]
max_temp: 260
"""


def _start(text: str):
    return suggest_print_start(parse_config(text))


class TestPurgePlacement:
    def test_purge_starts_from_the_bed_origin_not_position_min(self):
        """position_min is homing overtravel, not printable surface.

        Measuring the purge from position_min put the stripe at X-3.3 on the
        reported printer - off the bed entirely, onto the frame.
        """
        gcode = _start(NEPTUNE).gcode
        assert "X-" not in gcode, "no purge coordinate may be negative"
        assert "G1 X5.0 Y5.0 Z0.3" in gcode

    def test_purge_stays_inside_the_far_limit(self):
        gcode = _start(NEPTUNE).gcode
        # 203 is well short of position_max 330.
        assert "G1 X203.0 Y5.0" in gcode

    def test_small_bed_gets_a_proportionally_shorter_purge(self):
        gcode = _start(MINIMAL).gcode
        assert "G1 X5.0 Y5.0 Z0.3" in gcode
        # 5 + 120*0.6 = 77, not the 203 of the larger machine.
        assert "G1 X77.0" in gcode

    def test_no_purge_when_travel_is_unknown(self):
        suggestion = _start("[extruder]\nmax_temp: 250\n")
        assert "G92 E0" not in suggestion.gcode
        assert any("guessed coordinates" in reason for reason in suggestion.rationale)


class TestHeatingOrder:
    def test_bed_reaches_temperature_before_homing(self):
        gcode = _start(NEPTUNE).gcode
        assert gcode.index("M190") < gcode.index("G28"), "probing a cold bed gives a wrong Z"

    def test_full_nozzle_heat_comes_after_homing(self):
        gcode = _start(NEPTUNE).gcode
        assert gcode.index("G28") < gcode.index("M109")

    def test_standby_temperature_is_below_min_extrude_temp(self):
        """Hot enough not to drip, cold enough that Klipper refuses to extrude."""
        gcode = _start(NEPTUNE).gcode
        assert "M104 S150" in gcode  # min_extrude_temp 170 - 20

    def test_standby_follows_a_different_min_extrude_temp(self):
        gcode = _start(NEPTUNE.replace("min_extrude_temp: 170", "min_extrude_temp: 190")).gcode
        assert "M104 S170" in gcode

    def test_no_bed_commands_without_a_heated_bed(self):
        gcode = _start(MINIMAL).gcode
        assert "M190" not in gcode
        assert "M140" not in gcode


class TestMesh:
    def test_saved_profile_is_loaded(self):
        suggestion = _start(NEPTUNE)
        assert "BED_MESH_PROFILE LOAD=default" in suggestion.gcode
        assert any("never applied" in reason for reason in suggestion.rationale)

    def test_bed_mesh_without_a_saved_profile_is_only_suggested(self):
        text = NEPTUNE.replace("#*# [bed_mesh default]", "#*# [probe]")
        suggestion = _start(text)
        assert "BED_MESH_PROFILE LOAD" not in suggestion.gcode
        assert "# BED_MESH_CALIBRATE" in suggestion.gcode

    def test_no_mesh_step_without_the_module(self):
        assert "BED_MESH" not in _start(MINIMAL).gcode


class TestPrintEnd:
    def test_parks_inside_the_configured_maximum(self):
        gcode = suggest_print_end(parse_config(NEPTUNE)).gcode
        assert "G1 X325.0 Y325.0" in gcode

    def test_releases_heaters_and_steppers(self):
        gcode = suggest_print_end(parse_config(NEPTUNE)).gcode
        for command in ("TURN_OFF_HEATERS", "M107", "M84"):
            assert command in gcode

    def test_no_park_move_when_travel_is_unknown(self):
        suggestion = suggest_print_end(parse_config("[extruder]\nmax_temp: 250\n"))
        assert "F6000" not in suggestion.gcode


class TestExistingMacros:
    def test_an_existing_macro_is_reported_rather_than_overwritten(self):
        # Inserted before the SAVE_CONFIG marker: everything after it is
        # Klipper's autosave block and is not live configuration.
        text = NEPTUNE.replace(
            "#*# <---------------------- SAVE_CONFIG ---------------------->",
            "[gcode_macro PRINT_START]\ngcode:\n    G28\n\n"
            "#*# <---------------------- SAVE_CONFIG ---------------------->",
        )
        suggestion = _start(text)
        assert suggestion.conflicts
        assert suggestion.existing == "gcode_macro PRINT_START"

    def test_a_macro_inside_the_autosave_block_is_not_live_configuration(self):
        """Anything after the SAVE_CONFIG marker is Klipper's own bookkeeping."""
        text = NEPTUNE + "\n[gcode_macro PRINT_START]\ngcode:\n    G28\n"
        assert not _start(text).conflicts

    def test_no_conflict_when_absent(self):
        assert not _start(NEPTUNE).conflicts


class TestSlicerWiring:
    def test_the_slicer_lines_are_included(self):
        """A macro nothing calls does nothing - the wiring is half the answer."""
        result = suggest(parse_config(NEPTUNE))
        assert "PRINT_START BED=" in result["slicer"]["start_gcode"]
        assert result["slicer"]["end_gcode"] == "PRINT_END"
        assert "twice" in result["slicer"]["note"]

    def test_already_configured_is_false_for_this_printer(self):
        assert suggest(parse_config(NEPTUNE))["already_configured"] is False


class TestNothingIsInvented:
    def test_every_coordinate_appears_in_the_source_config(self):
        """No temperature or coordinate may come from anywhere but the config."""
        suggestion = _start(NEPTUNE)
        # The generator must not emit a build volume it was not given.
        assert "320" not in suggestion.gcode
        assert "400" not in suggestion.gcode

    def test_missing_extruder_blocks_generation(self):
        suggestion = _start("[stepper_x]\nposition_max: 100\n")
        assert not suggestion.ok
        assert any("extruder" in blocker for blocker in suggestion.blockers)
