import SwiftUI
import UIKit

extension Color {
    /// `0xRRGGBB`. Non-failable, for design tokens written in code - the
    /// string initialiser elsewhere is for colours that arrive as user data.
    init(rgb: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255,
            opacity: opacity
        )
    }
}

/// Central design tokens. Everything adapts to light and dark automatically.
///
/// The identity is the name: Neptune. Deep water for anything that is the
/// machine and its state, and molten amber for the one thing in the picture
/// that is hot - the nozzle. Two colours, used the same way on every screen,
/// so the app is recognisable from a single cropped screenshot.
enum Theme {
    /// Brand cyan. Deep enough to read on white, bright enough to glow on black.
    static let accent = Color("AccentColor")

    // MARK: Brand

    /// The deep-water gradient behind every hero surface.
    static let abyssTop = Color(rgb: 0x0E3557)
    static let abyssMid = Color(rgb: 0x082640)
    static let abyssDeep = Color(rgb: 0x030F1E)
    static let tide = Color(rgb: 0x22D3EE)
    static let tideDeep = Color(rgb: 0x0891B2)
    static let emberHot = Color(rgb: 0xFF8A1F)
    static let emberWarm = Color(rgb: 0xFFC14D)

    static var abyss: LinearGradient {
        LinearGradient(
            colors: [abyssTop, abyssMid, abyssDeep],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Progress, and anything that is the machine doing its job.
    static var tideGradient: LinearGradient {
        LinearGradient(colors: [tideDeep, tide], startPoint: .leading, endPoint: .trailing)
    }

    /// Heat. Used only for temperatures and the nozzle, so it keeps meaning
    /// "this is hot" everywhere it appears.
    static var emberGradient: LinearGradient {
        LinearGradient(colors: [emberHot, emberWarm], startPoint: .leading, endPoint: .trailing)
    }

    /// Cold metal - the bed, which is hot too, but never the thing to watch.
    static var frostGradient: LinearGradient {
        LinearGradient(colors: [Color(rgb: 0x3B82F6), Color(rgb: 0x60A5FA)], startPoint: .leading, endPoint: .trailing)
    }

    static let nozzle = Color(red: 1.00, green: 0.45, blue: 0.25)
    static let bed = Color(red: 0.30, green: 0.62, blue: 1.00)
    static let printing = Color(red: 0.20, green: 0.78, blue: 0.55)
    static let paused = Color(red: 1.00, green: 0.72, blue: 0.20)
    static let danger = Color(red: 0.94, green: 0.28, blue: 0.30)
    static let idle = Color.secondary

    /// Grouped-background surfaces that read correctly in light and dark.
    static let cardFill = Color(uiColor: .secondarySystemGroupedBackground)
    static let pageFill = Color(uiColor: .systemGroupedBackground)

    static let cornerRadius: CGFloat = 22
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

    /// Toolpath colours, borrowed from the vocabulary every slicer already
    /// uses: warm for the walls that show, cool for the infill nobody sees,
    /// green for support that gets thrown away, and a faint dash for travel.
    ///
    /// Anyone who has opened a slicer recognises this legend without reading
    /// it, which is the whole reason not to invent a new one.
    static func color(for feature: ToolpathFeature) -> Color {
        switch feature {
        case .outerWall: return Color(red: 0.98, green: 0.45, blue: 0.16)
        case .innerWall: return Color(red: 0.95, green: 0.72, blue: 0.22)
        case .infill:    return Color(red: 0.78, green: 0.32, blue: 0.28)
        case .solid:     return Color(red: 0.90, green: 0.55, blue: 0.35)
        case .support:   return Color(red: 0.31, green: 0.70, blue: 0.48)
        case .skirt:     return Color(red: 0.45, green: 0.62, blue: 0.85)
        case .bridge:    return Color(red: 0.38, green: 0.78, blue: 0.85)
        case .travel:    return Color.secondary.opacity(0.45)
        case .unknown:   return Color.secondary
        }
    }

    /// The plate the toolpath is drawn on. Dark enough that the warm wall
    /// colours read against it in both themes.
    static let previewBed = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 0.10, alpha: 1)
            : UIColor(white: 0.16, alpha: 1)
    })

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
///
/// Light mode lifts the card off the page with a soft shadow; dark mode has no
/// shadow to cast, so the same lift comes from a hairline of light along the top
/// edge - the way a pane of glass catches a ceiling light. Either way the card
/// reads as a surface rather than a rectangle filled in.
struct CardBackground: ViewModifier {
    var tint: Color = .clear
    var padding: CGFloat = Theme.cardPadding

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                shape
                    .fill(Theme.cardFill)
                    .overlay {
                        // The state colour as a wash from the leading edge,
                        // rather than a flat tint over the whole card - enough
                        // to say "this is the printing card" at a glance
                        // without turning the text a colour.
                        shape.fill(
                            LinearGradient(
                                colors: [tint.opacity(0.16), tint.opacity(0.02)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    }
                    .overlay {
                        shape.strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(colorScheme == .dark ? 0.14 : 0.9),
                                    Color.primary.opacity(colorScheme == .dark ? 0.04 : 0.05)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                    }
                    .shadow(
                        color: Color.black.opacity(colorScheme == .dark ? 0 : 0.06),
                        radius: 14, x: 0, y: 6
                    )
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
