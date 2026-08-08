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
from ..schemas import OKResponse
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
