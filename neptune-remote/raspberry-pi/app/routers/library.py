"""Model library, Arabic search, collections and media serving."""

from __future__ import annotations

import mimetypes
import tempfile
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

from fastapi import APIRouter, Body, Depends, File, Form, HTTPException, Query, UploadFile
from fastapi.responses import FileResponse

from ..deps import get_state
from ..library.mesh import SUPPORTED_EXTENSIONS
from ..library.models import (
    BUILTIN_CATEGORIES,
    CategoryInfo,
    Collection,
    IdeaRequest,
    LibraryGCode,
    LibraryItem,
    LibraryItemCreate,
    LibraryItemUpdate,
    LibraryPhoto,
    PrintRating,
    SearchResponse,
    SearchResult,
)
from ..schemas import (
    ArrangeRequest,
    ArrangeResponse,
    BackupInfo,
    BackupManifestInfo,
    BackupResult,
    MeshHealth,
    MeshRepairResult,
    ModelTransform,
    OKResponse,
    OrientationReport,
    OrientationSuggestion,
    PlatePlacement,
    RestoreRequest,
    RestoreResult,
)
from ..search.arabic import normalize
from ..security import require_token
from ..state import AppState

router = APIRouter(dependencies=[Depends(require_token)])

MAX_MODEL_BYTES = 512 * 1024 * 1024
MAX_IMAGE_BYTES = 25 * 1024 * 1024


# --------------------------------------------------------------------------- #
# Items
# --------------------------------------------------------------------------- #


@router.get("/library", response_model=List[LibraryItem])
async def list_items(
    category: Optional[str] = None,
    favourites: bool = False,
    collection: Optional[str] = None,
    limit: int = Query(200, ge=1, le=1000),
    offset: int = Query(0, ge=0),
    state: AppState = Depends(get_state),
) -> List[LibraryItem]:
    return state.library.list_items(
        category=category, favourites_only=favourites, collection=collection,
        limit=limit, offset=offset,
    )


@router.post("/library/upload", response_model=LibraryItem)
async def upload_model(
    file: UploadFile = File(...),
    name_ar: str = Form(""),
    name_en: str = Form(""),
    category: str = Form("other"),
    tags: str = Form(""),
    aliases: str = Form(""),
    notes: str = Form(""),
    recommended_material: str = Form(""),
    state: AppState = Depends(get_state),
) -> LibraryItem:
    """Import an STL / 3MF / OBJ and generate its thumbnail automatically."""
    filename = Path(file.filename or "").name
    extension = Path(filename).suffix.lower()
    if extension not in SUPPORTED_EXTENSIONS:
        raise HTTPException(
            status_code=400,
            detail=f"Unsupported model type '{extension or 'unknown'}'. Supported: "
                   + ", ".join(sorted(SUPPORTED_EXTENSIONS)),
        )

    content = await file.read()
    if not content:
        raise HTTPException(status_code=400, detail="Uploaded file is empty")
    if len(content) > MAX_MODEL_BYTES:
        raise HTTPException(status_code=413, detail="Model exceeds the 512 MB upload limit")

    temporary = Path(tempfile.mkdtemp(prefix="neptune-upload-")) / filename
    temporary.write_bytes(content)

    payload = LibraryItemCreate(
        name_ar=name_ar,
        name_en=name_en,
        category=category or "other",
        tags=[tag.strip() for tag in tags.split(",") if tag.strip()],
        aliases=[alias.strip() for alias in aliases.split(",") if alias.strip()],
        notes=notes,
        recommended_material=recommended_material,
    )
    item = state.library.create_item(
        payload=payload, model_file=temporary, original_filename=filename
    )
    return item


@router.get("/library/categories", response_model=List[CategoryInfo])
async def categories(state: AppState = Depends(get_state)) -> List[CategoryInfo]:
    return state.library.categories()


@router.get("/library/stats")
async def library_stats(state: AppState = Depends(get_state)) -> Dict[str, Any]:
    return state.library.stats()


# --------------------------------------------------------------------------- #
# Backup
#
# The library is the only thing on this Pi that cannot be recreated. Klipper's
# config lives in a repository, the G-code can be re-sliced, the videos are
# disposable - the models and everything known about them are years of
# accumulation on a consumer SD card, and those fail.
# --------------------------------------------------------------------------- #


