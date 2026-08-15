"""Model library: import, thumbnails, collections, G-code linking."""

from __future__ import annotations

import struct
from pathlib import Path

import pytest

from app.db import Database
from app.library import thumbnails
from app.library.mesh import MeshError, load, summarise
from app.library.models import LibraryItemCreate, LibraryItemUpdate
from app.library.store import LibraryStore, safe_name
from app.paths import StorageLayout


# --------------------------------------------------------------------------- #
# Fixtures
# --------------------------------------------------------------------------- #


def binary_stl(triangles: list[tuple[tuple[float, float, float], ...]]) -> bytes:
    data = bytearray(b"\0" * 80)
    data += struct.pack("<I", len(triangles))
    for triangle in triangles:
        data += struct.pack("<3f", 0.0, 0.0, 1.0)
        for vertex in triangle:
            data += struct.pack("<3f", *vertex)
        data += struct.pack("<H", 0)
    return bytes(data)


CUBE_TRIANGLES = [
    ((0, 0, 0), (20, 0, 0), (20, 30, 0)),
    ((0, 0, 0), (20, 30, 0), (0, 30, 0)),
    ((0, 0, 10), (20, 0, 10), (20, 30, 10)),
    ((0, 0, 10), (20, 30, 10), (0, 30, 10)),
]

ASCII_STL = """solid test
facet normal 0 0 1
  outer loop
    vertex 0 0 0
    vertex 10 0 0
    vertex 0 20 5
  endloop
endfacet
endsolid test
"""

OBJ_TEXT = """# quad
v 0 0 0
v 10 0 0
v 10 20 0
v 0 20 0
f 1 2 3 4
"""


@pytest.fixture()
def layout(tmp_path: Path) -> StorageLayout:
    return StorageLayout.create(tmp_path / "neptune_remote")


@pytest.fixture()
def database(layout: StorageLayout) -> Database:
    db = Database(layout.database / "test.db")
    yield db
    db.close()


@pytest.fixture()
def store(database: Database, layout: StorageLayout) -> LibraryStore:
    return LibraryStore(database, layout)


@pytest.fixture()
def stl_file(tmp_path: Path) -> Path:
    path = tmp_path / "incoming" / "cube.stl"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(binary_stl(CUBE_TRIANGLES))
    return path


# --------------------------------------------------------------------------- #
# Storage layout
# --------------------------------------------------------------------------- #


def test_layout_creates_every_directory(layout: StorageLayout):
    for name in ("models", "thumbnails", "videos", "timelapses", "snapshots",
                 "ai_events", "database", "backups", "cache"):
        assert (layout.root / name).is_dir()


def test_layout_refuses_directory_escape(layout: StorageLayout):
    with pytest.raises(ValueError):
        layout.resolve("../../etc/passwd")


def test_layout_relative_round_trip(layout: StorageLayout):
    path = layout.models / "a.stl"
    path.write_bytes(b"x")
    assert layout.resolve(layout.relative(path)) == path.resolve()


def test_dated_video_dir(layout: StorageLayout):
    directory = layout.dated_video_dir()
    assert directory.is_dir()
    assert directory.parent.parent.parent == layout.videos


def test_usage_reports_disk(layout: StorageLayout):
    (layout.models / "x.bin").write_bytes(b"0" * 2048)
    usage = layout.usage()
    assert usage["models"] >= 2048
    assert usage["disk_total"] > 0


# --------------------------------------------------------------------------- #
# Mesh parsing
# --------------------------------------------------------------------------- #


def test_binary_stl_dimensions(stl_file: Path):
    mesh = load(stl_file)
    assert mesh.triangle_count == 4
    assert mesh.size == pytest.approx((20.0, 30.0, 10.0))
    assert mesh.center == pytest.approx((10.0, 15.0, 5.0))


def test_ascii_stl(tmp_path: Path):
    path = tmp_path / "ascii.stl"
    path.write_text(ASCII_STL, encoding="utf-8")
    mesh = load(path)
    assert mesh.triangle_count == 1
    assert mesh.size == pytest.approx((10.0, 20.0, 5.0))


def test_obj_quad_is_triangulated(tmp_path: Path):
    path = tmp_path / "quad.obj"
    path.write_text(OBJ_TEXT, encoding="utf-8")
    mesh = load(path)
    assert mesh.triangle_count == 2
    assert mesh.size == pytest.approx((10.0, 20.0, 0.0))


