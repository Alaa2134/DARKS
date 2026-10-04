"""Telemetry anomaly detection.

Half of these tests are about *not* firing. A detector that flags every print
is one nobody reads, and then the one real warning arrives in a pile of noise -
so the false-positive cases here matter as much as the true ones: a tapering
part whose layers genuinely get quicker, the heat-up ramp, the purge line, a
print with no slicer metadata to compare against.
"""

from __future__ import annotations

import pytest

from app.anomaly.detector import AnomalyDetector, Severity


def detector(filament_mm: float | None = 100_000.0) -> AnomalyDetector:
    det = AnomalyDetector(clock=lambda: 1_000_000.0)
    det.begin("benchy.gcode", filament_mm)
    return det


def feed_layers(
    det: AnomalyDetector,
    times: list,
    *,
    filament_per_layer: float = 200.0,
    nozzle: float = 210.0,
    target: float = 210.0,
):
    """Drive the detector through a sequence of layers of the given durations."""
    duration = 0.0
    filament = 0.0
    for index, seconds in enumerate(times, start=1):
        det.observe(
            layer=index, print_duration=duration, filament_used_mm=filament,
            nozzle_actual=nozzle, nozzle_target=target,
        )
        duration += seconds
        filament += (
            filament_per_layer[index - 1]
            if isinstance(filament_per_layer, list)
            else filament_per_layer
        )
    # One more observation so the last layer is closed.
    det.observe(
        layer=len(times) + 1, print_duration=duration, filament_used_mm=filament,
        nozzle_actual=nozzle, nozzle_target=target,
    )
    return duration, filament


def find(findings, finding_id):
    return next((f for f in findings if f.id == finding_id), None)


# --------------------------------------------------------------------------- #
# Layer time drift - the earliest clog signal there is
# --------------------------------------------------------------------------- #


class TestLayerTimeDrift:
    def test_a_steady_print_raises_nothing(self):
        det = detector()
        feed_layers(det, [60.0] * 30)
        assert find(det.evaluate(), "layer_time_drift") is None

    def test_a_sustained_slowdown_is_caught(self):
        """The signature of a clog forming: same size layers, creeping slower."""
        det = detector()
        feed_layers(det, [60.0] * 16 + [95.0] * 10)
        finding = find(det.evaluate(), "layer_time_drift")

        assert finding is not None
        assert finding.severity == Severity.WARNING
        assert finding.evidence["change_percent"] == pytest.approx(58, abs=8)

    def test_a_severe_slowdown_is_urgent(self):
        det = detector()
        feed_layers(det, [60.0] * 16 + [130.0] * 10)
        finding = find(det.evaluate(), "layer_time_drift")
        assert finding.severity == Severity.URGENT

    def test_a_tapering_part_is_not_a_clog(self):
        """A cone's layers get quicker because they get smaller. If layer size
        were ignored, every conical print would raise a false alarm."""
        det = detector()
        times = [100.0 - index * 2 for index in range(26)]
        filaments = [400.0 - index * 8 for index in range(26)]
        feed_layers(det, times, filament_per_layer=filaments)
        assert find(det.evaluate(), "layer_time_drift") is None

    def test_a_widening_part_is_not_a_clog_either(self):
        det = detector()
        times = [40.0 + index * 3 for index in range(26)]
        filaments = [150.0 + index * 12 for index in range(26)]
        feed_layers(det, times, filament_per_layer=filaments)
        assert find(det.evaluate(), "layer_time_drift") is None

    def test_too_few_layers_means_no_verdict(self):
        det = detector()
        feed_layers(det, [60.0] * 5 + [200.0] * 3)
        assert find(det.evaluate(), "layer_time_drift") is None

    def test_the_finding_shows_its_arithmetic(self):
        det = detector()
        feed_layers(det, [60.0] * 16 + [110.0] * 10)
        finding = find(det.evaluate(), "layer_time_drift")
        assert finding.evidence["baseline_seconds"] == pytest.approx(60, abs=1)
        assert finding.evidence["recent_seconds"] == pytest.approx(110, abs=1)
        assert finding.evidence["layers_compared"] > 0


# --------------------------------------------------------------------------- #
# Extrusion against the slicer's plan
# --------------------------------------------------------------------------- #


