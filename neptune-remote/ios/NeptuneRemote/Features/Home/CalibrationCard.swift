import SwiftUI

/// Whether this printer's bed is calibrated - on the first screen, not behind a
/// menu.
///
/// Every wizard this card links to already existed. What did not exist was the
/// answer: the app knew how to calibrate a Z offset and had no opinion at all
/// about whether yours was calibrated, so the only way to find out was to run
/// the wizard and see. That is the wrong way round, and it is why a person can
/// use this app for a week and still not know why their first layer is bad.
///
/// Three rows, in the order the jobs have to be done: screws, then Z offset,
/// then mesh. Not alphabetical - a mesh measured over a tilted bed encodes the
/// tilt, and levelling afterwards throws it away. The order *is* the advice.
///
/// The card disappears entirely when everything is done and nothing is stale.
/// A permanent green panel is furniture; a card that appears when something
/// needs doing is information.
struct CalibrationCard: View {
    /// Called with the workflow kind once it has really started.
    ///
    /// Navigation is the caller's, not this card's: a `.navigationDestination`
    /// declared inside a `LazyVStack` is only registered while the row that
    /// owns it happens to be built, which is exactly the kind of "the button
    /// does nothing" this app has already been bitten by once.
    let onOpen: (String) -> Void

    @EnvironmentObject private var calibration: CalibrationStore
    @EnvironmentObject private var doctor: DoctorStore

    private var status: CalibrationStatus? { calibration.status }

    var body: some View {
        if let status, !status.items.isEmpty, !status.allDone {
            VStack(alignment: .leading, spacing: 12) {
                header(status)

                ForEach(status.items) { item in
                    row(item, isNext: item.id == status.nextID)
                }

                Text(localized: "calibration.card.order")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .card()
        }
    }

    private func header(_ status: CalibrationStatus) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "ruler.fill")
                .foregroundStyle(Theme.paused)
            VStack(alignment: .leading, spacing: 2) {
                Text(localized: "calibration.card.title")
                    .font(.subheadline.weight(.semibold))
                // The one thing to do first, named. Three outstanding items is
                // a to-do list; the first of them is a next step.
                if !status.nextTitle.isEmpty {
                    Text(L.t("calibration.card.start_with") + " " + status.nextTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func row(_ item: CalibrationItem, isNext: Bool) -> some View {
        Button {
            open(item)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol(for: item))
                    .foregroundStyle(tint(for: item))
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(item.title)
                            .font(.subheadline.weight(isNext ? .semibold : .regular))
                        if isNext {
                            Text(localized: "calibration.card.next")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.accent.opacity(0.2), in: Capsule())
                        }
                    }
                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // Kept separate from the detail, and shown even on a row
                    // that is otherwise done: "the mesh is saved but nothing
                    // loads it" is not a smaller version of "no mesh", it is a
                    // different problem with a different fix.
                    ForEach(item.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(Theme.paused)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Starts the wizard, then navigates - the same order the calibration hub
    /// uses, because WorkflowView draws a run that has to exist first.
    ///
    /// A run already in progress is resumed rather than restarted: only one
    /// procedure may move the toolhead at a time, so starting a second one is
    /// refused by the backend and would surface here as an error on a tap that
    /// looks like it should just work.
    private func open(_ item: CalibrationItem) {
        if let run = doctor.workflow, !run.finished {
            onOpen(run.kind)
            return
        }
        Task {
            if await doctor.startWorkflow(item.id) {
                onOpen(item.id)
            }
        }
    }

    private func symbol(for item: CalibrationItem) -> String {
        switch item.state {
        case "done": return "checkmark.circle.fill"
        case "missing": return "xmark.circle.fill"
        case "not_applicable": return "minus.circle"
        default: return "questionmark.circle.fill"
        }
    }

    private func tint(for item: CalibrationItem) -> Color {
        switch item.state {
        case "done": return item.warnings.isEmpty ? Theme.printing : Theme.paused
        case "missing": return Theme.danger
        case "not_applicable": return .secondary
        default: return Theme.paused
        }
    }
}
