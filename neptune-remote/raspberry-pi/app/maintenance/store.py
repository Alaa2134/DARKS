"""Usage-based maintenance reminders.

Reminders are derived only from measurable usage (print hours, print count,
elapsed days). The app never claims a part has actually failed - it says
"this is due", which is honest and useful.
"""

from __future__ import annotations

import time
import uuid
from typing import Any, Dict, List, Optional

from pydantic import BaseModel

from ..db import Database

BUILTIN_TASKS: List[Dict[str, Any]] = [
    {
        "id": "clean_bed", "name_ar": "تنظيف سطح الطباعة", "name_en": "Clean the print bed",
        "icon": "sparkles", "interval_prints": 10, "interval_days": 14,
    },
    {
        "id": "clean_nozzle", "name_ar": "تنظيف النوزل", "name_en": "Clean the nozzle",
        "icon": "flame", "interval_hours": 60,
    },
    {
        "id": "lubricate_axes", "name_ar": "تشحيم المحاور", "name_en": "Lubricate the axes",
        "icon": "drop", "interval_hours": 150, "interval_days": 90,
    },
    {
        "id": "check_belts", "name_ar": "فحص السيور", "name_en": "Check the belts",
        "icon": "arrow.left.and.right", "interval_hours": 120,
    },
    {
        "id": "check_wheels", "name_ar": "فحص العجلات", "name_en": "Check the wheels",
        "icon": "circle.dashed", "interval_hours": 200,
    },
    {
        "id": "clean_fans", "name_ar": "تنظيف المراوح", "name_en": "Clean the fans",
        "icon": "fanblades", "interval_hours": 250, "interval_days": 120,
    },
    {
        "id": "inspect_wiring", "name_ar": "فحص الأسلاك", "name_en": "Inspect the wiring",
        "icon": "cable.connector", "interval_hours": 300, "interval_days": 180,
    },
    {
        "id": "check_bed_mesh", "name_ar": "إعادة عمل خريطة السرير", "name_en": "Re-run the bed mesh",
        "icon": "grid", "interval_prints": 25, "interval_days": 60,
    },
    {
        "id": "tighten_screws", "name_ar": "ربط المسامير", "name_en": "Tighten the screws",
        "icon": "wrench.and.screwdriver", "interval_hours": 200,
    },
]


class MaintenanceTask(BaseModel):
    id: str
    name_ar: str
    name_en: str = ""
    icon: str = "wrench"
    interval_hours: Optional[float] = None
    interval_prints: Optional[int] = None
    interval_days: Optional[int] = None
    last_done_at: Optional[float] = None
    last_done_hours: float = 0.0
    last_done_prints: int = 0
    enabled: bool = True
    notes: str = ""
    builtin: bool = False

    # Computed for the UI.
    progress: float = 0.0        # 0..1, >=1 means due
    due: bool = False
    due_reason: str = ""         # localisation key
    remaining_hours: Optional[float] = None
    remaining_prints: Optional[int] = None
    remaining_days: Optional[int] = None


class MaintenanceStatus(BaseModel):
    total_prints: int = 0
    total_print_hours: float = 0.0
    total_filament_grams: float = 0.0
    tasks: List[MaintenanceTask] = []
    due_count: int = 0


