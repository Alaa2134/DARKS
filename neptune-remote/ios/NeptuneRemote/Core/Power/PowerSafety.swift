import Foundation

/// Client-side mirror of the backend's power-off safety rules.
///
/// The backend enforces the same checks again, so a malicious or stale client
/// can never bypass them. Doing it here too means the user gets an immediate,
/// localised explanation before anything is sent.
struct PowerSafetyReport: Equatable {
    var isSafe: Bool
    var blockers: [String]
    var warnings: [String]
    var nozzleTemp: Double
    var bedTemp: Double
    var maxNozzleTemp: Double
    var maxBedTemp: Double
    var isPrinting: Bool

    static let safe = PowerSafetyReport(
        isSafe: true, blockers: [], warnings: [],
        nozzleTemp: 0, bedTemp: 0, maxNozzleTemp: 50, maxBedTemp: 45, isPrinting: false
    )
}

enum PowerSafety {

    struct Thresholds: Equatable {
        var maxNozzleTemp: Double
        var maxBedTemp: Double
        var blockWhilePrinting: Bool

        init(maxNozzleTemp: Double = 50, maxBedTemp: Double = 45, blockWhilePrinting: Bool = true) {
            self.maxNozzleTemp = maxNozzleTemp
            self.maxBedTemp = maxBedTemp
            self.blockWhilePrinting = blockWhilePrinting
        }
    }

    static func evaluatePowerOff(
        snapshot: PrinterSnapshot,
        thresholds: Thresholds
    ) -> PowerSafetyReport {
        var blockers: [String] = []
        var warnings: [String] = []

        if !snapshot.isOnline {
            warnings.append(L.t("power.warning.status_unknown"))
        }

        if snapshot.state.isActive, thresholds.blockWhilePrinting {
            blockers.append(L.t("power.blocker.printing"))
        }

        if snapshot.isOnline {
            if snapshot.nozzleActual >= thresholds.maxNozzleTemp {
                blockers.append(
                    L.t("power.blocker.nozzle_hot", snapshot.nozzleActual, thresholds.maxNozzleTemp)
                )
            }
            if snapshot.bedActual >= thresholds.maxBedTemp {
                blockers.append(
                    L.t("power.blocker.bed_hot", snapshot.bedActual, thresholds.maxBedTemp)
                )
            }
            if snapshot.nozzleTarget > 0 || snapshot.bedTarget > 0 {
                warnings.append(L.t("power.warning.heaters_on"))
            }
        }

        return PowerSafetyReport(
            isSafe: blockers.isEmpty,
            blockers: blockers,
            warnings: warnings,
            nozzleTemp: snapshot.nozzleActual,
            bedTemp: snapshot.bedActual,
            maxNozzleTemp: thresholds.maxNozzleTemp,
            maxBedTemp: thresholds.maxBedTemp,
            isPrinting: snapshot.state.isActive
        )
    }

    /// Checklist shown before starting a remote print.
    static let printChecklistKeys = [
        "checklist.bed_clear",
        "checklist.filament_loaded",
        "checklist.no_obstruction",
        "checklist.camera_checked"
    ]
}
