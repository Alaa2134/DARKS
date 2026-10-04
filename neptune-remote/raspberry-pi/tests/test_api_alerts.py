"""The alerting endpoints, and the state machine behind them.

These go through the real AppState rather than the pieces in isolation, because
the bugs that matter here are wiring bugs: an event that reaches the WebSocket
but never the notification service is exactly as useless as no event at all.
"""

from __future__ import annotations

from pathlib import Path

import httpx
import pytest
from fastapi.testclient import TestClient

from app.config import AppConfig
from app.main import create_app
from app.schemas import FilamentSensorState, PrinterStatusResponse

BASE_STATUS = {
    "print_stats": {"state": "standby", "filename": "", "print_duration": 0, "filament_used": 0},
    "extruder": {"temperature": 24.0, "target": 0.0},
    "heater_bed": {"temperature": 23.0, "target": 0.0},
    "toolhead": {"position": [0, 0, 0, 0], "homed_axes": ""},
    "gcode_move": {"speed_factor": 1.0, "extrude_factor": 1.0, "gcode_position": [0, 0, 0, 0]},
    "fan": {"speed": 0.0},
    "display_status": {"progress": 0.0},
    "virtual_sdcard": {"progress": 0.0},
    "webhooks": {"state": "ready", "state_message": "Printer is ready"},
    "filament_switch_sensor filament_sensor": {"enabled": True, "filament_detected": True},
}


def moonraker_handler(request: httpx.Request) -> httpx.Response:
    path = request.url.path
    if path == "/server/info":
        return httpx.Response(200, json={"result": {"klippy_connected": True, "klippy_state": "ready"}})
    if path == "/printer/objects/query":
        return httpx.Response(200, json={"result": {"status": BASE_STATUS}})
    if path == "/printer/objects/list":
        return httpx.Response(
            200,
            json={
                "result": {
                    "objects": [
                        "extruder",
                        "heater_bed",
                        "filament_switch_sensor filament_sensor",
                        "pause_resume",
                        "gcode_macro PAUSE",
                    ]
                }
            },
        )
    if path.startswith("/printer/") or path.startswith("/machine/"):
        return httpx.Response(200, json={"result": "ok"})
    return httpx.Response(404, json={"error": {"message": "not found"}})


@pytest.fixture()
def client(tmp_path: Path):
    cfg = AppConfig()
    cfg.paths.data_dir = str(tmp_path / "data")
    cfg.paths.models_dir = str(tmp_path / "data" / "models")
    cfg.paths.gcode_dir = str(tmp_path / "data" / "gcode")
    cfg.paths.database = str(tmp_path / "data" / "neptune.db")
    cfg.paths.profiles_dir = str(Path(__file__).resolve().parent.parent / "profiles")
    cfg.storage.root = str(tmp_path / "storage")
    cfg.power.provider = "demo"

    app = create_app(cfg)
    with TestClient(app) as test_client:
        services = app.state.services
        services.moonraker._client = httpx.AsyncClient(
            transport=httpx.MockTransport(moonraker_handler), base_url="http://moonraker"
        )
        yield test_client


def _gcode_with_layers(count: int) -> str:
    """A file the preview index can actually count layers in."""
    lines = []
    for index in range(count):
        lines.append(f";LAYER:{index}")
        lines.append(f";Z:{0.2 * (index + 1):.2f}")
        lines.append(";TYPE:External perimeter")
        lines.append(f"G1 X10 Y10 Z{0.2 * (index + 1):.2f} E1 F1200")
        lines.append("G1 X20 Y10 E2 F1200")
    return "\n".join(lines) + "\n"


def services(client: TestClient):
    return client.app.state.services


# --------------------------------------------------------------------------- #
# Status and honesty about it
# --------------------------------------------------------------------------- #


