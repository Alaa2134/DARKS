import SwiftUI

/// Finds out why the probe is not working, instead of guessing.
///
/// "The probe doesn't work" is four separate faults, and Klipper reports every
/// one of them the same way - homing fails. They are told apart by two readings:
/// what the probe says with nothing touching it, and what it says with something
/// held against it.
///
/// ```
/// at rest    pressed     what it is
/// open       triggered   working
/// triggered  triggered   stuck on, or the pin needs `!`
/// open       open        never fires - unplugged, dead, or the wrong pin
/// triggered  open        wired backwards
/// ```
///
/// The third test answers a different question: the probe fires, but not in the
/// same place twice. `PROBE_ACCURACY` measures that, and its spread is what
/// `samples_tolerance` has to live with - which is exactly the number that was
/// set too tight on this printer and left it unable to home at all.
struct ProbeCheckView: View {
    @EnvironmentObject private var doctor: DoctorStore
    @EnvironmentObject private var printer: PrinterStore

    @State private var copied = false

    private var wiring: ProbeDiagnosis? { doctor.probeWiring }
    private var accuracy: ProbeDiagnosis? { doctor.probeAccuracy }
    private var isHomed: Bool { printer.snapshot.hasHomedAll }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                if let error = doctor.lastError {
                    ErrorBanner(
                        message: error.localizedDescription,
                        onDismiss: { doctor.lastError = nil }
                    )
                }

                intro
                wiringCard

                // The accuracy test only makes sense once the probe is known to
                // fire at all: dropping the toolhead ten times to measure a
                // sensor that never triggers is a nozzle into a bed.
                if wiring?.ok == true { accuracyCard }
            }
            .padding(Theme.spacing)
        }
        .background(Theme.pageFill)
        .navigationTitle(L.t("probe.title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("probe.title", systemImage: "sensor.tag.radiowaves.forward")
            Text(localized: "probe.intro")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }

    // MARK: - Steps 1 and 2: the wiring

    private var wiringCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("probe.wiring.title", systemImage: "cable.connector")

            if let wiring {
                result(wiring)
            } else {
                Text(localized: "probe.wiring.explain")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Neither button moves an axis or heats anything - both only read a
            // pin - so neither needs a confirmation.
            Button {
                Task { await doctor.checkProbeWiring(pressed: false) }
            } label: {
                Label(L.t("probe.read_at_rest"), systemImage: "1.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(doctor.isCheckingProbe)

            if wiring != nil {
                Text(localized: "probe.press_hint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    Task { await doctor.checkProbeWiring(pressed: true) }
                } label: {
                    Label(L.t("probe.read_pressed"), systemImage: "2.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(doctor.isCheckingProbe)
            }
        }
        .card()
    }

    // MARK: - Step 3: repeatability

    private var accuracyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("probe.accuracy.title", systemImage: "scope")

            Text(localized: "probe.accuracy.explain")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let accuracy {
                if let numbers = accuracy.accuracy { measurements(numbers) }
                result(accuracy)
            }

            // Unlike the two above, this one drops the toolhead onto the bed ten
            // times. Klipper refuses it unhomed, so the button does too rather
            // than sending a command that comes back as an error.
            if !isHomed {
                Label(L.t("probe.accuracy.needs_home"), systemImage: "house")
                    .font(.caption)
                    .foregroundStyle(Theme.paused)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                Task { await doctor.measureProbeAccuracy() }
            } label: {
                Label(L.t("probe.accuracy.run"), systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(doctor.isCheckingProbe || !isHomed)
        }
        .card()
    }

    private func measurements(_ numbers: ProbeAccuracy) -> some View {
        VStack(spacing: 6) {
            measurement("probe.accuracy.range", String(format: "%.3f mm", numbers.range))
            measurement("probe.accuracy.deviation", String(format: "%.4f mm", numbers.deviation))
            measurement("probe.accuracy.median", String(format: "%.3f mm", numbers.median))
        }
        .padding(10)
        .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func measurement(_ key: String, _ value: String) -> some View {
        HStack {
            Text(localized: key).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption.weight(.semibold)).monospacedDigit()
        }
    }

    // MARK: - Verdict

    private func result(_ diagnosis: ProbeDiagnosis) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                diagnosis.title,
                systemImage: diagnosis.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(diagnosis.ok ? Theme.printing : Theme.danger)
            .fixedSize(horizontal: false, vertical: true)

            Text(diagnosis.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(diagnosis.fixes, id: \.self) { fix in
                HStack(alignment: .top, spacing: 6) {
                    Text(verbatim: "•").font(.caption)
                    Text(fix)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !diagnosis.suggestedConfig.isEmpty {
                configSuggestion(diagnosis.suggestedConfig)
            }
        }
    }

    /// The config change, as text to copy.
    ///
    /// Not a button that applies it. This app has never written printer.cfg on
    /// its own and does not start here: a wrong pin polarity written by an app
    /// is a nozzle driven into a bed by an app.
    private func configSuggestion(_ config: [String: [String: String]]) -> some View {
        let text = config
            .sorted { $0.key < $1.key }
            .map { section, options in
                "[\(section)]\n" + options
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key): \($0.value)" }
                    .joined(separator: "\n")
            }
            .joined(separator: "\n\n")

        return VStack(alignment: .leading, spacing: 6) {
            Text(localized: "probe.suggested_change")
                .font(.caption.weight(.semibold))
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            Button {
                UIPasteboard.general.string = text
                copied = true
                Haptics.impact(.light)
            } label: {
                Label(
                    L.t(copied ? "common.copied" : "probe.copy"),
                    systemImage: copied ? "checkmark" : "doc.on.doc"
                )
                .font(.caption)
            }
            Text(localized: "probe.apply_yourself")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
