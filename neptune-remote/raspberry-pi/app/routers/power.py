"""Remote power endpoints with safety checks."""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException

from ..deps import get_state
from ..power import PowerError, evaluate_power_off
from ..printer_state import fetch_status
from ..schemas import (
    PowerActionResponse,
    PowerOffRequest,
    PowerSafetyReport,
    PowerStatusResponse,
)
from ..security import require_token
from ..state import AppState, _power_payload

router = APIRouter(dependencies=[Depends(require_token)])


@router.get("/power/status", response_model=PowerStatusResponse)
async def power_status(state: AppState = Depends(get_state)) -> PowerStatusResponse:
    try:
        result = await state.power.status()
    except PowerError as exc:
        return PowerStatusResponse(
            provider=state.power.name, state="error", available=False, message=exc.message
        )
    state.last_power = result
    return PowerStatusResponse(
        provider=state.power.name,
        state=result.state,
        available=result.available,
        device=result.device,
        message=result.message,
        raw=result.raw,
    )


@router.get("/power/safety", response_model=PowerSafetyReport)
async def power_safety(state: AppState = Depends(get_state)) -> PowerSafetyReport:
    status = await fetch_status(state.moonraker)
    state.last_status = status
    return evaluate_power_off(status, state.config.power.safety)


@router.post("/power/on", response_model=PowerActionResponse)
async def power_on(state: AppState = Depends(get_state)) -> PowerActionResponse:
    try:
        result = await state.power.turn_on()
    except PowerError as exc:
        raise HTTPException(status_code=502, detail=exc.message) from exc
    state.last_power = result
    await state.hub.broadcast("power", _power_payload(state.power.name, result))
    return PowerActionResponse(
        ok=True,
        state=result.state,
        provider=state.power.name,
        message=result.message or "Printer powered on",
    )


@router.post("/power/off", response_model=PowerActionResponse)
async def power_off(
    payload: PowerOffRequest | None = None, state: AppState = Depends(get_state)
) -> PowerActionResponse:
    force = bool(payload.force) if payload else False

    status = await fetch_status(state.moonraker)
    state.last_status = status
    report = evaluate_power_off(status, state.config.power.safety)

    if not report.safe and not force:
        raise HTTPException(
            status_code=409,
            detail={
                "message": "Unsafe to power off",
                "safety": report.model_dump(),
            },
        )

    try:
        result = await state.power.turn_off()
    except PowerError as exc:
        raise HTTPException(status_code=502, detail=exc.message) from exc

    state.last_power = result
    await state.hub.broadcast("power", _power_payload(state.power.name, result))
    return PowerActionResponse(
        ok=True,
        state=result.state,
        provider=state.power.name,
        message=result.message or ("Printer powered off (forced)" if force else "Printer powered off"),
        safety=report,
    )
