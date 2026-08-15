"""Filament spool inventory and consumption tracking."""

from __future__ import annotations

import time
import uuid
from typing import Any, Dict, List, Optional

from pydantic import BaseModel, Field

from ..db import Database

# Density in g/cm3 for the materials the app ships with, used to convert the
# slicer's millimetres of 1.75 mm filament into grams.
DENSITY = {
    "PLA": 1.24,
    "PLA+": 1.25,
    "PETG": 1.27,
    "TPU": 1.21,
    "ABS": 1.04,
    "ASA": 1.07,
}
DEFAULT_DENSITY = 1.24
DEFAULT_DIAMETER_MM = 1.75

# Do not let a print start if the spool has less than this margin left.
SAFETY_MARGIN_GRAMS = 15.0


class Spool(BaseModel):
    id: str
    brand: str = ""
    material: str = "PLA"
    color_name: str = ""
    color_hex: str = "#333333"
    initial_grams: float = 1000.0
    remaining_grams: float = 1000.0
    spool_weight_g: float = 200.0
    price: float = 0.0
    currency: str = "EGP"
    purchased_at: Optional[float] = None
    notes: str = ""
    active: bool = False
    archived: bool = False
    created_at: float = 0.0
    updated_at: float = 0.0

    @property
    def percent_remaining(self) -> float:
        if self.initial_grams <= 0:
            return 0.0
        return max(0.0, min(1.0, self.remaining_grams / self.initial_grams))

    @property
    def cost_per_gram(self) -> float:
        if self.initial_grams <= 0 or self.price <= 0:
            return 0.0
        return self.price / self.initial_grams


class SpoolCreate(BaseModel):
    brand: str = ""
    material: str = "PLA"
    color_name: str = ""
    color_hex: str = "#333333"
    initial_grams: float = 1000.0
    remaining_grams: Optional[float] = None
    spool_weight_g: float = 200.0
    price: float = 0.0
    currency: str = "EGP"
    purchased_at: Optional[float] = None
    notes: str = ""
    active: bool = False


class SpoolUpdate(BaseModel):
    brand: Optional[str] = None
    material: Optional[str] = None
    color_name: Optional[str] = None
    color_hex: Optional[str] = None
    initial_grams: Optional[float] = None
    remaining_grams: Optional[float] = None
    spool_weight_g: Optional[float] = None
    price: Optional[float] = None
    currency: Optional[str] = None
    notes: Optional[str] = None
    active: Optional[bool] = None
    archived: Optional[bool] = None


class FilamentCheck(BaseModel):
    """Answer to 'do I have enough filament for this print?'"""

    ok: bool
    spool: Optional[Spool] = None
    required_grams: float = 0.0
    remaining_grams: float = 0.0
    margin_grams: float = SAFETY_MARGIN_GRAMS
    message_key: str = "filament.check.ok"
    has_active_spool: bool = True


def grams_from_mm(millimetres: float, material: str = "PLA", diameter: float = DEFAULT_DIAMETER_MM) -> float:
    """Convert extruded filament length to grams."""
    if millimetres <= 0:
        return 0.0
    radius_cm = (diameter / 2.0) / 10.0
    length_cm = millimetres / 10.0
    volume_cm3 = 3.141592653589793 * radius_cm * radius_cm * length_cm
    density = DENSITY.get(material.upper(), DEFAULT_DENSITY)
    return volume_cm3 * density


