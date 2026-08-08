import AppIntents
import Foundation

/// Shortcuts for the smart-ecosystem features.
///
/// Two rules are enforced here exactly as in the UI, because a voice command is
/// no reason to relax them:
/// * a queued job never starts unless the user has already confirmed the bed is
///   clear (the intent refuses and says why);
/// * the print monitor can pause a print but never switches mains power.

// MARK: - What is printing

struct WhatIsPrintingIntent: AppIntent {
    static var title: LocalizedStringResource = "What Is Printing"
    static var description = IntentDescription(
        "Says which model is printing, not just the G-code filename."
    )
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let backend = IntentBridge.makeBackend()
        let summary = try await backend.summary()

        guard summary.printer.snapshot.isActive else {
            return .result(dialog: "Nothing is printing right now.")
        }

        var text: String
        if let item = summary.item, !item.displayName.isEmpty {
            text = "Printing \(item.displayName)."
        } else if !summary.printer.snapshot.filename.isEmpty {
            text = "Printing \(summary.printer.snapshot.filename). It is not linked to a model in your library."
        } else {
            text = "A print is running."
        }
        text += " \(Int(summary.printer.snapshot.progress * 100)) percent done"
        if let remaining = summary.printer.snapshot.estimatedTimeLeft {
            text += ", about \(Format.duration(remaining)) remaining"
        }
        text += "."
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

// MARK: - Filament

struct FilamentRemainingIntent: AppIntent {
    static var title: LocalizedStringResource = "Filament Remaining"
    static var description = IntentDescription("Reports how much filament is left on the loaded spool.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let backend = IntentBridge.makeBackend()
        let summary = try await backend.filamentSummary()

        guard summary.spoolCount > 0 else {
            return .result(dialog: "No spools are set up yet.")
        }
        let spools = try await backend.spools()
        guard let active = spools.first(where: \.active) else {
            return .result(
                dialog: IntentDialog(
                    stringLiteral: "No spool is marked as loaded. \(Int(summary.totalRemainingGrams)) grams in total."
                )
            )
        }
        return .result(
            dialog: IntentDialog(
                stringLiteral: "\(Int(active.remainingGrams)) grams left on the \(active.displayName) spool."
            )
        )
    }
}

// MARK: - Queue

struct StartNextQueuedPrintIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Next Queued Print"
    static var description = IntentDescription(
        "Starts the next job in the queue. Refuses unless the bed has been confirmed clear."
    )
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let backend = IntentBridge.makeBackend()
        let queue = try await backend.queueState()

        guard queue.nextJob != nil else {
            return .result(dialog: "The print queue is empty.")
        }
        guard queue.bedClear else {
            throw IntentError.unsafe(
                "Confirm in the app that the bed is clear before starting the next print."
            )
        }
        let snapshot = try await IntentBridge.snapshot()
        guard !snapshot.isActive else {
            throw IntentError.unsafe("A print is already running.")
        }

        try await backend.startNextQueuedJob()
        IntentBridge.refreshWidget()
        let name = queue.nextJob?.displayName ?? ""
        return .result(
            dialog: IntentDialog(
                stringLiteral: name.isEmpty ? "Started the next queued print." : "Started \(name)."
            )
        )
    }
}

// MARK: - Print monitor

struct PrintMonitorStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Print Monitor Status"
    static var description = IntentDescription(
        "Reports whether the local print-failure monitor is watching, and what it has seen."
    )
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let backend = IntentBridge.makeBackend()
        let status = try await backend.visionStatus()

        guard status.available else {
            let reason = status.reason.isEmpty ? "it is not available on the Raspberry Pi" : status.reason
            return .result(dialog: IntentDialog(stringLiteral: "The print monitor is off: \(reason)."))
        }
        guard status.running else {
            return .result(dialog: "The print monitor is set up but not watching right now.")
        }

        let events = try await backend.visionEvents(confirmedOnly: true)
        let unseen = events.filter { !$0.acknowledged }
        if unseen.isEmpty {
            return .result(
                dialog: IntentDialog(
                    stringLiteral: "The monitor is watching and has not flagged anything. \(status.framesAnalysed) frames analysed."
                )
            )
        }
        return .result(
            dialog: IntentDialog(
                stringLiteral: "The monitor has flagged \(unseen.count) possible problem\(unseen.count == 1 ? "" : "s"). Open the app to look."
            )
        )
    }
}

// MARK: - Camera snapshot

struct PrinterSnapshotIntent: AppIntent {
    static var title: LocalizedStringResource = "Save Printer Snapshot"
    static var description = IntentDescription(
        "Saves one camera frame on the Raspberry Pi. Nothing is uploaded anywhere else."
    )
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let backend = IntentBridge.makeBackend()
        let status = try await backend.cameraStatus()
        guard status.available else {
            throw IntentError.unsafe("No camera is available on the Raspberry Pi.")
        }
        _ = try await backend.saveSnapshot()
        return .result(dialog: "Snapshot saved on the Raspberry Pi.")
    }
}

// MARK: - Shortcut phrases

struct EcosystemShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: WhatIsPrintingIntent(),
            phrases: [
                "What is printing in \(.applicationName)",
                "What is my printer making with \(.applicationName)"
            ],
            shortTitle: "What Is Printing",
            systemImageName: "cube"
        )
        AppShortcut(
            intent: FilamentRemainingIntent(),
            phrases: ["How much filament is left in \(.applicationName)"],
            shortTitle: "Filament Left",
            systemImageName: "circle.hexagongrid"
        )
        AppShortcut(
            intent: StartNextQueuedPrintIntent(),
            phrases: ["Start the next print in \(.applicationName)"],
            shortTitle: "Start Next Print",
            systemImageName: "list.number"
        )
        AppShortcut(
            intent: PrintMonitorStatusIntent(),
            phrases: ["Is my print okay in \(.applicationName)"],
            shortTitle: "Print Monitor",
            systemImageName: "eye"
        )
        AppShortcut(
            intent: PrinterSnapshotIntent(),
            phrases: ["Take a printer snapshot with \(.applicationName)"],
            shortTitle: "Save Snapshot",
            systemImageName: "camera"
        )
    }
}
