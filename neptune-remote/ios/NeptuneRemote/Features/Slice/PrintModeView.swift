import SwiftUI

/// Choosing how to print, with the printer's answer rather than the profile's claim.
///
/// The list is not a set of presets. Each row is what that mode *becomes* on
/// this nozzle with this material - and, where the two disagree, why. A mode
/// whose speed was cut to the material's melt rate says so with both numbers,
/// because "fast" that the printer then silently slows down is worse than
/// having no modes at all.
struct PrintModeView: View {
    @Binding var selection: String?
    @EnvironmentObject private var calibration: CalibrationStore

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.spacing) {
                materialPicker

                if calibration.modes.limitsFromConfig {
                    Label(
                        L.t("mode.limits.live", Int(calibration.modes.maxAccel ?? 0)),
                        systemImage: "checkmark.seal"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                ForEach(calibration.modes.modes) { mode in
                    modeCard(mode)
                }

                if calibration.modes.modes.isEmpty, !calibration.isLoading {
                    EmptyStateView(
                        titleKey: "mode.empty",
                        messageKey: "mode.empty.hint",
                        systemImage: "slider.horizontal.3"
                    )
                }
            }
            .padding(Theme.spacing)
        }
        .background(Theme.pageFill)
        .navigationTitle(L.t("mode.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await calibration.load() }
        .refreshable { await calibration.loadModes() }
    }

    private var materialPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(localized: "mode.material")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker(L.t("mode.material"), selection: $calibration.filamentProfile) {
                ForEach(["pla", "pla_plus", "petg", "abs", "asa", "tpu"], id: \.self) { id in
                    Text(id.uppercased().replacingOccurrences(of: "_", with: " ")).tag(id)
                }
            }
            .pickerStyle(.segmented)
            Text(localized: "mode.material.hint")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .card()
    }

    private func modeCard(_ mode: PrintMode) -> some View {
        Button {
            selection = mode.id
            Haptics.impact(.light)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(mode.title)
                        .font(.headline)
                    Spacer()
                    Text(mode.timeComparison)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(mode.relativeTime <= 1 ? Theme.printing : Theme.paused)
                    if selection == mode.id {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.accent)
                    }
                }

                if !mode.descriptionAR.isEmpty {
                    Text(mode.descriptionAR)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 14) {
                    stat("mode.layer", Format.millimetres(mode.layerHeight, decimals: 2))
                    stat("mode.speed", "\(Int(mode.printSpeed)) mm/s")
                    stat("mode.walls", "\(mode.perimeters)")
                    stat("mode.infill", "\(mode.infillPercent)%")
                }

                // The finding that makes this screen worth having: a mode that
                // costs the same as a finer one buys nothing but a worse
                // surface. Given the accent treatment because it changes the
                // choice, unlike the trade-off line below it.
                ForEach(mode.notesAR, id: \.self) { note in
                    Label(note, systemImage: "lightbulb.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !mode.tradeoffAR.isEmpty {
                    Text(mode.tradeoffAR)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if mode.wasClamped {
                    DisclosureGroup(L.t("mode.clamped", mode.adjustments.count)) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(mode.adjustments) { adjustment in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(adjustment.setting): "
                                         + "\(Int(adjustment.requested)) → \(Int(adjustment.applied))")
                                        .font(.caption2.monospaced())
                                    Text(adjustment.reason)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                    .font(.caption)
                }
            }
        }
        .buttonStyle(.plain)
        .card(tint: selection == mode.id ? Theme.accent : .clear)
    }

    private func stat(_ titleKey: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(localized: titleKey)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
    }
}
