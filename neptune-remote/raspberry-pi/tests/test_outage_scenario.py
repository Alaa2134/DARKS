"""The whole power-cut sequence, start to finish.

The unit tests cover each piece. This covers the thing the pieces exist for:
somebody is out of the house, the mains goes, and the question is whether their
phone finds out and whether the backend can still say what was lost.

Two runs of the scenario, because they fail differently:

* the printer loses power and the Pi survives - detected live, reported
  immediately;
* the outage takes the Pi too - nothing can be sent at the time, so the answer
  has to come from what was already on disk when the next boot happens.
"""

from __future__ import annotations

from pathlib import Path

import httpx
import pytest
from fastapi.testclient import TestClient

from app.config import AppConfig
from app.main import create_app
from app.schemas import PrinterStatusResponse, TemperatureBlock

SERIAL_NAME = "usb-1a86_USB_Serial-if00-port0"


@pytest.fixture()
def app_state(tmp_path: Path):
    cfg = AppConfig()
    cfg.paths.data_dir = str(tmp_path / "data")
    cfg.paths.models_dir = str(tmp_path / "data" / "models")
    cfg.paths.gcode_dir = str(tmp_path / "data" / "gcode")
    cfg.paths.database = str(tmp_path / "data" / "neptune.db")
    cfg.paths.profiles_dir = str(Path(__file__).resolve().parent.parent / "profiles")
    cfg.storage.root = str(tmp_path / "storage")
    cfg.power.provider = "demo"
    # Written every poll so the test does not have to fake the clock.
    cfg.outage.snapshot_interval_seconds = 0.0

    app = create_app(cfg)
    with TestClient(app) as client:
        state = app.state.services
        state.moonraker._client = httpx.AsyncClient(
            transport=httpx.MockTransport(lambda request: httpx.Response(200, json={"result": {}})),
            base_url="http://moonraker",
        )
        # The MCU device, present until we "cut the power" by deleting it.
        serial = tmp_path / SERIAL_NAME
        serial.write_text("usb", encoding="utf-8")
        state.outage.serial_path = str(serial)
        state._outage_serial_resolved = True
        yield state, serial


class Spy:
    """A notification channel that just remembers what it was handed."""

    name = "spy"
    sent_count = 0
    failed_count = 0
    last_error = ""
    last_success_at = 0.0

    def __init__(self) -> None:
        self.sent = []

    async def send(self, http, notification) -> None:
        self.sent.append(notification)

    def describe(self):
        return {"name": self.name}

    @property
    def kinds(self):
        return [notification.kind for notification in self.sent]


def printing(layer: int = 412, z: float = 82.4) -> PrinterStatusResponse:
    return PrinterStatusResponse(
        online=True,
        klippy_state="ready",
        state="printing",
        filename="benchy.gcode",
        progress=0.45,
        current_layer=layer,
        total_layer=900,
        position=[100.0, 100.0, z],
        filament_used_mm=12_000.0,
        nozzle=TemperatureBlock(actual=210.0, target=210.0),
        bed=TemperatureBlock(actual=60.0, target=60.0),
    )


def dead(message: str = "Lost communication with MCU 'mcu'") -> PrinterStatusResponse:
    """What Moonraker reports once Klipper has given up."""
    return PrinterStatusResponse(
        online=True,
        klippy_state="shutdown",
        klippy_message=message,
        state="error",
        state_message=message,
    )


@pytest.mark.asyncio
async def test_the_printer_loses_power_while_the_pi_survives(app_state):
    state, serial = app_state
    spy = Spy()
    state.notifications.channels = [spy]

    # 1. A print is running, and is mirrored to disk as it goes.
    await state._handle_status(printing())
    assert state.outage.snapshot_file.exists()

    # 2. The mains goes. The USB interface deenumerates, so the device is gone.
    serial.unlink()
    await state._handle_status(dead())

    # 3. It is reported as a power cut, not as a generic Klipper error.
    assert "power_lost" in spy.kinds
    assert "klipper_error" not in spy.kinds, "one condition must not produce two alerts"

    # 4. And it says what was lost, at which layer.
    record = state.outage.last_record
    assert record is not None
    assert record.cause == "printer_power"
    assert record.was_printing is True
    assert record.snapshot.current_layer == 412
    assert "412/900" in record.advice_ar()

    # 5. Never "press resume": there is none, and homing would hit the part.
    assert "استئناف" in record.advice_ar()
    assert "شيلها" in record.advice_ar()


@pytest.mark.asyncio
async def test_a_klipper_crash_is_not_reported_as_a_power_cut(app_state):
    """Same visible state in Moonraker, different cause, different message."""
    state, serial = app_state
    spy = Spy()
    state.notifications.channels = [spy]

    await state._handle_status(printing())
    # The device is still attached: nothing was unplugged.
    await state._handle_status(dead("Heater extruder not heating at expected rate"))

    assert "power_lost" not in spy.kinds
    assert state.outage.last_record.cause == "klipper_shutdown"


