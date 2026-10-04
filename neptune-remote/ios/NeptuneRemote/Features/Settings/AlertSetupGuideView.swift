import SwiftUI
import UIKit

/// How to make alerts arrive when the app is closed.
///
/// This is a settings screen only in the sense that it explains work done
/// elsewhere: the credentials live in `config.yaml` on the Raspberry Pi and
/// never travel to the phone. A sideloaded unsigned app cannot receive Apple
/// push notifications at all, so the Pi pushing to a service the phone already
/// subscribes to is not a workaround - it is the only path that exists.
struct AlertSetupGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Text(localized: "alerts.setup.intro")
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                ForEach(1...5, id: \.self) { step in
                    stepRow(step, prefix: "alerts.setup.ntfy.step")
                }
                CopyableRow(
                    label: L.t("alerts.setup.config_path"),
                    value: "~/neptune-remote/raspberry-pi/config.yaml"
                )
            } header: {
                Text(localized: "alerts.setup.ntfy")
            } footer: {
                Text(localized: "alerts.setup.ntfy.footer")
            }

            Section {
                ForEach(1...4, id: \.self) { step in
                    stepRow(step, prefix: "alerts.setup.heartbeat.step")
                }
            } header: {
                Text(localized: "alerts.setup.heartbeat")
            } footer: {
                Text(localized: "alerts.setup.heartbeat.footer")
            }

            Section {
                Text(localized: "alerts.setup.limits")
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text(localized: "alerts.setup.limits.title")
            }
        }
        .navigationTitle(L.t("alerts.setup.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(L.t("common.done")) { dismiss() }
            }
        }
    }

    private func stepRow(_ step: Int, prefix: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(step)")
                .font(.caption.weight(.bold))
                .frame(width: 20, height: 20)
                .background(Theme.accent.opacity(0.18), in: Circle())
            Text(localized: "\(prefix)\(step)")
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A value worth copying rather than retyping on a phone keyboard.
struct CopyableRow: View {
    let label: String
    let value: String

    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = value
            copied = true
            Haptics.success()
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                copied = false
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copied ? Theme.printing : Theme.accent)
            }
        }
        .buttonStyle(.plain)
    }
}
