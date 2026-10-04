import Foundation

/// The workshop: customers, orders, production, payments, expenses, accounts.
extension BackendClient {

    // MARK: - Customers

    func customers(search: String = "") async throws -> [Customer] {
        let query = search.isEmpty ? [] : [URLQueryItem(name: "search", value: search)]
        return try await decode([Customer].self, path: "business/customers", query: query)
    }

    func createCustomer(_ payload: CustomerPayload) async throws -> Customer {
        try await decode(Customer.self, path: "business/customers", method: "POST",
                         body: try await http.encodeBody(payload))
    }

    func updateCustomer(id: String, _ payload: CustomerPayload) async throws -> Customer {
        try await decode(Customer.self, path: "business/customers/\(id)", method: "PATCH",
                         body: try await http.encodeBody(payload))
    }

    func deleteCustomer(id: String) async throws {
        _ = try await raw(path: "business/customers/\(id)", method: "DELETE")
    }

    // MARK: - Orders

    func orders(openOnly: Bool = false, customerID: String? = nil) async throws -> [Order] {
        var query: [URLQueryItem] = []
        if openOnly { query.append(URLQueryItem(name: "open_only", value: "true")) }
        if let customerID { query.append(URLQueryItem(name: "customer_id", value: customerID)) }
        return try await decode([Order].self, path: "business/orders", query: query)
    }

    func order(id: String) async throws -> Order {
        try await decode(Order.self, path: "business/orders/\(id)")
    }

    func createOrder(_ payload: OrderPayload) async throws -> Order {
        try await decode(Order.self, path: "business/orders", method: "POST",
                         body: try await http.encodeBody(payload))
    }

    func updateOrder(id: String, _ payload: OrderUpdatePayload) async throws -> Order {
        try await decode(Order.self, path: "business/orders/\(id)", method: "PATCH",
                         body: try await http.encodeBody(payload))
    }

    func deleteOrder(id: String) async throws {
        _ = try await raw(path: "business/orders/\(id)", method: "DELETE")
    }

    func addOrderItem(orderID: String, _ payload: OrderItemPayload) async throws -> Order {
        try await decode(Order.self, path: "business/orders/\(orderID)/items", method: "POST",
                         body: try await http.encodeBody(payload))
    }

    func removeOrderItem(id: String) async throws -> Order {
        try await decode(Order.self, path: "business/order-items/\(id)", method: "DELETE")
    }

    func recordPrinted(orderItemID: String, count: Int) async throws -> Order {
        try await decode(Order.self, path: "business/order-items/\(orderItemID)/printed", method: "POST",
                         query: [URLQueryItem(name: "count", value: String(count))])
    }

    func queueOrderItem(id: String, _ payload: QueueOrderItemPayload) async throws -> [QueueJob] {
        try await decode([QueueJob].self, path: "business/order-items/\(id)/queue", method: "POST",
                         body: try await http.encodeBody(payload))
    }

    func addPayment(orderID: String, _ payload: PaymentPayload) async throws -> Order {
        try await decode(Order.self, path: "business/orders/\(orderID)/payments", method: "POST",
                         body: try await http.encodeBody(payload))
    }

    func deletePayment(id: String) async throws {
        _ = try await raw(path: "business/payments/\(id)", method: "DELETE")
    }

    // MARK: - Expenses

    func expenses(start: Double? = nil, end: Double? = nil) async throws -> [Expense] {
        var query: [URLQueryItem] = []
        if let start { query.append(URLQueryItem(name: "start", value: String(start))) }
        if let end { query.append(URLQueryItem(name: "end", value: String(end))) }
        return try await decode([Expense].self, path: "business/expenses", query: query)
    }

    func addExpense(_ payload: ExpensePayload) async throws -> Expense {
        try await decode(Expense.self, path: "business/expenses", method: "POST",
                         body: try await http.encodeBody(payload))
    }

    func deleteExpense(id: String) async throws {
        _ = try await raw(path: "business/expenses/\(id)", method: "DELETE")
    }

    // MARK: - Accounts and the floor

    func accounts(start: Double, end: Double, months: Int = 6) async throws -> Accounts {
        try await decode(Accounts.self, path: "business/accounts", query: [
            URLQueryItem(name: "start", value: String(start)),
            URLQueryItem(name: "end", value: String(end)),
            URLQueryItem(name: "months", value: String(months)),
        ])
    }

    func production() async throws -> Production {
        try await decode(Production.self, path: "business/production")
    }
}
