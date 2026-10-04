"""Print modes.

The feature is not the dropdown - the profiles already existed. It is that a
mode's name has to match what the printer will actually do, and before this it
did not: "fast" asked for an acceleration the machine caps and a speed the
plastic cannot melt at, so the slicer quietly slowed everything down and the
time estimate was fiction.

So most of these tests are about the clamping, and about the clamping being
*reported*.
"""

from __future__ import annotations

import pytest

from pathlib import Path

import httpx
from fastapi.testclient import TestClient

from app.config import AppConfig
from app.main import create_app
from app.slicer.modes import MODES, resolve, resolve_all


@pytest.fixture()
def client(tmp_path):
    cfg = AppConfig()
    cfg.paths.data_dir = str(tmp_path / "data")
    cfg.paths.models_dir = str(tmp_path / "data" / "models")
    cfg.paths.gcode_dir = str(tmp_path / "data" / "gcode")
    cfg.paths.database = str(tmp_path / "data" / "neptune.db")
    cfg.paths.profiles_dir = str(Path(__file__).resolve().parent.parent / "profiles")
    cfg.storage.root = str(tmp_path / "storage")

    app = create_app(cfg)
    with TestClient(app) as test_client:
        app.state.services.moonraker._client = httpx.AsyncClient(
            transport=httpx.MockTransport(
                lambda request: httpx.Response(404, json={"error": {"message": "no"}})
            ),
            base_url="http://moonraker",
        )
        yield test_client

NEPTUNE_04 = {
    "nozzle_diameter": "0.4",
    "min_layer_height": "0.06",
    "max_layer_height": "0.3",
    "machine_max_acceleration_extruding": "3000",
    "machine_max_feedrate_x": "300",
}

NOZZLE_06 = dict(NEPTUNE_04, nozzle_diameter="0.6", max_layer_height="0.45")

PLA = {"filament_type": "PLA", "filament_max_volumetric_speed": "12"}
PETG = {"filament_type": "PETG", "filament_max_volumetric_speed": "8"}
# A filament profile with no volumetric cap, which many third-party ones omit.
UNCAPPED = {"filament_type": "PLA"}

FAST_PROFILE = {"infill_speed": "150"}


def build(mode="fast", printer=None, filament=None, print_values=None, **kwargs):
    return resolve(
        mode,
        printer_values=printer or NEPTUNE_04,
        filament_values=filament if filament is not None else PLA,
        print_values=print_values or FAST_PROFILE,
        **kwargs,
    )


def adjustment(mode, setting):
    return next((item for item in mode.adjustments if item.setting == setting), None)


# --------------------------------------------------------------------------- #
# Layer height follows the nozzle
# --------------------------------------------------------------------------- #


class TestLayerHeight:
    def test_layer_height_scales_with_the_nozzle(self):
        """A mode defined in millimetres stops making sense when the nozzle
        changes; defined as a ratio it keeps meaning the same thing."""
        small = build("balanced", printer=NEPTUNE_04)
        large = build("balanced", printer=NOZZLE_06)
        assert small.layer_height == pytest.approx(0.20, abs=0.001)
        assert large.layer_height == pytest.approx(0.30, abs=0.001)

    def test_no_mode_exceeds_three_quarters_of_the_nozzle(self):
        """Above that the plastic cannot be pressed flat enough to bond."""
        for mode_id in MODES:
            resolved = build(mode_id, printer=NOZZLE_06)
            assert resolved.layer_height <= 0.6 * 0.75 + 1e-9, mode_id

    def test_an_optimistic_printer_profile_does_not_win(self):
        """max_layer_height of 0.4 on a 0.4 nozzle is the profile being
        hopeful, not the physics changing."""
        optimistic = dict(NEPTUNE_04, max_layer_height="0.4")
        resolved = build("draft", printer=optimistic)
        assert resolved.layer_height <= 0.3 + 1e-9

    def test_the_printer_minimum_is_respected(self):
        coarse = dict(NEPTUNE_04, min_layer_height="0.15")
        resolved = build("miniature", printer=coarse)
        assert resolved.layer_height == pytest.approx(0.15)
        assert adjustment(resolved, "layer_height") is not None


