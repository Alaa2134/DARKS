"""Health, system information and profile listing."""

from __future__ import annotations

import time

from fastapi import APIRouter, Depends

from .. import system_info
from ..deps import get_state
from ..schemas import ProfileInfo, ProfileListResponse, SystemResponse
from ..security import require_token
from ..state import AppState
from ..version import VERSION

router = APIRouter()


@router.get("/health", summary="Liveness probe and capability report")
async def health(state: AppState = Depends(get_state)) -> dict:
    reachable = await state.moonraker.is_reachable()
    camera = state.camera.status(probe_devices=False)
    vision = state.vision.status()
    from ..library import thumbnails as thumbnail_module

    return {
        "ok": True,
        "version": VERSION,
        "moonraker_reachable": reachable,
        "moonraker_url": state.config.moonraker.base_url,
        "power_provider": state.power.name,
        "slicer_engine": state.engine.name,
        "slicer_available": state.engine.available,
        "auth_required": state.config.server.auth_required,
        "server_time": time.time(),
        "camera_available": camera.available,
        "camera_source": camera.source,
        "ffmpeg_available": camera.ffmpeg_available,
        "recording_mode": state.config.recording.mode,
        "timelapse_mode": state.config.timelapse.mode,
        "vision_mode": vision["mode"],
        "vision_provider": vision["provider"],
        "vision_available": vision["available"],
        "thumbnails_available": thumbnail_module.renderer_available(),
        "storage_root": str(state.layout.root),
        "library_items": state.library.stats().get("total", 0),
    }


@router.get(
    "/summary",
    dependencies=[Depends(require_token)],
    summary="Everything the Home screen needs in a single request",
)
async def summary(state: AppState = Depends(get_state)) -> dict:
    return state.status_summary()


@router.get(
    "/system",
    response_model=SystemResponse,
    dependencies=[Depends(require_token)],
    summary="Raspberry Pi CPU, memory, disk, uptime and Tailscale status",
)
async def system() -> SystemResponse:
    return system_info.collect()


@router.get(
    "/profiles",
    response_model=ProfileListResponse,
    dependencies=[Depends(require_token)],
    summary="Slicing profiles available on the Raspberry Pi",
)
async def profiles(state: AppState = Depends(get_state)) -> ProfileListResponse:
    grouped = state.profiles.all()

    def convert(kind: str) -> list[ProfileInfo]:
        return [
            ProfileInfo(
                id=profile.id,
                name=profile.name,
                kind=kind,
                description=profile.description,
                values=profile.values,
            )
            for profile in grouped.get(kind, [])
        ]

    return ProfileListResponse(
        printers=convert("printer"),
        filaments=convert("filament"),
        prints=convert("print"),
    )


@router.get(
    "/slicer/info",
    dependencies=[Depends(require_token)],
    summary="Which slicer engine is installed and usable",
)
async def slicer_info(state: AppState = Depends(get_state)) -> dict:
    return {
        "engine": state.engine.name,
        "binary": state.engine.binary,
        "resolved_binary": state.engine.resolve_binary(),
        "available": state.engine.available,
        "version": await state.engine.version(),
        "profiles_dir": str(state.profiles.root),
    }
