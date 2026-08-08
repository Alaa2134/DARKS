"""Camera, recording, timelapse and video library endpoints."""

from __future__ import annotations

from typing import Any, Dict, List, Optional

from fastapi import APIRouter, Body, Depends, HTTPException, Query
from fastapi.responses import FileResponse, Response

from ..camera.devices import discover
from ..deps import get_state
from ..recording.service import RecordingError
from ..recording.store import VideoRecord
from ..schemas import OKResponse
from ..security import require_token
from ..state import AppState

router = APIRouter(dependencies=[Depends(require_token)])


# --------------------------------------------------------------------------- #
# Camera
# --------------------------------------------------------------------------- #


@router.get("/camera/status")
async def camera_status(
    probe: bool = Query(True, description="Scan /dev/video* (slower)"),
    state: AppState = Depends(get_state),
) -> Dict[str, Any]:
    return state.camera.status(probe_devices=probe).as_dict()


@router.get("/camera/devices")
async def camera_devices() -> Dict[str, Any]:
    """Detected cameras with their supported modes and a recommendation."""
    devices = discover()
    return {
        "count": len(devices),
        "devices": [
            {
                "path": device.path,
                "name": device.name,
                "driver": device.driver,
                "bus": device.bus,
                "modes": [
                    {
                        "width": mode.width, "height": mode.height, "fps": mode.fps,
                        "pixel_format": mode.pixel_format, "label": mode.label,
                    }
                    for mode in device.modes
                ],
                "recommended": (
                    {
                        "width": device.recommended_mode().width,
                        "height": device.recommended_mode().height,
                        "fps": device.recommended_mode().fps,
                        "label": device.recommended_mode().label,
                    } if device.recommended_mode() else None
                ),
            }
            for device in devices
        ],
    }


@router.get("/camera/snapshot")
async def camera_snapshot(state: AppState = Depends(get_state)) -> Response:
    data = await state.camera.snapshot()
    if not data:
        raise HTTPException(
            status_code=503,
            detail=state.camera.last_error or "Camera is not available",
        )
    return Response(content=data, media_type="image/jpeg", headers={"Cache-Control": "no-store"})


@router.post("/camera/snapshot/save")
async def save_snapshot(state: AppState = Depends(get_state)) -> Dict[str, Any]:
    path = await state.capture_snapshot(prefix="manual")
    if path is None:
        raise HTTPException(
            status_code=503, detail=state.camera.last_error or "Camera is not available"
        )
    return {"ok": True, "path": state.layout.relative(path), "filename": path.name}


@router.get("/camera/snapshots")
async def list_snapshots(
    limit: int = Query(60, ge=1, le=500), state: AppState = Depends(get_state)
) -> List[Dict[str, Any]]:
    files = sorted(
        state.layout.snapshots.glob("*.jpg"), key=lambda item: item.stat().st_mtime, reverse=True
    )
    return [
        {
            "filename": path.name,
            "path": state.layout.relative(path),
            "size": path.stat().st_size,
            "created_at": path.stat().st_mtime,
        }
        for path in files[:limit]
    ]


@router.post("/camera/roi", response_model=OKResponse)
async def set_roi(
    roi: Optional[List[float]] = Body(None, embed=True),
    state: AppState = Depends(get_state),
) -> OKResponse:
    """Store the print-bed region (x, y, w, h as 0..1) used by the AI monitor."""
    if roi is not None:
        if len(roi) != 4 or any(value < 0 or value > 1 for value in roi):
            raise HTTPException(status_code=400, detail="roi must be four values between 0 and 1")
    state.config.camera.roi = roi
    state.vision.set_roi(roi)
    state.db.set_state("camera.roi", roi)
    return OKResponse(ok=True, message="Region of interest saved")


# --------------------------------------------------------------------------- #
# Recording
# --------------------------------------------------------------------------- #


@router.get("/camera/record/status")
async def recording_status(state: AppState = Depends(get_state)) -> Dict[str, Any]:
    return state.recording.status()


@router.post("/camera/record/start", response_model=VideoRecord)
async def start_recording(state: AppState = Depends(get_state)) -> VideoRecord:
    try:
        return await state.start_recording_manual()
    except RecordingError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


@router.post("/camera/record/stop")
async def stop_recording(state: AppState = Depends(get_state)) -> Dict[str, Any]:
    record = await state.recording.stop(result="completed")
    if record is None:
        raise HTTPException(
            status_code=409,
            detail=state.recording.last_error or "No recording was running, or it produced no video",
        )
    return record.model_dump()


# --------------------------------------------------------------------------- #
# Timelapse
# --------------------------------------------------------------------------- #


@router.get("/timelapse/status")
async def timelapse_status(state: AppState = Depends(get_state)) -> Dict[str, Any]:
    return state.timelapse.status()


