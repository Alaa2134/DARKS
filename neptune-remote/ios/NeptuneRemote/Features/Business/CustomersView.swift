import SwiftUI

/// Who the workshop makes things for, and who still owes it.
struct CustomersView: View {
    @EnvironmentObject private var business: BusinessStore

    @State private var search = ""
    @State private var showingNew = false

    private var visible: [Customer] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let list = query.isEmpty ? business.customers : business.customers.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.phone.contains(query)
        }
        // Whoever owes the most first: that is who this list is opened for.
        return list.sorted { $0.balance == $1.balance ? $0.name < $1.name : $0.balance > $1.balance }
    }

    var body: some View {
        List {
            if visible.isEmpty {
                EmptyStateView(titleKey: "business.customers.empty", messageKey: "business.customers.empty.hint",
                               systemImage: "person.2", actionTitleKey: "business.customer.new",
                               action: { showingNew = true })
                    .listRowBackground(Color.clear)
            }
            ForEach(visible) { customer in
                NavigationLink {
                    CustomerDetailView(customerID: customer.id)
                } label: {
                    HStack(spacing: 12) {
                        Text(String(customer.name.prefix(1)))
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Theme.tideGradient, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(customer.name).font(.subheadline.weight(.semibold))
                            Text(L.t("business.customer.orders", customer.orderCount))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if customer.balance > 0.005 {
                            Text(business.money(customer.balance))
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                                .foregroundStyle(Theme.emberHot)
                        }
                    }
                }
            }
        }
        .searchable(text: $search, prompt: L.t("business.customers.search"))
        .navigationTitle(L.t("business.customers.title"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingNew = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel(L.t("business.customer.new"))
            }
        }
        .sheet(isPresented: $showingNew) { NavigationStack { NewCustomerView() } }
        .task { await business.load() }
        .refreshable { await business.load(force: true) }
    }
}

/// One customer: how to reach them, what they owe, and every order.
struct CustomerDetailView: View {
    let customerID: String

    @EnvironmentObject private var business: BusinessStore

    private var customer: Customer? { business.customers.first { $0.id == customerID } }

    var body: some View {
        ScrollView {
            if let customer {
                VStack(spacing: Theme.spacing) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(customer.name)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)
                        if !customer.phone.isEmpty {
                            Text(customer.phone)
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.white.opacity(0.7))
                                .environment(\.layoutDirection, .leftToRight)
                        }
                        HStack(spacing: 10) {
                            HeroFigure(titleKey: "business.customer.ordered", value: business.money(customer.totalOrdered))
                            HeroFigure(titleKey: "business.customer.paid", value: business.money(customer.totalPaid),
                                       tint: Theme.tide)
                            HeroFigure(titleKey: "business.balance", value: business.money(customer.balance),
                                       tint: customer.balance > 0.005 ? Theme.emberWarm : .white)
                        }
                        HStack(spacing: 10) {
                            if let url = customer.phoneURL {
                                Link(destination: url) {
                                    Label(L.t("business.customer.call"), systemImage: "phone.fill")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .tint(.white)
                            }
                            if let url = customer.whatsAppURL {
                                Link(destination: url) {
                                    Label(L.t("business.customer.whatsapp"), systemImage: "message.fill")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(Color(rgb: 0x22C55E))
                            }
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                    .heroCard(glow: customer.balance > 0.005 ? Theme.emberHot : Theme.tide)

                    let orders = business.orders(for: customer)
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader("business.orders.title", systemImage: "list.clipboard.fill")
                        if orders.isEmpty {
                            Text(localized: "business.orders.empty")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(orders) { order in
                            NavigationLink {
                                OrderDetailView(orderID: order.id)
                            } label: {
                                OrderRow(order: order, currency: business.currency)
                            }
                            .buttonStyle(.plain)
                            if order.id != orders.last?.id { Divider() }
                        }
                    }
                    .card()

                    if !customer.notes.isEmpty {
                        Text(customer.notes)
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .card()
                    }
                }
                .padding(Theme.spacing)
            }
        }
        .background(Theme.pageFill)
        .navigationTitle(customer?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct NewCustomerView: View {
    @EnvironmentObject private var business: BusinessStore
    @Environment(\.dismiss) private var dismiss

    @State private var payload = CustomerPayload(name: "")

    var body: some View {
        Form {
            Section {
                TextField(L.t("business.customer.name"), text: $payload.name)
                TextField(L.t("business.customer.phone"), text: $payload.phone)
                    .keyboardType(.phonePad)
                TextField(L.t("business.customer.address"), text: $payload.address)
                TextField(L.t("business.notes"), text: $payload.notes, axis: .vertical)
                    .lineLimit(1...4)
            }
        }
        .navigationTitle(L.t("business.customer.new"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L.t("common.cancel")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(L.t("common.save")) {
                    Task {
                        if await business.addCustomer(payload) != nil { dismiss() }
                    }
                }
                .disabled(payload.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}
