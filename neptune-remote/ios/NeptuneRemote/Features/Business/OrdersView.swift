import SwiftUI

/// Every order, filtered by where it is in the workshop.
struct OrdersView: View {
    @EnvironmentObject private var business: BusinessStore

    @State private var filter: Filter = .open
    @State private var search = ""
    @State private var showingNewOrder = false

    enum Filter: String, CaseIterable, Identifiable {
        case open, delivered, cancelled, all
        var id: String { rawValue }
        var localizationKey: String { "business.filter.\(rawValue)" }
    }

    private var visible: [Order] {
        business.orders
            .filter { order in
                switch filter {
                case .open: return order.status.isOpen
                case .delivered: return order.status == .delivered
                case .cancelled: return order.status == .cancelled
                case .all: return true
                }
            }
            .filter { order in
                let query = search.trimmingCharacters(in: .whitespaces)
                guard !query.isEmpty else { return true }
                return order.customerName.localizedCaseInsensitiveContains(query)
                    || "\(order.number)" == query.replacingOccurrences(of: "#", with: "")
                    || order.items.contains { $0.name.localizedCaseInsensitiveContains(query) }
            }
    }

    var body: some View {
        List {
            Section {
                Picker(L.t("business.filter"), selection: $filter) {
                    ForEach(Filter.allCases) { option in
                        Text(localized: option.localizationKey).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            if visible.isEmpty {
                EmptyStateView(
                    titleKey: "business.orders.empty",
                    messageKey: "business.orders.empty.hint",
                    systemImage: "list.clipboard",
                    actionTitleKey: "business.order.new",
                    action: { showingNewOrder = true }
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(visible) { order in
                        NavigationLink {
                            OrderDetailView(orderID: order.id)
                        } label: {
                            OrderRow(order: order, currency: business.currency)
                        }
                    }
                } footer: {
                    let total = visible.reduce(0) { $0 + $1.total }
                    let owed = visible.reduce(0) { $0 + max(0, $1.balance) }
                    Text(L.t("business.orders.footer", visible.count, business.money(total), business.money(owed)))
                }
            }
        }
        .searchable(text: $search, prompt: L.t("business.orders.search"))
        .navigationTitle(L.t("business.orders.title"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingNewOrder = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel(L.t("business.order.new"))
            }
        }
        .sheet(isPresented: $showingNewOrder) { NavigationStack { NewOrderView() } }
        .task { await business.load() }
        .refreshable { await business.load(force: true) }
    }
}
