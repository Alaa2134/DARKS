"""Getting the library off the SD card, and back again."""

from __future__ import annotations

import json
import sqlite3
import tarfile
import time
from pathlib import Path

import pytest

from app.library.backup import (
    ARCHIVE_VERSION,
    DATABASE_NAME,
    MANIFEST_NAME,
    BackupError,
    create_archive,
    list_archives,
    prune,
    read_manifest,
    restore_archive,
)


@pytest.fixture()
def library(tmp_path: Path):
    """A small library: a database with a row, two models, one thumbnail."""
    database = tmp_path / "db" / "neptune.db"
    database.parent.mkdir(parents=True)
    with sqlite3.connect(database) as connection:
        connection.execute("CREATE TABLE items (id TEXT, name TEXT)")
        connection.execute("INSERT INTO items VALUES ('a1', 'حامل موبايل')")

    models = tmp_path / "models"
    models.mkdir()
    (models / "a1.stl").write_bytes(b"solid one\nendsolid\n")
    (models / "b2.stl").write_bytes(b"solid two\nendsolid\n")

    thumbnails = tmp_path / "thumbnails"
    thumbnails.mkdir()
    (thumbnails / "a1.jpg").write_bytes(b"\xff\xd8\xff\xd9")

    return {
        "database": database,
        "models": models,
        "thumbnails": thumbnails,
        "root": tmp_path,
    }


def archive_of(library, tmp_path: Path, name: str = "backup.tar.gz") -> Path:
    target = tmp_path / name
    create_archive(
        target,
        database=library["database"],
        models=library["models"],
        thumbnails=library["thumbnails"],
        app_version="test",
    )
    return target


# --------------------------------------------------------------------------- #
# Writing
# --------------------------------------------------------------------------- #


def test_an_archive_holds_the_database_models_and_thumbnails(library, tmp_path: Path):
    target = archive_of(library, tmp_path)

    with tarfile.open(target, "r:gz") as archive:
        names = set(archive.getnames())

    assert MANIFEST_NAME in names
    assert DATABASE_NAME in names
    assert "models/a1.stl" in names
    assert "thumbnails/a1.jpg" in names


def test_gcode_and_videos_are_not_included(library, tmp_path: Path):
    # They are large and regenerable. Including them turns a 40 MB archive into
    # a 4 GB one that nobody actually takes a copy of, which makes the backup
    # worse rather than better.
    (library["root"] / "gcode").mkdir()
    (library["root"] / "gcode" / "big.gcode").write_bytes(b"G1 X1\n" * 1000)

    target = archive_of(library, tmp_path)
    with tarfile.open(target, "r:gz") as archive:
        names = archive.getnames()

    assert not any("gcode" in name for name in names)


def test_the_manifest_counts_what_went_in(library, tmp_path: Path):
    target = archive_of(library, tmp_path)
    manifest = read_manifest(target)

    assert manifest.version == ARCHIVE_VERSION
    assert manifest.model_count == 2
    assert manifest.thumbnail_count == 1
    assert manifest.database_bytes > 0
    assert manifest.created_at > 0


def test_the_database_is_copied_with_its_most_recent_writes(library, tmp_path: Path):
    # In WAL mode the newest commits live in a separate file until a
    # checkpoint, so a plain file copy silently loses whatever was written
    # most recently - which on a library is the row somebody just added.
    with sqlite3.connect(library["database"]) as connection:
        connection.execute("PRAGMA journal_mode=WAL")
        connection.execute("INSERT INTO items VALUES ('c3', 'قطعة جديدة')")

    target = archive_of(library, tmp_path)

    with tarfile.open(target, "r:gz") as archive:
        archive.extract(DATABASE_NAME, tmp_path / "unpacked")
    with sqlite3.connect(tmp_path / "unpacked" / DATABASE_NAME) as restored:
        rows = restored.execute("SELECT id FROM items ORDER BY id").fetchall()

    assert [row[0] for row in rows] == ["a1", "c3"]


