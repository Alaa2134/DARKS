"""Normalise raw Moonraker object status into the API's PrinterStatusResponse."""

from __future__ import annotations

from typing import Any, Dict, List, Optional

from .moonraker import MoonrakerClient, MoonrakerError, progress_from_status
from .schemas import FilamentSensorState, PrinterStatusResponse, TemperatureBlock

# Klipper print_stats.state values, plus our own "unknown".
KNOWN_STATES = {"standby", "printing", "paused", "complete", "cancelled", "error", "unknown"}


def _floats(value: Any, count: int = 3) -> List[float]:
    if isinstance(value, (list, tuple)):
        out = [float(v) for v in value[:count] if isinstance(v, (int, float))]
        while len(out) < count:
            out.append(0.0)
        return out
    return [0.0] * count


def _temperature_block(obj: Optional[Dict[str, Any]]) -> TemperatureBlock:
    obj = obj or {}
    return TemperatureBlock(
        actual=float(obj.get("temperature") or 0.0),
        target=float(obj.get("target") or 0.0),
        power=float(obj.get("power") or 0.0),
    )


def estimate_time_left(status: Dict[str, Any], progress: float) -> Optional[float]:
    """File-progress based ETA.

    Klipper itself does not publish a remaining time. Mainsail/Fluidd compute one
    from elapsed print time and file progress; we do the same and additionally
    fall back to the slicer estimate stored in the G-code metadata when the file
    progress is still too small to be meaningful.
    """
    print_stats = status.get("print_stats") or {}
    duration = float(print_stats.get("print_duration") or 0.0)
    if progress > 0.02 and duration > 0:
        total = duration / progress
        return max(0.0, total - duration)
    return None


def layer_info(status: Dict[str, Any]) -> tuple[Optional[int], Optional[int]]:
    """Klipper >= 0.11 exposes current_layer/total_layer in print_stats.info."""
    print_stats = status.get("print_stats") or {}
    info = print_stats.get("info") or {}
    current = info.get("current_layer")
    total = info.get("total_layer")
    current_int = int(current) if isinstance(current, (int, float)) else None
    total_int = int(total) if isinstance(total, (int, float)) else None
    return current_int, total_int


def build_status(
    server_info: Optional[Dict[str, Any]],
    status: Dict[str, Any],
    *,
    error: Optional[str] = None,
) -> PrinterStatusResponse:
    if error is not None and not status:
        return PrinterStatusResponse(online=False, error=error, klippy_state="unknown")

    server_info = server_info or {}
    klippy_state = str(server_info.get("klippy_state") or "unknown")
    klippy_connected = bool(server_info.get("klippy_connected", klippy_state == "ready"))

    print_stats = status.get("print_stats") or {}
    toolhead = status.get("toolhead") or {}
    gcode_move = status.get("gcode_move") or {}
    fan = status.get("fan") or {}
    webhooks = status.get("webhooks") or {}
    virtual_sdcard = status.get("virtual_sdcard") or {}

    state = str(print_stats.get("state") or ("standby" if klippy_connected else "unknown"))
    if state not in KNOWN_STATES:
        state = "unknown"

    progress = progress_from_status(status)
    current_layer, total_layer = layer_info(status)

    klippy_message = str(webhooks.get("state_message") or server_info.get("klippy_message") or "")
    filament_sensors = filament_sensor_states(status)

    return PrinterStatusResponse(
        online=True,
        klippy_state=str(webhooks.get("state") or klippy_state),
        klippy_message=klippy_message,
        state=state,
        state_message=str(print_stats.get("message") or ""),
        filename=str(print_stats.get("filename") or ""),
        progress=progress,
        print_duration=float(print_stats.get("print_duration") or 0.0),
        total_duration=float(print_stats.get("total_duration") or 0.0),
        estimated_time_left=estimate_time_left(status, progress),
        filament_used_mm=float(print_stats.get("filament_used") or 0.0),
        current_layer=current_layer,
        total_layer=total_layer,
        nozzle=_temperature_block(status.get("extruder")),
        bed=_temperature_block(status.get("heater_bed")),
        position=_floats(toolhead.get("position")),
        gcode_position=_floats(gcode_move.get("gcode_position")),
        homed_axes=str(toolhead.get("homed_axes") or ""),
        speed=float(gcode_move.get("speed") or 0.0),
        speed_factor=float(gcode_move.get("speed_factor") or 1.0),
        extrude_factor=float(gcode_move.get("extrude_factor") or 1.0),
        fan_speed=float(fan.get("speed") or 0.0),
        filament_sensors=filament_sensors,
        error=error,
        raw={
            "print_stats": print_stats,
            "toolhead": toolhead,
            "gcode_move": gcode_move,
            "virtual_sdcard": virtual_sdcard,
            "webhooks": webhooks,
        },
    )


def filament_sensor_states(status: Dict[str, Any]) -> Dict[str, FilamentSensorState]:
    """Every filament sensor this machine reported, by short name.

    Both Klipper sensor types publish the same two fields, so switch and motion
    sensors are read identically - but the *kind* is kept, because a switch can
    only tell you the filament is gone while a motion sensor can also tell you
    it has stopped moving. Reporting a switch as if it could catch a jam would
    be promising a safety net that is not there.
    """
    sensors: Dict[str, FilamentSensorState] = {}
    for key, value in status.items():
        if not isinstance(value, dict):
            continue
        if key.startswith("filament_switch_sensor "):
            kind = "switch"
        elif key.startswith("filament_motion_sensor "):
            kind = "motion"
        else:
            continue
        name = key.split(" ", 1)[1]
        sensors[name] = FilamentSensorState(
            name=name,
            kind=kind,
            enabled=bool(value.get("enabled", True)),
            filament_detected=bool(value.get("filament_detected", True)),
        )
    return sensors


async def fetch_status(client: MoonrakerClient) -> PrinterStatusResponse:
    """Fetch and normalise, never raising for connectivity problems."""
    try:
        server_info = await client.server_info()
    except MoonrakerError as exc:
        return PrinterStatusResponse(online=False, error=exc.message, klippy_state="unknown")

    if not server_info.get("klippy_connected", True):
        # Moonraker is up but Klipper is not; still report what we know.
        return PrinterStatusResponse(
            online=True,
            klippy_state=str(server_info.get("klippy_state") or "disconnected"),
            klippy_message=str(server_info.get("klippy_message") or "Klipper is not connected"),
            state="error",
            error=str(server_info.get("klippy_message") or "Klipper is not connected"),
        )

    try:
        status = await client.query_status()
    except MoonrakerError as exc:
        return build_status(server_info, {}, error=exc.message)

    return build_status(server_info, status)


def is_hot(status: PrinterStatusResponse, max_nozzle: float, max_bed: float) -> bool:
    return status.nozzle.actual >= max_nozzle or status.bed.actual >= max_bed


def is_printing(status: PrinterStatusResponse) -> bool:
    return status.state in {"printing", "paused"}
