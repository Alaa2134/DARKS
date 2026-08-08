import Charts
import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var history: HistoryStore

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                if let error = history.lastError {
                    ErrorBanner(
                        message: error.localizedDescription,
                        onRetry: { Task { await history.load() } },
                        onDismiss: { history.lastError = nil }
                    )
                }

                statsCard
                if !history.entries.isEmpty {
                    breakdownCard
                }
                entriesCard
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .background(Theme.pageFill)
        .navigationTitle(L.t("history.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await history.load() }
        .refreshable { await history.load() }
    }

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    private var statsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader("history.statistics", systemImage: "chart.bar.fill")
            LazyVGrid(columns: columns, spacing: 14) {
                StatTile(titleKey: "history.total", value: "\(history.stats.totalPrints)",
                         systemImage: "printer.fill")
                StatTile(titleKey: "history.successful", value: "\(history.stats.successful)",
                         systemImage: "checkmark.seal.fill", tint: Theme.printing)
                StatTile(titleKey: "history.failed", value: "\(history.stats.failed + history.stats.cancelled)",
                         systemImage: "xmark.seal.fill", tint: Theme.danger)
                StatTile(titleKey: "history.success_rate", value: Format.percent(history.successRate),
                         systemImage: "percent")
                StatTile(titleKey: "history.total_hours",
                         value: String(format: "%.1f h", history.stats.totalPrintSeconds / 3600),
                         systemImage: "clock.fill")
                StatTile(titleKey: "history.filament",
                         value: Format.meters(history.totalFilamentMeters),
                         systemImage: "scalemass.fill")
            }
        }
        .card()
    }

    private var breakdownCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("history.breakdown", systemImage: "chart.pie.fill")
            Chart {
                BarMark(
                    x: .value("count", history.stats.successful),
                    y: .value("result", L.t("history.result.completed"))
                )
                .foregroundStyle(Theme.printing)
                BarMark(
                    x: .value("count", history.stats.cancelled),
                    y: .value("result", L.t("history.result.cancelled"))
                )
                .foregroundStyle(Theme.paused)
                BarMark(
                    x: .value("count", history.stats.failed),
                    y: .value("result", L.t("history.result.error"))
                )
                .foregroundStyle(Theme.danger)
            }
            .frame(height: 120)
        }
        .card()
    }

    private var entriesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("history.recent", systemImage: "clock.arrow.circlepath")

            if history.entries.isEmpty {
                EmptyStateView(
                    titleKey: "history.empty.title",
                    messageKey: "history.empty.message",
                    systemImage: "clock.arrow.circlepath"
                )
            } else {
                ForEach(history.entries) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        HistoryRow(entry: entry)
                        if let used = entry.filamentUsedMM {
                            HStack(spacing: 12) {
                                Label(Format.meters(used / 1000), systemImage: "scalemass")
                                if let nozzle = entry.nozzleTemp {
                                    Label(Format.temperatureShort(nozzle), systemImage: "flame")
                                }
                                if let profile = entry.speedProfile {
                                    Label(profile, systemImage: "speedometer")
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        if !entry.note.isEmpty {
                            Text(entry.note)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .contextMenu {
                        Button(role: .destructive) {
                            Task { await history.delete(entry) }
                        } label: {
                            Label(L.t("common.delete"), systemImage: "trash")
                        }
                    }

                    if entry.id != history.entries.last?.id { Divider() }
                }
            }
        }
        .card()
    }
}