class TestAlertStatus:
    def test_an_unconfigured_backend_says_so_plainly(self, client: TestClient):
        """Silence is the failure mode here, so it has to be stated."""
        body = client.get("/api/alerts/status").json()
        assert body["reachable_when_app_is_closed"] is False
        assert body["advice"]["level"] == "warning"
        assert "مفيش" in body["advice"]["ar"]

    def test_no_secret_is_ever_returned(self, client: TestClient):
        state = services(client)
        state.config.notifications.telegram.bot_token = "123456:SUPERSECRET"
        state.config.notifications.ntfy.token = "tk_secret"

        body = client.get("/api/alerts/status").text
        assert "SUPERSECRET" not in body
        assert "tk_secret" not in body

    def test_enabled_but_empty_channels_are_reported(self, tmp_path: Path):
        cfg = AppConfig()
        cfg.paths.database = str(tmp_path / "n.db")
        cfg.paths.profiles_dir = str(Path(__file__).resolve().parent.parent / "profiles")
        cfg.storage.root = str(tmp_path / "storage")
        cfg.notifications.ntfy.enabled = True  # but no topic

        app = create_app(cfg)
        with TestClient(app) as test_client:
            warnings = test_client.get("/api/alerts/status").json()["notifications"]["warnings"]
            assert any("topic" in warning for warning in warnings)


# --------------------------------------------------------------------------- #
# Preferences
# --------------------------------------------------------------------------- #


class TestPreferences:
    def test_reading_the_defaults(self, client: TestClient):
        body = client.get("/api/alerts/preferences").json()
        assert "print_finished" in body["preferences"]["events"]
        assert "power_lost" in body["critical_events"]

    def test_updating_and_persisting(self, client: TestClient):
        response = client.put(
            "/api/alerts/preferences",
            json={"events": ["power_lost", "print_finished"], "quiet_hours_enabled": True},
        )
        assert response.status_code == 200

        again = client.get("/api/alerts/preferences").json()["preferences"]
        assert sorted(again["events"]) == ["power_lost", "print_finished"]
        assert again["quiet_hours_enabled"] is True

    def test_preferences_survive_a_restart(self, client: TestClient, tmp_path: Path):
        """They live in the database, not in memory."""
        client.put("/api/alerts/preferences", json={"events": ["power_lost"]})

        state = services(client)
        from app.notify import NotificationService

        rebuilt = NotificationService(state.config.notifications, db=state.db)
        assert rebuilt.preferences.events == ["power_lost"]

    def test_a_partial_update_leaves_the_rest_alone(self, client: TestClient):
        before = client.get("/api/alerts/preferences").json()["preferences"]
        client.put("/api/alerts/preferences", json={"quiet_start_hour": 22})
        after = client.get("/api/alerts/preferences").json()["preferences"]
        assert after["events"] == before["events"]
        assert after["quiet_start_hour"] == 22

    def test_an_impossible_hour_is_rejected_by_the_schema(self, client: TestClient):
        assert client.put("/api/alerts/preferences", json={"quiet_start_hour": 99}).status_code == 422


# --------------------------------------------------------------------------- #
# Test messages
# --------------------------------------------------------------------------- #


class TestSendingTest:
    def test_testing_without_a_channel_is_a_clear_error_not_a_lie(self, client: TestClient):
        response = client.post("/api/alerts/test")
        assert response.status_code == 409
        assert "config.yaml" in response.json()["detail"]

    def test_a_test_message_reaches_a_configured_channel(self, client: TestClient):
        state = services(client)
        sent = []

        class Spy:
            name = "spy"
            sent_count = 0
            failed_count = 0
            last_error = ""
            last_success_at = 0.0

            async def send(self, http, notification):
                sent.append(notification)

            def describe(self):
                return {"name": self.name}

        state.notifications.channels = [Spy()]
        body = client.post("/api/alerts/test").json()
        assert body["sent"] is True
        assert len(sent) == 1

    def test_heartbeat_test_without_a_url_is_a_clear_error(self, client: TestClient):
        assert client.post("/api/alerts/heartbeat/test").status_code == 409


# --------------------------------------------------------------------------- #
# Outage endpoints
# --------------------------------------------------------------------------- #


