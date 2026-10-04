import Foundation
import OSLog

enum AppLog {
    static let network = Logger(subsystem: subsystem, category: "network")
    static let moonraker = Logger(subsystem: subsystem, category: "moonraker")
    static let backend = Logger(subsystem: subsystem, category: "backend")
    static let power = Logger(subsystem: subsystem, category: "power")
    static let slicing = Logger(subsystem: subsystem, category: "slicing")
    static let ui = Logger(subsystem: subsystem, category: "ui")

    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.neptune.remote"
}
