"""Model library storage: items, G-code versions, photos and collections."""

from __future__ import annotations

import logging
import shutil
import time
import uuid
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional

from ..db import Database, dump_json, load_json
from ..paths import StorageLayout
from ..search.engine import SearchDocument, SearchEngine, SearchHit, find_ideas, suggestions
from . import thumbnails
from .mesh import summarise
from .models import (
    BUILTIN_CATEGORIES,
    BUILTIN_COLLECTIONS,
    CategoryInfo,
    Collection,
    LibraryGCode,
    LibraryItem,
    LibraryItemCreate,
    LibraryItemUpdate,
    LibraryPhoto,
)

log = logging.getLogger("neptune.library")

SAFE_CHARS = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")


def safe_name(name: str, fallback: str = "model") -> str:
    """Keep Arabic letters, drop path separators and control characters."""
    cleaned = "".join(
        char for char in Path(name).name
        if char in SAFE_CHARS or "؀" <= char <= "ۿ" or char == " "
    ).strip()
    cleaned = cleaned.replace("  ", " ")
    return cleaned or fallback


class LibraryStore:
    def __init__(self, database: Database, layout: StorageLayout) -> None:
        self.db = database
        self.layout = layout
        self.engine = SearchEngine()
        self._ensure_builtin_collections()

    # ------------------------------------------------------------ built-ins
    def _ensure_builtin_collections(self) -> None:
        now = time.time()
        for entry in BUILTIN_COLLECTIONS:
            self.db.execute(
                "INSERT OR IGNORE INTO collections(id, name_ar, name_en, builtin, icon, created_at) "
                "VALUES(?, ?, ?, 1, ?, ?)",
                (entry["id"], entry["name_ar"], entry["name_en"], entry["icon"], now),
            )

    # ---------------------------------------------------------------- items
    def create_item(
        self,
        *,
        payload: LibraryItemCreate,
        model_file: Optional[Path] = None,
        original_filename: str = "",
        render_thumbnail: bool = True,
    ) -> LibraryItem:
        item_id = uuid.uuid4().hex[:12]
        now = time.time()

        stored_path: Optional[Path] = None
        model_size = 0
        dimensions = (None, None, None)
        triangle_count: Optional[int] = None

        if model_file is not None:
            filename = safe_name(original_filename or model_file.name)
            stored_path = self.layout.models / f"{item_id}__{filename}"
            shutil.move(str(model_file), str(stored_path))
            model_size = stored_path.stat().st_size

            summary = summarise(stored_path)
            if summary is not None:
                dimensions = (summary.size_x, summary.size_y, summary.size_z)
                triangle_count = summary.triangle_count

        name_ar = payload.name_ar.strip()
        name_en = payload.name_en.strip()
        if not name_ar and not name_en:
            base = Path(original_filename or (stored_path.name if stored_path else "")).stem
            name_en = base.replace("_", " ").replace("-", " ").strip() or "Model"

        item = LibraryItem(
            id=item_id,
            name_ar=name_ar,
            name_en=name_en,
            aliases=[alias.strip() for alias in payload.aliases if alias.strip()],
            tags=[tag.strip() for tag in payload.tags if tag.strip()],
            category=payload.category or "other",
            notes=payload.notes,
            recommended_material=payload.recommended_material,
            source_url=payload.source_url,
            author=payload.author,
            licence=payload.licence,
            favourite=payload.favourite,
            model_path=self.layout.relative(stored_path) if stored_path else None,
            model_filename=stored_path.name.split("__", 1)[-1] if stored_path else "",
            model_size=model_size,
            dimensions_x=dimensions[0],
            dimensions_y=dimensions[1],
            dimensions_z=dimensions[2],
            triangle_count=triangle_count,
            created_at=now,
            updated_at=now,
        )

        if render_thumbnail and stored_path is not None:
            self._render_thumbnails(item, stored_path)

        self._insert(item)
        if item.favourite:
            self.add_to_collection("favourites", item.id)
        return self.get_item(item_id) or item

    def _render_thumbnails(self, item: LibraryItem, model_path: Path) -> None:
        result = thumbnails.render_model(model_path, self.layout.thumbnails, item.id)
        if result.ok and result.thumbnail is not None:
            item.thumbnail = self.layout.relative(result.thumbnail)
            if result.hero is not None:
                item.hero_image = self.layout.relative(result.hero)
            return

        log.info("Falling back to a placeholder card for %s: %s", item.id, result.error)
        placeholder = thumbnails.render_placeholder(
            self.layout.thumbnails, item.id, item.name_en or item.name_ar or item.model_filename
        )
        if placeholder is not None:
            item.thumbnail = self.layout.relative(placeholder)

    def regenerate_thumbnail(self, item_id: str) -> Optional[LibraryItem]:
        item = self.get_item(item_id)
        if item is None or not item.model_path:
            return None
        model_path = self.layout.resolve(item.model_path)
        if not model_path.is_file():
            return None
        self._render_thumbnails(item, model_path)
        self.db.execute(
            "UPDATE library_items SET thumbnail = ?, hero_image = ?, updated_at = ? WHERE id = ?",
            (item.thumbnail, item.hero_image, time.time(), item_id),
        )
        return self.get_item(item_id)

    def set_thumbnail(self, item_id: str, image_bytes: bytes, extension: str = ".jpg") -> Optional[LibraryItem]:
        """Replace the thumbnail with a user-supplied photo."""
        item = self.get_item(item_id)
        if item is None:
            return None
        suffix = extension if extension.startswith(".") else f".{extension}"
        path = self.layout.thumbnails / f"{item_id}_user{suffix}"
        path.write_bytes(image_bytes)
        relative = self.layout.relative(path)
        self.db.execute(
            "UPDATE library_items SET thumbnail = ?, hero_image = ?, updated_at = ? WHERE id = ?",
            (relative, relative, time.time(), item_id),
        )
        return self.get_item(item_id)

    def _insert(self, item: LibraryItem) -> None:
        document = self._document(item)
        self.db.execute(
            """
            INSERT INTO library_items(
                id, name_ar, name_en, aliases, tags, category, notes,
                thumbnail, hero_image, model_path, model_filename, model_size,
                dimensions_x, dimensions_y, dimensions_z, triangle_count,
                recommended_material, estimated_seconds, estimated_filament_g,
                source_url, author, licence,
                favourite, print_count, last_printed, successful_profile,
                is_product, created_at, updated_at, search_blob
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """,
            (
                item.id, item.name_ar, item.name_en, dump_json(item.aliases), dump_json(item.tags),
                item.category, item.notes, item.thumbnail, item.hero_image, item.model_path,
                item.model_filename, item.model_size, item.dimensions_x, item.dimensions_y,
                item.dimensions_z, item.triangle_count, item.recommended_material,
                item.estimated_seconds, item.estimated_filament_g,
                item.source_url, item.author, item.licence, int(item.favourite),
                item.print_count, item.last_printed,
                dump_json(item.successful_profile) if item.successful_profile else None,
                int(item.is_product), item.created_at, item.updated_at, document.blob(),
            ),
        )

    def update_item(self, item_id: str, update: LibraryItemUpdate) -> Optional[LibraryItem]:
        item = self.get_item(item_id)
        if item is None:
            return None

        data = update.model_dump(exclude_none=True)
        for key, value in data.items():
            setattr(item, key, value)
        item.updated_at = time.time()

        self.db.execute(
            """
            UPDATE library_items SET
                name_ar = ?, name_en = ?, aliases = ?, tags = ?, category = ?, notes = ?,
                recommended_material = ?, favourite = ?, is_product = ?,
                estimated_seconds = ?, estimated_filament_g = ?,
                updated_at = ?, search_blob = ?
            WHERE id = ?
            """,
            (
                item.name_ar, item.name_en, dump_json(item.aliases), dump_json(item.tags),
                item.category, item.notes, item.recommended_material, int(item.favourite),
                int(item.is_product), item.estimated_seconds, item.estimated_filament_g,
                item.updated_at, self._document(item).blob(), item_id,
            ),
        )

        if "favourite" in data:
            if item.favourite:
                self.add_to_collection("favourites", item_id)
            else:
                self.remove_from_collection("favourites", item_id)

        return self.get_item(item_id)

    def delete_item(self, item_id: str, *, delete_files: bool = True) -> bool:
        item = self.get_item(item_id)
        if item is None:
            return False

        if delete_files:
            for relative in [item.model_path, item.thumbnail, item.hero_image]:
                if not relative:
                    continue
                try:
                    self.layout.resolve(relative).unlink(missing_ok=True)
                except (ValueError, OSError):
                    continue
            for photo in item.photos:
                try:
                    self.layout.resolve(photo.path).unlink(missing_ok=True)
                except (ValueError, OSError):
                    continue

        self.db.execute("DELETE FROM library_items WHERE id = ?", (item_id,))
        return True

    def get_item(self, item_id: str) -> Optional[LibraryItem]:
        row = self.db.query_one("SELECT * FROM library_items WHERE id = ?", (item_id,))
        if row is None:
            return None
        item = self._row_to_item(row)
        item.gcodes = self.list_gcodes(item_id)
        item.photos = self.list_photos(item_id)
        item.collections = self.collections_for(item_id)
        return item

    def list_items(
        self,
        *,
        category: Optional[str] = None,
        favourites_only: bool = False,
        collection: Optional[str] = None,
        limit: int = 500,
        offset: int = 0,
    ) -> List[LibraryItem]:
        sql = "SELECT i.* FROM library_items i"
        params: List[Any] = []
        clauses: List[str] = []

        if collection:
            sql += " JOIN collection_items c ON c.item_id = i.id"
            clauses.append("c.collection_id = ?")
            params.append(collection)
        if category:
            clauses.append("i.category = ?")
            params.append(category)
        if favourites_only:
            clauses.append("i.favourite = 1")

        if clauses:
            sql += " WHERE " + " AND ".join(clauses)
        sql += " ORDER BY i.updated_at DESC LIMIT ? OFFSET ?"
        params.extend([limit, offset])

        return [self._row_to_item(row) for row in self.db.query(sql, params)]

    def _row_to_item(self, row: Any) -> LibraryItem:
        data = dict(row)
        return LibraryItem(
            id=data["id"],
            name_ar=data["name_ar"] or "",
            name_en=data["name_en"] or "",
            aliases=load_json(data["aliases"], []),
            tags=load_json(data["tags"], []),
            category=data["category"] or "other",
            notes=data["notes"] or "",
            thumbnail=data["thumbnail"],
            hero_image=data["hero_image"],
            model_path=data["model_path"],
            model_filename=data["model_filename"] or "",
            model_size=int(data["model_size"] or 0),
            dimensions_x=data["dimensions_x"],
            dimensions_y=data["dimensions_y"],
            dimensions_z=data["dimensions_z"],
            triangle_count=data["triangle_count"],
            recommended_material=data["recommended_material"] or "",
            estimated_seconds=data["estimated_seconds"],
            estimated_filament_g=data["estimated_filament_g"],
            # `.get`, not `[...]`: a database restored from an archive made
            # before these columns existed is opened without another migration
            # pass, and a missing source is not worth a crash.
            source_url=data.get("source_url") or "",
            author=data.get("author") or "",
            licence=data.get("licence") or "",
            favourite=bool(data["favourite"]),
            print_count=int(data["print_count"] or 0),
            last_printed=data["last_printed"],
            successful_profile=load_json(data["successful_profile"], None),
            is_product=bool(data["is_product"]),
            created_at=float(data["created_at"] or 0),
            updated_at=float(data["updated_at"] or 0),
        )

    # ------------------------------------------------------------- G-code
    def add_gcode(
        self,
        item_id: str,
        *,
        filename: str,
        path: str = "",
        moonraker_path: Optional[str] = None,
        material: str = "",
        quality: str = "",
        layer_height: Optional[float] = None,
        estimated_seconds: Optional[float] = None,
        filament_g: Optional[float] = None,
        layer_count: Optional[int] = None,
        profile: Optional[Dict[str, Any]] = None,
    ) -> Optional[LibraryGCode]:
        if self.db.query_one("SELECT id FROM library_items WHERE id = ?", (item_id,)) is None:
            return None
        gcode_id = uuid.uuid4().hex[:12]
        now = time.time()
        self.db.execute(
            """
            INSERT INTO library_gcodes(
                id, item_id, filename, path, moonraker_path, material, quality,
                layer_height, estimated_seconds, filament_g, layer_count, profile, created_at
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
            """,
            (
                gcode_id, item_id, filename, path, moonraker_path, material, quality,
                layer_height, estimated_seconds, filament_g, layer_count,
                dump_json(profile or {}), now,
            ),
        )
        # Keep the item's headline estimates in sync with its newest slice.
        self.db.execute(
            "UPDATE library_items SET estimated_seconds = COALESCE(?, estimated_seconds), "
            "estimated_filament_g = COALESCE(?, estimated_filament_g), updated_at = ? WHERE id = ?",
            (estimated_seconds, filament_g, now, item_id),
        )
        return self.get_gcode(gcode_id)

    def get_gcode(self, gcode_id: str) -> Optional[LibraryGCode]:
        row = self.db.query_one("SELECT * FROM library_gcodes WHERE id = ?", (gcode_id,))
        if row is None:
            return None
        data = dict(row)
        data["profile"] = load_json(data["profile"], {})
        return LibraryGCode(**data)

    def list_gcodes(self, item_id: str) -> List[LibraryGCode]:
        rows = self.db.query(
            "SELECT * FROM library_gcodes WHERE item_id = ? ORDER BY created_at DESC", (item_id,)
        )
        result = []
        for row in rows:
            data = dict(row)
            data["profile"] = load_json(data["profile"], {})
            result.append(LibraryGCode(**data))
        return result

    def delete_gcode(self, gcode_id: str) -> bool:
        cursor = self.db.execute("DELETE FROM library_gcodes WHERE id = ?", (gcode_id,))
        return cursor.rowcount > 0

    def find_item_for_gcode(self, gcode_filename: str) -> Optional[LibraryItem]:
        """Map a printing G-code file back to its library item.

        This is what makes the printing screen able to show the model image
        instead of a filename.
        """
        if not gcode_filename:
            return None
        name = Path(gcode_filename).name

        row = self.db.query_one(
            "SELECT item_id FROM library_gcodes WHERE filename = ? OR moonraker_path = ? "
            "ORDER BY created_at DESC LIMIT 1",
            (name, gcode_filename),
        )
        if row is not None:
            return self.get_item(row["item_id"])

        # Fall back to a stem match against the model filename.
        stem = Path(name).stem.lower()
        for item in self.list_items(limit=500):
            if item.model_filename and Path(item.model_filename).stem.lower() == stem:
                return self.get_item(item.id)
        return None

    # -------------------------------------------------------------- photos
    def add_photo(self, item_id: str, image_bytes: bytes, *, caption: str = "", extension: str = ".jpg") -> Optional[LibraryPhoto]:
        if self.db.query_one("SELECT id FROM library_items WHERE id = ?", (item_id,)) is None:
            return None
        photo_id = uuid.uuid4().hex[:12]
        suffix = extension if extension.startswith(".") else f".{extension}"
        path = self.layout.snapshots / f"item_{item_id}_{photo_id}{suffix}"
        path.write_bytes(image_bytes)
        now = time.time()
        self.db.execute(
            "INSERT INTO library_photos(id, item_id, path, caption, created_at) VALUES (?,?,?,?,?)",
            (photo_id, item_id, self.layout.relative(path), caption, now),
        )
        return LibraryPhoto(
            id=photo_id, item_id=item_id, path=self.layout.relative(path),
            caption=caption, created_at=now,
        )

    def list_photos(self, item_id: str) -> List[LibraryPhoto]:
        rows = self.db.query(
            "SELECT * FROM library_photos WHERE item_id = ? ORDER BY created_at DESC", (item_id,)
        )
        return [LibraryPhoto(**dict(row)) for row in rows]

    def delete_photo(self, photo_id: str) -> bool:
        row = self.db.query_one("SELECT path FROM library_photos WHERE id = ?", (photo_id,))
        if row is None:
            return False
        try:
            self.layout.resolve(row["path"]).unlink(missing_ok=True)
        except (ValueError, OSError):
            pass
        self.db.execute("DELETE FROM library_photos WHERE id = ?", (photo_id,))
        return True

    # ---------------------------------------------------------- collections
    def list_collections(self) -> List[Collection]:
        rows = self.db.query(
            "SELECT c.*, (SELECT COUNT(*) FROM collection_items ci WHERE ci.collection_id = c.id) "
            "AS item_count FROM collections c ORDER BY c.builtin DESC, c.name_ar"
        )
        return [
            Collection(
                id=row["id"], name_ar=row["name_ar"], name_en=row["name_en"] or "",
                builtin=bool(row["builtin"]), icon=row["icon"] or "folder",
                item_count=int(row["item_count"] or 0), created_at=float(row["created_at"] or 0),
            )
            for row in rows
        ]

    def create_collection(self, name_ar: str, name_en: str = "", icon: str = "folder") -> Collection:
        collection_id = uuid.uuid4().hex[:10]
        now = time.time()
        self.db.execute(
            "INSERT INTO collections(id, name_ar, name_en, builtin, icon, created_at) VALUES (?,?,?,0,?,?)",
            (collection_id, name_ar, name_en, icon, now),
        )
        return Collection(id=collection_id, name_ar=name_ar, name_en=name_en, icon=icon, created_at=now)

    def collection(self, collection_id: str) -> Optional[Collection]:
        for entry in self.list_collections():
            if entry.id == collection_id:
                return entry
        return None

    def rename_collection(
        self, collection_id: str, *, name_ar: str = "", name_en: str = "", icon: str = ""
    ) -> Optional[Collection]:
        """Rename a project, or change its icon.

        A project imported from an archive is named after the archive, which is
        whatever the person who packed it typed. Renaming is the difference
        between a library of projects and a library of filenames.
        """
        existing = self.collection(collection_id)
        if existing is None or existing.builtin:
            return None
        self.db.execute(
            "UPDATE collections SET name_ar = ?, name_en = ?, icon = ? WHERE id = ?",
            (
                name_ar.strip() or existing.name_ar,
                name_en.strip() or existing.name_en,
                icon.strip() or existing.icon,
                collection_id,
            ),
        )
        return self.collection(collection_id)

    def delete_collection(self, collection_id: str) -> bool:
        row = self.db.query_one("SELECT builtin FROM collections WHERE id = ?", (collection_id,))
        if row is None or bool(row["builtin"]):
            return False
        self.db.execute("DELETE FROM collections WHERE id = ?", (collection_id,))
        return True

    def add_to_collection(self, collection_id: str, item_id: str) -> bool:
        if self.db.query_one("SELECT id FROM collections WHERE id = ?", (collection_id,)) is None:
            return False
        self.db.execute(
            "INSERT OR IGNORE INTO collection_items(collection_id, item_id, added_at) VALUES (?,?,?)",
            (collection_id, item_id, time.time()),
        )
        return True

    def remove_from_collection(self, collection_id: str, item_id: str) -> bool:
        cursor = self.db.execute(
            "DELETE FROM collection_items WHERE collection_id = ? AND item_id = ?",
            (collection_id, item_id),
        )
        return cursor.rowcount > 0

    def collections_for(self, item_id: str) -> List[str]:
        rows = self.db.query(
            "SELECT collection_id FROM collection_items WHERE item_id = ?", (item_id,)
        )
        return [row["collection_id"] for row in rows]

    # ---------------------------------------------------------- categories
    def categories(self) -> List[CategoryInfo]:
        counts = {
            row["category"]: int(row["total"])
            for row in self.db.query(
                "SELECT category, COUNT(*) AS total FROM library_items GROUP BY category"
            )
        }
        result = [
            CategoryInfo(
                id=entry["id"], name_ar=entry["name_ar"], name_en=entry["name_en"],
                icon=entry["icon"], item_count=counts.pop(entry["id"], 0),
            )
            for entry in BUILTIN_CATEGORIES
        ]
        # Any custom categories the user invented.
        for name, count in sorted(counts.items()):
            result.append(
                CategoryInfo(id=name, name_ar=name, name_en=name, icon="square.grid.2x2", item_count=count)
            )
        return result

    # -------------------------------------------------------------- search
    def documents(self, items: Optional[Iterable[LibraryItem]] = None) -> List[SearchDocument]:
        source = items if items is not None else self.list_items(limit=2000)
        return [self._document(item) for item in source]

    def _document(self, item: LibraryItem) -> SearchDocument:
        return SearchDocument(
            id=item.id,
            name_ar=item.name_ar,
            name_en=item.name_en,
            aliases=item.aliases,
            tags=item.tags,
            category=item.category,
            notes=item.notes,
            favourite=item.favourite,
            print_count=item.print_count,
            last_printed=item.last_printed,
            material=item.recommended_material,
            estimated_seconds=item.estimated_seconds,
        )

    def search(
        self,
        query: str,
        *,
        limit: int = 50,
        category: Optional[str] = None,
        favourites_only: bool = False,
    ) -> List[SearchHit]:
        items = {item.id: item for item in self.list_items(limit=2000)}
        hits = self.engine.search(
            query,
            self.documents(items.values()),
            limit=limit,
            category=category,
            favourites_only=favourites_only,
        )
        for hit in hits:
            hit.document.payload = {"item": items.get(hit.document.id)}
        return hits

    def suggest(self, prefix: str, limit: int = 8) -> List[str]:
        return suggestions(prefix, self.documents(), limit=limit)

    def ideas(
        self,
        *,
        room: Optional[str] = None,
        max_seconds: Optional[float] = None,
        material: Optional[str] = None,
        limit: int = 12,
    ) -> List[LibraryItem]:
        items = {item.id: item for item in self.list_items(limit=2000)}
        hits = find_ideas(
            self.documents(items.values()),
            room=room,
            max_seconds=max_seconds,
            material=material,
            now=time.time(),
            limit=limit,
        )
        return [items[hit.document.id] for hit in hits if hit.document.id in items]

    # ------------------------------------------------------- print tracking
    def record_print(self, item_id: str, *, when: Optional[float] = None) -> None:
        self.db.execute(
            "UPDATE library_items SET print_count = print_count + 1, last_printed = ?, updated_at = ? "
            "WHERE id = ?",
            (when or time.time(), time.time(), item_id),
        )

    def save_successful_profile(self, item_id: str, profile: Dict[str, Any]) -> None:
        self.db.execute(
            "UPDATE library_items SET successful_profile = ?, updated_at = ? WHERE id = ?",
            (dump_json(profile), time.time(), item_id),
        )

    def stats(self) -> Dict[str, Any]:
        row = self.db.query_one(
            "SELECT COUNT(*) AS total, "
            "SUM(CASE WHEN favourite = 1 THEN 1 ELSE 0 END) AS favourites, "
            "SUM(CASE WHEN is_product = 1 THEN 1 ELSE 0 END) AS products, "
            "SUM(print_count) AS prints FROM library_items"
        )
        return {
            "total": int(row["total"] or 0),
            "favourites": int(row["favourites"] or 0),
            "products": int(row["products"] or 0),
            "prints": int(row["prints"] or 0),
        }