class TestOutageEndpoints:
    def test_a_fresh_install_has_no_outages(self, client: TestClient):
        body = client.get("/api/alerts/outage").json()
        assert body["records"] == []
        assert body["in_outage"] is False

    def test_acknowledging_an_unknown_outage_is_a_404(self, client: TestClient):
        assert client.post("/api/alerts/outage/nope/acknowledge").status_code == 404

    def test_an_outage_appears_with_arabic_advice(self, client: TestClient):
        state = services(client)
        from app.power.outage import Detection, PrintSnapshot

        state.outage.open_outage(
            Detection(cause="printer_power", detail="device gone"),
            PrintSnapshot(filename="benchy.gcode", current_layer=412, total_layer=900),
        )

        body = client.get("/api/alerts/outage").json()
        assert body["records"][0]["cause_ar"] == "الكهرباء اتقطعت عن الطابعة"
        assert "412/900" in body["records"][0]["advice_ar"]

        record_id = body["records"][0]["id"]
        assert client.post(f"/api/alerts/outage/{record_id}/acknowledge").status_code == 200

    # ----------------------------------------------------------------- resume
    #
    # The Pi knew a print died and at which layer, and it could already build a
    # file starting from a layer. Nothing joined the two, so the app said "the
    # power went at layer 214" and left the user to find the file and count.

    def _cut_power(self, client: TestClient, **snapshot):
        from app.power.outage import Detection, PrintSnapshot

        services(client).outage.open_outage(
            Detection(cause="printer_power", detail="device gone"),
            PrintSnapshot(**snapshot),
        )

    def test_nothing_to_resume_on_a_fresh_install(self, client: TestClient):
        body = client.get("/api/alerts/outage/resume").json()

        assert body["available"] is False
        assert body["reason_ar"]

    def test_a_cut_print_offers_to_carry_on(self, client: TestClient, tmp_path):
        state = services(client)
        target = state.gcodes.path_for("benchy.gcode")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(_gcode_with_layers(300), encoding="utf-8")

        self._cut_power(
            client,
            filename="benchy.gcode",
            current_layer=214,
            total_layer=900,
            nozzle_target=210,
            bed_target=60,
            z_height=42.8,
        )

        body = client.get("/api/alerts/outage/resume").json()

        assert body["available"] is True
        assert body["filename"] == "benchy.gcode"
        # One layer back: the layer it was on is the one that did not finish,
        # and starting on top of half a layer leaves a seam.
        assert body["layer"] == 213
        assert body["recorded_layer"] == 214
        assert body["nozzle_temp"] == 210
        # The real count, read from the file: the app's resume screen bounds
        # its slider with it, and a zero leaves that screen unable to ask for
        # a plan at all.
        assert body["layer_count"] == 300

    def test_a_file_that_no_longer_has_that_layer_is_refused(self, client: TestClient):
        # Re-sliced, or a different job with the same name. Resuming into a
        # layer that does not exist would produce an empty file.
        state = services(client)
        target = state.gcodes.path_for("short.gcode")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(_gcode_with_layers(20), encoding="utf-8")

        self._cut_power(client, filename="short.gcode", current_layer=214)

        body = client.get("/api/alerts/outage/resume").json()

        assert body["available"] is False
        assert "اتغيّر" in body["reason_ar"]

    def test_a_print_that_died_on_the_first_layer_has_nothing_to_resume(
        self, client: TestClient
    ):
        self._cut_power(client, filename="benchy.gcode", current_layer=0)

        body = client.get("/api/alerts/outage/resume").json()

        assert body["available"] is False
        assert "أول طبقة" in body["reason_ar"]

    def test_a_file_that_is_not_on_the_pi_says_so_rather_than_404ing(
        self, client: TestClient
    ):
        # A print started from Mainsail lives in Moonraker's own folder. Saying
        # that beats an error that reads like the feature is broken.
        self._cut_power(client, filename="from-mainsail.gcode", current_layer=100)

        body = client.get("/api/alerts/outage/resume").json()

        assert body["available"] is False
        assert "from-mainsail.gcode" in body["reason_ar"]
        assert body["layer"] == 100

    def test_an_acknowledged_outage_can_still_be_resumed(self, client: TestClient):
        # Dismissing the card means "I have seen it", not "I have dealt with
        # it" - the print is usually picked up the next morning.
        state = services(client)
        target = state.gcodes.path_for("kit.gcode")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(_gcode_with_layers(80), encoding="utf-8")

        self._cut_power(client, filename="kit.gcode", current_layer=50)
        record_id = client.get("/api/alerts/outage").json()["records"][0]["id"]
        client.post(f"/api/alerts/outage/{record_id}/acknowledge")

        assert client.get("/api/alerts/outage/resume").json()["available"] is True

    def test_a_print_that_was_not_running_is_not_offered(self, client: TestClient):
        from app.power.outage import Detection

        services(client).outage.open_outage(
            Detection(cause="printer_power", detail="idle"), None
        )

        assert client.get("/api/alerts/outage/resume").json()["available"] is False


