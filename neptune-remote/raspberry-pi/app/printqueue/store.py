"""Print queue.

The queue never starts the next print by itself: after a job finishes the user
must confirm "the part is removed and the bed is clear" before the next one can
be sent. A robot arm this printer does not have.
"""

from __future__ import annotations

import time
import uuid
from typing import Any, Dict, List, Optional

from pydantic import BaseModel

from ..db import Database

STATE_KEY_BED_CLEAR = "queue.bed_clear"


class QueueJob(BaseModel):
    id: str
    item_id: Optional[str] = None
    gcode_path: str
    display_name: str = ""
    material: str = ""
    estimated_seconds: Optional[float] = None
    filament_g: Optional[float] = None
    position: int = 0
    status: str = "waiting"     # waiting | printing | done | failed | cancelled
    created_at: float = 0.0
    started_at: Optional[float] = None
    finished_at: Optional[float] = None


class QueueJobCreate(BaseModel):
    gcode_path: str
    item_id: Optional[str] = None
    display_name: str = ""
    material: str = ""
    estimated_seconds: Optional[float] = None
    filament_g: Optional[float] = None


class QueueState(BaseModel):
    jobs: List[QueueJob] = []
    bed_clear: bool = False
    next_job: Optional[QueueJob] = None
    total_seconds: float = 0.0
    total_filament_g: float = 0.0
    blocked_reason_key: str = ""


class PrintQueueStore:
    def __init__(self, database: Database) -> None:
        self.db = database

    # ----------------------------------------------------------------- CRUD
    def add(self, payload: QueueJobCreate) -> QueueJob:
        job_id = uuid.uuid4().hex[:12]
        now = time.time()
        row = self.db.query_one(
            "SELECT COALESCE(MAX(position), 0) AS top FROM print_queue WHERE status = 'waiting'"
        )
        position = int(row["top"] or 0) + 1

        self.db.execute(
            """
            INSERT INTO print_queue(
                id, item_id, gcode_path, display_name, material, estimated_seconds,
                filament_g, position, status, created_at, started_at, finished_at
            ) VALUES (?,?,?,?,?,?,?,?,'waiting',?,NULL,NULL)
            """,
            (
                job_id, payload.item_id, payload.gcode_path,
                payload.display_name or payload.gcode_path, payload.material,
                payload.estimated_seconds, payload.filament_g, position, now,
            ),
        )
        job = self.get(job_id)
        assert job is not None
        return job

    def get(self, job_id: str) -> Optional[QueueJob]:
        row = self.db.query_one("SELECT * FROM print_queue WHERE id = ?", (job_id,))
        return QueueJob(**dict(row)) if row else None

    def list(self, *, include_finished: bool = False, limit: int = 200) -> List[QueueJob]:
        if include_finished:
            rows = self.db.query(
                "SELECT * FROM print_queue ORDER BY status = 'waiting' DESC, position, created_at DESC LIMIT ?",
                (limit,),
            )
        else:
            rows = self.db.query(
                "SELECT * FROM print_queue WHERE status IN ('waiting','printing') "
                "ORDER BY position LIMIT ?",
                (limit,),
            )
        return [QueueJob(**dict(row)) for row in rows]

    def remove(self, job_id: str) -> bool:
        cursor = self.db.execute("DELETE FROM print_queue WHERE id = ?", (job_id,))
        return cursor.rowcount > 0

    def clear(self) -> int:
        cursor = self.db.execute("DELETE FROM print_queue WHERE status = 'waiting'")
        return cursor.rowcount

    def reorder(self, ordered_ids: List[str]) -> List[QueueJob]:
        for index, job_id in enumerate(ordered_ids, start=1):
            self.db.execute(
                "UPDATE print_queue SET position = ? WHERE id = ? AND status = 'waiting'",
                (index, job_id),
            )
        return self.list()

    def mark(self, job_id: str, status: str) -> Optional[QueueJob]:
        now = time.time()
        if status == "printing":
            self.db.execute(
                "UPDATE print_queue SET status = ?, started_at = ? WHERE id = ?",
                (status, now, job_id),
            )
        else:
            self.db.execute(
                "UPDATE print_queue SET status = ?, finished_at = ? WHERE id = ?",
                (status, now, job_id),
            )
        return self.get(job_id)

    # --------------------------------------------------------------- gating
    def bed_clear(self) -> bool:
        return bool(self.db.get_state(STATE_KEY_BED_CLEAR, False))

    def set_bed_clear(self, value: bool) -> None:
        self.db.set_state(STATE_KEY_BED_CLEAR, bool(value))

    def state(self, *, printer_state: str = "standby") -> QueueState:
        jobs = self.list()
        waiting = [job for job in jobs if job.status == "waiting"]
        bed_clear = self.bed_clear()

        blocked = ""
        if printer_state in {"printing", "paused"}:
            blocked = "queue.blocked.printing"
        elif not bed_clear and waiting:
            blocked = "queue.blocked.bed_not_clear"

        return QueueState(
            jobs=jobs,
            bed_clear=bed_clear,
            next_job=waiting[0] if waiting and not blocked else None,
            total_seconds=sum(job.estimated_seconds or 0.0 for job in waiting),
            total_filament_g=sum(job.filament_g or 0.0 for job in waiting),
            blocked_reason_key=blocked,
        )

    def take_next(self, *, printer_state: str = "standby") -> Optional[QueueJob]:
        """Return the next job only if it is genuinely safe to start it."""
        state = self.state(printer_state=printer_state)
        if state.blocked_reason_key or state.next_job is None:
            return None
        # Starting consumes the "bed is clear" confirmation.
        self.set_bed_clear(False)
        return self.mark(state.next_job.id, "printing")

    def summary(self) -> Dict[str, Any]:
        state = self.state()
        return {
            "waiting": len([job for job in state.jobs if job.status == "waiting"]),
            "printing": len([job for job in state.jobs if job.status == "printing"]),
            "total_seconds": state.total_seconds,
            "total_filament_g": state.total_filament_g,
            "bed_clear": state.bed_clear,
        }