def _manifest_info(manifest: Any) -> BackupManifestInfo:
    return BackupManifestInfo(
        version=manifest.version,
        created_at=manifest.created_at,
        app_version=manifest.app_version,
        model_count=manifest.model_count,
        model_bytes=manifest.model_bytes,
        thumbnail_count=manifest.thumbnail_count,
        database_bytes=manifest.database_bytes,
    )


@router.get("/library/backups", response_model=List[BackupInfo])
async def list_backups(state: AppState = Depends(get_state)) -> List[BackupInfo]:
    from ..library.backup import list_archives

    return [
        BackupInfo(
            filename=str(entry["filename"]),
            size=int(entry["size"]),
            created_at=float(entry["created_at"]),
        )
        for entry in list_archives(state.layout.backups)
    ]


@router.post("/library/backups", response_model=BackupResult)
async def create_backup(
    keep: int = Query(5, ge=1, le=50, description="How many archives to keep"),
    state: AppState = Depends(get_state),
) -> BackupResult:
    """Write an archive of the database, the models and the thumbnails.

    G-code and videos are left out on purpose: they are large and regenerable,
    and including them turns a 40 MB archive into a 4 GB one that nobody
    actually takes a copy of.
    """
    import time as _time

    from ..library.backup import BackupError, create_archive, prune
    from ..version import VERSION

    stamp = _time.strftime("%Y%m%d-%H%M%S")
    folder = Path(state.layout.backups)
    target = folder / f"neptune-library-{stamp}.tar.gz"
    # Two backups inside the same second would otherwise land on the same name
    # and the first would be silently destroyed by the second - which is a
    # backup feature deleting a backup.
    counter = 2
    while target.exists():
        target = folder / f"neptune-library-{stamp}-{counter}.tar.gz"
        counter += 1

    try:
        manifest = create_archive(
            target,
            database=Path(state.layout.database) / "neptune.db",
            models=Path(state.layout.models),
            thumbnails=Path(state.layout.thumbnails),
            app_version=VERSION,
        )
    except (BackupError, OSError) as error:
        raise HTTPException(status_code=500, detail=f"مش قادر أعمل النسخة: {error}") from error

    # A backup nobody prunes fills the card it exists to protect.
    pruned = prune(state.layout.backups, keep=keep)

    return BackupResult(
        ok=True,
        filename=target.name,
        size=target.stat().st_size,
        manifest=_manifest_info(manifest),
        pruned=pruned,
    )


@router.get("/library/backups/{filename}/download")
async def download_backup(filename: str, state: AppState = Depends(get_state)) -> FileResponse:
    path = Path(state.layout.backups) / Path(filename).name
    if not path.is_file():
        raise HTTPException(status_code=404, detail="النسخة دي مش موجودة.")
    return FileResponse(path, filename=path.name, media_type="application/gzip")


@router.post("/library/backups/restore", response_model=RestoreResult)
async def restore_backup(
    request: RestoreRequest, state: AppState = Depends(get_state)
) -> RestoreResult:
    """Unpack an archive over the current library.

    Merges by default. Replacing the database moves the old one aside rather
    than deleting it - the difference between a restore you can walk back from
    and one you cannot.
    """
    from ..library.backup import BackupError, restore_archive

    path = Path(state.layout.backups) / Path(request.filename).name
    if not path.is_file():
        raise HTTPException(status_code=404, detail="النسخة دي مش موجودة.")

    try:
        report = restore_archive(
            path,
            database=Path(state.layout.database) / "neptune.db",
            models=Path(state.layout.models),
            thumbnails=Path(state.layout.thumbnails),
            keep_existing=request.keep_existing,
        )
    except BackupError as error:
        raise HTTPException(status_code=422, detail=str(error)) from error

    return RestoreResult(
        ok=True,
        manifest=_manifest_info(report.manifest),
        models_restored=report.models_restored,
        thumbnails_restored=report.thumbnails_restored,
        database_restored=report.database_restored,
        notes_ar=report.notes_ar,
    )


@router.delete("/library/backups/{filename}", response_model=OKResponse)
async def delete_backup(filename: str, state: AppState = Depends(get_state)) -> OKResponse:
    path = Path(state.layout.backups) / Path(filename).name
    if not path.is_file():
        raise HTTPException(status_code=404, detail="النسخة دي مش موجودة.")
    path.unlink()
    return OKResponse(ok=True, message="النسخة اتمسحت.")


