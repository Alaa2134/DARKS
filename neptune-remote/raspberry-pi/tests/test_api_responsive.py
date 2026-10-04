"""The Pi answers while it works.

Every heavy thing the library does - reading a mesh, rendering a thumbnail,
scanning a G-code file, writing a backup - is CPU, and CPU on the event loop is
an API that answers nothing at all until it finishes. The app polls the printer
every few seconds and draws silence as the printer going away, so a user who
opened the plate screen would watch their printer "disconnect" because of their
own tap.

These tests do not measure speed. They check that something else can be served
*while* the slow thing runs, which is the only property that matters.
"""

from __future__ import annotations

import asyncio
import struct
import time
from pathlib import Path

import httpx
import pytest

from app.config import AppConfig
from app.main import create_app

PROFILES = Path(__file__).resolve().parent.parent / "profiles"

#: Long enough to be unmistakable, short enough that the suite does not crawl.
SLOW = 0.6

#: A stall longer than this means the loop stopped rather than handed the work
#: to a thread. Generous: CI machines are noisy, and the difference being
#: measured is a factor of ten, not a few percent.
PATIENCE = SLOW / 3


def cube_stl() -> bytes:
    corner = {
        "a": (0, 0, 0), "b": (10, 0, 0), "c": (10, 10, 0), "d": (0, 10, 0),
        "e": (0, 0, 10), "f": (10, 0, 10), "g": (10, 10, 10), "h": (0, 10, 10),
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


@pytest.fixture()
def app(tmp_path: Path):
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
    return create_app(config)


async def longest_stall(slow_request, client: httpx.AsyncClient) -> float:
    """The longest the event loop stopped running while a request was served.

    Measured with a ticker rather than with a second request, because a second
    request proves nothing here: it can be served in the gap before the slow
    handler reaches its blocking call, and then the test passes on exactly the
    code it exists to catch. A ticker cannot be fooled that way - if the loop
    stops, the gap between two ticks is the length of the stall.
    """
    gaps: list[float] = []
    running = True

    async def ticker() -> None:
        last = time.monotonic()
        while running:
            await asyncio.sleep(0.01)
            now = time.monotonic()
            gaps.append(now - last)
            last = now

    tick = asyncio.create_task(ticker())
    started = time.monotonic()
    response = await slow_request(client)
    duration = time.monotonic() - started
    running = False
    await tick

    assert response.status_code == 200, response.text
    # The work has to have actually been slow, or the measurement is of
    # nothing at all.
    assert duration >= SLOW, f"the slow path did not run ({duration:.2f}s)"
    return max(gaps) if gaps else 0.0


async def upload_raw(client: httpx.AsyncClient) -> httpx.Response:
    return await client.post(
        "/api/library/upload",
        files={"file": ("cube.stl", cube_stl(), "application/octet-stream")},
        data={"name_ar": "مكعب", "category": "other"},
        timeout=30,
    )


async def upload(client: httpx.AsyncClient) -> str:
    response = await upload_raw(client)
    assert response.status_code == 200, response.text
    return response.json()["id"]


@pytest.mark.asyncio
async def test_a_mesh_check_does_not_stop_the_pi_answering(app, monkeypatch):
    from app.library import repair

    real = repair.inspect_file

    def slow(path, *args, **kwargs):
        time.sleep(SLOW)
        return real(path, *args, **kwargs)

    monkeypatch.setattr(repair, "inspect_file", slow)

    async with app.router.lifespan_context(app):
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
            item = await upload(client)
            stall = await longest_stall(
                lambda c: c.get(f"/api/library/{item}/health", timeout=30), client
            )

    assert stall < PATIENCE, f"the event loop stopped for {stall:.2f}s"


@pytest.mark.asyncio
async def test_arranging_a_plate_does_not_stop_the_pi_answering(app, monkeypatch):
    # The worst of them: one mesh load per part, so a plate of eight parts is
    # eight times whatever one costs - and it happens while the user is
    # dragging things around on screen.
    from app.library import mesh

    real = mesh.load

    def slow(path, *args, **kwargs):
        time.sleep(SLOW)
        return real(path, *args, **kwargs)

    monkeypatch.setattr(mesh, "load", slow)

    async with app.router.lifespan_context(app):
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
            item = await upload(client)
            stall = await longest_stall(
                lambda c: c.post(
                    "/api/library/arrange", json={"model_ids": [item]}, timeout=30
                ),
                client,
            )

    assert stall < PATIENCE, f"the event loop stopped for {stall:.2f}s"


@pytest.mark.asyncio
async def test_writing_a_backup_does_not_stop_the_pi_answering(app, monkeypatch):
    # The longest of the lot - minutes on a real library - from a button whose
    # whole promise is that it is safe to press.
    from app.library import backup

    real = backup.create_archive

    def slow(*args, **kwargs):
        time.sleep(SLOW)
        return real(*args, **kwargs)

    monkeypatch.setattr(backup, "create_archive", slow)

    async with app.router.lifespan_context(app):
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
            stall = await longest_stall(
                lambda c: c.post("/api/library/backups", timeout=30), client
            )

    assert stall < PATIENCE, f"the event loop stopped for {stall:.2f}s"


@pytest.mark.asyncio
async def test_an_upload_does_not_stop_the_pi_answering(app, monkeypatch):
    # Measuring the mesh and rendering its thumbnail, on a file that can be
    # 200 MB.
    from app.library import store as library_store

    real = library_store.summarise

    def slow(path, *args, **kwargs):
        time.sleep(SLOW)
        return real(path, *args, **kwargs)

    monkeypatch.setattr(library_store, "summarise", slow)

    async with app.router.lifespan_context(app):
        transport = httpx.ASGITransport(app=app)
        async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
            stall = await longest_stall(upload_raw, client)

    assert stall < PATIENCE, f"the event loop stopped for {stall:.2f}s"