def test_3mf_round_trip(tmp_path: Path):
    import zipfile

    path = tmp_path / "part.3mf"
    model = """<?xml version="1.0"?>
    <model><resources><object id="1"><mesh>
    <vertices>
      <vertex x="0" y="0" z="0"/><vertex x="15" y="0" z="0"/><vertex x="0" y="25" z="8"/>
    </vertices>
    <triangles><triangle v1="0" v2="1" v3="2"/></triangles>
    </mesh></object></resources></model>"""
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("3D/3dmodel.model", model)

    mesh = load(path)
    assert mesh.triangle_count == 1
    assert mesh.size == pytest.approx((15.0, 25.0, 8.0))


def test_unsupported_format_raises(tmp_path: Path):
    path = tmp_path / "notes.txt"
    path.write_text("hello")
    with pytest.raises(MeshError):
        load(path)


def test_corrupt_file_is_reported_not_crashed(tmp_path: Path):
    path = tmp_path / "broken.3mf"
    path.write_bytes(b"definitely not a zip")
    with pytest.raises(MeshError):
        load(path)


def test_summarise_returns_none_for_bad_file(tmp_path: Path):
    path = tmp_path / "broken.stl"
    path.write_bytes(b"tiny")
    assert summarise(path) is None


# --------------------------------------------------------------------------- #
# Thumbnails
# --------------------------------------------------------------------------- #


def test_renderer_is_available_with_numpy_and_pillow():
    assert thumbnails.renderer_available()


def test_render_model_produces_two_pngs(stl_file: Path, tmp_path: Path):
    result = thumbnails.render_model(stl_file, tmp_path / "thumbs", "abc123")
    assert result.ok, result.error
    assert result.thumbnail is not None and result.thumbnail.is_file()
    assert result.hero is not None and result.hero.is_file()

    from PIL import Image

    with Image.open(result.thumbnail) as image:
        assert image.size == thumbnails.THUMBNAIL_SIZE
        # The render must not be a blank canvas.
        assert len(image.convert("RGB").getcolors(maxcolors=100000) or []) > 2


def test_render_model_reports_failure_without_faking(tmp_path: Path):
    broken = tmp_path / "broken.stl"
    broken.write_bytes(b"not an stl")
    result = thumbnails.render_model(broken, tmp_path / "thumbs", "bad")
    assert not result.ok
    assert result.thumbnail is None
    assert result.error


def test_placeholder_card_is_generated(tmp_path: Path):
    path = thumbnails.render_placeholder(tmp_path / "thumbs", "xyz", "Test model")
    assert path is not None and path.is_file()


def test_gcode_thumbnail_extraction(tmp_path: Path):
    import base64

    from PIL import Image

    source = tmp_path / "src.png"
    Image.new("RGB", (32, 32), (10, 120, 220)).save(source)
    encoded = base64.b64encode(source.read_bytes()).decode()
    chunks = [encoded[index:index + 60] for index in range(0, len(encoded), 60)]

    gcode = tmp_path / "part.gcode"
    lines = ["; generated by PrusaSlicer", f"; thumbnail begin 32x32 {len(encoded)}"]
    lines += [f"; {chunk}" for chunk in chunks]
    lines += ["; thumbnail end", "G28"]
    gcode.write_text("\n".join(lines), encoding="utf-8")

    extracted = thumbnails.extract_gcode_thumbnail(gcode, tmp_path / "out", "job1")
    assert extracted is not None and extracted.is_file()


def test_gcode_without_thumbnail_returns_none(tmp_path: Path):
    gcode = tmp_path / "plain.gcode"
    gcode.write_text("G28\nG1 X10\n", encoding="utf-8")
    assert thumbnails.extract_gcode_thumbnail(gcode, tmp_path / "out", "job2") is None


# --------------------------------------------------------------------------- #
# Library store
# --------------------------------------------------------------------------- #


def test_safe_name_keeps_arabic_drops_paths():
    assert safe_name("../../etc/passwd") == "passwd"
    assert safe_name("حامل موبايل.stl") == "حامل موبايل.stl"
    assert safe_name("") == "model"


def test_create_item_stores_model_and_thumbnail(store: LibraryStore, stl_file: Path):
    item = store.create_item(
        payload=LibraryItemCreate(
            name_ar="حامل موبايل", name_en="Phone stand", category="stands",
            tags=["مكتب"], recommended_material="PLA",
        ),
        model_file=stl_file,
        original_filename="cube.stl",
    )

    assert item.name_ar == "حامل موبايل"
    assert item.model_path
    assert store.layout.resolve(item.model_path).is_file()
    assert item.thumbnail, "a thumbnail (render or placeholder) must always exist"
    assert store.layout.resolve(item.thumbnail).is_file()
    assert item.dimensions_x == pytest.approx(20.0)
    assert item.dimensions_z == pytest.approx(10.0)
    assert item.triangle_count == 4