@router.get("/library/{item_id}", response_model=LibraryItem)
async def get_item(item_id: str, state: AppState = Depends(get_state)) -> LibraryItem:
    item = state.library.get_item(item_id)
    if item is None:
        raise HTTPException(status_code=404, detail="Model not found")
    return item


@router.patch("/library/{item_id}", response_model=LibraryItem)
async def update_item(
    item_id: str, update: LibraryItemUpdate, state: AppState = Depends(get_state)
) -> LibraryItem:
    item = state.library.update_item(item_id, update)
    if item is None:
        raise HTTPException(status_code=404, detail="Model not found")
    return item


@router.delete("/library/{item_id}", response_model=OKResponse)
async def delete_item(item_id: str, state: AppState = Depends(get_state)) -> OKResponse:
    if not state.library.delete_item(item_id):
        raise HTTPException(status_code=404, detail="Model not found")
    return OKResponse(ok=True, message="Model deleted")


@router.get("/library/{item_id}/download")
async def download_model(item_id: str, state: AppState = Depends(get_state)) -> FileResponse:
    item = state.library.get_item(item_id)
    if item is None or not item.model_path:
        raise HTTPException(status_code=404, detail="Model file not found")
    try:
        path = state.layout.resolve(item.model_path)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    if not path.is_file():
        raise HTTPException(status_code=404, detail="Model file is missing on disk")
    return FileResponse(path, filename=item.model_filename or path.name)


@router.post("/library/{item_id}/thumbnail", response_model=LibraryItem)
async def replace_thumbnail(
    item_id: str, file: UploadFile = File(...), state: AppState = Depends(get_state)
) -> LibraryItem:
    content = await file.read()
    if not content:
        raise HTTPException(status_code=400, detail="Image is empty")
    if len(content) > MAX_IMAGE_BYTES:
        raise HTTPException(status_code=413, detail="Image is too large")
    extension = Path(file.filename or "photo.jpg").suffix.lower() or ".jpg"
    item = state.library.set_thumbnail(item_id, content, extension=extension)
    if item is None:
        raise HTTPException(status_code=404, detail="Model not found")
    return item


@router.post("/library/{item_id}/regenerate-thumbnail", response_model=LibraryItem)
async def regenerate_thumbnail(item_id: str, state: AppState = Depends(get_state)) -> LibraryItem:
    item = state.library.regenerate_thumbnail(item_id)
    if item is None:
        raise HTTPException(
            status_code=404, detail="Model not found, or it has no model file to render"
        )
    return item


# --------------------------------------------------------------------------- #
# Mesh health
#
# A broken model used to fail at slice time, with a slicer message that assumes
# you know what a manifold is - after the upload, the profile and the wait.
# --------------------------------------------------------------------------- #


def _health(report: Any) -> MeshHealth:
    return MeshHealth(
        triangle_count=report.triangle_count,
        degenerate=report.degenerate,
        open_edges=report.open_edges,
        overlapping_edges=report.overlapping_edges,
        total_edges=report.total_edges,
        shells=report.shells,
        flipped=report.flipped,
        inside_out=report.inside_out,
        watertight=report.is_watertight,
        clean=report.is_clean,
        probably_not_a_solid=report.is_probably_not_a_solid,
        summary_ar=report.summary_ar(),
        # Only the safe repairs count: holes are never filled, so a model whose
        # only problem is a hole is not "repairable" and saying it was would be
        # promising something that does not happen.
        repairable=report.degenerate > 0 or report.flipped > 0 or report.inside_out,
    )


@router.get("/library/{item_id}/health", response_model=MeshHealth)
async def mesh_health(item_id: str, state: AppState = Depends(get_state)) -> MeshHealth:
    """Check a model before slicing it."""
    from ..library.repair import RepairError, inspect_file

    path = state.models.path_for(item_id)
    if path is None or not path.is_file():
        raise HTTPException(status_code=404, detail="Model file not found")

    try:
        return _health(inspect_file(path))
    except RepairError as error:
        raise HTTPException(status_code=422, detail=str(error)) from error


