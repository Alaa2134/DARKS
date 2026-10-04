import Combine
import Foundation
import SwiftUI

/// Every user preference in one observable object.
///
/// Non-secret values live in UserDefaults (mirrored into the App Group so the
/// widget and App Intents see the same connection details). Secrets live in the
/// Keychain and are never encoded here.
@MainActor
final class AppSettings: ObservableObject {

    // MARK: - Connection

    @Published var host: String { didSet { persist(host, .host); syncConnection() } }
    @Published var moonrakerPort: Int { didSet { persist(moonrakerPort, .moonrakerPort); syncConnection() } }
    @Published var backendPort: Int { didSet { persist(backendPort, .backendPort); syncConnection() } }
    @Published var useHTTPS: Bool { didSet { persist(useHTTPS, .useHTTPS); syncConnection() } }
    @Published var printerName: String { didSet { persist(printerName, .printerName) } }

    /// Kept in the Keychain, surfaced here for the settings form.
    @Published var backendToken: String {
        didSet { Keychain.set(backendToken.isEmpty ? nil : backendToken, for: .backendToken) }
    }
    @Published var moonrakerAPIKey: String {
        didSet { Keychain.set(moonrakerAPIKey.isEmpty ? nil : moonrakerAPIKey, for: .moonrakerAPIKey) }
    }

    // MARK: - Appearance & language

    @Published var appearance: AppearanceMode { didSet { persist(appearance.rawValue, .appearance) } }
    @Published var language: AppLanguage {
        didSet {
            persist(language.rawValue, .language)
            LocalizationManager.shared.apply(language)
        }
    }
    @Published var hapticsEnabled: Bool {
        didSet {
            persist(hapticsEnabled, .haptics)
            Haptics.isEnabled = hapticsEnabled
        }
    }

    // MARK: - Safety

    @Published var safeNozzleTemp: Double { didSet { persist(safeNozzleTemp, .safeNozzle) } }
    @Published var safeBedTemp: Double { didSet { persist(safeBedTemp, .safeBed) } }
    @Published var requirePrintChecklist: Bool { didSet { persist(requirePrintChecklist, .checklist) } }
    /// Turns pre-print warnings into blocks. For people who would rather the
    /// app be pedantic than sorry.
    @Published var strictSafetyMode: Bool { didSet { persist(strictSafetyMode, .strictSafety) } }
    @Published var allowColdExtrusion: Bool { didSet { persist(allowColdExtrusion, .coldExtrusion) } }
    @Published var minExtrusionTemp: Double { didSet { persist(minExtrusionTemp, .minExtrusionTemp) } }

    // MARK: - Automatic power off

    @Published var autoPowerOffEnabled: Bool { didSet { persist(autoPowerOffEnabled, .autoPowerOff) } }
    @Published var autoPowerOffNozzle: Double { didSet { persist(autoPowerOffNozzle, .autoPowerOffNozzle) } }
    @Published var autoPowerOffBed: Double { didSet { persist(autoPowerOffBed, .autoPowerOffBed) } }
    @Published var autoPowerOffDelay: Double { didSet { persist(autoPowerOffDelay, .autoPowerOffDelay) } }

    // MARK: - Power provider

    @Published var powerProvider: PowerProviderKind { didSet { persist(powerProvider.rawValue, .powerProvider) } }
    @Published var moonrakerPowerDevice: String { didSet { persist(moonrakerPowerDevice, .moonrakerPowerDevice) } }
    @Published var webhookOnURL: String { didSet { persist(webhookOnURL, .webhookOn) } }
    @Published var webhookOffURL: String { didSet { persist(webhookOffURL, .webhookOff) } }
    @Published var webhookStatusURL: String { didSet { persist(webhookStatusURL, .webhookStatus) } }

    // MARK: - Camera

