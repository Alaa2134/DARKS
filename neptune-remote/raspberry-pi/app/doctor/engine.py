"""The engine behind "Fix My Printer" and the Printer Health page.

It inspects everything it can reach - Moonraker, Klipper, the MCU, the live
config, endstops, the probe, heaters, fans, the filament sensor, saved
calibration - and turns each observation into a :class:`Finding` with a
severity, a likely cause, the affected subsystem, and a recommended fix.

Two rules run through the whole module:

* **Read-only.** Diagnosis never moves the printer. Anything that needs motion
  is offered as a separate, explicitly-started workflow that goes through the
  safety engine.
* **Unknown is not "fine".** When a check cannot be performed, it reports
  ``unknown`` and says why, rather than reporting a pass.
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Dict, List, Optional

from ..klipper.model import ParsedConfig
from ..klipper.validator import PrinterModelProfile, validate


class Subsystem(str, Enum):
    CONNECTION = "connection"
    MOONRAKER = "moonraker"
    KLIPPER = "klipper"
    MCU = "mcu"
    CONFIG = "config"
    X_AXIS = "x_axis"
    Y_AXIS = "y_axis"
    Z_AXIS = "z_axis"
    PROBE = "probe"
    BED = "bed"
    HOTEND = "hotend"
    PART_COOLING = "part_cooling"
    FILAMENT_SENSOR = "filament_sensor"
    BED_MESH = "bed_mesh"
    Z_OFFSET = "z_offset"
    MOTION_LIMITS = "motion_limits"
    ACCELEROMETER = "accelerometer"
    CAMERA = "camera"
    HOST = "host"
    STORAGE = "storage"


class Health(str, Enum):
    GREEN = "green"
    YELLOW = "yellow"
    RED = "red"
    UNKNOWN = "unknown"


class Severity(str, Enum):
    INFO = "info"
    WARNING = "warning"
    CRITICAL = "critical"


@dataclass
class Finding:
    """One thing that is wrong, or worth knowing."""

    code: str
    subsystem: Subsystem
    severity: Severity
    title: str
    cause: str = ""
    recommendation: str = ""
    #: Present when the app can fix this itself without hardware intervention.
    auto_fix: Optional[str] = None          # workflow id or command id
    auto_fix_label: str = ""
    #: Present when a human has to touch the machine.
    manual_steps: List[str] = field(default_factory=list)
    detail: str = ""

    def as_dict(self) -> Dict[str, Any]:
        return {
            "code": self.code,
            "subsystem": self.subsystem.value,
            "severity": self.severity.value,
            "title": self.title,
            "cause": self.cause,
            "recommendation": self.recommendation,
            "auto_fix": self.auto_fix,
            "auto_fix_label": self.auto_fix_label,
            "manual_steps": list(self.manual_steps),
            "detail": self.detail,
        }


@dataclass
class HealthCard:
    """One row on the Printer Health page."""

    subsystem: Subsystem
    health: Health
    status: str
    detail: str = ""
    recommendation: str = ""
    checked_at: float = field(default_factory=time.time)

    def as_dict(self) -> Dict[str, Any]:
        return {
            "subsystem": self.subsystem.value,
            "health": self.health.value,
            "status": self.status,
            "detail": self.detail,
            "recommendation": self.recommendation,
            "checked_at": self.checked_at,
        }


@dataclass
class HealthReport:
    generated_at: float = field(default_factory=time.time)
    findings: List[Finding] = field(default_factory=list)
    cards: List[HealthCard] = field(default_factory=list)
    #: True when nothing blocks a print.
    safe_to_print: bool = True

    @property
    def critical(self) -> List[Finding]:
        return [f for f in self.findings if f.severity is Severity.CRITICAL]

    @property
    def warnings(self) -> List[Finding]:
        return [f for f in self.findings if f.severity is Severity.WARNING]

    @property
    def overall(self) -> Health:
        if any(c.health is Health.RED for c in self.cards):
            return Health.RED
        if any(c.health is Health.YELLOW for c in self.cards):
            return Health.YELLOW
        if all(c.health is Health.UNKNOWN for c in self.cards) and self.cards:
            return Health.UNKNOWN
        return Health.GREEN

    @property
    def summary(self) -> str:
        if self.critical:
            return self.critical[0].title
        if self.warnings:
            count = len(self.warnings)
            return f"{count} thing{'s' if count > 1 else ''} to look at."
        if not self.cards:
            return "Nothing could be checked."
        return "Everything checks out."

    def as_dict(self) -> Dict[str, Any]:
        return {
            "generated_at": self.generated_at,
            "overall": self.overall.value,
            "summary": self.summary,
            "safe_to_print": self.safe_to_print,
            "critical_count": len(self.critical),
            "warning_count": len(self.warnings),
            "findings": [f.as_dict() for f in self.findings],
            "cards": [c.as_dict() for c in self.cards],
        }


@dataclass
class DiagnosticInput:
    """Everything the engine was able to read. Missing values stay ``None``,
    which is what makes "unknown" distinguishable from "fine"."""

    moonraker_reachable: Optional[bool] = None
    moonraker_version: str = ""
    klippy_state: str = "unknown"
    klippy_message: str = ""
    printing: bool = False
    paused: bool = False
    config: Optional[ParsedConfig] = None
    config_error: str = ""
    homed_axes: str = ""
    #: `{"x": "TRIGGERED"|"open", ...}` from QUERY_ENDSTOPS.
    endstops: Dict[str, str] = field(default_factory=dict)
    probe_triggered: Optional[bool] = None
    #: `{"extruder": {"temperature": 24.0, "target": 0.0, "power": 0.0}, ...}`
    heaters: Dict[str, Dict[str, float]] = field(default_factory=dict)
    fans: Dict[str, float] = field(default_factory=dict)
    filament_detected: Optional[bool] = None
    filament_sensor_enabled: Optional[bool] = None
    mcu_awake: Optional[bool] = None
    mcu_version: str = ""
    #: Klipper's own load estimate; above ~0.9 it starts missing deadlines.
    mcu_load: Optional[float] = None
    host_cpu_percent: Optional[float] = None
    host_temp_c: Optional[float] = None
    disk_free_gb: Optional[float] = None
    camera_available: Optional[bool] = None
    accelerometer_present: Optional[bool] = None
    #: Recent lines from klippy.log / moonraker.log.
    klipper_log_tail: List[str] = field(default_factory=list)
    moonraker_log_tail: List[str] = field(default_factory=list)
    #: sha256 of the live config, for comparison with the known-good version.
    config_sha: str = ""
    known_good_sha: str = ""
    known_good_label: str = ""


class DiagnosticsEngine:
    """Turns a :class:`DiagnosticInput` into findings and health cards."""

    def __init__(self, profile: Optional[PrinterModelProfile] = None) -> None:
        self.profile = profile

    # ------------------------------------------------------------------ api
    def run(self, data: DiagnosticInput) -> HealthReport:
        report = HealthReport()
        blocking = False

        blocking |= self._check_connection(data, report)
        # Without Moonraker there is nothing else to read, so stop cleanly
        # rather than emitting a wall of "unknown".
        if data.moonraker_reachable is False:
            report.safe_to_print = False
            return report

        blocking |= self._check_klipper(data, report)
        blocking |= self._check_mcu(data, report)
        blocking |= self._check_config(data, report)
        blocking |= self._check_axes(data, report)
        blocking |= self._check_probe(data, report)
        blocking |= self._check_calibration(data, report)
        self._check_heaters(data, report)
        self._check_fans(data, report)
        self._check_filament_sensor(data, report)
        self._check_accessories(data, report)
        self._check_host(data, report)
        self._check_logs(data, report)

        # Any critical finding blocks, wherever it came from - a check should
        # not have to remember to also return True. `blocking` additionally
        # covers states that are not critical but still cannot print, such as
        # Klipper still starting up.
        report.safe_to_print = not (blocking or report.critical)
        return report

    # ---------------------------------------------------------------- parts
    @staticmethod
    def _card(report: HealthReport, subsystem: Subsystem, health: Health, status: str, **kwargs: Any) -> None:
        report.cards.append(HealthCard(subsystem=subsystem, health=health, status=status, **kwargs))

    @staticmethod
    def _finding(report: HealthReport, **kwargs: Any) -> Finding:
        finding = Finding(**kwargs)
        report.findings.append(finding)
        return finding

    def _check_connection(self, data: DiagnosticInput, report: HealthReport) -> bool:
        if data.moonraker_reachable is None:
            self._card(report, Subsystem.MOONRAKER, Health.UNKNOWN, "Not checked")
            return False
        if not data.moonraker_reachable:
            self._card(
                report,
                Subsystem.MOONRAKER,
                Health.RED,
                "Unreachable",
                recommendation="Check the Raspberry Pi is on and Moonraker is running.",
            )
            self._finding(
                report,
                code="moonraker_unreachable",
                subsystem=Subsystem.MOONRAKER,
                severity=Severity.CRITICAL,
                title="Moonraker is not responding.",
                cause="The Raspberry Pi is off, Moonraker has stopped, or the network path is down.",
                recommendation="Check the Pi, then Moonraker's service status.",
                manual_steps=[
                    "Confirm the Raspberry Pi has power and is on the network.",
                    "On the Pi: systemctl status moonraker",
                    "If it is down: sudo systemctl restart moonraker",
                ],
            )
            return True
        self._card(
            report,
            Subsystem.MOONRAKER,
            Health.GREEN,
            "Connected",
            detail=data.moonraker_version,
        )
        return False

    def _check_klipper(self, data: DiagnosticInput, report: HealthReport) -> bool:
        state = (data.klippy_state or "unknown").lower()
        if state == "ready":
            self._card(report, Subsystem.KLIPPER, Health.GREEN, "Ready")
            return False

        if state == "startup":
            self._card(report, Subsystem.KLIPPER, Health.YELLOW, "Starting up")
            self._finding(
                report,
                code="klipper_starting",
                subsystem=Subsystem.KLIPPER,
                severity=Severity.WARNING,
                title="Klipper is still starting up.",
                recommendation="Wait a few seconds and check again.",
            )
            return True

        health = Health.RED if state in {"error", "shutdown"} else Health.UNKNOWN
        self._card(
            report,
            Subsystem.KLIPPER,
            health,
            state.capitalize(),
            detail=data.klippy_message[:400],
        )
        self._finding(
            report,
            code="klipper_not_ready",
            subsystem=Subsystem.KLIPPER,
            severity=Severity.CRITICAL,
            title=f"Klipper is in the '{state}' state.",
            cause=data.klippy_message.splitlines()[0] if data.klippy_message else "",
            detail=data.klippy_message[:1000],
            recommendation="Read the message, fix the cause, then restart the firmware.",
            auto_fix="firmware_restart",
            auto_fix_label="Restart firmware",
        )
        return True

    def _check_mcu(self, data: DiagnosticInput, report: HealthReport) -> bool:
        if data.mcu_awake is None:
            self._card(report, Subsystem.MCU, Health.UNKNOWN, "Not reported")
            return False
        if not data.mcu_awake:
            self._card(
                report,
                Subsystem.MCU,
                Health.RED,
                "Not communicating",
                recommendation="Check the USB cable between the Pi and the mainboard.",
            )
            self._finding(
                report,
                code="mcu_disconnected",
                subsystem=Subsystem.MCU,
                severity=Severity.CRITICAL,
                title="The mainboard is not communicating with Klipper.",
                cause="USB cable, mainboard power, or the wrong serial path in printer.cfg.",
                recommendation="Reseat the USB cable, then restart the firmware.",
                manual_steps=[
                    "Reseat the USB cable at both ends.",
                    "Confirm the printer's mainboard has power.",
                    "On the Pi: ls /dev/serial/by-id/ and compare with [mcu] serial in printer.cfg.",
                ],
            )
            return True

        detail = data.mcu_version
        if data.mcu_load is not None and data.mcu_load > 0.9:
            self._card(
                report,
                Subsystem.MCU,
                Health.YELLOW,
                "Overloaded",
                detail=f"Load {data.mcu_load:.2f}",
                recommendation="Reduce microstepping or acceleration.",
            )
            self._finding(
                report,
                code="mcu_load_high",
                subsystem=Subsystem.MCU,
                severity=Severity.WARNING,
                title=f"The mainboard is running at {data.mcu_load:.0%} load.",
                cause="Too many steps per second - usually very high microstepping or speed.",
                recommendation="Lower microstepping, speed or acceleration. Above 100 % Klipper shuts down mid-print.",
            )
        else:
            self._card(report, Subsystem.MCU, Health.GREEN, "Connected", detail=detail)
        return False

    def _check_config(self, data: DiagnosticInput, report: HealthReport) -> bool:
        if data.config is None:
            self._card(
                report,
                Subsystem.CONFIG,
                Health.UNKNOWN,
                "Not readable",
                detail=data.config_error,
                recommendation="The app could not read printer.cfg from Moonraker.",
            )
            self._finding(
                report,
                code="config_unreadable",
                subsystem=Subsystem.CONFIG,
                severity=Severity.WARNING,
                title="printer.cfg could not be read.",
                cause=data.config_error or "Moonraker did not return the file.",
                recommendation="Without it, travel limits and probe settings cannot be verified.",
            )
            return False

        result = validate(data.config, profile=self.profile)
        errors, warnings = result.errors, result.warnings

        if errors:
            self._card(
                report,
                Subsystem.CONFIG,
                Health.RED,
                f"{len(errors)} error(s)",
                detail=errors[0].message,
            )
        elif warnings:
            self._card(
                report,
                Subsystem.CONFIG,
                Health.YELLOW,
                f"{len(warnings)} warning(s)",
                detail=warnings[0].message,
            )
        else:
            self._card(report, Subsystem.CONFIG, Health.GREEN, "Valid")

        for item in errors + warnings:
            self._finding(
                report,
                code=item.code,
                subsystem=Subsystem.CONFIG,
                severity=Severity.CRITICAL if item.severity == "error" else Severity.WARNING,
                title=item.message,
                cause=item.detail,
                recommendation=item.remedy,
            )

        # Has the config drifted from the version that is known to work?
        if data.known_good_sha and data.config_sha and data.config_sha != data.known_good_sha:
            label = data.known_good_label or "the last known-good version"
            self._finding(
                report,
                code="config_changed",
                subsystem=Subsystem.CONFIG,
                severity=Severity.WARNING,
                title=f"printer.cfg has changed since {label}.",
                cause="A SAVE_CONFIG, a manual edit, or a calibration wrote new values.",
                recommendation="Compare the two versions, and roll back if the change was not intended.",
                auto_fix="config_diff",
                auto_fix_label="Show what changed",
            )

        return bool(errors)

    def _check_axes(self, data: DiagnosticInput, report: HealthReport) -> bool:
        homed = (data.homed_axes or "").lower()
        for axis, subsystem in (
            ("x", Subsystem.X_AXIS),
            ("y", Subsystem.Y_AXIS),
            ("z", Subsystem.Z_AXIS),
        ):
            endstop = data.endstops.get(axis, "").lower()
            is_homed = axis in homed

            if endstop == "triggered" and not is_homed:
                # Sitting on the endstop while unhomed is normal at rest, so
                # this is information, not an alarm.
                status, health = "At endstop", Health.GREEN
            elif endstop in {"open", "triggered"}:
                status, health = ("Homed" if is_homed else "Not homed"), (
                    Health.GREEN if is_homed else Health.YELLOW
                )
            elif is_homed:
                status, health = "Homed", Health.GREEN
            else:
                status, health = "Not homed", Health.YELLOW

            detail = ""
            if data.config is not None:
                limits = data.config.axis_limits(axis)
                if limits.is_known:
                    detail = f"{limits.position_min:g} to {limits.position_max:g} mm"
            self._card(report, subsystem, health, status, detail=detail)

        if data.klippy_state == "ready" and not all(a in homed for a in "xyz"):
            missing = [a.upper() for a in "xyz" if a not in homed]
            self._finding(
                report,
                code="not_homed",
                subsystem=Subsystem.MOTION_LIMITS,
                severity=Severity.INFO,
                title=f"{', '.join(missing)} {'is' if len(missing) == 1 else 'are'} not homed.",
                cause="Normal after a restart - Klipper does not know where the toolhead is.",
                recommendation="Home before moving or printing.",
                auto_fix="safe_home",
                auto_fix_label="Home safely",
            )
        return False

    def _check_probe(self, data: DiagnosticInput, report: HealthReport) -> bool:
        if data.config is not None and not data.config.has_probe:
            self._card(report, Subsystem.PROBE, Health.UNKNOWN, "Not configured")
            return False

        if data.probe_triggered is None:
            self._card(
                report,
                Subsystem.PROBE,
                Health.UNKNOWN,
                "Not read",
                recommendation="Run QUERY_PROBE to read the current state.",
            )
            return False

        if data.probe_triggered:
            self._card(
                report,
                Subsystem.PROBE,
                Health.RED,
                "Triggered at rest",
                recommendation="Do not home Z until this is resolved.",
            )
            self._finding(
                report,
                code="probe_triggered_at_rest",
                subsystem=Subsystem.PROBE,
                severity=Severity.CRITICAL,
                title="The Z probe is already triggered before any movement.",
                cause=(
                    "The probe is shorted, wired inverted, physically stuck down, or the "
                    "nozzle is already touching the bed."
                ),
                detail=(
                    "Homing Z in this state drives the nozzle into the bed: Klipper believes "
                    "it has reached the trigger point immediately."
                ),
                recommendation="Fix the probe before homing Z. The app blocks Z homing until you do.",
                manual_steps=[
                    "Check nothing is pressing on the probe.",
                    "Check the probe connector at both ends.",
                    "Raise Z manually if the nozzle is resting on the bed.",
                    "Re-run the probe check.",
                ],
            )
            return True

        self._card(report, Subsystem.PROBE, Health.GREEN, "Open")
        return False

    def _check_calibration(self, data: DiagnosticInput, report: HealthReport) -> bool:
        config = data.config
        if config is None:
            self._card(report, Subsystem.Z_OFFSET, Health.UNKNOWN, "Not readable")
            self._card(report, Subsystem.BED_MESH, Health.UNKNOWN, "Not readable")
            return False

        # -- Z offset -------------------------------------------------------
        if not config.has_probe:
            self._card(report, Subsystem.Z_OFFSET, Health.UNKNOWN, "No probe")
        else:
            offset = config.effective_probe_z_offset
            saved = config.saved_probe_z_offset is not None
            if offset is None:
                self._card(
                    report,
                    Subsystem.Z_OFFSET,
                    Health.RED,
                    "Not calibrated",
                    recommendation="Run the Z Offset wizard.",
                )
                self._finding(
                    report,
                    code="z_offset_missing",
                    subsystem=Subsystem.Z_OFFSET,
                    severity=Severity.CRITICAL,
                    title="The Z offset has never been calibrated.",
                    cause="No z_offset is set for the probe.",
                    recommendation="Run the Z Offset wizard before printing.",
                    auto_fix="z_offset_wizard",
                    auto_fix_label="Calibrate Z offset",
                )
                return True
            self._card(
                report,
                Subsystem.Z_OFFSET,
                Health.GREEN if saved else Health.YELLOW,
                f"{offset:.3f} mm",
                detail="Saved by SAVE_CONFIG" if saved else "From the config file, never calibrated in place",
            )
            if not saved:
                self._finding(
                    report,
                    code="z_offset_not_saved",
                    subsystem=Subsystem.Z_OFFSET,
                    severity=Severity.WARNING,
                    title="The Z offset has not been calibrated on this machine.",
                    cause="The value comes from the config file rather than from PROBE_CALIBRATE.",
                    recommendation="Run the Z Offset wizard so the value matches this nozzle and bed.",
                    auto_fix="z_offset_wizard",
                    auto_fix_label="Calibrate Z offset",
                )

        # -- bed mesh -------------------------------------------------------
        if not config.has_bed_mesh:
            self._card(report, Subsystem.BED_MESH, Health.UNKNOWN, "Not configured")
        elif config.has_saved_mesh:
            profiles = config.saved_mesh_profiles
            self._card(
                report,
                Subsystem.BED_MESH,
                Health.GREEN,
                f"{len(profiles)} saved",
                detail=", ".join(profiles[:4]),
            )
        else:
            self._card(
                report,
                Subsystem.BED_MESH,
                Health.YELLOW,
                "No saved mesh",
                recommendation="Run a bed mesh and SAVE_CONFIG.",
            )
            self._finding(
                report,
                code="bed_mesh_missing",
                subsystem=Subsystem.BED_MESH,
                severity=Severity.WARNING,
                title="There is no saved bed mesh.",
                cause="BED_MESH_CALIBRATE has not been run, or the result was never saved.",
                recommendation="Run a bed mesh - first layers on a 320 mm bed depend on it.",
                auto_fix="bed_mesh_wizard",
                auto_fix_label="Run a bed mesh",
            )

        # -- motion limits --------------------------------------------------
        accel, velocity = config.max_accel, config.max_velocity
        if accel is None or velocity is None:
            self._card(report, Subsystem.MOTION_LIMITS, Health.YELLOW, "Incomplete")
        else:
            recommended = self.profile.recommended_max_accel if self.profile else None
            over = recommended is not None and accel > recommended
            self._card(
                report,
                Subsystem.MOTION_LIMITS,
                Health.YELLOW if over else Health.GREEN,
                f"{velocity:g} mm/s, {accel:g} mm/s²",
                recommendation=(
                    "Consider lowering acceleration if you see layer shifts." if over else ""
                ),
            )
        return False

    def _check_heaters(self, data: DiagnosticInput, report: HealthReport) -> None:
        for key, subsystem, label in (
            ("extruder", Subsystem.HOTEND, "Hotend"),
            ("heater_bed", Subsystem.BED, "Bed"),
        ):
            values = data.heaters.get(key)
            if not values:
                self._card(report, subsystem, Health.UNKNOWN, "Not reported")
                continue

            temperature = values.get("temperature")
            target = values.get("target", 0.0)
            if temperature is None:
                self._card(report, subsystem, Health.UNKNOWN, "No reading")
                continue

            # A thermistor reading near absolute zero or wildly high is the
            # classic signature of a disconnected or shorted sensor.
            if temperature < -10 or temperature > 500:
                self._card(
                    report,
                    subsystem,
                    Health.RED,
                    f"Implausible reading ({temperature:.0f} °C)",
                    recommendation="Check the thermistor wiring.",
                )
                self._finding(
                    report,
                    code="thermistor_implausible",
                    subsystem=subsystem,
                    severity=Severity.CRITICAL,
                    title=f"The {label.lower()} thermistor is reading {temperature:.0f} °C.",
                    cause="A disconnected or shorted thermistor reads at the extremes of its range.",
                    recommendation="Check the thermistor connector before heating anything.",
                    manual_steps=[
                        f"Power off the printer and inspect the {label.lower()} thermistor wiring.",
                        "Look for a pinched or broken wire near the moving parts.",
                    ],
                )
                continue

            status = f"{temperature:.1f} °C"
            if target > 0:
                status += f" → {target:.0f} °C"
            self._card(report, subsystem, Health.GREEN, status)

    def _check_fans(self, data: DiagnosticInput, report: HealthReport) -> None:
        if not data.fans:
            self._card(report, Subsystem.PART_COOLING, Health.UNKNOWN, "Not reported")
            return
        speed = data.fans.get("fan", data.fans.get("part_cooling", 0.0))
        self._card(
            report,
            Subsystem.PART_COOLING,
            Health.GREEN,
            f"{speed * 100:.0f}%" if speed else "Off",
            detail=", ".join(sorted(data.fans)),
        )

    def _check_filament_sensor(self, data: DiagnosticInput, report: HealthReport) -> None:
        if data.config is not None and not data.config.has_filament_sensor:
            self._card(report, Subsystem.FILAMENT_SENSOR, Health.UNKNOWN, "Not configured")
            return
        if data.filament_detected is None:
            self._card(report, Subsystem.FILAMENT_SENSOR, Health.UNKNOWN, "Not reported")
            return
        if data.filament_sensor_enabled is False:
            self._card(
                report,
                Subsystem.FILAMENT_SENSOR,
                Health.YELLOW,
                "Disabled",
                recommendation="Runouts will not be detected while it is off.",
            )
            return
        self._card(
            report,
            Subsystem.FILAMENT_SENSOR,
            Health.GREEN if data.filament_detected else Health.YELLOW,
            "Filament present" if data.filament_detected else "No filament",
        )

    def _check_accessories(self, data: DiagnosticInput, report: HealthReport) -> None:
        configured = data.config.has_accelerometer if data.config is not None else None
        if configured is False:
            self._card(report, Subsystem.ACCELEROMETER, Health.UNKNOWN, "Not installed")
        elif data.accelerometer_present is None:
            self._card(report, Subsystem.ACCELEROMETER, Health.UNKNOWN, "Configured, not verified")
        elif data.accelerometer_present:
            self._card(report, Subsystem.ACCELEROMETER, Health.GREEN, "Responding")
        else:
            self._card(
                report,
                Subsystem.ACCELEROMETER,
                Health.RED,
                "Configured but not responding",
                recommendation="Check the SPI wiring.",
            )
            self._finding(
                report,
                code="accelerometer_not_responding",
                subsystem=Subsystem.ACCELEROMETER,
                severity=Severity.WARNING,
                title="An accelerometer is configured but does not respond.",
                cause="SPI wiring, the wrong cs_pin, or SPI not enabled on the Pi.",
                recommendation="Resonance testing is unavailable until this is fixed.",
                manual_steps=[
                    "Check the six SPI wires between the Pi and the ADXL345.",
                    "On the Pi: ls /dev/spidev* - if empty, enable SPI with raspi-config.",
                    "Run ACCELEROMETER_QUERY to test.",
                ],
            )

        if data.camera_available is None:
            self._card(report, Subsystem.CAMERA, Health.UNKNOWN, "Not checked")
        elif data.camera_available:
            self._card(report, Subsystem.CAMERA, Health.GREEN, "Available")
        else:
            self._card(report, Subsystem.CAMERA, Health.YELLOW, "Not available")

    def _check_host(self, data: DiagnosticInput, report: HealthReport) -> None:
        if data.host_cpu_percent is None and data.host_temp_c is None:
            self._card(report, Subsystem.HOST, Health.UNKNOWN, "Not reported")
        else:
            parts = []
            health = Health.GREEN
            if data.host_cpu_percent is not None:
                parts.append(f"CPU {data.host_cpu_percent:.0f}%")
                if data.host_cpu_percent > 85:
                    health = Health.YELLOW
            if data.host_temp_c is not None:
                parts.append(f"{data.host_temp_c:.0f} °C")
                if data.host_temp_c > 80:
                    health = Health.YELLOW
            self._card(report, Subsystem.HOST, health, ", ".join(parts))

        if data.disk_free_gb is None:
            self._card(report, Subsystem.STORAGE, Health.UNKNOWN, "Not reported")
        elif data.disk_free_gb < 1.0:
            self._card(
                report,
                Subsystem.STORAGE,
                Health.RED,
                f"{data.disk_free_gb:.1f} GB free",
                recommendation="Klipper and Moonraker misbehave when the card fills up.",
            )
            self._finding(
                report,
                code="disk_almost_full",
                subsystem=Subsystem.STORAGE,
                severity=Severity.CRITICAL,
                title=f"Only {data.disk_free_gb:.1f} GB of disk space is left.",
                cause="G-code files, logs, timelapse frames and videos accumulate.",
                recommendation="Delete old G-code and videos before printing again.",
            )
        else:
            self._card(
                report,
                Subsystem.STORAGE,
                Health.YELLOW if data.disk_free_gb < 3 else Health.GREEN,
                f"{data.disk_free_gb:.1f} GB free",
            )

    def _check_logs(self, data: DiagnosticInput, report: HealthReport) -> None:
        """Surface the log lines that actually mean something."""
        from ..knowledge import translate_error

        patterns = (
            ("shutdown", Severity.CRITICAL),
            ("mcu 'mcu': timer too close", Severity.CRITICAL),
            ("lost communication with mcu", Severity.CRITICAL),
            ("move out of range", Severity.WARNING),
            ("probe triggered prior to movement", Severity.CRITICAL),
            ("must home", Severity.WARNING),
            ("adc out of range", Severity.CRITICAL),
            ("heating failed", Severity.CRITICAL),
            ("thermal runaway", Severity.CRITICAL),
            ("unable to obtain", Severity.WARNING),
        )

        seen: set[str] = set()
        for line in reversed(data.klipper_log_tail[-200:]):
            lowered = line.lower()
            for needle, severity in patterns:
                if needle not in lowered or needle in seen:
                    continue
                seen.add(needle)
                translated = translate_error(line)
                self._finding(
                    report,
                    code=f"log_{needle.replace(' ', '_').replace(chr(39), '')}",
                    subsystem=Subsystem.KLIPPER,
                    severity=severity,
                    title=translated.title_en or line.strip()[:120],
                    cause=translated.explanation_en,
                    detail=line.strip()[:500],
                    recommendation=(
                        translated.checks_ar[0] if translated.checks_ar else "Check the Klipper log."
                    ),
                )
                break