# --------------------------------------------------------------------------- #
# The wiring: events actually reach the notification service
# --------------------------------------------------------------------------- #


class TestEventsReachNotifications:
    @pytest.mark.asyncio
    async def test_a_printer_event_is_dispatched_as_a_notification(self, client: TestClient):
        state = services(client)
        sent = []

        class Spy:
            name = "spy"
            sent_count = 0
            failed_count = 0
            last_error = ""
            last_success_at = 0.0

            async def send(self, http, notification):
                sent.append(notification)

            def describe(self):
                return {"name": self.name}

        state.notifications.channels = [Spy()]
        await state._emit_event("print_finished", "Print finished", "", "benchy.gcode")

        assert len(sent) == 1
        assert sent[0].kind == "print_finished"
        assert "benchy.gcode" in sent[0].title

    @pytest.mark.asyncio
    async def test_a_broken_notification_channel_does_not_break_the_printer_loop(
        self, client: TestClient
    ):
        """Printer control always wins over alerting."""
        state = services(client)

        class Exploding:
            name = "boom"

            async def send(self, http, notification):
                raise RuntimeError("nope")

            def describe(self):
                return {}

        state.notifications.channels = [Exploding()]
        state.notifications.config.retries = 0
        await state._emit_event("print_finished", "Print finished")
        assert state.events[-1].kind == "print_finished"


# --------------------------------------------------------------------------- #
# Filament runout
# --------------------------------------------------------------------------- #


def status_with_filament(detected: bool, kind: str = "switch") -> PrinterStatusResponse:
    return PrinterStatusResponse(
        online=True,
        klippy_state="ready",
        state="printing",
        filename="benchy.gcode",
        filament_sensors={
            "filament_sensor": FilamentSensorState(
                name="filament_sensor", kind=kind, enabled=True, filament_detected=detected
            )
        },
    )


class TestFilamentRunout:
    @pytest.mark.asyncio
    async def test_a_runout_gets_its_own_event(self, client: TestClient):
        """Otherwise it is indistinguishable from someone pressing pause."""
        state = services(client)
        await state._check_filament(status_with_filament(True), status_with_filament(False))
        assert state.events[-1].kind == "filament_runout"

    @pytest.mark.asyncio
    async def test_reloading_filament_is_not_an_alert(self, client: TestClient):
        state = services(client)
        before = len(state.events)
        await state._check_filament(status_with_filament(False), status_with_filament(True))
        assert len(state.events) == before

    @pytest.mark.asyncio
    async def test_nothing_is_emitted_while_the_state_is_unchanged(self, client: TestClient):
        state = services(client)
        before = len(state.events)
        await state._check_filament(status_with_filament(True), status_with_filament(True))
        await state._check_filament(status_with_filament(False), status_with_filament(False))
        assert len(state.events) == before

    @pytest.mark.asyncio
    async def test_a_switch_is_not_described_as_catching_a_jam(self, client: TestClient):
        """It cannot. Saying otherwise promises a safety net that is not there."""
        state = services(client)
        await state._check_filament(status_with_filament(True), status_with_filament(False))
        assert "انحشار" not in state.events[-1].message

        await state._check_filament(
            status_with_filament(True, kind="motion"),
            status_with_filament(False, kind="motion"),
        )
        assert "انحشار" in state.events[-1].message

    def test_the_sensor_is_reported_in_the_printer_status(self, client: TestClient):
        """Discovered from the printer's own object list, not hardcoded."""
        state = services(client)
        state.moonraker.extra_objects = ["filament_switch_sensor filament_sensor"]

        body = client.get("/api/printer/status").json()
        assert body["filament_sensors"]["filament_sensor"]["kind"] == "switch"
        assert body["filament_sensors"]["filament_sensor"]["filament_detected"] is True
