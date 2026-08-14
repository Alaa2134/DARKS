"""The orientation endpoints, end to end through the real router."""

from __future__ import annotations

import struct
from pathlib import Path

import httpx
import pytest
from fastapi.testclient import TestClient

from app.config import AppConfig
from app.main import create_app

PROFILES = Path(__file__).resolve().parent.parent / "profiles"

SERVER_INFO = {"klippy_connected": True, "klippy_state": "ready"}

#: A printer.cfg with a real build volume, so the endpoints are tested against
#: a machine's own limits rather than the fallback.
PRINTER_CFG = """
[stepper_x]
position_min: -5
position_max: 250

[stepper_y]
position_min: 0
position_max: 320

[stepper_z]
position_min: 0
position_max: 400
"""


def moonraker_handler(request: httpx.Request) -> httpx.Response:
    path = request.url.path
    if path == "/server/info":
        return httpx.Response(200, json={"result": SERVER_INFO})
    if path == "/server/files/printer.cfg" or path.endswith("/printer.cfg"):
        return httpx.Response(200, text=PRINTER_CFG)
    if path == "/printer/objects/query":
        return httpx.Response(200, json={"result": {"status": {}}})
    if path == "/server/files/list":
        return httpx.Response(200, json={"result": []})
    if path.startswith(("/printer/", "/machine/", "/server/")):
        return httpx.Response(200, json={"result": "ok"})
    return httpx.Response(404, json={"error": {"message": "not found"}})


def slab_stl(width: float, depth: float, height: float) -> bytes:
    """A closed box as binary STL, with correct outward normals.

    Deliberately not a cube: auto-orientation has to have a largest face to
    find, and a cube has six equal ones.
    """
    x, y, z = width, depth, height
    c = {
        "a": (0, 0, 0), "b": (x, 0, 0), "c": (x, y, 0), "d": (0, y, 0),
        "e": (0, 0, z), "f": (x, 0, z), "g": (x, y, z), "h": (0, y, z),
    }
    faces = [
        ("a", "c", "b"), ("a", "d", "c"),      # bottom
        ("e", "f", "g"), ("e", "g", "h"),      # top
        ("a", "b", "f"), ("a", "f", "e"),
        ("b", "c", "g"), ("b", "g", "f"),
        ("c", "d", "h"), ("c", "h", "g"),
        ("d", "a", "e"), ("d", "e", "h"),
    ]
    data = bytearray(b"\0" * 80) + struct.pack("<I", len(faces))
    for names in faces:
        data += struct.pack("<3f", 0.0, 0.0, 0.0)          # normal, recomputed on read
        for name in names:
            data += struct.pack("<3f", *c[name])
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

    app = create_app(config)
    with TestClient(app) as test_client:
        services = app.state.services
        services.moonraker._client = httpx.AsyncClient(
            transport=httpx.MockTransport(moonraker_handler), base_url="http://moonraker"
        )
        yield test_client


def upload(client: TestClient, data: bytes, name: str = "slab.stl") -> str:
    response = client.post(
        "/api/library/upload",
        files={"file": (name, data, "application/octet-stream")},
        data={"name_ar": "قطعة اختبار", "category": "other"},
    )
    assert response.status_code == 200, response.text
    return response.json()["id"]


# --------------------------------------------------------------------------- #
# Measuring a transform
# --------------------------------------------------------------------------- #


def test_measuring_the_identity_reports_the_models_own_size(client: TestClient):
    item = upload(client, slab_stl(10, 20, 40))

    body = client.post(f"/api/library/{item}/transform", json={}).json()

    assert body["width"] == pytest.approx(10.0, abs=1e-3)
    assert body["depth"] == pytest.approx(20.0, abs=1e-3)
    assert body["height"] == pytest.approx(40.0, abs=1e-3)
    assert body["fits"] is True
    assert body["problems_ar"] == []


def test_measuring_a_rotation_reports_the_new_size(client: TestClient):
    item = upload(client, slab_stl(10, 20, 40))

    body = client.post(
        f"/api/library/{item}/transform",
        json={"rotation_deg": [90, 0, 0]},
    ).json()

    # Rotating about X swaps depth and height.
    assert body["depth"] == pytest.approx(40.0, abs=1e-3)
    assert body["height"] == pytest.approx(20.0, abs=1e-3)


def test_a_scale_that_overflows_the_bed_names_each_axis(client: TestClient):
    item = upload(client, slab_stl(10, 20, 40))

    body = client.post(
        f"/api/library/{item}/transform",
        json={"scale": [40, 40, 40]},
    ).json()

    assert body["fits"] is False
    # 400 x 800 x 1600 against a 320 x 320 x 400 machine: all three are over.
    assert len(body["problems_ar"]) == 3


