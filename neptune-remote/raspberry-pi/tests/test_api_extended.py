"""End-to-end API tests for the library, media, vision and inventory routers."""

from __future__ import annotations

import io
import struct
from pathlib import Path

import httpx
import pytest
from fastapi.testclient import TestClient

from app.config import AppConfig
from app.main import create_app

PROFILES = Path(__file__).resolve().parent.parent / "profiles"

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
    "bed_mesh": {
        "profile_name": "default",
        "mesh_min": [20, 20],
        "mesh_max": [300, 300],
        "probed_matrix": [[0.02, -0.01, 0.03], [0.0, 0.04, -0.02], [0.01, 0.0, 0.02]],
    },
}


def moonraker_handler(request: httpx.Request) -> httpx.Response:
    path = request.url.path
    if path == "/server/info":
        return httpx.Response(200, json={"result": SERVER_INFO})
    if path == "/printer/objects/query":
        return httpx.Response(200, json={"result": {"status": STATUS}})
    if path == "/server/files/list":
        return httpx.Response(200, json={"result": []})
    if path.startswith("/printer/") or path.startswith("/machine/") or path.startswith("/server/"):
        return httpx.Response(200, json={"result": "ok"})
    return httpx.Response(404, json={"error": {"message": "not found"}})


def binary_stl() -> bytes:
    triangles = [
        ((0, 0, 0), (20, 0, 0), (20, 30, 0)),
        ((0, 0, 0), (20, 30, 0), (0, 30, 0)),
        ((0, 0, 12), (20, 0, 12), (20, 30, 12)),
    ]
    data = bytearray(b"\0" * 80) + struct.pack("<I", len(triangles))
    for triangle in triangles:
        data += struct.pack("<3f", 0.0, 0.0, 1.0)
        for vertex in triangle:
            data += struct.pack("<3f", *vertex)
        data += struct.pack("<H", 0)
    return bytes(data)


@pytest.fixture()
def client(tmp_path: Path):
    config = AppConfig()
    config.paths.data_dir = str(tmp_path / "data")
    config.paths.models_dir = str(tmp_path / "data" / "models")
    config.paths.gcode_dir = str(tmp_path / "data" / "gcode")
    config.paths.database = str(tmp_path / "data" / "neptune.db")
    config.paths.profiles_dir = str(PROFILES)
    config.storage.root = str(tmp_path / "printer_data" / "neptune_remote")
    config.storage.backup_sources = []
    config.power.provider = "demo"
    config.camera.stream_url = ""
    config.camera.snapshot_url = ""
    config.camera.device = ""
    config.vision.mode = "warn"
    config.vision.provider = "heuristic"

    app = create_app(config)
    with TestClient(app) as test_client:
        services = app.state.services
        services.moonraker._client = httpx.AsyncClient(
            transport=httpx.MockTransport(moonraker_handler), base_url="http://moonraker"
        )
        yield test_client


def upload_model(client: TestClient, name_ar: str = "حامل موبايل", **fields) -> dict:
    response = client.post(
        "/api/library/upload",
        files={"file": ("phone_stand.stl", binary_stl(), "application/octet-stream")},
        data={"name_ar": name_ar, "category": "stands", "tags": "مكتب,موبايل", **fields},
    )
    assert response.status_code == 200, response.text
    return response.json()


# --------------------------------------------------------------------------- #
# Health / summary
# --------------------------------------------------------------------------- #


def test_health_reports_every_capability(client: TestClient):
    body = client.get("/api/health").json()
    for key in (
        "camera_available", "ffmpeg_available", "recording_mode", "timelapse_mode",
        "vision_mode", "vision_provider", "vision_available", "thumbnails_available",
        "storage_root", "library_items",
    ):
        assert key in body, key
    assert body["vision_provider"] == "heuristic"
    assert body["thumbnails_available"] is True


def test_summary_endpoint(client: TestClient):
    body = client.get("/api/summary").json()
    assert set(body) >= {
        "printer", "power", "camera", "recording", "timelapse", "vision",
        "queue", "filament", "library", "totals",
    }
    assert body["vision"]["never_cuts_power"] is True


# --------------------------------------------------------------------------- #
# Library
# --------------------------------------------------------------------------- #


