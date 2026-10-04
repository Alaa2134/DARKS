"""Reading a first-layer patch.

Patches are rendered synthetically at a known Z error, so the test knows the
right answer and can check the measurement recovers it. The relationship being
inverted is volume conservation - lift the nozzle and the line draws narrower -
so a rendered line width implies a Z error exactly, and the analyser has to
find it back.

The refusals matter more than the measurements. A Z offset applied from a bad
reading drives the nozzle into the bed, so every case where the image cannot
support a number has a test proving it returns `unreadable` rather than a
smaller number with lower confidence.
"""

from __future__ import annotations

import io

import pytest

np = pytest.importorskip("numpy")
Image = pytest.importorskip("PIL.Image")

from app.klipper.model import parse_config
from app.klipper.patterns import first_layer_patch
from app.vision.firstlayer import Verdict, analyse

SPACING = 1.44          # mm, three times the extrusion width
WIDTH = 0.48            # mm, what a correct first layer produces
LAYER = 0.20            # mm, commanded first layer height
PIXELS_PER_MM = 12.0


def render(
    *,
    line_width_mm: float = WIDTH,
    spacing_mm: float = SPACING,
    lines: int = 24,
    contrast: float = 0.7,
    tilt: float = 0.0,
    noise: float = 0.0,
) -> bytes:
    """A top-down patch of horizontal lines, as a JPEG.

    `tilt` stretches the spacing progressively down the image, which is what a
    camera looking at the bed from an angle actually does.
    """
    height = int(lines * spacing_mm * PIXELS_PER_MM)
    width = 240
    canvas = np.full((height, width), 0.15, dtype=np.float32)

    position = 0.0
    index = 0
    while position < height and index < lines * 2:
        stretch = 1.0 + tilt * (position / max(height, 1))
        period_px = spacing_mm * PIXELS_PER_MM * stretch
        line_px = line_width_mm * PIXELS_PER_MM * stretch
        start = int(position)
        end = int(position + line_px)
        canvas[start:end, :] = 0.15 + contrast
        position += period_px
        index += 1

    if noise:
        rng = np.random.default_rng(7)
        canvas = canvas + rng.normal(0, noise, canvas.shape).astype(np.float32)

    canvas = np.clip(canvas, 0.0, 1.0)
    image = Image.fromarray((canvas * 255).astype(np.uint8), mode="L")
    buffer = io.BytesIO()
    image.save(buffer, format="JPEG", quality=95)
    return buffer.getvalue()


def measure(frame: bytes, **kwargs):
    return analyse(
        frame,
        expected_spacing_mm=kwargs.pop("spacing", SPACING),
        expected_width_mm=WIDTH,
        first_layer_height_mm=LAYER,
        **kwargs,
    )


def width_for_z_error(delta_mm: float) -> float:
    """Volume conservation: w * (h0 + d) = w0 * h0."""
    return WIDTH * LAYER / (LAYER + delta_mm)


# --------------------------------------------------------------------------- #
# Recovering a known error
# --------------------------------------------------------------------------- #


class TestMeasurement:
    def test_a_correct_first_layer_is_called_good(self):
        result = measure(render(line_width_mm=WIDTH))
        assert result.verdict is Verdict.GOOD
        assert result.command is None, "nothing to apply when it is already right"

    def test_a_nozzle_too_high_is_detected(self):
        """Lifted 0.04 mm, so the lines draw narrower."""
        result = measure(render(line_width_mm=width_for_z_error(0.04)))
        assert result.verdict is Verdict.TOO_HIGH
        assert result.z_adjust_mm == pytest.approx(0.04, abs=0.012)

    def test_a_nozzle_too_low_is_detected(self):
        result = measure(render(line_width_mm=width_for_z_error(-0.04)))
        assert result.verdict is Verdict.TOO_LOW
        assert result.z_adjust_mm == pytest.approx(-0.04, abs=0.012)

    def test_the_correction_sign_raises_the_nozzle_when_it_is_too_high(self):
        """A positive Z_ADJUST raises. Getting this backwards drives the
        nozzle into the bed, so it is asserted explicitly."""
        result = measure(render(line_width_mm=width_for_z_error(0.05)))
        assert result.z_adjust_mm > 0
        assert "+" in result.command

    def test_it_emits_a_klipper_command_that_moves(self):
        result = measure(render(line_width_mm=width_for_z_error(0.04)))
        assert result.command.startswith("SET_GCODE_OFFSET Z_ADJUST=")
        assert "MOVE=1" in result.command

    def test_the_camera_needs_no_calibration(self):
        """The known spacing is the scale bar, so the same patch at a
        different apparent size gives the same answer."""
        global PIXELS_PER_MM
        original = PIXELS_PER_MM
        try:
            PIXELS_PER_MM = 8.0
            small = measure(render(line_width_mm=width_for_z_error(0.04)))
            PIXELS_PER_MM = 18.0
            large = measure(render(line_width_mm=width_for_z_error(0.04)))
        finally:
            PIXELS_PER_MM = original
        assert small.z_adjust_mm == pytest.approx(large.z_adjust_mm, abs=0.015)

    def test_it_survives_a_noisy_frame(self):
        result = measure(render(line_width_mm=width_for_z_error(0.04), noise=0.05))
        assert result.readable
        assert result.z_adjust_mm == pytest.approx(0.04, abs=0.02)


