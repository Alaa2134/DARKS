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


# --------------------------------------------------------------------------- #
# Toolpath preview
# --------------------------------------------------------------------------- #

SLICED = """\
; generated by PrusaSlicer
G90
;LAYER_CHANGE
;Z:0.2
;TYPE:External perimeter
G1 X10 Y10 F9000
G1 X40 Y10 E1.0
G1 X40 Y30 E1.0
;TYPE:Internal infill
G1 X12 Y12 F9000
G1 X14 Y14 E0.3
G1 X38 Y28 E0.3
;LAYER_CHANGE
;Z:0.4
;TYPE:Support material
G1 X20 Y20 E0.5
G1 X25 Y25 E0.5
"""


def put_gcode(client: TestClient, name: str, text: str) -> str:
    """Write a file into the Pi's own gcode directory, as slicing would."""
    services = client.app.state.services
    path = services.gcodes.path_for(name)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return path.name


def test_the_preview_summary_reports_layers_and_extent(client: TestClient):
    name = put_gcode(client, "part.gcode", SLICED)

    body = client.get(f"/api/gcodes/local/{name}/preview").json()

    assert body["layer_count"] == 2
    assert body["layer_heights"] == [pytest.approx(0.2), pytest.approx(0.4)]
    # The extent is the part, measured from extruding moves - not the bed.
    assert body["bounds"]["max_x"] == pytest.approx(40.0)
    assert body["bounds"]["max_y"] == pytest.approx(30.0)


def test_a_layer_comes_back_split_by_feature(client: TestClient):
    name = put_gcode(client, "part.gcode", SLICED)

    body = client.get(f"/api/gcodes/local/{name}/preview/0").json()
    features = {segment["feature"] for segment in body["segments"]}

    assert features == {"outer_wall", "infill"}
    assert body["z"] == pytest.approx(0.2)


def test_travel_is_left_out_unless_it_is_asked_for(client: TestClient):
    name = put_gcode(client, "part.gcode", SLICED)

    without = client.get(f"/api/gcodes/local/{name}/preview/0").json()
    with_travel = client.get(
        f"/api/gcodes/local/{name}/preview/0", params={"travel": "true"}
    ).json()

    assert all(s["feature"] != "travel" for s in without["segments"])
    assert any(s["feature"] == "travel" for s in with_travel["segments"])


def test_asking_for_a_layer_past_the_end_is_refused(client: TestClient):
    name = put_gcode(client, "part.gcode", SLICED)

    assert client.get(f"/api/gcodes/local/{name}/preview/99").status_code == 422


def test_previewing_a_file_that_is_not_on_the_pi_is_a_404(client: TestClient):
    response = client.get("/api/gcodes/local/missing.gcode/preview")

    assert response.status_code == 404
    assert "الباي" in response.json()["detail"]


def test_a_file_with_no_layer_markers_explains_itself(client: TestClient):
    name = put_gcode(client, "flat.gcode", "G90\nG1 X10 Y10 E1\n")

    response = client.get(f"/api/gcodes/local/{name}/preview")

    assert response.status_code == 422
    assert "طبقات" in response.json()["detail"]


def test_the_second_open_is_served_from_the_cache(client: TestClient):
    name = put_gcode(client, "part.gcode", SLICED)
    services = client.app.state.services

    client.get(f"/api/gcodes/local/{name}/preview")
    cache_dir = Path(services.gcodes.directory) / ".preview-cache"

    assert any(cache_dir.glob("*.preview.json"))
    # And it still answers correctly from the cached index.
    assert client.get(f"/api/gcodes/local/{name}/preview").json()["layer_count"] == 2


# --------------------------------------------------------------------------- #
# Mesh health and repair
# --------------------------------------------------------------------------- #


def flipped_slab_stl(width: float, depth: float, height: float) -> bytes:
    """A closed box with one face turned inside out."""
    data = bytearray(slab_stl(width, depth, height))
    # Records are 50 bytes after the 84-byte header; swap two vertices of the
    # fourth triangle to reverse its winding.
    base = 84 + 3 * 50 + 12
    first = bytes(data[base:base + 12])
    second = bytes(data[base + 12:base + 24])
    data[base:base + 12] = second
    data[base + 12:base + 24] = first
    return bytes(data)