def test_create_item_without_name_uses_the_filename(store: LibraryStore, stl_file: Path):
    item = store.create_item(
        payload=LibraryItemCreate(), model_file=stl_file, original_filename="phone_stand_v2.stl"
    )
    assert item.name_en == "phone stand v2"


def test_update_item(store: LibraryStore, stl_file: Path):
    item = store.create_item(payload=LibraryItemCreate(name_ar="اختبار"), model_file=stl_file)
    updated = store.update_item(item.id, LibraryItemUpdate(name_ar="اسم جديد", favourite=True))
    assert updated is not None
    assert updated.name_ar == "اسم جديد"
    assert updated.favourite is True
    assert "favourites" in updated.collections


def test_unfavourite_removes_from_collection(store: LibraryStore, stl_file: Path):
    item = store.create_item(
        payload=LibraryItemCreate(name_ar="اختبار", favourite=True), model_file=stl_file
    )
    assert "favourites" in store.get_item(item.id).collections
    store.update_item(item.id, LibraryItemUpdate(favourite=False))
    assert "favourites" not in store.get_item(item.id).collections


def test_delete_item_removes_files(store: LibraryStore, stl_file: Path):
    item = store.create_item(payload=LibraryItemCreate(name_ar="حذف"), model_file=stl_file)
    model_path = store.layout.resolve(item.model_path)
    assert store.delete_item(item.id) is True
    assert store.get_item(item.id) is None
    assert not model_path.exists()


def test_replace_thumbnail_with_a_photo(store: LibraryStore, stl_file: Path):
    item = store.create_item(payload=LibraryItemCreate(name_ar="صورة"), model_file=stl_file)
    updated = store.set_thumbnail(item.id, b"\xff\xd8\xff\xd9", extension=".jpg")
    assert updated is not None
    assert updated.thumbnail.endswith("_user.jpg")


def test_gcode_links_back_to_the_item(store: LibraryStore, stl_file: Path):
    item = store.create_item(payload=LibraryItemCreate(name_ar="حامل"), model_file=stl_file)
    gcode = store.add_gcode(
        item.id, filename="holder.gcode", material="pla", quality="standard",
        estimated_seconds=3600, filament_g=22.5, layer_count=120,
    )
    assert gcode is not None

    found = store.find_item_for_gcode("holder.gcode")
    assert found is not None and found.id == item.id

    refreshed = store.get_item(item.id)
    assert refreshed.estimated_seconds == 3600
    assert refreshed.estimated_filament_g == pytest.approx(22.5)
    assert len(refreshed.gcodes) == 1


def test_find_item_for_gcode_falls_back_to_the_model_name(store: LibraryStore, stl_file: Path):
    item = store.create_item(
        payload=LibraryItemCreate(name_ar="مكعب"), model_file=stl_file, original_filename="cube.stl"
    )
    found = store.find_item_for_gcode("cube.gcode")
    assert found is not None and found.id == item.id


def test_find_item_for_unknown_gcode_returns_none(store: LibraryStore):
    assert store.find_item_for_gcode("nothing.gcode") is None
    assert store.find_item_for_gcode("") is None


def test_photos(store: LibraryStore, stl_file: Path):
    item = store.create_item(payload=LibraryItemCreate(name_ar="صور"), model_file=stl_file)
    photo = store.add_photo(item.id, b"jpegbytes", caption="بعد الطباعة")
    assert photo is not None
    assert store.list_photos(item.id)[0].caption == "بعد الطباعة"
    assert store.delete_photo(photo.id) is True
    assert store.list_photos(item.id) == []


def test_builtin_collections_exist(store: LibraryStore):
    ids = {collection.id for collection in store.list_collections()}
    assert {"favourites", "print_later", "products", "gifts", "quick_prints"} <= ids


def test_custom_collections(store: LibraryStore, stl_file: Path):
    item = store.create_item(payload=LibraryItemCreate(name_ar="عنصر"), model_file=stl_file)
    collection = store.create_collection("مجموعتي")
    assert store.add_to_collection(collection.id, item.id) is True
    assert collection.id in store.get_item(item.id).collections
    assert store.remove_from_collection(collection.id, item.id) is True
    assert store.delete_collection(collection.id) is True


def test_builtin_collection_cannot_be_deleted(store: LibraryStore):
    assert store.delete_collection("favourites") is False


def test_a_project_can_be_renamed(store: LibraryStore):
    # An imported archive is named after whatever the person who packed it
    # typed, so renaming is what turns it into a project.
    collection = store.create_collection("kit")

    renamed = store.rename_collection(collection.id, name_ar="طقم الرف")

    assert renamed is not None
    assert renamed.name_ar == "طقم الرف"
    assert store.collection(collection.id).name_ar == "طقم الرف"