# --------------------------------------------------------------------------- #
# The material's melt rate - the ceiling nobody accounts for
# --------------------------------------------------------------------------- #


class TestVolumetricLimit:
    def test_petg_cannot_run_at_the_speed_fast_asks_for(self):
        resolved = build("fast", filament=PETG)
        clamp = adjustment(resolved, "print_speed")
        assert clamp is not None
        assert clamp.applied < clamp.requested
        assert "PETG" in clamp.reason_ar

    def test_the_resulting_flow_sits_exactly_on_the_limit(self):
        resolved = build("fast", filament=PETG)
        assert resolved.volumetric_flow == pytest.approx(8.0, abs=0.01)

    def test_pla_gets_a_higher_ceiling_than_petg(self):
        assert build("fast", filament=PLA).print_speed > build("fast", filament=PETG).print_speed

    def test_a_filament_with_no_stated_limit_is_not_given_an_invented_one(self):
        resolved = build("fast", filament=UNCAPPED)
        assert adjustment(resolved, "print_speed") is None

    def test_a_thicker_layer_lowers_the_speed_the_material_allows(self):
        """Same flow ceiling, more plastic per millimetre, so fewer
        millimetres per second - which is why draft is not faster."""
        draft = build("draft", filament=PETG)
        balanced = build("balanced", filament=PETG)
        assert draft.print_speed < balanced.print_speed
        assert draft.volumetric_flow == pytest.approx(balanced.volumetric_flow, abs=0.1)


# --------------------------------------------------------------------------- #
# The machine's own limits
# --------------------------------------------------------------------------- #


class TestMachineLimits:
    def test_acceleration_is_capped_to_what_the_machine_does(self):
        resolved = build("draft")
        clamp = adjustment(resolved, "acceleration")
        assert clamp is not None
        assert clamp.requested == 5000
        assert clamp.applied == 3000

    def test_the_live_config_outranks_the_slicer_profile(self):
        """printer.cfg is what Klipper enforces; the profile is only a hint."""
        resolved = build("draft", max_accel=2500)
        assert resolved.acceleration == 2500

    def test_a_mode_within_the_limits_is_not_adjusted(self):
        resolved = build("miniature", filament=UNCAPPED)
        assert adjustment(resolved, "acceleration") is None

    def test_speed_is_capped_to_the_machine_maximum(self):
        slow_machine = dict(NEPTUNE_04, machine_max_feedrate_x="60")
        resolved = build("draft", printer=slow_machine, filament=UNCAPPED)
        assert resolved.print_speed == pytest.approx(60)
        assert adjustment(resolved, "print_speed") is not None


# --------------------------------------------------------------------------- #
# The finding this feature exists for
# --------------------------------------------------------------------------- #


class TestHonestComparison:
    def test_a_coarser_flow_limited_mode_is_flagged_as_pointless(self):
        """Once two modes both hit the melt-rate ceiling they take the same
        time, so the coarser one is pure loss - same wait, worse surface."""
        modes = {
            mode.id: mode
            for mode in resolve_all(
                printer_values=NEPTUNE_04, filament_values=PETG,
                print_values=FAST_PROFILE, max_accel=3000,
            )
        }
        draft = modes["draft"]
        assert draft.flow_limited
        assert draft.notes_ar, "the user has to be told this saves nothing"
        assert "مش هيكون أسرع" in draft.notes_ar[0]

        # It names the *finest* mode that costs the same, since that is the
        # one worth switching to.
        equivalent = [
            mode for mode in modes.values()
            if mode.layer_height < draft.layer_height
            and mode.relative_time <= draft.relative_time * 1.05
        ]
        best = min(equivalent, key=lambda mode: mode.layer_height)
        assert best.title_ar in draft.notes_ar[0]

    def test_with_pla_quality_really_is_slower_and_says_nothing_odd(self):
        modes = {
            mode.id: mode
            for mode in resolve_all(
                printer_values=NEPTUNE_04, filament_values=PLA,
                print_values=FAST_PROFILE, max_accel=3000,
            )
        }
        assert modes["quality"].relative_time > 1.5
        assert modes["quality"].notes_ar == []

    def test_balanced_is_the_reference_and_never_notes_itself(self):
        modes = {
            mode.id: mode
            for mode in resolve_all(
                printer_values=NEPTUNE_04, filament_values=PETG,
                print_values=FAST_PROFILE,
            )
        }
        assert modes["balanced"].relative_time == pytest.approx(1.0)
        assert modes["balanced"].notes_ar == []

    def test_an_uncapped_filament_produces_no_false_note(self):
        modes = {
            mode.id: mode
            for mode in resolve_all(
                printer_values=NEPTUNE_04, filament_values=UNCAPPED,
                print_values=FAST_PROFILE, max_accel=3000,
            )
        }
        assert modes["draft"].relative_time < 0.95
        assert modes["draft"].notes_ar == []