class TestExtrusionDeviation:
    def test_matching_the_plan_raises_nothing(self):
        det = detector(100_000.0)
        assert find(det.evaluate(progress=0.5, filament_used_mm=50_000.0),
                    "extrusion_deviation") is None

    def test_under_extrusion_is_caught(self):
        det = detector(100_000.0)
        finding = find(det.evaluate(progress=0.5, filament_used_mm=42_000.0),
                       "extrusion_deviation")
        assert finding is not None
        assert finding.evidence["deviation_percent"] == pytest.approx(-16, abs=1)
        assert "بيزحلق" in finding.detail_ar

    def test_over_extrusion_says_something_different(self):
        det = detector(100_000.0)
        finding = find(det.evaluate(progress=0.5, filament_used_mm=58_000.0),
                       "extrusion_deviation")
        assert finding is not None
        assert "التدفق" in finding.detail_ar
        assert "Flow" in finding.suggestion_ar

    def test_a_severe_shortfall_is_urgent(self):
        det = detector(100_000.0)
        finding = find(det.evaluate(progress=0.5, filament_used_mm=35_000.0),
                       "extrusion_deviation")
        assert finding.severity == Severity.URGENT

    def test_early_progress_is_ignored(self):
        """The purge line and first layer distort the comparison badly."""
        det = detector(100_000.0)
        assert find(det.evaluate(progress=0.05, filament_used_mm=100.0),
                    "extrusion_deviation") is None

    def test_no_slicer_total_means_no_comparison(self):
        """Rather than inventing an expectation to compare against."""
        det = detector(None)
        assert find(det.evaluate(progress=0.5, filament_used_mm=10.0),
                    "extrusion_deviation") is None


# --------------------------------------------------------------------------- #
# Heaters
# --------------------------------------------------------------------------- #


def feed_temperatures(det: AnomalyDetector, samples: list, target: float = 210.0):
    for value in samples:
        det.observe(
            layer=None, print_duration=0.0, filament_used_mm=0.0,
            nozzle_actual=value, nozzle_target=target,
        )


class TestHeaterStability:
    def test_a_steady_hotend_raises_nothing(self):
        det = detector()
        feed_temperatures(det, [210.0, 210.2, 209.8, 210.1] * 20)
        assert find(det.evaluate(), "nozzle_unstable") is None

    def test_oscillation_is_caught(self):
        det = detector()
        feed_temperatures(det, [206.0, 214.0] * 40)
        finding = find(det.evaluate(), "nozzle_unstable")
        assert finding is not None
        assert finding.evidence["wobble_c"] == pytest.approx(4.0, abs=0.5)
        assert "PID_CALIBRATE" in finding.suggestion_ar

    def test_the_heat_up_ramp_is_not_instability(self):
        """Every print starts cold. Counting the ramp would flag all of them."""
        det = detector()
        feed_temperatures(det, [float(value) for value in range(25, 211, 2)])
        feed_temperatures(det, [210.0] * 40)
        assert find(det.evaluate(), "nozzle_unstable") is None

    def test_too_few_samples_means_no_verdict(self):
        det = detector()
        feed_temperatures(det, [200.0, 220.0] * 3)
        assert find(det.evaluate(), "nozzle_unstable") is None

    def test_sitting_below_target_is_reported_separately(self):
        det = detector()
        feed_temperatures(det, [201.0] * 40)
        finding = find(det.evaluate(), "nozzle_below_target")
        assert finding is not None
        assert finding.evidence["average_deficit_c"] == pytest.approx(9.0, abs=0.5)

    def test_being_slightly_under_is_normal(self):
        det = detector()
        feed_temperatures(det, [208.5] * 40)
        assert find(det.evaluate(), "nozzle_below_target") is None


# --------------------------------------------------------------------------- #
# Lifecycle
# --------------------------------------------------------------------------- #


class TestLifecycle:
    def test_a_new_print_starts_clean(self):
        det = detector()
        feed_layers(det, [60.0] * 16 + [130.0] * 10)
        assert det.evaluate()

        det.begin("other.gcode", 50_000.0)
        assert det.layers == []
        assert det.evaluate() == []

    def test_status_reports_what_it_is_watching(self):
        det = detector()
        feed_layers(det, [60.0] * 20)
        status = det.status()
        assert status["watching"] is True
        assert status["layers_observed"] >= 18

    def test_findings_serialise_with_their_evidence(self):
        det = detector(100_000.0)
        det.evaluate(progress=0.5, filament_used_mm=40_000.0)
        payload = det.status()["findings"][0]
        assert payload["severity"] in {"info", "watch", "warning", "urgent"}
        assert payload["evidence"]
        assert payload["title_ar"]
        assert payload["detected_at"] > 0

    def test_several_things_can_be_wrong_at_once(self):
        det = detector(100_000.0)
        feed_layers(det, [60.0] * 16 + [130.0] * 10, nozzle=200.0, target=210.0)
        # The heater checks poll far more often than layers change.
        feed_temperatures(det, [200.0] * 40)
        findings = det.evaluate(progress=0.5, filament_used_mm=40_000.0)
        assert {f.id for f in findings} >= {
            "layer_time_drift", "extrusion_deviation", "nozzle_below_target"
        }
