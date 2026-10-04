"""Slicing profile store.

PrusaSlicer profiles are plain ``key = value`` ini files (no sections), which is
exactly what ``prusa-slicer --load`` expects. OrcaSlicer profiles are JSON and
live in ``profiles/orca``.

A profile may carry human metadata in leading comments::

    # name: Neptune 3 Plus - 0.4 nozzle
    # description: Stock Elegoo Neptune 3 Plus running Klipper
"""

from __future__ import annotations

import json
import logging
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional

log = logging.getLogger("neptune.slicer.profiles")

KINDS = ("printer", "filament", "print")
META_RE = re.compile(r"^#\s*(name|description)\s*:\s*(.+)$", re.IGNORECASE)


@dataclass
class Profile:
    id: str
    kind: str
    path: Path
    name: str
    description: str
    values: Dict[str, str]

    @property
    def is_json(self) -> bool:
        return self.path.suffix.lower() == ".json"


def parse_ini(text: str) -> tuple[Dict[str, str], str, str]:
    values: Dict[str, str] = {}
    name = ""
    description = ""
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if line.startswith("#") or line.startswith(";"):
            match = META_RE.match(line)
            if match:
                key = match.group(1).lower()
                if key == "name":
                    name = match.group(2).strip()
                else:
                    description = match.group(2).strip()
            continue
        if line.startswith("[") and line.endswith("]"):
            continue
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip()
    return values, name, description


class ProfileStore:
    def __init__(self, root: Path) -> None:
        self.root = Path(root)

    # ------------------------------------------------------------------ load
    def _load_file(self, path: Path, kind: str) -> Optional[Profile]:
        try:
            if path.suffix.lower() == ".json":
                data = json.loads(path.read_text(encoding="utf-8"))
                if not isinstance(data, dict):
                    return None
                values = {str(k): _stringify(v) for k, v in data.items()}
                name = str(data.get("name") or path.stem)
                description = str(data.get("description") or "")
            else:
                values, name, description = parse_ini(path.read_text(encoding="utf-8"))
                name = name or values.get("printer_settings_id") or path.stem
        except (OSError, ValueError) as exc:
            log.warning("Skipping unreadable profile %s: %s", path, exc)
            return None
        return Profile(
            id=path.stem,
            kind=kind,
            path=path,
            name=name,
            description=description,
            values=values,
        )

    def list(self, kind: str) -> List[Profile]:
        directory = self.root / kind
        if not directory.is_dir():
            return []
        profiles: List[Profile] = []
        for path in sorted(directory.iterdir()):
            if path.suffix.lower() not in {".ini", ".json"}:
                continue
            profile = self._load_file(path, kind)
            if profile is not None:
                profiles.append(profile)
        return profiles

    def get(self, kind: str, profile_id: str) -> Optional[Profile]:
        if kind not in KINDS and kind != "orca":
            return None
        directory = self.root / kind
        for suffix in (".ini", ".json"):
            candidate = directory / f"{profile_id}{suffix}"
            if candidate.is_file():
                return self._load_file(candidate, kind)
        return None

    def require(self, kind: str, profile_id: str) -> Profile:
        profile = self.get(kind, profile_id)
        if profile is None:
            available = ", ".join(p.id for p in self.list(kind)) or "none"
            raise FileNotFoundError(
                f"{kind} profile '{profile_id}' not found in {self.root / kind} (available: {available})"
            )
        return profile

    def all(self) -> Dict[str, List[Profile]]:
        return {kind: self.list(kind) for kind in KINDS}

    # --------------------------------------------------------------- helpers
    def orca_profile(self, kind: str, profile_id: str) -> Optional[Profile]:
        """Orca JSON profiles live in profiles/orca/<kind>/<id>.json."""
        path = self.root / "orca" / kind / f"{profile_id}.json"
        if not path.is_file():
            return None
        return self._load_file(path, kind)


def _stringify(value: object) -> str:
    if isinstance(value, bool):
        return "1" if value else "0"
    if isinstance(value, (list, tuple)):
        return ",".join(str(v) for v in value)
    return str(value)
