"""The print-failure monitor: sampling, temporal confirmation, events, actions.

Design rules that are enforced here, not just documented:

* inference never runs faster than ``vision.interval_seconds`` (default 5 s);
* a single suspicious frame never triggers anything - a detection must repeat
  ``confirmations`` times inside ``window_seconds``;
* the monitor can pause a print (only in ``auto_pause`` mode) but it can NEVER
  switch mains power off - there is no power call anywhere in this module;
* if the Raspberry Pi is hot or busy the sampling interval is stretched
  automatically so Klipper always keeps its CPU.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import time
import uuid
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Awaitable, Callable, Deque, Dict, List, Optional

from ..camera.service import CameraService
from ..config import VisionConfig
from ..db import Database
from ..paths import StorageLayout
from .providers import Detection, VisionProvider, build_provider

log = logging.getLogger("neptune.vision.detector")

EventCallback = Callable[["VisionEvent"], Awaitable[None]]
PauseCallback = Callable[[], Awaitable[None]]
StatusProvider = Callable[[], Dict[str, Any]]

MODES = ("off", "monitor", "warn", "auto_pause")


@dataclass
class VisionEvent:
    id: str
    created_at: float
    kind: str
    confidence: float
    confirmed: bool
    action: str = "none"
    snapshot: Optional[str] = None
    gcode_name: str = ""
    layer: Optional[int] = None
    progress: Optional[float] = None
    detail: str = ""
    acknowledged: bool = False

    def as_dict(self) -> Dict[str, Any]:
        return {
            "id": self.id,
            "created_at": self.created_at,
            "kind": self.kind,
            "confidence": round(self.confidence, 3),
            "confirmed": self.confirmed,
            "action": self.action,
            "snapshot": self.snapshot,
            "gcode_name": self.gcode_name,
            "layer": self.layer,
            "progress": self.progress,
            "detail": self.detail,
            "acknowledged": self.acknowledged,
        }


@dataclass
class _Tracker:
    """Rolling record of one failure kind."""

    kind: str
    hits: Deque[tuple[float, float]] = field(default_factory=deque)  # (timestamp, confidence)
    # -inf so the very first confirmation always fires; the cooldown only ever
    # suppresses *repeat* events.
    last_event_at: float = float("-inf")

    def add(self, confidence: float, *, now: float, window: float) -> None:
        self.hits.append((now, confidence))
        while self.hits and now - self.hits[0][0] > window:
            self.hits.popleft()

    def count(self) -> int:
        return len(self.hits)

    def peak(self) -> float:
        return max((confidence for _, confidence in self.hits), default=0.0)

    def average(self) -> float:
        if not self.hits:
            return 0.0
        return sum(confidence for _, confidence in self.hits) / len(self.hits)


class VisionDetector:
    def __init__(
        self,
        config: VisionConfig,
        camera: CameraService,
        database: Database,
        layout: StorageLayout,
    ) -> None:
        self.config = config
        self.camera = camera
        self.db = database
        self.layout = layout

        self.provider: VisionProvider = build_provider(config)
        self.on_event: Optional[EventCallback] = None
        self.on_pause_requested: Optional[PauseCallback] = None
        self.printer_status: Optional[StatusProvider] = None
        self.system_load: Optional[StatusProvider] = None

        self._task: Optional[asyncio.Task] = None
        self._running = False
        self._trackers: Dict[str, _Tracker] = {}
        self._frames_analysed = 0
        self._last_frame_at: Optional[float] = None
        self._last_error = ""
        self._current_interval = float(config.interval_seconds)
        self._paused_by_us = False
        self._first_layer_until: float = 0.0

    # ---------------------------------------------------------------- state
    @property
    def mode(self) -> str:
        return self.config.mode if self.config.mode in MODES else "warn"

    @property
    def is_running(self) -> bool:
        return self._running

    def status(self) -> Dict[str, Any]:
        info = self.provider.info()
        return {
            "mode": self.mode,
            "running": self._running,
            "provider": info.name,
            "available": info.available,
            "reason": info.reason,
            "details": info.details,
            "interval_seconds": round(self._current_interval, 1),
            "configured_interval": self.config.interval_seconds,
            "confirmations_required": self.config.confirmations,
            "window_seconds": self.config.window_seconds,
            "min_confidence": self.config.min_confidence,
            "frames_analysed": self._frames_analysed,
            "last_frame_at": self._last_frame_at,
            "last_error": self._last_error,
            "roi": list(self.config.roi) if self.config.roi else None,
            "camera_available": self.camera.status(probe_devices=False).available,
            "can_pause": self.mode == "auto_pause",
            "never_cuts_power": True,
        }

    def rebuild_provider(self) -> None:
        self.provider = build_provider(self.config)
        self._trackers.clear()

    # ------------------------------------------------------------- lifecycle
    async def start(self) -> bool:
        if self.mode == "off":
            return False
        if self._running:
            return True
        if not self.provider.available:
            self._last_error = self.provider.info().reason
            log.info("Vision detector not started: %s", self._last_error)
            return False

        self._running = True
        self._trackers.clear()
        self.provider.reset()
        self._paused_by_us = False
        self._first_layer_until = time.time() + self.config.first_layer_seconds
        self._task = asyncio.create_task(self._loop())
        log.info("Vision detector started (provider=%s, mode=%s)", self.provider.name, self.mode)
        return True

    async def stop(self) -> None:
        self._running = False
        if self._task is not None:
            self._task.cancel()
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await self._task
            self._task = None

    async def shutdown(self) -> None:
        await self.stop()

    # ------------------------------------------------------------------ loop
    async def _loop(self) -> None:
        try:
            while self._running:
                interval = self._effective_interval()
                self._current_interval = interval
                await asyncio.sleep(interval)
                if not self._running:
                    return
                with contextlib.suppress(Exception):
                    await self._tick()
        except asyncio.CancelledError:
            raise
        except Exception:
            log.exception("Vision loop crashed")
            self._running = False

    def _effective_interval(self) -> float:
        """Back off when the Pi is busy or hot - Klipper always wins."""
        interval = max(1.0, float(self.config.interval_seconds))

        # During the first layers, sample more often if configured.
        if time.time() < self._first_layer_until and self.config.first_layer_interval_seconds > 0:
            interval = max(1.0, float(self.config.first_layer_interval_seconds))

        if self.system_load is None:
            return interval
        try:
            load = self.system_load() or {}
        except Exception:
            return interval

        cpu = float(load.get("cpu_percent") or 0.0)
        temperature = float(load.get("cpu_temp_c") or 0.0)

        if temperature >= self.config.throttle_temp_c or cpu >= self.config.throttle_cpu_percent:
            return min(interval * 3.0, 60.0)
        if cpu >= self.config.throttle_cpu_percent * 0.75:
            return min(interval * 1.6, 45.0)
        return interval

    async def _tick(self) -> None:
        status = self.printer_status() if self.printer_status else {}
        if self.config.only_while_printing and status.get("state") != "printing":
            return

        frame = await self.camera.snapshot()
        if not frame:
            self._last_error = self.camera.last_error or "no frame available"
            return

        self._frames_analysed += 1
        self._last_frame_at = time.time()
        self._last_error = ""

        detections = await asyncio.get_running_loop().run_in_executor(
            None, lambda: self.provider.analyse(frame, roi=self.config.roi)
        )
        if not detections:
            return

        now = time.time()
        for detection in detections:
            if detection.confidence < self.config.min_confidence:
                continue
            await self._handle_detection(detection, frame=frame, status=status, now=now)

    # ------------------------------------------------- temporal confirmation
    async def _handle_detection(
        self,
        detection: Detection,
        *,
        frame: bytes,
        status: Dict[str, Any],
        now: float,
    ) -> None:
        tracker = self._trackers.setdefault(detection.kind, _Tracker(kind=detection.kind))
        tracker.add(detection.confidence, now=now, window=float(self.config.window_seconds))

        confirmed = tracker.count() >= self.config.confirmations
        if not confirmed:
            # Record the suspicion in the timeline, but take no action.
            await self._record_event(
                detection,
                confirmed=False,
                action="none",
                frame=None,
                status=status,
                confidence=detection.confidence,
            )
            return

        # Do not spam: one confirmed event per kind per cooldown window.
        if now - tracker.last_event_at < float(self.config.cooldown_seconds):
            return
        tracker.last_event_at = now

        action = "warn"
        if self.mode == "monitor":
            action = "monitor"
        elif self.mode == "auto_pause":
            action = "paused"

        event = await self._record_event(
            detection,
            confirmed=True,
            action=action,
            frame=frame,
            status=status,
            confidence=tracker.peak(),
        )

        if self.mode == "auto_pause" and self.on_pause_requested is not None and not self._paused_by_us:
            self._paused_by_us = True
            log.warning(
                "Vision confirmed %s (%.2f) - pausing the print", detection.kind, tracker.peak()
            )
            with contextlib.suppress(Exception):
                await self.on_pause_requested()

        if self.on_event is not None and event is not None:
            with contextlib.suppress(Exception):
                await self.on_event(event)

    async def _record_event(
        self,
        detection: Detection,
        *,
        confirmed: bool,
        action: str,
        frame: Optional[bytes],
        status: Dict[str, Any],
        confidence: float,
    ) -> Optional[VisionEvent]:
        snapshot_relative: Optional[str] = None
        if frame is not None:
            stamp = time.strftime("%Y%m%d-%H%M%S")
            path = self.layout.ai_events / f"{stamp}_{detection.kind}.jpg"
            try:
                path.write_bytes(frame)
                snapshot_relative = self.layout.relative(path)
            except OSError as exc:
                log.warning("Could not save AI event snapshot: %s", exc)

        event = VisionEvent(
            id=uuid.uuid4().hex[:12],
            created_at=time.time(),
            kind=detection.kind,
            confidence=confidence,
            confirmed=confirmed,
            action=action,
            snapshot=snapshot_relative,
            gcode_name=str(status.get("filename") or ""),
            layer=status.get("current_layer"),
            progress=status.get("progress"),
            detail=detection.detail
                   + (" [heuristic]" if detection.heuristic else ""),
        )

        self.db.execute(
            """
            INSERT INTO vision_events(
                id, created_at, kind, confidence, confirmed, action, snapshot,
                gcode_name, layer, progress, detail, acknowledged
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,0)
            """,
            (
                event.id, event.created_at, event.kind, event.confidence, int(event.confirmed),
                event.action, event.snapshot, event.gcode_name, event.layer, event.progress,
                event.detail,
            ),
        )
        self._prune_events()
        return event

    def _prune_events(self) -> None:
        self.db.execute(
            "DELETE FROM vision_events WHERE id NOT IN "
            "(SELECT id FROM vision_events ORDER BY created_at DESC LIMIT ?)",
            (self.config.max_events,),
        )

    # ---------------------------------------------------------------- events
    def events(self, *, limit: int = 100, confirmed_only: bool = False) -> List[VisionEvent]:
        sql = "SELECT * FROM vision_events"
        params: List[Any] = []
        if confirmed_only:
            sql += " WHERE confirmed = 1"
        sql += " ORDER BY created_at DESC LIMIT ?"
        params.append(limit)

        return [
            VisionEvent(
                id=row["id"],
                created_at=float(row["created_at"]),
                kind=row["kind"],
                confidence=float(row["confidence"]),
                confirmed=bool(row["confirmed"]),
                action=row["action"],
                snapshot=row["snapshot"],
                gcode_name=row["gcode_name"] or "",
                layer=row["layer"],
                progress=row["progress"],
                detail=row["detail"] or "",
                acknowledged=bool(row["acknowledged"]),
            )
            for row in self.db.query(sql, params)
        ]

    def acknowledge(self, event_id: str) -> bool:
        cursor = self.db.execute(
            "UPDATE vision_events SET acknowledged = 1 WHERE id = ?", (event_id,)
        )
        return cursor.rowcount > 0

    def clear_events(self) -> int:
        cursor = self.db.execute("DELETE FROM vision_events")
        return cursor.rowcount

    def snapshot_path(self, event_id: str) -> Optional[Path]:
        row = self.db.query_one("SELECT snapshot FROM vision_events WHERE id = ?", (event_id,))
        if row is None or not row["snapshot"]:
            return None
        try:
            path = self.layout.resolve(row["snapshot"])
        except ValueError:
            return None
        return path if path.is_file() else None

    # ------------------------------------------------------- print lifecycle
    async def handle_print_started(self) -> None:
        self._trackers.clear()
        self.provider.reset()
        self._paused_by_us = False
        self._first_layer_until = time.time() + self.config.first_layer_seconds
        await self.start()

    async def handle_print_finished(self) -> None:
        await self.stop()
        self._trackers.clear()

    def confirm_first_layer_ok(self) -> None:
        """User pressed 'the first layer looks great' - stop first-layer boost."""
        self._first_layer_until = 0.0
        self.provider.reset()
        self._trackers.clear()

    def set_roi(self, roi: Optional[List[float]]) -> None:
        self.config.roi = roi
        self.provider.reset()
        self._trackers.clear()
