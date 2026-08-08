"""Configuration loading for the Neptune Remote backend.

Configuration comes from three layers, later layers win:

1. Built-in defaults (this file).
2. ``config.yaml`` next to the ``raspberry-pi`` directory (or ``$NEPTUNE_CONFIG``).
3. Environment variables (and a ``.env`` file sitting beside the config file).

Secrets (Tuya access secret, API token) should live in the environment or in a
``config.yaml`` that is excluded from git -- never in ``config.example.yaml``.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any, Dict, List, Optional

import yaml
from pydantic import BaseModel, Field

# --------------------------------------------------------------------------- #
# Paths
# --------------------------------------------------------------------------- #

PACKAGE_DIR = Path(__file__).resolve().parent
BASE_DIR = PACKAGE_DIR.parent  # .../raspberry-pi
DEFAULT_CONFIG_PATH = BASE_DIR / "config.yaml"
EXAMPLE_CONFIG_PATH = BASE_DIR / "config.example.yaml"


def _expand(path: str | Path) -> Path:
    return Path(os.path.expandvars(str(path))).expanduser()


# --------------------------------------------------------------------------- #
# Models
# --------------------------------------------------------------------------- #


class ServerConfig(BaseModel):
    host: str = "0.0.0.0"
    port: int = 8710
    api_token: str = ""
    cors_origins: List[str] = Field(default_factory=lambda: ["*"])
    log_level: str = "info"

    @property
    def auth_required(self) -> bool:
        return bool(self.api_token.strip())


class MoonrakerConfig(BaseModel):
    host: str = "127.0.0.1"
    port: int = 7125
    use_tls: bool = False
    api_key: str = ""
    timeout_seconds: float = 10.0

    @property
    def base_url(self) -> str:
        scheme = "https" if self.use_tls else "http"
        return f"{scheme}://{self.host}:{self.port}"

    @property
    def ws_url(self) -> str:
        scheme = "wss" if self.use_tls else "ws"
        return f"{scheme}://{self.host}:{self.port}/websocket"


class PathsConfig(BaseModel):
    data_dir: str = "~/neptune-remote-data"
    models_dir: str = "~/neptune-remote-data/models"
    gcode_dir: str = "~/neptune-remote-data/gcode"
    profiles_dir: str = str(BASE_DIR / "profiles")
    database: str = "~/neptune-remote-data/neptune.db"

    def resolved(self) -> Dict[str, Path]:
        return {
            "data_dir": _expand(self.data_dir),
            "models_dir": _expand(self.models_dir),
            "gcode_dir": _expand(self.gcode_dir),
            "profiles_dir": _expand(self.profiles_dir),
            "database": _expand(self.database),
        }


class SlicerConfig(BaseModel):
    engine: str = "prusaslicer"  # prusaslicer | orcaslicer
    prusaslicer_bin: str = "prusa-slicer"
    orcaslicer_bin: str = "orca-slicer"
    timeout_seconds: int = 1800
    max_concurrent_jobs: int = 1
    keep_jobs: int = 40


class WebhookPowerConfig(BaseModel):
    on_url: str = ""
    off_url: str = ""
    status_url: str = ""
    method: str = "POST"
    headers: Dict[str, str] = Field(default_factory=dict)
    on_body: str = ""
    off_body: str = ""
    # Dotted path inside the JSON response that holds the state, e.g. "data.state".
    status_json_path: str = "state"
    # Value (case-insensitive, stringified) that means "powered on".
    on_value: str = "on"


class PowerSafetyConfig(BaseModel):
    enabled: bool = True
    max_nozzle_temp: float = 50.0
    max_bed_temp: float = 45.0
    block_while_printing: bool = True


class PowerConfig(BaseModel):
    # tuya | moonraker | webhook | demo | none
    provider: str = "none"
    moonraker_device: str = "printer"
    webhook: WebhookPowerConfig = Field(default_factory=WebhookPowerConfig)
    safety: PowerSafetyConfig = Field(default_factory=PowerSafetyConfig)


class TuyaConfig(BaseModel):
    enabled: bool = False
    access_id: str = ""
    access_secret: str = ""
    device_id: str = ""
    endpoint: str = "https://openapi.tuyaeu.com"
    # DP code of the relay on the device. Most single-gang plugs use "switch_1",
    # some use "switch". Read GET /api/power/status -> raw to discover yours.
    switch_code: str = "switch_1"


class AutoPowerOffConfig(BaseModel):
    enabled: bool = False
    nozzle_below: float = 50.0
    bed_below: float = 45.0
    delay_seconds: int = 300
    # Only fire after a print that completed successfully.
    only_after_successful_print: bool = True


class HistoryConfig(BaseModel):
    enabled: bool = True
    max_entries: int = 2000


class CameraConfig(BaseModel):
    enabled: bool = True
    # Preferred: a stream served by crowsnest / ustreamer, shared with Mainsail.
    stream_url: str = ""
    snapshot_url: str = ""
    # Fallback: read /dev/videoN directly with FFmpeg (exclusive access).
    device: str = ""
    width: int = 1280
    height: int = 720
    fps: int = 15
    ffmpeg_binary: str = "ffmpeg"
    # Region of the frame that contains the print bed, as (x, y, w, h) 0..1.
    roi: Optional[List[float]] = None


class RecordingConfig(BaseModel):
    # off | manual | full | first_layer | last_layer
    mode: str = "manual"
    video_codec: str = "libx264"
    preset: str = "veryfast"
    crf: int = 24
    output_fps: int = 15
    max_seconds: int = 0            # 0 = unlimited
    # never | max_size | keep_last
    retention_policy: str = "max_size"
    retention_max_gb: float = 8.0
    retention_keep_last: int = 20


class TimelapseConfig(BaseModel):
    # off | interval | layer
    mode: str = "off"
    interval_seconds: int = 10
    output_fps: int = 25
    crf: int = 20
    min_frames: int = 12
    max_frames: int = 20_000
    keep_frames: bool = False


class VisionConfig(BaseModel):
    # off | monitor | warn | auto_pause
    mode: str = "warn"
    # disabled | heuristic | onnx
    provider: str = "heuristic"
    model_path: str = ""
    labels: List[str] = Field(default_factory=list)
    input_size: int = 320
    execution_providers: List[str] = Field(default_factory=lambda: ["CPUExecutionProvider"])
    fallback_to_heuristic: bool = True

    interval_seconds: float = 5.0
    first_layer_seconds: float = 600.0
    first_layer_interval_seconds: float = 3.0
    min_confidence: float = 0.55
    confirmations: int = 3
    window_seconds: float = 30.0
    cooldown_seconds: float = 180.0
    only_while_printing: bool = True
    max_events: int = 500

    # Back off automatically so Klipper always keeps its CPU.
    throttle_cpu_percent: float = 80.0
    throttle_temp_c: float = 75.0

    roi: Optional[List[float]] = None

    # Heuristic provider tuning.
    edge_growth_threshold: float = 1.55
    change_threshold: float = 0.28


class StorageConfig(BaseModel):
    """Root of everything Neptune Remote writes."""

    root: str = "~/printer_data/neptune_remote"
    # Files copied into a backup archive. Never modified, only read.
    backup_sources: List[str] = Field(
        default_factory=lambda: [
            "~/printer_data/config/printer.cfg",
            "~/printer_data/config/moonraker.conf",
        ]
    )
    max_backups: int = 10


class AppConfig(BaseModel):
    server: ServerConfig = Field(default_factory=ServerConfig)
    moonraker: MoonrakerConfig = Field(default_factory=MoonrakerConfig)
    paths: PathsConfig = Field(default_factory=PathsConfig)
    storage: StorageConfig = Field(default_factory=StorageConfig)
    slicer: SlicerConfig = Field(default_factory=SlicerConfig)
    power: PowerConfig = Field(default_factory=PowerConfig)
    tuya: TuyaConfig = Field(default_factory=TuyaConfig)
    auto_power_off: AutoPowerOffConfig = Field(default_factory=AutoPowerOffConfig)
    history: HistoryConfig = Field(default_factory=HistoryConfig)
    camera: CameraConfig = Field(default_factory=CameraConfig)
    recording: RecordingConfig = Field(default_factory=RecordingConfig)
    timelapse: TimelapseConfig = Field(default_factory=TimelapseConfig)
    vision: VisionConfig = Field(default_factory=VisionConfig)

    source_path: Optional[str] = None

    def ensure_directories(self) -> None:
        paths = self.paths.resolved()
        for key in ("data_dir", "models_dir", "gcode_dir"):
            paths[key].mkdir(parents=True, exist_ok=True)
        paths["database"].parent.mkdir(parents=True, exist_ok=True)


# --------------------------------------------------------------------------- #
# Loading
# --------------------------------------------------------------------------- #

# env var -> dotted config path
ENV_OVERRIDES: Dict[str, str] = {
    "NEPTUNE_HOST": "server.host",
    "NEPTUNE_PORT": "server.port",
    "NEPTUNE_API_TOKEN": "server.api_token",
    "NEPTUNE_LOG_LEVEL": "server.log_level",
    "NEPTUNE_MOONRAKER_HOST": "moonraker.host",
    "NEPTUNE_MOONRAKER_PORT": "moonraker.port",
    "NEPTUNE_MOONRAKER_API_KEY": "moonraker.api_key",
    "NEPTUNE_DATA_DIR": "paths.data_dir",
    "NEPTUNE_MODELS_DIR": "paths.models_dir",
    "NEPTUNE_GCODE_DIR": "paths.gcode_dir",
    "NEPTUNE_PROFILES_DIR": "paths.profiles_dir",
    "NEPTUNE_DATABASE": "paths.database",
    "NEPTUNE_SLICER_ENGINE": "slicer.engine",
    "NEPTUNE_PRUSASLICER_BIN": "slicer.prusaslicer_bin",
    "NEPTUNE_ORCASLICER_BIN": "slicer.orcaslicer_bin",
    "NEPTUNE_POWER_PROVIDER": "power.provider",
    "NEPTUNE_POWER_MOONRAKER_DEVICE": "power.moonraker_device",
    "NEPTUNE_TUYA_ENABLED": "tuya.enabled",
    "NEPTUNE_TUYA_ACCESS_ID": "tuya.access_id",
    "NEPTUNE_TUYA_ACCESS_SECRET": "tuya.access_secret",
    "NEPTUNE_TUYA_DEVICE_ID": "tuya.device_id",
    "NEPTUNE_TUYA_ENDPOINT": "tuya.endpoint",
    "NEPTUNE_TUYA_SWITCH_CODE": "tuya.switch_code",
    "NEPTUNE_STORAGE_ROOT": "storage.root",
    "NEPTUNE_CAMERA_STREAM_URL": "camera.stream_url",
    "NEPTUNE_CAMERA_SNAPSHOT_URL": "camera.snapshot_url",
    "NEPTUNE_CAMERA_DEVICE": "camera.device",
    "NEPTUNE_FFMPEG_BIN": "camera.ffmpeg_binary",
    "NEPTUNE_RECORDING_MODE": "recording.mode",
    "NEPTUNE_TIMELAPSE_MODE": "timelapse.mode",
    "NEPTUNE_VISION_MODE": "vision.mode",
    "NEPTUNE_VISION_PROVIDER": "vision.provider",
    "NEPTUNE_VISION_MODEL": "vision.model_path",
}

_BOOL_TRUE = {"1", "true", "yes", "on", "y"}
_BOOL_FALSE = {"0", "false", "no", "off", "n"}


def _coerce(raw: str) -> Any:
    lowered = raw.strip().lower()
    if lowered in _BOOL_TRUE:
        return True
    if lowered in _BOOL_FALSE:
        return False
    try:
        if lowered.isdigit() or (lowered.startswith("-") and lowered[1:].isdigit()):
            return int(lowered)
        return float(raw)
    except ValueError:
        return raw


def _assign(tree: Dict[str, Any], dotted: str, value: Any) -> None:
    parts = dotted.split(".")
    node = tree
    for part in parts[:-1]:
        nxt = node.get(part)
        if not isinstance(nxt, dict):
            nxt = {}
            node[part] = nxt
        node = nxt
    node[parts[-1]] = value


def _deep_merge(base: Dict[str, Any], overlay: Dict[str, Any]) -> Dict[str, Any]:
    out = dict(base)
    for key, value in overlay.items():
        if isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = _deep_merge(out[key], value)
        else:
            out[key] = value
    return out


def load_dotenv(path: Path) -> None:
    """Minimal .env loader (no external dependency).

    Existing environment variables always win, so systemd/CLI overrides are safe.
    """
    if not path.is_file():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if key and key not in os.environ:
            os.environ[key] = value


def load_config(path: Optional[str | Path] = None) -> AppConfig:
    """Load configuration from YAML + environment."""
    config_path = Path(path) if path else Path(os.environ.get("NEPTUNE_CONFIG", DEFAULT_CONFIG_PATH))
    load_dotenv(config_path.parent / ".env")

    data: Dict[str, Any] = {}
    if config_path.is_file():
        loaded = yaml.safe_load(config_path.read_text(encoding="utf-8")) or {}
        if not isinstance(loaded, dict):
            raise ValueError(f"{config_path} must contain a YAML mapping at the top level")
        data = loaded

    overrides: Dict[str, Any] = {}
    for env_key, dotted in ENV_OVERRIDES.items():
        raw = os.environ.get(env_key)
        if raw is not None and raw != "":
            _assign(overrides, dotted, _coerce(raw))

    merged = _deep_merge(data, overrides)
    config = AppConfig(**merged)
    config.source_path = str(config_path)
    return config


_cached: Optional[AppConfig] = None


def get_config() -> AppConfig:
    global _cached
    if _cached is None:
        _cached = load_config()
    return _cached


def set_config(config: AppConfig) -> None:
    """Used by tests and by the app factory to inject configuration."""
    global _cached
    _cached = config


def reset_config() -> None:
    global _cached
    _cached = None
