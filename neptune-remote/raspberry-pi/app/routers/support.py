"""Diagnostics, offline knowledge base, bed mesh and backups."""

from __future__ import annotations

import time
from typing import Any, Dict, List, Optional

from fastapi import APIRouter, Body, Depends, HTTPException, Query
from fastapi.responses import FileResponse
from pydantic import BaseModel

from .. import system_info
from ..deps import get_state
from ..knowledge import TranslatedError, TroubleshootingTopic, topic, topics, translate_error
from ..moonraker import MoonrakerError
from ..schemas import OKResponse
from ..security import require_token
from ..state import AppState
from ..version import VERSION

router = APIRouter(dependencies=[Depends(require_token)])


# --------------------------------------------------------------------------- #
# System check
# --------------------------------------------------------------------------- #


class CheckResult(BaseModel):
    id: str
    name_ar: str
    name_en: str
    status: str            # ok | warning | error
    detail: str = ""
    hint_key: str = ""


class DiagnosticsReport(BaseModel):
    generated_at: float
    version: str
    overall: str
    checks: List[CheckResult]
    summary_ar: str = ""


@router.get("/diagnostics", response_model=DiagnosticsReport)
async def diagnostics(state: AppState = Depends(get_state)) -> DiagnosticsReport:
    """One screen that answers 'is everything working?' without any jargon."""
    checks: List[CheckResult] = []

    def add(identifier: str, name_ar: str, name_en: str, status: str, detail: str = "", hint: str = "") -> None:
        checks.append(
            CheckResult(
                id=identifier, name_ar=name_ar, name_en=name_en,
                status=status, detail=detail, hint_key=hint,
            )
        )

    # --- Raspberry Pi ----------------------------------------------------
    info = system_info.collect()
    pi_status = "ok"
    pi_detail = f"{info.model or info.platform}"
    if info.cpu_temp_c and info.cpu_temp_c > 80:
        pi_status = "warning"
        pi_detail += f" · CPU {info.cpu_temp_c:.0f}°C"
    if info.throttled and info.throttled not in {"ok", ""}:
        pi_status = "warning"
        pi_detail += f" · {info.throttled}"
    add("raspberry_pi", "الراسبيري باي", "Raspberry Pi", pi_status, pi_detail)

    # --- storage ---------------------------------------------------------
    usage = state.layout.usage()
    free_gb = usage.get("disk_free", 0.0) / (1024 ** 3)
    storage_status = "ok" if free_gb > 4 else ("warning" if free_gb > 1 else "error")
    add(
        "storage", "مساحة التخزين", "Storage", storage_status,
        f"{free_gb:.1f} GB free",
        "" if storage_status == "ok" else "diagnostics.hint.storage",
    )

    # --- Tailscale -------------------------------------------------------
    tail = info.tailscale
    if not tail.installed:
        add("tailscale", "تايل سكيل", "Tailscale", "warning", "not installed", "diagnostics.hint.tailscale")
    elif not tail.running:
        add("tailscale", "تايل سكيل", "Tailscale", "warning", tail.backend_state or "stopped",
            "diagnostics.hint.tailscale")
    else:
        add("tailscale", "تايل سكيل", "Tailscale", "ok", ", ".join(tail.ips) or tail.hostname)

    # --- Moonraker / Klipper --------------------------------------------
    try:
        server_info = await state.moonraker.server_info()
        add("moonraker", "مونريكر", "Moonraker", "ok",
            str(server_info.get("moonraker_version") or "connected"))
        klippy_state = str(server_info.get("klippy_state") or "unknown")
        if server_info.get("klippy_connected") and klippy_state == "ready":
            add("klipper", "كليبر", "Klipper", "ok", "ready")
        else:
            add("klipper", "كليبر", "Klipper", "error", klippy_state, "diagnostics.hint.klipper")
    except MoonrakerError as exc:
        add("moonraker", "مونريكر", "Moonraker", "error", exc.message, "diagnostics.hint.moonraker")
        add("klipper", "كليبر", "Klipper", "error", "unreachable", "diagnostics.hint.klipper")

    # --- WebSocket -------------------------------------------------------
    add(
        "websocket", "الاتصال اللحظي", "Realtime connection",
        "ok" if state.hub.client_count > 0 else "warning",
        f"{state.hub.client_count} client(s)",
    )

    # --- power -----------------------------------------------------------
    power = state.last_power
    if state.power.name == "none":
        add("power", "التحكم في الكهرباء", "Smart power", "warning", "not configured",
            "diagnostics.hint.power")
    elif power.state == "error" or not power.available:
        add("power", "التحكم في الكهرباء", "Smart power", "error",
            power.message or "unavailable", "diagnostics.hint.power")
    else:
        add("power", "التحكم في الكهرباء", "Smart power", "ok", f"{state.power.name}: {power.state}")

    # --- camera ----------------------------------------------------------
    camera = state.camera.status(probe_devices=True)
    if camera.available:
        add("camera", "الكاميرا", "Camera", "ok", camera.source)
    elif camera.devices:
        add("camera", "الكاميرا", "Camera", "warning", "detected but not configured",
            "diagnostics.hint.camera")
    else:
        add("camera", "الكاميرا", "Camera", "warning", "no camera detected", "diagnostics.hint.camera")

    # --- recording -------------------------------------------------------
    add(
        "recording", "تسجيل الفيديو", "Video recording",
        "ok" if camera.ffmpeg_available and camera.available else "warning",
        "ffmpeg found" if camera.ffmpeg_available else "ffmpeg is not installed",
        "" if camera.ffmpeg_available else "diagnostics.hint.ffmpeg",
    )

    # --- slicer ----------------------------------------------------------
    if state.engine.available:
        add("slicer", "السلايسر", "Slicer", "ok", state.engine.name)
    else:
        add("slicer", "السلايسر", "Slicer", "warning",
            f"{state.engine.binary} not found", "diagnostics.hint.slicer")

    # --- AI --------------------------------------------------------------
    vision = state.vision.status()
    if vision["mode"] == "off":
        add("vision", "مراقبة الأعطال", "Failure monitor", "warning", "switched off")
    elif vision["available"]:
        add("vision", "مراقبة الأعطال", "Failure monitor", "ok",
            f"{vision['provider']} · {vision['mode']}")
    else:
        add("vision", "مراقبة الأعطال", "Failure monitor", "warning",
            vision.get("reason", ""), "diagnostics.hint.vision")

    # --- thumbnails ------------------------------------------------------
    from ..library import thumbnails as thumbnail_module

    add(
        "thumbnails", "الصور المصغرة", "Thumbnails",
        "ok" if thumbnail_module.renderer_available() else "warning",
        "renderer ready" if thumbnail_module.renderer_available() else "numpy/Pillow missing",
    )

    errors = sum(1 for check in checks if check.status == "error")
    warnings = sum(1 for check in checks if check.status == "warning")
    overall = "error" if errors else ("warning" if warnings else "ok")
    summary = (
        "كل شيء يعمل ✓" if overall == "ok"
        else (f"{errors} مشكلة تحتاج إصلاح" if errors else f"{warnings} تحذير")
    )

    return DiagnosticsReport(
        generated_at=time.time(), version=VERSION, overall=overall,
        checks=checks, summary_ar=summary,
    )


