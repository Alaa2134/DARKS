"""Print cost and selling-price calculator.

Everything is explicit and auditable - no hidden fudge factors. Defaults are
stored in the app_state table so the phone and the backend agree.
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional

from pydantic import BaseModel, Field

from ..db import Database

STATE_KEY = "cost.settings"


class CostSettings(BaseModel):
    """Editable rates. Currency is free text so any market works."""

    currency: str = "EGP"
    filament_price_per_kg: float = 700.0
    electricity_price_per_kwh: float = 1.5
    printer_watts: float = 180.0
    machine_hourly_rate: float = 5.0        # depreciation + maintenance per printing hour
    failure_rate_percent: float = 8.0       # spread the cost of failed prints
    labour_per_print: float = 10.0          # handling, removing supports
    packaging_per_print: float = 0.0
    other_per_print: float = 0.0
    profit_percent: float = 40.0
    round_selling_price_to: float = 5.0


class CostRequest(BaseModel):
    filament_grams: float = 0.0
    print_seconds: float = 0.0
    filament_price_per_kg: Optional[float] = None
    quantity: int = 1
    extra_cost: float = 0.0
    profit_percent: Optional[float] = None
    spool_id: Optional[str] = None


class CostLine(BaseModel):
    key: str          # localisation key, e.g. "cost.line.filament"
    amount: float
    detail: str = ""


class CostBreakdown(BaseModel):
    currency: str
    quantity: int = 1
    lines: List[CostLine] = Field(default_factory=list)
    cost_per_unit: float = 0.0
    total_cost: float = 0.0
    suggested_price_per_unit: float = 0.0
    suggested_price_total: float = 0.0
    profit_per_unit: float = 0.0
    profit_percent: float = 0.0
    print_hours: float = 0.0
    filament_grams: float = 0.0


class CostCalculator:
    def __init__(self, database: Database) -> None:
        self.db = database

    # ------------------------------------------------------------- settings
    def settings(self) -> CostSettings:
        stored = self.db.get_state(STATE_KEY, None)
        if isinstance(stored, dict):
            try:
                return CostSettings(**stored)
            except Exception:
                pass
        return CostSettings()

    def save_settings(self, settings: CostSettings) -> CostSettings:
        self.db.set_state(STATE_KEY, settings.model_dump())
        return settings

    # ---------------------------------------------------------- calculation
    def calculate(
        self,
        request: CostRequest,
        *,
        settings: Optional[CostSettings] = None,
        filament_price_per_kg: Optional[float] = None,
    ) -> CostBreakdown:
        config = settings or self.settings()
        quantity = max(1, int(request.quantity))
        hours = max(0.0, request.print_seconds) / 3600.0
        grams = max(0.0, request.filament_grams)

        price_per_kg = (
            request.filament_price_per_kg
            if request.filament_price_per_kg is not None
            else (filament_price_per_kg if filament_price_per_kg is not None
                  else config.filament_price_per_kg)
        )

        filament_cost = grams / 1000.0 * max(0.0, price_per_kg)
        electricity_cost = hours * (config.printer_watts / 1000.0) * config.electricity_price_per_kwh
        machine_cost = hours * config.machine_hourly_rate
        labour_cost = config.labour_per_print
        packaging_cost = config.packaging_per_print
        other_cost = config.other_per_print + max(0.0, request.extra_cost)

        subtotal = (
            filament_cost + electricity_cost + machine_cost
            + labour_cost + packaging_cost + other_cost
        )
        failure_cost = subtotal * (config.failure_rate_percent / 100.0)
        cost_per_unit = subtotal + failure_cost

        profit_percent = (
            request.profit_percent if request.profit_percent is not None else config.profit_percent
        )
        raw_price = cost_per_unit * (1 + profit_percent / 100.0)
        price_per_unit = _round_up(raw_price, config.round_selling_price_to)

        lines = [
            CostLine(key="cost.line.filament", amount=round(filament_cost, 2),
                     detail=f"{grams:.0f} g @ {price_per_kg:.0f}/kg"),
            CostLine(key="cost.line.electricity", amount=round(electricity_cost, 2),
                     detail=f"{hours:.2f} h @ {config.printer_watts:.0f} W"),
            CostLine(key="cost.line.machine", amount=round(machine_cost, 2),
                     detail=f"{hours:.2f} h @ {config.machine_hourly_rate:.2f}/h"),
            CostLine(key="cost.line.labour", amount=round(labour_cost, 2)),
            CostLine(key="cost.line.packaging", amount=round(packaging_cost, 2)),
            CostLine(key="cost.line.other", amount=round(other_cost, 2)),
            CostLine(key="cost.line.failure_allowance", amount=round(failure_cost, 2),
                     detail=f"{config.failure_rate_percent:.0f}%"),
        ]

        return CostBreakdown(
            currency=config.currency,
            quantity=quantity,
            lines=[line for line in lines if line.amount > 0 or line.key == "cost.line.filament"],
            cost_per_unit=round(cost_per_unit, 2),
            total_cost=round(cost_per_unit * quantity, 2),
            suggested_price_per_unit=round(price_per_unit, 2),
            suggested_price_total=round(price_per_unit * quantity, 2),
            profit_per_unit=round(price_per_unit - cost_per_unit, 2),
            profit_percent=round(
                ((price_per_unit - cost_per_unit) / cost_per_unit * 100.0) if cost_per_unit else 0.0, 1
            ),
            print_hours=round(hours, 2),
            filament_grams=round(grams, 1),
        )


def _round_up(value: float, step: float) -> float:
    if step <= 0:
        return value
    import math

    return math.ceil(value / step) * step