class MaintenanceStore:
    def __init__(self, database: Database) -> None:
        self.db = database
        self._ensure_builtins()

    def _ensure_builtins(self) -> None:
        for task in BUILTIN_TASKS:
            self.db.execute(
                """
                INSERT OR IGNORE INTO maintenance_tasks(
                    id, name_ar, name_en, icon, interval_hours, interval_prints, interval_days,
                    last_done_at, last_done_hours, last_done_prints, enabled, notes, builtin
                ) VALUES (?,?,?,?,?,?,?,NULL,0,0,1,'',1)
                """,
                (
                    task["id"], task["name_ar"], task["name_en"], task["icon"],
                    task.get("interval_hours"), task.get("interval_prints"), task.get("interval_days"),
                ),
            )

    # --------------------------------------------------------------- status
    def status(self, *, total_prints: int, total_print_hours: float, total_filament_grams: float = 0.0) -> MaintenanceStatus:
        tasks = []
        now = time.time()
        for row in self.db.query("SELECT * FROM maintenance_tasks ORDER BY builtin DESC, name_ar"):
            task = self._row(row)
            self._evaluate(task, total_prints=total_prints, total_hours=total_print_hours, now=now)
            tasks.append(task)

        return MaintenanceStatus(
            total_prints=total_prints,
            total_print_hours=round(total_print_hours, 2),
            total_filament_grams=round(total_filament_grams, 1),
            tasks=tasks,
            due_count=sum(1 for task in tasks if task.due and task.enabled),
        )

    @staticmethod
    def _evaluate(task: MaintenanceTask, *, total_prints: int, total_hours: float, now: float) -> None:
        progress_values: List[float] = []

        if task.interval_hours:
            used = max(0.0, total_hours - task.last_done_hours)
            progress_values.append(used / task.interval_hours)
            task.remaining_hours = round(max(0.0, task.interval_hours - used), 1)

        if task.interval_prints:
            used_prints = max(0, total_prints - task.last_done_prints)
            progress_values.append(used_prints / task.interval_prints)
            task.remaining_prints = max(0, task.interval_prints - used_prints)

        if task.interval_days:
            reference = task.last_done_at or now
            elapsed_days = (now - reference) / 86_400
            progress_values.append(elapsed_days / task.interval_days)
            task.remaining_days = max(0, int(task.interval_days - elapsed_days))

        task.progress = max(progress_values) if progress_values else 0.0
        task.due = task.progress >= 1.0

        if task.due:
            if task.interval_hours and task.remaining_hours == 0:
                task.due_reason = "maintenance.reason.hours"
            elif task.interval_prints and task.remaining_prints == 0:
                task.due_reason = "maintenance.reason.prints"
            else:
                task.due_reason = "maintenance.reason.days"

    # ------------------------------------------------------------- mutation
    def complete(self, task_id: str, *, total_prints: int, total_print_hours: float, note: str = "") -> Optional[MaintenanceTask]:
        row = self.db.query_one("SELECT * FROM maintenance_tasks WHERE id = ?", (task_id,))
        if row is None:
            return None
        now = time.time()
        self.db.execute(
            "UPDATE maintenance_tasks SET last_done_at = ?, last_done_hours = ?, last_done_prints = ? "
            "WHERE id = ?",
            (now, total_print_hours, total_prints, task_id),
        )
        self.db.execute(
            "INSERT INTO maintenance_log(task_id, done_at, note) VALUES (?,?,?)",
            (task_id, now, note),
        )
        updated = self.db.query_one("SELECT * FROM maintenance_tasks WHERE id = ?", (task_id,))
        task = self._row(updated) if updated else None
        if task is not None:
            self._evaluate(task, total_prints=total_prints, total_hours=total_print_hours, now=now)
        return task

    def create(
        self,
        *,
        name_ar: str,
        name_en: str = "",
        icon: str = "wrench",
        interval_hours: Optional[float] = None,
        interval_prints: Optional[int] = None,
        interval_days: Optional[int] = None,
    ) -> MaintenanceTask:
        task_id = uuid.uuid4().hex[:10]
        self.db.execute(
            """
            INSERT INTO maintenance_tasks(
                id, name_ar, name_en, icon, interval_hours, interval_prints, interval_days,
                last_done_at, last_done_hours, last_done_prints, enabled, notes, builtin
            ) VALUES (?,?,?,?,?,?,?,NULL,0,0,1,'',0)
            """,
            (task_id, name_ar, name_en, icon, interval_hours, interval_prints, interval_days),
        )
        row = self.db.query_one("SELECT * FROM maintenance_tasks WHERE id = ?", (task_id,))
        return self._row(row)  # type: ignore[arg-type]

    def set_enabled(self, task_id: str, enabled: bool) -> bool:
        cursor = self.db.execute(
            "UPDATE maintenance_tasks SET enabled = ? WHERE id = ?", (int(enabled), task_id)
        )
        return cursor.rowcount > 0

    def delete(self, task_id: str) -> bool:
        row = self.db.query_one("SELECT builtin FROM maintenance_tasks WHERE id = ?", (task_id,))
        if row is None or bool(row["builtin"]):
            return False
        self.db.execute("DELETE FROM maintenance_tasks WHERE id = ?", (task_id,))
        return True

    def log(self, limit: int = 50) -> List[Dict[str, Any]]:
        rows = self.db.query(
            "SELECT * FROM maintenance_log ORDER BY done_at DESC LIMIT ?", (limit,)
        )
        return [dict(row) for row in rows]

    @staticmethod
    def _row(row: Any) -> MaintenanceTask:
        data = dict(row)
        data["enabled"] = bool(data["enabled"])
        data["builtin"] = bool(data["builtin"])
        return MaintenanceTask(**data)
