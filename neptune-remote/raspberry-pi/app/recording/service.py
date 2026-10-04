"""Real print recording with FFmpeg.

The recorder spawns one ``ffmpeg`` process that reads the configured camera
source and writes an MP4 into ``videos/YYYY/MM/DD/``. It is stopped gracefully
(``q`` on stdin, then SIGTERM) so the container is always finalised and the file
plays everywhere.

If FFmpeg is missing or the camera is unavailable the service reports the
failure - it never creates an empty file and calls it a recording.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Awaitable, Callable, List, Optional

from ..camera.service import CameraService
from ..config import RecordingConfig
from ..paths import StorageLayout
from .store import VideoRecord, VideoStore

log = logging.getLogger("neptune.recording")

StatusCallback = Callable[[dict], Awaitable[None]]


class RecordingError(RuntimeError):
    pass


@dataclass
class ActiveRecording:
    video_id: str
    path: Path
    process: asyncio.subprocess.Process
    started_at: float
    gcode_name: str
    mode: str
    stderr_task: Optional[asyncio.Task] = None
    stderr_tail: List[str] = None  # type: ignore[assignment]


class RecordingService:
    def __init__(
        self,
        config: RecordingConfig,
        camera: CameraService,
        store: VideoStore,
        layout: StorageLayout,
    ) -> None:
        self.config = config
        self.camera = camera
        self.store = store
        self.layout = layout
        self._active: Optional[ActiveRecording] = None
        self._lock = asyncio.Lock()
        self.on_status: Optional[StatusCallback] = None
        self.last_error: str = ""

    # ---------------------------------------------------------------- state
    @property
    def is_recording(self) -> bool:
        return self._active is not None

    @property
    def active_video_id(self) -> Optional[str]:
        return self._active.video_id if self._active else None

    def status(self) -> dict:
        active = self._active
        return {
            "recording": active is not None,
            "video_id": active.video_id if active else None,
            "filename": active.path.name if active else "",
            "started_at": active.started_at if active else None,
            "elapsed": (time.time() - active.started_at) if active else 0.0,
            "mode": active.mode if active else self.config.mode,
            "gcode_name": active.gcode_name if active else "",
            "ffmpeg_available": self.camera.ffmpeg is not None,
            "camera_available": self.camera.status(probe_devices=False).available,
            "auto_mode": self.config.mode,
            "last_error": self.last_error,
        }

    async def _publish(self) -> None:
        if self.on_status is not None:
            with contextlib.suppress(Exception):
                await self.on_status(self.status())

    # ---------------------------------------------------------------- start
    async def start(
        self,
        *,
        gcode_name: str = "",
        item_id: Optional[str] = None,
        history_id: Optional[int] = None,
        mode: str = "manual",
    ) -> VideoRecord:
        async with self._lock:
            if self._active is not None:
                raise RecordingError("A recording is already running")

            binary = self.camera.ffmpeg
            if binary is None:
                self.last_error = "ffmpeg is not installed"
                raise RecordingError(self.last_error)

            input_args = self.camera.ffmpeg_input_args()
            if input_args is None:
                self.last_error = "no camera source configured"
                raise RecordingError(self.last_error)

            stamp = time.strftime("%Y%m%d-%H%M%S")
            base = Path(gcode_name).stem or "print"
            safe_base = "".join(char for char in base if char.isalnum() or char in "-_")[:40] or "print"
            directory = self.layout.dated_video_dir()
            path = directory / f"{stamp}_{safe_base}.mp4"

            command = [
                binary, "-hide_banner", "-loglevel", "warning", "-y",
                *input_args,
                "-c:v", self.config.video_codec,
                "-preset", self.config.preset,
                "-crf", str(self.config.crf),
                "-pix_fmt", "yuv420p",
                "-r", str(self.config.output_fps),
                "-movflags", "+faststart",
                str(path),
            ]
            if self.config.max_seconds > 0:
                command[-1:-1] = ["-t", str(self.config.max_seconds)]

            log.info("Starting recording: %s", " ".join(command))
            try:
                process = await asyncio.create_subprocess_exec(
                    *command,
                    stdin=asyncio.subprocess.PIPE,
                    stdout=asyncio.subprocess.DEVNULL,
                    stderr=asyncio.subprocess.PIPE,
                )
            except OSError as exc:
                self.last_error = f"could not start ffmpeg: {exc}"
                raise RecordingError(self.last_error) from exc

            # Give FFmpeg a moment to fail fast on a bad source.
            await asyncio.sleep(1.2)
            if process.returncode is not None:
                stderr = b""
                if process.stderr is not None:
                    stderr = await process.stderr.read()
                message = stderr.decode("utf-8", errors="replace").strip().splitlines()
                self.last_error = message[-1] if message else "ffmpeg exited immediately"
                path.unlink(missing_ok=True)
                raise RecordingError(f"ffmpeg failed to start: {self.last_error}")

            record = self.store.create(
                kind="recording",
                path=path,
                gcode_name=gcode_name,
                item_id=item_id,
                history_id=history_id,
            )
            active = ActiveRecording(
                video_id=record.id,
                path=path,
                process=process,
                started_at=time.time(),
                gcode_name=gcode_name,
                mode=mode,
                stderr_tail=[],
            )
            active.stderr_task = asyncio.create_task(self._drain_stderr(active))
            self._active = active
            self.last_error = ""

        await self._publish()
        return record

    async def _drain_stderr(self, active: ActiveRecording) -> None:
        stream = active.process.stderr
        if stream is None:
            return
        try:
            while True:
                line = await stream.readline()
                if not line:
                    return
                text = line.decode("utf-8", errors="replace").strip()
                if text:
                    active.stderr_tail.append(text)
                    if len(active.stderr_tail) > 30:
                        del active.stderr_tail[:-30]
        except asyncio.CancelledError:
            raise
        except Exception:
            return

    # ----------------------------------------------------------------- stop
    async def stop(self, *, result: str = "completed") -> Optional[VideoRecord]:
        async with self._lock:
            active = self._active
            if active is None:
                return None
            self._active = None

        process = active.process
        if process.returncode is None:
            # 'q' makes FFmpeg finalise the MP4 container cleanly.
            with contextlib.suppress(Exception):
                if process.stdin is not None:
                    process.stdin.write(b"q")
                    await process.stdin.drain()
            try:
                await asyncio.wait_for(process.wait(), timeout=12)
            except asyncio.TimeoutError:
                with contextlib.suppress(ProcessLookupError):
                    process.terminate()
                try:
                    await asyncio.wait_for(process.wait(), timeout=6)
                except asyncio.TimeoutError:
                    with contextlib.suppress(ProcessLookupError):
                        process.kill()

        if active.stderr_task is not None:
            active.stderr_task.cancel()
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await active.stderr_task

        error = ""
        final_result = result
        if not active.path.is_file() or active.path.stat().st_size < 1024:
            error = "; ".join(active.stderr_tail[-3:]) or "ffmpeg produced no usable video"
            final_result = "error"
            self.last_error = error
            active.path.unlink(missing_ok=True)

        record = self.store.finish(active.video_id, result=final_result, error=error)
        if final_result == "error":
            # Drop the placeholder row so the app never lists a broken video.
            self.store.delete(active.video_id, delete_file=True)
            record = None

        await self._publish()
        self._apply_retention()
        return record

    async def cancel(self) -> Optional[VideoRecord]:
        return await self.stop(result="cancelled")

    # ------------------------------------------------------------- retention
    def _apply_retention(self) -> None:
        try:
            removed = self.store.apply_retention(
                policy=self.config.retention_policy,
                max_gigabytes=self.config.retention_max_gb,
                keep_last=self.config.retention_keep_last,
                active_ids=[self.active_video_id] if self.active_video_id else [],
            )
            if removed:
                log.info("Retention removed %d recording(s)", len(removed))
        except Exception:
            log.exception("Retention policy failed")

    # ------------------------------------------------------ automatic modes
    def should_record_print(self) -> bool:
        return self.config.mode in {"full", "first_layer", "last_layer"}

    async def handle_print_started(self, gcode_name: str, item_id: Optional[str]) -> None:
        if not self.should_record_print() or self.is_recording:
            return
        try:
            await self.start(gcode_name=gcode_name, item_id=item_id, mode=self.config.mode)
        except RecordingError as exc:
            log.warning("Automatic recording could not start: %s", exc)

    async def handle_print_finished(self, result: str) -> None:
        if self.is_recording:
            await self.stop(result=result)

    async def handle_layer_change(self, layer: int, total_layers: Optional[int]) -> None:
        """First-layer / last-layer modes stop or start around the edges."""
        if self.config.mode == "first_layer" and self.is_recording and layer >= 2:
            await self.stop(result="completed")
        elif (
            self.config.mode == "last_layer"
            and not self.is_recording
            and total_layers
            and layer >= max(1, total_layers - 1)
        ):
            with contextlib.suppress(RecordingError):
                await self.start(mode="last_layer")

    async def shutdown(self) -> None:
        if self.is_recording:
            await self.stop(result="cancelled")
