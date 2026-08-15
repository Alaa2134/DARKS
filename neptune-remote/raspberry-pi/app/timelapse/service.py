"""Timelapse capture and rendering.

Two modes, both real:

* ``interval``  - the backend grabs a frame every N seconds while printing.
* ``layer``     - one frame per layer, triggered by a Klipper macro that calls
                  ``POST /api/timelapse/frame``. The macro is NEVER installed
                  automatically: ``suggested_macro()`` returns the config text
                  and the user copies it into printer.cfg themselves.

Frames are written to ``cache/timelapse/<session>/`` and rendered into an MP4
with FFmpeg when the print ends.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import shutil
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Awaitable, Callable, Optional

from ..camera.service import CameraService
from ..config import TimelapseConfig
from ..paths import StorageLayout
from ..recording.store import VideoRecord, VideoStore

log = logging.getLogger("neptune.timelapse")

StatusCallback = Callable[[dict], Awaitable[None]]

SUGGESTED_MACRO = """\
# ---------------------------------------------------------------------------
# Neptune Remote - layer-based timelapse trigger
#
# Copy this into printer.cfg (or a file you include from it) and restart
# Klipper. Neptune Remote never edits printer.cfg for you.
#
# Then set the slicer's "after layer change G-code" to:
#     TIMELAPSE_TAKE_FRAME
#
# This snippet contains no API token: the frame endpoint accepts calls from
# the Pi itself without one, so it is safe to share when asking for help.
# ---------------------------------------------------------------------------

[gcode_shell_command neptune_timelapse_frame]
command: curl -s -m 5 -X POST http://127.0.0.1:{port}/api/timelapse/frame
timeout: 6
verbose: False

[gcode_macro TIMELAPSE_TAKE_FRAME]
description: Ask Neptune Remote to capture one timelapse frame
gcode:
    RUN_SHELL_COMMAND CMD=neptune_timelapse_frame

