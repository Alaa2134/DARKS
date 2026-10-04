"""Get the library off the SD card and back again.

The library is the only thing on this Pi that cannot be recreated. Klipper's
config lives in a repository, the G-code can be re-sliced, the videos are
disposable - but the models, what they are called in Arabic, which ones worked,
which profile printed them and which photos were taken of the result are years
of accumulation on a consumer SD card. Those fail.

An archive holds three things:

**The database**, copied through SQLite's own backup API rather than off disk.
A WAL-mode database being written to has its most recent commits in a separate
file; copying the `.db` alone captures a version that is missing them, and does
so silently.

**The model files and their thumbnails**, which are what the database rows point
at. A database without them restores a library of dead links.

**A manifest**, so a restore can refuse an archive from a newer version rather
than half-apply it.

G-code and videos are deliberately excluded. They are large, they are
regenerable, and including them turns a 40 MB archive into a 4 GB one that
nobody will actually take a copy of - which makes the backup worse, not better.
"""

from __future__ import annotations

import json
import logging
import shutil
import sqlite3
import tarfile
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional

log = logging.getLogger("neptune.library.backup")

#: Bump when the archive layout changes in a way an older reader cannot handle.
ARCHIVE_VERSION = 1

MANIFEST_NAME = "neptune-backup.json"
DATABASE_NAME = "library.db"
MODELS_DIR = "models"
THUMBNAILS_DIR = "thumbnails"

#: Refuse to restore anything bigger. An archive past this is not a library, it
#: is a mistake, and unpacking it would fill the card it is meant to protect.
MAX_ARCHIVE_BYTES = 8 * 1024 * 1024 * 1024


class BackupError(RuntimeError):
    pass


@dataclass
class BackupManifest:
    version: int = ARCHIVE_VERSION
    created_at: float = 0.0
    app_version: str = ""
    model_count: int = 0
    model_bytes: int = 0
    thumbnail_count: int = 0
    database_bytes: int = 0

    def as_dict(self) -> dict:
        return {
            "version": self.version,
            "created_at": self.created_at,
            "app_version": self.app_version,
            "model_count": self.model_count,
            "model_bytes": self.model_bytes,
            "thumbnail_count": self.thumbnail_count,
            "database_bytes": self.database_bytes,
        }

    @classmethod
    def from_dict(cls, data: dict) -> "BackupManifest":
        return cls(
            version=int(data.get("version", 0)),
            created_at=float(data.get("created_at", 0.0)),
            app_version=str(data.get("app_version", "")),
            model_count=int(data.get("model_count", 0)),
            model_bytes=int(data.get("model_bytes", 0)),
            thumbnail_count=int(data.get("thumbnail_count", 0)),
            database_bytes=int(data.get("database_bytes", 0)),
        )


@dataclass
class RestoreReport:
    """What a restore did, or would do."""

    manifest: BackupManifest = field(default_factory=BackupManifest)
    models_restored: int = 0
    thumbnails_restored: int = 0
    database_restored: bool = False
    notes_ar: List[str] = field(default_factory=list)


# --------------------------------------------------------------------------- #
# Writing
# --------------------------------------------------------------------------- #


def _copy_database(source: Path, target: Path) -> int:
    """Copy a live SQLite database safely.

    Through SQLite's own backup API, not `shutil.copy`. In WAL mode the most
    recent commits live in a separate `-wal` file until a checkpoint, so a plain
    file copy silently produces a database missing whatever was written most
    recently - which on a library is the row somebody just added.
    """
    if not source.is_file():
        return 0
    target.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(f"file:{source}?mode=ro", uri=True) as origin:
        with sqlite3.connect(target) as destination:
            origin.backup(destination)
    return target.stat().st_size


def _tree_size(path: Path) -> tuple[int, int]:
    """(file count, total bytes) under a directory."""
    count = 0
    total = 0
    if not path.is_dir():
        return (0, 0)
    for item in path.rglob("*"):
        if item.is_file():
            count += 1
            total += item.stat().st_size
    return (count, total)


