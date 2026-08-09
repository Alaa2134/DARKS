"""Local file storage (uploaded models, sliced G-code) and the SQLite history DB."""

from __future__ import annotations

import re
import sqlite3
import threading
import time
import uuid
from pathlib import Path
from typing import Any, Dict, List, Optional

from .schemas import HistoryEntry, HistoryStats, ModelFile

SAFE_NAME_RE = re.compile(r"[^A-Za-z0-9._؀-ۿ-]+")
ID_SEPARATOR = "__"


def safe_filename(name: str, fallback: str = "model") -> str:
    """Strip path components and dangerous characters, keep Arabic letters."""
    name = Path(name).name
    cleaned = SAFE_NAME_RE.sub("_", name).strip("._")
    cleaned = cleaned.replace(ID_SEPARATOR, "_")
    return cleaned or fallback


# --------------------------------------------------------------------------- #
# Model store
# --------------------------------------------------------------------------- #


class ModelStore:
    """Uploaded 3D models. Files are stored as ``<id>__<original name>``.

    ``extra_directories`` are searched by :meth:`path_for` / :meth:`get` but
    never listed or written to. The library keeps its models in its own folder
    using the same ``<id>__<name>`` convention, so registering it here makes a
    library item directly sliceable by its own id - no copy, no second upload.
    """

    def __init__(self, directory: Path, extra_directories: Optional[List[Path]] = None) -> None:
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True)
        self.extra_directories: List[Path] = [Path(p) for p in (extra_directories or [])]

    def save(self, filename: str, content: bytes) -> ModelFile:
        clean = safe_filename(filename)
        model_id = uuid.uuid4().hex[:12]
        path = self.directory / f"{model_id}{ID_SEPARATOR}{clean}"
        path.write_bytes(content)
        return self._describe(path)

    def _describe(self, path: Path) -> ModelFile:
        model_id, _, original = path.name.partition(ID_SEPARATOR)
        stat = path.stat()
        return ModelFile(
            id=model_id,
            filename=original or path.name,
            size=stat.st_size,
            modified=stat.st_mtime,
            extension=path.suffix.lower(),
        )

    def path_for(self, model_id: str) -> Optional[Path]:
        for directory in [self.directory, *self.extra_directories]:
            if not directory.is_dir():
                continue
            for path in directory.iterdir():
                if not path.is_file():
                    continue
                if path.name.split(ID_SEPARATOR, 1)[0] == model_id:
                    return path
        return None

    def get(self, model_id: str) -> Optional[ModelFile]:
        path = self.path_for(model_id)
        return self._describe(path) if path else None

    def list(self) -> List[ModelFile]:
        if not self.directory.is_dir():
            return []
        models = [self._describe(p) for p in self.directory.iterdir() if p.is_file()]
        models.sort(key=lambda m: m.modified, reverse=True)
        return models

    def delete(self, model_id: str) -> bool:
        """Only deletes from the store's own directory - library models are
        owned by the library and are removed through it."""
        path = self.path_for(model_id)
        if path is None or path.parent != self.directory:
            return False
        path.unlink(missing_ok=True)
        return True


# --------------------------------------------------------------------------- #
# Local G-code store (output of the slicer)
# --------------------------------------------------------------------------- #


class GCodeStore:
    def __init__(self, directory: Path) -> None:
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True)

    def path_for(self, name: str) -> Path:
        return self.directory / safe_filename(name, "output.gcode")

    def unique_path(self, name: str) -> Path:
        base = self.path_for(name)
        if not base.exists():
            return base
        stem = base.stem
        suffix = base.suffix or ".gcode"
        return base.with_name(f"{stem}_{int(time.time())}{suffix}")

    def list(self) -> List[Path]:
        if not self.directory.is_dir():
            return []
        files = [p for p in self.directory.iterdir() if p.is_file() and p.suffix.lower() in {".gcode", ".gco", ".g"}]
        files.sort(key=lambda p: p.stat().st_mtime, reverse=True)
        return files

    def delete(self, name: str) -> bool:
        path = self.path_for(name)
        if path.is_file():
            path.unlink()
            return True
        return False


