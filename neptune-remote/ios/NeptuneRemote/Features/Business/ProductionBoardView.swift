import SwiftUI

/// The factory floor: every part still to make, soonest due first, with when
/// the machine will get to it and whether that is too late.
struct ProductionBoardView: View {
    @EnvironmentObject private var business: BusinessStore

    private var board: Production { business.production }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                summary
                if board.lines.isEmpty {
                    EmptyStateView(titleKey: "business.floor.empty", messageKey: "business.floor.empty.hint",
                                   systemImage: "checkmark.seal")
                }
                ForEach(board.lines) { line in
                    lineCard(line)
                }
                Text(localized: "business.floor.hint")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Theme.spacing)
        }
        .background(Theme.pageFill)
        .navigationTitle(L.t("business.floor.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await business.load() }
        .refreshable { await business.load(force: true) }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                ProgressRing(progress: board.utilisation7d ?? 0, lineWidth: 9, tint: Theme.tide,
                             label: Format.percent(board.utilisation7d), caption: L.t("business.utilisation.7d"))
                    .frame(width: 96, height: 96)
                VStack(alignment: .leading, spacing: 6) {
                    Text(L.t("business.floor.units", board.unitsRemaining))
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                    Label(L.t("business.floor.hours", Format.duration(board.hoursRemaining * 3600)),
                          systemImage: "clock.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.emberWarm)
                    if let clear = board.projectedClear {
                        Label(L.t("business.floor.clear", Format.date(clear)), systemImage: "flag.checkered")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                HeroFigure(titleKey: "business.floor.orders", value: "\(board.openOrders)")
                HeroFigure(titleKey: "business.utilisation.30d", value: Format.percent(board.utilisation30d),
                           tint: Theme.tide)
                HeroFigure(titleKey: "business.floor.late.short", value: "\(board.lateLines)",
                           tint: board.lateLines > 0 ? Theme.danger : .white)
            }
        }
        .heroCard(glow: board.lateLines > 0 ? Theme.emberHot : Theme.tide)
    }

    private func lineCard(_ line: ProductionLine) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.name).font(.headline)
                    Text("#\(line.orderNumber) · \(line.customerName.isEmpty ? L.t("business.walk_in") : line.customerName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if line.late {
                    Label(L.t("business.floor.late.badge"), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.danger)
                }
            }
            HStack(spacing: 8) {
                MadeBar(progress: line.progress, tint: line.late ? Theme.danger : Theme.tide)
                Text("\(line.printed)/\(line.quantity)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .environment(\.layoutDirection, .leftToRight)
            }
            HStack(spacing: 14) {
                Label(Format.duration(line.remainingSeconds), systemImage: "clock")
                if let due = line.dueDate {
                    Label(Format.date(due), systemImage: "calendar")
                }
                if line.queued > 0 {
                    Label(L.t("business.line.queued", line.queued), systemImage: "list.number")
                        .foregroundStyle(Theme.emberHot)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let order = business.order(id: line.orderID),
               let item = order.items.first(where: { $0.id == line.orderItemID }) {
                HStack(spacing: 8) {
                    if item.remaining - item.queued > 0 {
                        Button {
                            Task { await business.queue(order, line: item) }
                        } label: {
                            Label(line.hasGCode ? L.t("business.line.queue", item.remaining - item.queued)
                                                : L.t("business.line.no_gcode"),
                                  systemImage: line.hasGCode ? "printer.fill" : "scissors")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.tideDeep)
                        .disabled(!line.hasGCode)
                    }
                    Button {
                        Task { await business.recordPrinted(order, line: item) }
                    } label: {
                        Label(L.t("business.line.made_one"), systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    NavigationLink {
                        OrderDetailView(orderID: order.id)
                    } label: {
                        Image(systemName: "doc.text")
                    }
                    .buttonStyle(.bordered)
                }
                .font(.caption.weight(.semibold))
                .controlSize(.small)
                .disabled(business.isBusy)
            }
        }
        .card(tint: line.late ? Theme.danger : .clear)
    }
}