@pytest.mark.asyncio
async def test_power_returning_closes_the_outage(app_state):
    state, serial = app_state
    spy = Spy()
    state.notifications.channels = [spy]

    await state._handle_status(printing())
    serial.unlink()
    await state._handle_status(dead())

    serial.write_text("usb", encoding="utf-8")
    await state._handle_status(
        PrinterStatusResponse(online=True, klippy_state="ready", state="standby")
    )

    assert "power_restored" in spy.kinds
    assert state.outage.in_outage is False
    assert state.outage.last_record.restored_at is not None


@pytest.mark.asyncio
async def test_the_outage_is_reported_once_not_on_every_poll(app_state):
    state, serial = app_state
    spy = Spy()
    state.notifications.channels = [spy]

    await state._handle_status(printing())
    serial.unlink()
    for _ in range(20):
        await state._handle_status(dead())

    assert spy.kinds.count("power_lost") == 1


@pytest.mark.asyncio
async def test_the_pi_goes_down_too_and_reports_on_the_next_boot(app_state, monkeypatch):
    """The case nothing local can report at the time.

    A print is running; the power goes and takes the Pi with it, so no
    notification is sent and no outage is opened. Everything depends on the
    snapshot that was already on disk.
    """
    state, serial = app_state
    spy = Spy()
    state.notifications.channels = [spy]

    await state._handle_status(printing(layer=512))
    assert state.outage.snapshot_file.exists()

    # Power cut. The process dies here - no clean stop, so nothing is cleared
    # and nothing is sent. Simulated by not calling stop().
    spy.sent.clear()

    # The Pi boots. /proc/uptime says the machine came up after that snapshot.
    snapshot_written_at = state.outage.live_snapshot.updated_at
    monkeypatch.setattr(
        "app.power.outage.boot_time", lambda now=None: snapshot_written_at + 60
    )
    state.outage._live = None

    await state._reconcile_interrupted_print()

    assert "print_interrupted" in spy.kinds
    record = state.outage.last_record
    assert record.cause == "pi_power"
    assert record.snapshot.current_layer == 512

    # The snapshot is consumed, so a second boot does not re-report it.
    assert not state.outage.snapshot_file.exists()


@pytest.mark.asyncio
async def test_a_service_restart_does_not_send_someone_home_from_work(app_state, monkeypatch):
    state, serial = app_state
    spy = Spy()
    state.notifications.channels = [spy]

    await state._handle_status(printing())
    spy.sent.clear()

    # Booted long before the snapshot: only the process restarted.
    monkeypatch.setattr("app.power.outage.boot_time", lambda now=None: 1.0)
    state.outage._live = None
    await state._reconcile_interrupted_print()

    assert "print_interrupted" not in spy.kinds
    assert state.outage.last_record.cause == "service_restart"


@pytest.mark.asyncio
async def test_a_print_that_finished_normally_leaves_nothing_to_recover(app_state):
    state, serial = app_state

    await state._handle_status(printing())
    assert state.outage.snapshot_file.exists()

    await state._handle_state_transition(
        "printing",
        "complete",
        PrinterStatusResponse(online=True, klippy_state="ready", state="complete",
                              filename="benchy.gcode"),
    )

    assert not state.outage.snapshot_file.exists()
    assert await _reconcile_returns_nothing(state)


async def _reconcile_returns_nothing(state) -> bool:
    before = len(state.outage.records)
    await state._reconcile_interrupted_print()
    return len(state.outage.records) == before


@pytest.mark.asyncio
async def test_an_interrupted_print_is_closed_in_the_history(app_state, monkeypatch):
    """Otherwise it sits at 'in progress' forever and every total is wrong."""
    state, _ = app_state
    state.notifications.channels = [Spy()]

    status = printing()
    state._ensure_history_entry(status)
    assert state.history.active_entry() is not None

    await state._handle_status(status)
    # Captured now, not inside the lambda: it is called after _live is cleared.
    booted_at = state.outage.live_snapshot.updated_at + 60
    monkeypatch.setattr("app.power.outage.boot_time", lambda now=None: booted_at)
    state.outage._live = None
    await state._reconcile_interrupted_print()

    assert state.history.active_entry() is None
    assert state.history.list(limit=1)[0].result == "interrupted"


@pytest.mark.asyncio
async def test_the_heartbeat_signals_failure_before_the_pi_can_die(app_state):
    """The last thing that gets out when the cut is about to take the Pi too."""
    state, serial = app_state
    state.notifications.channels = [Spy()]

    pinged = []
    state.config.notifications.heartbeat.enabled = True
    state.config.notifications.heartbeat.url = "https://hc.example.invalid/uuid"
    state.heartbeat.config = state.config.notifications.heartbeat
    state.heartbeat._client = httpx.AsyncClient(
        transport=httpx.MockTransport(
            lambda request: (pinged.append(str(request.url)), httpx.Response(200))[1]
        )
    )

    await state._handle_status(printing())
    serial.unlink()
    await state._handle_status(dead())

    assert any(url.endswith("/fail") for url in pinged)
