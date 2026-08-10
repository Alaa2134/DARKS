import SwiftUI

/// Sweeps the finished part off the bed - if the printer has been told how.
///
/// The card appears **only** when `EJECT_PART` exists in the user's own
/// printer.cfg. The app does not compose the motion: it runs the macro the user
/// installed after reading what it does, which is the same rule every other
/// moving command in this app follows.
///
/// The conditions below are the macro's own guards, checked here as well. The
/// macro will refuse anyway - but a button that greys out and says *why* is a
/// different experience from one that looks fine, gets tapped, and returns an
/// error from Klipper thirty seconds later.
struct EjectPartCard: View {
    @EnvironmentObject private var printer: PrinterStore

    @State private var showingConfirm = false

    /// The bed temperature the generated macro refuses above. Adhesion is what
    /// has to let go first, and it only lets go as the bed cools.
    private static let maxBedC: Double = 40

    private var macro: PrinterCapabilities.MacroSpec? {
        printer.capabilities.macro(named: "EJECT_PART")
    }

    private var snapshot: PrinterSnapshot { printer.snapshot }

    /// Why the sweep cannot run now, in the order a person would hit them.
    private var blockers: [String] {
        var reasons: [String] = []
        if snapshot.isActive {
            reasons.append(L.t("eject.blocked.printing"))
        }
        if snapshot.bedActual > Self.maxBedC {
            reasons.append(L.t("eject.blocked.bed_hot", snapshot.bedActual, Self.maxBedC))
        }
        let minExtrude = printer.capabilities.primaryExtruder?.minExtrudeTemp ?? 170
        if snapshot.nozzleActual > minExtrude {
            reasons.append(L.t("eject.blocked.nozzle_hot", snapshot.nozzleActual))
        }
        return reasons
    }

    var body: some View {
        if let macro {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("eject.title", systemImage: "arrow.down.to.line")

                Text(localized: "eject.explain")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(blockers, id: \.self) { reason in
                    Label(reason, systemImage: "clock.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.paused)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    showingConfirm = true
                } label: {
                    Label(L.t("eject.action"), systemImage: "arrow.down.to.line")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!blockers.isEmpty || printer.isBusy)
            }
            .card()
            .confirmationDialog(
                L.t("eject.confirm.title"),
                isPresented: $showingConfirm,
                titleVisibility: .visible
            ) {
                Button(L.t("eject.action"), role: .destructive) {
                    Task { await printer.runMacro(macro) }
                }
                Button(L.t("common.cancel"), role: .cancel) {}
            } message: {
                Text(localized: "eject.confirm.message")
            }
        }
    }
}
