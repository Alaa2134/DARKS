"""Camera service: status, snapshots and the source used for recording.

Two sources are supported and both are real:

* ``stream``  - an MJPEG/snapshot URL served by crowsnest / ustreamer / mjpg-streamer.
                This is the normal MainsailOS setup and lets the camera be shared
                between Mainsail, this backend and the phone at the same time.
* ``device``  - a /dev/videoN node read directly with FFmpeg. Used when no
                streamer is installed. Only one consumer can hold the device.

Snapshots are taken with FFmpeg, so exactly what is recorded is what you see.
"""

from __future__ import annotations

import asyncio
import logging
import shutil
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional

import httpx

from ..config import CameraConfig
from ..paths import StorageLayout
from .devices import CameraDevice, discover, has_v4l2

log = logging.getLogger("neptune.camera")


@dataclass
class CameraStatus:
    available: bool = False
    source: str = "none"          # stream | device | none
    url: str = ""
    device_path: str = ""
    ffmpeg_available: bool = False
    v4l2_available: bool = False
    devices: List[Dict[str, Any]] = None  # type: ignore[assignment]
    last_snapshot_at: Optional[float] = None
    last_error: str = ""
    message_key: str = "camera.status.ok"

    def as_dict(self) -> Dict[str, Any]:
        return {
            "available": self.available,
            "source": self.source,
            "url": self.url,
            "device_path": self.device_path,
            "ffmpeg_available": self.ffmpeg_available,
            "v4l2_available": self.v4l2_available,
            "devices": self.devices or [],
            "last_snapshot_at": self.last_snapshot_at,
            "last_error": self.last_error,
            "message_key": self.message_key,
        }


def ffmpeg_binary(configured: str = "ffmpeg") -> Optional[str]:
    direct = Path(configured)
    if direct.is_file():
        return str(direct)
    return shutil.which(configured)


