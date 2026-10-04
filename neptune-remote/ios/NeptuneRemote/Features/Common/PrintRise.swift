import SwiftUI

/// The print, rising.
///
/// A progress ring says "62 %"; this shows what 62 % of a print looks like -
/// the object standing on the bed up to the layer it has reached, the layer
/// being laid down glowing hot, the hotend sweeping across it, and the rest of
/// the object still a faint outline above. It is the one picture every FDM
/// print has in common, so it works for a file the library knows nothing about.
///
/// The silhouette is a stylised shape picked from the file's name, not the
/// real model: it is labelled as a layer view and never stands in for a
/// rendered preview of the actual part.
struct PrintRise: View {
    var progress: Double
    /// Picks the silhouette, so one print keeps one shape across screens.
    var seed: String = ""
    var paused = false
    /// Visible layers - a drawing density, not the file's layer count.
    var layers = 30

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || paused)) { timeline in
            Canvas { context, size in
                let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                draw(in: &context, size: size, time: time)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(L.t("printing.live_layers"))
        .accessibilityValue(Format.percent(progress))
    }

    // MARK: - Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let fraction = min(max(progress, 0), 1)
        let plateY = size.height - max(6, size.height * 0.06)
        let objectHeight = size.height * 0.68
        let maxHalf = size.width * 0.34
        let centreX = size.width / 2
        let pitch = objectHeight / CGFloat(layers)
        let thickness = max(1, pitch * 0.64)
        let profile = Self.profile(for: seed)
        let current = min(Int(fraction * Double(layers)), layers - 1)

        func halfWidth(_ index: Int) -> CGFloat {
            let t = (Double(index) + 0.5) / Double(layers)
            // A small per-layer ripple: the wave texture of a real wall.
            let ripple = 1 + 0.035 * sin(Double(index) * 0.85)
            return maxHalf * CGFloat(profile(t) * ripple)
        }
        func layerRect(_ index: Int) -> CGRect {
            let half = halfWidth(index)
            let y = plateY - CGFloat(index + 1) * pitch + (pitch - thickness) / 2
            return CGRect(x: centreX - half, y: y, width: half * 2, height: thickness)
        }

        // Light under the part, as if the bed were lit from below.
        context.drawLayer { glow in
            glow.addFilter(.blur(radius: size.width * 0.06))
            let width = maxHalf * 2.2
            glow.fill(
                Path(ellipseIn: CGRect(x: centreX - width / 2, y: plateY - 10, width: width, height: 20)),
                with: .color(Theme.tide.opacity(0.45))
            )
        }

        // The bed.
        let plate = CGRect(x: size.width * 0.07, y: plateY, width: size.width * 0.86, height: max(3, size.height * 0.022))
        context.fill(
            Path(roundedRect: plate, cornerRadius: plate.height / 2),
            with: .linearGradient(
                Gradient(colors: [.white.opacity(0.05), .white.opacity(0.42), .white.opacity(0.05)]),
                startPoint: CGPoint(x: plate.minX, y: 0),
                endPoint: CGPoint(x: plate.maxX, y: 0)
            )
        )

        // Layers still to come: an outline of where the part is going.
        for index in stride(from: layers - 1, to: current, by: -1) {
            let rect = layerRect(index)
            context.stroke(
                Path(roundedRect: rect, cornerRadius: thickness / 2),
                with: .color(.white.opacity(0.11)),
                lineWidth: 0.7
            )
        }

        // Layers already printed, shaded as a round wall catching the light.
        for index in 0..<current {
            let rect = layerRect(index)
            let depth = 0.72 + 0.28 * Double(index) / Double(max(layers - 1, 1))
            context.fill(
                Path(roundedRect: rect, cornerRadius: thickness / 2),
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: Theme.tideDeep.opacity(0.75 * depth), location: 0),
                        .init(color: Theme.tide.opacity(depth), location: 0.35),
                        .init(color: Color(rgb: 0xE6FDFF).opacity(depth), location: 0.5),
                        .init(color: Theme.tide.opacity(depth), location: 0.65),
                        .init(color: Theme.tideDeep.opacity(0.75 * depth), location: 1)
                    ]),
                    startPoint: CGPoint(x: rect.minX, y: 0),
                    endPoint: CGPoint(x: rect.maxX, y: 0)
                )
            )
        }

        // The layer going down now: molten, and laid as far as the nozzle has got.
        let hot = layerRect(current)
        let sweep = (sin(time * 1.7) + 1) / 2                      // 0...1, back and forth
        let nozzleX = hot.minX + hot.width * CGFloat(reduceMotion ? 0.5 : sweep)
        context.drawLayer { glow in
            glow.addFilter(.blur(radius: max(2, thickness * 1.6)))
            glow.fill(Path(roundedRect: hot.insetBy(dx: -2, dy: -1), cornerRadius: thickness),
                      with: .color(Theme.emberHot.opacity(0.85)))
        }
        context.fill(
            Path(roundedRect: hot, cornerRadius: thickness / 2),
            with: .linearGradient(
                Gradient(colors: [Theme.emberHot, Theme.emberWarm, Theme.emberHot]),
                startPoint: CGPoint(x: hot.minX, y: 0),
                endPoint: CGPoint(x: hot.maxX, y: 0)
            )
        )

        drawHotend(in: &context, size: size, tipX: nozzleX, tipY: hot.minY - 0.5)
    }

    /// Gantry, carriage, heater block and nozzle, tip touching the hot layer.
    private func drawHotend(in context: inout GraphicsContext, size: CGSize, tipX: CGFloat, tipY: CGFloat) {
        let unit = min(size.width, size.height) / 118                 // designed at 118 pt
        let nozzle = 5 * unit
        let block = CGSize(width: 12 * unit, height: 7 * unit)
        let carriage = CGSize(width: 24 * unit, height: 13 * unit)
        let blockY = tipY - nozzle - block.height
        let carriageY = blockY - carriage.height + 1 * unit
        let gantryY = carriageY + carriage.height * 0.35

        // X gantry across the machine.
        let gantry = CGRect(x: size.width * 0.04, y: gantryY, width: size.width * 0.92, height: 3 * unit)
        context.fill(Path(roundedRect: gantry, cornerRadius: 1.5 * unit), with: .color(.white.opacity(0.16)))

        // Carriage.
        let carriageRect = CGRect(x: tipX - carriage.width / 2, y: carriageY, width: carriage.width, height: carriage.height)
        context.fill(
            Path(roundedRect: carriageRect, cornerRadius: 3.5 * unit),
            with: .linearGradient(
                Gradient(colors: [Color(rgb: 0xD9E7F2), Color(rgb: 0x7B8FA6)]),
                startPoint: CGPoint(x: 0, y: carriageRect.minY),
                endPoint: CGPoint(x: 0, y: carriageRect.maxY)
            )
        )
        context.fill(
            Path(roundedRect: carriageRect.insetBy(dx: 6 * unit, dy: 4 * unit), cornerRadius: 1.5 * unit),
            with: .color(Theme.abyssDeep.opacity(0.55))
        )

        // Heater block, glowing.
        let blockRect = CGRect(x: tipX - block.width / 2, y: blockY, width: block.width, height: block.height)
        context.fill(
            Path(roundedRect: blockRect, cornerRadius: 1.5 * unit),
            with: .linearGradient(
                Gradient(colors: [Theme.emberWarm, Theme.emberHot]),
                startPoint: CGPoint(x: 0, y: blockRect.minY),
                endPoint: CGPoint(x: 0, y: blockRect.maxY)
            )
        )

        // Nozzle.
        var cone = Path()
        cone.move(to: CGPoint(x: tipX - 3.2 * unit, y: blockRect.maxY))
        cone.addLine(to: CGPoint(x: tipX + 3.2 * unit, y: blockRect.maxY))
        cone.addLine(to: CGPoint(x: tipX + 0.8 * unit, y: tipY))
        cone.addLine(to: CGPoint(x: tipX - 0.8 * unit, y: tipY))
        cone.closeSubpath()
        context.fill(cone, with: .color(Color(rgb: 0xC9A227)))

        // Where plastic meets the part.
        context.drawLayer { glow in
            glow.addFilter(.blur(radius: 3 * unit))
            glow.fill(Path(ellipseIn: CGRect(x: tipX - 4 * unit, y: tipY - 3 * unit, width: 8 * unit, height: 6 * unit)),
                      with: .color(Theme.emberWarm))
        }
    }

    // MARK: - Silhouettes

    /// Relative radius (0...1) at relative height t (0...1).
    static func profile(for seed: String) -> (Double) -> Double {
        let name = seed.lowercased()
        let shapes: [(Double) -> Double] = [
            // Vase: swells, pinches at the waist, flares at the lip.
            { t in 0.62 + 0.30 * sin(t * .pi * 1.15) - 0.14 * t },
            // Tower: a tapering column.
            { t in 0.82 - 0.38 * t },
            // Bowl: narrow foot, wide rim.
            { t in 0.38 + 0.60 * sqrt(t) },
            // Box: straight walls with a chamfered top.
            { t in t > 0.88 ? 0.86 - (t - 0.88) * 2.2 : 0.86 }
        ]
        if name.contains("vase") { return shapes[0] }
        if name.contains("bowl") || name.contains("cup") { return shapes[2] }
        if name.contains("box") || name.contains("case") || name.contains("cube") { return shapes[3] }
        if name.contains("tower") || name.contains("benchy") { return shapes[1] }
        var hash: UInt64 = 1469598103934665603
        for byte in name.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return shapes[Int(hash % UInt64(shapes.count))]
    }
}
