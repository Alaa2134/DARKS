"""Pasting a link into the app, end to end through the real router."""

from __future__ import annotations

import io
import struct
import zipfile
from pathlib import Path

import httpx
import pytest
from fastapi.testclient import TestClient

from app.config import AppConfig
from app.library.importer import Download
from app.main import create_app

PROFILES = Path(__file__).resolve().parent.parent / "profiles"


def moonraker_handler(request: httpx.Request) -> httpx.Response:
    if request.url.path == "/server/info":
        return httpx.Response(200, json={"result": {"klippy_connected": True, "klippy_state": "ready"}})
    return httpx.Response(200, json={"result": "ok"})


def cube_stl() -> bytes:
    """A closed box, so the library can measure and render it."""
    x = y = z = 10.0
    corner = {
        "a": (0, 0, 0), "b": (x, 0, 0), "c": (x, y, 0), "d": (0, y, 0),
        "e": (0, 0, z), "f": (x, 0, z), "g": (x, y, z), "h": (0, y, z),
    }
    faces = [
        ("a", "c", "b"), ("a", "d", "c"), ("e", "f", "g"), ("e", "g", "h"),
        ("a", "b", "f"), ("a", "f", "e"), ("b", "c", "g"), ("b", "g", "f"),
        ("c", "d", "h"), ("c", "h", "g"), ("d", "a", "e"), ("d", "e", "h"),
    ]
    data = bytearray(b"\0" * 80) + struct.pack("<I", len(faces))
    for names in faces:
        data += struct.pack("<3f", 0.0, 0.0, 0.0)
        for name in names:
            data += struct.pack("<3f", *corner[name])
        data += struct.pack("<H", 0)
    return bytes(data)


def zip_of(entries) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, payload in entries:
            archive.writestr(name, payload)
    return buffer.getvalue()


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
        test_client.app_config = config
        services = app.state.services
        services.moonraker._client = httpx.AsyncClient(
            transport=httpx.MockTransport(moonraker_handler), base_url="http://moonraker"
        )
        yield test_client


@pytest.fixture()
def served(monkeypatch):
    """Serve a fixed download instead of going out to the internet.

    Only `fetch` is replaced: everything the endpoint decides - whether the URL
    may be fetched at all, what the archive contains, what becomes an item - is
    still the real code.
    """

    def serve(data: bytes, filename: str):
        async def fake_fetch(url, **kwargs):
            return Download(data=data, filename=filename)

        monkeypatch.setattr("app.library.importer.fetch", fake_fetch)

    return serve


def import_url(client: TestClient, url: str, **body):
    return client.post("/api/library/import", json={"url": url, **body})


# --------------------------------------------------------------------------- #
# One file
# --------------------------------------------------------------------------- #


def test_a_direct_link_becomes_one_library_item(client: TestClient, served):
    served(cube_stl(), "bracket.stl")

    response = import_url(client, "https://example.com/models/bracket.stl")

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["ok"]
    assert len(body["items"]) == 1
    assert body["collection_id"] == ""


def test_where_it_came_from_is_kept_on_the_item(client: TestClient, served):
    # A link is the only way back to the licence, and the only way to find the
    # model again a month later.
    served(cube_stl(), "bracket.stl")
    url = "https://example.com/models/bracket.stl"

    item_id = import_url(client, url).json()["items"][0]["id"]
    stored = client.get(f"/api/library/{item_id}").json()

    assert stored["source_url"] == url


def test_a_name_given_by_the_user_wins_for_a_single_file(client: TestClient, served):
    served(cube_stl(), "bracket.stl")

    body = import_url(
        client, "https://example.com/bracket.stl", name_ar="مسمار الرف"
    ).json()

    assert body["items"][0]["name_ar"] == "مسمار الرف"


def test_the_imported_model_is_measured_like_an_uploaded_one(client: TestClient, served):
    served(cube_stl(), "bracket.stl")

    item = import_url(client, "https://example.com/bracket.stl").json()["items"][0]

    assert item["dimensions_x"] == pytest.approx(10.0)
    assert item["model_size"] > 0


# --------------------------------------------------------------------------- #
# An archive
# --------------------------------------------------------------------------- #


def test_an_archive_of_parts_becomes_one_collection(client: TestClient, served):
    served(
        zip_of([
            ("kit/base.stl", cube_stl()),
            ("kit/lid.stl", cube_stl()),
            ("kit/pin.stl", cube_stl()),
        ]),
        "kit.zip",
    )

    body = import_url(client, "https://example.com/kit.zip").json()

    assert len(body["items"]) == 3
    assert body["collection_id"]
    assert body["collection_name"] == "kit"


def test_the_parts_are_findable_through_the_collection(client: TestClient, served):
    # A collection nothing is in is not a project.
    served(zip_of([("a.stl", cube_stl()), ("b.stl", cube_stl())]), "kit.zip")

    body = import_url(client, "https://example.com/kit.zip").json()
    listed = client.get(f"/api/library?collection={body['collection_id']}").json()

    assert len(listed) == 2


def test_a_file_the_slicer_cannot_read_is_skipped_and_said_so(client: TestClient, served):
    served(zip_of([("part.stl", cube_stl()), ("source.step", b"ISO-10303-21;")]), "kit.zip")

    body = import_url(client, "https://example.com/kit.zip").json()

    assert len(body["items"]) == 1
    assert any("مش مدعوم" in note for note in body["notes_ar"])


def test_an_archive_with_nothing_printable_is_refused_with_a_reason(
    client: TestClient, served
):
    served(zip_of([("model.step", b"ISO-10303-21;")]), "kit.zip")

    response = import_url(client, "https://example.com/kit.zip")

    assert response.status_code == 422
    assert ".stl" in response.json()["detail"]


def test_an_archive_of_documents_is_refused(client: TestClient, served):
    served(zip_of([("readme.txt", b"nothing here")]), "docs.zip")

    response = import_url(client, "https://example.com/docs.zip")

    assert response.status_code == 422


# --------------------------------------------------------------------------- #
# Links that cannot be imported
# --------------------------------------------------------------------------- #


def test_a_link_pointing_at_the_pi_itself_is_refused(client: TestClient):
    response = import_url(client, "http://127.0.0.1:7125/printer/emergency_stop")

    assert response.status_code == 422


def test_a_page_that_is_not_a_file_is_refused_with_advice(client: TestClient):
    response = import_url(client, "https://example.com/some/page")

    assert response.status_code == 422
    assert "STL" in response.json()["detail"]


def test_thingiverse_without_a_key_asks_for_one_rather_than_failing(client: TestClient):
    # 200 with `needs_key`: this is something the user can fix, and an error
    # screen does not say how.
    response = import_url(client, "https://www.thingiverse.com/thing:12345")

    assert response.status_code == 200
    body = response.json()
    assert body["ok"] is False
    assert body["needs_key"] == "thingiverse"
    assert body["items"] == []


def test_thingiverse_with_a_key_configured_downloads(client: TestClient, served):
    client.app_config.library.thingiverse_key = "secret"
    served(zip_of([("part.stl", cube_stl())]), "thing-12345.zip")

    body = import_url(client, "https://www.thingiverse.com/thing:12345").json()

    assert body["ok"]
    assert len(body["items"]) == 1
    # The page, not the download URL - which carries the key.
    assert "access_token" not in body["source_url"]


def test_printables_explains_what_to_do_instead(client: TestClient):
    response = import_url(client, "https://www.printables.com/model/12345-thing")

    assert response.status_code == 422
    assert "نزّل" in response.json()["detail"]
