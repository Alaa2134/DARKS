"""Printer status and control endpoints (thin, validated proxy to Moonraker)."""

from __future__ import annotations

from typing import Any, Dict, List

from fastapi import APIRouter, Depends, HTTPException, Query

from ..deps import get_state
from ..moonraker import MoonrakerError
from ..printer_state import fetch_status
from ..schemas import (
    GCodeCommandRequest,
    OKResponse,
    PrinterActionRequest,
    PrinterStatusResponse,
)
from ..security import require_token
from ..state import AppState

router = APIRouter(dependencies=[Depends(require_token)])

# Commands we refuse to forward blindly. Everything else is passed to Klipper,
# which validates it and returns a proper error we surface to the app.
BLOCKED_PREFIXES = ("M112",)  # emergency stop has its own explicit endpoint

ACTIONS = {
    "start",
    "pause",
    "resume",
    "cancel",
    "emergency_stop",
    "restart_klipper",
    "restart_firmware",
    "restart_moonraker",
}


@router.get("/printer/status", response_model=PrinterStatusResponse)
async def printer_status(state: AppState = Depends(get_state)) -> PrinterStatusResponse:
    status = await fetch_status(state.moonraker)
    state.last_status = status
    return status


@router.get("/printer/objects")
async def printer_objects(state: AppState = Depends(get_state)) -> Dict[str, List[str]]:
    try:
        return {"objects": await state.moonraker.list_objects()}
    except MoonrakerError as exc:
        raise HTTPException(status_code=502, detail=exc.message) from exc


@router.get("/printer/query")
async def printer_query(
    objects: str = Query(..., description="Comma separated Klipper object names"),
    state: AppState = Depends(get_state),
) -> Dict[str, Any]:
    requested = {name.strip(): None for name in objects.split(",") if name.strip()}
    if not requested:
        raise HTTPException(status_code=400, detail="No objects requested")
    try:
        return await state.moonraker.query_objects(requested)
    except MoonrakerError as exc:
        raise HTTPException(status_code=502, detail=exc.message) from exc


@router.get("/printer/info")
async def printer_info(state: AppState = Depends(get_state)) -> Dict[str, Any]:
    try:
        return await state.moonraker.printer_info()
    except MoonrakerError as exc:
        raise HTTPException(status_code=502, detail=exc.message) from exc


@router.get("/server/info")
async def server_info(state: AppState = Depends(get_state)) -> Dict[str, Any]:
    try:
        return await state.moonraker.server_info()
    except MoonrakerError as exc:
        raise HTTPException(status_code=502, detail=exc.message) from exc


@router.post("/printer/command", response_model=OKResponse)
async def printer_command(
    payload: GCodeCommandRequest, state: AppState = Depends(get_state)
) -> OKResponse:
    script = payload.script.strip()
    if not script:
        raise HTTPException(status_code=400, detail="Empty G-code command")

    upper = script.upper()
    for blocked in BLOCKED_PREFIXES:
        if upper.startswith(blocked):
            raise HTTPException(
                status_code=400,
                detail="Use POST /api/printer/action with action=emergency_stop for M112",
            )

    try:
        await state.moonraker.run_gcode(script)
    except MoonrakerError as exc:
        raise HTTPException(status_code=502, detail=exc.message) from exc
    return OKResponse(ok=True, message=f"Sent: {script}")


@router.post("/printer/action", response_model=OKResponse)
async def printer_action(
    payload: PrinterActionRequest, state: AppState = Depends(get_state)
) -> OKResponse:
    action = payload.action.strip().lower()
    if action not in ACTIONS:
        raise HTTPException(
            status_code=400,
            detail=f"Unknown action '{action}'. Supported: {', '.join(sorted(ACTIONS))}",
        )

    client = state.moonraker
    try:
        if action == "start":
            if not payload.filename:
                raise HTTPException(status_code=400, detail="filename is required to start a print")
            await client.start_print(payload.filename)
            message = f"Started {payload.filename}"
        elif action == "pause":
            await client.pause_print()
            message = "Paused"
        elif action == "resume":
            await client.resume_print()
            message = "Resumed"
        elif action == "cancel":
            await client.cancel_print()
            message = "Cancelled"
        elif action == "emergency_stop":
            await client.emergency_stop()
            message = "Emergency stop issued - firmware restart required before printing again"
        elif action == "restart_klipper":
            await client.restart_klipper()
            message = "Klipper restarting"
        elif action == "restart_firmware":
            await client.restart_firmware()
            message = "Firmware restarting"
        else:  # restart_moonraker
            await client.restart_service("moonraker")
            message = "Moonraker restarting"
    except MoonrakerError as exc:
        raise HTTPException(status_code=502, detail=exc.message) from exc

    return OKResponse(ok=True, message=message)


@router.get("/printer/events")
async def printer_events(limit: int = 50, state: AppState = Depends(get_state)) -> Dict[str, Any]:
    """Recent discrete events, for clients that reconnect after being suspended."""
    events = state.events[-max(1, min(limit, 200)) :]
    return {"events": [event.model_dump() for event in events]}