@router.post("/library/{item_id}/repair", response_model=MeshRepairResult)
async def repair_mesh(item_id: str, state: AppState = Depends(get_state)) -> MeshRepairResult:
    """Fix what has one right answer, and leave the original alone.

    The repaired mesh becomes a *new* library item rather than replacing the
    old one. A repair changes geometry, and the person who uploaded the file is
    the only one who can say whether the result is still the part they wanted.
    """
    import tempfile

    from ..library.models import LibraryItemCreate
    from ..library.repair import RepairError, repair_file

    item = state.library.get_item(item_id)
    path = state.models.path_for(item_id)
    if item is None or path is None or not path.is_file():
        raise HTTPException(status_code=404, detail="Model file not found")

    workdir = Path(tempfile.mkdtemp(prefix="neptune-repair-"))
    target = workdir / f"{Path(path.name).stem}_repaired.stl"
    try:
        result = repair_file(path, target)
    except RepairError as error:
        raise HTTPException(status_code=422, detail=str(error)) from error

    if not result.changed:
        return MeshRepairResult(
            ok=True,
            before=_health(result.before),
            after=_health(result.after),
            notes_ar=result.notes_ar,
        )

    repaired = state.library.create_item(
        payload=LibraryItemCreate(
            name_ar=f"{item.display_name} (مُصلَّح)",
            name_en=f"{item.name_en} (repaired)" if item.name_en else "",
            category=item.category,
            tags=list(item.tags),
            notes="اتعمل تلقائيًا من إصلاح الميش. الأصل موجود زي ما هو.",
            recommended_material=item.recommended_material,
        ),
        model_file=target,
        original_filename=target.name,
    )

    return MeshRepairResult(
        ok=True,
        before=_health(result.before),
        after=_health(result.after),
        removed_triangles=result.removed_triangles,
        reoriented=result.reoriented,
        notes_ar=result.notes_ar,
        repaired_model_id=repaired.id,
    )


# --------------------------------------------------------------------------- #
# Placement: how the model is turned before it is sliced
# --------------------------------------------------------------------------- #


async def _build_volume(state: AppState) -> tuple[float, float, float]:
    """This printer's usable volume, read from its own printer.cfg.

    Falls back to the Neptune 3 Plus figures only when the config cannot be
    read at all - a fallback that is a last resort rather than an assumption,
    because telling somebody their model fits when it does not is worse than
    saying the size is unknown.
    """
    default = (320.0, 320.0, 400.0)
    try:
        config = await state.refresh_live_config()
    except Exception:                                       # noqa: BLE001
        return default
    if config is None:
        return default

    sizes: List[float] = []
    for axis, fallback in zip("xyz", default):
        limits = config.axis_limits(axis)
        low = limits.position_min if limits.position_min is not None else 0.0
        high = limits.position_max
        if high is None:
            sizes.append(fallback)
            continue
        # position_min is usually negative: it is homing overtravel, not
        # printable space, so the usable size starts at zero.
        sizes.append(float(high) - max(float(low), 0.0))
    return (sizes[0], sizes[1], sizes[2])


def _report(score: Any, volume: tuple) -> OrientationReport:
    """Turn a measured orientation into the shape the app reads."""
    from ..library.transform import fits_on_bed

    size = (score.footprint[0], score.footprint[1], score.height)
    fits, problems = fits_on_bed(
        size, width=volume[0], depth=volume[1], height=volume[2]
    )
    return OrientationReport(
        base_area=round(score.base_area, 2),
        overhang_area=round(score.overhang_area, 2),
        height=round(score.height, 3),
        width=round(score.footprint[0], 3),
        depth=round(score.footprint[1], 3),
        needs_support=score.needs_support,
        fits=fits,
        problems_ar=problems,
    )