def test_upload_generates_a_thumbnail_and_dimensions(client: TestClient):
    item = upload_model(client)
    assert item["name_ar"] == "حامل موبايل"
    assert item["thumbnail"]
    assert item["dimensions_x"] == pytest.approx(20.0)
    assert item["dimensions_z"] == pytest.approx(12.0)
    assert item["triangle_count"] == 3

    # And the thumbnail is really servable.
    image = client.get(f"/api/media/{item['thumbnail']}")
    assert image.status_code == 200
    assert image.headers["content-type"].startswith("image/")


def test_upload_rejects_unsupported_types(client: TestClient):
    response = client.post(
        "/api/library/upload",
        files={"file": ("notes.txt", b"hello", "text/plain")},
        data={"name_ar": "x"},
    )
    assert response.status_code == 400
    assert ".stl" in response.json()["detail"]


def test_media_endpoint_refuses_directory_escape(client: TestClient):
    response = client.get("/api/media/../../../etc/passwd")
    assert response.status_code in {400, 404}


def test_list_update_and_delete(client: TestClient):
    item = upload_model(client)

    assert any(entry["id"] == item["id"] for entry in client.get("/api/library").json())

    patched = client.patch(
        f"/api/library/{item['id']}", json={"favourite": True, "name_en": "Phone stand"}
    ).json()
    assert patched["favourite"] is True
    assert "favourites" in patched["collections"]

    assert client.get("/api/library?favourites=true").json()[0]["id"] == item["id"]
    assert client.delete(f"/api/library/{item['id']}").status_code == 200
    assert client.get(f"/api/library/{item['id']}").status_code == 404


def test_categories_endpoint(client: TestClient):
    upload_model(client)
    categories = {entry["id"]: entry for entry in client.get("/api/library/categories").json()}
    assert categories["stands"]["item_count"] == 1
    assert categories["stands"]["name_ar"] == "حوامل"


def test_download_model(client: TestClient):
    item = upload_model(client)
    response = client.get(f"/api/library/{item['id']}/download")
    assert response.status_code == 200
    assert len(response.content) == len(binary_stl())


def test_replace_thumbnail_with_a_photo(client: TestClient):
    from PIL import Image

    item = upload_model(client)
    buffer = io.BytesIO()
    Image.new("RGB", (64, 64), (200, 30, 30)).save(buffer, format="JPEG")

    response = client.post(
        f"/api/library/{item['id']}/thumbnail",
        files={"file": ("photo.jpg", buffer.getvalue(), "image/jpeg")},
    )
    assert response.status_code == 200
    assert response.json()["thumbnail"].endswith("_user.jpg")


def test_regenerate_thumbnail(client: TestClient):
    item = upload_model(client)
    response = client.post(f"/api/library/{item['id']}/regenerate-thumbnail")
    assert response.status_code == 200
    assert response.json()["thumbnail"]


def test_photos_endpoint(client: TestClient):
    item = upload_model(client)
    response = client.post(
        f"/api/library/{item['id']}/photos",
        files={"file": ("done.jpg", b"\xff\xd8\xff\xd9", "image/jpeg")},
        data={"caption": "بعد الطباعة"},
    )
    assert response.status_code == 200
    photo = response.json()
    assert client.delete(f"/api/library/photos/{photo['id']}").status_code == 200


# --------------------------------------------------------------------------- #
# Search
# --------------------------------------------------------------------------- #


def test_arabic_search_end_to_end(client: TestClient):
    upload_model(client, name_ar="حامل موبايل للمكتب")
    body = client.get("/api/search", params={"q": "ستاند تليفون"}).json()
    assert body["total"] >= 1
    assert body["results"][0]["item"]["name_ar"] == "حامل موبايل للمكتب"
    assert body["normalized_query"]


def test_search_typo_tolerance_end_to_end(client: TestClient):
    upload_model(client, name_ar="ميدالية مفاتيح")
    body = client.get("/api/search", params={"q": "ميدليه"}).json()
    assert body["total"] >= 1
    assert "ميدالية" in body["results"][0]["item"]["name_ar"]


