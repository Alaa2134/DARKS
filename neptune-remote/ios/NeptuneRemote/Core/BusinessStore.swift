import Foundation
import SwiftUI

/// The workshop: orders and who they are for, what is on the floor, what came
/// in and what went out.
///
/// Every figure is the Pi's, computed from its rows; the app only shows it. In
/// demo mode the same screens run on `DemoBusiness`, and changes made there
/// are applied locally with the Pi's arithmetic so the demo stays coherent.
@MainActor
final class BusinessStore: ObservableObject {
    @Published private(set) var orders: [Order] = []
    @Published private(set) var customers: [Customer] = []
    @Published private(set) var expenses: [Expense] = []
    @Published private(set) var accounts = Accounts.empty
    @Published private(set) var production = Production.empty
    @Published private(set) var isLoading = false
    @Published private(set) var isBusy = false
    @Published var period: AccountsPeriod = .thisMonth
    @Published var lastError: APIError?
    /// A one-line confirmation ("2 copies queued") the screen shows briefly.
    @Published var lastMessage: String?

    private let settings: AppSettings
    private let printer: PrinterStore

    init(settings: AppSettings, printer: PrinterStore) {
        self.settings = settings
        self.printer = printer
    }

    var currency: String { accounts.currency.isEmpty ? "EGP" : accounts.currency }

    func money(_ value: Double) -> String { Format.money(value, currency: currency) }

    var openOrders: [Order] { orders.filter { $0.status.isOpen } }

    /// Open orders due within three days or already late, soonest first.
    var dueSoon: [Order] {
        let horizon = Date().timeIntervalSince1970 + 3 * 86_400
        return openOrders
            .filter { ($0.dueDate ?? .infinity) < horizon }
            .sorted { ($0.dueDate ?? 0) < ($1.dueDate ?? 0) }
    }

    func order(id: String) -> Order? { orders.first { $0.id == id } }

    // MARK: - Loading

    func load(force: Bool = false) async {
        guard force || orders.isEmpty else { return }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        if settings.demoMode {
            if orders.isEmpty || force {
                orders = DemoBusiness.orders
                customers = DemoBusiness.customers
                expenses = DemoBusiness.expenses
                accounts = DemoBusiness.accounts
                production = DemoBusiness.production
            }
            return
        }
        do {
            let (start, end) = period.range()
            async let ordersTask = printer.backend.orders()
            async let customersTask = printer.backend.customers()
            async let expensesTask = printer.backend.expenses(
                start: start.timeIntervalSince1970, end: end.timeIntervalSince1970
            )
            async let accountsTask = printer.backend.accounts(
                start: start.timeIntervalSince1970, end: end.timeIntervalSince1970
            )
            async let productionTask = printer.backend.production()
            orders = try await ordersTask
            customers = try await customersTask
            expenses = try await expensesTask
            accounts = try await accountsTask
            production = try await productionTask
            lastError = nil
        } catch {
            fail(error)
        }
    }

    func reloadAccounts() async {
        guard !settings.demoMode else { return }
        let (start, end) = period.range()
        do {
            accounts = try await printer.backend.accounts(
                start: start.timeIntervalSince1970, end: end.timeIntervalSince1970
            )
            expenses = try await printer.backend.expenses(
                start: start.timeIntervalSince1970, end: end.timeIntervalSince1970
            )
        } catch {
            fail(error)
        }
    }

    private func refreshSideViews() async {
        guard !settings.demoMode else {
            production = DemoBusiness.productionFrom(orders)
            return
        }
        async let productionTask = printer.backend.production()
        async let customersTask = printer.backend.customers()
        if let floor = try? await productionTask { production = floor }
        if let list = try? await customersTask { customers = list }
        await reloadAccounts()
    }

    // MARK: - Orders

    @discardableResult
    func createOrder(_ payload: OrderPayload) async -> Order? {
        isBusy = true
        defer { isBusy = false }
        if settings.demoMode {
            let order = DemoBusiness.newOrder(from: payload, number: (orders.map(\.number).max() ?? 0) + 1,
                                              customers: customers)
            orders.insert(order, at: 0)
            await refreshSideViews()
            Haptics.success()
            return order
        }
        do {
            let order = try await printer.backend.createOrder(payload)
            orders.insert(order, at: 0)
            await refreshSideViews()
            Haptics.success()
            lastError = nil
            return order
        } catch {
            fail(error)
            return nil
        }
    }

    func setStatus(_ order: Order, to status: OrderStatus) async {
        await mutate(order) { current in
            var copy = current
            copy.statusRaw = status.rawValue
            copy.deliveredAt = status == .delivered ? Date().timeIntervalSince1970 : nil
            return copy
        } remote: {
            try await self.printer.backend.updateOrder(id: order.id, OrderUpdatePayload(status: status.rawValue))
        }
    }

    func addPayment(_ order: Order, amount: Double, method: PaymentMethod, note: String = "") async {
        guard amount > 0 else { return }
        await mutate(order) { current in
            var copy = current
            copy.payments.append(Payment(id: UUID().uuidString, orderID: order.id, amount: amount,
                                         method: method.rawValue, note: note,
                                         paidAt: Date().timeIntervalSince1970))
            return copy
        } remote: {
            try await self.printer.backend.addPayment(
                orderID: order.id, PaymentPayload(amount: amount, method: method.rawValue, note: note)
            )
        }
    }

