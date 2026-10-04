from __future__ import annotations

import httpx
import pytest

from app.config import MoonrakerConfig
from app.moonraker import MoonrakerClient, MoonrakerError, flatten_temperatures, progress_from_status
from app.printer_state import build_status, estimate_time_left, fetch_status, layer_info

SERVER_INFO = {
    "klippy_connected": True,
    "klippy_state": "ready",
    "components": ["server", "file_manager"],
    "moonraker_version": "v0.9.3",
}

STATUS = {
    "print_stats": {
        "filename": "benchy.gcode",
        "total_duration": 1200.0,
        "print_duration": 1100.0,
        "filament_used": 2345.6,
        "state": "printing",
        "message": "",
        "info": {"total_layer": 120, "current_layer": 42},
    },
    "display_status": {"progress": 0.35, "message": None},
    "virtual_sdcard": {"progress": 0.34, "is_active": True, "file_position": 1234},
    "toolhead": {
        "position": [10.0, 20.0, 0.6, 55.0],
        "homed_axes": "xyz",
        "max_velocity": 300.0,
        "max_accel": 3000.0,
        "square_corner_velocity": 5.0,
    },
    "extruder": {"temperature": 209.8, "target": 210.0, "power": 0.4},
    "heater_bed": {"temperature": 59.6, "target": 60.0, "power": 0.2},
    "fan": {"speed": 0.75, "rpm": None},
    "gcode_move": {
        "speed": 6000.0,
        "speed_factor": 1.25,
        "extrude_factor": 0.98,
        "gcode_position": [10.0, 20.0, 0.6, 55.0],
    },
    "webhooks": {"state": "ready", "state_message": "Printer is ready"},
}


def make_client(handler) -> MoonrakerClient:
    client = MoonrakerClient(MoonrakerConfig())
    client._client = httpx.AsyncClient(
        transport=httpx.MockTransport(handler), base_url="http://testserver"
    )
    return client


def test_build_status_maps_every_dashboard_field():
    status = build_status(SERVER_INFO, STATUS)
    assert status.online is True
    assert status.state == "printing"
    assert status.klippy_state == "ready"
    assert status.filename == "benchy.gcode"
    assert status.progress == pytest.approx(0.35)
    assert status.nozzle.actual == pytest.approx(209.8)
    assert status.nozzle.target == pytest.approx(210.0)
    assert status.bed.actual == pytest.approx(59.6)
    assert status.bed.target == pytest.approx(60.0)
    assert status.position == [10.0, 20.0, 0.6]
    assert status.homed_axes == "xyz"
    assert status.speed_factor == pytest.approx(1.25)
    assert status.extrude_factor == pytest.approx(0.98)
    assert status.fan_speed == pytest.approx(0.75)
    assert status.current_layer == 42
    assert status.total_layer == 120
    assert status.filament_used_mm == pytest.approx(2345.6)


def test_progress_falls_back_to_virtual_sdcard():
    partial = {"virtual_sdcard": {"progress": 0.5}}
    assert progress_from_status(partial) == pytest.approx(0.5)
    assert progress_from_status({}) == 0.0


def test_estimated_time_left_uses_file_progress():
    remaining = estimate_time_left(STATUS, 0.35)
    assert remaining is not None
    # 1100 s elapsed at 35 % -> ~3143 s total -> ~2043 s remaining
    assert remaining == pytest.approx(2042.857, rel=1e-3)


def test_estimated_time_left_is_none_at_start():
    assert estimate_time_left({"print_stats": {"print_duration": 3}}, 0.0) is None


def test_layer_info_missing_is_none():
    assert layer_info({"print_stats": {}}) == (None, None)


def test_flatten_temperatures():
    temps = flatten_temperatures(STATUS)
    assert temps["nozzle_actual"] == pytest.approx(209.8)
    assert temps["bed_target"] == pytest.approx(60.0)


def test_unknown_state_is_normalised():
    payload = {"print_stats": {"state": "some_future_state"}}
    assert build_status(SERVER_INFO, payload).state == "unknown"


@pytest.mark.asyncio
async def test_query_objects_unwraps_result_status():
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/printer/objects/query"
        return httpx.Response(200, json={"result": {"status": STATUS, "eventtime": 1.0}})

    client = make_client(handler)
    result = await client.query_status()
    assert result["print_stats"]["state"] == "printing"
    await client.aclose()


@pytest.mark.asyncio
async def test_error_payload_becomes_moonraker_error():
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            400,
            json={"error": {"code": 400, "message": "Unknown command: FOO"}},
            headers={"content-type": "application/json"},
        )

    client = make_client(handler)
    with pytest.raises(MoonrakerError) as excinfo:
        await client.run_gcode("FOO")
    assert "Unknown command: FOO" in str(excinfo.value)
    await client.aclose()


@pytest.mark.asyncio
async def test_connection_failure_is_wrapped():
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("connection refused")

    client = make_client(handler)
    with pytest.raises(MoonrakerError) as excinfo:
        await client.server_info()
    assert "unreachable" in str(excinfo.value).lower()
    await client.aclose()


@pytest.mark.asyncio
async def test_fetch_status_survives_offline_printer():
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("no route to host")

    client = make_client(handler)
    status = await fetch_status(client)
    assert status.online is False
    assert status.error
    assert status.state == "unknown"
    await client.aclose()


@pytest.mark.asyncio
async def test_fetch_status_reports_klipper_disconnected():
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            json={
                "result": {
                    "klippy_connected": False,
                    "klippy_state": "shutdown",
                    "klippy_message": "MCU shutdown",
                }
            },
        )

    client = make_client(handler)
    status = await fetch_status(client)
    assert status.online is True
    assert status.state == "error"
    assert "MCU shutdown" in (status.error or "")
    await client.aclose()


@pytest.mark.asyncio
async def test_print_control_endpoints_hit_the_right_paths():
    seen: list[tuple[str, str, str]] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append((request.method, request.url.path, request.url.query.decode()))
        return httpx.Response(200, json={"result": "ok"})

    client = make_client(handler)
    await client.start_print("a/b.gcode")
    await client.pause_print()
    await client.resume_print()
    await client.cancel_print()
    await client.emergency_stop()
    await client.run_gcode("G28")
    await client.restart_service("moonraker")
    await client.delete_gcode("old.gcode")
    await client.aclose()

    paths = [(method, path) for method, path, _ in seen]
    assert ("POST", "/printer/print/start") in paths
    assert ("POST", "/printer/print/pause") in paths
    assert ("POST", "/printer/print/resume") in paths
    assert ("POST", "/printer/print/cancel") in paths
    assert ("POST", "/printer/emergency_stop") in paths
    assert ("POST", "/printer/gcode/script") in paths
    assert ("POST", "/machine/services/restart") in paths
    assert ("DELETE", "/server/files/gcodes/old.gcode") in paths
    assert "filename=a%2Fb.gcode" in seen[0][2]


@pytest.mark.asyncio
async def test_power_device_helpers():
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/machine/device_power/devices":
            return httpx.Response(
                200, json={"result": {"devices": [{"device": "printer", "status": "on"}]}}
            )
        return httpx.Response(200, json={"result": {"printer": "off"}})

    client = make_client(handler)
    devices = await client.power_devices()
    assert devices[0]["device"] == "printer"
    assert await client.set_power_device("printer", "off") == "off"
    with pytest.raises(MoonrakerError):
        await client.set_power_device("printer", "explode")
    await client.aclose()