class CameraService:
    def __init__(self, config: CameraConfig, layout: StorageLayout) -> None:
        self.config = config
        self.layout = layout
        self._last_snapshot_at: Optional[float] = None
        self._last_error = ""
        self._client: Optional[httpx.AsyncClient] = None

    async def aclose(self) -> None:
        if self._client is not None and not self._client.is_closed:
            await self._client.aclose()
        self._client = None

    # -------------------------------------------------------------- helpers
    @property
    def ffmpeg(self) -> Optional[str]:
        return ffmpeg_binary(self.config.ffmpeg_binary)

    @property
    def source(self) -> str:
        if self.config.snapshot_url or self.config.stream_url:
            return "stream"
        if self.config.device:
            return "device"
        return "none"

    def _http(self) -> httpx.AsyncClient:
        if self._client is None or self._client.is_closed:
            self._client = httpx.AsyncClient(timeout=httpx.Timeout(10.0), follow_redirects=True)
        return self._client

    # --------------------------------------------------------------- status
    def status(self, *, probe_devices: bool = True) -> CameraStatus:
        devices: List[CameraDevice] = discover() if probe_devices else []
        ffmpeg = self.ffmpeg is not None

        status = CameraStatus(
            source=self.source,
            url=self.config.snapshot_url or self.config.stream_url,
            device_path=self.config.device,
            ffmpeg_available=ffmpeg,
            v4l2_available=has_v4l2(),
            devices=[
                {
                    "path": device.path,
                    "name": device.name,
                    "driver": device.driver,
                    "bus": device.bus,
                    "modes": [
                        {"width": mode.width, "height": mode.height,
                         "fps": mode.fps, "pixel_format": mode.pixel_format,
                         "label": mode.label}
                        for mode in device.modes[:40]
                    ],
                    "recommended": (
                        {
                            "width": device.recommended_mode().width,
                            "height": device.recommended_mode().height,
                            "fps": device.recommended_mode().fps,
                            "label": device.recommended_mode().label,
                        }
                        if device.recommended_mode() else None
                    ),
                }
                for device in devices
            ],
            last_snapshot_at=self._last_snapshot_at,
            last_error=self._last_error,
        )

        if not self.config.enabled:
            status.available = False
            status.message_key = "camera.status.disabled"
            return status

        if status.source == "none":
            status.available = False
            status.message_key = (
                "camera.status.detected_not_configured" if devices else "camera.status.no_camera"
            )
            return status

        if status.source == "device" and not ffmpeg:
            status.available = False
            status.message_key = "camera.status.no_ffmpeg"
            return status

        status.available = True
        status.message_key = "camera.status.ok"
        return status

    # ------------------------------------------------------------ snapshots
    async def snapshot(self) -> Optional[bytes]:
        """Grab a single JPEG. Returns None (never a fake image) on failure."""
        if not self.config.enabled:
            self._last_error = "camera disabled in config.yaml"
            return None

        tried = False
        first_error = ""

        if self.config.snapshot_url:
            tried = True
            data = await self._snapshot_from_url(self.config.snapshot_url)
            if data:
                return data
            first_error = first_error or self._last_error

        if self.config.stream_url:
            tried = True
            data = await self._snapshot_from_stream(self.config.stream_url)
            if data:
                return data
            first_error = first_error or self._last_error

        if self.config.device:
            tried = True
            data = await self._snapshot_from_device()
            if data:
                return data
            first_error = first_error or self._last_error

        # Keep the first real failure reason instead of overwriting it with a
        # generic message - the app shows this text to the user.
        self._last_error = first_error or ("" if tried else "no camera source configured")
        return None

    async def _snapshot_from_url(self, url: str) -> Optional[bytes]:
        try:
            response = await self._http().get(url)
            if response.status_code >= 400:
                self._last_error = f"snapshot URL returned HTTP {response.status_code}"
                return None
            data = response.content
            if data[:2] == b"\xff\xd8":  # JPEG SOI
                self._last_snapshot_at = time.time()
                self._last_error = ""
                return data
            self._last_error = "snapshot URL did not return a JPEG"
            return None
        except httpx.HTTPError as exc:
            self._last_error = f"snapshot request failed: {exc}"
            return None

    async def _snapshot_from_stream(self, url: str) -> Optional[bytes]:
        """Read one frame out of an MJPEG stream."""
        try:
            async with self._http().stream("GET", url) as response:
                if response.status_code >= 400:
                    self._last_error = f"stream returned HTTP {response.status_code}"
                    return None
                buffer = bytearray()
                async for chunk in response.aiter_bytes():
                    buffer.extend(chunk)
                    start = buffer.find(b"\xff\xd8")
                    end = buffer.find(b"\xff\xd9", start + 2) if start >= 0 else -1
                    if start >= 0 and end > start:
                        self._last_snapshot_at = time.time()
                        self._last_error = ""
                        return bytes(buffer[start:end + 2])
                    if len(buffer) > 8 * 1024 * 1024:
                        self._last_error = "stream did not contain a JPEG frame"
                        return None
        except httpx.HTTPError as exc:
            self._last_error = f"stream request failed: {exc}"
        return None

    async def _snapshot_from_device(self) -> Optional[bytes]:
        binary = self.ffmpeg
        if binary is None:
            self._last_error = "ffmpeg is not installed"
            return None

        target = self.layout.cache / f"snapshot_{int(time.time() * 1000)}.jpg"
        command = [
            binary, "-hide_banner", "-loglevel", "error", "-y",
            "-f", "v4l2",
            "-video_size", f"{self.config.width}x{self.config.height}",
            "-i", self.config.device,
            "-frames:v", "1",
            str(target),
        ]
        try:
            process = await asyncio.create_subprocess_exec(
                *command, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
            )
            _, stderr = await asyncio.wait_for(process.communicate(), timeout=20)
        except (OSError, asyncio.TimeoutError) as exc:
            self._last_error = f"ffmpeg snapshot failed: {exc}"
            return None

        if process.returncode != 0 or not target.is_file():
            self._last_error = (stderr or b"").decode("utf-8", errors="replace").strip()[:300]
            target.unlink(missing_ok=True)
            return None

        data = target.read_bytes()
        target.unlink(missing_ok=True)
        self._last_snapshot_at = time.time()
        self._last_error = ""
        return data

    async def save_snapshot(self, *, prefix: str = "snapshot") -> Optional[Path]:
        data = await self.snapshot()
        if not data:
            return None
        stamp = time.strftime("%Y%m%d-%H%M%S")
        path = self.layout.snapshots / f"{prefix}-{stamp}.jpg"
        path.write_bytes(data)
        return path

    # ------------------------------------------------------ ffmpeg input args
    def ffmpeg_input_args(self) -> Optional[List[str]]:
        """Input arguments for recording/timelapse, matching the active source."""
        if self.config.stream_url:
            return [
                "-use_wallclock_as_timestamps", "1",
                "-f", "mjpeg",
                "-i", self.config.stream_url,
            ]
        if self.config.device:
            return [
                "-f", "v4l2",
                "-framerate", str(self.config.fps),
                "-video_size", f"{self.config.width}x{self.config.height}",
                "-i", self.config.device,
            ]
        return None

    @property
    def last_error(self) -> str:
        return self._last_error
