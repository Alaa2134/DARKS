"""The Golden Slicer Profile registry.

A profile earns "Golden" once it has completed test prints without positional
problems. From then on it is pinned: editing it never overwrites it, it creates
a new version beside it. That is the whole point - the known-good profile is
protected from convenience.
"""

from __future__ import annotations

import hashlib
import json
import time
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

from ..db import Database

SCHEMA = """
CREATE TABLE IF NOT EXISTS slicer_profiles (
    id            TEXT PRIMARY KEY,
    name          TEXT NOT NULL,
    version       INTEGER NOT NULL DEFAULT 1,
    parent_id     TEXT,
    engine        TEXT NOT NULL DEFAULT 'prusaslicer',
    printer_model TEXT NOT NULL DEFAULT 'neptune3plus',
    settings      TEXT NOT NULL DEFAULT '{}',
    sha256        TEXT NOT NULL DEFAULT '',
    golden        INTEGER NOT NULL DEFAULT 0,
    successful_prints INTEGER NOT NULL DEFAULT 0,
    failed_prints INTEGER NOT NULL DEFAULT 0,
    created_at    REAL NOT NULL,
    promoted_at   REAL,
    note          TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_slicer_profiles_name ON slicer_profiles(name, version DESC);
"""


@dataclass
class SlicerProfile:
    id: str
    name: str
    version: int
    engine: str
    printer_model: str
    settings: Dict[str, Any]
    sha256: str
    golden: bool
    successful_prints: int
    failed_prints: int
    created_at: float
    promoted_at: Optional[float] = None
    parent_id: Optional[str] = None
    note: str = ""

    @property
    def status(self) -> str:
        return "golden" if self.golden else "candidate"

    @property
    def display_name(self) -> str:
        return f"{self.name} v{self.version}"

    def as_dict(self) -> Dict[str, Any]:
        return {
            "id": self.id,
            "name": self.name,
            "display_name": self.display_name,
            "version": self.version,
            "parent_id": self.parent_id,
            "engine": self.engine,
            "printer_model": self.printer_model,
            "settings": self.settings,
            "sha256": self.sha256,
            "golden": self.golden,
            "status": self.status,
            "successful_prints": self.successful_prints,
            "failed_prints": self.failed_prints,
            "created_at": self.created_at,
            "promoted_at": self.promoted_at,
            "note": self.note,
        }


class GoldenProfileStore:
    def __init__(self, db: Database) -> None:
        self.db = db
        self.db.executescript(SCHEMA)

    # ------------------------------------------------------------- writing
    def save(
        self,
        name: str,
        settings: Dict[str, Any],
        *,
        engine: str = "prusaslicer",
        printer_model: str = "neptune3plus",
        note: str = "",
    ) -> SlicerProfile:
        """Store a profile. A name that already exists creates the next version;
        it never modifies the existing row, Golden or not."""
        payload = json.dumps(settings, sort_keys=True, ensure_ascii=False)
        digest = hashlib.sha256(payload.encode("utf-8")).hexdigest()

        rows = self.db.query(
            "SELECT id, version, sha256 FROM slicer_profiles WHERE name = ? "
            "ORDER BY version DESC LIMIT 1",
            (name,),
        )
        if rows and rows[0]["sha256"] == digest:
            existing = self.get(rows[0]["id"])
            if existing is not None:
                return existing

        version = (rows[0]["version"] + 1) if rows else 1
        parent_id = rows[0]["id"] if rows else None
        profile_id = f"{hashlib.sha1(name.encode()).hexdigest()[:8]}-v{version}"

        self.db.execute(
            """
            INSERT INTO slicer_profiles
                (id, name, version, parent_id, engine, printer_model, settings,
                 sha256, golden, successful_prints, failed_prints, created_at, note)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, 0, 0, ?, ?)
            """,
            (
                profile_id, name, version, parent_id, engine, printer_model,
                payload, digest, time.time(), note,
            ),
        )
        result = self.get(profile_id)
        assert result is not None
        return result

    def mark_golden(self, profile_id: str) -> Optional[SlicerProfile]:
        """Pin one version of one profile name as known-good."""
        profile = self.get(profile_id)
        if profile is None:
            return None
        # Golden is per profile *name*: a new Golden replaces the old one for
        # that name, and leaves other profiles alone.
        self.db.execute("UPDATE slicer_profiles SET golden = 0 WHERE name = ?", (profile.name,))
        self.db.execute(
            "UPDATE slicer_profiles SET golden = 1, promoted_at = ? WHERE id = ?",
            (time.time(), profile_id),
        )
        return self.get(profile_id)

    def clear_golden(self, profile_id: str) -> Optional[SlicerProfile]:
        self.db.execute(
            "UPDATE slicer_profiles SET golden = 0, promoted_at = NULL WHERE id = ?",
            (profile_id,),
        )
        return self.get(profile_id)

    def record_print(self, profile_id: str, *, success: bool) -> Optional[SlicerProfile]:
        column = "successful_prints" if success else "failed_prints"
        self.db.execute(
            f"UPDATE slicer_profiles SET {column} = {column} + 1 WHERE id = ?",
            (profile_id,),
        )
        return self.get(profile_id)

    def delete(self, profile_id: str) -> bool:
        """Golden profiles cannot be deleted - that is what pinning means."""
        profile = self.get(profile_id)
        if profile is None or profile.golden:
            return False
        self.db.execute("DELETE FROM slicer_profiles WHERE id = ?", (profile_id,))
        return True

    # ------------------------------------------------------------- reading
    def _row(self, row: Any) -> SlicerProfile:
        try:
            settings = json.loads(row["settings"])
        except (TypeError, ValueError):
            settings = {}
        return SlicerProfile(
            id=row["id"],
            name=row["name"],
            version=row["version"],
            parent_id=row["parent_id"],
            engine=row["engine"],
            printer_model=row["printer_model"],
            settings=settings,
            sha256=row["sha256"],
            golden=bool(row["golden"]),
            successful_prints=row["successful_prints"],
            failed_prints=row["failed_prints"],
            created_at=row["created_at"],
            promoted_at=row["promoted_at"],
            note=row["note"],
        )

    def get(self, profile_id: str) -> Optional[SlicerProfile]:
        rows = self.db.query("SELECT * FROM slicer_profiles WHERE id = ?", (profile_id,))
        return self._row(rows[0]) if rows else None

    def list(self) -> List[SlicerProfile]:
        rows = self.db.query(
            "SELECT * FROM slicer_profiles ORDER BY golden DESC, name ASC, version DESC"
        )
        return [self._row(row) for row in rows]

    def golden_profiles(self) -> List[SlicerProfile]:
        rows = self.db.query("SELECT * FROM slicer_profiles WHERE golden = 1")
        return [self._row(row) for row in rows]

    def golden_names(self) -> List[str]:
        """Names the G-code validator compares ``print_settings_id`` against."""
        return [p.name for p in self.golden_profiles()]

    def find_by_name(self, name: str) -> Optional[SlicerProfile]:
        rows = self.db.query(
            "SELECT * FROM slicer_profiles WHERE name = ? ORDER BY golden DESC, version DESC LIMIT 1",
            (name,),
        )
        return self._row(rows[0]) if rows else None

    def versions_of(self, name: str) -> List[SlicerProfile]:
        rows = self.db.query(
            "SELECT * FROM slicer_profiles WHERE name = ? ORDER BY version DESC", (name,)
        )
        return [self._row(row) for row in rows]
