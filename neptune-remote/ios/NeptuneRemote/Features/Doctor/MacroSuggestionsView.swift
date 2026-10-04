import SwiftUI

/// Macros written for this printer, from this printer's own config.
///
/// The backend reads the live `printer.cfg` and generates PRINT_START,
/// PRINT_END and EJECT_PART with every coordinate taken from the configured
/// travel - no build volume, no purge position and no park position borrowed
/// from someone else's machine.
///
/// **Nothing here is installed by the app.** Copying it into printer.cfg is a
/// deliberate act by the person who owns the printer, which is the whole reason
/// the reasoning is shown next to each macro rather than hidden behind a button
/// that says "apply".
struct MacroSuggestionsView: View {
    @EnvironmentObject private var calibration: CalibrationStore
    @EnvironmentObject private var printer: PrinterStore

    @State private var copied: String?

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                if let error = calibration.lastError {
                    ErrorBanner(
                        message: error.localizedDescription,
                        onRetry: { Task { await calibration.loadMacros() } },
                        onDismiss: { calibration.lastError = nil }
                    )
                }

                intro

                if calibration.isLoadingMacros && calibration.macros == nil {
                    ProgressView().padding(.vertical, 60)
                }

                ForEach(calibration.macros?.macros ?? []) { macro in
                    card(macro)
                }

                if let slicer = calibration.macros?.slicer, !slicer.startGCode.isEmpty {
                    slicerCard(slicer)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .background(Theme.pageFill)
        .navigationTitle(L.t("macros.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await calibration.loadMacros() }
        .refreshable { await calibration.loadMacros() }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("macros.title", systemImage: "chevron.left.forwardslash.chevron.right")
            Text(localized: "macros.intro")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }

    @ViewBuilder
    private func card(_ macro: MacroSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(macro.name)
                    .font(.subheadline.weight(.semibold).monospaced())
                Spacer()
                if macro.conflicts {
                    Label(L.t("macros.exists"), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(Theme.paused)
                }
            }

            // A refusal is a result, not an empty state: it says the backend
            // would have had to guess, and why it would not.
            if !macro.blockers.isEmpty {
                ForEach(macro.blockers, id: \.self) { blocker in
                    Label(blocker, systemImage: "xmark.octagon.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !macro.gcode.isEmpty {
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(macro.gcode)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                }
                .background(
                    Theme.pageFill,
                    in: RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous)
                )

                Button {
                    UIPasteboard.general.string = macro.gcode
                    copied = macro.name
                    Haptics.success()
                } label: {
                    Label(
                        L.t(copied == macro.name ? "common.copied" : "macros.copy"),
                        systemImage: copied == macro.name ? "checkmark" : "doc.on.doc"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            if !macro.rationale.isEmpty {
                DisclosureGroup(L.t("macros.why")) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(macro.rationale, id: \.self) { reason in
                            Label(reason, systemImage: "checkmark.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 6)
                }
                .font(.caption)
            }
        }
        .card(tint: macro.ok ? Theme.accent : Theme.danger)
    }

    private func slicerCard(_ slicer: MacroSlicerWiring) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("macros.slicer", systemImage: "square.and.arrow.down")
            // A macro nothing calls does nothing at all, which is a state real
            // printers sit in for months.
            InfoRow(titleKey: "macros.slicer.start", value: slicer.startGCode)
            InfoRow(titleKey: "macros.slicer.end", value: slicer.endGCode)
            Text(slicer.note)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }
}