@router.post("/library/arrange", response_model=ArrangeResponse)
async def arrange_plate(
    request: ArrangeRequest, state: AppState = Depends(get_state)
) -> ArrangeResponse:
    """Work out where a set of models goes on this printer's bed.

    Footprints are measured *after* each model's rotation and scale, because a
    rotated part casts a different shadow on the plate than the file did.

    Declared before `/library/{item_id}` - FastAPI matches in declaration order
    and a literal path has to come first or the parameterised one swallows it.
    """
    from ..library import transform as transform_tools
    from ..library.mesh import load
    from ..slicer.arrange import (
        ArrangeError,
        ArrangeResult,
        Placement,
        auto_arrange,
        check,
    )

    volume = await _build_volume(state)
    bed_width, bed_depth = volume[0], volume[1]

    footprints: List[tuple] = []
    for model_id in request.model_ids:
        path = state.models.path_for(model_id)
        if path is None or not path.is_file():
            raise HTTPException(
                status_code=404, detail=f"الموديل «{model_id}» مش موجود."
            )
        spec = request.transforms.get(model_id)
        placement = transform_tools.Transform.from_dict(
            spec.model_dump() if spec else None
        )
        try:
            # Measured without the offset: the arrangement is about to decide
            # where it goes, so where it currently sits is not an input.
            sized = transform_tools.apply(
                load(path),
                transform_tools.Transform(
                    rotation_deg=placement.rotation_deg,
                    scale=placement.scale,
                    mirror=placement.mirror,
                ),
            )
        except Exception as error:                          # noqa: BLE001
            raise HTTPException(
                status_code=422, detail=f"مش قادر أقرا «{model_id}»: {error}"
            ) from error
        size = sized.size
        footprints.append((model_id, float(size[0]), float(size[1])))


    if request.check_only:
        # Judge the plate as it stands. Positions come from the transforms the
        # app already holds, because rearranging here would undo the drag the
        # user just made and answer a question nobody asked.
        placements = []
        for model_id, width, depth in footprints:
            spec = request.transforms.get(model_id)
            offset = list(spec.offset_xy) if spec else [0.0, 0.0]
            placements.append(
                Placement(
                    model_id=model_id, width=width, depth=depth,
                    x=float(offset[0]), y=float(offset[1]),
                )
            )
        result = ArrangeResult(placements=placements)
    else:
        try:
            result = auto_arrange(
                footprints,
                bed_width=bed_width,
                bed_depth=bed_depth,
                spacing=request.spacing,
                margin=request.margin,
            )
        except ArrangeError as error:
            raise HTTPException(status_code=422, detail=str(error)) from error

    # Checked against what will actually be printed, either way, so the answer
    # the app shows is about this plate rather than about a promise.
    problems = list(result.problems_ar)
    problems += check(
        result.placements,
        bed_width=bed_width,
        bed_depth=bed_depth,
        spacing=request.spacing,
        margin=request.margin,
    )

    return ArrangeResponse(
        placements=[
            PlatePlacement(
                model_id=placement.model_id,
                width=round(placement.width, 3),
                depth=round(placement.depth, 3),
                x=round(placement.x, 3),
                y=round(placement.y, 3),
            )
            for placement in result.placements
        ],
        problems_ar=problems,
        unplaced=result.unplaced,
        ok=not problems and not result.unplaced,
        bed_width=bed_width,
        bed_depth=bed_depth,
    )


@router.post("/library/{item_id}/orient", response_model=OrientationSuggestion)
async def suggest_orientation(
    item_id: str,
    transform: Optional[ModelTransform] = Body(default=None),
    state: AppState = Depends(get_state),
) -> OrientationSuggestion:
    """Work out the way up that needs the least support.

    Scored against the real mesh rather than guessed: every candidate is
    actually turned and measured. The answer comes back with the measurements
    for the model as it stands too, so the app can show what the change buys
    instead of asking the user to trust it.

    Nothing is saved here. Applying the suggestion is a separate call, because
    an orientation is a decision and this is only advice.
    """
    from ..library import transform as transform_tools
    from ..library.mesh import load

    path = state.models.path_for(item_id)
    if path is None or not path.is_file():
        raise HTTPException(status_code=404, detail="Model file not found")

    volume = await _build_volume(state)

    try:
        mesh = load(path)
        # Measure where it stands now - including any transform already saved
        # against it, so "current" means what the user is actually looking at.
        starting = transform_tools.Transform.from_dict(
            transform.model_dump() if transform else None
        )
        current_mesh = transform_tools.apply(mesh, starting)
        current = transform_tools.score_orientation(current_mesh)

        placement, score = transform_tools.auto_orient(
            current_mesh, max_height=volume[2]
        )
    except transform_tools.TransformError as error:
        raise HTTPException(status_code=422, detail=str(error)) from error
    except Exception as error:                              # noqa: BLE001
        raise HTTPException(
            status_code=422, detail=f"مش قادر أقرا الموديل: {error}"
        ) from error

    # The suggestion is relative to where the model already is, so it composes
    # with whatever the user had already set rather than discarding it.
    return OrientationSuggestion(
        transform=ModelTransform(
            rotation_deg=list(placement.rotation_deg),
            scale=list(starting.scale),
            mirror=list(starting.mirror),
        ),
        suggested=_report(score, volume),
        current=_report(current, volume),
    )


