import SwiftUI

/// Sweeps the finished part off the bed - if the printer has been told how.
///
/// The card appears **only** when `EJECT_PART` exists in the user's own
/// printer.cfg. The app does not compose the motion: it runs the macro the user
/// installed after reading what it does, which is the same rule every other
/// moving command in this app follows.
///
/// The macro refuses while the printer is warm, and it is right to. A printed
/// part is held down by nothing but the temperature difference between the
/// plastic and the sheet; sweep a warm one and the toolhead is driven into
/// something still glued down.
///
/// But refusing used to be *all* this card did. It greyed the button out, said
/// "the bed is 58 degrees", and left the person to go and turn the heaters off
/// somewhere else, guess how long to wait, and come back to try again - and
/// after a cancelled print the heaters were usually still holding a target, so
/// it never cooled at all and the button never came back.
///
/// Now the wait is the feature, and the wait lives on the Pi. One tap turns the
/// heaters off and the printer sweeps the part off on its own the moment it is
/// cold enough - whether or not the phone is still awake, which is the whole
/// point: iOS suspends an app seconds after it leaves the screen.
struct EjectPartCard: View {
    @EnvironmentObject private var printer: PrinterStore

    @State private var showingConfirm = false

    private var macro: PrinterCapabilities.MacroSpec? {
        printer.capabilities.macro(named: "EJECT_PART")
    }

    private var snapshot: PrinterSnapshot { printer.snapshot }
    private var eject: EjectState { printer.ejectState }

    /// Printing is the one blocker no amount of waiting fixes, so it is kept
    /// apart from the ones that just need time.
    private var isPrinting: Bool { snapshot.isActive }

    private var bedTooHot: Bool { snapshot.bedActual > eject.maxBedC }
    private var nozzleTooHot: Bool { snapshot.nozzleActual > eject.maxNozzleC }
    private var needsCooling: Bool { bedTooHot || nozzleTooHot || snapshot.bedTarget > 0 }

    var body: some View {
        if let macro {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("eject.title", systemImage: "arrow.down.to.line")

                Text(localized: "eject.explain")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if isPrinting {
                    Label(L.t("eject.blocked.printing"), systemImage: "printer.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.paused)
                } else if eject.armed {
                    armedState
                } else if needsCooling {
                    coolingState
                } else if eject.lastOutcome == "ejected" || eject.lastOutcome == "timeout" {
                    // The arm finished while nobody was looking. Saying so is
                    // the difference between a feature that worked and one that
                    // appears to have done nothing.
                    Label(eject.lastMessage, systemImage: eject.lastOutcome == "ejected"
                          ? "checkmark.circle.fill" : "clock.badge.xmark")
                        .font(.caption)
                        .foregroundStyle(eject.lastOutcome == "ejected" ? Theme.printing : Theme.paused)
                        .fixedSize(horizontal: false, vertical: true)
                }

                action(macro)
            }
            .card()
            .task { await printer.refreshEjectState() }
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

    // MARK: - Waiting

    /// Armed: heaters are off and the printer will sweep on its own.
    ///
    /// The countdown appears only when it was actually measured. An invented
    /// number would be worse than none, because the point of arming is that the
    /// person walks away and trusts the printer to finish the job.
    private var armedState: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(localized: "eject.waiting.title")
                    .font(.subheadline.weight(.medium))
                Spacer()
                if let wait = printer.ejectWaitEstimate {
                    Text(verbatim: "~" + Format.duration(wait))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .monospacedDigit()
                }
            }

            temperatureRow(
                titleKey: "temperature.bed",
                actual: snapshot.bedActual,
                target: eject.maxBedC
            )
            temperatureRow(
                titleKey: "temperature.nozzle",
                actual: snapshot.nozzleActual,
                target: eject.maxNozzleC
            )

            if let rate = printer.bedCoolingRate, rate > 0.2 {
                Text(L.t("eject.cooling_rate", rate))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Text(localized: "eject.waiting.note")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Not armed, but too hot: say what is in the way before it is tapped.
    private var coolingState: some View {
        VStack(alignment: .leading, spacing: 6) {
            if bedTooHot {
                blocker(L.t("eject.blocked.bed_hot", snapshot.bedActual, eject.maxBedC),
                        symbol: "thermometer.medium")
            }
            if nozzleTooHot {
                blocker(L.t("eject.blocked.nozzle_hot", snapshot.nozzleActual),
                        symbol: "thermometer.high")
            }
            if snapshot.bedTarget > 0 || snapshot.nozzleTarget > 0 {
                // Cold *now* is not the same as cooling. A held target means it
                // is on its way back up, and this is the reason the button used
                // to look permanently stuck.
                blocker(L.t("eject.blocked.heaters_on"), symbol: "flame.fill")
            }
        }
    }

    private func blocker(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(Theme.paused)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func temperatureRow(titleKey: String, actual: Double, target: Double) -> some View {
        HStack {
            Text(localized: titleKey)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(String(format: "%.0f° → %.0f°", actual, target))
                .font(.caption.weight(.medium))
                .foregroundStyle(actual <= target ? Theme.printing : .primary)
                .monospacedDigit()
        }
    }

    // MARK: - The button

    @ViewBuilder
    private func action(_ macro: PrinterCapabilities.MacroSpec) -> some View {
        if eject.armed {
            Button(role: .cancel) {
                Task { await printer.cancelEjectArm() }
            } label: {
                Label(L.t("eject.waiting.cancel"), systemImage: "xmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        } else if needsCooling && !isPrinting {
            // The button that used to be greyed out. Same place, same tap - it
            // just does the waiting for you instead of telling you to.
            Button {
                Task { await printer.armEject() }
            } label: {
                Label(L.t("eject.cool_then_eject"), systemImage: "snowflake")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(printer.isBusy)
        } else {
            Button {
                showingConfirm = true
            } label: {
                Label(L.t("eject.action"), systemImage: "arrow.down.to.line")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isPrinting || printer.isBusy)
        }
    }
}
