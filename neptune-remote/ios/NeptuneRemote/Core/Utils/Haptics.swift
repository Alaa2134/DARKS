import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Thin wrapper around UIFeedbackGenerator so views can call haptics without
/// `#if` noise, and so the user can switch them off in Settings.
enum Haptics {
    static var isEnabled = true

    enum ImpactStyle {
        case light, medium, heavy, rigid, soft
    }

    enum NotificationStyle {
        case success, warning, error
    }

    static func impact(_ style: ImpactStyle = .medium) {
        guard isEnabled else { return }
        #if canImport(UIKit)
        let generator = UIImpactFeedbackGenerator(style: style.uiStyle)
        generator.prepare()
        generator.impactOccurred()
        #endif
    }

    static func notify(_ style: NotificationStyle) {
        guard isEnabled else { return }
        #if canImport(UIKit)
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(style.uiType)
        #endif
    }

    static func success() { notify(.success) }
    static func warning() { notify(.warning) }
    static func error() { notify(.error) }

    static func selection() {
        guard isEnabled else { return }
        #if canImport(UIKit)
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
        #endif
    }
}

#if canImport(UIKit)
private extension Haptics.ImpactStyle {
    var uiStyle: UIImpactFeedbackGenerator.FeedbackStyle {
        switch self {
        case .light: return .light
        case .medium: return .medium
        case .heavy: return .heavy
        case .rigid: return .rigid
        case .soft: return .soft
        }
    }
}

private extension Haptics.NotificationStyle {
    var uiType: UINotificationFeedbackGenerator.FeedbackType {
        switch self {
        case .success: return .success
        case .warning: return .warning
        case .error: return .error
        }
    }
}
#endif