def test_a_sound_model_reports_clean(client: TestClient):
    item = upload(client, slab_stl(10, 20, 40))

    body = client.get(f"/api/library/{item}/health").json()

    assert body["clean"] is True
    assert body["watertight"] is True
    assert body["open_edges"] == 0
    assert body["repairable"] is False
    assert any("سليم" in line for line in body["summary_ar"])


def test_a_flipped_face_is_reported_and_marked_repairable(client: TestClient):
    item = upload(client, flipped_slab_stl(10, 20, 40))

    body = client.get(f"/api/library/{item}/health").json()

    assert body["clean"] is False
    assert body["flipped"] > 0
    assert body["repairable"] is True


def test_repairing_makes_a_new_model_and_keeps_the_original(client: TestClient):
    item = upload(client, flipped_slab_stl(10, 20, 40))

    body = client.post(f"/api/library/{item}/repair").json()

    assert body["reoriented"] is True
    assert body["after"]["flipped"] == 0
    assert body["repaired_model_id"]
    # A repair changes geometry, so the original has to survive it.
    assert client.get(f"/api/library/{item}").status_code == 200
    assert client.get(f"/api/library/{body['repaired_model_id']}").status_code == 200


def test_repairing_a_sound_model_changes_nothing_and_makes_no_copy(client: TestClient):
    item = upload(client, slab_stl(10, 20, 40))

    body = client.post(f"/api/library/{item}/repair").json()

    assert body["repaired_model_id"] == ""
    assert body["removed_triangles"] == 0
    assert body["reoriented"] is False


def test_health_for_a_model_that_does_not_exist_is_a_404(client: TestClient):
    assert client.get("/api/library/nope/health").status_code == 404
    assert client.post("/api/library/nope/repair").status_code == 404


# --------------------------------------------------------------------------- #
# Library backup
# --------------------------------------------------------------------------- #


def test_a_backup_can_be_made_and_lists_afterwards(client: TestClient):
    upload(client, slab_stl(10, 20, 40))

    made = client.post("/api/library/backups").json()

    assert made["ok"] is True
    assert made["filename"].endswith(".tar.gz")
    assert made["size"] > 0
    assert made["manifest"]["model_count"] >= 1

    listed = client.get("/api/library/backups").json()
    assert any(entry["filename"] == made["filename"] for entry in listed)


def test_a_backup_can_be_downloaded(client: TestClient):
    upload(client, slab_stl(10, 20, 40))
    made = client.post("/api/library/backups").json()

    response = client.get(f"/api/library/backups/{made['filename']}/download")

    assert response.status_code == 200
    assert len(response.content) == made["size"]


def test_restoring_over_a_working_library_reports_what_it_did(client: TestClient):
    upload(client, slab_stl(10, 20, 40))
    made = client.post("/api/library/backups").json()

    body = client.post(
        "/api/library/backups/restore",
        json={"filename": made["filename"], "keep_existing": True},
    ).json()

    assert body["ok"] is True
    # Everything in the archive is already on disk, so nothing was restored -
    # and the report has to say that rather than going quiet.
    assert body["models_restored"] == 0
    assert body["notes_ar"]


def test_old_backups_are_pruned(client: TestClient):
    upload(client, slab_stl(10, 20, 40))
    for _ in range(3):
        client.post("/api/library/backups", params={"keep": 50})

    result = client.post("/api/library/backups", params={"keep": 2}).json()

    assert result["pruned"] >= 1
    assert len(client.get("/api/library/backups").json()) == 2


def test_a_backup_can_be_deleted(client: TestClient):
    upload(client, slab_stl(10, 20, 40))
    made = client.post("/api/library/backups").json()

    assert client.delete(f"/api/library/backups/{made['filename']}").status_code == 200
    assert client.get("/api/library/backups").json() == []


def test_restoring_something_that_is_not_there_is_a_404(client: TestClient):
    response = client.post(
        "/api/library/backups/restore", json={"filename": "nope.tar.gz"}
    )
    assert response.status_code == 404


def test_a_backup_filename_cannot_escape_the_backup_directory(client: TestClient):
    # The filename comes from the client, so it must never be able to name a
    # path outside the folder it is supposed to address.
    response = client.get("/api/library/backups/..%2F..%2Fetc%2Fpasswd/download")
    assert response.status_code in (404, 422)