@router.get("/diagnostics/report")
async def diagnostics_report(state: AppState = Depends(get_state)) -> Dict[str, str]:
    """Copyable plain-text report. Contains no tokens or credentials."""
    report = await diagnostics(state)  # type: ignore[arg-type]
    lines = [
        "Neptune 3 Plus Remote - diagnostics",
        f"version: {report.version}",
        f"generated: {time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(report.generated_at))}",
        f"overall: {report.overall}",
        "",
    ]
    symbols = {"ok": "OK  ", "warning": "WARN", "error": "FAIL"}
    for check in report.checks:
        lines.append(f"[{symbols.get(check.status, '?')}] {check.name_en}: {check.detail}")

    info = state.last_system or {}
    lines += [
        "",
        f"cpu: {info.get('cpu_percent', '?')}%  temp: {info.get('cpu_temp_c', '?')}C",
        f"memory: {info.get('memory_used_mb', '?')}/{info.get('memory_total_mb', '?')} MB",
        f"disk: {info.get('disk_used_gb', '?')}/{info.get('disk_total_gb', '?')} GB",
        f"printer: {state.last_status.state} / klippy {state.last_status.klippy_state}",
        f"slicer: {state.engine.name} available={state.engine.available}",
        f"power provider: {state.power.name}",
        "",
        "No credentials, tokens or IP addresses beyond the local network are included.",
    ]
    return {"report": "\n".join(lines)}


