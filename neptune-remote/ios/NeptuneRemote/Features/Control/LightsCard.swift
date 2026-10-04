import SwiftUI

/// On, off, and how bright - for whatever lights this printer actually has.
///
/// The card removes itself when discovery found none, which on a stock Neptune
/// 3 Plus is the correct answer: there is no LED in the config, so there is
/// nothing to switch and no button that could pretend otherwise. What appears
/// here came from `[neopixel]`, `[led]` or a light-named `[output_pin]` in the
/// user's own printer.cfg.
struct LightsCard: View {
    @EnvironmentObject private var printer: PrinterStore

    /// Slider positions while the user is dragging, before the printer has
    /// confirmed. Keyed by Klipper object name.
    @State private var pending: [String: Double] = [:]

    private var lights: [PrinterCapabilities.LightSpec] { printer.capabilities.lights }

    var body: some View {
        if !lights.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader("light.section", systemImage: "lightbulb.fill")
                ForEach(lights) { light in
                    row(light)
                    if light.id != lights.last?.id { Divider() }
                }
            }
            .card()
            .task { await printer.refreshLights() }
        }
    }

    @ViewBuilder
    private func row(_ light: PrinterCapabilities.LightSpec) -> some View {
        let level = printer.lightLevels[light.object]

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(light.displayName)
                        .font(.subheadline.weight(.medium))
                    // The exact object being switched. On an output pin this is
                    // the difference between turning on a lamp and turning on
                    // whatever else happened to be wired to that pin.
                    Text(light.object)
                        .font(.caption2)
                        .monospaced()
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if level == nil {
                    Text(localized: "light.unknown")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // Two explicit buttons rather than a toggle: a toggle has no way to
            // say "I have not heard from this light yet", and would show off for
            // a lamp that is on.
            HStack(spacing: 10) {
                stateButton(titleKey: "common.off", isActive: level.map { $0 <= 0.001 }) {
                    pending[light.object] = 0
                    Task { await printer.setLight(light, brightness: 0) }
                }
                stateButton(titleKey: "common.on", isActive: level.map { $0 > 0.001 }) {
                    pending[light.object] = 1
                    Task { await printer.setLight(light, brightness: 1) }
                }
            }

            if light.isDimmable {
                LabelledSlider(
                    titleKey: "light.brightness",
                    value: brightnessBinding(light),
                    range: 0...100,
                    step: 5,
                    unit: "%",
                    tint: Theme.paused
                ) { value in
                    Task { await printer.setLight(light, brightness: value / 100) }
                }
            } else {
                Text(localized: "light.not_dimmable")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if light.hasColour {
                colourRow(light)
            }
        }
    }

    private func brightnessBinding(_ light: PrinterCapabilities.LightSpec) -> Binding<Double> {
        Binding(
            get: { (pending[light.object] ?? printer.lightLevels[light.object] ?? 0) * 100 },
            set: { pending[light.object] = $0 / 100 }
        )
    }

    private func stateButton(
        titleKey: String,
        isActive: Bool?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(localized: titleKey)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    (isActive == true) ? Theme.accent.opacity(0.25) : Theme.accent.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
        }
        .buttonStyle(.plain)
    }

    /// Colour is only offered on a light that has separate red, green and blue
    /// channels - a single PWM pin has no colour to set, and asking for one
    /// would just quietly change the brightness.
    private func colourRow(_ light: PrinterCapabilities.LightSpec) -> some View {
        ColourPickerRow(light: light)
    }
}

/// A colour picker that sends once the value settles.
///
/// The system picker updates its binding continuously while a finger is on the
/// gradient, and forwarding every one of those would push hundreds of SET_LED
/// commands into the same G-code queue the print is running through. Each change
/// cancels the previous send and waits a moment first, so a drag costs one
/// command instead of a hundred.
private struct ColourPickerRow: View {
    let light: PrinterCapabilities.LightSpec

    @EnvironmentObject private var printer: PrinterStore
    @State private var colour: Color = .white
    @State private var sendTask: Task<Void, Never>?

    var body: some View {
        ColorPicker(L.t("light.colour"), selection: $colour, supportsOpacity: false)
            .font(.subheadline)
            .onChange(of: colour) { _, value in
                let components = Self.components(of: value)
                sendTask?.cancel()
                sendTask = Task {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard !Task.isCancelled else { return }
                    await printer.setLight(
                        light, red: components.red, green: components.green, blue: components.blue
                    )
                }
            }
            .onDisappear { sendTask?.cancel() }
    }

    static func components(of colour: Color) -> (red: Double, green: Double, blue: Double) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        UIColor(colour).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (Double(red), Double(green), Double(blue))
    }
}
