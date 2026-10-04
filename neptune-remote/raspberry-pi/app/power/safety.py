"""Safety checks performed before cutting mains power to the printer."""

from __future__ import annotations

from ..config import PowerSafetyConfig
from ..schemas import PowerSafetyReport, PrinterStatusResponse


def evaluate_power_off(
    status: PrinterStatusResponse,
    safety: PowerSafetyConfig,
) -> PowerSafetyReport:
    """Decide whether it is safe to cut mains power right now.

    Blockers stop the action unless the caller explicitly forces it.
    Warnings are informational and never block.
    """
    blockers: list[str] = []
    warnings: list[str] = []

    printing = status.state in {"printing", "paused"}

    if not safety.enabled:
        return PowerSafetyReport(
            safe=True,
            blockers=[],
            warnings=["Safety checks are disabled in config.yaml"],
            nozzle_temp=status.nozzle.actual,
            bed_temp=status.bed.actual,
            max_nozzle_temp=safety.max_nozzle_temp,
            max_bed_temp=safety.max_bed_temp,
            printing=printing,
        )

    if not status.online:
        warnings.append(
            "Printer status is unknown (Moonraker unreachable); temperatures could not be verified"
        )

    if printing and safety.block_while_printing:
        blockers.append(
            "A print is currently in progress ({}) - cutting power will ruin the print".format(
                status.state
            )
        )

    if status.online:
        if status.nozzle.actual >= safety.max_nozzle_temp:
            blockers.append(
                "Nozzle is {:.0f}C, above the safe shutdown limit of {:.0f}C".format(
                    status.nozzle.actual, safety.max_nozzle_temp
                )
            )
        if status.bed.actual >= safety.max_bed_temp:
            blockers.append(
                "Bed is {:.0f}C, above the safe shutdown limit of {:.0f}C".format(
                    status.bed.actual, safety.max_bed_temp
                )
            )
        if status.nozzle.target > 0 or status.bed.target > 0:
            warnings.append("Heaters still have an active target temperature")

    return PowerSafetyReport(
        safe=not blockers,
        blockers=blockers,
        warnings=warnings,
        nozzle_temp=status.nozzle.actual,
        bed_temp=status.bed.actual,
        max_nozzle_temp=safety.max_nozzle_temp,
        max_bed_temp=safety.max_bed_temp,
        printing=printing,
    )