def test_renaming_keeps_what_was_not_given(store: LibraryStore):
    collection = store.create_collection("kit", "Kit", icon="shippingbox")

    renamed = store.rename_collection(collection.id, name_ar="طقم")

    assert renamed.name_en == "Kit"
    assert renamed.icon == "shippingbox"


def test_renaming_does_not_lose_the_parts(store: LibraryStore, stl_file: Path):
    item = store.create_item(payload=LibraryItemCreate(name_ar="قطعة"), model_file=stl_file)
    collection = store.create_collection("kit")
    store.add_to_collection(collection.id, item.id)

    store.rename_collection(collection.id, name_ar="طقم")

    assert collection.id in store.get_item(item.id).collections


def test_a_builtin_collection_cannot_be_renamed(store: LibraryStore):
    assert store.rename_collection("favourites", name_ar="المفضلة بتاعتي") is None


def test_renaming_something_that_is_not_there_says_so(store: LibraryStore):
    assert store.rename_collection("nope", name_ar="x") is None


def test_categories_include_counts(store: LibraryStore, stl_file: Path):
    store.create_item(payload=LibraryItemCreate(name_ar="أ", category="stands"), model_file=stl_file)
    categories = {entry.id: entry for entry in store.categories()}
    assert categories["stands"].item_count == 1
    assert categories["stands"].name_ar == "حوامل"


def test_record_print_updates_counters(store: LibraryStore, stl_file: Path):
    item = store.create_item(payload=LibraryItemCreate(name_ar="عداد"), model_file=stl_file)
    store.record_print(item.id)
    store.record_print(item.id)
    refreshed = store.get_item(item.id)
    assert refreshed.print_count == 2
    assert refreshed.last_printed is not None


def test_successful_profile_memory(store: LibraryStore, stl_file: Path):
    item = store.create_item(payload=LibraryItemCreate(name_ar="بروفايل"), model_file=stl_file)
    store.save_successful_profile(item.id, {"layer_height": 0.2, "infill": 20})
    assert store.get_item(item.id).successful_profile["layer_height"] == 0.2


def test_search_through_the_store(store: LibraryStore, stl_file: Path):
    store.create_item(
        payload=LibraryItemCreate(name_ar="حامل موبايل للمكتب", category="stands"),
        model_file=stl_file,
    )
    hits = store.search("ستاند تليفون")
    assert hits
    assert hits[0].document.name_ar == "حامل موبايل للمكتب"


def test_ideas_through_the_store(store: LibraryStore, stl_file: Path):
    store.create_item(
        payload=LibraryItemCreate(name_ar="منظم مكتب", category="office", tags=["مكتب"]),
        model_file=stl_file,
    )
    assert store.ideas(room="desk")


def test_stats(store: LibraryStore, stl_file: Path):
    store.create_item(payload=LibraryItemCreate(name_ar="١", favourite=True), model_file=stl_file)
    stats = store.stats()
    assert stats["total"] == 1
    assert stats["favourites"] == 1


# --------------------------------------------------------------------------- #
# Library models are sliceable by their own id
# --------------------------------------------------------------------------- #


def test_model_store_resolves_library_items(
    store: LibraryStore, layout: StorageLayout, stl_file: Path, tmp_path: Path
):
    """One-tap print slices a library item directly - no second upload."""
    from app.storage import ModelStore

    item = store.create_item(payload=LibraryItemCreate(name_ar="حامل"), model_file=stl_file)
    models = ModelStore(tmp_path / "uploads", extra_directories=[layout.models])

    resolved = models.get(item.id)
    assert resolved is not None
    assert resolved.id == item.id
    assert models.path_for(item.id).is_file()


def test_model_store_does_not_list_library_items(
    store: LibraryStore, layout: StorageLayout, stl_file: Path, tmp_path: Path
):
    from app.storage import ModelStore

    store.create_item(payload=LibraryItemCreate(name_ar="حامل"), model_file=stl_file)
    models = ModelStore(tmp_path / "uploads", extra_directories=[layout.models])
    assert models.list() == []


def test_model_store_refuses_to_delete_library_items(
    store: LibraryStore, layout: StorageLayout, stl_file: Path, tmp_path: Path
):
    """Library files are owned by the library; the upload store must not eat them."""
    from app.storage import ModelStore

    item = store.create_item(payload=LibraryItemCreate(name_ar="حامل"), model_file=stl_file)
    models = ModelStore(tmp_path / "uploads", extra_directories=[layout.models])

    assert models.delete(item.id) is False
    assert models.path_for(item.id).is_file()