    @Published var cameraURL: String { didSet { persist(cameraURL, .cameraURL) } }
    @Published var cameraKind: CameraKind { didSet { persist(cameraKind.rawValue, .cameraKind) } }
    @Published var cameraRotation: Int { didSet { persist(cameraRotation, .cameraRotation) } }
    @Published var cameraMirrored: Bool { didSet { persist(cameraMirrored, .cameraMirrored) } }

    // MARK: - Notifications

    @Published var notificationsEnabled: Bool { didSet { persist(notificationsEnabled, .notifications) } }
    @Published var notifyPrintFinished: Bool { didSet { persist(notifyPrintFinished, .notifyFinished) } }
    @Published var notifyPrintFailed: Bool { didSet { persist(notifyPrintFailed, .notifyFailed) } }
    @Published var notifyKlipperError: Bool { didSet { persist(notifyKlipperError, .notifyKlipper) } }
    @Published var notifyDisconnected: Bool { didSet { persist(notifyDisconnected, .notifyDisconnected) } }
    @Published var notifyTargetReached: Bool { didSet { persist(notifyTargetReached, .notifyTarget) } }
    @Published var notifyPrintStateChanges: Bool { didSet { persist(notifyPrintStateChanges, .notifyStateChanges) } }
    @Published var notifyVisionAlerts: Bool { didSet { persist(notifyVisionAlerts, .notifyVision) } }
    @Published var notifyQueueReady: Bool { didSet { persist(notifyQueueReady, .notifyQueue) } }
    @Published var notifyMaintenanceDue: Bool { didSet { persist(notifyMaintenanceDue, .notifyMaintenance) } }
    @Published var notifyFilamentLow: Bool { didSet { persist(notifyFilamentLow, .notifyFilament) } }
    /// Power cuts, interrupted prints and filament runout - on by default,
    /// because these are the ones you are away from the house for.
    @Published var notifyPowerAndRunout: Bool { didSet { persist(notifyPowerAndRunout, .notifyPower) } }
    /// First layer done, halfway there. Off by default: pleasant, not urgent.
    @Published var notifyProgressMilestones: Bool { didSet { persist(notifyProgressMilestones, .notifyProgress) } }

    // MARK: - Modes

    @Published var demoMode: Bool { didSet { persist(demoMode, .demoMode) } }
    @Published var advancedMode: Bool { didSet { persist(advancedMode, .advancedMode) } }
    @Published var developerMode: Bool { didSet { persist(developerMode, .developerMode) } }
    @Published var hasCompletedSetup: Bool { didSet { persist(hasCompletedSetup, .setupComplete) } }

    // MARK: - Collections

    @Published var temperaturePresets: [TemperaturePreset] { didSet { persistJSON(temperaturePresets, .temperaturePresets) } }
    @Published var gcodeFavourites: [GCodeShortcut] { didSet { persistJSON(gcodeFavourites, .gcodeFavourites) } }
    @Published var gcodeHistory: [String] { didSet { persistJSON(gcodeHistory, .gcodeHistory) } }
    @Published var slicePresets: [SlicePreset] { didSet { persistJSON(slicePresets, .slicePresets) } }

    // MARK: - Jog defaults

    @Published var jogStep: Double { didSet { persist(jogStep, .jogStep) } }
    @Published var jogFeedrate: Double { didSet { persist(jogFeedrate, .jogFeedrate) } }
    @Published var extrudeLength: Double { didSet { persist(extrudeLength, .extrudeLength) } }
    @Published var extrudeSpeed: Double { didSet { persist(extrudeSpeed, .extrudeSpeed) } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        func string(_ key: Key, _ fallback: String) -> String {
            defaults.string(forKey: key.rawValue) ?? fallback
        }
        func int(_ key: Key, _ fallback: Int) -> Int {
            defaults.object(forKey: key.rawValue) as? Int ?? fallback
        }
        func double(_ key: Key, _ fallback: Double) -> Double {
            defaults.object(forKey: key.rawValue) as? Double ?? fallback
        }
        func bool(_ key: Key, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key.rawValue) as? Bool ?? fallback
        }
        func json<T: Decodable>(_ key: Key, _ fallback: T) -> T {
            guard let data = defaults.data(forKey: key.rawValue),
                  let value = try? JSONDecoder().decode(T.self, from: data)
            else { return fallback }
            return value
        }