# --------------------------------------------------------------------------- #
# Knowledge base
# --------------------------------------------------------------------------- #


@router.post("/support/translate-error", response_model=TranslatedError)
async def translate(message: str = Body(..., embed=True)) -> TranslatedError:
    return translate_error(message)


@router.get("/support/topics", response_model=List[TroubleshootingTopic])
async def troubleshooting_topics() -> List[TroubleshootingTopic]:
    return topics()


@router.get("/support/topics/{topic_id}", response_model=TroubleshootingTopic)
async def troubleshooting_topic(topic_id: str) -> TroubleshootingTopic:
    found = topic(topic_id)
    if found is None:
        raise HTTPException(status_code=404, detail="Topic not found")
    return found


# --------------------------------------------------------------------------- #
# Bed mesh
# --------------------------------------------------------------------------- #


@router.get("/printer/bed-mesh")
async def bed_mesh(state: AppState = Depends(get_state)) -> Dict[str, Any]:
    """Klipper's bed mesh, plus a simple deterministic verdict."""
    try:
        status = await state.moonraker.query_objects({"bed_mesh": None})
    except MoonrakerError as exc:
        raise HTTPException(status_code=502, detail=exc.message) from exc

    mesh = status.get("bed_mesh") or {}
    matrix = mesh.get("probed_matrix") or mesh.get("mesh_matrix") or []
    values = [value for row in matrix for value in row if isinstance(value, (int, float))]

    if not values:
        return {
            "available": False,
            "profile_name": mesh.get("profile_name") or "",
            "message_key": "bedmesh.none",
        }

    highest = max(values)
    lowest = min(values)
    span = highest - lowest

    if span <= 0.10:
        verdict, verdict_key = "excellent", "bedmesh.verdict.excellent"
    elif span <= 0.25:
        verdict, verdict_key = "good", "bedmesh.verdict.good"
    else:
        verdict, verdict_key = "needs_attention", "bedmesh.verdict.needs_attention"

    return {
        "available": True,
        "profile_name": mesh.get("profile_name") or "",
        "matrix": matrix,
        "mesh_min": mesh.get("mesh_min"),
        "mesh_max": mesh.get("mesh_max"),
        "highest": round(highest, 4),
        "lowest": round(lowest, 4),
        "range": round(span, 4),
        "verdict": verdict,
        "verdict_key": verdict_key,
        "thresholds": {"excellent": 0.10, "good": 0.25},
    }


# --------------------------------------------------------------------------- #
# Backups
# --------------------------------------------------------------------------- #


@router.get("/backups")
async def list_backups(state: AppState = Depends(get_state)) -> List[Dict[str, Any]]:
    return [backup.as_dict() for backup in state.backups.list()]


@router.post("/backups")
async def create_backup(
    include_profiles: bool = Body(True, embed=True), state: AppState = Depends(get_state)
) -> Dict[str, Any]:
    try:
        backup = state.backups.create(include_profiles=include_profiles)
    except OSError as exc:
        raise HTTPException(status_code=500, detail=f"Backup failed: {exc}") from exc
    return backup.as_dict()


@router.get("/backups/{filename}/download")
async def download_backup(filename: str, state: AppState = Depends(get_state)) -> FileResponse:
    path = state.backups.get(filename)
    if path is None:
        raise HTTPException(status_code=404, detail="Backup not found")
    return FileResponse(path, media_type="application/zip", filename=path.name)


@router.delete("/backups/{filename}", response_model=OKResponse)
async def delete_backup(filename: str, state: AppState = Depends(get_state)) -> OKResponse:
    if not state.backups.delete(filename):
        raise HTTPException(status_code=404, detail="Backup not found")
    return OKResponse(ok=True, message="Backup deleted")


# --------------------------------------------------------------------------- #
# Storage
# --------------------------------------------------------------------------- #


@router.get("/storage")
async def storage(state: AppState = Depends(get_state)) -> Dict[str, Any]:
    usage = state.layout.usage()
    return {
        "root": str(state.layout.root),
        "usage_bytes": usage,
        "videos": state.videos.storage_summary(),
    }
