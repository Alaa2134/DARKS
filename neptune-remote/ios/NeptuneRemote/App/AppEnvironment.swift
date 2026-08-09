import Foundation
import SwiftUI

/// Builds and owns every store, and wires the cross-store event routing.
@MainActor
final class AppEnvironment: ObservableObject {
    let settings: AppSettings
    let notifications: NotificationManager
    let printer: PrinterStore
    let files: FilesStore
    let slicing: SliceStore
    let history: HistoryStore
    let system: SystemStore
    let library: LibraryStore
    let media: MediaStore
    let inventory: InventoryStore
    let support: SupportStore
    let doctor: DoctorStore
    let alerts: AlertStore
    let calibration: CalibrationStore
    let liveActivity: LiveActivityController

    /// Vision events already turned into a notification, so a repeated summary
    /// frame does not re-alert for the same detection.
    private var announcedVisionEvents = Set<String>()
    private var announcedMaintenance = false
    private var announcedFilamentLow = false
    private var lastAnomalyRefresh = Date.distantPast

    init() {
        let settings = AppSettings()
        let notifications = NotificationManager()
        let printer = PrinterStore(settings: settings, notifications: notifications)

        self.settings = settings
        self.notifications = notifications
        self.printer = printer
        files = FilesStore(settings: settings, printer: printer)
        slicing = SliceStore(settings: settings, printer: printer)
        history = HistoryStore(settings: settings, printer: printer)
        system = SystemStore(settings: settings, printer: printer)
        library = LibraryStore(settings: settings, printer: printer)
        media = MediaStore(settings: settings, printer: printer)
        inventory = InventoryStore(settings: settings, printer: printer)
        support = SupportStore(settings: settings, printer: printer)
        doctor = DoctorStore(settings: settings, printer: printer)
        alerts = AlertStore(settings: settings, printer: printer)
        calibration = CalibrationStore(settings: settings, printer: printer)
        liveActivity = LiveActivityController()

        printer.onSliceProgress = { [weak self] progress in
            self?.slicing.apply(progressEvent: progress)
        }
        printer.onSystemUpdate = { [weak self] info in
            self?.system.apply(info)
        }
        printer.onSummary = { [weak self] summary in
            self?.apply(summary)
        }
    }

    // MARK: - Summary fan-out

    /// One backend frame feeds every screen, so Home never has to poll four
    /// endpoints to draw itself.
    private func apply(_ summary: BackendSummary) {
        media.apply(summary)
        inventory.apply(summary)
        announce(summary)
        syncLiveActivity(summary)
        refreshAnomalies()
    }

    /// Telemetry findings, refreshed while a print is running.
    ///
    /// Throttled to once a minute rather than following the summary frame: the
    /// checks behind it need tens of layers before they say anything, so
    /// polling on every frame would be a request per second for a value that
    /// cannot have changed.
    private func refreshAnomalies() {
        guard printer.snapshot.isActive else { return }
        let now = Date()
        guard now.timeIntervalSince(lastAnomalyRefresh) > 60 else { return }
        lastAnomalyRefresh = now
        Task { await calibration.refreshAnomalies() }
    }

    /// Keeps the lock screen / Dynamic Island in step with the print. The
    /// controller starts and ends the activity itself based on printer state.
    private func syncLiveActivity(_ summary: BackendSummary) {
        guard settings.notificationsEnabled else { return }
        liveActivity.sync(
            snapshot: printer.snapshot,
            item: summary.item,
            thumbnailURL: library.mediaURL(summary.item?.thumbnail),
            printerName: settings.printerName,
            warningKey: media.unacknowledgedVisionEvents.first?.localizationKey
        )
    }

    private func announce(_ summary: BackendSummary) {
        // Maintenance and filament are edge-triggered: alert on the transition,
        // then stay quiet until the condition clears.
        if summary.maintenanceDue > 0 {
            if !announcedMaintenance {
                announcedMaintenance = true
                notifications.post(
                    event: .maintenanceDue,
                    body: L.t("notification.maintenance_due.body", summary.maintenanceDue),
                    identifier: "maintenance-\(summary.maintenanceDue)",
                    settings: settings
                )
            }
        } else {
            announcedMaintenance = false
        }

        let remaining = summary.filament.totalRemainingGrams
        if summary.filament.spoolCount > 0, remaining < 100 {
            if !announcedFilamentLow {
                announcedFilamentLow = true
                notifications.post(
                    event: .filamentLow,
                    body: L.t("notification.filament_low.body", Int(remaining.rounded())),
                    settings: settings
                )
            }
        } else {
            announcedFilamentLow = false
        }
    }

    /// Confirmed detections arrive through MediaStore's event list; announce the
    /// ones the user has not seen yet. The monitor itself only ever pauses a
    /// print - it never touches mains power.
    func announceVisionEvents() {
        for event in media.unacknowledgedVisionEvents where !announcedVisionEvents.contains(event.id) {
            announcedVisionEvents.insert(event.id)
            let action = event.action == "paused"
                ? L.t("vision.action.paused")
                : L.t("vision.action.warned")
            notifications.post(
                event: .visionAlert,
                body: "\(L.t(event.localizationKey)) · \(action)",
                identifier: "vision-\(event.id)",
                settings: settings
            )
        }
        if announcedVisionEvents.count > 200 { announcedVisionEvents.removeAll() }
    }

    // MARK: - Lifecycle

    func start() {
        printer.start()
        liveActivity.reattach()
        Task {
            await notifications.refreshAuthorizationStatus()
            if settings.notificationsEnabled, notifications.authorizationStatus == .notDetermined {
                await notifications.requestAuthorization()
            }
        }
        Task { await refreshEcosystem() }
        // Loaded at launch rather than when the settings screen opens: the
        // outage card has to be able to appear on Home, and "was I even
        // reachable while I was out" is not a question you go looking for.
        Task { await alerts.load() }
    }

    /// Pulls the library / media / inventory state the summary frame does not
    /// carry (lists rather than counters).
    func refreshEcosystem() async {
        // Anything the Share Extension staged is uploaded first, so a model the
        // user just shared is already there when the library appears.
        await library.importPendingShares()
        await library.load()
        await media.load()
        await inventory.load()
        await media.loadVisionEvents()
        announceVisionEvents()
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            printer.resume()
            Task {
                await library.importPendingShares()
                await printer.refreshSummary()
                await media.loadVisionEvents()
                announceVisionEvents()
                // Coming back to the app is exactly when a power cut that
                // happened while it was closed needs to surface.
                await alerts.refreshOutage()
            }
        case .background:
            // Keep the widget snapshot fresh, then let the sockets idle out.
            printer.stop()
        default:
            break
        }
    }
}
