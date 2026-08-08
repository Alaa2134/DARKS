import SwiftUI
import UIKit

/// Central design tokens. Everything adapts to light and dark automatically.
enum Theme {
    static let accent = Color("AccentColor")

    static let nozzle = Color(red: 1.00, green: 0.45, blue: 0.25)
    static let bed = Color(red: 0.30, green: 0.62, blue: 1.00)
    static let printing = Color(red: 0.20, green: 0.78, blue: 0.55)
    static let paused = Color(red: 1.00, green: 0.72, blue: 0.20)
    static let danger = Color(red: 0.94, green: 0.28, blue: 0.30)
    static let idle = Color.secondary

    /// Grouped-background surfaces that read correctly in light and dark.
    static let cardFill = Color(uiColor: .secondarySystemGroupedBackground)
    static let pageFill = Color(uiColor: .systemGroupedBackground)

    static let cornerRadius: CGFloat = 20
    static let smallCornerRadius: CGFloat = 14
    static let cardPadding: CGFloat = 16
    static let spacing: CGFloat = 14

    static func color(for state: PrinterState) -> Color {
        switch state {
        case .printing: return printing
        case .paused: return paused
        case .error, .cancelled: return danger
        case .complete: return printing
        case .standby: return accent
        case .unknown: return idle
        }
    }

    static func color(for power: PowerState) -> Color {
        switch power {
        case .on: return printing
        case .off: return idle
        case .error: return danger
        case .unknown: return idle
        }
    }

    static func temperatureColor(_ value: Double, hotAt: Double = 60) -> Color {
        value >= hotAt ? nozzle : (value > 35 ? paused : bed)
    }
}

/// The card surface used across every screen.
struct CardBackground: ViewModifier {
    var tint: Color = .clear
    var padding: CGFloat = Theme.cardPadding

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(Theme.cardFill)
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                            .fill(tint.opacity(0.08))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                    }
            }
    }
}

extension View {
    func card(tint: Color = .clear, padding: CGFloat = Theme.cardPadding) -> some View {
        modifier(CardBackground(tint: tint, padding: padding))
    }

    /// Small helper so `if` chains stay readable in view builders.
    @ViewBuilder
    func applyIf<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition { transform(self) } else { self }
    }
}