def test_the_build_volume_comes_from_the_printers_own_config(client: TestClient):
    """X is 250 here, not the 320 the fallback would assume.

    Deliberately different from the Neptune's own figure, so this fails if the
    endpoint ever quietly falls back instead of reading the machine. And
    position_min is -5, which is homing overtravel rather than printable space,
    so the usable width is 250 and not 255.
    """
    item = upload(client, slab_stl(10, 10, 10))

    fits = client.post(
        f"/api/library/{item}/transform", json={"scale": [25.0, 1, 1]}
    ).json()
    over = client.post(
        f"/api/library/{item}/transform", json={"scale": [25.5, 1, 1]}
    ).json()

    assert fits["fits"] is True, "250 mm has to fit a 250 mm axis"
    assert over["fits"] is False, "255 mm must not fit - that would be reading position_min as usable"
    assert any("العرض" in problem for problem in over["problems_ar"])


def test_a_zero_scale_is_refused_with_a_reason(client: TestClient):
    item = upload(client, slab_stl(10, 20, 40))

    response = client.post(
        f"/api/library/{item}/transform", json={"scale": [0, 1, 1]}
    )

    assert response.status_code == 422


def test_a_transform_with_the_wrong_number_of_axes_is_refused(client: TestClient):
    item = upload(client, slab_stl(10, 20, 40))

    response = client.post(
        f"/api/library/{item}/transform", json={"rotation_deg": [90, 0]}
    )

    assert response.status_code == 422


def test_measuring_a_model_that_does_not_exist_is_a_404(client: TestClient):
    response = client.post("/api/library/nope/transform", json={})
    assert response.status_code == 404


# --------------------------------------------------------------------------- #
# Suggesting an orientation
# --------------------------------------------------------------------------- #


def test_a_slab_lying_down_is_advised_to_stay_down(client: TestClient):
    # 40 x 30 x 4: it is already resting on its largest face, and the best
    # advice is to leave it alone. An auto-orient that always turns something
    # is worse than useless.
    item = upload(client, slab_stl(40, 30, 4))

    body = client.post(f"/api/library/{item}/orient", json={}).json()

    assert body["suggested"]["height"] == pytest.approx(4.0, abs=1e-3)
    assert body["current"]["height"] == pytest.approx(4.0, abs=1e-3)


def test_a_tall_model_is_advised_to_lie_down(client: TestClient):
    # 10 x 20 x 40 standing on its smallest face. The largest face is 20 x 40,
    # so the advice should be to put that on the bed and stand 10 mm tall.
    item = upload(client, slab_stl(10, 20, 40))

    body = client.post(f"/api/library/{item}/orient", json={}).json()

    assert body["current"]["height"] == pytest.approx(40.0, abs=1e-3)
    assert body["suggested"]["height"] == pytest.approx(10.0, abs=1e-3)
    assert body["suggested"]["base_area"] > body["current"]["base_area"]


def test_the_suggestion_comes_back_as_a_transform_the_app_can_apply(client: TestClient):
    item = upload(client, slab_stl(10, 20, 40))

    body = client.post(f"/api/library/{item}/orient", json={}).json()
    suggestion = body["transform"]

    # Feeding the suggestion straight back into the measure endpoint has to
    # reproduce the numbers it was reported with, or the advice is not
    # actionable.
    measured = client.post(f"/api/library/{item}/transform", json=suggestion).json()
    assert measured["height"] == pytest.approx(body["suggested"]["height"], abs=1e-3)
    assert measured["base_area"] == pytest.approx(body["suggested"]["base_area"], rel=1e-3)


def test_a_suggestion_composes_with_a_scale_the_user_already_set(client: TestClient):
    item = upload(client, slab_stl(10, 20, 40))

    body = client.post(
        f"/api/library/{item}/orient",
        json={"scale": [2, 2, 2]},
    ).json()

    # The scale must survive: an orientation suggestion that silently discarded
    # the user's resize would undo work they had already done.
    assert body["transform"]["scale"] == [2.0, 2.0, 2.0]
    assert body["current"]["height"] == pytest.approx(80.0, abs=1e-3)


def test_orienting_a_model_that_does_not_exist_is_a_404(client: TestClient):
    response = client.post("/api/library/nope/orient", json={})
    assert response.status_code == 404


def test_a_model_too_big_for_the_machine_any_way_up_says_so(client: TestClient):
    # 500 mm in every direction: there is no orientation under a 400 mm Z.
    item = upload(client, slab_stl(500, 500, 500))

    response = client.post(f"/api/library/{item}/orient", json={})

    assert response.status_code == 422
    assert "الارتفاع" in response.json()["detail"] or "صغّر" in response.json()["detail"]