    func recordPrinted(_ order: Order, line: OrderItem, count: Int = 1) async {
        await mutate(order) { current in
            var copy = current
            if let index = copy.items.firstIndex(where: { $0.id == line.id }) {
                copy.items[index].printed += count
            }
            return DemoBusiness.advanced(copy)
        } remote: {
            try await self.printer.backend.recordPrinted(orderItemID: line.id, count: count)
        }
    }

    /// Put the line's remaining copies on the print queue. Never starts a print.
    func queue(_ order: Order, line: OrderItem, copies: Int? = nil) async {
        if settings.demoMode {
            let available = line.remaining - line.queued
            guard available > 0 else {
                lastMessage = L.t("business.queue.nothing_left")
                return
            }
            let count = min(copies ?? available, available)
            var copy = order
            if let index = copy.items.firstIndex(where: { $0.id == line.id }) {
                copy.items[index].queued += count
            }
            if copy.status == .new { copy.statusRaw = OrderStatus.inProduction.rawValue }
            replace(DemoBusiness.recomputed(copy))
            await refreshSideViews()
            lastMessage = L.t("business.queue.queued", count)
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let jobs = try await printer.backend.queueOrderItem(id: line.id, QueueOrderItemPayload(copies: copies))
            replace(try await printer.backend.order(id: order.id))
            await refreshSideViews()
            lastMessage = L.t("business.queue.queued", jobs.count)
            Haptics.success()
        } catch {
            fail(error)
        }
    }

    func delete(_ order: Order) async -> Bool {
        if settings.demoMode {
            guard order.payments.isEmpty else {
                lastError = .server(status: 409, message: L.t("business.order.has_payments"))
                return false
            }
            orders.removeAll { $0.id == order.id }
            await refreshSideViews()
            return true
        }
        do {
            try await printer.backend.deleteOrder(id: order.id)
            orders.removeAll { $0.id == order.id }
            await refreshSideViews()
            return true
        } catch {
            fail(error)
            return false
        }
    }

    // MARK: - Customers

    @discardableResult
    func addCustomer(_ payload: CustomerPayload) async -> Customer? {
        if settings.demoMode {
            let customer = Customer(id: UUID().uuidString, name: payload.name, phone: payload.phone,
                                    email: payload.email, address: payload.address, notes: payload.notes,
                                    createdAt: Date().timeIntervalSince1970, orderCount: 0,
                                    totalOrdered: 0, totalPaid: 0, balance: 0)
            customers.insert(customer, at: 0)
            return customer
        }
        do {
            let customer = try await printer.backend.createCustomer(payload)
            customers.insert(customer, at: 0)
            Haptics.success()
            return customer
        } catch {
            fail(error)
            return nil
        }
    }

    func orders(for customer: Customer) -> [Order] {
        orders.filter { $0.customerID == customer.id }
    }

    // MARK: - Expenses

    func addExpense(_ payload: ExpensePayload) async {
        if settings.demoMode {
            expenses.insert(Expense(id: UUID().uuidString, category: payload.category, amount: payload.amount,
                                    note: payload.note,
                                    spentAt: payload.spentAt ?? Date().timeIntervalSince1970), at: 0)
            Haptics.success()
            return
        }
        do {
            _ = try await printer.backend.addExpense(payload)
            await reloadAccounts()
            Haptics.success()
        } catch {
            fail(error)
        }
    }

    func deleteExpense(_ expense: Expense) async {
        if settings.demoMode {
            expenses.removeAll { $0.id == expense.id }
            return
        }
        do {
            try await printer.backend.deleteExpense(id: expense.id)
            expenses.removeAll { $0.id == expense.id }
            await reloadAccounts()
        } catch {
            fail(error)
        }
    }

    // MARK: - Plumbing

    /// One change to an order: applied locally in demo mode, sent to the Pi
    /// otherwise, and the side views (floor, books) brought up to date after.
    private func mutate(
        _ order: Order,
        local: (Order) -> Order,
        remote: @escaping () async throws -> Order
    ) async {
        isBusy = true
        defer { isBusy = false }
        if settings.demoMode {
            replace(DemoBusiness.recomputed(local(order)))
            await refreshSideViews()
            return
        }
        do {
            replace(try await remote())
            await refreshSideViews()
            lastError = nil
        } catch {
            fail(error)
        }
    }

    private func replace(_ order: Order) {
        if let index = orders.firstIndex(where: { $0.id == order.id }) {
            orders[index] = order
        } else {
            orders.insert(order, at: 0)
        }
    }

    /// The Pi refuses with a key ("business.queue.no_gcode"); show the words.
    private func fail(_ error: Error) {
        let api = APIError.from(error, host: settings.host)
        if case .server(let status, let message) = api, message.hasPrefix("business.") {
            lastError = .server(status: status, message: L.t(message))
        } else if case .notFound(let message) = api, message.hasPrefix("business.") {
            lastError = .server(status: 404, message: L.t(message))
        } else {
            lastError = api
        }
        Haptics.error()
    }
}
