import SwiftUI

/// One order: what was asked for, how much of it exists yet, and the money.
///
/// Read by id from the store rather than held as a value, so a part counted
/// by the print queue, or a payment taken on another screen, shows here the
/// moment it lands.
struct OrderDetailView: View {
    let orderID: String

    @EnvironmentObject private var business: BusinessStore
    @Environment(\.dismiss) private var dismiss

    @State private var showingPayment = false
    @State private var showingInvoice = false
    @State private var confirmingCancel = false
    @State private var confirmingDelete = false

    private var order: Order? { business.order(id: orderID) }

    var body: some View {
        Group {
            if let order {
                content(order)
            } else {
                EmptyStateView(titleKey: "business.order.missing", messageKey: "business.order.missing.hint",
                               systemImage: "questionmark.folder")
            }
        }
        .background(Theme.pageFill)
        .navigationTitle(order?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func content(_ order: Order) -> some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                header(order)
                if let message = business.lastMessage {
                    Label(message, systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.printing)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card(tint: Theme.printing)
                        .task {
                            try? await Task.sleep(nanoseconds: 2_500_000_000)
                            business.lastMessage = nil
                        }
                }
                linesCard(order)
                moneyCard(order)
                paymentsCard(order)
                actions(order)
            }
            .padding(Theme.spacing)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showingInvoice = true } label: {
                        Label(L.t("business.invoice.share"), systemImage: "square.and.arrow.up")
                    }
                    if order.status != .cancelled {
                        Button(role: .destructive) { confirmingCancel = true } label: {
                            Label(L.t("business.order.cancel"), systemImage: "xmark.circle")
                        }
                    }
                    if order.payments.isEmpty {
                        Button(role: .destructive) { confirmingDelete = true } label: {
                            Label(L.t("business.order.delete"), systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingPayment) {
            NavigationStack { NewPaymentView(order: order) }
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showingInvoice) {
            NavigationStack { InvoiceView(order: order) }
        }
        .confirmationDialog(L.t("business.order.cancel.confirm"), isPresented: $confirmingCancel,
                            titleVisibility: .visible) {
            Button(L.t("business.order.cancel"), role: .destructive) {
                Task { await business.setStatus(order, to: .cancelled) }
            }
        }
        .confirmationDialog(L.t("business.order.delete.confirm"), isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button(L.t("business.order.delete"), role: .destructive) {
                Task { if await business.delete(order) { dismiss() } }
            }
        }
    }

    // MARK: - Header

    private func header(_ order: Order) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                OrderStatusChip(status: order.status)
                    .environment(\.colorScheme, .dark)
                Spacer()
                Text(Format.date(order.createdAt))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
            Text(order.displayCustomer)
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
            HStack(spacing: 16) {
                ProgressRing(progress: order.progress, lineWidth: 8, tint: Theme.tide,
                             label: "\(order.printed)/\(order.units)")
                    .frame(width: 76, height: 76)
                VStack(alignment: .leading, spacing: 6) {
                    Text(business.money(order.total))
                        .font(.title.weight(.heavy))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if order.balance > 0.005 {
                        Text(L.t("business.balance.short", business.money(order.balance)))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.emberWarm)
                    } else if order.isPaid {
                        Label(L.t("business.paid.full"), systemImage: "checkmark.seal.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.tide)
                    }
                    if let due = order.dueDate {
                        Label(Format.date(due), systemImage: order.overdue ? "exclamationmark.triangle.fill" : "calendar")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(order.overdue ? Theme.danger : .white.opacity(0.7))
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .heroCard(glow: order.status.color)
    }

    // MARK: - Lines

    private func linesCard(_ order: Order) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("business.order.items", systemImage: "cube.box.fill")
            ForEach(order.items) { line in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(line.name)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(business.money(line.lineTotal))
                            .font(.subheadline.monospacedDigit())
                    }
                    HStack(spacing: 8) {
                        Text(L.t("business.line.qty_price", line.quantity, business.money(line.unitPrice)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if line.queued > 0 {
                            Label(L.t("business.line.queued", line.queued), systemImage: "list.number")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Theme.emberHot)
                        }
                    }
                    HStack(spacing: 8) {
                        MadeBar(progress: line.progress)
                        Text("\(line.printed)/\(line.quantity)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .environment(\.layoutDirection, .leftToRight)
                    }
                    if order.status.isOpen && line.remaining > 0 {
                        HStack(spacing: 8) {
                            if line.remaining - line.queued > 0 {
                                Button {
                                    Task { await business.queue(order, line: line) }
                                } label: {
                                    Label(L.t("business.line.queue", line.remaining - line.queued),
                                          systemImage: "printer.fill")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(Theme.tideDeep)
                            }
                            Button {
                                Task { await business.recordPrinted(order, line: line) }
                            } label: {
                                Label(L.t("business.line.made_one"), systemImage: "plus")
                            }
                            .buttonStyle(.bordered)
                        }
                        .font(.caption.weight(.semibold))
                        .controlSize(.small)
                        .disabled(business.isBusy)
                    }
                }
                if line.id != order.items.last?.id { Divider() }
            }
            Text(localized: "business.line.queue.hint")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .card()
    }

    // MARK: - Money

    private func moneyCard(_ order: Order) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("business.order.money", systemImage: "banknote.fill")
            InfoRow(titleKey: "business.subtotal", value: business.money(order.subtotal))
            if order.discount > 0 {
                InfoRow(titleKey: "business.discount", value: "− " + business.money(order.discount))
            }
            if order.shipping > 0 {
                InfoRow(titleKey: "business.shipping", value: business.money(order.shipping))
            }
            Divider()
            InfoRow(titleKey: "business.total", value: business.money(order.total))
            InfoRow(titleKey: "business.cost", value: business.money(order.cost))
            InfoRow(titleKey: "business.profit", value: business.money(order.profit),
                    tint: order.profit >= 0 ? Theme.printing : Theme.danger)
        }
        .card()
    }

    private func paymentsCard(_ order: Order) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("business.payments", systemImage: "creditcard.fill")
            if order.payments.isEmpty {
                Text(localized: "business.payments.none")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(order.payments) { payment in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L.t(payment.methodKey))
                            .font(.subheadline.weight(.medium))
                        Text(Format.date(payment.paidAt))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(business.money(payment.amount))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Theme.printing)
                }
            }
            if order.balance > 0.005 && order.status != .cancelled {
                Button {
                    showingPayment = true
                } label: {
                    Label(L.t("business.payment.take", business.money(order.balance)), systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(Theme.printing)
            }
        }
        .card()
    }

    // MARK: - Moving it along

    @ViewBuilder
    private func actions(_ order: Order) -> some View {
        if let next = order.status.next {
            BigActionButton(
                titleKey: "business.advance.\(next.rawValue)",
                systemImage: next.systemImage,
                tint: next.color,
                isLoading: business.isBusy
            ) {
                Task { await business.setStatus(order, to: next) }
            }
        }
    }
}

/// Taking money against an order. Defaults to what is still owed.
struct NewPaymentView: View {
    let order: Order

    @EnvironmentObject private var business: BusinessStore
    @Environment(\.dismiss) private var dismiss

    @State private var amount: Double = 0
    @State private var method: PaymentMethod = .cash
    @State private var note = ""

    var body: some View {
        Form {
            Section {
                MoneyField(titleKey: "business.amount", value: $amount)
                Picker(L.t("business.method"), selection: $method) {
                    ForEach(PaymentMethod.allCases) { option in
                        Text(localized: option.localizationKey).tag(option)
                    }
                }
                TextField(L.t("business.note"), text: $note)
            } footer: {
                Text(L.t("business.balance.short", business.money(order.balance)))
            }
        }
        .navigationTitle(L.t("business.payment.new"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L.t("common.cancel")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(L.t("common.save")) {
                    Task {
                        await business.addPayment(order, amount: amount, method: method, note: note)
                        dismiss()
                    }
                }
                .disabled(amount <= 0)
            }
        }
        .onAppear { amount = max(0, order.balance) }
    }
}
