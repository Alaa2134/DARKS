from __future__ import annotations

import sys
from pathlib import Path

import pytest

BASE_DIR = Path(__file__).resolve().parent.parent
if str(BASE_DIR) not in sys.path:
    sys.path.insert(0, str(BASE_DIR))

from app.config import AppConfig, reset_config, set_config  # noqa: E402


@pytest.fixture()
def config(tmp_path: Path) -> AppConfig:
    cfg = AppConfig()
    cfg.paths.data_dir = str(tmp_path / "data")
    cfg.paths.models_dir = str(tmp_path / "data" / "models")
    cfg.paths.gcode_dir = str(tmp_path / "data" / "gcode")
    cfg.paths.database = str(tmp_path / "data" / "neptune.db")
    cfg.paths.profiles_dir = str(BASE_DIR / "profiles")
    cfg.power.provider = "demo"
    cfg.history.enabled = True
    cfg.ensure_directories()
    set_config(cfg)
    yield cfg
    reset_config()
