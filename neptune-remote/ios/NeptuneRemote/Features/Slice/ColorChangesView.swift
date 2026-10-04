import SwiftUI

/// Planning a multi-colour print on a printer with one nozzle.
///
/// The whole technique is a pause: the print stops at a layer you choose, you
/// swap the spool, it carries on. Everything below the stop is one colour and
/// everything above it is the next, so the plan is a list of layers with a
/// colour name against each - and the order they appear in is the order the
/// printer will ask for them.
///
/// Layers rather than heights, because a layer is what a slicer counts and what
/// a preview shows. The height each one lands at is filled in afterwards from
/// the sliced file, not multiplied out here: the first layer is normally
/// thicker than the rest, so `layer × layer height` is wrong by exactly that
/// difference, and wrong at every layer above it.
struct ColorChangesView: View {
    @EnvironmentObject private var slicing: SliceStore
    @EnvironmentObject private var calibration: CalibrationStore

    @State private var layerText = ""
    @State private var colorName = ""
    @State private var problem: String?

    /// Names offered as a starting point. Tapping one fills the field; it can
    /// be typed over, because a colour is whatever the person calls the spool
    /// sitting on their shelf.
    private static let common = [
        "أبيض", "أسود", "أحمر", "أزرق", "أخضر", "أصفر", "رمادي", "برتقالي", "بمبي", "شفاف"
    ]

    var body: some View {
        Form {
            explanation
            plan
            adder
            macroWarning
        }
        .navigationTitle(L.t("colors.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await calibration.loadMacros() }
    }

    // MARK: - What this is

    private var explanation: some View {
        Section {
            Text(localized: "colors.explain")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - The plan

    @ViewBuilder
    private var plan: some View {
        Section {
            if slicing.colorChanges.isEmpty {
                Text(localized: "colors.empty")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                // The colour already in the printer when you press print. It
                // has no stop of its own - it is simply what is loaded - and
                // saying so is what makes the list below read as "and then".
                Label(L.t("colors.starting"), systemImage: "arrow.down.to.line")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(slicing.sortedColorChanges) { change in
                    HStack(spacing: 12) {
                        Image(systemName: "paintpalette.fill")
                            .foregroundStyle(Theme.accent)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(change.color)
                                .font(.subheadline.weight(.medium))
                            Text(L.t("colors.from_layer") + " \(change.layer)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Spacer()
                    }
                }
                .onDelete { slicing.removeColorChanges(at: $0) }
            }
        } header: {
            Text(localized: "colors.plan")
        } footer: {
            if !slicing.colorChanges.isEmpty {
                Text(localized: "colors.plan.hint")
            }
        }
    }

    // MARK: - Adding one

    private var adder: some View {
        Section {
            HStack {
                Text(localized: "colors.layer")
                    .font(.subheadline)
                Spacer()
                TextField("", text: $layerText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 90)
            }

            TextField(L.t("colors.name"), text: $colorName)
                .textInputAutocapitalization(.never)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Self.common, id: \.self) { name in
                        Button(name) { colorName = name }
                            .font(.caption)
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                    }
                }
                .padding(.vertical, 2)
            }

            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                add()
            } label: {
                Label(L.t("colors.add"), systemImage: "plus.circle.fill")
            }
            .disabled(layerText.isEmpty || colorName.trimmingCharacters(in: .whitespaces).isEmpty)
        } header: {
            Text(localized: "colors.add.section")
        } footer: {
            Text(localized: "colors.layer.hint")
        }
    }

    private func add() {
        guard let layer = Int(layerText.trimmingCharacters(in: .whitespaces)) else {
            problem = L.t("colors.error.not_a_number")
            return
        }
        // The same two refusals the backend makes, made here where the layer
        // the person typed is still on screen next to the reason.
        guard layer >= 2 else {
            problem = L.t("colors.error.first_layer")
            return
        }
        guard !slicing.colorChanges.contains(where: { $0.layer == layer }) else {
            problem = L.t("colors.error.duplicate")
            return
        }
        slicing.addColorChange(layer: layer, color: colorName)
        layerText = ""
        colorName = ""
        problem = nil
        Haptics.impact(.light)
    }

    // MARK: - The macro this depends on

    /// Klipper has no colour-change command. Each stop calls a COLOR_CHANGE
    /// macro, and a call to a macro that is not installed does not print in one
    /// colour - it ends the print with "Unknown command", hours in.
    ///
    /// The backend refuses the slice in that case, which is the guarantee. This
    /// says so beforehand, while there is still something to do about it.
    @ViewBuilder
    private var macroWarning: some View {
        if !slicing.colorChanges.isEmpty, calibration.macros != nil, !hasColorChangeMacro {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label(L.t("colors.macro.missing"), systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.danger)
                    Text(localized: "colors.macro.missing.body")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    NavigationLink {
                        MacroSuggestionsView()
                    } label: {
                        Label(L.t("colors.macro.open"), systemImage: "wrench.and.screwdriver")
                            .font(.subheadline)
                    }
                }
            }
        }
    }

    private var hasColorChangeMacro: Bool {
        calibration.macros?.macros.first { $0.name == "COLOR_CHANGE" }?.conflicts ?? false
    }
}