def test_search_result_carries_the_image(client: TestClient):
    upload_model(client)
    result = client.get("/api/search", params={"q": "حامل"}).json()["results"][0]
    assert result["item"]["thumbnail"], "every search card must have an image"


def test_suggestions_endpoint(client: TestClient):
    upload_model(client, name_ar="ميدالية مفاتيح")
    suggestions = client.get("/api/search/suggest", params={"q": "ميد"}).json()
    assert any("ميدالية" in value for value in suggestions)


def test_ideas_endpoint(client: TestClient):
    upload_model(client, name_ar="منظم مكتب", category="office")
    response = client.post("/api/ideas", json={"room": "desk", "limit": 5})
    assert response.status_code == 200


# --------------------------------------------------------------------------- #
# Collections
# --------------------------------------------------------------------------- #


def test_collections_flow(client: TestClient):
    item = upload_model(client)
    builtin = {entry["id"] for entry in client.get("/api/collections").json()}
    assert "print_later" in builtin

    created = client.post("/api/collections", json={"name_ar": "مجموعتي"}).json()
    assert client.post(f"/api/collections/{created['id']}/items/{item['id']}").status_code == 200
    assert created["id"] in client.get(f"/api/library/{item['id']}").json()["collections"]
    assert client.delete(f"/api/collections/{created['id']}/items/{item['id']}").status_code == 200
    assert client.delete(f"/api/collections/{created['id']}").status_code == 200
    assert client.delete("/api/collections/favourites").status_code == 400


# --------------------------------------------------------------------------- #
# Print quality memory
# --------------------------------------------------------------------------- #


def test_rating_remembers_a_good_profile(client: TestClient):
    item = upload_model(client)
    response = client.post(
        "/api/library/ratings",
        json={
            "history_id": 1, "item_id": item["id"], "rating": "excellent",
            "profile": {"layer_height": 0.2, "filament_profile": "pla"},
        },
    )
    assert response.status_code == 200

    stored = client.get(f"/api/library/{item['id']}/successful-profile").json()
    assert stored["profile"]["layer_height"] == 0.2


def test_rating_rejects_unknown_values(client: TestClient):
    response = client.post(
        "/api/library/ratings", json={"history_id": 2, "rating": "amazing"}
    )
    assert response.status_code == 400


# --------------------------------------------------------------------------- #
# Camera / recording / timelapse
# --------------------------------------------------------------------------- #


def test_camera_status_without_hardware_is_honest(client: TestClient):
    body = client.get("/api/camera/status", params={"probe": "false"}).json()
    assert body["available"] is False
    assert body["source"] == "none"
    assert body["message_key"].startswith("camera.status")


def test_camera_devices_endpoint(client: TestClient):
    body = client.get("/api/camera/devices").json()
    assert "devices" in body and "count" in body


def test_snapshot_without_a_camera_returns_503(client: TestClient):
    response = client.get("/api/camera/snapshot")
    assert response.status_code == 503


def test_recording_start_without_a_camera_returns_503(client: TestClient):
    response = client.post("/api/camera/record/start")
    assert response.status_code == 503
    assert client.get("/api/camera/record/status").json()["recording"] is False


def test_recording_stop_without_a_session_returns_409(client: TestClient):
    assert client.post("/api/camera/record/stop").status_code == 409


def test_timelapse_status_and_macro(client: TestClient):
    status = client.get("/api/timelapse/status").json()
    assert status["running"] is False
    assert status["configured_mode"] == "off"

    macro = client.get("/api/timelapse/macro").json()
    assert macro["requires_approval"] is True
    assert "TIMELAPSE_TAKE_FRAME" in macro["macro"]
    assert "printer.cfg" in macro["warning"]


def test_timelapse_frame_without_a_session(client: TestClient):
    assert client.post("/api/timelapse/frame").status_code == 409


def test_videos_are_empty_and_storage_reports(client: TestClient):
    assert client.get("/api/videos").json() == []
    storage = client.get("/api/videos/storage").json()
    assert "disk_free_bytes" in storage
    assert storage["retention_policy"] == "max_size"


def test_unknown_video_404(client: TestClient):
    assert client.get("/api/videos/nope").status_code == 404
    assert client.delete("/api/videos/nope").status_code == 404


