"""Slicing endpoints."""

from __future__ import annotations

from typing import Any, Dict, List

from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import FileResponse

from ..deps import get_state
from ..schemas import OKResponse, SliceJob, SliceJobSummary, SliceRequest
from ..security import require_token
from ..slicer import modes as print_modes
from ..state import AppState

router = APIRouter(dependencies=[Depends(require_token)])


@router.get("/slice/modes")
async def slice_modes(
    printer_profile: str = Query("neptune3plus_0.4"),
    filament_profile: str = Query("pla"),
    state: AppState = Depends(get_state),
) -> Dict[str, Any]:
    """Every print mode, resolved against this printer and this material.

    A mode is an intent - draft, strong, fine detail - not a fixed set of
    numbers. What it becomes depends on the nozzle, on how fast the material
    can melt, and on the machine's own limits, so the same mode is genuinely
    different settings on PLA and on PETG. Anything that had to be clamped
    comes back with both numbers and the reason, because a mode called "fast"
    that the printer then silently slows down is worse than no mode at all.
    """
    printer = state.profiles.get("printer", printer_profile)
    filament = state.profiles.get("filament", filament_profile)

    # The live config is what Klipper actually enforces; the slicer's printer
    # profile is only a description of it and can drift out of date.
    config = await state.refresh_live_config()
    max_accel = config.max_accel() if config else None
    max_velocity = config.max_velocity() if config else None

    modes = []
    for spec_id in print_modes.MODES:
        base = print_modes.MODES[spec_id].base_profile
        print_profile = state.profiles.get("print", base)
        resolved = print_modes.resolve(
            spec_id,
            printer_values=printer.values if printer else None,
            filament_values=filament.values if filament else None,
            print_values=print_profile.values if print_profile else None,
            max_accel=max_accel,
            max_velocity=max_velocity,
        )
        if resolved is not None:
            modes.append(resolved)

    print_modes.annotate_comparison(modes)

    return {
        "modes": [mode.to_dict() for mode in modes],
        "printer_profile": printer_profile,
        "filament_profile": filament_profile,
        "limits_from_config": config is not None,
        "max_accel": max_accel,
        "max_velocity": max_velocity,
    }


def _apply_mode(request: SliceRequest, state: AppState) -> SliceRequest:
    """Fill in the settings a named mode implies.

    Explicit fields win. The mode decides what the caller did not, so a phone
    can send `{"model_id": ..., "mode": "strong"}` and still override one value
    without having to restate the other eleven.

    The live config is not consulted here: this path runs on every slice and
    reading printer.cfg costs a Moonraker round trip. The profile limits are
    close enough for the settings themselves, and /slice/modes - which the user
    is looking at when they choose - does use the live values.
    """
    printer = state.profiles.get("printer", request.printer_profile)
    filament = state.profiles.get("filament", request.filament_profile)
    spec = print_modes.MODES.get(request.mode or "")
    if spec is None:
        raise HTTPException(
            status_code=400,
            detail=(
                f"Unknown print mode '{request.mode}' "
                f"(available: {', '.join(print_modes.MODES)})"
            ),
        )

    print_profile = state.profiles.get("print", spec.base_profile)
    resolved = print_modes.resolve(
        request.mode,
        printer_values=printer.values if printer else None,
        filament_values=filament.values if filament else None,
        print_values=print_profile.values if print_profile else None,
    )
    if resolved is None:
        return request

    updated = request.model_copy()
    if updated.print_profile == "standard":
        # Only when the caller left it at the default - an explicitly chosen
        # profile is a decision the mode must not overwrite.
        updated.print_profile = resolved.base_profile
    for field, value in resolved.overrides().items():
        if field == "print_profile":
            continue
        if getattr(updated, field, None) is None:
            setattr(updated, field, value)

    speeds = dict(resolved.speed_overrides())
    speeds.update(updated.speed_profile_overrides)
    updated.speed_profile_overrides = speeds
    return updated


@router.post("/slice", response_model=SliceJob, status_code=202)
async def start_slice(request: SliceRequest, state: AppState = Depends(get_state)) -> SliceJob:
    # Checked first: a misspelled mode is the caller's mistake and has nothing
    # to do with whether a slicer is installed, so it should not be reported as
    # a 503 about PrusaSlicer.
    if request.mode and request.mode not in print_modes.MODES:
        raise HTTPException(
            status_code=400,
            detail=(
                f"Unknown print mode '{request.mode}' "
                f"(available: {', '.join(print_modes.MODES)})"
            ),
        )

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
    if request.mode:
        request = _apply_mode(request, state)

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
