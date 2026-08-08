"""Single SQLite database shared by the library, filament, products,
maintenance, videos and vision modules.

The database is opened once, guarded by a lock, and migrated forward with
plain ``CREATE TABLE IF NOT EXISTS`` statements so upgrades never lose data.
"""

from __future__ import annotations

import json
import sqlite3
import threading
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence

SCHEMA = """
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

-- ---------------------------------------------------------------- library --
CREATE TABLE IF NOT EXISTS library_items (
    id              TEXT PRIMARY KEY,
    name_ar         TEXT NOT NULL DEFAULT '',
    name_en         TEXT NOT NULL DEFAULT '',
    aliases         TEXT NOT NULL DEFAULT '[]',
    tags            TEXT NOT NULL DEFAULT '[]',
    category        TEXT NOT NULL DEFAULT 'other',
    notes           TEXT NOT NULL DEFAULT '',
    thumbnail       TEXT,
    hero_image      TEXT,
    model_path      TEXT,
    model_filename  TEXT NOT NULL DEFAULT '',
    model_size      INTEGER NOT NULL DEFAULT 0,
    dimensions_x    REAL,
    dimensions_y    REAL,
    dimensions_z    REAL,
    triangle_count  INTEGER,
    recommended_material TEXT NOT NULL DEFAULT '',
    estimated_seconds    REAL,
    estimated_filament_g REAL,
    favourite       INTEGER NOT NULL DEFAULT 0,
    print_count     INTEGER NOT NULL DEFAULT 0,
    last_printed    REAL,
    successful_profile TEXT,
    is_product      INTEGER NOT NULL DEFAULT 0,
    created_at      REAL NOT NULL,
    updated_at      REAL NOT NULL,
    search_blob     TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_library_updated ON library_items(updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_library_category ON library_items(category);
CREATE INDEX IF NOT EXISTS idx_library_favourite ON library_items(favourite);

CREATE TABLE IF NOT EXISTS library_gcodes (
    id          TEXT PRIMARY KEY,
    item_id     TEXT NOT NULL,
    filename    TEXT NOT NULL,
    path        TEXT NOT NULL DEFAULT '',
    moonraker_path TEXT,
    material    TEXT NOT NULL DEFAULT '',
    quality     TEXT NOT NULL DEFAULT '',
    layer_height REAL,
    estimated_seconds REAL,
    filament_g  REAL,
    layer_count INTEGER,
    profile     TEXT NOT NULL DEFAULT '{}',
    created_at  REAL NOT NULL,
    FOREIGN KEY(item_id) REFERENCES library_items(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_gcodes_item ON library_gcodes(item_id);

CREATE TABLE IF NOT EXISTS library_photos (
    id         TEXT PRIMARY KEY,
    item_id    TEXT NOT NULL,
    path       TEXT NOT NULL,
    caption    TEXT NOT NULL DEFAULT '',
    created_at REAL NOT NULL,
    FOREIGN KEY(item_id) REFERENCES library_items(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS collections (
    id         TEXT PRIMARY KEY,
    name_ar    TEXT NOT NULL,
    name_en    TEXT NOT NULL DEFAULT '',
    builtin    INTEGER NOT NULL DEFAULT 0,
    icon       TEXT NOT NULL DEFAULT 'folder',
    created_at REAL NOT NULL
);

CREATE TABLE IF NOT EXISTS collection_items (
    collection_id TEXT NOT NULL,
    item_id       TEXT NOT NULL,
    added_at      REAL NOT NULL,
    PRIMARY KEY (collection_id, item_id),
    FOREIGN KEY(collection_id) REFERENCES collections(id) ON DELETE CASCADE,
    FOREIGN KEY(item_id) REFERENCES library_items(id) ON DELETE CASCADE
);

-- --------------------------------------------------------------- filament --
CREATE TABLE IF NOT EXISTS filament_spools (
    id             TEXT PRIMARY KEY,
    brand          TEXT NOT NULL DEFAULT '',
    material       TEXT NOT NULL DEFAULT 'PLA',
    color_name     TEXT NOT NULL DEFAULT '',
    color_hex      TEXT NOT NULL DEFAULT '#333333',
    initial_grams  REAL NOT NULL DEFAULT 1000,
    remaining_grams REAL NOT NULL DEFAULT 1000,
    spool_weight_g REAL NOT NULL DEFAULT 200,
    price          REAL NOT NULL DEFAULT 0,
    currency       TEXT NOT NULL DEFAULT 'EGP',
    purchased_at   REAL,
    notes          TEXT NOT NULL DEFAULT '',
    active         INTEGER NOT NULL DEFAULT 0,
    archived       INTEGER NOT NULL DEFAULT 0,
    created_at     REAL NOT NULL,
    updated_at     REAL NOT NULL
);

CREATE TABLE IF NOT EXISTS filament_usage (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    spool_id   TEXT NOT NULL,
    grams      REAL NOT NULL,
    reason     TEXT NOT NULL DEFAULT 'print',
    history_id INTEGER,
    created_at REAL NOT NULL,
    FOREIGN KEY(spool_id) REFERENCES filament_spools(id) ON DELETE CASCADE
);

-- --------------------------------------------------------------- products --
CREATE TABLE IF NOT EXISTS products (
    id            TEXT PRIMARY KEY,
    item_id       TEXT,
    name_ar       TEXT NOT NULL DEFAULT '',
    name_en       TEXT NOT NULL DEFAULT '',
    sku           TEXT NOT NULL DEFAULT '',
    image         TEXT,
    material      TEXT NOT NULL DEFAULT 'PLA',
    colors        TEXT NOT NULL DEFAULT '[]',
    print_cost    REAL NOT NULL DEFAULT 0,
    selling_price REAL NOT NULL DEFAULT 0,
    currency      TEXT NOT NULL DEFAULT 'EGP',
    made_to_order INTEGER NOT NULL DEFAULT 1,
    stock         INTEGER NOT NULL DEFAULT 0,
    notes         TEXT NOT NULL DEFAULT '',
    created_at    REAL NOT NULL,
    updated_at    REAL NOT NULL,
    FOREIGN KEY(item_id) REFERENCES library_items(id) ON DELETE SET NULL
);

-- ------------------------------------------------------------ maintenance --
CREATE TABLE IF NOT EXISTS maintenance_tasks (
    id             TEXT PRIMARY KEY,
    name_ar        TEXT NOT NULL,
    name_en        TEXT NOT NULL DEFAULT '',
    icon           TEXT NOT NULL DEFAULT 'wrench',
    interval_hours REAL,
    interval_prints INTEGER,
    interval_days  INTEGER,
    last_done_at   REAL,
    last_done_hours REAL NOT NULL DEFAULT 0,
    last_done_prints INTEGER NOT NULL DEFAULT 0,
    enabled        INTEGER NOT NULL DEFAULT 1,
    notes          TEXT NOT NULL DEFAULT '',
    builtin        INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS maintenance_log (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id    TEXT NOT NULL,
    done_at    REAL NOT NULL,
    note       TEXT NOT NULL DEFAULT ''
);

-- ----------------------------------------------------------------- videos --
CREATE TABLE IF NOT EXISTS videos (
    id           TEXT PRIMARY KEY,
    kind         TEXT NOT NULL DEFAULT 'recording',
    path         TEXT NOT NULL,
    filename     TEXT NOT NULL,
    item_id      TEXT,
    history_id   INTEGER,
    gcode_name   TEXT NOT NULL DEFAULT '',
    started_at   REAL NOT NULL,
    finished_at  REAL,
    duration     REAL,
    size_bytes   INTEGER NOT NULL DEFAULT 0,
    result       TEXT NOT NULL DEFAULT 'unknown',
    thumbnail    TEXT,
    frame_count  INTEGER,
    error        TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_videos_started ON videos(started_at DESC);

-- ----------------------------------------------------------------- vision --
CREATE TABLE IF NOT EXISTS vision_events (
    id          TEXT PRIMARY KEY,
    created_at  REAL NOT NULL,
    kind        TEXT NOT NULL,
    confidence  REAL NOT NULL DEFAULT 0,
    confirmed   INTEGER NOT NULL DEFAULT 0,
    action      TEXT NOT NULL DEFAULT 'none',
    snapshot    TEXT,
    gcode_name  TEXT NOT NULL DEFAULT '',
    layer       INTEGER,
    progress    REAL,
    detail      TEXT NOT NULL DEFAULT '',
    acknowledged INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_vision_created ON vision_events(created_at DESC);

-- ------------------------------------------------------------ print queue --
CREATE TABLE IF NOT EXISTS print_queue (
    id          TEXT PRIMARY KEY,
    item_id     TEXT,
    gcode_path  TEXT NOT NULL,
    display_name TEXT NOT NULL DEFAULT '',
    material    TEXT NOT NULL DEFAULT '',
    estimated_seconds REAL,
    filament_g  REAL,
    position    INTEGER NOT NULL DEFAULT 0,
    status      TEXT NOT NULL DEFAULT 'waiting',
    created_at  REAL NOT NULL,
    started_at  REAL,
    finished_at REAL
);

-- ---------------------------------------------------------------- ratings --
CREATE TABLE IF NOT EXISTS print_ratings (
    history_id INTEGER PRIMARY KEY,
    item_id    TEXT,
    rating     TEXT NOT NULL,
    profile    TEXT NOT NULL DEFAULT '{}',
    note       TEXT NOT NULL DEFAULT '',
    created_at REAL NOT NULL
);

-- --------------------------------------------------------- key/value store --
CREATE TABLE IF NOT EXISTS app_state (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
"""