def test_an_interrupted_backup_leaves_no_partial_file(library, tmp_path: Path, monkeypatch):
    target = tmp_path / "backup.tar.gz"

    def explode(*args, **kwargs):
        raise OSError("disk full")

    monkeypatch.setattr(tarfile, "open", explode)

    with pytest.raises(OSError):
        create_archive(
            target,
            database=library["database"],
            models=library["models"],
            thumbnails=library["thumbnails"],
        )

    # A truncated archive that looks restorable is worse than none.
    assert not target.exists()


def test_a_library_with_no_database_yet_still_backs_up(tmp_path: Path):
    models = tmp_path / "models"
    models.mkdir()
    (models / "x.stl").write_bytes(b"solid x\n")

    manifest = create_archive(
        tmp_path / "b.tar.gz",
        database=tmp_path / "missing.db",
        models=models,
        thumbnails=tmp_path / "no-thumbs",
    )

    assert manifest.database_bytes == 0
    assert manifest.model_count == 1


# --------------------------------------------------------------------------- #
# Reading
# --------------------------------------------------------------------------- #


def test_a_file_that_is_not_an_archive_is_refused(tmp_path: Path):
    fake = tmp_path / "notes.tar.gz"
    fake.write_bytes(b"just some text")

    with pytest.raises(BackupError):
        read_manifest(fake)


def test_a_tar_without_a_manifest_is_refused(tmp_path: Path):
    plain = tmp_path / "other.tar.gz"
    payload = tmp_path / "file.txt"
    payload.write_text("hello", encoding="utf-8")
    with tarfile.open(plain, "w:gz") as archive:
        archive.add(payload, arcname="file.txt")

    with pytest.raises(BackupError):
        read_manifest(plain)


def test_an_archive_from_a_newer_version_is_refused(library, tmp_path: Path):
    target = archive_of(library, tmp_path)

    # Rewrite the manifest claiming a future format.
    staging = tmp_path / "staging"
    with tarfile.open(target, "r:gz") as archive:
        archive.extractall(staging)
    manifest = json.loads((staging / MANIFEST_NAME).read_text(encoding="utf-8"))
    manifest["version"] = ARCHIVE_VERSION + 5
    (staging / MANIFEST_NAME).write_text(json.dumps(manifest), encoding="utf-8")
    rebuilt = tmp_path / "future.tar.gz"
    with tarfile.open(rebuilt, "w:gz") as archive:
        for item in staging.rglob("*"):
            if item.is_file():
                archive.add(item, arcname=str(item.relative_to(staging)))

    # Half-applying an archive we do not understand is worse than refusing it.
    with pytest.raises(BackupError) as caught:
        read_manifest(rebuilt)
    assert "أحدث" in str(caught.value)


def test_a_missing_archive_is_refused(tmp_path: Path):
    with pytest.raises(BackupError):
        read_manifest(tmp_path / "nope.tar.gz")


# --------------------------------------------------------------------------- #
# Restoring
# --------------------------------------------------------------------------- #


def test_restoring_onto_an_empty_pi_brings_everything_back(library, tmp_path: Path):
    target = archive_of(library, tmp_path)
    fresh = tmp_path / "fresh"

    report = restore_archive(
        target,
        database=fresh / "db" / "neptune.db",
        models=fresh / "models",
        thumbnails=fresh / "thumbnails",
    )

    assert report.models_restored == 2
    assert report.thumbnails_restored == 1
    assert report.database_restored is True
    assert (fresh / "models" / "a1.stl").read_bytes() == b"solid one\nendsolid\n"


def test_restoring_over_a_working_library_only_fills_the_gaps(library, tmp_path: Path):
    target = archive_of(library, tmp_path)

    # Delete one model and change another, then restore.
    (library["models"] / "a1.stl").unlink()
    (library["models"] / "b2.stl").write_bytes(b"solid EDITED\n")

    report = restore_archive(
        target,
        database=library["database"],
        models=library["models"],
        thumbnails=library["thumbnails"],
    )

    assert report.models_restored == 1
    # The edited file is left alone: a restore onto a working Pi is usually
    # somebody recovering one thing, not rolling the library back.
    assert (library["models"] / "b2.stl").read_bytes() == b"solid EDITED\n"
    assert (library["models"] / "a1.stl").is_file()
    assert report.database_restored is False


