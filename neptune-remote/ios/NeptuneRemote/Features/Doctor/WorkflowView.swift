import SwiftUI

/// Drives any guided calibration workflow: the step list, the running step, and
/// whatever that step needs from the person.
///
/// The app never asks you to remember G28, PROBE_CALIBRATE, TESTZ,
/// SCREWS_TILT_CALCULATE, BED_MESH_CALIBRATE or SAVE_CONFIG - the workflow
/// issues them, and each one goes through the backend's safety engine.
struct WorkflowView: View {
    let kind: String

    @EnvironmentObject private var doctor: DoctorStore
    @EnvironmentObject private var printer: PrinterStore
    /// So the home screen's calibration card reflects what just happened. A
    /// SAVE_CONFIG at the end of a wizard rewrites printer.cfg, and the card is
    /// read from printer.cfg - without this it keeps saying "not calibrated"
    /// after you have just calibrated it.
    @EnvironmentObject private var calibration: CalibrationStore
    @Environment(\.dismiss) private var dismiss

    @State private var showingCancelConfirm = false

    private var run: WorkflowRun? { doctor.workflow }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                if let error = doctor.lastError {
                    ErrorBanner(message: error.localizedDescription) {
                        doctor.lastError = nil
                    }
                }

                if let run {
                    statusCard(run)
                    activeStepCard(run)
                    if let screws = run.data.screws {
                        BedScrewDiagram(report: screws)
                        screwList(screws)
                    }
                    stepList(run)
                } else {
                    ProgressView().padding(.vertical, 60)
                }
            }
            .padding(Theme.spacing)
        }
        .background(Theme.pageFill)
        .onChange(of: run?.finished ?? false) { _, finished in
            if finished { Task { await calibration.loadStatus() } }
        }
        .navigationTitle(run?.title ?? L.t("workflow.\(kind)"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(role: .destructive) {
                    showingCancelConfirm = true
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .disabled(run?.finished ?? true)
            }
        }
        .safeAreaInset(edge: .bottom) {
            EmergencyStopButton {
                Task { await printer.emergencyStop() }
            }
            .padding(.horizontal, Theme.spacing)
            .padding(.bottom, 8)
            .background(.ultraThinMaterial)
        }
        .confirmationDialog(
            L.t("workflow.cancel.confirm"),
            isPresented: $showingCancelConfirm,
            titleVisibility: .visible
        ) {
            Button(L.t("workflow.cancel"), role: .destructive) {
                Task {
                    await doctor.cancelWorkflow()
                    dismiss()
                }
            }
            Button(L.t("common.cancel"), role: .cancel) {}
        }
        .task {
            if doctor.workflow == nil {
                _ = await doctor.startWorkflow(kind)
            }
        }
    }

    // MARK: - Status

    private func statusCard(_ run: WorkflowRun) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: DoctorCatalog.icon(forWorkflow: run.kind))
                    .font(.title3)
                    .foregroundStyle(run.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(localized: "workflow.state.\(run.state)")
                        .font(.subheadline.weight(.semibold))
                    if !run.message.isEmpty {
                        Text(run.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            ProgressView(value: run.progress).tint(run.color)
        }
        .card(tint: run.color)
    }

    // MARK: - The active step

    @ViewBuilder
    private func activeStepCard(_ run: WorkflowRun) -> some View {
        if run.finished {
            finishedCard(run)
        } else if let step = run.activeStep {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(step.title)
                        .font(.headline)
                    if !step.description.isEmpty {
                        Text(step.description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // The Z Offset wizard's adjust step gets its own controls.
                if step.id == "adjust" || step.id == "z_adjust" {
                    ZOffsetControls()
                }

                if !step.message.isEmpty {
                    Text(step.message)
                        .font(.caption)
                        .foregroundStyle(step.isFailed ? Theme.danger : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                controls(run, step)
            }
            .card()
        }
    }

    @ViewBuilder
    private func controls(_ run: WorkflowRun, _ step: WorkflowStep) -> some View {
        if run.failed {
            VStack(spacing: 10) {
                Label(L.t("workflow.stopped"), systemImage: "hand.raised.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    Task { await doctor.repeatStep() }
                } label: {
                    primaryLabel(L.t("workflow.retry"), tint: Theme.accent)
                }
                .buttonStyle(.plain)
            }
        } else if step.manual {
            VStack(spacing: 10) {
                Button {
                    Task { await doctor.confirmStep() }
                } label: {
                    primaryLabel(L.t("workflow.done_continue"), tint: Theme.printing)
                }
                .buttonStyle(.plain)

                // Measure-and-turn loops back rather than moving on.
                if step.id == "adjust" || step.id == "screws_adjust" {
                    Button {
                        Task {
                            await doctor.goToStep(run.kind == "full_bed_calibration" ? "screws" : "measure")
                            await doctor.advance(force: true)
                        }
                    } label: {
                        secondaryLabel(L.t("workflow.measure_again"), icon: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                }
            }
        } else if run.needsUser {
            // A warning the person must acknowledge before it runs.
            VStack(spacing: 10) {
                Button {
                    Task { await doctor.advance(force: true) }
                } label: {
                    primaryLabel(L.t("workflow.continue_anyway"), tint: Theme.paused)
                }
                .buttonStyle(.plain)
                .disabled(doctor.isAdvancing)

                Button {
                    Task { await doctor.repeatStep() }
                } label: {
                    secondaryLabel(L.t("workflow.recheck"), icon: "arrow.clockwise")
                }
                .buttonStyle(.plain)
            }
        } else {
            Button {
                Task { await doctor.advance() }
            } label: {
                HStack(spacing: 8) {
                    if doctor.isAdvancing {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: "play.fill")
                    }
                    Text(localized: "workflow.run_step")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(doctor.isAdvancing)
        }
    }

    private func finishedCard(_ run: WorkflowRun) -> some View {
        VStack(spacing: 12) {
            Image(systemName: run.failed ? "xmark.octagon.fill" : "checkmark.seal.fill")
                .font(.largeTitle)
                .foregroundStyle(run.color)
            Text(localized: run.failed ? "workflow.failed" : "workflow.complete")
                .font(.headline)
            if !run.message.isEmpty {
                Text(run.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(L.t("common.close")) {
                Task {
                    await doctor.cancelWorkflow()
                    dismiss()
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .card(tint: run.color)
    }

    private func primaryLabel(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(tint, in: RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous))
            .foregroundStyle(.white)
    }

    private func secondaryLabel(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.subheadline.weight(.medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Theme.pageFill, in: RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous))
    }

    // MARK: - Screw list and step list

    private func screwList(_ report: ScrewsTiltReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("screws.adjustments", systemImage: "dial.medium")
            ForEach(report.screws) { screw in
                HStack(spacing: 10) {
                    Image(systemName: screw.isBase ? "target" : (screw.isClockwise ? "arrow.clockwise" : "arrow.counterclockwise"))
                        .foregroundStyle(screw.color)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(screwName(screw))
                            .font(.subheadline.weight(.medium))
                        Text(screw.instruction)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if !screw.isBase, screw.adjusted {
                        Text(screw.clock)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .card()
    }

    private func screwName(_ screw: ScrewAdjustment) -> String {
        if let key = DoctorCatalog.screwLabelKeys[screw.positionKey] {
            return L.t(key)
        }
        return screw.name
    }

    private func stepList(_ run: WorkflowRun) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("workflow.steps", systemImage: "list.bullet")
                .padding(.bottom, 10)
            ForEach(Array(run.steps.enumerated()), id: \.element.id) { index, step in
                HStack(spacing: 12) {
                    Image(systemName: step.symbol)
                        .foregroundStyle(step.color)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(step.title)
                            .font(.subheadline)
                            .foregroundStyle(index == run.current ? .primary : .secondary)
                        if !step.commands.isEmpty {
                            Text(step.commands.joined(separator: "  ·  "))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 7)
            }
        }
        .card()
    }
}

// MARK: - Z offset stepping

/// The nudge buttons for PROBE_CALIBRATE.
///
/// Three different numbers get confused constantly, so they are labelled
/// separately and never mixed: the live Z coordinate, the temporary TESTZ
/// nudges, and the probe z_offset Klipper calculates at the end.
struct ZOffsetControls: View {
    @EnvironmentObject private var doctor: DoctorStore
    @EnvironmentObject private var printer: PrinterStore

    @State private var applied: Double = 0

    private let coarse: [Double] = [-1.0, -0.5, -0.1]
    private let fine: [Double] = [-0.05, -0.01]
    private let up: [Double] = [0.01, 0.05, 0.1]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            explanation

            VStack(spacing: 10) {
                row(coarse + fine, tint: Theme.danger)
                row(up, tint: Theme.printing)
            }

            HStack {
                Text(localized: "zoffset.applied")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%+.3f mm", applied))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
            }

            InfoRow(
                titleKey: "zoffset.current_z",
                value: Format.millimetres(printer.snapshot.z, decimals: 3)
            )
        }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(localized: "zoffset.paper_instruction")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(localized: "zoffset.sign_note")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ steps: [Double], tint: Color) -> some View {
        HStack(spacing: 8) {
            ForEach(steps, id: \.self) { step in
                Button {
                    Task {
                        if await doctor.stepZ(step) != nil {
                            applied += step
                        }
                    }
                } label: {
                    Text(String(format: "%+g", step))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous))
                        .foregroundStyle(tint)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Bed screw diagram

/// The bed seen from above, with an arrow on each screw.
struct BedScrewDiagram: View {
    let report: ScrewsTiltReport

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader("screws.diagram", systemImage: "square.dashed")
                Spacer()
                StatusPill(
                    text: L.t("screws.verdict.\(report.verdict)"),
                    color: report.color,
                    systemImage: report.level ? "checkmark" : "dial.medium"
                )
            }

            Text(localized: "screws.rear")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)

            VStack(spacing: 10) {
                ForEach(DoctorCatalog.bedLayout, id: \.self) { row in
                    HStack(spacing: 10) {
                        ForEach(row, id: \.self) { slot in
                            screwCell(slot)
                        }
                    }
                }
            }
            .padding(12)
            .background(Theme.pageFill, in: RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous))

            Text(localized: "screws.front")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)

            Text(report.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }

    @ViewBuilder
    private func screwCell(_ slot: String) -> some View {
        let screw = report.screw(at: slot)
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill((screw?.color ?? Theme.idle).opacity(0.16))
                Circle()
                    .strokeBorder((screw?.color ?? Theme.idle).opacity(0.5), lineWidth: 1.5)

                if let screw {
                    if screw.isBase {
                        Image(systemName: "target")
                            .font(.title3)
                            .foregroundStyle(screw.color)
                    } else if screw.adjusted {
                        Image(systemName: screw.isClockwise ? "arrow.clockwise" : "arrow.counterclockwise")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(screw.color)
                    } else {
                        Image(systemName: "checkmark")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Theme.printing)
                    }
                } else {
                    Image(systemName: "questionmark")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 62)

            Text(L.t(DoctorCatalog.screwLabelKeys[slot] ?? ""))
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            if let screw, !screw.isBase, screw.adjusted {
                Text(String(format: "%.2f", screw.turns))
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(screw.color)
            } else {
                Text(screw?.isBase == true ? L.t("screws.base") : "—")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
