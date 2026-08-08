from __future__ import annotations

from pathlib import Path

import httpx
import pytest
from fastapi.testclient import TestClient

from app.config import AppConfig
from app.main import create_app
from app.storage import HistoryDB, ModelStore, safe_filename

SERVER_INFO = {"klippy_connected": True, "klippy_state": "ready"}
STATUS = {
    "print_stats": {"state": "standby", "filename": "", "print_duration": 0, "filament_used": 0},
    "extruder": {"temperature": 24.0, "target": 0.0},
    "heater_bed": {"temperature": 23.0, "target": 0.0},
    "toolhead": {"position": [0, 0, 0, 0], "homed_axes": ""},
    "gcode_move": {"speed_factor": 1.0, "extrude_factor": 1.0, "gcode_position": [0, 0, 0, 0]},
    "fan": {"speed": 0.0},
    "display_status": {"progress": 0.0},
    "virtual_sdcard": {"progress": 0.0},
    "webhooks": {"state": "ready", "state_message": "Printer is ready"},
}

RECORDED: list[tuple[str, str]] = []


def moonraker_handler(request: httpx.Request) -> httpx.Response:
    path = request.url.path
    RECORDED.append((request.method, path))
    if path == "/server/info":
        return httpx.Response(200, json={"result": SERVER_INFO})
    if path == "/printer/info":
        return httpx.Response(200, json={"result": {"state": "ready", "hostname": "pi"}})
    if path == "/printer/objects/query":
        return httpx.Response(200, json={"result": {"status": STATUS}})
    if path == "/printer/objects/list":
        return httpx.Response(200, json={"result": {"objects": ["extruder", "heater_bed"]}})
    if path == "/server/files/list":
        return httpx.Response(
            200,
            json={
                "result": [
                    {
                        "path": "benchy.gcode",
                        "modified": 1700000000.0,
                        "size": 1024,
                        "estimated_time": 3600,
                        "filament_total": 4321.5,
                        "filament_weight_total": 12.9,
                        "layer_height": 0.2,
                        "filament_type": "PLA",
                        "slicer": "PrusaSlicer",
                        "thumbnails": [
                            {"width": 300, "height": 300, "size": 9000, "relative_path": ".thumbs/benchy-300x300.png"}
                        ],
                    }
                ]
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
    cfg.power.provider = "demo"

    app = create_app(cfg)
    RECORDED.clear()
    with TestClient(app) as test_client:
        services = app.state.services
        services.moonraker._client = httpx.AsyncClient(
            transport=httpx.MockTransport(moonraker_handler), base_url="http://moonraker"
        )
        yield test_client


# --------------------------------------------------------------------------- #
# Core
# --------------------------------------------------------------------------- #


def test_health(client: TestClient):
    response = client.get("/api/health")
    assert response.status_code == 200
    body = response.json()
    assert body["ok"] is True
    assert body["power_provider"] == "demo"
    assert body["auth_required"] is False
    assert "version" in body


def test_root_lists_entry_points(client: TestClient):
    body = client.get("/").json()
    assert body["websocket"] == "/ws"
    assert body["health"] == "/api/health"


def test_system_endpoint(client: TestClient):
    body = client.get("/api/system").json()
    assert body["hostname"]
    assert "tailscale" in body
    assert body["memory_total_mb"] >= 0


def test_profiles_endpoint_exposes_the_shipped_profiles(client: TestClient):
    body = client.get("/api/profiles").json()
    assert {p["id"] for p in body["printers"]} >= {"neptune3plus_0.4"}
    assert {p["id"] for p in body["filaments"]} >= {"pla", "petg", "tpu"}
    assert {p["id"] for p in body["prints"]} >= {"standard", "klipper_fast"}


def test_slicer_info(client: TestClient):
    body = client.get("/api/slicer/info").json()
    assert body["engine"] == "prusaslicer"
    assert "available" in body


# --------------------------------------------------------------------------- #
# Printer
# --------------------------------------------------------------------------- #


def test_printer_status(client: TestClient):
    body = client.get("/api/printer/status").json()
    assert body["online"] is True
    assert body["state"] == "standby"
    assert body["nozzle"]["actual"] == 24.0
    assert body["bed"]["actual"] == 23.0


def test_printer_command(client: TestClient):
    response = client.post("/api/printer/command", json={"script": "G28"})
    assert response.status_code == 200
    assert "G28" in response.json()["message"]
    assert ("POST", "/printer/gcode/script") in RECORDED


def test_emergency_stop_is_not_reachable_through_plain_gcode(client: TestClient):
    response = client.post("/api/printer/command", json={"script": "M112"})
    assert response.status_code == 400
    assert "emergency_stop" in response.json()["detail"]


def test_empty_command_is_rejected(client: TestClient):
    assert client.post("/api/printer/command", json={"script": "   "}).status_code == 400


def test_printer_actions(client: TestClient):
    for action in ("pause", "resume", "cancel", "emergency_stop", "restart_firmware"):
        response = client.post("/api/printer/action", json={"action": action})
        assert response.status_code == 200, action

    assert client.post("/api/printer/action", json={"action": "nope"}).status_code == 400
    assert client.post("/api/printer/action", json={"action": "start"}).status_code == 400

    response = client.post("/api/printer/action", json={"action": "start", "filename": "a.gcode"})
    assert response.status_code == 200


# --------------------------------------------------------------------------- #
# Power
# --------------------------------------------------------------------------- #


def test_power_status_on_demo_provider(client: TestClient):
    body = client.get("/api/power/status").json()
    assert body["provider"] == "demo"
    assert body["state"] in {"on", "off"}


def test_power_on_and_off_when_cold(client: TestClient):
    assert client.post("/api/power/on").json()["state"] == "on"
    response = client.post("/api/power/off", json={"force": False})
    assert response.status_code == 200
    assert response.json()["state"] == "off"


def test_power_off_blocked_while_hot(client: TestClient):
    STATUS["extruder"]["temperature"] = 210.0
    try:
        response = client.post("/api/power/off", json={"force": False})
        assert response.status_code == 409
        detail = response.json()["detail"]
        assert detail["safety"]["safe"] is False
        assert detail["safety"]["blockers"]

        forced = client.post("/api/power/off", json={"force": True})
        assert forced.status_code == 200
        assert forced.json()["state"] == "off"
    finally:
        STATUS["extruder"]["temperature"] = 24.0


def test_power_off_blocked_while_printing(client: TestClient):
    STATUS["print_stats"]["state"] = "printing"
    try:
        response = client.post("/api/power/off", json={"force": False})
        assert response.status_code == 409
    finally:
        STATUS["print_stats"]["state"] = "standby"


def test_power_safety_report(client: TestClient):
    body = client.get("/api/power/safety").json()
    assert body["safe"] is True
    assert body["max_nozzle_temp"] == 50
    assert body["max_bed_temp"] == 45


# --------------------------------------------------------------------------- #
# Files
# --------------------------------------------------------------------------- #


def test_model_upload_list_delete(client: TestClient):
    response = client.post(
        "/api/models/upload",
        files={"file": ("cube.stl", b"solid cube\nendsolid cube\n", "application/octet-stream")},
    )
    assert response.status_code == 200
    model_id = response.json()["id"]

    listing = client.get("/api/models").json()
    assert any(item["id"] == model_id for item in listing)

    assert client.get(f"/api/models/{model_id}").json()["filename"] == "cube.stl"
    assert client.get(f"/api/models/{model_id}/download").status_code == 200
    assert client.delete(f"/api/models/{model_id}").status_code == 200
    assert client.get(f"/api/models/{model_id}").status_code == 404


def test_model_upload_rejects_unsupported_type(client: TestClient):
    response = client.post(
        "/api/models/upload", files={"file": ("notes.txt", b"hello", "text/plain")}
    )
    assert response.status_code == 400
    assert ".stl" in response.json()["detail"]


def test_gcode_listing_merges_moonraker_metadata(client: TestClient):
    files = client.get("/api/gcodes").json()
    benchy = next(item for item in files if item["filename"] == "benchy.gcode")
    assert benchy["estimated_time"] == 3600
    assert benchy["filament_total_mm"] == 4321.5
    assert benchy["filament_type"] == "PLA"
    assert benchy["thumbnail_path"] == ".thumbs/benchy-300x300.png"
    assert benchy["source"] == "moonraker"


def test_gcode_upload_requires_gcode_extension(client: TestClient):
    response = client.post(
        "/api/gcodes/upload", files={"file": ("model.stl", b"solid", "application/octet-stream")}
    )
    assert response.status_code == 400


# --------------------------------------------------------------------------- #
# Slicing
# --------------------------------------------------------------------------- #


def test_slice_rejects_unknown_profile(client: TestClient):
    upload = client.post(
        "/api/models/upload",
        files={"file": ("cube.stl", b"solid cube\nendsolid cube\n", "application/octet-stream")},
    )
    model_id = upload.json()["id"]
    response = client.post(
        "/api/slice", json={"model_id": model_id, "filament_profile": "unobtanium"}
    )
    # 400 if the slicer is installed, 503 if it is not - either way, never a 500.
    assert response.status_code in {400, 503}


def test_slice_job_lookup_404(client: TestClient):
    assert client.get("/api/slice/does-not-exist").status_code == 404


# --------------------------------------------------------------------------- #
# History
# --------------------------------------------------------------------------- #


def test_history_starts_empty(client: TestClient):
    body = client.get("/api/history").json()
    assert body["entries"] == []
    assert body["stats"]["total_prints"] == 0


def test_history_db_round_trip(tmp_path: Path):
    db = HistoryDB(tmp_path / "h.db")
    entry_id = db.start_print("a.gcode", start_time=1000.0, estimated_filament_mm=100.0)
    assert db.active_entry() is not None
    db.finish_print(entry_id, result="completed", finish_time=1600.0, filament_used_mm=98.0)

    entries = db.list()
    assert len(entries) == 1
    assert entries[0].result == "completed"
    assert entries[0].duration == pytest.approx(600.0)

    stats = db.stats()
    assert stats.total_prints == 1
    assert stats.successful == 1
    assert stats.total_print_seconds == pytest.approx(600.0)
    assert stats.total_filament_mm == pytest.approx(98.0)

    assert db.delete(entry_id) is True
    assert db.list() == []
    db.close()


def test_history_prune_keeps_newest(tmp_path: Path):
    db = HistoryDB(tmp_path / "h.db")
    for index in range(5):
        entry = db.start_print(f"f{index}.gcode", start_time=1000.0 + index)
        db.finish_print(entry, result="completed", finish_time=1100.0 + index)
    db.prune(2)
    remaining = db.list()
    assert len(remaining) == 2
    assert remaining[0].filename == "f4.gcode"
    db.close()


# --------------------------------------------------------------------------- #
# Storage helpers
# --------------------------------------------------------------------------- #


def test_safe_filename_strips_paths_and_keeps_arabic():
    assert safe_filename("../../etc/passwd") == "passwd"
    assert safe_filename("مكعب.stl") == "مكعب.stl"
    assert safe_filename("") == "model"
    assert "__" not in safe_filename("a__b.stl")


def test_model_store_ids_are_stable(tmp_path: Path):
    store = ModelStore(tmp_path)
    model = store.save("cube.stl", b"x")
    assert store.get(model.id) is not None
    assert store.path_for(model.id) is not None
    assert store.delete(model.id) is True
    assert store.get(model.id) is None


# --------------------------------------------------------------------------- #
# Authentication
# --------------------------------------------------------------------------- #


def test_api_token_is_enforced_when_configured(tmp_path: Path):
    cfg = AppConfig()
    cfg.paths.data_dir = str(tmp_path / "d")
    cfg.paths.models_dir = str(tmp_path / "d" / "models")
    cfg.paths.gcode_dir = str(tmp_path / "d" / "gcode")
    cfg.paths.database = str(tmp_path / "d" / "n.db")
    cfg.paths.profiles_dir = str(Path(__file__).resolve().parent.parent / "profiles")
    cfg.power.provider = "demo"
    cfg.server.api_token = "s3cret"

    app = create_app(cfg)
    with TestClient(app) as test_client:
        assert test_client.get("/api/health").status_code == 200  # health stays open
        assert test_client.get("/api/system").status_code == 401
        assert test_client.get("/api/system", headers={"X-API-Key": "wrong"}).status_code == 401
        assert test_client.get("/api/system", headers={"X-API-Key": "s3cret"}).status_code == 200
        assert (
            test_client.get("/api/system", headers={"Authorization": "Bearer s3cret"}).status_code
            == 200
        )


# --------------------------------------------------------------------------- #
# WebSocket
# --------------------------------------------------------------------------- #


def test_websocket_handshake_and_ping(client: TestClient):
    with client.websocket_connect("/ws") as websocket:
        hello = websocket.receive_json()
        assert hello["type"] == "hello"
        assert hello["payload"]["power_provider"] == "demo"

        summary = websocket.receive_json()
        assert summary["type"] == "summary"

        printer = websocket.receive_json()
        assert printer["type"] == "printer"

        power = websocket.receive_json()
        assert power["type"] == "power"

        websocket.send_json({"type": "ping"})
        assert websocket.receive_json()["type"] == "pong"


def test_websocket_rejects_bad_token(tmp_path: Path):
    cfg = AppConfig()
    cfg.paths.data_dir = str(tmp_path / "d")
    cfg.paths.models_dir = str(tmp_path / "d" / "models")
    cfg.paths.gcode_dir = str(tmp_path / "d" / "gcode")
    cfg.paths.database = str(tmp_path / "d" / "n.db")
    cfg.paths.profiles_dir = str(Path(__file__).resolve().parent.parent / "profiles")
    cfg.power.provider = "demo"
    cfg.server.api_token = "s3cret"

    app = create_app(cfg)
    with TestClient(app) as test_client:
        with pytest.raises(Exception):
            with test_client.websocket_connect("/ws") as websocket:
                websocket.receive_json()
