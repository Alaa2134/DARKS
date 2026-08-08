import AppIntents
import Foundation
import SwiftUI

/// Shortcuts / Siri support.
///
/// Intents run outside the app process, so they build their own clients from the
/// shared App Group configuration and the Keychain. Safety rules are enforced
/// here exactly as they are in the UI: a power-off never bypasses the hot/printing
/// checks unless the user explicitly asks for the forced variant.
enum IntentBridge {

    static func makeBackend() -> BackendClient {
        BackendClient(config: SharedStore.loadConnection(), token: Keychain.get(.backendToken) ?? "")
    }

    static func makeMoonraker() -> MoonrakerClient {
        MoonrakerClient(config: SharedStore.loadConnection(), apiKey: Keychain.get(.moonrakerAPIKey) ?? "")
    }

    static func snapshot() async throws -> PrinterSnapshot {
        try await makeMoonraker().snapshot()
    }

    static func refreshWidget() {
        #if canImport(WidgetKit)
        WidgetCenterBridge.reload()
        #endif
    }
}

#if canImport(WidgetKit)
import WidgetKit

enum WidgetCenterBridge {
    static func reload() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}
#endif

// MARK: - Power on

struct PowerPrinterOnIntent: AppIntent {
    static var title: LocalizedStringResource = "Power Printer On"
    static var description = IntentDescription(
        "Switches the smart plug that feeds the Neptune 3 Plus on."
    )
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let backend = IntentBridge.makeBackend()
        let result = try await backend.powerOn()
        IntentBridge.refreshWidget()
        return .result(dialog: IntentDialog(stringLiteral: result.message.isEmpty
            ? "Printer powered on."
            : result.message))
    }
}

// MARK: - Power off (safe)

struct PowerPrinterOffIntent: AppIntent {
    static var title: LocalizedStringResource = "Power Printer Off"
    static var description = IntentDescription(
        "Switches the printer's smart plug off. Refuses while a print is running or while the nozzle or bed are still hot."
    )
    static var openAppWhenRun: Bool = false

    @Parameter(
        title: "Force",
        description: "Ignore the hot-printer safety checks. Only use if you know the printer is safe.",
        default: false
    )
    var force: Bool

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let backend = IntentBridge.makeBackend()

        if !force {
            // Ask the backend first: it owns the authoritative safety report.
            if let safety = try? await backend.powerSafety(), !safety.safe {
                throw IntentError.unsafe(safety.blockers.joined(separator: " "))
            }
        }

        do {
            let result = try await backend.powerOff(force: force)
            IntentBridge.refreshWidget()
            return .result(dialog: IntentDialog(stringLiteral: result.message.isEmpty
                ? "Printer powered off."
                : result.message))
        } catch let error as APIError {
            if case .unsafeOperation(let blockers) = error {
                throw IntentError.unsafe(blockers.joined(separator: " "))
            }
            throw error
        }
    }
}

// MARK: - Print control

struct PausePrintIntent: AppIntent {
    static var title: LocalizedStringResource = "Pause Print"
    static var description = IntentDescription("Pauses the running print.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await IntentBridge.makeMoonraker().pausePrint()
        IntentBridge.refreshWidget()
        return .result(dialog: "Print paused.")
    }
}

struct ResumePrintIntent: AppIntent {
    static var title: LocalizedStringResource = "Resume Print"
    static var description = IntentDescription("Resumes a paused print.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await IntentBridge.makeMoonraker().resumePrint()
        IntentBridge.refreshWidget()
        return .result(dialog: "Print resumed.")
    }
}

struct PrinterStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Printer Status"
    static var description = IntentDescription("Reports the printer state, progress and temperatures.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let snapshot = try await IntentBridge.snapshot()
        guard snapshot.isOnline else {
            return .result(dialog: "The printer is not reachable.")
        }
        var text = "Printer is \(snapshot.state.rawValue)."
        if snapshot.isActive {
            text += " \(Int(snapshot.progress * 100)) percent done"
            if let remaining = snapshot.estimatedTimeLeft {
                text += ", about \(Format.duration(remaining)) remaining"
            }
            text += "."
        }
        text += " Nozzle \(Int(snapshot.nozzleActual)) degrees, bed \(Int(snapshot.bedActual)) degrees."
        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

struct OpenPrinterIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Printer"
    static var description = IntentDescription("Opens the Neptune 3 Plus Remote dashboard.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        .result()
    }
}

// MARK: - Errors

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case unsafe(String)
    case notConfigured

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .unsafe(let reason):
            return LocalizedStringResource(stringLiteral: "Refused for safety: \(reason)")
        case .notConfigured:
            return "Set the Raspberry Pi address in the app first."
        }
    }
}

// MARK: - Shortcuts

struct NeptuneShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PowerPrinterOnIntent(),
            phrases: [
                "Turn on my \(.applicationName) printer",
                "Power on the printer with \(.applicationName)"
            ],
            shortTitle: "Power On",
            systemImageName: "power"
        )
        AppShortcut(
            intent: PowerPrinterOffIntent(),
            phrases: [
                "Turn off my \(.applicationName) printer",
                "Power off the printer with \(.applicationName)"
            ],
            shortTitle: "Power Off",
            systemImageName: "power.circle"
        )
        AppShortcut(
            intent: PausePrintIntent(),
            phrases: ["Pause my print in \(.applicationName)"],
            shortTitle: "Pause Print",
            systemImageName: "pause.circle"
        )
        AppShortcut(
            intent: ResumePrintIntent(),
            phrases: ["Resume my print in \(.applicationName)"],
            shortTitle: "Resume Print",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: PrinterStatusIntent(),
            phrases: ["What is my printer doing in \(.applicationName)"],
            shortTitle: "Printer Status",
            systemImageName: "printer"
        )
        AppShortcut(
            intent: OpenPrinterIntent(),
            phrases: ["Open \(.applicationName)"],
            shortTitle: "Open Printer",
            systemImageName: "house"
        )
    }
}