# --------------------------------------------------------------------------- #
# Refusing to answer
# --------------------------------------------------------------------------- #


class TestRefusals:
    def test_a_low_contrast_frame_is_unreadable(self):
        """Dark filament on a dark sheet. Guessing here crashes a nozzle."""
        result = measure(render(contrast=0.04))
        assert result.verdict is Verdict.UNREADABLE
        assert result.z_adjust_mm is None
        assert "الإضاءة" in result.blockers[0] or "ضعيف" in result.blockers[0]

    def test_too_few_lines_is_unreadable(self):
        result = measure(render(lines=3))
        assert result.verdict is Verdict.UNREADABLE
        assert "خط" in result.blockers[0]

    def test_an_angled_camera_is_refused(self):
        """Perspective breaks the pixels-to-millimetres scale the whole
        measurement rests on."""
        result = measure(render(tilt=1.2))
        assert result.verdict is Verdict.UNREADABLE
        assert "زاوية" in result.blockers[0]

    def test_an_implausible_correction_is_refused_not_applied(self):
        """A large apparent error is a bad image or bad flow, not a Z offset."""
        result = measure(render(line_width_mm=WIDTH * 0.5))
        assert result.verdict is Verdict.UNREADABLE
        assert result.z_adjust_mm is None
        assert "التدفق" in result.blockers[0]

    def test_a_corrupt_frame_is_unreadable(self):
        result = measure(b"not a jpeg")
        assert result.verdict is Verdict.UNREADABLE

    def test_nonsense_parameters_are_refused(self):
        result = analyse(
            render(), expected_spacing_mm=0, expected_width_mm=WIDTH,
            first_layer_height_mm=LAYER,
        )
        assert result.verdict is Verdict.UNREADABLE

    def test_an_unreadable_result_never_offers_a_command(self):
        for frame in (render(contrast=0.04), render(lines=3), b"junk"):
            assert measure(frame).command is None


# --------------------------------------------------------------------------- #
# What comes back
# --------------------------------------------------------------------------- #


class TestReporting:
    def test_the_measurements_are_reported_for_checking(self):
        result = measure(render(line_width_mm=width_for_z_error(0.03)))
        payload = result.to_dict()
        assert payload["measurements"]["line_width_mm"] > 0
        assert payload["measurements"]["mm_per_pixel"] > 0
        assert payload["measurements"]["lines_found"] >= 5
        assert payload["detail_ar"]

    def test_confidence_rises_with_contrast(self):
        weak = measure(render(line_width_mm=width_for_z_error(0.04), contrast=0.2))
        strong = measure(render(line_width_mm=width_for_z_error(0.04), contrast=0.8))
        assert strong.confidence > weak.confidence

    def test_confidence_is_never_claimed_for_an_unreadable_frame(self):
        assert measure(render(contrast=0.04)).confidence == 0.0

    def test_the_arabic_detail_explains_the_direction(self):
        far = measure(render(line_width_mm=width_for_z_error(0.05)))
        near = measure(render(line_width_mm=width_for_z_error(-0.05)))
        assert "بعيد" in far.detail_ar
        assert "قريب" in near.detail_ar

    def test_lines_and_gaps_of_equal_width_are_refused(self):
        """The pattern is drawn at a third; a half means the image is not
        showing what the generator drew, and which run is plastic is a
        coin flip."""
        result = measure(render(line_width_mm=SPACING / 2))
        assert result.verdict is Verdict.UNREADABLE


# --------------------------------------------------------------------------- #
# The generated pattern matches what the analyser expects
# --------------------------------------------------------------------------- #


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
filament_diameter: 1.75
min_extrude_temp: 170
max_temp: 250
[heater_bed]
max_temp: 110
"""


class TestPatternAgreesWithTheAnalyser:
    def test_the_pattern_spacing_is_three_times_the_line_width(self):
        """At twice, lines and gaps would be equal at a correct Z - and then
        nothing in a greyscale profile can say which of the two is plastic."""
        params = first_layer_patch(parse_config(NEPTUNE)).parameters
        assert params["spacing_mm"] == pytest.approx(params["expected_width_mm"] * 3)

    def test_the_pattern_reports_everything_the_analyser_needs(self):
        params = first_layer_patch(parse_config(NEPTUNE)).parameters
        for key in ("spacing_mm", "expected_width_mm", "first_layer_height_mm"):
            assert params[key] > 0

    def test_the_pattern_has_enough_lines_to_average_over(self):
        assert first_layer_patch(parse_config(NEPTUNE)).parameters["lines"] >= 12

    def test_a_round_trip_through_the_generated_numbers(self):
        """Render at the pattern's own numbers and recover a known error."""
        params = first_layer_patch(parse_config(NEPTUNE)).parameters
        spacing = params["spacing_mm"]
        width = params["expected_width_mm"]
        height = params["first_layer_height_mm"]

        error = 0.03
        rendered = render(
            line_width_mm=width * height / (height + error), spacing_mm=spacing, lines=30
        )
        result = analyse(
            rendered, expected_spacing_mm=spacing, expected_width_mm=width,
            first_layer_height_mm=height,
        )
        assert result.readable
        assert result.z_adjust_mm == pytest.approx(error, abs=0.015)
