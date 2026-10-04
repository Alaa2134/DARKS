import SwiftUI

/// The deep-water surface behind the one card per screen that *is* the machine.
///
/// Every other card is a neutral surface. This one is not, on purpose: it is
/// the first thing the eye lands on, it carries the brand, and it is where the
/// printer's state lives - so the state is read before anything else is.
struct HeroBackground: View {
    /// The light coming up through the water. The state colour, so a printer
    /// that is printing glows green and one in trouble glows red.
    var glow: Color = Theme.tide

    var body: some View {
        ZStack {
            Theme.abyss
            RadialGradient(
                colors: [glow.opacity(0.42), glow.opacity(0.0)],
                center: UnitPoint(x: 0.85, y: 0.05),
                startRadius: 4,
                endRadius: 280
            )
            RadialGradient(
                colors: [Theme.tide.opacity(0.18), .clear],
                center: UnitPoint(x: 0.1, y: 1.0),
                startRadius: 4,
                endRadius: 240
            )
            // Printed layers laid down as a sea - the same motif as the icon,
            // faint enough to be texture rather than picture.
            LayerWaves()
                .stroke(Color.white.opacity(0.07), lineWidth: 1.2)
        }
    }
}

/// Four gentle waves along the bottom of a surface.
struct LayerWaves: Shape {
    var count = 4

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for index in 0..<count {
            let y = rect.maxY - CGFloat(index) * 13 - 14
            let amplitude: CGFloat = 6
            let phase = CGFloat(index) * 0.9
            path.move(to: CGPoint(x: rect.minX, y: y))
            var x = rect.minX
            while x <= rect.maxX {
                let progress = (x - rect.minX) / max(rect.width, 1)
                let wave = sin(progress * .pi * 2.2 + phase) * amplitude
                path.addLine(to: CGPoint(x: x, y: y + wave))
                x += 6
            }
        }
        return path
    }
}

extension View {
    /// Put this content on the hero surface.
    ///
    /// The content is drawn in the dark appearance whatever the system is set
    /// to, because it sits on deep water in both - white text on navy is the
    /// only combination that reads there.
    func heroCard(glow: Color = Theme.tide, padding: CGFloat = 20) -> some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        return self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { HeroBackground(glow: glow).clipShape(shape) }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.28), Color.white.opacity(0.03)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            }
            .shadow(color: Theme.abyssDeep.opacity(0.35), radius: 22, x: 0, y: 12)
            .environment(\.colorScheme, .dark)
    }
}

/// A state label that looks alive when the thing it describes is.
struct StatusChip: View {
    let text: String
    var color: Color = Theme.tide
    var systemImage: String?
    var pulsing = false

    @State private var breathe = false

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption.weight(.bold))
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                    .shadow(color: color, radius: breathe ? 6 : 2)
                    .scaleEffect(breathe ? 1.15 : 0.9)
            }
            Text(text)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.16), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.35), lineWidth: 1))
        .onAppear {
            guard pulsing else { return }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
    }
}

/// The Neptune 3 Plus, drawn. Shown where a live picture would go when there
/// is no print to show - an empty frame says "no camera", this says "your
/// printer, ready".
struct PrinterIllustration: View {
    /// A slow float, so the idle home screen is not a still photograph.
    var floats = true

    @State private var up = false

    var body: some View {
        Image("PrinterHero")
            .resizable()
            .scaledToFit()
            .offset(y: up ? -3 : 3)
            .shadow(color: Theme.tide.opacity(0.25), radius: 18, y: 8)
            .accessibilityHidden(true)
            .onAppear {
                guard floats else { return }
                withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) {
                    up = true
                }
            }
    }
}
