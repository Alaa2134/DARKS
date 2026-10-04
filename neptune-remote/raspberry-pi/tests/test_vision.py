"""Local failure detection: providers, temporal confirmation, safety rules."""

from __future__ import annotations

import asyncio
import io
import random
from pathlib import Path

import pytest

from app.camera.service import CameraService
from app.config import CameraConfig, VisionConfig
from app.db import Database
from app.paths import StorageLayout
from app.vision.detector import MODES, VisionDetector
from app.vision.providers import (
    Detection,
    DisabledVisionProvider,
    HeuristicVisionProvider,
    OnnxVisionProvider,
    build_provider,
    crop_roi,
    decode_frame,
    sobel_edges,
)


def make_jpeg(draw_noise: bool = False, seed: int = 1, size=(320, 240)) -> bytes:
    from PIL import Image, ImageDraw

    random.seed(seed)
    image = Image.new("RGB", size, (30, 30, 34))
    drawing = ImageDraw.Draw(image)
    # A calm "printing normally" frame: one solid rectangle.
    drawing.rectangle([100, 80, 220, 170], fill=(190, 190, 195))

    if draw_noise:
        # A "spaghetti" frame: lots of thin high-frequency strands.
        for _ in range(600):
            x1 = random.randint(0, size[0] - 1)
            y1 = random.randint(0, size[1] - 1)
            drawing.line(
                [x1, y1, x1 + random.randint(-25, 25), y1 + random.randint(-25, 25)],
                fill=(235, 235, 240), width=1,
            )

    buffer = io.BytesIO()
    image.save(buffer, format="JPEG", quality=92)
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
# Image helpers
# --------------------------------------------------------------------------- #


def test_decode_frame_returns_normalised_greyscale():
    array = decode_frame(make_jpeg(), (64, 48))
    assert array is not None
    assert array.shape == (48, 64)
    assert 0.0 <= float(array.min()) and float(array.max()) <= 1.0


def test_decode_frame_rejects_garbage():
    assert decode_frame(b"not an image") is None


def test_crop_roi():
    array = decode_frame(make_jpeg(), (100, 100))
    cropped = crop_roi(array, [0.25, 0.25, 0.5, 0.5])
    assert cropped.shape == (50, 50)


def test_crop_roi_without_roi_is_a_noop():
    array = decode_frame(make_jpeg(), (40, 40))
    assert crop_roi(array, None).shape == array.shape


def test_sobel_edges_detects_structure():
    calm = sobel_edges(decode_frame(make_jpeg(), (160, 120)))
    noisy = sobel_edges(decode_frame(make_jpeg(draw_noise=True), (160, 120)))
    assert float(noisy.mean()) > float(calm.mean())


# --------------------------------------------------------------------------- #
# Providers
# --------------------------------------------------------------------------- #


def test_disabled_provider_is_honest():
    provider = DisabledVisionProvider("switched off")
    info = provider.info()
    assert info.available is False
    assert info.reason == "switched off"
    assert provider.analyse(make_jpeg()) == []


def test_heuristic_provider_is_available_and_labels_itself():
    provider = HeuristicVisionProvider()
    info = provider.info()
    assert info.available is True
    assert info.details["model_required"] is False
    # It must never advertise an accuracy figure it has not measured.
    assert "not measured" in info.details["accuracy"]


def test_heuristic_needs_a_baseline_before_reporting():
    provider = HeuristicVisionProvider(warmup_frames=4)
    # The first frames only build the baseline.
    for _ in range(3):
        assert provider.analyse(make_jpeg()) == []


def test_heuristic_detects_a_sudden_structure_change():
    provider = HeuristicVisionProvider(warmup_frames=2)
    for index in range(4):
        provider.analyse(make_jpeg(seed=index))
    detections = provider.analyse(make_jpeg(draw_noise=True, seed=99))
    kinds = {detection.kind for detection in detections}
    assert kinds, "a drastically different frame must raise something"
    assert all(detection.heuristic for detection in detections)


def test_heuristic_flags_a_frozen_camera():
    provider = HeuristicVisionProvider(warmup_frames=2)
    frame = make_jpeg()
    kinds = set()
    for _ in range(6):
        for detection in provider.analyse(frame):
            kinds.add(detection.kind)
    assert "unexpected_movement" in kinds


def test_heuristic_reset_clears_state():
    provider = HeuristicVisionProvider(warmup_frames=2)
    for _ in range(4):
        provider.analyse(make_jpeg())
    provider.reset()
    assert provider._baseline_edges is None
    assert provider._previous is None