# Requires the "gcode_shell_command" extension from KIAUH / Moonraker's
# extension list. If you do not have it, use interval mode instead - it needs
# no printer.cfg change at all.
"""


@dataclass
class TimelapseSession:
    id: str
    directory: Path
    started_at: float
    gcode_name: str = ""
    item_id: Optional[str] = None
    frame_count: int = 0
    mode: str = "interval"
    task: Optional[asyncio.Task] = None
    last_frame_at: Optional[float] = None
    errors: int = 0


class TimelapseService:
    def __init__(
        self,
        config: TimelapseConfig,
        camera: CameraService,
        store: VideoStore,
        layout: StorageLayout,
    ) -> None:
        self.config = config
        self.camera = camera
        self.store = store
        self.layout = layout
        self._session: Optional[TimelapseSession] = None
        self._lock = asyncio.Lock()
        self.on_status: Optional[StatusCallback] = None
        self.last_error = ""

    # ---------------------------------------------------------------- state
    @property
    def is_running(self) -> bool:
        return self._session is not None

    def status(self) -> dict:
        session = self._session
        return {
            "running": session is not None,
            "session_id": session.id if session else None,
            "mode": session.mode if session else self.config.mode,
            "frames": session.frame_count if session else 0,
            "started_at": session.started_at if session else None,
            "last_frame_at": session.last_frame_at if session else None,
            "interval_seconds": self.config.interval_seconds,
            "configured_mode": self.config.mode,
            "ffmpeg_available": self.camera.ffmpeg is not None,
            "camera_available": self.camera.status(probe_devices=False).available,
            "last_error": self.last_error,
        }

    async def _publish(self) -> None:
        if self.on_status is not None:
            with contextlib.suppress(Exception):
                await self.on_status(self.status())

    # ---------------------------------------------------------------- start
    async def start(self, *, gcode_name: str = "", item_id: Optional[str] = None) -> bool:
        if self.config.mode == "off":
            return False

        async with self._lock:
            if self._session is not None:
                return False

            session_id = uuid.uuid4().hex[:10]
            directory = self.layout.cache / "timelapse" / session_id
            directory.mkdir(parents=True, exist_ok=True)

            session = TimelapseSession(
                id=session_id,
                directory=directory,
                started_at=time.time(),
                gcode_name=gcode_name,
                item_id=item_id,
                mode=self.config.mode,
            )
            if self.config.mode == "interval":
                session.task = asyncio.create_task(self._interval_loop(session))
            self._session = session

        log.info("Timelapse session %s started (%s)", session_id, self.config.mode)
        await self._publish()
        return True

    async def _interval_loop(self, session: TimelapseSession) -> None:
        interval = max(1.0, float(self.config.interval_seconds))
        try:
            while True:
                await self.capture_frame()
                await asyncio.sleep(interval)
        except asyncio.CancelledError:
            raise
        except Exception:
            log.exception("Timelapse interval loop failed")

    # ---------------------------------------------------------------- frame
    async def capture_frame(self) -> bool:
        session = self._session
        if session is None:
            return False
        if session.frame_count >= self.config.max_frames:
            return False

        data = await self.camera.snapshot()
        if not data:
            session.errors += 1
            self.last_error = self.camera.last_error or "snapshot failed"
            if session.errors == 5:
                log.warning("Timelapse: 5 failed frames (%s)", self.last_error)
            return False

        session.frame_count += 1
        session.last_frame_at = time.time()
        path = session.directory / f"frame_{session.frame_count:06d}.jpg"
        path.write_bytes(data)
        return True

    # ---------------------------------------------------------------- finish
    async def finish(self, *, result: str = "completed") -> Optional[VideoRecord]:
        async with self._lock:
            session = self._session
            if session is None:
                return None
            self._session = None

        if session.task is not None:
            session.task.cancel()
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await session.task

        try:
            if session.frame_count < self.config.min_frames:
                self.last_error = (
                    f"only {session.frame_count} frame(s) captured, "
                    f"need at least {self.config.min_frames}"
                )
                log.info("Timelapse discarded: %s", self.last_error)
                return None

            record = await self._render(session, result=result)
            return record
        finally:
            if not self.config.keep_frames:
                shutil.rmtree(session.directory, ignore_errors=True)
            await self._publish()

    async def _render(self, session: TimelapseSession, *, result: str) -> Optional[VideoRecord]:
        binary = self.camera.ffmpeg
        if binary is None:
            self.last_error = "ffmpeg is not installed"
            return None

        stamp = time.strftime("%Y%m%d-%H%M%S", time.localtime(session.started_at))
        base = Path(session.gcode_name).stem or "timelapse"
        safe_base = "".join(char for char in base if char.isalnum() or char in "-_")[:40] or "timelapse"
        output = self.layout.timelapses / f"{stamp}_{safe_base}.mp4"

        command = [
            binary, "-hide_banner", "-loglevel", "error", "-y",
            "-framerate", str(self.config.output_fps),
            "-pattern_type", "glob",
            "-i", str(session.directory / "frame_*.jpg"),
            "-c:v", "libx264",
            "-preset", "medium",
            "-crf", str(self.config.crf),
            "-pix_fmt", "yuv420p",
            "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2",
            "-movflags", "+faststart",
            str(output),
        ]

        try:
            process = await asyncio.create_subprocess_exec(
                *command, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
            )
            _, stderr = await asyncio.wait_for(process.communicate(), timeout=600)
        except (OSError, asyncio.TimeoutError) as exc:
            self.last_error = f"ffmpeg render failed: {exc}"
            return None

        if process.returncode != 0 or not output.is_file():
            self.last_error = (stderr or b"").decode("utf-8", errors="replace").strip()[:300]
            log.error("Timelapse render failed: %s", self.last_error)
            output.unlink(missing_ok=True)
            return None

        record = self.store.create(
            kind="timelapse",
            path=output,
            gcode_name=session.gcode_name,
            item_id=session.item_id,
            started_at=session.started_at,
        )
        # Use the last captured frame as the poster image.
        frames = sorted(session.directory.glob("frame_*.jpg"))
        thumbnail: Optional[Path] = None
        if frames:
            thumbnail = self.layout.snapshots / f"timelapse_{record.id}.jpg"
            shutil.copyfile(frames[-1], thumbnail)

        self.last_error = ""
        return self.store.finish(
            record.id, result=result, frame_count=session.frame_count, thumbnail=thumbnail
        )

    # ------------------------------------------------------------- lifecycle
    async def handle_print_started(self, gcode_name: str, item_id: Optional[str]) -> None:
        if self.config.mode == "off":
            return
        await self.start(gcode_name=gcode_name, item_id=item_id)

    async def handle_print_finished(self, result: str) -> Optional[VideoRecord]:
        if not self.is_running:
            return None
        return await self.finish(result=result)

    async def handle_layer_change(self) -> None:
        if self.config.mode == "layer" and self.is_running:
            await self.capture_frame()

    async def shutdown(self) -> None:
        if self.is_running:
            await self.finish(result="cancelled")

    # --------------------------------------------------------------- macros
    def suggested_macro(self, *, port: int) -> str:
        """The printer.cfg snippet, deliberately free of any secret.

        The frame endpoint accepts loopback callers without a token precisely so
        this text can be pasted into printer.cfg - and shared on a forum - with
        nothing sensitive in it.
        """
        return SUGGESTED_MACRO.format(port=port)
