import Foundation

/// One thing worth telling the user about the printer's state.
///
/// The problem this replaces: every non-ready Klipper state was flattened into a
/// single red "Printer error" card. "Z is not homed" is not a fault - it is the
/// normal state of a printer that has just been switched on, and it needs a Home
/// button, not an alarm. Meanwhile a genuine MCU shutdown got the same card and
/// the same colour, so the two were indistinguishable.
struct PrinterCondition: Identifiable, Equatable {

    /// How bad this is, and therefore how it is presented.
    ///
    /// Ordered, so grouping can keep the most serious condition for a cause and
    /// discard the rest.
    enum Severity: Int, Comparable, Equatable {
        /// Normal operation worth showing - Klipper starting up, print paused.
        case informational
        /// Nothing is broken, but the printer will refuse commands until the
        /// user does something. Homing after a restart is the archetype.
        case actionRequired
        /// Worth knowing, does not block.
        case warning
        /// Klipper stopped and a restart clears it.
        case recoverableError
        /// The configuration or the MCU is wrong; restarting will not help
        /// until printer.cfg or the hardware is fixed.
        case configurationError
        /// Emergency stop, thermal runaway, MCU shutdown mid-print.
        case critical

        static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var isError: Bool { self >= .recoverableError }

        var localizationKey: String {
            switch self {
            case .informational: return "condition.severity.info"
            case .actionRequired: return "condition.severity.action"
            case .warning: return "condition.severity.warning"
            case .recoverableError: return "condition.severity.recoverable"
            case .configurationError: return "condition.severity.configuration"
            case .critical: return "condition.severity.critical"
            }
        }
    }

    /// What the user can do about it, offered as a button.
    enum Remedy: Equatable {
        case homeAxes(String)       // "" for all
        case firmwareRestart
        case restartKlipper
        case openConfig
        case none
    }

    /// The underlying situation. Two conditions sharing a cause are the same
    /// event described twice, and only the worst survives - this is what stops
    /// "Printer error" / "Z is not homed" / "Printer error" stacking up for one
    /// underlying state.
    enum Cause: String, Equatable {
        case klippyShutdown
        case klippyError
        case klippyStartup
        case klippyDisconnected
        case notHomed
        case printPaused
        case printCancelled
        case filamentRunout
        case unknownMessage
    }

    let cause: Cause
    let severity: Severity
    let titleKey: String
    /// Extra explanation, e.g. that homing is expected after a restart.
    let bodyKey: String?
    /// Klipper's own words, preserved exactly and never translated. Shown under
    /// "technical details" so the English text is still searchable and can be
    /// pasted into a forum post.
    let rawMessage: String?
    let remedy: Remedy
    /// Axes this concerns, for the homing case.
    let axes: String

    var id: String { cause.rawValue + axes }

    /// Whether this deserves the red treatment. Action-required states do not.
    var isError: Bool { severity.isError }
}

/// Builds the current conditions from live Klipper objects.
///
/// Order of evidence matters and is deliberate: **state objects first, message
/// text only as a fallback.** `webhooks.state`, `toolhead.homed_axes` and
/// `print_stats.state` are structured and reliable; the state message is
/// free-form English that changes between Klipper versions, so parsing it is a
/// last resort and never the basis for a diagnosis on its own.
enum PrinterConditionEvaluator {

    /// Inputs, all from live objects rather than from parsed prose.
    struct Input {
        var klippy: KlippyState = .unknown
        /// `webhooks.state_message`, verbatim.
        var klippyMessage: String = ""
        /// `toolhead.homed_axes`, e.g. "xy" or "xyz".
        var homedAxes: String = ""
        var printState: PrinterState = .unknown
        var idleTimeoutState: String = ""
        var isPrinting: Bool = false
        /// Axes this printer actually has, from printer.cfg. A machine with no
        /// Z stepper must not be told to home Z.
        var configuredAxes: [String] = ["x", "y", "z"]
        var connected: Bool = true
        /// The filament sensor currently reporting no filament, if any.
        /// Nil on a printer with no sensor - which is not the same as "there is
        /// filament", and is why this is optional rather than a Bool.
        var filamentRunoutSensor: BackendFilamentSensor?
    }

    /// Message fragments that mean "an axis has not been homed".
    ///
    /// Used only to decide whether an *already-known* unhomed state explains a
    /// message we would otherwise have to show as unclassified - never to infer
    /// the homing state itself, which comes from `toolhead.homed_axes`.
    static let homingPhrases = [
        "must home axis first",
        "must home",
        "not homed",
        "unhomed",
        "home the printer first",
        "printer not homed"
    ]

    /// Fragments that mean the configuration or the microcontroller is at
    /// fault, so a plain restart will not clear it.
    static let configurationPhrases = [
        "mcu", "config error", "option ", "section ", "unable to parse",
        "invalid pin", "pin ", "unknown config", "must specify",
        "firmware version", "software version", "mismatch", "shutdown due to",
        "can't connect", "cannot connect", "unable to connect"
    ]

    // MARK: - Evaluation

