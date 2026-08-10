"""Model and G-code file management."""

from __future__ import annotations

import posixpath
from pathlib import Path
from typing import Any, Dict, List, Optional

from fastapi import APIRouter, Depends, File, HTTPException, Query, UploadFile
from fastapi.responses import FileResponse, Response

from ..deps import get_state
from ..moonraker import MoonrakerError
from ..schemas import AppliedColorChange, GCodeFile, ModelFile, OKResponse, UploadResponse
from ..security import require_token
from ..slicer.engine import SUPPORTED_MODEL_EXTENSIONS
from ..slicer.gcode_meta import color_changes, parse_gcode
from ..state import AppState

router = APIRouter(dependencies=[Depends(require_token)])

MAX_UPLOAD_BYTES = 512 * 1024 * 1024  # 512 MB


# --------------------------------------------------------------------------- #
# Models
# --------------------------------------------------------------------------- #


@router.get("/models", response_model=List[ModelFile])
async def list_models(state: AppState = Depends(get_state)) -> List[ModelFile]:
    return state.models.list()


@router.post("/models/upload", response_model=UploadResponse)
async def upload_model(
    file: UploadFile = File(...), state: AppState = Depends(get_state)
) -> UploadResponse:
    extension = Path(file.filename or "").suffix.lower()
    if extension not in SUPPORTED_MODEL_EXTENSIONS:
        raise HTTPException(
            status_code=400,
            detail=f"Unsupported model type '{extension or 'unknown'}'. Supported: "
            + ", ".join(sorted(SUPPORTED_MODEL_EXTENSIONS)),
        )

    content = await file.read()
    if not content:
        raise HTTPException(status_code=400, detail="Uploaded file is empty")
    if len(content) > MAX_UPLOAD_BYTES:
        raise HTTPException(status_code=413, detail="Model exceeds the 512 MB upload limit")

    model = state.models.save(file.filename or f"model{extension}", content)
    return UploadResponse(
        ok=True, id=model.id, filename=model.filename, size=model.size, path=model.id
    )


@router.get("/models/{model_id}", response_model=ModelFile)
async def get_model(model_id: str, state: AppState = Depends(get_state)) -> ModelFile:
    model = state.models.get(model_id)
    if model is None:
        raise HTTPException(status_code=404, detail="Model not found")
    return model


@router.get("/models/{model_id}/download")
async def download_model(model_id: str, state: AppState = Depends(get_state)) -> FileResponse:
    path = state.models.path_for(model_id)
    if path is None:
        raise HTTPException(status_code=404, detail="Model not found")
    original = path.name.split("__", 1)[-1]
    return FileResponse(path, filename=original, media_type="application/octet-stream")


@router.delete("/models/{model_id}", response_model=OKResponse)
async def delete_model(model_id: str, state: AppState = Depends(get_state)) -> OKResponse:
    if not state.models.delete(model_id):
        raise HTTPException(status_code=404, detail="Model not found")
    return OKResponse(ok=True, message="Model deleted")


# --------------------------------------------------------------------------- #
# G-code
# --------------------------------------------------------------------------- #


def _thumbnail_path(filename: str, metadata: Dict[str, Any]) -> Optional[str]:
    thumbnails = metadata.get("thumbnails")
    if not isinstance(thumbnails, list) or not thumbnails:
        return None
    best = max(
        (t for t in thumbnails if isinstance(t, dict)),
        key=lambda t: int(t.get("size") or 0),
        default=None,
    )
    if not best:
        return None
    relative = str(best.get("relative_path") or "")
    if not relative:
        return None
    directory = posixpath.dirname(filename)
    return posixpath.join(directory, relative) if directory else relative


def _moonraker_entry(entry: Dict[str, Any]) -> GCodeFile:
    path = str(entry.get("path") or entry.get("filename") or "")
    return GCodeFile(
        path=path,
        filename=posixpath.basename(path),
        size=int(entry.get("size") or 0),
        modified=float(entry.get("modified") or 0.0),
        estimated_time=_optional_float(entry.get("estimated_time")),
        filament_total_mm=_optional_float(entry.get("filament_total")),
        filament_weight_g=_optional_float(entry.get("filament_weight_total")),
        layer_height=_optional_float(entry.get("layer_height")),
        first_layer_height=_optional_float(entry.get("first_layer_height")),
        object_height=_optional_float(entry.get("object_height")),
        filament_type=_optional_str(entry.get("filament_type")),
        filament_name=_optional_str(entry.get("filament_name")),
        slicer=_optional_str(entry.get("slicer")),
        thumbnail_path=_thumbnail_path(path, entry),
        layer_count=_optional_int(entry.get("layer_count")),
        source="moonraker",
    )


def _optional_float(value: Any) -> Optional[float]:
    return float(value) if isinstance(value, (int, float)) else None


def _optional_int(value: Any) -> Optional[int]:
    return int(value) if isinstance(value, (int, float)) else None


def _optional_str(value: Any) -> Optional[str]:
    return str(value) if isinstance(value, str) and value else None