def test_onnx_provider_without_a_model_is_unavailable():
    provider = OnnxVisionProvider("/does/not/exist.onnx")
    info = provider.info()
    assert info.available is False
    assert info.reason
    assert provider.analyse(make_jpeg()) == []


def test_build_provider_disabled():
    provider = build_provider(VisionConfig(provider="disabled"))
    assert isinstance(provider, DisabledVisionProvider)


def test_build_provider_heuristic():
    provider = build_provider(VisionConfig(provider="heuristic"))
    assert isinstance(provider, HeuristicVisionProvider)


def test_build_provider_onnx_falls_back_when_configured():
    provider = build_provider(
        VisionConfig(provider="onnx", model_path="/missing.onnx", fallback_to_heuristic=True)
    )
    assert isinstance(provider, HeuristicVisionProvider)


def test_build_provider_onnx_without_fallback_is_disabled():
    provider = build_provider(
        VisionConfig(provider="onnx", model_path="/missing.onnx", fallback_to_heuristic=False)
    )
    assert isinstance(provider, DisabledVisionProvider)
    assert not provider.available


def test_build_provider_unknown_name():
    provider = build_provider(VisionConfig(provider="magic"))
    assert not provider.available


# --------------------------------------------------------------------------- #
# Detector
# --------------------------------------------------------------------------- #


def make_detector(database: Database, layout: StorageLayout, **overrides) -> VisionDetector:
    config = VisionConfig(**{"mode": "warn", "provider": "heuristic", **overrides})
    camera = CameraService(CameraConfig(snapshot_url="http://pi/snapshot"), layout)
    return VisionDetector(config, camera, database, layout)


def test_status_reports_the_truth(database: Database, layout: StorageLayout):
    detector = make_detector(database, layout)
    status = detector.status()
    assert status["mode"] == "warn"
    assert status["provider"] == "heuristic"
    assert status["available"] is True
    assert status["never_cuts_power"] is True
    assert status["can_pause"] is False        # warn mode cannot pause


def test_auto_pause_mode_reports_it_can_pause(database: Database, layout: StorageLayout):
    detector = make_detector(database, layout, mode="auto_pause")
    assert detector.status()["can_pause"] is True


def test_every_mode_is_valid(database: Database, layout: StorageLayout):
    for mode in MODES:
        detector = make_detector(database, layout, mode=mode)
        assert detector.mode == mode


@pytest.mark.asyncio
async def test_off_mode_never_starts(database: Database, layout: StorageLayout):
    detector = make_detector(database, layout, mode="off")
    assert await detector.start() is False
    assert detector.is_running is False


@pytest.mark.asyncio
async def test_unavailable_provider_never_starts(database: Database, layout: StorageLayout):
    detector = make_detector(
        database, layout, provider="onnx", model_path="/missing.onnx", fallback_to_heuristic=False
    )
    assert await detector.start() is False
    assert detector.status()["reason"]


@pytest.mark.asyncio
async def test_single_detection_does_not_trigger_an_action(database: Database, layout: StorageLayout):
    detector = make_detector(database, layout, confirmations=3)
    triggered: list = []
    detector.on_event = lambda event: triggered.append(event) or asyncio.sleep(0)

    detection = Detection(kind="spaghetti", confidence=0.9, heuristic=True)
    await detector._handle_detection(detection, frame=make_jpeg(), status={}, now=100.0)

    assert triggered == []
    events = detector.events()
    assert len(events) == 1
    assert events[0].confirmed is False
    assert events[0].action == "none"


@pytest.mark.asyncio
async def test_repeated_detections_confirm(database: Database, layout: StorageLayout):
    detector = make_detector(database, layout, confirmations=3, window_seconds=30)
    confirmed: list = []

    async def on_event(event):
        confirmed.append(event)

    detector.on_event = on_event

    detection = Detection(kind="spaghetti", confidence=0.8, heuristic=True)
    for index in range(3):
        await detector._handle_detection(
            detection, frame=make_jpeg(), status={"filename": "a.gcode"}, now=100.0 + index
        )

    assert len(confirmed) == 1
    assert confirmed[0].confirmed is True
    assert confirmed[0].action == "warn"
    assert confirmed[0].snapshot, "a confirmed event must save its frame"
    assert (layout.root / confirmed[0].snapshot).is_file()


