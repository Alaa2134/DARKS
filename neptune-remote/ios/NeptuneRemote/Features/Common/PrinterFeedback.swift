import SwiftUI

/// Shows what the printer said back, from wherever you were standing.
///
/// Every command in this app records its outcome on `PrinterStore` - a failure
/// on `lastError`, a note on `lastMessage`. Three screens displayed the first
/// one and **nothing at all displayed the second**, so a command sent from the
/// temperature screen, the speed screen, a calibration screen or a card could
/// be rejected by Klipper and leave no trace anywhere.
///
/// That is how "I press print and nothing happens" happened, and fixing it one
/// screen at a time would only mean the next screen someone adds has the bug
/// again. So it is presented once, at the root, above every tab.
///
/// Errors stay until dismissed or until the next command succeeds - `send`
/// clears `lastError` on success, so the banner disappears the moment the
/// printer is answering again. Notes fade on their own: "started benchy.gcode"
/// does not need acknowledging.
struct PrinterFeedback: ViewModifier {
    @EnvironmentObject private var printer: PrinterStore

    /// Long enough to read a clamped-temperature note in a second language,
    /// short enough not to sit over the tab bar.
    private static let noteSeconds: UInt64 = 5

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    if let error = printer.lastError {
                        banner(
                            text: error.localizedDescription,
                            symbol: "exclamationmark.triangle.fill",
                            tint: Theme.danger
                        ) {
                            printer.lastError = nil
                        }
                    }
                    if let message = printer.lastMessage {
                        banner(
                            text: message,
                            symbol: "info.circle.fill",
                            tint: Theme.accent
                        ) {
                            printer.lastMessage = nil
                        }
                        .task(id: message) {
                            try? await Task.sleep(nanoseconds: Self.noteSeconds * 1_000_000_000)
                            guard !Task.isCancelled else { return }
                            // Only clear the note this task was started for; a
                            // newer one must get its own full time on screen.
                            if printer.lastMessage == message { printer.lastMessage = nil }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 6)
                .animation(.easeOut(duration: 0.25), value: printer.lastError)
                .animation(.easeOut(duration: 0.25), value: printer.lastMessage)
            }
    }

    private func banner(
        text: String,
        symbol: String,
        tint: Color,
        onDismiss: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel(L.t("common.dismiss"))
        }
        .padding(12)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .stroke(tint.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

extension View {
    /// Presents printer errors and notes above everything else in the app.
    func printerFeedback() -> some View { modifier(PrinterFeedback()) }
}