def test_roi_can_be_saved_and_validated(client: TestClient):
    assert client.post("/api/camera/roi", json={"roi": [0.1, 0.1, 0.8, 0.8]}).status_code == 200
    assert client.get("/api/vision/status").json()["roi"] == [0.1, 0.1, 0.8, 0.8]
    assert client.post("/api/camera/roi", json={"roi": [0, 0, 2, 2]}).status_code == 400


# --------------------------------------------------------------------------- #
# Vision
# --------------------------------------------------------------------------- #


def test_vision_status(client: TestClient):
    body = client.get("/api/vision/status").json()
    assert body["mode"] == "warn"
    assert body["provider"] == "heuristic"
    assert body["available"] is True
    assert body["can_pause"] is False
    assert body["never_cuts_power"] is True


def test_vision_settings_update(client: TestClient):
    body = client.post(
        "/api/vision/settings",
        json={"mode": "monitor", "interval_seconds": 10, "confirmations": 4},
    ).json()
    assert body["mode"] == "monitor"
    assert body["configured_interval"] == 10
    assert body["confirmations_required"] == 4


def test_vision_settings_reject_bad_mode(client: TestClient):
    assert client.post("/api/vision/settings", json={"mode": "destroy"}).status_code == 400


def test_vision_events_are_empty_at_first(client: TestClient):
    body = client.get("/api/vision/events").json()
    assert body["events"] == []
    assert client.delete("/api/vision/events").status_code == 200


def test_vision_start_without_a_camera_still_reports_clearly(client: TestClient):
    # The heuristic provider is available, so starting succeeds; snapshots will
    # simply fail and be reported through status.last_error.
    response = client.post("/api/vision/start")
    assert response.status_code in {200, 503}


def test_first_layer_confirmation(client: TestClient):
    assert client.post("/api/vision/first-layer-ok").status_code == 200


# --------------------------------------------------------------------------- #
# Filament / cost / products / maintenance / queue
# --------------------------------------------------------------------------- #


def test_filament_flow(client: TestClient):
    spool = client.post(
        "/api/filament",
        json={"brand": "eSun", "material": "PLA", "color_name": "أسود",
              "color_hex": "#101010", "initial_grams": 1000, "price": 700, "active": True},
    ).json()
    assert spool["material"] == "PLA"

    assert client.get("/api/filament/summary").json()["spool_count"] == 1

    consumed = client.post(
        f"/api/filament/{spool['id']}/consume", json={"grams": 100, "reason": "test"}
    ).json()
    assert consumed["remaining_grams"] == pytest.approx(900)

    check = client.get("/api/filament/check/estimate", params={"grams": 950}).json()
    assert check["ok"] is False
    assert check["message_key"] == "filament.check.not_enough"

    ok = client.get("/api/filament/check/estimate", params={"millimetres": 10000}).json()
    assert ok["ok"] is True

    assert client.delete(f"/api/filament/{spool['id']}").status_code == 200


def test_filament_check_requires_a_quantity(client: TestClient):
    assert client.get("/api/filament/check/estimate").status_code == 400


def test_cost_endpoints(client: TestClient):
    settings = client.get("/api/cost/settings").json()
    assert settings["currency"] == "EGP"

    settings["profit_percent"] = 60
    assert client.put("/api/cost/settings", json=settings).json()["profit_percent"] == 60

    breakdown = client.post(
        "/api/cost/calculate", json={"filament_grams": 100, "print_seconds": 7200}
    ).json()
    assert breakdown["cost_per_unit"] > 0
    assert breakdown["suggested_price_per_unit"] > breakdown["cost_per_unit"]
    assert any(line["key"] == "cost.line.filament" for line in breakdown["lines"])


def test_products_flow(client: TestClient):
    item = upload_model(client, name_ar="ميدالية")
    product = client.post(
        "/api/products",
        json={"item_id": item["id"], "print_cost": 12, "selling_price": 40, "colors": ["أسود"]},
    ).json()
    assert product["name_ar"] == "ميدالية"

    assert client.get("/api/library/" + item["id"]).json()["is_product"] is True
    assert client.get("/api/products/summary").json()["count"] == 1
    assert client.patch(f"/api/products/{product['id']}", json={"stock": 5}).json()["stock"] == 5
    assert client.delete(f"/api/products/{product['id']}").status_code == 200