        let stored = SharedStore.loadConnection()
        host = string(.host, stored.host)
        moonrakerPort = int(.moonrakerPort, stored.moonrakerPort)
        backendPort = int(.backendPort, stored.backendPort)
        useHTTPS = bool(.useHTTPS, stored.useHTTPS)
        printerName = string(.printerName, "Neptune 3 Plus")

        backendToken = Keychain.get(.backendToken) ?? ""
        moonrakerAPIKey = Keychain.get(.moonrakerAPIKey) ?? ""

        appearance = AppearanceMode(rawValue: string(.appearance, AppearanceMode.system.rawValue)) ?? .system
        language = AppLanguage(rawValue: string(.language, AppLanguage.system.rawValue)) ?? .system
        hapticsEnabled = bool(.haptics, true)

        safeNozzleTemp = double(.safeNozzle, 50)
        safeBedTemp = double(.safeBed, 45)
        requirePrintChecklist = bool(.checklist, true)
        strictSafetyMode = bool(.strictSafety, false)
        allowColdExtrusion = bool(.coldExtrusion, false)
        minExtrusionTemp = double(.minExtrusionTemp, 170)

        autoPowerOffEnabled = bool(.autoPowerOff, false)
        autoPowerOffNozzle = double(.autoPowerOffNozzle, 50)
        autoPowerOffBed = double(.autoPowerOffBed, 45)
        autoPowerOffDelay = double(.autoPowerOffDelay, 300)

        powerProvider = PowerProviderKind(rawValue: string(.powerProvider, PowerProviderKind.backend.rawValue)) ?? .backend
        moonrakerPowerDevice = string(.moonrakerPowerDevice, "printer")
        webhookOnURL = string(.webhookOn, "")
        webhookOffURL = string(.webhookOff, "")
        webhookStatusURL = string(.webhookStatus, "")

        cameraURL = string(.cameraURL, "")
        cameraKind = CameraKind(rawValue: string(.cameraKind, CameraKind.mjpeg.rawValue)) ?? .mjpeg
        cameraRotation = int(.cameraRotation, 0)
        cameraMirrored = bool(.cameraMirrored, false)

        notificationsEnabled = bool(.notifications, true)
        notifyPrintFinished = bool(.notifyFinished, true)
        notifyPrintFailed = bool(.notifyFailed, true)
        notifyKlipperError = bool(.notifyKlipper, true)
        notifyDisconnected = bool(.notifyDisconnected, true)
        notifyTargetReached = bool(.notifyTarget, false)
        notifyPrintStateChanges = bool(.notifyStateChanges, true)
        notifyVisionAlerts = bool(.notifyVision, true)
        notifyQueueReady = bool(.notifyQueue, true)
        notifyMaintenanceDue = bool(.notifyMaintenance, true)
        notifyFilamentLow = bool(.notifyFilament, true)
        notifyPowerAndRunout = bool(.notifyPower, true)
        notifyProgressMilestones = bool(.notifyProgress, false)

        demoMode = bool(.demoMode, false)
        advancedMode = bool(.advancedMode, false)
        developerMode = bool(.developerMode, false)
        hasCompletedSetup = bool(.setupComplete, false)

        temperaturePresets = json(.temperaturePresets, TemperaturePreset.defaults)
        gcodeFavourites = json(.gcodeFavourites, [GCodeShortcut]())
        gcodeHistory = json(.gcodeHistory, [String]())
        slicePresets = json(.slicePresets, SlicePreset.defaults)

        jogStep = double(.jogStep, 10)
        jogFeedrate = double(.jogFeedrate, 3000)
        extrudeLength = double(.extrudeLength, 10)
        extrudeSpeed = double(.extrudeSpeed, 5)