class FilamentStore:
    def __init__(self, database: Database) -> None:
        self.db = database

    # --------------------------------------------------------------- spools
    def create(self, payload: SpoolCreate) -> Spool:
        spool_id = uuid.uuid4().hex[:12]
        now = time.time()
        remaining = payload.remaining_grams
        if remaining is None:
            remaining = payload.initial_grams

        if payload.active:
            self.db.execute("UPDATE filament_spools SET active = 0")

        self.db.execute(
            """
            INSERT INTO filament_spools(
                id, brand, material, color_name, color_hex, initial_grams, remaining_grams,
                spool_weight_g, price, currency, purchased_at, notes, active, archived,
                created_at, updated_at
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,0,?,?)
            """,
            (
                spool_id, payload.brand, payload.material.upper(), payload.color_name,
                payload.color_hex, payload.initial_grams, remaining, payload.spool_weight_g,
                payload.price, payload.currency, payload.purchased_at, payload.notes,
                int(payload.active), now, now,
            ),
        )
        spool = self.get(spool_id)
        assert spool is not None
        return spool

    def get(self, spool_id: str) -> Optional[Spool]:
        row = self.db.query_one("SELECT * FROM filament_spools WHERE id = ?", (spool_id,))
        return self._row(row) if row else None

    def list(self, *, include_archived: bool = False) -> List[Spool]:
        sql = "SELECT * FROM filament_spools"
        if not include_archived:
            sql += " WHERE archived = 0"
        sql += " ORDER BY active DESC, updated_at DESC"
        return [self._row(row) for row in self.db.query(sql)]

    def active_spool(self) -> Optional[Spool]:
        row = self.db.query_one(
            "SELECT * FROM filament_spools WHERE active = 1 AND archived = 0 LIMIT 1"
        )
        return self._row(row) if row else None

    def set_active(self, spool_id: str) -> Optional[Spool]:
        if self.get(spool_id) is None:
            return None
        self.db.execute("UPDATE filament_spools SET active = 0")
        self.db.execute(
            "UPDATE filament_spools SET active = 1, archived = 0, updated_at = ? WHERE id = ?",
            (time.time(), spool_id),
        )
        return self.get(spool_id)

    def update(self, spool_id: str, payload: SpoolUpdate) -> Optional[Spool]:
        spool = self.get(spool_id)
        if spool is None:
            return None

        data = payload.model_dump(exclude_none=True)
        if data.get("active"):
            self.db.execute("UPDATE filament_spools SET active = 0")
        for key, value in data.items():
            setattr(spool, key, value.upper() if key == "material" else value)
        spool.updated_at = time.time()

        self.db.execute(
            """
            UPDATE filament_spools SET brand=?, material=?, color_name=?, color_hex=?,
                initial_grams=?, remaining_grams=?, spool_weight_g=?, price=?, currency=?,
                notes=?, active=?, archived=?, updated_at=? WHERE id=?
            """,
            (
                spool.brand, spool.material, spool.color_name, spool.color_hex,
                spool.initial_grams, spool.remaining_grams, spool.spool_weight_g, spool.price,
                spool.currency, spool.notes, int(spool.active), int(spool.archived),
                spool.updated_at, spool_id,
            ),
        )
        return self.get(spool_id)

    def delete(self, spool_id: str) -> bool:
        cursor = self.db.execute("DELETE FROM filament_spools WHERE id = ?", (spool_id,))
        return cursor.rowcount > 0

    # ---------------------------------------------------------- consumption
    def consume(
        self,
        grams: float,
        *,
        spool_id: Optional[str] = None,
        reason: str = "print",
        history_id: Optional[int] = None,
    ) -> Optional[Spool]:
        """Subtract used filament. Never goes below zero."""
        if grams <= 0:
            return self.get(spool_id) if spool_id else self.active_spool()

        spool = self.get(spool_id) if spool_id else self.active_spool()
        if spool is None:
            return None

        remaining = max(0.0, spool.remaining_grams - grams)
        now = time.time()
        self.db.execute(
            "UPDATE filament_spools SET remaining_grams = ?, updated_at = ? WHERE id = ?",
            (remaining, now, spool.id),
        )
        self.db.execute(
            "INSERT INTO filament_usage(spool_id, grams, reason, history_id, created_at) "
            "VALUES (?,?,?,?,?)",
            (spool.id, grams, reason, history_id, now),
        )
        return self.get(spool.id)

    def usage_history(self, spool_id: Optional[str] = None, limit: int = 100) -> List[Dict[str, Any]]:
        if spool_id:
            rows = self.db.query(
                "SELECT * FROM filament_usage WHERE spool_id = ? ORDER BY created_at DESC LIMIT ?",
                (spool_id, limit),
            )
        else:
            rows = self.db.query(
                "SELECT * FROM filament_usage ORDER BY created_at DESC LIMIT ?", (limit,)
            )
        return [dict(row) for row in rows]

    # ---------------------------------------------------------------- check
    def check_enough(
        self,
        required_grams: float,
        *,
        material: Optional[str] = None,
        spool_id: Optional[str] = None,
    ) -> FilamentCheck:
        spool = self.get(spool_id) if spool_id else self.active_spool()

        if spool is None:
            # No inventory configured: never block the user, just say so.
            return FilamentCheck(
                ok=True,
                required_grams=required_grams,
                remaining_grams=0.0,
                message_key="filament.check.no_spool",
                has_active_spool=False,
            )

        enough = spool.remaining_grams >= required_grams + SAFETY_MARGIN_GRAMS
        message = "filament.check.ok"
        if not enough:
            message = "filament.check.not_enough"
        elif material and spool.material.upper() != material.upper():
            message = "filament.check.material_mismatch"

        return FilamentCheck(
            ok=enough,
            spool=spool,
            required_grams=required_grams,
            remaining_grams=spool.remaining_grams,
            message_key=message,
            has_active_spool=True,
        )

    def summary(self) -> Dict[str, Any]:
        rows = self.db.query("SELECT * FROM filament_spools WHERE archived = 0")
        spools = [self._row(row) for row in rows]
        by_material: Dict[str, float] = {}
        for spool in spools:
            by_material[spool.material] = by_material.get(spool.material, 0.0) + spool.remaining_grams
        return {
            "spool_count": len(spools),
            "total_remaining_grams": round(sum(spool.remaining_grams for spool in spools), 1),
            "total_value": round(
                sum(spool.cost_per_gram * spool.remaining_grams for spool in spools), 2
            ),
            "by_material": {key: round(value, 1) for key, value in by_material.items()},
            "active_spool_id": next((spool.id for spool in spools if spool.active), None),
        }

    @staticmethod
    def _row(row: Any) -> Spool:
        data = dict(row)
        data["active"] = bool(data["active"])
        data["archived"] = bool(data["archived"])
        return Spool(**data)
