import SwiftUI

/// A queue that never starts anything on its own.
///
/// The only way the next job begins is: the user confirms the bed is clear,
/// then taps start. The backend consumes that confirmation on every start, so
/// it can never carry over to a second job.
struct QueueView: View {
    @EnvironmentObject private var inventory: InventoryStore
    @EnvironmentObject private var printer: PrinterStore

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                if let error = inventory.lastError {
                    ErrorBanner(message: error.localizedDescription) {
                        Task { await inventory.loadQueue() }
                    } onDismiss: {
                        inventory.lastError = nil
                    }
                }

                bedClearCard

                if inventory.queue.jobs.isEmpty {
                    EmptyStateView(
                        titleKey: "queue.empty",
                        messageKey: "queue.empty.hint",
                        systemImage: "list.number"
                    )
                } else {
                    totals
                    jobs
                }
            }
            .padding(Theme.spacing)
        }
        .background(Theme.pageFill)
        .navigationTitle(L.t("queue.title"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await inventory.loadQueue() }
        .task { await inventory.loadQueue() }
    }

    private var bedClearCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: Binding(
                get: { inventory.queue.bedClear },
                set: { value in Task { await inventory.setBedClear(value) } }
            )) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(localized: "queue.bed_clear")
                        .font(.subheadline.weight(.medium))
                    Text(localized: "queue.bed_clear.explain")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            Button {
                Task { await inventory.startNext() }
            } label: {
                HStack(spacing: 8) {
                    if inventory.isBusy {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: "play.fill")
                    }
                    Text(localized: "queue.start_next")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    inventory.canStartNext ? Theme.accent : Theme.idle.opacity(0.25),
                    in: RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous)
                )
                .foregroundStyle(inventory.canStartNext ? .white : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!inventory.canStartNext || inventory.isBusy)

            if !inventory.canStartNext, !inventory.queueBlockedKey.isEmpty {
                Label(L.t(inventory.queueBlockedKey), systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private var totals: some View {
        Text(L.t(
            "queue.total",
            inventory.queue.waiting.count,
            Format.duration(inventory.queue.totalSeconds),
            String(Int(inventory.queue.totalFilamentGrams.rounded()))
        ))
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var jobs: some View {
        VStack(spacing: 10) {
            ForEach(Array(inventory.queue.jobs.enumerated()), id: \.element.id) { index, job in
                HStack(spacing: 12) {
                    Text("\(index + 1)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(job.displayName.isEmpty ? job.gcodePath : job.displayName)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(2)
                        HStack(spacing: 8) {
                            if !job.material.isEmpty {
                                Text(job.material)
                            }
                            if let seconds = job.estimatedSeconds {
                                Text(Format.duration(seconds))
                            }
                            if let grams = job.filamentGrams {
                                Text(Format.grams(grams))
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)

                    Button {
                        Task { await inventory.remove(job) }
                    } label: {
                        Image(systemName: "minus.circle")
                            .foregroundStyle(Theme.danger)
                    }
                    .buttonStyle(.plain)
                }
                .card(tint: index == 0 ? Theme.accent : .clear)
            }
        }
    }
}
