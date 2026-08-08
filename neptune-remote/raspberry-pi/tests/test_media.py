"""Camera, recording, timelapse and video-storage behaviour.

These tests never require a real camera or FFmpeg: the failure paths are the
interesting ones, and they are exactly what must not fake success.
"""

from __future__ import annotations

import asyncio
import io
from pathlib import Path

import httpx
import pytest

from app.camera.devices import CameraDevice, CameraMode, _parse_modes
from app.camera.service import CameraService
from app.config import CameraConfig, RecordingConfig, TimelapseConfig
from app.db import Database
from app.paths import StorageLayout
from app.recording.service import RecordingError, RecordingService
from app.recording.store import VideoStore
from app.timelapse.service import TimelapseService

V4L2_OUTPUT = """ioctl: VIDIOC_ENUM_FMT
	Type: Video Capture

	[0]: 'MJPG' (Motion-JPEG, compressed)
		Size: Discrete 1280x720
			Interval: Discrete 0.033s (30.000 fps)
			Interval: Discrete 0.067s (15.000 fps)
		Size: Discrete 640x480
			Interval: Discrete 0.033s (30.000 fps)
	[1]: 'YUYV' (YUYV 4:2:2)
		Size: Discrete 1920x1080
			Interval: Discrete 0.200s (5.000 fps)
"""


def jpeg_bytes(colour=(20, 90, 200), size=(64, 48)) -> bytes:
    from PIL import Image

    buffer = io.BytesIO()
    Image.new("RGB", size, colour).save(buffer, format="JPEG")
    return buffer.getvalue()


@pytest.fixture()
def layout(tmp_path: Path) -> StorageLayout:
    return StorageLayout.create(tmp_path / "storage")


@pytest.fixture()
def database(layout: StorageLayout) -> Database:
    db = Database(layout.database / "test.db")
    yield db
    db.close()


# --------------------------------------------------------------------------- #
# Device discovery
# --------------------------------------------------------------------------- #


def test_v4l2_mode_parsing():
    modes = _parse_modes(V4L2_OUTPUT)
    assert CameraMode(1280, 720, 30.0, "MJPG") in modes
    assert any(mode.width == 1920 and mode.fps == 5.0 for mode in modes)
    assert modes[0].label == "1280x720 @ 30 fps"


def test_recommended_mode_prefers_720p15():
    device = CameraDevice(path="/dev/video0", modes=_parse_modes(V4L2_OUTPUT))
    recommended = device.recommended_mode()
    assert (recommended.width, recommended.height) == (1280, 720)
    assert recommended.fps == 15.0


def test_recommended_mode_without_modes_is_none():
    assert CameraDevice(path="/dev/video9").recommended_mode() is None


def test_device_index_parsing():
    assert CameraDevice(path="/dev/video2").index == 2


# --------------------------------------------------------------------------- #
# Camera service
# --------------------------------------------------------------------------- #


def test_status_when_no_camera_is_configured(layout: StorageLayout):
    service = CameraService(CameraConfig(stream_url="", snapshot_url="", device=""), layout)
    status = service.status(probe_devices=False)
    assert status.available is False
    assert status.source == "none"
    assert status.message_key in {"camera.status.no_camera", "camera.status.detected_not_configured"}


def test_status_when_disabled(layout: StorageLayout):
    service = CameraService(CameraConfig(enabled=False, stream_url="http://x/stream"), layout)
    status = service.status(probe_devices=False)
    assert status.available is False
    assert status.message_key == "camera.status.disabled"


def test_status_with_a_stream_url(layout: StorageLayout):
    service = CameraService(CameraConfig(snapshot_url="http://pi/webcam/?action=snapshot"), layout)
    status = service.status(probe_devices=False)
    assert status.available is True
    assert status.source == "stream"


@pytest.mark.asyncio
async def test_snapshot_from_url(layout: StorageLayout):
    payload = jpeg_bytes()

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, content=payload, headers={"content-type": "image/jpeg"})

    service = CameraService(CameraConfig(snapshot_url="http://pi/snapshot"), layout)
    service._client = httpx.AsyncClient(transport=httpx.MockTransport(handler))

    data = await service.snapshot()
    assert data == payload
    await service.aclose()


@pytest.mark.asyncio
async def test_snapshot_rejects_non_jpeg(layout: StorageLayout):
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, content=b"<html>not an image</html>")

    service = CameraService(CameraConfig(snapshot_url="http://pi/snapshot"), layout)
    service._client = httpx.AsyncClient(transport=httpx.MockTransport(handler))

    assert await service.snapshot() is None
    assert "JPEG" in service.last_error
    await service.aclose()


@pytest.mark.asyncio
async def test_snapshot_reports_http_errors(layout: StorageLayout):
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(503, content=b"")

    service = CameraService(CameraConfig(snapshot_url="http://pi/snapshot"), layout)
    service._client = httpx.AsyncClient(transport=httpx.MockTransport(handler))

    assert await service.snapshot() is None
    assert "503" in service.last_error
    await service.aclose()


