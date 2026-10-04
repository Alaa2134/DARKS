import SwiftUI

/// What a multi-colour print is going to ask you for, and when.
///
/// Shown after slicing, on a file's detail screen, and - as the card below -
/// while the printer is actually standing there waiting. The same list in all
/// three places on purpose: the plan you made is the plan you are reminded of.
struct ColorPlanList: View {
    let changes: [ColorChange]
    /// The layer the printer is on now, when there is one. Stops already passed
    /// are dimmed, which turns a list into a position.
    var currentLayer: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("colors.plan", systemImage: "paintpalette.fill")

            // The colour loaded before the print starts has no stop of its own.
            // Naming the fact - not the colour, which the app has no way to
            // know - is what makes the rows below read as "and then".
            row(
                symbol: "arrow.down.to.line",
                title: L.t("colors.starting"),
                detail: nil,
                passed: (currentLayer ?? 0) > 0
            )

            ForEach(changes.sorted { $0.layer < $1.layer }) { change in
                row(
                    symbol: "paintpalette.fill",
                    title: change.color,
                    detail: detail(for: change),
                    passed: (currentLayer ?? 0) >= change.layer
                )
            }
        }
    }

    private func detail(for change: ColorChange) -> String {
        var text = L.t("colors.from_layer") + " \(change.layer)"
        if let z = change.z {
            text += String(format: " · %.1f mm", z)
        }
        return text
    }

    private func row(symbol: String, title: String, detail: String?, passed: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: passed ? "checkmark.circle.fill" : symbol)
                .foregroundStyle(passed ? Theme.printing : Theme.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 0)
        }
        .opacity(passed ? 0.5 : 1)
    }
}

/// The printer is stopped, hot, and waiting for you to change the spool.
///
/// A colour change arrives as an ordinary pause, and "print paused" is the
/// wrong thing to read: it sounds like something went wrong, when in fact
/// nothing is wrong and nothing will happen until a person walks over. So the
/// pause is named for what it is, the colour is quoted, and Resume is right
/// there - the printer will otherwise stand there all night.
///
/// The colour comes from the printer's own display message, put there by the
/// M117 written next to each stop. That means it works for any file carrying
/// the marker, not only one sliced in this app this week.
struct ColorChangeWaitingCard: View {
    let color: String
    let onResume: () -> Void

    @State private var isResuming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "paintpalette.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.paused)
                VStack(alignment: .leading, spacing: 2) {
                    Text(localized: "colors.waiting.title")
                        .font(.subheadline.weight(.semibold))
                    Text(color)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Theme.paused)
                }
                Spacer()
            }

            Text(localized: "colors.waiting.body")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                isResuming = true
                onResume()
            } label: {
                Label(L.t("action.resume"), systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isResuming)
        }
        .card()
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .stroke(Theme.paused.opacity(0.45), lineWidth: 1.5)
        )
    }
}
