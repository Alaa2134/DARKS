import SwiftUI

/// Taking an order: who for, what, how many, by when, and any deposit.
///
/// Lines come from the products list (priced), the library (priced by the
/// Pi's cost calculator when left blank), or are typed in for one-off work.
struct NewOrderView: View {
    @EnvironmentObject private var business: BusinessStore
    @EnvironmentObject private var inventory: InventoryStore
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var customerID: String?
    @State private var customerName = ""
    @State private var lines: [OrderItemPayload] = []
    @State private var hasDueDate = true
    @State private var dueDate = Calendar.current.date(byAdding: .day, value: 3, to: Date()) ?? Date()
    @State private var discount: Double = 0
    @State private var shipping: Double = 0
    @State private var deposit: Double = 0
    @State private var depositMethod: PaymentMethod = .cash
    @State private var notes = ""

    private var subtotal: Double {
        lines.reduce(0) { $0 + Double($1.quantity) * ($1.unitPrice ?? 0) }
    }

    private var total: Double { max(0, subtotal - discount + shipping) }

    private var canSave: Bool {
        !lines.isEmpty && lines.allSatisfy { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty || $0.productID != nil || $0.itemID != nil }
    }

    var body: some View {
        Form {
            customerSection
            linesSection
            Section {
                Toggle(L.t("business.due"), isOn: $hasDueDate.animation())
                if hasDueDate {
                    DatePicker(L.t("business.due.date"), selection: $dueDate, in: Date()..., displayedComponents: .date)
                }
            }
            Section {
                MoneyField(titleKey: "business.discount", value: $discount)
                MoneyField(titleKey: "business.shipping", value: $shipping)
                MoneyField(titleKey: "business.deposit", value: $deposit)
                if deposit > 0 {
                    Picker(L.t("business.method"), selection: $depositMethod) {
                        ForEach(PaymentMethod.allCases) { option in
                            Text(localized: option.localizationKey).tag(option)
                        }
                    }
                }
            } header: {
                Text(localized: "business.order.money")
            } footer: {
                HStack {
                    Text(localized: "business.total")
                    Spacer()
                    Text(business.money(total))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.primary)
                }
                .padding(.top, 6)
            }
            Section {
                TextField(L.t("business.notes"), text: $notes, axis: .vertical)
                    .lineLimit(2...5)
            }
        }
        .navigationTitle(L.t("business.order.new"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L.t("common.cancel")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(L.t("common.save")) { save() }
                    .disabled(!canSave || business.isBusy)
            }
        }
        .task {
            await inventory.load()
            await library.load()
            if business.customers.isEmpty { await business.load() }
        }
    }

    // MARK: - Sections

    private var customerSection: some View {
        Section {
            Picker(L.t("business.customer"), selection: $customerID) {
                Text(localized: "business.walk_in").tag(String?.none)
                ForEach(business.customers) { customer in
                    Text(customer.name).tag(Optional(customer.id))
                }
            }
            if customerID == nil {
                TextField(L.t("business.customer.name"), text: $customerName)
            }
        } header: {
            Text(localized: "business.customer")
        }
    }

    private var linesSection: some View {
        Section {
            ForEach($lines) { $line in
                VStack(alignment: .leading, spacing: 8) {
                    TextField(L.t("business.item.name"), text: $line.name)
                        .font(.subheadline.weight(.semibold))
                    HStack {
                        Stepper(value: $line.quantity, in: 1...10_000) {
                            Text(L.t("business.qty", line.quantity))
                                .monospacedDigit()
                        }
                    }
                    HStack {
                        Text(localized: "business.unit_price")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        TextField(L.t("business.price.auto"), text: Binding(
                            get: { line.unitPrice.map { Amount.text($0) } ?? "" },
                            set: { line.unitPrice = Amount.parse($0) }
                        ))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 140)
                    }
                }
            }
            .onDelete { lines.remove(atOffsets: $0) }

            Menu {
                if !inventory.products.isEmpty {
                    Section(L.t("products.title")) {
                        ForEach(inventory.products) { product in
                            Button(product.displayName) {
                                lines.append(OrderItemPayload(
                                    productID: product.id, itemID: product.itemID, name: product.displayName,
                                    quantity: 1, unitPrice: product.sellingPrice, unitCost: product.printCost
                                ))
                            }
                        }
                    }
                }
                if !library.items.isEmpty {
                    Section(L.t("library.title")) {
                        ForEach(library.items.prefix(30)) { item in
                            Button(item.displayName) {
                                lines.append(OrderItemPayload(itemID: item.id, name: item.displayName))
                            }
                        }
                    }
                }
                Button {
                    lines.append(OrderItemPayload())
                } label: {
                    Label(L.t("business.item.custom"), systemImage: "pencil")
                }
            } label: {
                Label(L.t("business.item.add"), systemImage: "plus.circle.fill")
            }
        } header: {
            Text(localized: "business.order.items")
        } footer: {
            Text(localized: "business.price.auto.hint")
        }
    }

    // MARK: - Save

    private func save() {
        let payload = OrderPayload(
            customerID: customerID,
            customerName: customerID == nil ? customerName.trimmingCharacters(in: .whitespaces) : "",
            dueDate: hasDueDate ? dueDate.timeIntervalSince1970 : nil,
            discount: discount,
            shipping: shipping,
            notes: notes,
            items: lines,
            deposit: deposit,
            depositMethod: depositMethod.rawValue
        )
        Task {
            if await business.createOrder(payload) != nil { dismiss() }
        }
    }
}