def create_archive(
    destination: Path,
    *,
    database: Path,
    models: Path,
    thumbnails: Path,
    app_version: str = "",
) -> BackupManifest:
    """Write a `.tar.gz` holding the database, the models and the thumbnails.

    Compressed, because STL is text-like enough to shrink usefully and the point
    of an archive is that it fits somewhere else.

    Written to a temporary name and moved into place, so an interrupted backup
    cannot leave a truncated archive that looks restorable.
    """
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)

    workdir = Path(tempfile.mkdtemp(prefix="neptune-backup-"))
    staged_db = workdir / DATABASE_NAME
    try:
        database_bytes = _copy_database(Path(database), staged_db)
        model_count, model_bytes = _tree_size(Path(models))
        thumbnail_count, _ = _tree_size(Path(thumbnails))

        manifest = BackupManifest(
            created_at=time.time(),
            app_version=app_version,
            model_count=model_count,
            model_bytes=model_bytes,
            thumbnail_count=thumbnail_count,
            database_bytes=database_bytes,
        )
        (workdir / MANIFEST_NAME).write_text(
            json.dumps(manifest.as_dict(), indent=2), encoding="utf-8"
        )

        temporary = destination.with_suffix(destination.suffix + ".partial")
        with tarfile.open(temporary, "w:gz") as archive:
            archive.add(workdir / MANIFEST_NAME, arcname=MANIFEST_NAME)
            if database_bytes:
                archive.add(staged_db, arcname=DATABASE_NAME)
            if Path(models).is_dir():
                archive.add(Path(models), arcname=MODELS_DIR)
            if Path(thumbnails).is_dir():
                archive.add(Path(thumbnails), arcname=THUMBNAILS_DIR)
        temporary.replace(destination)

        return manifest
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


# --------------------------------------------------------------------------- #
# Reading
# --------------------------------------------------------------------------- #


def _safe_members(archive: tarfile.TarFile, roots: tuple) -> List[tarfile.TarInfo]:
    """Only regular files inside the expected directories.

    A tar archive can name `../../etc/anything`, and extracting one blindly
    writes wherever it says. Every member is checked against the roots this
    format is supposed to contain, and links are refused outright - a symlink in
    an archive is a way to make a later write land somewhere else.
    """
    members: List[tarfile.TarInfo] = []
    for member in archive.getmembers():
        if member.issym() or member.islnk():
            continue
        if not member.isfile():
            continue
        name = member.name.lstrip("./")
        if ".." in Path(name).parts:
            continue
        if name != MANIFEST_NAME and name != DATABASE_NAME:
            if not any(name.startswith(f"{root}/") for root in roots):
                continue
        members.append(member)
    return members


def read_manifest(archive_path: Path) -> BackupManifest:
    """What is in this archive, without unpacking it."""
    archive_path = Path(archive_path)
    if not archive_path.is_file():
        raise BackupError("ملف النسخة الاحتياطية مش موجود.")
    if archive_path.stat().st_size > MAX_ARCHIVE_BYTES:
        raise BackupError("الملف ده أكبر من اللازم عشان يكون نسخة احتياطية للمكتبة.")

    try:
        with tarfile.open(archive_path, "r:gz") as archive:
            handle = archive.extractfile(MANIFEST_NAME)
            if handle is None:
                raise BackupError("الملف ده مش نسخة احتياطية من نبتون.")
            manifest = BackupManifest.from_dict(json.loads(handle.read().decode("utf-8")))
    except tarfile.TarError as error:
        raise BackupError(f"مش قادر أقرا الأرشيف: {error}") from error
    except (KeyError, json.JSONDecodeError) as error:
        raise BackupError("الملف ده مش نسخة احتياطية من نبتون.") from error

    if manifest.version > ARCHIVE_VERSION:
        raise BackupError(
            f"النسخة دي من إصدار أحدث (v{manifest.version}). "
            "حدّث التطبيق على الباي الأول."
        )
    return manifest