# --------------------------------------------------------------------------- #
# What comes out
# --------------------------------------------------------------------------- #


class TestOutput:
    def test_the_overrides_are_ready_for_a_slice_request(self):
        overrides = build("strong").overrides()
        assert overrides["perimeters"] == 5
        assert overrides["infill_percent"] == 45
        assert overrides["print_profile"] == "standard"
        assert 0 < overrides["layer_height"] <= 0.3

    def test_speeds_are_derived_from_the_clamped_speed_not_the_requested_one(self):
        resolved = build("fast", filament=PETG)
        speeds = resolved.speed_overrides()
        assert speeds["infill_speed"] == pytest.approx(resolved.print_speed, abs=0.1)
        assert speeds["external_perimeter_speed"] < speeds["infill_speed"]
        assert speeds["default_acceleration"] == 3000

    def test_every_mode_resolves_on_a_bare_configuration(self):
        """No printer profile, no filament profile, nothing to read."""
        for mode_id in MODES:
            resolved = resolve(mode_id)
            assert resolved is not None, mode_id
            assert resolved.layer_height > 0
            assert resolved.print_speed > 0

    def test_an_unknown_mode_is_none_rather_than_a_default(self):
        assert resolve("turbo") is None

    def test_the_payload_carries_the_reasoning(self):
        payload = build("draft", filament=PETG).to_dict()
        assert payload["was_clamped"] is True
        assert payload["flow_limited"] is True
        assert len(payload["adjustments"]) >= 2
        assert payload["tradeoff_ar"]
        assert payload["speed_overrides"]

    def test_each_mode_states_what_it_costs(self):
        for mode_id in MODES:
            assert build(mode_id).tradeoff_ar


# --------------------------------------------------------------------------- #
# Through the API
# --------------------------------------------------------------------------- #


class TestModeEndpoint:
    def test_the_endpoint_lists_every_mode_with_its_reasoning(self, client):
        body = client.get("/api/slice/modes?filament_profile=petg").json()
        modes = {mode["id"]: mode for mode in body["modes"]}

        assert set(modes) == set(MODES)
        assert modes["draft"]["was_clamped"] is True
        assert modes["draft"]["flow_limited"] is True
        assert modes["draft"]["notes_ar"], "draft matches fast on PETG - say so"

    def test_pla_and_petg_resolve_to_different_settings(self):
        """The same mode is genuinely different numbers per material."""
        pla = build("fast", filament=PLA)
        petg = build("fast", filament=PETG)
        assert pla.print_speed != petg.print_speed

    def test_a_slice_can_name_a_mode_instead_of_twelve_fields(self, client):
        response = client.post(
            "/api/slice",
            json={"model_id": "missing.stl", "mode": "strong", "upload_to_moonraker": False},
        )
        # There is no slicer installed in the test environment, so this cannot
        # reach 202. What matters is that the mode was accepted: a bad one
        # comes back as a 400 naming it, and this does not.
        assert response.status_code != 400
        assert "print mode" not in response.text

    def test_an_unknown_mode_is_rejected_by_name(self, client):
        response = client.post(
            "/api/slice", json={"model_id": "x.stl", "mode": "ludicrous"}
        )
        assert response.status_code == 400
        assert "ludicrous" in response.json()["detail"]