@pytest.mark.asyncio
async def test_snapshot_when_camera_unplugged(layout: StorageLayout):
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("connection refused")

    service = CameraService(CameraConfig(snapshot_url="http://pi/snapshot"), layout)
    service._client = httpx.AsyncClient(transport=httpx.MockTransport(handler))

    assert await service.snapshot() is None
    assert service.last_error
    await service.aclose()


@pytest.mark.asyncio
async def test_save_snapshot_returns_none_on_failure(layout: StorageLayout):
    service = CameraService(CameraConfig(), layout)
    assert await service.save_snapshot() is None


def test_ffmpeg_input_args_prefers_the_stream(layout: StorageLayout):
    service = CameraService(
        CameraConfig(stream_url="http://pi/stream", device="/dev/video0"), layout
    )
    args = service.ffmpeg_input_args()
    assert "-i" in args and "http://pi/stream" in args


def test_ffmpeg_input_args_for_a_device(layout: StorageLayout):
    service = CameraService(CameraConfig(device="/dev/video0", width=800, height=600), layout)
    args = service.ffmpeg_input_args()
    assert "v4l2" in args
    assert "800x600" in args


def test_ffmpeg_input_args_none_without_a_source(layout: StorageLayout):
    assert CameraService(CameraConfig(), layout).ffmpeg_input_args() is None


# --------------------------------------------------------------------------- #
# Video store
# --------------------------------------------------------------------------- #


def test_video_record_lifecycle(database: Database, layout: StorageLayout):
    store = VideoStore(database, layout)
    path = layout.dated_video_dir() / "test.mp4"
    path.write_bytes(b"0" * 4096)

    record = store.create(kind="recording", path=path, gcode_name="benchy.gcode")
    assert record.result == "in_progress"

    finished = store.finish(record.id, result="completed")
    assert finished.result == "completed"
    assert finished.size_bytes == 4096
    assert finished.duration is not None


def test_in_progress_video_cannot_be_deleted(database: Database, layout: StorageLayout):
    store = VideoStore(database, layout)
    path = layout.dated_video_dir() / "live.mp4"
    path.write_bytes(b"0")
    record = store.create(kind="recording", path=path)
    assert store.delete(record.id) is False
    assert path.exists()


def test_delete_removes_the_file(database: Database, layout: StorageLayout):
    store = VideoStore(database, layout)
    path = layout.dated_video_dir() / "old.mp4"
    path.write_bytes(b"0" * 100)
    record = store.create(kind="recording", path=path)
    store.finish(record.id, result="completed")

    assert store.delete(record.id) is True
    assert not path.exists()


def test_retention_keep_last(database: Database, layout: StorageLayout):
    store = VideoStore(database, layout)
    for index in range(5):
        path = layout.dated_video_dir() / f"v{index}.mp4"
        path.write_bytes(b"0" * 1000)
        record = store.create(kind="recording", path=path, started_at=1000.0 + index)
        store.finish(record.id, result="completed")

    removed = store.apply_retention(policy="keep_last", max_gigabytes=0, keep_last=2)
    assert len(removed) == 3
    assert len(store.list()) == 2


def test_retention_max_size(database: Database, layout: StorageLayout):
    store = VideoStore(database, layout)
    one_mb = 1024 * 1024
    for index in range(4):
        path = layout.dated_video_dir() / f"big{index}.mp4"
        path.write_bytes(b"0" * one_mb)
        record = store.create(kind="recording", path=path, started_at=1000.0 + index)
        store.finish(record.id, result="completed")

    # 2 MB budget over 4 MB of video: the two oldest must go.
    removed = store.apply_retention(
        policy="max_size", max_gigabytes=2 / 1024, keep_last=0
    )
    assert len(removed) == 2
    assert len(store.list()) == 2


def test_retention_never_touches_the_active_recording(database: Database, layout: StorageLayout):
    store = VideoStore(database, layout)
    for index in range(3):
        path = layout.dated_video_dir() / f"r{index}.mp4"
        path.write_bytes(b"0" * 1000)
        record = store.create(kind="recording", path=path, started_at=1000.0 + index)
        store.finish(record.id, result="completed")

    active_path = layout.dated_video_dir() / "active.mp4"
    active_path.write_bytes(b"0" * 1000)
    active = store.create(kind="recording", path=active_path, started_at=2000.0)

    store.apply_retention(policy="keep_last", max_gigabytes=0, keep_last=1, active_ids=[active.id])
    assert store.get(active.id) is not None
    assert active_path.exists()


def test_storage_summary(database: Database, layout: StorageLayout):
    store = VideoStore(database, layout)
    path = layout.dated_video_dir() / "x.mp4"
    path.write_bytes(b"0" * 2048)
    record = store.create(kind="recording", path=path)
    store.finish(record.id, result="completed")

    summary = store.storage_summary()
    assert summary["videos_bytes"] >= 2048
    assert summary["by_kind"]["recording"]["count"] == 1