@router.post("/timelapse/start", response_model=OKResponse)
async def timelapse_start(state: AppState = Depends(get_state)) -> OKResponse:
    started = await state.timelapse.start(gcode_name=state.last_status.filename,
                                          item_id=state.current_item_id)
    if not started:
        raise HTTPException(
            status_code=409,
            detail="Timelapse is off in config.yaml, or a session is already running",
        )
    return OKResponse(ok=True, message="Timelapse started")


@router.post("/timelapse/frame", response_model=OKResponse)
async def timelapse_frame(state: AppState = Depends(get_state)) -> OKResponse:
    """Called by the Klipper layer macro (see /api/timelapse/macro)."""
    captured = await state.timelapse.capture_frame()
    if not captured:
        raise HTTPException(
            status_code=409,
            detail=state.timelapse.last_error or "No timelapse session is running",
        )
    return OKResponse(ok=True, message="Frame captured")


@router.post("/timelapse/finish")
async def timelapse_finish(state: AppState = Depends(get_state)) -> Dict[str, Any]:
    record = await state.timelapse.finish(result="completed")
    if record is None:
        raise HTTPException(
            status_code=409,
            detail=state.timelapse.last_error or "Nothing to render",
        )
    return record.model_dump()


@router.get("/timelapse/macro")
async def timelapse_macro(state: AppState = Depends(get_state)) -> Dict[str, Any]:
    """The printer.cfg snippet for layer-based timelapse.

    Returned as text for the user to copy. Neptune Remote never writes to
    printer.cfg itself.
    """
    return {
        "requires_approval": True,
        "warning": "Neptune Remote does not edit printer.cfg. Copy this yourself and restart Klipper.",
        "macro": state.timelapse.suggested_macro(
            port=state.config.server.port, token=state.config.server.api_token
        ),
    }


# --------------------------------------------------------------------------- #
# Videos
# --------------------------------------------------------------------------- #


@router.get("/videos", response_model=List[VideoRecord])
async def list_videos(
    kind: Optional[str] = Query(None, pattern="^(recording|timelapse)$"),
    limit: int = Query(100, ge=1, le=500),
    state: AppState = Depends(get_state),
) -> List[VideoRecord]:
    return state.videos.list(kind=kind, limit=limit)


@router.get("/videos/storage")
async def video_storage(state: AppState = Depends(get_state)) -> Dict[str, Any]:
    summary = state.videos.storage_summary()
    summary["retention_policy"] = state.config.recording.retention_policy
    summary["retention_max_gb"] = state.config.recording.retention_max_gb
    summary["retention_keep_last"] = state.config.recording.retention_keep_last
    return summary


@router.post("/videos/cleanup")
async def cleanup_videos(state: AppState = Depends(get_state)) -> Dict[str, Any]:
    removed = state.videos.apply_retention(
        policy=state.config.recording.retention_policy,
        max_gigabytes=state.config.recording.retention_max_gb,
        keep_last=state.config.recording.retention_keep_last,
        active_ids=[state.recording.active_video_id] if state.recording.active_video_id else [],
    )
    return {"removed": removed, "count": len(removed)}


@router.get("/videos/{video_id}", response_model=VideoRecord)
async def get_video(video_id: str, state: AppState = Depends(get_state)) -> VideoRecord:
    record = state.videos.get(video_id)
    if record is None:
        raise HTTPException(status_code=404, detail="Video not found")
    return record


@router.get("/videos/{video_id}/download")
async def download_video(video_id: str, state: AppState = Depends(get_state)) -> FileResponse:
    record = state.videos.get(video_id)
    if record is None:
        raise HTTPException(status_code=404, detail="Video not found")
    if record.result == "in_progress":
        raise HTTPException(status_code=409, detail="This recording is still being written")
    try:
        path = state.layout.resolve(record.path)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    if not path.is_file():
        raise HTTPException(status_code=404, detail="Video file is missing on disk")
    return FileResponse(path, media_type="video/mp4", filename=record.filename)


@router.delete("/videos/{video_id}", response_model=OKResponse)
async def delete_video(video_id: str, state: AppState = Depends(get_state)) -> OKResponse:
    record = state.videos.get(video_id)
    if record is None:
        raise HTTPException(status_code=404, detail="Video not found")
    if record.result == "in_progress":
        raise HTTPException(status_code=409, detail="Cannot delete a recording that is in progress")
    state.videos.delete(video_id)
    return OKResponse(ok=True, message="Video deleted")


@router.get("/timelapses", response_model=List[VideoRecord])
async def list_timelapses(
    limit: int = Query(100, ge=1, le=500), state: AppState = Depends(get_state)
) -> List[VideoRecord]:
    return state.videos.list(kind="timelapse", limit=limit)
