"""Versioned ``printer.cfg`` history: backup, name, diff, roll back.

Two rules shape this module:

* **Every modification is preceded by a backup.** The safety engine requests one
  before SAVE_CONFIG; the config editor takes one before writing.
* **A known-good config is never overwritten.** Marking a version "Golden"
  pins it; later saves create new versions beside it.
"""

from __future__ import annotations

import hashlib
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional

from ..db import Database
from .model import parse_config
from .validator import diff_configs

MAX_VERSIONS = 60


@dataclass
class ConfigVersion:
    id: str
    created_at: float
    label: str
    reason: str                    # manual | pre_save_config | pre_edit | imported | auto
    size_bytes: int
    sha256: str
    golden: bool = False
    #: Set when a print completed successfully while this version was active.
    proven_prints: int = 0
    last_proven_at: Optional[float] = None
    note: str = ""
    section_count: int = 0
    validation: Dict[str, Any] = field(default_factory=dict)

    def as_dict(self) -> Dict[str, Any]:
        return {
            "id": self.id,
            "created_at": self.created_at,
            "label": self.label,
            "reason": self.reason,
            "size_bytes": self.size_bytes,
            "sha256": self.sha256,
            "golden": self.golden,
            "proven_prints": self.proven_prints,
            "last_proven_at": self.last_proven_at,
            "note": self.note,
            "section_count": self.section_count,
            "validation": self.validation,
        }


SCHEMA = """
CREATE TABLE IF NOT EXISTS config_versions (
    id            TEXT PRIMARY KEY,
    created_at    REAL NOT NULL,
    label         TEXT NOT NULL DEFAULT '',
    reason        TEXT NOT NULL DEFAULT 'manual',
    size_bytes    INTEGER NOT NULL DEFAULT 0,
    sha256        TEXT NOT NULL DEFAULT '',
    golden        INTEGER NOT NULL DEFAULT 0,
    proven_prints INTEGER NOT NULL DEFAULT 0,
    last_proven_at REAL,
    note          TEXT NOT NULL DEFAULT '',
    section_count INTEGER NOT NULL DEFAULT 0,
    path          TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_config_versions_created ON config_versions(created_at DESC);
"""


