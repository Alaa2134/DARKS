"""Metadata store for recordings and timelapses (the ``videos`` table)."""

from __future__ import annotations

import time
import uuid
from pathlib import Path
from typing import Any, Dict, List, Optional

from pydantic import BaseModel

from ..db import Database
from ..paths import StorageLayout


class VideoRecord(BaseModel):
    id: str
    kind: str = "recording"          # recording | timelapse
    path: str
    filename: str
    item_id: Optional[str] = None
    history_id: Optional[int] = None
    gcode_name: str = ""
    started_at: float = 0.0
    finished_at: Optional[float] = None
    duration: Optional[float] = None
    size_bytes: int = 0
    result: str = "unknown"          # completed | cancelled | error | in_progress
    thumbnail: Optional[str] = None
    frame_count: Optional[int] = None
    error: str = ""

    @property
    def is_finished(self) -> bool:
        return self.result != "in_progress"


class VideoStore:
    def __init__(self, database: Database, layout: StorageLayout) -> None:
        self.db = database
        self.layout = layout

    def create(
        self,
        *,
        kind: str,
        path: Path,
        gcode_name: str = "",
        item_id: Optional[str] = None,
        history_id: Optional[int] = None,
        started_at: Optional[float] = None,
    ) -> VideoRecord:
        video_id = uuid.uuid4().hex[:12]
        started = started_at or time.time()
        self.db.execute(
            """
            INSERT INTO videos(
                id, kind, path, filename, item_id, history_id, gcode_name,
                started_at, finished_at, duration, size_bytes, result, thumbnail,
                frame_count, error
            ) VALUES (?,?,?,?,?,?,?,?,NULL,NULL,0,'in_progress',NULL,NULL,'')
            """,
            (
                video_id, kind, self.layout.relative(path), Path(path).name,
                item_id, history_id, gcode_name, started,
            ),
        )
        record = self.get(video_id)
        assert record is not None
        return record

    def finish(
        self,
        video_id: str,
        *,
        result: str,
        error: str = "",
        frame_count: Optional[int] = None,
        thumbnail: Optional[Path] = None,
    ) -> Optional[VideoRecord]:
        record = self.get(video_id)
        if record is None:
            return None

        finished = time.time()
        size = 0
        try:
            full_path = self.layout.resolve(record.path)
            if full_path.is_file():
                size = full_path.stat().st_size
        except (ValueError, OSError):
            size = 0

        self.db.execute(
            "UPDATE videos SET finished_at = ?, duration = ?, size_bytes = ?, result = ?, "
            "error = ?, frame_count = COALESCE(?, frame_count), thumbnail = COALESCE(?, thumbnail) "
            "WHERE id = ?",
            (
                finished, max(0.0, finished - record.started_at), size, result, error,
                frame_count, self.layout.relative(thumbnail) if thumbnail else None, video_id,
            ),
        )
        return self.get(video_id)

    def get(self, video_id: str) -> Optional[VideoRecord]:
        row = self.db.query_one("SELECT * FROM videos WHERE id = ?", (video_id,))
        return VideoRecord(**dict(row)) if row else None

    def list(self, *, kind: Optional[str] = None, limit: int = 200) -> List[VideoRecord]:
        if kind:
            rows = self.db.query(
                "SELECT * FROM videos WHERE kind = ? ORDER BY started_at DESC LIMIT ?", (kind, limit)
            )
        else:
            rows = self.db.query("SELECT * FROM videos ORDER BY started_at DESC LIMIT ?", (limit,))
        return [VideoRecord(**dict(row)) for row in rows]

    def delete(self, video_id: str, *, delete_file: bool = True) -> bool:
        record = self.get(video_id)
        if record is None:
            return False
        if record.result == "in_progress":
            # Never delete a file that is still being written to.
            return False
        if delete_file:
            for relative in (record.path, record.thumbnail):
                if not relative:
                    continue
                try:
                    self.layout.resolve(relative).unlink(missing_ok=True)
                except (ValueError, OSError):
                    continue
        self.db.execute("DELETE FROM videos WHERE id = ?", (video_id,))
        return True

    def storage_summary(self) -> Dict[str, Any]:
        usage = self.layout.usage()
        rows = self.db.query("SELECT kind, COUNT(*) AS total, SUM(size_bytes) AS bytes FROM videos GROUP BY kind")
        by_kind = {
            row["kind"]: {"count": int(row["total"] or 0), "bytes": int(row["bytes"] or 0)}
            for row in rows
        }
        return {
            "videos_bytes": usage.get("videos", 0.0),
            "timelapses_bytes": usage.get("timelapses", 0.0),
            "snapshots_bytes": usage.get("snapshots", 0.0),
            "total_bytes": usage.get("total", 0.0),
            "disk_free_bytes": usage.get("disk_free", 0.0),
            "disk_total_bytes": usage.get("disk_total", 0.0),
            "by_kind": by_kind,
        }

    # ------------------------------------------------------------- cleanup
    def apply_retention(
        self,
        *,
        policy: str,
        max_gigabytes: float,
        keep_last: int,
        active_ids: Optional[List[str]] = None,
    ) -> List[str]:
        """Delete old videos according to the retention policy.

        ``policy`` is one of ``never``, ``max_size`` or ``keep_last``.
        Recordings currently in progress are never touched.
        """
        protected = set(active_ids or [])
        finished = [
            record for record in self.list(limit=10_000)
            if record.result != "in_progress" and record.id not in protected
        ]
        removed: List[str] = []

        if policy == "keep_last" and keep_last > 0:
            for record in finished[keep_last:]:
                if self.delete(record.id):
                    removed.append(record.id)

        elif policy == "max_size" and max_gigabytes > 0:
            limit_bytes = max_gigabytes * 1024 ** 3
            total = sum(record.size_bytes for record in finished)
            for record in reversed(finished):  # oldest first
                if total <= limit_bytes:
                    break
                if self.delete(record.id):
                    total -= record.size_bytes
                    removed.append(record.id)

        return removed