    static func conditions(for input: Input) -> [PrinterCondition] {
        var result: [PrinterCondition] = []
        let message = input.klippyMessage.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Klipper's own state is the primary signal.
        switch input.klippy {
        case .shutdown:
            result.append(shutdownCondition(message: message, isPrinting: input.isPrinting))

        case .error:
            result.append(errorCondition(message: message))

        case .startup:
            result.append(
                PrinterCondition(
                    cause: .klippyStartup,
                    severity: .informational,
                    titleKey: "condition.starting.title",
                    bodyKey: "condition.starting.body",
                    rawMessage: message.isEmpty ? nil : message,
                    remedy: .none,
                    axes: ""
                )
            )

        case .disconnected:
            result.append(
                PrinterCondition(
                    cause: .klippyDisconnected,
                    severity: .recoverableError,
                    titleKey: "condition.disconnected.title",
                    bodyKey: "condition.disconnected.body",
                    rawMessage: message.isEmpty ? nil : message,
                    remedy: .restartKlipper,
                    axes: ""
                )
            )

        case .ready, .unknown:
            // Klipper is fine. Anything left is a normal operating state, and
            // in particular a stale message from before the restart must not
            // produce an error card.
            break
        }

        // 2. Homing, read from toolhead.homed_axes rather than from any string.
        //    This is reported even when Klipper is ready, because it is the
        //    normal post-restart state - and it is *not* an error.
        if input.klippy == .ready || input.klippy == .unknown {
            let missing = missingAxes(homed: input.homedAxes, configured: input.configuredAxes)
            if !missing.isEmpty, !input.isPrinting {
                result.append(
                    PrinterCondition(
                        cause: .notHomed,
                        severity: .actionRequired,
                        titleKey: "condition.not_homed.title",
                        bodyKey: "condition.not_homed.body",
                        // A "Must home axis first" message is explained by this
                        // condition, so it rides along here instead of becoming
                        // a second card.
                        rawMessage: mentionsHoming(message) ? message : nil,
                        remedy: .homeAxes(missing.joined()),
                        axes: missing.joined()
                    )
                )
            }
        }

        // 3. A message we have not explained yet. Never invent a diagnosis for
        //    it - say it needs review and show Klipper's exact words.
        if input.klippy == .ready, !message.isEmpty, !isExplained(message, by: result) {
            result.append(
                PrinterCondition(
                    cause: .unknownMessage,
                    severity: .warning,
                    titleKey: "condition.unknown.title",
                    bodyKey: nil,
                    rawMessage: message,
                    remedy: .none,
                    axes: ""
                )
            )
        }

        // 4. Filament, read from the sensor object rather than from the pause.
        //
        //    Klipper's pause_on_runout turns a runout into a PAUSE, so the
        //    pause alone cannot tell you whether the filament ran out or
        //    somebody tapped the button. Checked before the paused condition
        //    below so the more specific of the two wins the dedupe.
        if let sensor = input.filamentRunoutSensor {
            result.append(
                PrinterCondition(
                    cause: .filamentRunout,
                    severity: .actionRequired,
                    titleKey: "condition.filament_runout.title",
                    // A switch sensor sees absence only. Claiming it caught a
                    // jam would describe a safety net this printer does not
                    // have installed.
                    bodyKey: sensor.detectsJams
                        ? "condition.filament_runout.motion"
                        : "condition.filament_runout.switch",
                    rawMessage: nil,
                    remedy: .none,
                    axes: ""
                )
            )
        }

        // 5. Normal print states, informational only.
        if input.printState == .paused, input.filamentRunoutSensor == nil {
            result.append(
                PrinterCondition(
                    cause: .printPaused,
                    severity: .informational,
                    titleKey: "printer.state.paused",
                    bodyKey: nil,
                    rawMessage: nil,
                    remedy: .none,
                    axes: ""
                )
            )
        }

        return deduplicate(result)
    }

    // MARK: - Individual conditions

    private static func shutdownCondition(message: String, isPrinting: Bool) -> PrinterCondition {
        let configuration = mentionsConfiguration(message)
        return PrinterCondition(
            cause: .klippyShutdown,
            severity: configuration ? .configurationError : (isPrinting ? .critical : .recoverableError),
            titleKey: configuration ? "condition.config_error.title" : "condition.shutdown.title",
            bodyKey: configuration ? "condition.config_error.body" : "condition.shutdown.body",
            rawMessage: message.isEmpty ? nil : message,
            remedy: .firmwareRestart,
            axes: ""
        )
    }

    private static func errorCondition(message: String) -> PrinterCondition {
        let configuration = mentionsConfiguration(message)
        return PrinterCondition(
            cause: .klippyError,
            severity: configuration ? .configurationError : .recoverableError,
            titleKey: configuration ? "condition.config_error.title" : "condition.error.title",
            bodyKey: configuration ? "condition.config_error.body" : "condition.error.body",
            rawMessage: message.isEmpty ? nil : message,
            remedy: configuration ? .openConfig : .firmwareRestart,
            axes: ""
        )
    }

    // MARK: - Helpers

    /// Axes the printer has but has not homed.
    static func missingAxes(homed: String, configured: [String]) -> [String] {
        let homedSet = Set(homed.lowercased().map(String.init))
        return configured
            .map { $0.lowercased() }
            .filter { !homedSet.contains($0) }
    }

    static func mentionsHoming(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return homingPhrases.contains { lowered.contains($0) }
    }

    static func mentionsConfiguration(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return configurationPhrases.contains { lowered.contains($0) }
    }

    /// Whether a condition already on the list accounts for this message, so it
    /// does not also become an "unclassified message" card.
    private static func isExplained(_ message: String, by conditions: [PrinterCondition]) -> Bool {
        if conditions.contains(where: { $0.cause == .notHomed }), mentionsHoming(message) {
            return true
        }
        return conditions.contains { $0.rawMessage == message }
    }

    /// One card per underlying cause, keeping the most serious.
    static func deduplicate(_ conditions: [PrinterCondition]) -> [PrinterCondition] {
        var best: [PrinterCondition.Cause: PrinterCondition] = [:]
        for condition in conditions {
            if let existing = best[condition.cause], existing.severity >= condition.severity {
                continue
            }
            best[condition.cause] = condition
        }
        // Worst first, so the thing that matters is at the top of the screen.
        return best.values.sorted {
            $0.severity == $1.severity
                ? $0.cause.rawValue < $1.cause.rawValue
                : $0.severity > $1.severity
        }
    }
}
