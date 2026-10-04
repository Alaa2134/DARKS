import Charts
import SwiftUI

/// The workshop at a glance: is it making money, what is on the machine, and
/// what is due.
///
/// The order of the screen is the order of the questions an owner asks in the
/// morning - how are we doing, what do I start now, who is waiting on me.
struct BusinessHomeView: View {
    @EnvironmentObject private var business: BusinessStore

    @State private var showingNewOrder = false
    @State private var showingExpense = false
    @State private var showingCustomer = false

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                hero
                shortcuts
                floorCard
                if !business.dueSoon.isEmpty { dueSoonCard }
                destinations
            }
            .padding(Theme.spacing)
        }
        .background(Theme.pageFill)
        .navigationTitle(L.t("business.title"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingNewOrder = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .accessibilityLabel(L.t("business.order.new"))
            }
        }
        .sheet(isPresented: $showingNewOrder) { NavigationStack { NewOrderView() } }
        .sheet(isPresented: $showingExpense) { NavigationStack { NewExpenseView() } }
        .sheet(isPresented: $showingCustomer) { NavigationStack { NewCustomerView() } }
        .task { await business.load() }
        .refreshable { await business.load(force: true) }
    }

    // MARK: - Hero: this month's books

    private var hero: some View {
        let books = business.accounts
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                StatusChip(text: L.t(business.period.localizationKey), color: Theme.tide,
                           systemImage: "calendar")
                Spacer()
                NavigationLink {
                    AccountsView()
                } label: {
                    HStack(spacing: 4) {
                        Text(localized: "business.accounts.open")
                        Image(systemName: "chevron.forward")
                            .flipsForRightToLeftLayoutDirection(true)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.75))
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(localized: "business.net_profit")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.65))
                Text(business.money(books.netProfit))
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                    .foregroundStyle(books.netProfit >= 0 ? .white : Theme.danger)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }

            if books.months.count > 1 {
                Chart(books.months) { month in
                    AreaMark(x: .value("month", month.date, unit: .month), y: .value("profit", month.profit))
                        .foregroundStyle(LinearGradient(colors: [Theme.tide.opacity(0.45), Theme.tide.opacity(0.02)],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("month", month.date, unit: .month), y: .value("profit", month.profit))
                        .foregroundStyle(Theme.tide)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .interpolationMethod(.catmullRom)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 64)
                .accessibilityHidden(true)
            }

            HStack(spacing: 10) {
                HeroFigure(titleKey: "business.sales", value: business.money(books.sales))
                HeroFigure(titleKey: "business.cash_in", value: business.money(books.cashIn), tint: Theme.tide)
                HeroFigure(titleKey: "business.receivables", value: business.money(books.receivables),
                           tint: Theme.emberWarm)
            }
        }
        .heroCard(glow: books.netProfit >= 0 ? Theme.printing : Theme.danger)
    }

    // MARK: - Shortcuts

    private var shortcuts: some View {
        HStack(spacing: 10) {
            Button { showingNewOrder = true } label: {
                BusinessShortcut(titleKey: "business.order.new", systemImage: "cart.badge.plus", tint: Theme.tideDeep)
            }
            Button { showingExpense = true } label: {
                BusinessShortcut(titleKey: "business.expense.new", systemImage: "arrow.down.circle", tint: Theme.emberHot)
            }
            Button { showingCustomer = true } label: {
                BusinessShortcut(titleKey: "business.customer.new", systemImage: "person.crop.circle.badge.plus",
                                 tint: Color(rgb: 0x6366F1))
            }
            NavigationLink { ProductionBoardView() } label: {
                BusinessShortcut(titleKey: "business.floor.short", systemImage: "gearshape.2.fill",
                                 tint: Color(rgb: 0x14B8A6))
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - The floor

    private var floorCard: some View {
        let board = business.production
        return NavigationLink {
            ProductionBoardView()
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionHeader("business.floor.title", systemImage: "gearshape.2.fill")
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .flipsForRightToLeftLayoutDirection(true)
                }
                HStack(spacing: 16) {
                    ProgressRing(
                        progress: board.utilisation7d ?? 0,
                        lineWidth: 8,
                        tint: Theme.tide,
                        label: Format.percent(board.utilisation7d),
                        caption: L.t("business.utilisation.7d")
                    )
                    .frame(width: 84, height: 84)
                    VStack(alignment: .leading, spacing: 6) {
                        Label(L.t("business.floor.units", board.unitsRemaining), systemImage: "cube.fill")
                            .font(.subheadline.weight(.semibold))
                        Label(L.t("business.floor.hours", Format.duration(board.hoursRemaining * 3600)),
                              systemImage: "clock.fill")
                            .font(.subheadline)
                            .foregroundStyle(Theme.emberHot)
                        if let clear = board.projectedClear {
                            Label(L.t("business.floor.clear", Format.date(clear)), systemImage: "flag.checkered")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if board.lateLines > 0 {
                            Label(L.t("business.floor.late", board.lateLines), systemImage: "exclamationmark.triangle.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.danger)
                        }
                    }
                    Spacer(minLength: 0)
                }
                ForEach(board.lines.prefix(3)) { line in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(line.name).font(.subheadline.weight(.medium)).lineLimit(1)
                            Spacer()
                            Text("#\(line.orderNumber)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        MadeBar(progress: line.progress, tint: line.late ? Theme.danger : Theme.tide)
                    }
                }
            }
            .card()
        }
        .buttonStyle(.plain)
    }

    // MARK: - Due soon

    private var dueSoonCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("business.due_soon", systemImage: "calendar.badge.exclamationmark")
            ForEach(business.dueSoon) { order in
                NavigationLink {
                    OrderDetailView(orderID: order.id)
                } label: {
                    OrderRow(order: order, currency: business.currency)
                }
                .buttonStyle(.plain)
                if order.id != business.dueSoon.last?.id { Divider() }
            }
        }
        .card()
    }

    // MARK: - Everything else

    private var destinations: some View {
        VStack(spacing: 0) {
            NavigationLink { OrdersView() } label: {
                destinationRow(MenuRow(titleKey: "business.orders.title", systemImage: "list.clipboard.fill",
                                       color: Theme.tideDeep),
                               trailing: "\(business.openOrders.count)")
            }
            Divider().padding(.leading, 52)
            NavigationLink { CustomersView() } label: {
                destinationRow(MenuRow(titleKey: "business.customers.title", systemImage: "person.2.fill",
                                       color: Color(rgb: 0x6366F1)),
                               trailing: "\(business.customers.count)")
            }
            Divider().padding(.leading, 52)
            NavigationLink { ExpensesView() } label: {
                destinationRow(MenuRow(titleKey: "business.expenses.title", systemImage: "arrow.down.circle.fill",
                                       color: Theme.emberHot),
                               trailing: business.money(business.accounts.cashOut))
            }
            Divider().padding(.leading, 52)
            NavigationLink { AccountsView() } label: {
                destinationRow(MenuRow(titleKey: "business.accounts.title", systemImage: "chart.bar.xaxis",
                                       color: Theme.printing),
                               trailing: nil)
            }
        }
        .buttonStyle(.plain)
        .card()
    }

    private func destinationRow(_ row: MenuRow, trailing: String?) -> some View {
        HStack {
            row
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.forward")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .flipsForRightToLeftLayoutDirection(true)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}
