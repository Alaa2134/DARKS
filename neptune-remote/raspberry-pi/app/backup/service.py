"""Read-only configuration backups.

The service copies files into a zip archive. It never writes to, moves or
deletes printer.cfg, moonraker.conf or anything else Klipper owns, and it
redacts secrets from its own configuration before adding it.
"""

from __future__ import annotations

import io
import logging
import re
import time
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional

import yaml

from ..config import AppConfig
from ..paths import StorageLayout, expand

log = logging.getLogger("neptune.backup")

# Keys whose values are removed before the config is written into a backup.
SECRET_KEYS = {
    "access_secret", "access_id", "device_id", "api_token", "api_key",
    "password", "token", "secret",
}

REDACTED = "***REDACTED***"


@dataclass
class BackupInfo:
    filename: str
    path: str
    size_bytes: int
    created_at: float
    contents: List[str]

    def as_dict(self) -> Dict[str, Any]:
        return {
            "filename": self.filename,
            "path": self.path,
            "size_bytes": self.size_bytes,
            "created_at": self.created_at,
            "contents": self.contents,
        }


def redact(value: Any) -> Any:
    if isinstance(value, dict):
        return {
            key: (REDACTED if key.lower() in SECRET_KEYS and value.get(key) else redact(item))
            for key, item in value.items()
        }
    if isinstance(value, list):
        return [redact(item) for item in value]
    return value


class BackupService:
    def __init__(self, config: AppConfig, layout: StorageLayout) -> None:
        self.config = config
        self.layout = layout

    # --------------------------------------------------------------- create
    def create(self, *, include_profiles: bool = True) -> BackupInfo:
        stamp = time.strftime("%Y%m%d-%H%M%S")
        filename = f"neptune-backup-{stamp}.zip"
        path = self.layout.backups / filename
        contents: List[str] = []

        with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            # 1. Klipper / Moonraker configuration (read only).
            for source in self.config.storage.backup_sources:
                candidate = expand(source)
                if candidate.is_file():
                    arcname = f"printer_config/{candidate.name}"
                    archive.write(candidate, arcname)
                    contents.append(arcname)
                elif candidate.is_dir():
                    for child in sorted(candidate.rglob("*")):
                        if child.is_file() and child.suffix in {".cfg", ".conf"}:
                            arcname = f"printer_config/{child.relative_to(candidate.parent)}"
                            archive.write(child, arcname)
                            contents.append(arcname)

            # 2. Neptune Remote configuration, with secrets stripped.
            redacted = redact(self.config.model_dump(exclude={"source_path"}))
            archive.writestr(
                "neptune_remote/config.redacted.yaml",
                yaml.safe_dump(redacted, allow_unicode=True, sort_keys=False),
            )
            contents.append("neptune_remote/config.redacted.yaml")

            # 3. Slicing profiles.
            if include_profiles:
                profiles_dir = self.config.paths.resolved()["profiles_dir"]
                if profiles_dir.is_dir():
                    for child in sorted(profiles_dir.rglob("*")):
                        if child.is_file() and child.suffix in {".ini", ".json"}:
                            arcname = f"profiles/{child.relative_to(profiles_dir)}"
                            archive.write(child, arcname)
                            contents.append(arcname)

            # 4. The application database (library, filament, products ...).
            database = self.layout.database / "neptune.db"
            if database.is_file():
                archive.write(database, "neptune_remote/neptune.db")
                contents.append("neptune_remote/neptune.db")

            archive.writestr(
                "README.txt",
                "Neptune 3 Plus Remote backup\n"
                f"Created: {time.strftime('%Y-%m-%d %H:%M:%S')}\n\n"
                "printer_config/  copies of your Klipper/Moonraker config (read only)\n"
                "profiles/        slicing profiles\n"
                "neptune_remote/  app database and a redacted copy of config.yaml\n\n"
                "Secrets (Tuya credentials, API tokens) are NOT included.\n",
            )
            contents.append("README.txt")

        self._prune()
        stat = path.stat()
        return BackupInfo(
            filename=filename,
            path=self.layout.relative(path),
            size_bytes=stat.st_size,
            created_at=stat.st_mtime,
            contents=contents,
        )

    # ----------------------------------------------------------------- list
    def list(self) -> List[BackupInfo]:
        result: List[BackupInfo] = []
        for path in sorted(self.layout.backups.glob("*.zip"), key=lambda item: item.stat().st_mtime, reverse=True):
            try:
                with zipfile.ZipFile(path) as archive:
                    contents = archive.namelist()
            except zipfile.BadZipFile:
                contents = []
            stat = path.stat()
            result.append(
                BackupInfo(
                    filename=path.name,
                    path=self.layout.relative(path),
                    size_bytes=stat.st_size,
                    created_at=stat.st_mtime,
                    contents=contents,
                )
            )
        return result

    def get(self, filename: str) -> Optional[Path]:
        path = self.layout.backups / Path(filename).name
        return path if path.is_file() else None

    def delete(self, filename: str) -> bool:
        path = self.get(filename)
        if path is None:
            return False
        path.unlink()
        return True

    def _prune(self) -> None:
        backups = sorted(
            self.layout.backups.glob("*.zip"), key=lambda item: item.stat().st_mtime, reverse=True
        )
        for path in backups[self.config.storage.max_backups:]:
            path.unlink(missing_ok=True)
