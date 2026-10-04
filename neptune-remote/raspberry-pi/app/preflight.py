"""Pre-print safety check.

Combines the printer's health, the live config and the G-code analysis into one
verdict: READY, WARNING, or BLOCKED. Strict Safety Mode turns warnings into
blocks for people who would rather the app be pedantic than sorry.
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

from .doctor.engine import HealthReport, Severity
from .gcode.validator import GCodeReport, GCodeVerdict


@dataclass
class PreflightCheck:
    id: str
    label: str
    passed: bool
    severity: str          # info | warning | error
    detail: str = ""
    remedy: str = ""

    def as_dict(self) -> Dict[str, Any]:
        return {
            "id": self.id,
            "label": self.label,
            "passed": self.passed,
            "severity": self.severity,
            "detail": self.detail,
            "remedy": self.remedy,
        }


@dataclass
class PreflightReport:
    generated_at: float = field(default_factory=time.time)
    checks: List[PreflightCheck] = field(default_factory=list)
    strict: bool = False
    gcode: Optional[Dict[str, Any]] = None
    #: The summary block shown before a print starts.
    banner: Dict[str, str] = field(default_factory=dict)

    @property
    def failures(self) -> List[PreflightCheck]:
        return [c for c in self.checks if not c.passed and c.severity == "error"]

    @property
    def warnings(self) -> List[PreflightCheck]:
        return [c for c in self.checks if not c.passed and c.severity == "warning"]

    @property
    def verdict(self) -> str:
        if self.failures:
            return "blocked"
        if self.warnings:
            return "blocked" if self.strict else "warning"
        return "ready"

    @property
    def ready(self) -> bool:
        return self.verdict == "ready"

    @property
    def summary(self) -> str:
        if self.failures:
            return self.failures[0].detail or self.failures[0].label
        if self.warnings:
            count = len(self.warnings)
            return f"{count} warning{'s' if count > 1 else ''} - review before printing."
        return "Ready to print."

    def as_dict(self) -> Dict[str, Any]:
        return {
            "generated_at": self.generated_at,
            "verdict": self.verdict,
            "ready": self.ready,
            "strict": self.strict,
            "summary": self.summary,
            "failure_count": len(self.failures),
            "warning_count": len(self.warnings),
            "checks": [c.as_dict() for c in self.checks],
            "gcode": self.gcode,
            "banner": self.banner,
        }


def run_preflight(
    *,
    health: Optional[HealthReport],
    gcode: Optional[GCodeReport],
    strict: bool = False,
    filament_ok: Optional[bool] = None,
    filament_message: str = "",
) -> PreflightReport:
    """Build the pre-print report. Anything unknown is reported as unknown."""
    report = PreflightReport(strict=strict)

    def add(check_id: str, label: str, passed: bool, severity: str, **kwargs: Any) -> None:
        report.checks.append(
            PreflightCheck(id=check_id, label=label, passed=passed, severity=severity, **kwargs)
        )

    # ------------------------------------------------------------- printer
    if health is None:
        add(
            "printer_health", "Printer health", False, "warning",
            detail="The printer could not be checked.",
            remedy="Open Fix My Printer.",
        )
    else:
        for finding in health.findings:
            if finding.severity is Severity.CRITICAL:
                add(
                    f"health_{finding.code}", finding.title, False, "error",
                    detail=finding.cause or finding.title,
                    remedy=finding.recommendation,
                )
            elif finding.severity is Severity.WARNING:
                add(
                    f"health_{finding.code}", finding.title, False, "warning",
                    detail=finding.cause or finding.title,
                    remedy=finding.recommendation,
                )
        if health.safe_to_print and not health.warnings:
            add("printer_health", "Printer health", True, "info", detail="All checks green.")

    # --------------------------------------------------------------- gcode
    if gcode is None:
        add(
            "gcode_validation", "G-code validation", False, "error",
            detail="The file was not analysed.",
            remedy="Select a G-code file first.",
        )
    else:
        report.gcode = gcode.as_dict()
        for issue in gcode.issues:
            if issue.severity == "error":
                add(
                    f"gcode_{issue.code}", issue.message, False, "error",
                    detail=issue.detail, remedy=issue.remedy,
                )
            elif issue.severity == "warning":
                add(
                    f"gcode_{issue.code}", issue.message, False, "warning",
                    detail=issue.detail, remedy=issue.remedy,
                )
        if gcode.verdict is GCodeVerdict.SAFE:
            add("gcode_validation", "G-code validation", True, "info", detail="Passed.")

    # ------------------------------------------------------------ filament
    if filament_ok is False:
        add(
            "filament", "Filament", False, "warning",
            detail=filament_message or "There may not be enough filament for this print.",
            remedy="Check the spool, or load a new one.",
        )
    elif filament_ok is True:
        add("filament", "Filament", True, "info", detail=filament_message)

    # -------------------------------------------------------------- banner
    if gcode is not None:
        bounds = gcode.bounds
        volume = (
            "PASSED"
            if not any(i.code == "outside_build_volume" for i in gcode.errors)
            else "FAILED"
        )
        motion = (
            "PASSED"
            if not any(i.code.startswith(("accel_above", "feedrate_above")) for i in gcode.issues)
            else "WARNING"
        )
        report.banner = {
            "slicer": gcode.slicer or "Unknown",
            "printer_profile": gcode.profile_name or "Unknown",
            "profile_status": gcode.profile_status.upper(),
            "gcode_validation": gcode.verdict.value.upper(),
            "build_volume": volume,
            "unsupported_commands": (
                "NONE" if not gcode.unsupported
                else ", ".join(u["command"] for u in gcode.unsupported)
            ),
            "motion_limits": motion,
            "bounds": (
                f"X {bounds.min_x:.1f}..{bounds.max_x:.1f}  "
                f"Y {bounds.min_y:.1f}..{bounds.max_y:.1f}  "
                f"Z {bounds.min_z:.1f}..{bounds.max_z:.1f}"
                if bounds.max_x is not None and bounds.max_y is not None and bounds.max_z is not None
                else "unknown"
            ),
        }

    return report