def restore_archive(
    archive_path: Path,
    *,
    database: Path,
    models: Path,
    thumbnails: Path,
    keep_existing: bool = True,
) -> RestoreReport:
    """Unpack an archive over the current library.

    `keep_existing` merges rather than replaces: files already present are left
    alone and the database is only restored when there is not one already. That
    is the safe default, because a restore onto a working Pi is usually somebody
    recovering *one* thing rather than rolling the whole library back.

    Turning it off replaces the database, and the previous one is moved aside
    rather than deleted - the difference between a restore you can undo and one
    you cannot.
    """
    archive_path = Path(archive_path)
    manifest = read_manifest(archive_path)
    report = RestoreReport(manifest=manifest)

    workdir = Path(tempfile.mkdtemp(prefix="neptune-restore-"))
    try:
        with tarfile.open(archive_path, "r:gz") as archive:
            members = _safe_members(archive, (MODELS_DIR, THUMBNAILS_DIR))
            archive.extractall(workdir, members=members)

        for source_name, target in (
            (MODELS_DIR, Path(models)),
            (THUMBNAILS_DIR, Path(thumbnails)),
        ):
            staged = workdir / source_name
            if not staged.is_dir():
                continue
            target.mkdir(parents=True, exist_ok=True)
            for item in staged.rglob("*"):
                if not item.is_file():
                    continue
                relative = item.relative_to(staged)
                landing = target / relative
                if landing.exists() and keep_existing:
                    continue
                landing.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(item, landing)
                if source_name == MODELS_DIR:
                    report.models_restored += 1
                else:
                    report.thumbnails_restored += 1

        staged_db = workdir / DATABASE_NAME
        database = Path(database)
        if staged_db.is_file():
            if database.is_file() and keep_existing:
                report.notes_ar.append(
                    "فيه قاعدة بيانات موجودة، فاتسابت زي ما هي. "
                    "الملفات الناقصة بس هي اللي اترجّعت."
                )
            else:
                database.parent.mkdir(parents=True, exist_ok=True)
                if database.is_file():
                    # Moved aside, not deleted: this is the difference between
                    # a restore you can walk back from and one you cannot.
                    aside = database.with_name(
                        f"{database.stem}.replaced-{int(time.time())}{database.suffix}"
                    )
                    shutil.move(str(database), str(aside))
                    report.notes_ar.append(
                        f"قاعدة البيانات القديمة اتنقلت لـ {aside.name} بدل ما تتمسح."
                    )
                shutil.copy2(staged_db, database)
                report.database_restored = True

        if report.models_restored:
            report.notes_ar.append(f"اترجّع {report.models_restored} موديل.")
        if report.thumbnails_restored:
            report.notes_ar.append(f"اترجّعت {report.thumbnails_restored} صورة مصغرة.")

        # Keyed on what was actually restored rather than on whether any note
        # was written: skipping the database produces a note of its own, and
        # without this the user would be told what was *not* done and never
        # told that the answer overall was "nothing needed doing".
        nothing_changed = (
            report.models_restored == 0
            and report.thumbnails_restored == 0
            and not report.database_restored
        )
        if nothing_changed:
            report.notes_ar.append("مفيش حاجة جديدة — كل اللي في النسخة موجود بالفعل.")

        return report
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


def list_archives(directory: Path) -> List[Dict[str, object]]:
    """Backups on disk, newest first."""
    directory = Path(directory)
    if not directory.is_dir():
        return []
    entries: List[Dict[str, object]] = []
    for path in directory.glob("*.tar.gz"):
        if not path.is_file():
            continue
        stat = path.stat()
        entries.append({
            "filename": path.name,
            "size": stat.st_size,
            "created_at": stat.st_mtime,
        })
    entries.sort(key=lambda entry: entry["created_at"], reverse=True)
    return entries


def prune(directory: Path, *, keep: int = 5) -> int:
    """Delete all but the newest `keep` archives, and say how many went.

    A backup nobody prunes fills the card it exists to protect.
    """
    archives = list_archives(directory)
    removed = 0
    for entry in archives[keep:]:
        try:
            (Path(directory) / str(entry["filename"])).unlink()
            removed += 1
        except OSError as error:                            # noqa: PERF203
            log.warning("Could not delete old backup %s: %s", entry["filename"], error)
    return removed
