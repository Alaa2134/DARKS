"""Local AI print-failure detection endpoints."""

from __future__ import annotations

from typing import Any, Dict, List, Optional

from fastapi import APIRouter, Body, Depends, HTTPException, Query
from fastapi.responses import FileResponse
from pydantic import BaseModel

from ..deps import get_state
from ..schemas import OKResponse
from ..security import require_token
from ..state import AppState
from ..vision.detector import MODES

router = APIRouter(dependencies=[Depends(require_token)])


class VisionSettings(BaseModel):
    mode: Optional[str] = None
    provider: Optional[str] = None
    interval_seconds: Optional[float] = None
    min_confidence: Optional[float] = None
    confirmations: Optional[int] = None
    window_seconds: Optional[float] = None
    first_layer_interval_seconds: Optional[float] = None
    only_while_printing: Optional[bool] = None
    roi: Optional[List[float]] = None


@router.get("/vision/status")
async def vision_status(state: AppState = Depends(get_state)) -> Dict[str, Any]:
    return state.vision.status()


@router.post("/vision/settings")
async def update_vision_settings(
    settings: VisionSettings, state: AppState = Depends(get_state)
) -> Dict[str, Any]:
    config = state.config.vision
    rebuild = False

    if settings.mode is not None:
        if settings.mode not in MODES:
            raise HTTPException(
                status_code=400, detail=f"mode must be one of {', '.join(MODES)}"
            )
        config.mode = settings.mode
    if settings.provider is not None:
        config.provider = settings.provider
        rebuild = True
    if settings.interval_seconds is not None:
        config.interval_seconds = max(1.0, float(settings.interval_seconds))
    if settings.min_confidence is not None:
        config.min_confidence = min(0.99, max(0.1, float(settings.min_confidence)))
    if settings.confirmations is not None:
        config.confirmations = max(1, int(settings.confirmations))
    if settings.window_seconds is not None:
        config.window_seconds = max(5.0, float(settings.window_seconds))
    if settings.first_layer_interval_seconds is not None:
        config.first_layer_interval_seconds = max(1.0, float(settings.first_layer_interval_seconds))
    if settings.only_while_printing is not None:
        config.only_while_printing = bool(settings.only_while_printing)
    if settings.roi is not None:
        if len(settings.roi) != 4 or any(value < 0 or value > 1 for value in settings.roi):
            raise HTTPException(status_code=400, detail="roi must be four values between 0 and 1")
        config.roi = settings.roi
        state.vision.set_roi(settings.roi)

    if rebuild:
        state.vision.rebuild_provider()

    # Apply the mode change immediately.
    if config.mode == "off":
        await state.vision.stop()
    elif state.last_status.state == "printing":
        await state.vision.start()

    state.db.set_state("vision.settings", config.model_dump())
    return state.vision.status()


@router.get("/vision/events")
async def vision_events(
    limit: int = Query(100, ge=1, le=500),
    confirmed_only: bool = False,
    state: AppState = Depends(get_state),
) -> Dict[str, Any]:
    events = state.vision.events(limit=limit, confirmed_only=confirmed_only)
    return {"events": [event.as_dict() for event in events], "count": len(events)}


@router.get("/vision/events/{event_id}/snapshot")
async def vision_event_snapshot(event_id: str, state: AppState = Depends(get_state)) -> FileResponse:
    path = state.vision.snapshot_path(event_id)
    if path is None:
        raise HTTPException(status_code=404, detail="No snapshot for this event")
    return FileResponse(path, media_type="image/jpeg")


@router.post("/vision/events/{event_id}/acknowledge", response_model=OKResponse)
async def acknowledge_event(event_id: str, state: AppState = Depends(get_state)) -> OKResponse:
    if not state.vision.acknowledge(event_id):
        raise HTTPException(status_code=404, detail="Event not found")
    return OKResponse(ok=True, message="Acknowledged")


@router.delete("/vision/events", response_model=OKResponse)
async def clear_events(state: AppState = Depends(get_state)) -> OKResponse:
    removed = state.vision.clear_events()
    return OKResponse(ok=True, message=f"Removed {removed} event(s)")


@router.post("/vision/start", response_model=OKResponse)
async def start_vision(state: AppState = Depends(get_state)) -> OKResponse:
    started = await state.vision.start()
    if not started:
        status = state.vision.status()
        raise HTTPException(
            status_code=503,
            detail=status.get("reason") or "The failure monitor could not start",
        )
    return OKResponse(ok=True, message="Failure monitor running")


@router.post("/vision/stop", response_model=OKResponse)
async def stop_vision(state: AppState = Depends(get_state)) -> OKResponse:
    await state.vision.stop()
    return OKResponse(ok=True, message="Failure monitor stopped")


@router.post("/vision/first-layer-ok", response_model=OKResponse)
async def first_layer_ok(state: AppState = Depends(get_state)) -> OKResponse:
    """User confirmed the first layer looks good - relax the extra sampling."""
    state.vision.confirm_first_layer_ok()
    return OKResponse(ok=True, message="Thanks - first layer confirmed")
