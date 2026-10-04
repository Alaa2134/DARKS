from __future__ import annotations

import os
from pathlib import Path

from app.config import AppConfig, load_config, load_dotenv


def test_defaults_match_the_documented_setup():
    cfg = AppConfig()
    assert cfg.server.port == 8710
    assert cfg.moonraker.port == 7125
    assert cfg.moonraker.base_url == "http://127.0.0.1:7125"
    assert cfg.moonraker.ws_url == "ws://127.0.0.1:7125/websocket"
    assert cfg.power.safety.max_nozzle_temp == 50
    assert cfg.power.safety.max_bed_temp == 45
    assert cfg.auto_power_off.enabled is False
    assert cfg.tuya.enabled is False


def test_example_config_parses(tmp_path: Path):
    example = Path(__file__).resolve().parent.parent / "config.example.yaml"
    cfg = load_config(example)
    assert cfg.server.port == 8710
    assert cfg.tuya.endpoint.startswith("https://openapi.tuya")
    assert cfg.power.provider == "none"
    assert cfg.slicer.engine == "prusaslicer"
    # No secrets committed in the example.
    assert cfg.tuya.access_secret == ""
    assert cfg.server.api_token == ""


def test_yaml_then_env_override(tmp_path: Path, monkeypatch):
    config_file = tmp_path / "config.yaml"
    config_file.write_text(
        "server:\n  port: 9000\nmoonraker:\n  host: '10.0.0.5'\n", encoding="utf-8"
    )
    monkeypatch.setenv("NEPTUNE_MOONRAKER_HOST", "100.78.2.66")
    monkeypatch.setenv("NEPTUNE_TUYA_ENABLED", "true")
    monkeypatch.setenv("NEPTUNE_PORT", "8712")

    cfg = load_config(config_file)
    assert cfg.server.port == 8712  # env wins over yaml
    assert cfg.moonraker.host == "100.78.2.66"
    assert cfg.tuya.enabled is True


def test_dotenv_does_not_clobber_real_env(tmp_path: Path, monkeypatch):
    env_file = tmp_path / ".env"
    env_file.write_text('NEPTUNE_API_TOKEN="from-file"\nNEPTUNE_LOG_LEVEL=debug\n', encoding="utf-8")
    monkeypatch.setenv("NEPTUNE_API_TOKEN", "from-environment")
    load_dotenv(env_file)
    assert os.environ["NEPTUNE_API_TOKEN"] == "from-environment"
    assert os.environ["NEPTUNE_LOG_LEVEL"] == "debug"


def test_auth_required_flag():
    cfg = AppConfig()
    assert cfg.server.auth_required is False
    cfg.server.api_token = "  secret "
    assert cfg.server.auth_required is True


def test_paths_expand_user():
    cfg = AppConfig()
    resolved = cfg.paths.resolved()
    assert not str(resolved["data_dir"]).startswith("~")
    assert resolved["models_dir"].name == "models"