def test_replacing_the_database_moves_the_old_one_aside(library, tmp_path: Path):
    target = archive_of(library, tmp_path)
    with sqlite3.connect(library["database"]) as connection:
        connection.execute("INSERT INTO items VALUES ('z9', 'بعد النسخة')")

    report = restore_archive(
        target,
        database=library["database"],
        models=library["models"],
        thumbnails=library["thumbnails"],
        keep_existing=False,
    )

    assert report.database_restored is True
    # Moved, not deleted - the difference between a restore you can walk back
    # from and one you cannot.
    aside = list(library["database"].parent.glob("*.replaced-*.db"))
    assert len(aside) == 1
    with sqlite3.connect(aside[0]) as old:
        assert old.execute("SELECT COUNT(*) FROM items").fetchone()[0] == 2


def test_a_restore_with_nothing_new_says_so(library, tmp_path: Path):
    target = archive_of(library, tmp_path)

    report = restore_archive(
        target,
        database=library["database"],
        models=library["models"],
        thumbnails=library["thumbnails"],
    )

    assert report.models_restored == 0
    assert any("موجود بالفعل" in note for note in report.notes_ar)


def test_an_archive_that_tries_to_escape_the_directory_is_ignored(tmp_path: Path):
    # A tar member can be named ../../etc/anything, and extracting one blindly
    # writes wherever it says.
    staging = tmp_path / "evil"
    staging.mkdir()
    manifest = {"version": ARCHIVE_VERSION, "created_at": time.time()}
    (staging / MANIFEST_NAME).write_text(json.dumps(manifest), encoding="utf-8")
    escape = staging / "escape.txt"
    escape.write_text("owned", encoding="utf-8")

    evil = tmp_path / "evil.tar.gz"
    with tarfile.open(evil, "w:gz") as archive:
        archive.add(staging / MANIFEST_NAME, arcname=MANIFEST_NAME)
        archive.add(escape, arcname="../../escaped.txt")

    fresh = tmp_path / "fresh"
    restore_archive(
        evil,
        database=fresh / "neptune.db",
        models=fresh / "models",
        thumbnails=fresh / "thumbnails",
    )

    assert not (tmp_path.parent / "escaped.txt").exists()
    assert not (tmp_path / "escaped.txt").exists()


# --------------------------------------------------------------------------- #
# Housekeeping
# --------------------------------------------------------------------------- #


def test_archives_are_listed_newest_first(library, tmp_path: Path):
    folder = tmp_path / "backups"
    folder.mkdir()
    for index, name in enumerate(["old.tar.gz", "middle.tar.gz", "new.tar.gz"]):
        path = folder / name
        create_archive(
            path,
            database=library["database"],
            models=library["models"],
            thumbnails=library["thumbnails"],
        )
        import os
        os.utime(path, (1000 + index * 100, 1000 + index * 100))

    listed = [entry["filename"] for entry in list_archives(folder)]

    assert listed == ["new.tar.gz", "middle.tar.gz", "old.tar.gz"]


def test_listing_a_directory_that_does_not_exist_is_empty(tmp_path: Path):
    assert list_archives(tmp_path / "nope") == []


def test_pruning_keeps_the_newest_and_deletes_the_rest(library, tmp_path: Path):
    folder = tmp_path / "backups"
    folder.mkdir()
    import os
    for index in range(5):
        path = folder / f"b{index}.tar.gz"
        create_archive(
            path,
            database=library["database"],
            models=library["models"],
            thumbnails=library["thumbnails"],
        )
        os.utime(path, (1000 + index * 100, 1000 + index * 100))

    # A backup nobody prunes fills the card it exists to protect.
    removed = prune(folder, keep=2)

    assert removed == 3
    assert {entry["filename"] for entry in list_archives(folder)} == {"b4.tar.gz", "b3.tar.gz"}