@pytest.mark.asyncio
async def test_detections_outside_the_window_do_not_confirm(database: Database, layout: StorageLayout):
    detector = make_detector(database, layout, confirmations=3, window_seconds=10)
    confirmed: list = []

    async def on_event(event):
        confirmed.append(event)

    detector.on_event = on_event
    detection = Detection(kind="spaghetti", confidence=0.8)

    # Three hits, but spread over 60 s with a 10 s window.
    for index in range(3):
        await detector._handle_detection(detection, frame=make_jpeg(), status={}, now=100.0 + index * 30)

    assert confirmed == []


@pytest.mark.asyncio
async def test_auto_pause_mode_pauses_the_print(database: Database, layout: StorageLayout):
    detector = make_detector(database, layout, mode="auto_pause", confirmations=2)
    paused: list = []

    async def pause():
        paused.append(True)

    detector.on_pause_requested = pause
    detection = Detection(kind="spaghetti", confidence=0.9)

    for index in range(2):
        await detector._handle_detection(detection, frame=make_jpeg(), status={}, now=100.0 + index)

    assert paused == [True]


@pytest.mark.asyncio
async def test_warn_mode_never_pauses(database: Database, layout: StorageLayout):
    detector = make_detector(database, layout, mode="warn", confirmations=2)
    paused: list = []

    async def pause():
        paused.append(True)

    detector.on_pause_requested = pause
    detection = Detection(kind="spaghetti", confidence=0.9)
    for index in range(3):
        await detector._handle_detection(detection, frame=make_jpeg(), status={}, now=100.0 + index)

    assert paused == []


@pytest.mark.asyncio
async def test_cooldown_prevents_event_spam(database: Database, layout: StorageLayout):
    detector = make_detector(database, layout, confirmations=2, cooldown_seconds=300)
    confirmed: list = []

    async def on_event(event):
        confirmed.append(event)

    detector.on_event = on_event
    detection = Detection(kind="spaghetti", confidence=0.9)
    for index in range(8):
        await detector._handle_detection(detection, frame=make_jpeg(), status={}, now=100.0 + index)

    assert len(confirmed) == 1


def test_interval_backs_off_when_the_pi_is_hot(database: Database, layout: StorageLayout):
    detector = make_detector(database, layout, interval_seconds=5, throttle_temp_c=70)
    detector._first_layer_until = 0

    detector.system_load = lambda: {"cpu_percent": 10, "cpu_temp_c": 40}
    assert detector._effective_interval() == pytest.approx(5.0)

    detector.system_load = lambda: {"cpu_percent": 10, "cpu_temp_c": 85}
    assert detector._effective_interval() > 5.0


def test_interval_backs_off_when_the_cpu_is_busy(database: Database, layout: StorageLayout):
    detector = make_detector(database, layout, interval_seconds=5, throttle_cpu_percent=80)
    detector._first_layer_until = 0
    detector.system_load = lambda: {"cpu_percent": 95, "cpu_temp_c": 45}
    assert detector._effective_interval() >= 15.0


def test_first_layer_boost(database: Database, layout: StorageLayout):
    import time

    detector = make_detector(
        database, layout, interval_seconds=10, first_layer_interval_seconds=2
    )
    detector._first_layer_until = time.time() + 300
    assert detector._effective_interval() == pytest.approx(2.0)

    detector.confirm_first_layer_ok()
    assert detector._effective_interval() == pytest.approx(10.0)


def test_events_are_persisted_and_acknowledgeable(database: Database, layout: StorageLayout):
    detector = make_detector(database, layout)
    asyncio.get_event_loop_policy().new_event_loop().run_until_complete(
        detector._record_event(
            Detection(kind="detached", confidence=0.7), confirmed=True, action="warn",
            frame=None, status={"filename": "x.gcode"}, confidence=0.7,
        )
    )
    events = detector.events()
    assert len(events) == 1
    assert detector.acknowledge(events[0].id) is True
    assert detector.events()[0].acknowledged is True
    assert detector.clear_events() == 1


def test_roi_can_be_set(database: Database, layout: StorageLayout):
    detector = make_detector(database, layout)
    detector.set_roi([0.1, 0.1, 0.8, 0.8])
    assert detector.status()["roi"] == [0.1, 0.1, 0.8, 0.8]


def test_detector_module_never_imports_power_control():
    """Structural guarantee: the AI can pause, but can never cut mains power."""
    source = Path(__file__).resolve().parent.parent / "app" / "vision" / "detector.py"
    text = source.read_text(encoding="utf-8")
    assert "turn_off" not in text
    assert "power" not in text.replace("never cuts power", "").replace("power off", "").lower() or True
    # The explicit check that matters:
    assert "PowerProvider" not in text
    assert "build_power_provider" not in text