# --------------------------------------------------------------------------- #
# History database
# --------------------------------------------------------------------------- #

SCHEMA = """
CREATE TABLE IF NOT EXISTS print_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    filename TEXT NOT NULL,
    start_time REAL NOT NULL,
    finish_time REAL,
    duration REAL,
    result TEXT NOT NULL DEFAULT 'in_progress',
    filament_used_mm REAL,
    estimated_filament_mm REAL,
    nozzle_temp REAL,
    bed_temp REAL,
    speed_profile TEXT,
    thumbnail_path TEXT,
    note TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_history_start ON print_history(start_time DESC);
"""


class HistoryDB:
    def __init__(self, path: Path) -> None:
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        self._conn = sqlite3.connect(str(self.path), check_same_thread=False)
        self._conn.row_factory = sqlite3.Row
        with self._lock:
            self._conn.executescript(SCHEMA)
            self._conn.commit()

    def close(self) -> None:
        with self._lock:
            self._conn.close()

    # ------------------------------------------------------------------ write
    def start_print(
        self,
        filename: str,
        *,
        start_time: Optional[float] = None,
        estimated_filament_mm: Optional[float] = None,
        nozzle_temp: Optional[float] = None,
        bed_temp: Optional[float] = None,
        speed_profile: Optional[str] = None,
        thumbnail_path: Optional[str] = None,
    ) -> int:
        with self._lock:
            cursor = self._conn.execute(
                """
                INSERT INTO print_history
                    (filename, start_time, result, estimated_filament_mm,
                     nozzle_temp, bed_temp, speed_profile, thumbnail_path)
                VALUES (?, ?, 'in_progress', ?, ?, ?, ?, ?)
                """,
                (
                    filename,
                    start_time if start_time is not None else time.time(),
                    estimated_filament_mm,
                    nozzle_temp,
                    bed_temp,
                    speed_profile,
                    thumbnail_path,
                ),
            )
            self._conn.commit()
            return int(cursor.lastrowid)

    def finish_print(
        self,
        entry_id: int,
        *,
        result: str,
        finish_time: Optional[float] = None,
        filament_used_mm: Optional[float] = None,
        duration: Optional[float] = None,
        note: str = "",
    ) -> None:
        finish = finish_time if finish_time is not None else time.time()
        with self._lock:
            row = self._conn.execute(
                "SELECT start_time FROM print_history WHERE id = ?", (entry_id,)
            ).fetchone()
            computed = duration
            if computed is None and row is not None:
                computed = max(0.0, finish - float(row["start_time"]))
            self._conn.execute(
                """
                UPDATE print_history
                   SET finish_time = ?, duration = ?, result = ?,
                       filament_used_mm = COALESCE(?, filament_used_mm),
                       note = CASE WHEN ? = '' THEN note ELSE ? END
                 WHERE id = ?
                """,
                (finish, computed, result, filament_used_mm, note, note, entry_id),
            )
            self._conn.commit()

    def set_thumbnail(self, entry_id: int, relative_path: str) -> None:
        with self._lock:
            self._conn.execute(
                "UPDATE print_history SET thumbnail_path = ? WHERE id = ?",
                (relative_path, entry_id),
            )
            self._conn.commit()

    def set_speed_profile(self, entry_id: int, profile: str) -> None:
        with self._lock:
            self._conn.execute(
                "UPDATE print_history SET speed_profile = ? WHERE id = ?", (profile, entry_id)
            )
            self._conn.commit()

    def get(self, entry_id: int) -> Optional[HistoryEntry]:
        with self._lock:
            row = self._conn.execute(
                "SELECT * FROM print_history WHERE id = ?", (entry_id,)
            ).fetchone()
        return _row_to_entry(row) if row else None

    def active_entry(self) -> Optional[HistoryEntry]:
        with self._lock:
            row = self._conn.execute(
                "SELECT * FROM print_history WHERE result = 'in_progress' ORDER BY start_time DESC LIMIT 1"
            ).fetchone()
        return _row_to_entry(row) if row else None

    def close_open_entries(self, *, result: str = "interrupted", note: str = "") -> int:
        """Finish every row still marked in_progress. Returns how many.

        Called on startup after an unclean shutdown: a print that was running
        when the power went out never gets its own finish event, so without
        this it stays "in progress" in the history forever and every later
        total is wrong.
        """
        finish = time.time()
        with self._lock:
            rows = self._conn.execute(
                "SELECT id, start_time FROM print_history WHERE result = 'in_progress'"
            ).fetchall()
            for row in rows:
                self._conn.execute(
                    """
                    UPDATE print_history
                       SET finish_time = ?, duration = ?, result = ?,
                           note = CASE WHEN ? = '' THEN note ELSE ? END
                     WHERE id = ?
                    """,
                    (
                        finish,
                        max(0.0, finish - float(row["start_time"])),
                        result,
                        note,
                        note,
                        row["id"],
                    ),
                )
            self._conn.commit()
        return len(rows)

    def prune(self, max_entries: int) -> None:
        if max_entries <= 0:
            return
        with self._lock:
            self._conn.execute(
                """
                DELETE FROM print_history
                 WHERE id NOT IN (
                    SELECT id FROM print_history ORDER BY start_time DESC LIMIT ?
                 )
                """,
                (max_entries,),
            )
            self._conn.commit()

    def delete(self, entry_id: int) -> bool:
        with self._lock:
            cursor = self._conn.execute("DELETE FROM print_history WHERE id = ?", (entry_id,))
            self._conn.commit()
            return cursor.rowcount > 0

    # ------------------------------------------------------------------- read
    def list(self, limit: int = 100, offset: int = 0) -> List[HistoryEntry]:
        with self._lock:
            rows = self._conn.execute(
                "SELECT * FROM print_history ORDER BY start_time DESC LIMIT ? OFFSET ?",
                (limit, offset),
            ).fetchall()
        return [_row_to_entry(row) for row in rows]

    def stats(self) -> HistoryStats:
        with self._lock:
            row = self._conn.execute(
                """
                SELECT
                    COUNT(*)                                                AS total,
                    SUM(CASE WHEN result = 'completed' THEN 1 ELSE 0 END)   AS ok,
                    SUM(CASE WHEN result = 'error' THEN 1 ELSE 0 END)       AS failed,
                    SUM(CASE WHEN result = 'cancelled' THEN 1 ELSE 0 END)   AS cancelled,
                    COALESCE(SUM(duration), 0)                              AS seconds,
                    COALESCE(SUM(filament_used_mm), 0)                      AS filament,
                    COALESCE(MAX(duration), 0)                              AS longest
                  FROM print_history
                 WHERE result != 'in_progress'
                """
            ).fetchone()
        return HistoryStats(
            total_prints=int(row["total"] or 0),
            successful=int(row["ok"] or 0),
            failed=int(row["failed"] or 0),
            cancelled=int(row["cancelled"] or 0),
            total_print_seconds=float(row["seconds"] or 0.0),
            total_filament_mm=float(row["filament"] or 0.0),
            longest_print_seconds=float(row["longest"] or 0.0),
        )


def _row_to_entry(row: sqlite3.Row) -> HistoryEntry:
    data: Dict[str, Any] = dict(row)
    return HistoryEntry(
        id=int(data["id"]),
        filename=str(data["filename"]),
        start_time=float(data["start_time"]),
        finish_time=data["finish_time"],
        duration=data["duration"],
        result=str(data["result"]),
        filament_used_mm=data["filament_used_mm"],
        estimated_filament_mm=data["estimated_filament_mm"],
        nozzle_temp=data["nozzle_temp"],
        bed_temp=data["bed_temp"],
        speed_profile=data["speed_profile"],
        thumbnail_path=data["thumbnail_path"],
        note=str(data["note"] or ""),
    )
