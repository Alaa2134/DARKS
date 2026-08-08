"""Slicing endpoints."""

from __future__ import annotations

from typing import List

from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import FileResponse

from ..deps import get_state
from ..schemas import OKResponse, SliceJob, SliceJobSummary, SliceRequest
from ..security import require_token
from ..state import AppState

router = APIRouter(dependencies=[Depends(require_token)])


@router.post("/slice", response_model=SliceJob, status_code=202)
async def start_slice(request: SliceRequest, state: AppState = Depends(get_state)) -> SliceJob:
    # Verify rather than just look for the file. An installed slicer that
    # cannot start - a missing system locale is the usual cause on a fresh
    # Raspberry Pi OS image - would otherwise be accepted here and fail deep
    # inside the job, where the reason is much harder to see.
    if not await state.engine.verify():
        reason = state.engine.verify_error
        raise HTTPException(
            status_code=503,
            detail=(
                f"Slicer '{state.engine.binary}' cannot run on the Raspberry Pi."
                + (f" {reason}" if reason else "")
                + " Run raspberry-pi/install.sh or install prusa-slicer manually."
            ),
        )
    for kind, profile_id in (
        ("printer", request.printer_profile),
        ("filament", request.filament_profile),
        ("print", request.print_profile),
    ):
        if state.profiles.get(kind, profile_id) is None and state.profiles.orca_profile(kind, profile_id) is None:
            available = ", ".join(p.id for p in state.profiles.list(kind)) or "none"
            raise HTTPException(
                status_code=400,
                detail=f"Unknown {kind} profile '{profile_id}' (available: {available})",
            )

    try:
        return state.slice_jobs.submit(request, on_complete=state.upload_sliced_gcode)
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@router.get("/slice", response_model=List[SliceJobSummary])
async def list_slice_jobs(state: AppState = Depends(get_state)) -> List[SliceJobSummary]:
    return state.slice_jobs.list()


@router.get("/slice/{job_id}", response_model=SliceJob)
async def get_slice_job(job_id: str, state: AppState = Depends(get_state)) -> SliceJob:
    job = state.slice_jobs.get(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="Slice job not found")
    return job


@router.delete("/slice/{job_id}", response_model=OKResponse)
async def cancel_slice_job(job_id: str, state: AppState = Depends(get_state)) -> OKResponse:
    if state.slice_jobs.get(job_id) is None:
        raise HTTPException(status_code=404, detail="Slice job not found")
    if not state.slice_jobs.cancel(job_id):
        raise HTTPException(status_code=409, detail="Job already finished")
    return OKResponse(ok=True, message="Slice job cancelled")


@router.get("/slice/{job_id}/download")
async def download_slice_output(job_id: str, state: AppState = Depends(get_state)) -> FileResponse:
    job = state.slice_jobs.get(job_id)
    if job is None or not job.output_path:
        raise HTTPException(status_code=404, detail="Slice output not available")
    from pathlib import Path

    path = Path(job.output_path)
    if not path.is_file():
        raise HTTPException(status_code=404, detail="Slice output file is missing")
    return FileResponse(path, filename=path.name, media_type="text/plain")


@router.post("/slice/{job_id}/print", response_model=OKResponse)
async def print_slice_output(job_id: str, state: AppState = Depends(get_state)) -> OKResponse:
    job = state.slice_jobs.get(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="Slice job not found")
    if job.status != "done":
        raise HTTPException(status_code=409, detail=f"Slice job is {job.status}")

    target = job.moonraker_path or job.output_filename
    if job.moonraker_path is None:
        from pathlib import Path

        from ..moonraker import MoonrakerError

        path = Path(job.output_path)
        if not path.is_file():
            raise HTTPException(status_code=404, detail="Slice output file is missing")
        try:
            result = await state.moonraker.upload_gcode(path.name, path.read_bytes())
        except (MoonrakerError, OSError) as exc:
            detail = getattr(exc, "message", None) or str(exc)
            raise HTTPException(status_code=502, detail=detail) from exc
        item = result.get("item") if isinstance(result, dict) else None
        target = str(item.get("path")) if isinstance(item, dict) else path.name
        job.moonraker_path = target

    from ..moonraker import MoonrakerError

    try:
        await state.moonraker.start_print(target)
    except MoonrakerError as exc:
        raise HTTPException(status_code=502, detail=exc.message) from exc
    return OKResponse(ok=True, message=f"Printing {target}")