class ConfigStore:
    """Stores config snapshots on disk with their metadata in SQLite."""

    def __init__(self, db: Database, directory: Path) -> None:
        self.db = db
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True)
        self.db.executescript(SCHEMA)

    # ------------------------------------------------------------- writing
    def snapshot(
        self,
        text: str,
        *,
        label: str = "",
        reason: str = "manual",
        note: str = "",
    ) -> ConfigVersion:
        """Store ``text`` as a new version.

        Identical consecutive content is not duplicated: re-snapshotting an
        unchanged config returns the existing newest version, so a burst of
        SAVE_CONFIG calls does not bury the history.
        """
        digest = hashlib.sha256(text.encode("utf-8")).hexdigest()
        newest = self.latest()
        if newest is not None and newest.sha256 == digest and not label:
            return newest

        version_id = f"{int(time.time() * 1000):x}-{digest[:8]}"
        path = self.directory / f"{version_id}.cfg"
        path.write_text(text, encoding="utf-8")

        parsed = parse_config(text)
        from .validator import NEPTUNE_3_PLUS, validate

        report = validate(parsed, profile=NEPTUNE_3_PLUS)

        version = ConfigVersion(
            id=version_id,
            created_at=time.time(),
            label=label,
            reason=reason,
            size_bytes=len(text.encode("utf-8")),
            sha256=digest,
            note=note,
            section_count=len(parsed.sections),
            validation={
                "verdict": report.verdict,
                "error_count": len(report.errors),
                "warning_count": len(report.warnings),
            },
        )
        self.db.execute(
            """
            INSERT INTO config_versions
                (id, created_at, label, reason, size_bytes, sha256, golden,
                 proven_prints, last_proven_at, note, section_count, path)
            VALUES (?, ?, ?, ?, ?, ?, 0, 0, NULL, ?, ?, ?)
            """,
            (
                version.id,
                version.created_at,
                version.label,
                version.reason,
                version.size_bytes,
                version.sha256,
                version.note,
                version.section_count,
                str(path),
            ),
        )
        self._prune()
        return version

    def _prune(self) -> None:
        """Drop the oldest versions past the cap - but never a Golden one, and
        never one that has proven prints behind it."""
        rows = self.db.query(
            "SELECT id, path FROM config_versions "
            "WHERE golden = 0 AND proven_prints = 0 "
            "ORDER BY created_at DESC"
        )
        for row in rows[MAX_VERSIONS:]:
            Path(row["path"]).unlink(missing_ok=True)
            self.db.execute("DELETE FROM config_versions WHERE id = ?", (row["id"],))

    # ------------------------------------------------------------- reading
    def _row_to_version(self, row: Dict[str, Any]) -> ConfigVersion:
        return ConfigVersion(
            id=row["id"],
            created_at=row["created_at"],
            label=row["label"],
            reason=row["reason"],
            size_bytes=row["size_bytes"],
            sha256=row["sha256"],
            golden=bool(row["golden"]),
            proven_prints=row["proven_prints"],
            last_proven_at=row["last_proven_at"],
            note=row["note"],
            section_count=row["section_count"],
        )

    def list(self, limit: int = 100) -> List[ConfigVersion]:
        rows = self.db.query(
            "SELECT * FROM config_versions ORDER BY created_at DESC LIMIT ?", (limit,)
        )
        return [self._row_to_version(row) for row in rows]

    def get(self, version_id: str) -> Optional[ConfigVersion]:
        rows = self.db.query("SELECT * FROM config_versions WHERE id = ?", (version_id,))
        return self._row_to_version(rows[0]) if rows else None

    def text(self, version_id: str) -> Optional[str]:
        rows = self.db.query("SELECT path FROM config_versions WHERE id = ?", (version_id,))
        if not rows:
            return None
        path = Path(rows[0]["path"])
        return path.read_text(encoding="utf-8") if path.is_file() else None

    def latest(self) -> Optional[ConfigVersion]:
        rows = self.db.query("SELECT * FROM config_versions ORDER BY created_at DESC LIMIT 1")
        return self._row_to_version(rows[0]) if rows else None

    def golden(self) -> Optional[ConfigVersion]:
        rows = self.db.query(
            "SELECT * FROM config_versions WHERE golden = 1 ORDER BY created_at DESC LIMIT 1"
        )
        return self._row_to_version(rows[0]) if rows else None

    def last_known_good(self) -> Optional[ConfigVersion]:
        """The Golden config if one is pinned, otherwise the most recent version
        that a print actually completed on, otherwise nothing.

        Deliberately does **not** fall back to "the newest version": the newest
        one may be exactly what broke the printer.
        """
        pinned = self.golden()
        if pinned is not None:
            return pinned
        rows = self.db.query(
            "SELECT * FROM config_versions WHERE proven_prints > 0 "
            "ORDER BY last_proven_at DESC LIMIT 1"
        )
        return self._row_to_version(rows[0]) if rows else None

    # ------------------------------------------------------------ labelling
    def set_label(self, version_id: str, label: str, note: str = "") -> Optional[ConfigVersion]:
        self.db.execute(
            "UPDATE config_versions SET label = ?, note = ? WHERE id = ?",
            (label, note, version_id),
        )
        return self.get(version_id)

    def mark_golden(self, version_id: str) -> Optional[ConfigVersion]:
        """Pin one version as the known-good config. Only one at a time."""
        if self.get(version_id) is None:
            return None
        self.db.execute("UPDATE config_versions SET golden = 0")
        self.db.execute("UPDATE config_versions SET golden = 1 WHERE id = ?", (version_id,))
        version = self.get(version_id)
        if version is not None and not version.label:
            return self.set_label(version_id, "Golden Config")
        return version

    def clear_golden(self) -> None:
        self.db.execute("UPDATE config_versions SET golden = 0")

    def record_successful_print(self, sha256: str) -> Optional[ConfigVersion]:
        """Credit whichever version was active when a print completed."""
        rows = self.db.query(
            "SELECT id FROM config_versions WHERE sha256 = ? ORDER BY created_at DESC LIMIT 1",
            (sha256,),
        )
        if not rows:
            return None
        self.db.execute(
            "UPDATE config_versions SET proven_prints = proven_prints + 1, last_proven_at = ? "
            "WHERE id = ?",
            (time.time(), rows[0]["id"]),
        )
        return self.get(rows[0]["id"])

    def delete(self, version_id: str) -> bool:
        version = self.get(version_id)
        if version is None or version.golden:
            return False
        rows = self.db.query("SELECT path FROM config_versions WHERE id = ?", (version_id,))
        if rows:
            Path(rows[0]["path"]).unlink(missing_ok=True)
        self.db.execute("DELETE FROM config_versions WHERE id = ?", (version_id,))
        return True

    # ----------------------------------------------------------------- diff
    def diff(self, from_id: str, to_id: str) -> Optional[Dict[str, Any]]:
        before, after = self.text(from_id), self.text(to_id)
        if before is None or after is None:
            return None
        return diff_configs(before, after)

    def diff_against(self, version_id: str, current_text: str) -> Optional[Dict[str, Any]]:
        stored = self.text(version_id)
        if stored is None:
            return None
        return diff_configs(stored, current_text)

    def matches(self, version_id: str, text: str) -> bool:
        version = self.get(version_id)
        if version is None:
            return False
        return version.sha256 == hashlib.sha256(text.encode("utf-8")).hexdigest()