def test_product_with_unknown_model_404(client: TestClient):
    response = client.post("/api/products", json={"item_id": "nope", "selling_price": 10})
    assert response.status_code == 404


def test_maintenance_flow(client: TestClient):
    status = client.get("/api/maintenance").json()
    assert status["total_prints"] == 0
    assert any(task["id"] == "clean_bed" for task in status["tasks"])

    completed = client.post("/api/maintenance/clean_bed/complete", json={"note": "تم"}).json()
    assert completed["last_done_at"] is not None
    assert client.get("/api/maintenance/log").json()[0]["note"] == "تم"

    assert client.delete("/api/maintenance/clean_bed").status_code == 400


def test_queue_flow(client: TestClient):
    job = client.post(
        "/api/queue", json={"gcode_path": "a.gcode", "display_name": "A", "estimated_seconds": 600}
    ).json()

    state = client.get("/api/queue").json()
    assert state["blocked_reason_key"] == "queue.blocked.bed_not_clear"
    assert client.post("/api/queue/start-next").status_code == 409

    client.post("/api/queue/bed-clear", json={"clear": True})
    state = client.get("/api/queue").json()
    assert state["next_job"]["id"] == job["id"]

    started = client.post("/api/queue/start-next")
    assert started.status_code == 200
    assert started.json()["job"]["status"] == "printing"


# --------------------------------------------------------------------------- #
# Support
# --------------------------------------------------------------------------- #


def test_diagnostics_report(client: TestClient):
    body = client.get("/api/diagnostics").json()
    assert body["overall"] in {"ok", "warning", "error"}
    ids = {check["id"] for check in body["checks"]}
    assert {"raspberry_pi", "storage", "moonraker", "klipper", "camera", "slicer", "vision"} <= ids
    assert body["summary_ar"]


def test_diagnostics_text_report_has_no_secrets(client: TestClient):
    text = client.get("/api/diagnostics/report").json()["report"]
    assert "Neptune 3 Plus Remote" in text
    assert "token" not in text.lower() or "No credentials" in text


def test_error_translation_endpoint(client: TestClient):
    body = client.post(
        "/api/support/translate-error", json={"message": "Heater extruder not heating at expected rate"}
    ).json()
    assert body["matched"] is True
    assert body["severity"] == "critical"
    assert body["original"]


def test_troubleshooting_endpoints(client: TestClient):
    all_topics = client.get("/api/support/topics").json()
    assert any(item["id"] == "adhesion" for item in all_topics)

    detail = client.get("/api/support/topics/adhesion").json()
    assert detail["first_step"]
    assert client.get("/api/support/topics/nope").status_code == 404


def test_bed_mesh_endpoint(client: TestClient):
    body = client.get("/api/printer/bed-mesh").json()
    assert body["available"] is True
    assert body["range"] == pytest.approx(0.06, abs=0.001)
    assert body["verdict"] == "excellent"


def test_backups_endpoint(client: TestClient):
    created = client.post("/api/backups", json={"include_profiles": False}).json()
    assert created["filename"].endswith(".zip")
    assert len(client.get("/api/backups").json()) == 1

    download = client.get(f"/api/backups/{created['filename']}/download")
    assert download.status_code == 200
    assert download.content[:2] == b"PK"

    assert client.delete(f"/api/backups/{created['filename']}").status_code == 200


def test_storage_endpoint(client: TestClient):
    body = client.get("/api/storage").json()
    assert "usage_bytes" in body
    assert body["root"]


# --------------------------------------------------------------------------- #
# WebSocket
# --------------------------------------------------------------------------- #


def test_websocket_sends_a_summary_snapshot(client: TestClient):
    with client.websocket_connect("/ws") as websocket:
        hello = websocket.receive_json()
        assert hello["type"] == "hello"
        assert "vision_provider" in hello["payload"]

        summary = websocket.receive_json()
        assert summary["type"] == "summary"
        assert "camera" in summary["payload"]
        assert "vision" in summary["payload"]

        printer = websocket.receive_json()
        assert printer["type"] == "printer"
        assert "item" in printer["payload"]