@router.get("/gcodes", response_model=List[GCodeFile])
async def list_gcodes(
    include_local: bool = Query(True, description="Also list G-code sliced on the Pi"),
    state: AppState = Depends(get_state),
) -> List[GCodeFile]:
    files: List[GCodeFile] = []

    try:
        entries = await state.moonraker.list_gcodes()
        files.extend(_moonraker_entry(entry) for entry in entries if isinstance(entry, dict))
    except MoonrakerError:
        # Moonraker offline: still return the locally sliced files.
        pass

    if include_local:
        known = {f.filename for f in files}
        for path in state.gcodes.list():
            if path.name in known:
                continue
            meta = parse_gcode(path)
            filament_mm = meta.get("filament_mm")
            files.append(
                GCodeFile(
                    path=path.name,
                    filename=path.name,
                    size=path.stat().st_size,
                    modified=path.stat().st_mtime,
                    estimated_time=_optional_float(meta.get("estimated_time")),
                    filament_total_mm=_optional_float(filament_mm),
                    filament_weight_g=_optional_float(meta.get("filament_grams")),
                    layer_height=_optional_float(meta.get("layer_height")),
                    object_height=_optional_float(meta.get("object_height")),
                    filament_type=_optional_str(meta.get("filament_type")),
                    slicer=_optional_str(meta.get("slicer")),
                    layer_count=_optional_int(meta.get("layer_count")),
                    color_changes=[
                        AppliedColorChange(layer=c.layer, color=c.color, z=c.z)
                        for c in color_changes(path)
                    ],
                    source="backend",
                )
            )

    files.sort(key=lambda f: f.modified, reverse=True)
    return files


@router.get("/gcodes/metadata", response_model=GCodeFile)
async def gcode_metadata(
    path: str = Query(..., description="Path relative to the Moonraker gcodes root"),
    state: AppState = Depends(get_state),
) -> GCodeFile:
    try:
        metadata = await state.moonraker.metadata(path)
    except MoonrakerError as exc:
        raise HTTPException(status_code=502, detail=exc.message) from exc
    metadata.setdefault("path", path)
    entry = _moonraker_entry(metadata)

    # Moonraker does not know about colour changes - they are our own header,
    # written after slicing. The copy we sliced is still on the Pi under the
    # same name, so the plan is read from there. Only on this endpoint, never
    # in the listing: opening every file to check would make the file list slow
    # on a Pi in exactly the way a file list must not be.
    local = state.gcodes.path_for(entry.filename)
    if local.is_file():
        entry.color_changes = [
            AppliedColorChange(layer=item.layer, color=item.color, z=item.z)
            for item in color_changes(local)
        ]
    return entry


@router.get("/gcodes/thumbnail")
async def gcode_thumbnail(
    path: str = Query(..., description="thumbnail_path returned by /api/gcodes"),
    state: AppState = Depends(get_state),
) -> Response:
    try:
        data = await state.moonraker.thumbnail(path)
    except MoonrakerError as exc:
        raise HTTPException(status_code=502, detail=exc.message) from exc
    media_type = "image/png" if path.lower().endswith(".png") else "image/jpeg"
    return Response(content=data, media_type=media_type, headers={"Cache-Control": "max-age=3600"})


@router.post("/gcodes/upload", response_model=UploadResponse)
async def upload_gcode(
    file: UploadFile = File(...),
    start_print: bool = Query(False),
    state: AppState = Depends(get_state),
) -> UploadResponse:
    name = Path(file.filename or "").name
    if not name.lower().endswith((".gcode", ".gco", ".g")):
        raise HTTPException(status_code=400, detail="Only .gcode/.gco/.g files can be uploaded")

    content = await file.read()
    if not content:
        raise HTTPException(status_code=400, detail="Uploaded file is empty")
    if len(content) > MAX_UPLOAD_BYTES:
        raise HTTPException(status_code=413, detail="G-code exceeds the 512 MB upload limit")

    try:
        result = await state.moonraker.upload_gcode(name, content, start_print=start_print)
    except MoonrakerError as exc:
        raise HTTPException(status_code=502, detail=exc.message) from exc

    item = result.get("item") if isinstance(result, dict) else None
    path = str(item.get("path")) if isinstance(item, dict) else name
    return UploadResponse(ok=True, filename=name, size=len(content), path=path)


@router.post("/gcodes/send/{name}", response_model=UploadResponse)
async def send_local_gcode(
    name: str,
    start_print: bool = Query(False),
    state: AppState = Depends(get_state),
) -> UploadResponse:
    """Push a G-code file sliced on the Pi into Moonraker."""
    path = state.gcodes.path_for(name)
    if not path.is_file():
        raise HTTPException(status_code=404, detail="Local G-code not found")
    try:
        result = await state.moonraker.upload_gcode(
            path.name, path.read_bytes(), start_print=start_print
        )
    except (MoonrakerError, OSError) as exc:
        detail = getattr(exc, "message", None) or str(exc)
        raise HTTPException(status_code=502, detail=detail) from exc

    item = result.get("item") if isinstance(result, dict) else None
    remote_path = str(item.get("path")) if isinstance(item, dict) else path.name
    return UploadResponse(
        ok=True, filename=path.name, size=path.stat().st_size, path=remote_path
    )


@router.get("/gcodes/local/{name}/download")
async def download_local_gcode(name: str, state: AppState = Depends(get_state)) -> FileResponse:
    path = state.gcodes.path_for(name)
    if not path.is_file():
        raise HTTPException(status_code=404, detail="Local G-code not found")
    return FileResponse(path, filename=path.name, media_type="text/plain")


@router.delete("/gcodes/local/{name}", response_model=OKResponse)
async def delete_local_gcode(name: str, state: AppState = Depends(get_state)) -> OKResponse:
    if not state.gcodes.delete(name):
        raise HTTPException(status_code=404, detail="Local G-code not found")
    return OKResponse(ok=True, message="Deleted")


@router.delete("/gcodes", response_model=OKResponse)
async def delete_gcode(
    path: str = Query(..., description="Path relative to the Moonraker gcodes root"),
    state: AppState = Depends(get_state),
) -> OKResponse:
    try:
        await state.moonraker.delete_gcode(path)
    except MoonrakerError as exc:
        raise HTTPException(status_code=502, detail=exc.message) from exc
    return OKResponse(ok=True, message=f"Deleted {path}")