@router.post("/library/{item_id}/transform", response_model=OrientationReport)
async def measure_transform(
    item_id: str,
    transform: ModelTransform = Body(...),
    state: AppState = Depends(get_state),
) -> OrientationReport:
    """Measure a proposed transform without saving or slicing anything.

    This is what the app calls while the user is dragging a rotation dial: it
    answers "how tall is it now, does it still fit, does it still need
    support" from the real geometry.
    """
    from ..library import transform as transform_tools
    from ..library.mesh import load

    path = state.models.path_for(item_id)
    if path is None or not path.is_file():
        raise HTTPException(status_code=404, detail="Model file not found")

    volume = await _build_volume(state)
    try:
        placed = transform_tools.apply(
            load(path), transform_tools.Transform.from_dict(transform.model_dump())
        )
        score = transform_tools.score_orientation(placed)
    except transform_tools.TransformError as error:
        raise HTTPException(status_code=422, detail=str(error)) from error
    except Exception as error:                              # noqa: BLE001
        raise HTTPException(
            status_code=422, detail=f"مش قادر أقرا الموديل: {error}"
        ) from error

    return _report(score, volume)


# --------------------------------------------------------------------------- #
# Photos and G-code versions
# --------------------------------------------------------------------------- #


@router.post("/library/{item_id}/photos", response_model=LibraryPhoto)
async def add_photo(
    item_id: str,
    file: UploadFile = File(...),
    caption: str = Form(""),
    state: AppState = Depends(get_state),
) -> LibraryPhoto:
    content = await file.read()
    if not content:
        raise HTTPException(status_code=400, detail="Image is empty")
    extension = Path(file.filename or "photo.jpg").suffix.lower() or ".jpg"
    photo = state.library.add_photo(item_id, content, caption=caption, extension=extension)
    if photo is None:
        raise HTTPException(status_code=404, detail="Model not found")
    return photo


@router.delete("/library/photos/{photo_id}", response_model=OKResponse)
async def delete_photo(photo_id: str, state: AppState = Depends(get_state)) -> OKResponse:
    if not state.library.delete_photo(photo_id):
        raise HTTPException(status_code=404, detail="Photo not found")
    return OKResponse(ok=True, message="Photo deleted")


@router.get("/library/{item_id}/gcodes", response_model=List[LibraryGCode])
async def item_gcodes(item_id: str, state: AppState = Depends(get_state)) -> List[LibraryGCode]:
    return state.library.list_gcodes(item_id)


@router.delete("/library/gcodes/{gcode_id}", response_model=OKResponse)
async def delete_item_gcode(gcode_id: str, state: AppState = Depends(get_state)) -> OKResponse:
    if not state.library.delete_gcode(gcode_id):
        raise HTTPException(status_code=404, detail="G-code entry not found")
    return OKResponse(ok=True, message="Deleted")


# --------------------------------------------------------------------------- #
# Search
# --------------------------------------------------------------------------- #


@router.get("/search", response_model=SearchResponse)
async def search(
    q: str = Query("", description="Arabic or English query"),
    limit: int = Query(40, ge=1, le=200),
    category: Optional[str] = None,
    favourites: bool = False,
    state: AppState = Depends(get_state),
) -> SearchResponse:
    hits = state.library.search(q, limit=limit, category=category, favourites_only=favourites)
    results: List[SearchResult] = []
    for hit in hits:
        item = hit.document.payload.get("item")
        if item is None:
            item = state.library.get_item(hit.document.id)
        if item is None:
            continue
        results.append(SearchResult(item=item, score=round(hit.score, 1), reasons=hit.reasons))

    return SearchResponse(
        query=q,
        normalized_query=normalize(q),
        results=results,
        total=len(results),
        suggestions=state.library.suggest(q) if q else [],
    )


@router.get("/search/suggest", response_model=List[str])
async def suggest(
    q: str = Query(..., min_length=1),
    limit: int = Query(8, ge=1, le=20),
    state: AppState = Depends(get_state),
) -> List[str]:
    return state.library.suggest(q, limit=limit)


