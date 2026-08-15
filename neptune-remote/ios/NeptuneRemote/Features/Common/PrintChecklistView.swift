import SwiftUI

/// Safety checklist shown before a print is started remotely.
///
/// Every item must be ticked. It can only be skipped from Developer settings,
/// and never automatically.
struct PrintChecklistView: View {
    let onConfirm: () -> Void

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var printer: PrinterStore
    @Environment(\.dismiss) private var dismiss

    @State private var checked: Set<String> = []

    private var allChecked: Bool {
        PowerSafety.printChecklistKeys.allSatisfy { checked.contains($0) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List {
                    Section {
                        ForEach(PowerSafety.printChecklistKeys, id: \.self) { key in
                            Button {
                                toggle(key)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: checked.contains(key)
                                          ? "checkmark.circle.fill" : "circle")
                                        .font(.title3)
                                        .foregroundStyle(checked.contains(key) ? Theme.printing : .secondary)
                                    Text(localized: key)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                }
                            }
                        }
                    } header: {
                        Text(localized: "checklist.header")
                    } footer: {
                        Text(localized: "checklist.footer")
                    }

                    if printer.power.state == .off {
                        Section {
                            Label(L.t("checklist.power_off_warning"), systemImage: "bolt.slash.fill")
                                .foregroundStyle(Theme.paused)
                                .font(.footnote)
                        }
                    }

                    if !printer.snapshot.isReady {
                        Section {
                            Label(L.t("error.klipper_not_ready"), systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(Theme.danger)
                                .font(.footnote)
                        }
                    }
                }

                Button {
                    Haptics.success()
                    onConfirm()
                } label: {
                    Label(L.t("checklist.start_print"), systemImage: "printer.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!allChecked)
                .padding()
            }
            .navigationTitle(L.t("checklist.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L.t("common.cancel")) { dismiss() }
                }
            }
        }
    }

    private func toggle(_ key: String) {
        if checked.contains(key) {
            checked.remove(key)
        } else {
            checked.insert(key)
            Haptics.selection()
        }
    }
}
