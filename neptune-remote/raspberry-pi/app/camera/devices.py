"""USB (UVC) camera discovery on Raspberry Pi OS / Debian.

Uses ``v4l2-ctl`` when it is installed (package ``v4l-utils``) and degrades to
listing ``/dev/video*`` nodes otherwise. Nothing here modifies system config.
"""

from __future__ import annotations

import logging
import re
import shutil
import subprocess
from dataclasses import dataclass, field
from pathlib import Path
from typing import List, Optional

log = logging.getLogger("neptune.camera.devices")

# Resolutions worth recommending for print monitoring: high enough to see a
# failure, low enough that a Pi can encode them while Klipper is printing.
PREFERRED_MODES = [
    (1280, 720, 15),
    (1280, 720, 30),
    (1024, 576, 15),
    (800, 600, 15),
    (640, 480, 30),
]


@dataclass
class CameraMode:
    width: int
    height: int
    fps: float
    pixel_format: str = ""

    @property
    def label(self) -> str:
        return f"{self.width}x{self.height} @ {self.fps:g} fps"


@dataclass
class CameraDevice:
    path: str
    name: str = ""
    driver: str = ""
    bus: str = ""
    is_capture: bool = True
    modes: List[CameraMode] = field(default_factory=list)

    @property
    def index(self) -> Optional[int]:
        match = re.search(r"(\d+)$", self.path)
        return int(match.group(1)) if match else None

    def recommended_mode(self) -> Optional[CameraMode]:
        if not self.modes:
            return None
        for width, height, fps in PREFERRED_MODES:
            for mode in self.modes:
                if mode.width == width and mode.height == height and abs(mode.fps - fps) < 1.5:
                    return mode
        # Otherwise the largest mode not exceeding 1920x1080.
        usable = [mode for mode in self.modes if mode.width <= 1920 and mode.height <= 1080]
        pool = usable or self.modes
        return max(pool, key=lambda mode: (mode.width * mode.height, mode.fps))


def _run(command: List[str], timeout: float = 6.0) -> str:
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return ""
    return result.stdout or ""


def has_v4l2() -> bool:
    return shutil.which("v4l2-ctl") is not None


def list_video_nodes() -> List[str]:
    directory = Path("/dev")
    if not directory.is_dir():
        return []
    nodes = sorted(
        (str(path) for path in directory.glob("video*")),
        key=lambda value: int(re.search(r"(\d+)$", value).group(1)) if re.search(r"(\d+)$", value) else 0,
    )
    return nodes


def _parse_modes(output: str) -> List[CameraMode]:
    """Parse ``v4l2-ctl --list-formats-ext`` output."""
    modes: List[CameraMode] = []
    pixel_format = ""
    size: Optional[tuple[int, int]] = None

    for raw_line in output.splitlines():
        line = raw_line.strip()
        format_match = re.match(r"\[\d+\]:\s*'(\w+)'", line)
        if format_match:
            pixel_format = format_match.group(1)
            continue
        size_match = re.match(r"Size:\s*Discrete\s*(\d+)x(\d+)", line)
        if size_match:
            size = (int(size_match.group(1)), int(size_match.group(2)))
            continue
        fps_match = re.search(r"\(([\d.]+)\s*fps\)", line)
        if fps_match and size is not None:
            modes.append(
                CameraMode(
                    width=size[0], height=size[1],
                    fps=float(fps_match.group(1)), pixel_format=pixel_format,
                )
            )
    # De-duplicate while keeping order.
    seen = set()
    unique: List[CameraMode] = []
    for mode in modes:
        key = (mode.width, mode.height, round(mode.fps, 1), mode.pixel_format)
        if key in seen:
            continue
        seen.add(key)
        unique.append(mode)
    return unique


def describe(path: str) -> CameraDevice:
    device = CameraDevice(path=path)
    if not has_v4l2():
        device.name = Path(path).name
        return device

    info = _run(["v4l2-ctl", "-d", path, "--info"])
    for line in info.splitlines():
        stripped = line.strip()
        if stripped.startswith("Card type"):
            device.name = stripped.split(":", 1)[-1].strip()
        elif stripped.startswith("Driver name"):
            device.driver = stripped.split(":", 1)[-1].strip()
        elif stripped.startswith("Bus info"):
            device.bus = stripped.split(":", 1)[-1].strip()
    device.is_capture = "Video Capture" in info or not info

    device.modes = _parse_modes(_run(["v4l2-ctl", "-d", path, "--list-formats-ext"]))
    if not device.name:
        device.name = Path(path).name
    return device


def discover() -> List[CameraDevice]:
    """All capture-capable video nodes, best first.

    On the Pi every physical camera exposes several /dev/videoN nodes; only the
    ones that actually report video-capture formats are returned.
    """
    devices: List[CameraDevice] = []
    for node in list_video_nodes():
        device = describe(node)
        if has_v4l2() and not device.modes and not device.is_capture:
            continue
        devices.append(device)

    # Devices with real modes first, then by node number.
    devices.sort(key=lambda item: (0 if item.modes else 1, item.index if item.index is not None else 99))
    return devices


def first_camera() -> Optional[CameraDevice]:
    devices = discover()
    return devices[0] if devices else None
