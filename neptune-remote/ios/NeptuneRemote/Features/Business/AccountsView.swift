import Charts
import SwiftUI

/// The books, in the two views an owner needs and must never confuse.
///
/// *Orders*: what was sold, less what it cost to make, less the overheads -
/// is the work itself profitable. *Cash*: what came in, less what went out -
/// is there money in the drawer. A month of big orders on credit is a good
/// month in the first and a hard one in the second, and both are true.
struct AccountsView: View {
    @EnvironmentObject private var business: BusinessStore

    private var books: Accounts { business.accounts }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                Picker(L.t("business.period"), selection: $business.period) {
                    ForEach(AccountsPeriod.allCases) { period in
                        Text(localized: period.localizationKey).tag(period)
                    }
                }
                .pickerStyle(.segmented)

                hero
                ordersView
                cashView
                if books.months.count > 1 { trend }
                if !books.topProducts.isEmpty { topProducts }
            }
            .padding(Theme.spacing)
        }
        .background(Theme.pageFill)
        .navigationTitle(L.t("business.accounts.title"))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: business.period) { _, _ in Task { await business.reloadAccounts() } }
        .task { await business.load() }
        .refreshable { await business.load(force: true) }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(localized: "business.net_profit")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.65))
            Text(business.money(books.netProfit))
                .font(.system(size: 42, weight: .heavy, design: .rounded))
                .foregroundStyle(books.netProfit >= 0 ? .white : Theme.danger)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            HStack(spacing: 10) {
                HeroFigure(titleKey: "business.orders.count", value: "\(books.orders)")
                HeroFigure(titleKey: "business.units", value: "\(books.units)")
                HeroFigure(titleKey: "business.average_order", value: business.money(books.averageOrder),
                           tint: Theme.tide)
            }
        }
        .heroCard(glow: books.netProfit >= 0 ? Theme.printing : Theme.danger)
    }

    private var ordersView: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("business.view.orders", systemImage: "list.clipboard.fill")
            InfoRow(titleKey: "business.sales", value: business.money(books.sales))
            InfoRow(titleKey: "business.cost_of_goods", value: "− " + business.money(books.costOfGoods))
            Divider()
            HStack {
                InfoRow(titleKey: "business.gross_profit", value: business.money(books.grossProfit),
                        tint: Theme.printing)
            }
            Text(L.t("business.margin", Format.percentValue(books.grossMarginPercent)))
                .font(.caption)
                .foregroundStyle(.secondary)
            InfoRow(titleKey: "business.overheads", value: "− " + business.money(books.overheads))
            Divider()
            InfoRow(titleKey: "business.net_profit", value: business.money(books.netProfit),
                    tint: books.netProfit >= 0 ? Theme.printing : Theme.danger)
            Text(localized: "business.view.orders.hint")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .card()
    }

    private var cashView: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("business.view.cash", systemImage: "banknote.fill")
            InfoRow(titleKey: "business.cash_in", value: business.money(books.cashIn), tint: Theme.printing)
            InfoRow(titleKey: "business.cash_out", value: "− " + business.money(books.cashOut), tint: Theme.emberHot)
            Divider()
            InfoRow(titleKey: "business.cash_profit", value: business.money(books.cashProfit),
                    tint: books.cashProfit >= 0 ? Theme.printing : Theme.danger)
            HStack {
                Label(L.t("business.receivables"), systemImage: "hourglass")
                    .font(.subheadline)
                Spacer()
                Text(business.money(books.receivables))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.emberHot)
            }
            .padding(.top, 4)
            Text(localized: "business.view.cash.hint")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .card()
    }

    private var trend: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("business.trend", systemImage: "chart.bar.xaxis")
            Chart {
                ForEach(books.months) { month in
                    BarMark(x: .value("month", month.date, unit: .month), y: .value("sales", month.sales))
                        .foregroundStyle(Theme.tide.opacity(0.35).gradient)
                        .cornerRadius(5)
                    LineMark(x: .value("month", month.date, unit: .month), y: .value("profit", month.profit))
                        .foregroundStyle(Theme.printing)
                        .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                        .symbol(.circle)
                        .interpolationMethod(.catmullRom)
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated))
                }
            }
            .frame(height: 190)
            HStack(spacing: 14) {
                Label(L.t("business.sales"), systemImage: "square.fill").foregroundStyle(Theme.tide)
                Label(L.t("business.profit"), systemImage: "circle.fill").foregroundStyle(Theme.printing)
            }
            .font(.caption2)
        }
        .card()
    }

    private var topProducts: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("business.top_products", systemImage: "star.fill")
            let best = books.topProducts.map(\.revenue).max() ?? 1
            ForEach(books.topProducts) { product in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(product.name).font(.subheadline.weight(.medium)).lineLimit(1)
                        Spacer()
                        Text(business.money(product.revenue))
                            .font(.subheadline.monospacedDigit())
                    }
                    MadeBar(progress: best > 0 ? product.revenue / best : 0, tint: Theme.tideDeep)
                    Text(L.t("business.top.detail", product.units, business.money(product.profit)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .card()
    }
}