        LocalizationManager.shared.apply(language)
        Haptics.isEnabled = hapticsEnabled
        syncConnection()
    }

    // MARK: - Derived

    var connection: ConnectionConfig {
        ConnectionConfig(
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            moonrakerPort: moonrakerPort,
            backendPort: backendPort,
            useHTTPS: useHTTPS
        )
    }

    var colorScheme: ColorScheme? { appearance.colorScheme }

    var locale: Locale {
        guard let identifier = language.localeIdentifier else { return .autoupdatingCurrent }
        return Locale(identifier: identifier)
    }

    var layoutDirection: LayoutDirection {
        if let direction = language.layoutDirection { return direction }
        return Locale.Language(identifier: Locale.current.identifier).characterDirection == .rightToLeft
            ? .rightToLeft
            : .leftToRight
    }

    // MARK: - Mutations

    func recordCommand(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var history = gcodeHistory.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        history.insert(trimmed, at: 0)
        gcodeHistory = Array(history.prefix(60))
    }

    func toggleFavourite(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let index = gcodeFavourites.firstIndex(where: { $0.command.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            gcodeFavourites.remove(at: index)
        } else {
            gcodeFavourites.append(GCodeShortcut(command: trimmed, label: trimmed, isFavourite: true))
        }
    }

    func isFavourite(_ command: String) -> Bool {
        gcodeFavourites.contains { $0.command.caseInsensitiveCompare(command) == .orderedSame }
    }

    func resetTemperaturePresets() {
        temperaturePresets = TemperaturePreset.defaults
    }

    func resetEverything() {
        Key.allCases.forEach { defaults.removeObject(forKey: $0.rawValue) }
        Keychain.deleteAll()
    }

    // MARK: - Persistence

    private func persist(_ value: Any?, _ key: Key) {
        defaults.set(value, forKey: key.rawValue)
    }

    private func persistJSON<T: Encodable>(_ value: T, _ key: Key) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key.rawValue)
    }

    /// Mirror the connection into the shared App Group for widget + Shortcuts.
    private func syncConnection() {
        SharedStore.save(connection)
    }

    enum Key: String, CaseIterable {
        case host, moonrakerPort, backendPort, useHTTPS, printerName
        case appearance, language, haptics
        case safeNozzle, safeBed, checklist, coldExtrusion, minExtrusionTemp
        case strictSafety
        case autoPowerOff, autoPowerOffNozzle, autoPowerOffBed, autoPowerOffDelay
        case powerProvider, moonrakerPowerDevice, webhookOn, webhookOff, webhookStatus
        case cameraURL, cameraKind, cameraRotation, cameraMirrored
        case notifications, notifyFinished, notifyFailed, notifyKlipper
        case notifyDisconnected, notifyTarget, notifyStateChanges
        case notifyVision, notifyQueue, notifyMaintenance, notifyFilament
        case notifyPower, notifyProgress
        case demoMode, advancedMode, developerMode, setupComplete
        case temperaturePresets, gcodeFavourites, gcodeHistory, slicePresets
        case jogStep, jogFeedrate, extrudeLength, extrudeSpeed
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var localizationKey: String { "settings.appearance.\(rawValue)" }
}

enum CameraKind: String, CaseIterable, Identifiable, Codable {
    case mjpeg
    case snapshot
    case webrtc
    case mainsail

    var id: String { rawValue }
    var localizationKey: String { "camera.kind.\(rawValue)" }
}

enum PowerProviderKind: String, CaseIterable, Identifiable, Codable {
    /// Ask the Raspberry Pi backend (which owns the Tuya credentials).
    case backend
    /// Use a Moonraker `[power ...]` device directly.
    case moonraker
    /// Call user-supplied HTTP endpoints straight from the phone.
    case webhook
    /// Simulated switch for Demo Mode.
    case demo
    case none

    var id: String { rawValue }
    var localizationKey: String { "power.provider.\(rawValue)" }
}