# --------------------------------------------------------------------------- #
# Recording service
# --------------------------------------------------------------------------- #


@pytest.mark.asyncio
async def test_recording_refuses_without_ffmpeg(database: Database, layout: StorageLayout):
    camera = CameraService(CameraConfig(stream_url="http://pi/stream",
                                        ffmpeg_binary="definitely-not-ffmpeg"), layout)
    service = RecordingService(RecordingConfig(), camera, VideoStore(database, layout), layout)

    with pytest.raises(RecordingError) as excinfo:
        await service.start()
    assert "ffmpeg" in str(excinfo.value).lower()
    assert service.is_recording is False


@pytest.mark.asyncio
async def test_recording_refuses_without_a_camera(database: Database, layout: StorageLayout):
    camera = CameraService(CameraConfig(stream_url="", device=""), layout)
    service = RecordingService(RecordingConfig(), camera, VideoStore(database, layout), layout)

    with pytest.raises(RecordingError):
        await service.start()


@pytest.mark.asyncio
async def test_recording_stop_without_start_returns_none(database: Database, layout: StorageLayout):
    camera = CameraService(CameraConfig(), layout)
    service = RecordingService(RecordingConfig(), camera, VideoStore(database, layout), layout)
    assert await service.stop() is None


def test_recording_status_is_honest(database: Database, layout: StorageLayout):
    camera = CameraService(CameraConfig(ffmpeg_binary="definitely-not-ffmpeg"), layout)
    service = RecordingService(RecordingConfig(mode="full"), camera, VideoStore(database, layout), layout)
    status = service.status()
    assert status["recording"] is False
    assert status["ffmpeg_available"] is False
    assert status["auto_mode"] == "full"


def test_should_record_print_modes(database: Database, layout: StorageLayout):
    camera = CameraService(CameraConfig(), layout)
    store = VideoStore(database, layout)
    assert RecordingService(RecordingConfig(mode="off"), camera, store, layout).should_record_print() is False
    assert RecordingService(RecordingConfig(mode="manual"), camera, store, layout).should_record_print() is False
    assert RecordingService(RecordingConfig(mode="full"), camera, store, layout).should_record_print() is True


@pytest.mark.asyncio
async def test_automatic_recording_failure_is_swallowed(database: Database, layout: StorageLayout):
    """A camera problem must never stop a print from starting."""
    camera = CameraService(CameraConfig(ffmpeg_binary="nope"), layout)
    service = RecordingService(RecordingConfig(mode="full"), camera, VideoStore(database, layout), layout)
    await service.handle_print_started("benchy.gcode", None)  # must not raise
    assert service.is_recording is False


# --------------------------------------------------------------------------- #
# Timelapse
# --------------------------------------------------------------------------- #


@pytest.mark.asyncio
async def test_timelapse_off_does_not_start(database: Database, layout: StorageLayout):
    camera = CameraService(CameraConfig(), layout)
    service = TimelapseService(TimelapseConfig(mode="off"), camera, VideoStore(database, layout), layout)
    assert await service.start() is False
    assert service.is_running is False


@pytest.mark.asyncio
async def test_timelapse_layer_mode_captures_on_demand(database: Database, layout: StorageLayout):
    payload = jpeg_bytes()

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, content=payload, headers={"content-type": "image/jpeg"})

    camera = CameraService(CameraConfig(snapshot_url="http://pi/snapshot"), layout)
    camera._client = httpx.AsyncClient(transport=httpx.MockTransport(handler))

    service = TimelapseService(
        TimelapseConfig(mode="layer", min_frames=2), camera, VideoStore(database, layout), layout
    )
    assert await service.start(gcode_name="benchy.gcode") is True

    assert await service.capture_frame() is True
    assert await service.capture_frame() is True
    assert service.status()["frames"] == 2

    await camera.aclose()


@pytest.mark.asyncio
async def test_timelapse_discards_too_few_frames(database: Database, layout: StorageLayout):
    camera = CameraService(CameraConfig(), layout)
    service = TimelapseService(
        TimelapseConfig(mode="layer", min_frames=10), camera, VideoStore(database, layout), layout
    )
    await service.start()
    record = await service.finish()
    assert record is None
    assert "frame" in service.last_error


@pytest.mark.asyncio
async def test_timelapse_frame_without_a_session(database: Database, layout: StorageLayout):
    camera = CameraService(CameraConfig(), layout)
    service = TimelapseService(TimelapseConfig(mode="layer"), camera, VideoStore(database, layout), layout)
    assert await service.capture_frame() is False


def test_timelapse_macro_is_advisory_only(database: Database, layout: StorageLayout):
    camera = CameraService(CameraConfig(), layout)
    service = TimelapseService(TimelapseConfig(), camera, VideoStore(database, layout), layout)
    macro = service.suggested_macro(port=8710, token="abc")
    assert "TIMELAPSE_TAKE_FRAME" in macro
    assert "8710" in macro
    assert "token=abc" in macro
    assert "never edits printer.cfg" in macro.lower()
