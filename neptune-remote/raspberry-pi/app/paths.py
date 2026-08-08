"""Storage layout for Neptune Remote.

Everything the backend writes lives under one root, by default:

    ~/printer_data/neptune_remote/

That directory sits beside Klipper's own ``printer_data`` folders but is
completely separate: nothing here ever touches ``config/printer.cfg``,
``gcodes/`` or anything else Klipper, Moonraker or Mainsail own.

    models/       uploaded STL / 3MF / OBJ
    thumbnails/   generated PNG previews and hero images
    gcode/        G-code produced by the on-Pi slicer
    videos/       print recordings, organised YYYY/MM/DD
    timelapses/   rendered timelapse MP4s
    snapshots/    still images (manual + AI events + completion photos)
    ai_events/    frames that triggered a vision detection
    database/     SQLite databases
    backups/      configuration backups (zip)
    cache/        scratch space, safe to delete
"""

from __future__ import annotations

import os
import shutil
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Dict, Iterable

SUBDIRECTORIES = (
    "models",
    "thumbnails",
    "gcode",
    "videos",
    "timelapses",
    "snapshots",
    "ai_events",
    "database",
    "backups",
    "cache",
)


def expand(path: str | Path) -> Path:
    return Path(os.path.expandvars(str(path))).expanduser()


@dataclass
class StorageLayout:
    """Resolved, created-on-demand storage tree."""

    root: Path

    @classmethod
    def create(cls, root: str | Path) -> "StorageLayout":
        layout = cls(root=expand(root))
        layout.ensure()
        return layout

    def ensure(self) -> None:
        self.root.mkdir(parents=True, exist_ok=True)
        for name in SUBDIRECTORIES:
            (self.root / name).mkdir(parents=True, exist_ok=True)

    # ----------------------------------------------------------- directories
    @property
    def models(self) -> Path:
        return self.root / "models"

    @property
    def thumbnails(self) -> Path:
        return self.root / "thumbnails"

    @property
    def gcode(self) -> Path:
        return self.root / "gcode"

    @property
    def videos(self) -> Path:
        return self.root / "videos"

    @property
    def timelapses(self) -> Path:
        return self.root / "timelapses"

    @property
    def snapshots(self) -> Path:
        return self.root / "snapshots"

    @property
    def ai_events(self) -> Path:
        return self.root / "ai_events"

    @property
    def database(self) -> Path:
        return self.root / "database"

    @property
    def backups(self) -> Path:
        return self.root / "backups"

    @property
    def cache(self) -> Path:
        return self.root / "cache"

    # ---------------------------------------------------------------- helpers
    def dated_video_dir(self, when: datetime | None = None) -> Path:
        """videos/YYYY/MM/DD, created on demand."""
        stamp = when or datetime.now()
        directory = self.videos / f"{stamp:%Y}" / f"{stamp:%m}" / f"{stamp:%d}"
        directory.mkdir(parents=True, exist_ok=True)
        return directory

    def relative(self, path: Path) -> str:
        """Path relative to the root, used as a stable id in the API."""
        try:
            return str(Path(path).resolve().relative_to(self.root.resolve()))
        except ValueError:
            return str(path)

    def resolve(self, relative_path: str) -> Path:
        """Resolve an API-supplied relative path, refusing directory escapes."""
        candidate = (self.root / relative_path).resolve()
        root = self.root.resolve()
        if candidate != root and root not in candidate.parents:
            raise ValueError(f"Path escapes the storage root: {relative_path}")
        return candidate

    def usage(self) -> Dict[str, float]:
        """Bytes used per subdirectory plus free space on the volume."""
        result: Dict[str, float] = {}
        for name in SUBDIRECTORIES:
            result[name] = directory_size(self.root / name)
        result["total"] = sum(result[name] for name in SUBDIRECTORIES)
        try:
            usage = shutil.disk_usage(self.root)
            result["disk_total"] = float(usage.total)
            result["disk_free"] = float(usage.free)
        except OSError:
            result["disk_total"] = 0.0
            result["disk_free"] = 0.0
        return result


def directory_size(path: Path) -> float:
    total = 0.0
    if not path.is_dir():
        return total
    for entry in path.rglob("*"):
        try:
            if entry.is_file():
                total += entry.stat().st_size
        except OSError:
            continue
    return total


def newest_first(paths: Iterable[Path]) -> list[Path]:
    def stamp(path: Path) -> float:
        try:
            return path.stat().st_mtime
        except OSError:
            return 0.0

    return sorted(paths, key=stamp, reverse=True)