class Database:
    """Thin synchronous SQLite wrapper. All access is serialised by a lock."""

    def __init__(self, path: Path) -> None:
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        self._conn = sqlite3.connect(str(self.path), check_same_thread=False)
        self._conn.row_factory = sqlite3.Row
        with self._lock:
            self._conn.executescript(SCHEMA)
            self._conn.commit()

    # ------------------------------------------------------------- plumbing
    def close(self) -> None:
        with self._lock:
            self._conn.close()

    def execute(self, sql: str, params: Sequence[Any] = ()) -> sqlite3.Cursor:
        with self._lock:
            cursor = self._conn.execute(sql, params)
            self._conn.commit()
            return cursor

    def executescript(self, sql: str) -> None:
        """Run a multi-statement script. Used by modules that own their own
        tables so their schema lives beside their code."""
        with self._lock:
            self._conn.executescript(sql)
            self._conn.commit()

    def executemany(self, sql: str, seq: Iterable[Sequence[Any]]) -> None:
        with self._lock:
            self._conn.executemany(sql, seq)
            self._conn.commit()

    def query(self, sql: str, params: Sequence[Any] = ()) -> List[sqlite3.Row]:
        with self._lock:
            return list(self._conn.execute(sql, params).fetchall())

    def query_one(self, sql: str, params: Sequence[Any] = ()) -> Optional[sqlite3.Row]:
        rows = self.query(sql, params)
        return rows[0] if rows else None

    # --------------------------------------------------------- key/value API
    def get_state(self, key: str, default: Any = None) -> Any:
        row = self.query_one("SELECT value FROM app_state WHERE key = ?", (key,))
        if row is None:
            return default
        try:
            return json.loads(row["value"])
        except ValueError:
            return default

    def set_state(self, key: str, value: Any) -> None:
        self.execute(
            "INSERT INTO app_state(key, value) VALUES(?, ?) "
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            (key, json.dumps(value, ensure_ascii=False)),
        )


def row_to_dict(row: Optional[sqlite3.Row]) -> Dict[str, Any]:
    return dict(row) if row is not None else {}


def load_json(value: Any, default: Any) -> Any:
    if value is None:
        return default
    if isinstance(value, (list, dict)):
        return value
    try:
        return json.loads(value)
    except (TypeError, ValueError):
        return default


def dump_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False)