@router.post("/ideas", response_model=List[LibraryItem])
async def ideas(request: IdeaRequest, state: AppState = Depends(get_state)) -> List[LibraryItem]:
    return state.library.ideas(
        room=request.room,
        max_seconds=request.max_seconds,
        material=request.material,
        limit=request.limit,
    )


# --------------------------------------------------------------------------- #
# Collections
# --------------------------------------------------------------------------- #


@router.get("/collections", response_model=List[Collection])
async def list_collections(state: AppState = Depends(get_state)) -> List[Collection]:
    return state.library.list_collections()


@router.post("/collections", response_model=Collection)
async def create_collection(
    name_ar: str = Body(..., embed=True),
    name_en: str = Body("", embed=True),
    icon: str = Body("folder", embed=True),
    state: AppState = Depends(get_state),
) -> Collection:
    return state.library.create_collection(name_ar, name_en, icon)


@router.delete("/collections/{collection_id}", response_model=OKResponse)
async def delete_collection(collection_id: str, state: AppState = Depends(get_state)) -> OKResponse:
    if not state.library.delete_collection(collection_id):
        raise HTTPException(status_code=400, detail="Built-in collections cannot be deleted")
    return OKResponse(ok=True, message="Collection deleted")


@router.post("/collections/{collection_id}/items/{item_id}", response_model=OKResponse)
async def add_to_collection(
    collection_id: str, item_id: str, state: AppState = Depends(get_state)
) -> OKResponse:
    if not state.library.add_to_collection(collection_id, item_id):
        raise HTTPException(status_code=404, detail="Collection not found")
    return OKResponse(ok=True, message="Added")


@router.delete("/collections/{collection_id}/items/{item_id}", response_model=OKResponse)
async def remove_from_collection(
    collection_id: str, item_id: str, state: AppState = Depends(get_state)
) -> OKResponse:
    if not state.library.remove_from_collection(collection_id, item_id):
        raise HTTPException(status_code=404, detail="Not in this collection")
    return OKResponse(ok=True, message="Removed")


# --------------------------------------------------------------------------- #
# Print quality memory
# --------------------------------------------------------------------------- #


@router.post("/library/ratings", response_model=PrintRating)
async def rate_print(rating: PrintRating, state: AppState = Depends(get_state)) -> PrintRating:
    if rating.rating not in {"excellent", "good", "problem"}:
        raise HTTPException(status_code=400, detail="rating must be excellent, good or problem")

    created = time.time()
    state.db.execute(
        "INSERT INTO print_ratings(history_id, item_id, rating, profile, note, created_at) "
        "VALUES (?,?,?,?,?,?) ON CONFLICT(history_id) DO UPDATE SET "
        "rating = excluded.rating, profile = excluded.profile, note = excluded.note",
        (
            rating.history_id, rating.item_id, rating.rating,
            __import__("json").dumps(rating.profile, ensure_ascii=False), rating.note, created,
        ),
    )

    # An excellent result becomes the item's remembered good profile.
    if rating.rating == "excellent" and rating.item_id and rating.profile:
        state.library.save_successful_profile(rating.item_id, rating.profile)

    rating.created_at = created
    return rating


@router.get("/library/{item_id}/successful-profile")
async def successful_profile(item_id: str, state: AppState = Depends(get_state)) -> Dict[str, Any]:
    item = state.library.get_item(item_id)
    if item is None:
        raise HTTPException(status_code=404, detail="Model not found")
    return {"item_id": item_id, "profile": item.successful_profile}


# --------------------------------------------------------------------------- #
# Media serving (thumbnails, snapshots, videos)
# --------------------------------------------------------------------------- #


@router.get("/media/{relative_path:path}")
async def media(relative_path: str, state: AppState = Depends(get_state)) -> FileResponse:
    """Serve any file inside the storage root. Directory escapes are refused."""
    try:
        path = state.layout.resolve(relative_path)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    if not path.is_file():
        raise HTTPException(status_code=404, detail="File not found")

    media_type, _ = mimetypes.guess_type(path.name)
    return FileResponse(
        path,
        media_type=media_type or "application/octet-stream",
        headers={"Cache-Control": "public, max-age=86400"},
    )
