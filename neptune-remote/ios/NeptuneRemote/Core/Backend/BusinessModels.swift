import Foundation
import SwiftUI

// MARK: - Order status

/// Where an order is in the workshop. The order is the order of the work.
enum OrderStatus: String, CaseIterable, Identifiable, Codable {
    case new
    case inProduction = "in_production"
    case ready
    case delivered
    case cancelled

    var id: String { rawValue }
    var localizationKey: String { "business.status.\(rawValue)" }

    var color: Color {
        switch self {
        case .new: return Theme.accent
        case .inProduction: return Theme.emberHot
        case .ready: return Theme.printing
        case .delivered: return Color(rgb: 0x6366F1)
        case .cancelled: return .secondary
        }
    }

    var systemImage: String {
        switch self {
        case .new: return "sparkles"
        case .inProduction: return "gearshape.2.fill"
        case .ready: return "shippingbox.fill"
        case .delivered: return "checkmark.seal.fill"
        case .cancelled: return "xmark.circle"
        }
    }

    /// The one step forward a person takes by hand, if any.
    var next: OrderStatus? {
        switch self {
        case .new: return .inProduction
        case .inProduction: return .ready
        case .ready: return .delivered
        case .delivered, .cancelled: return nil
        }
    }

    var isOpen: Bool { self == .new || self == .inProduction || self == .ready }
}

// MARK: - Customers

struct Customer: Decodable, Identifiable, Equatable, Hashable {
    let id: String
    var name: String
    var phone: String
    var email: String
    var address: String
    var notes: String
    var createdAt: Double
    var orderCount: Int
    var totalOrdered: Double
    var totalPaid: Double
    var balance: Double

    enum CodingKeys: String, CodingKey {
        case id, name, phone, email, address, notes, balance
        case createdAt = "created_at"
        case orderCount = "order_count"
        case totalOrdered = "total_ordered"
        case totalPaid = "total_paid"
    }

    /// A WhatsApp link for the customer's number, Egyptian numbers written the
    /// local way (010...) included.
    var whatsAppURL: URL? {
        var digits = phone.filter(\.isNumber)
        guard digits.count >= 8 else { return nil }
        if digits.hasPrefix("0") && digits.count == 11 { digits = "2" + digits }
        return URL(string: "https://wa.me/\(digits)")
    }

    var phoneURL: URL? {
        let digits = phone.filter { $0.isNumber || $0 == "+" }
        return digits.isEmpty ? nil : URL(string: "tel:\(digits)")
    }
}

struct CustomerPayload: Encodable {
    var name: String
    var phone: String = ""
    var email: String = ""
    var address: String = ""
    var notes: String = ""
}

// MARK: - Orders

struct OrderItem: Decodable, Identifiable, Equatable, Hashable {
    let id: String
    let orderID: String
    var productID: String?
    var itemID: String?
    var name: String
    var quantity: Int
    var unitPrice: Double
    var unitCost: Double
    var printed: Int
    var estimatedSeconds: Double?
    var lineTotal: Double
    var lineCost: Double
    var remaining: Int
    var queued: Int

    var progress: Double { quantity > 0 ? Double(printed) / Double(quantity) : 0 }

    enum CodingKeys: String, CodingKey {
        case id, name, quantity, printed, remaining, queued
        case orderID = "order_id"
        case productID = "product_id"
        case itemID = "item_id"
        case unitPrice = "unit_price"
        case unitCost = "unit_cost"
        case estimatedSeconds = "estimated_seconds"
        case lineTotal = "line_total"
        case lineCost = "line_cost"
    }
}

struct Payment: Decodable, Identifiable, Equatable, Hashable {
    let id: String
    var orderID: String?
    var amount: Double
    var method: String
    var note: String
    var paidAt: Double

    var methodKey: String { "business.method.\(method)" }

    enum CodingKeys: String, CodingKey {
        case id, amount, method, note
        case orderID = "order_id"
        case paidAt = "paid_at"
    }
}

struct Order: Decodable, Identifiable, Equatable, Hashable {
    let id: String
    let number: Int
    var customerID: String?
    var customerName: String
    var statusRaw: String
    var dueDate: Double?
    var discount: Double
    var shipping: Double
    var notes: String
    var currency: String
    var createdAt: Double
    var deliveredAt: Double?
    var items: [OrderItem]
    var payments: [Payment]
    var subtotal: Double
    var total: Double
    var cost: Double
    var profit: Double
    var paid: Double
    var balance: Double
    var units: Int
    var printed: Int
    var progress: Double
    var remainingSeconds: Double
    var overdue: Bool

    var status: OrderStatus { OrderStatus(rawValue: statusRaw) ?? .new }
    var title: String { "#\(number)" }
    var displayCustomer: String { customerName.isEmpty ? L.t("business.walk_in") : customerName }
    var isPaid: Bool { balance <= 0.005 && total > 0 }

    enum CodingKeys: String, CodingKey {
        case id, number, discount, shipping, notes, currency, items, payments
        case subtotal, total, cost, profit, paid, balance, units, printed, progress, overdue
        case customerID = "customer_id"
        case customerName = "customer_name"
        case statusRaw = "status"
        case dueDate = "due_date"
        case createdAt = "created_at"
        case deliveredAt = "delivered_at"
        case remainingSeconds = "remaining_seconds"
    }
}

struct OrderItemPayload: Encodable, Identifiable, Equatable {
    var id = UUID()
    var productID: String?
    var itemID: String?
    var name: String = ""
    var quantity: Int = 1
    var unitPrice: Double?
    var unitCost: Double?

    enum CodingKeys: String, CodingKey {
        case name, quantity
        case productID = "product_id"
        case itemID = "item_id"
        case unitPrice = "unit_price"
        case unitCost = "unit_cost"
    }
}

struct OrderPayload: Encodable {
    var customerID: String?
    var customerName: String = ""
    var dueDate: Double?
    var discount: Double = 0
    var shipping: Double = 0
    var notes: String = ""
    var items: [OrderItemPayload] = []
    var deposit: Double = 0
    var depositMethod: String = "cash"

    enum CodingKeys: String, CodingKey {
        case discount, shipping, notes, items, deposit
        case customerID = "customer_id"
        case customerName = "customer_name"
        case dueDate = "due_date"
        case depositMethod = "deposit_method"
    }
}

struct OrderUpdatePayload: Encodable {
    var status: String?
    var dueDate: Double?
    var discount: Double?
    var shipping: Double?
    var notes: String?

    enum CodingKeys: String, CodingKey {
        case status, discount, shipping, notes
        case dueDate = "due_date"
    }
}

struct PaymentPayload: Encodable {
    var amount: Double
    var method: String = "cash"
    var note: String = ""
}

enum PaymentMethod: String, CaseIterable, Identifiable {
    case cash, transfer, wallet, card, other
    var id: String { rawValue }
    var localizationKey: String { "business.method.\(rawValue)" }
}

// MARK: - Expenses

enum ExpenseCategory: String, CaseIterable, Identifiable {
    case materials, electricity, parts, rent, shipping, marketing, salaries, other
    var id: String { rawValue }
    var localizationKey: String { "business.expense.\(rawValue)" }

    var systemImage: String {
        switch self {
        case .materials: return "circle.hexagongrid.fill"
        case .electricity: return "bolt.fill"
        case .parts: return "wrench.and.screwdriver.fill"
        case .rent: return "building.2.fill"
        case .shipping: return "shippingbox.fill"
        case .marketing: return "megaphone.fill"
        case .salaries: return "person.2.fill"
        case .other: return "ellipsis.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .materials: return Theme.emberHot
        case .electricity: return Theme.paused
        case .parts: return Color(rgb: 0x64748B)
        case .rent: return Color(rgb: 0x6366F1)
        case .shipping: return Theme.tideDeep
        case .marketing: return Color(rgb: 0xEC4899)
        case .salaries: return Color(rgb: 0x14B8A6)
        case .other: return .secondary
        }
    }
}

struct Expense: Decodable, Identifiable, Equatable, Hashable {
    let id: String
    var category: String
    var amount: Double
    var note: String
    var spentAt: Double

    var kind: ExpenseCategory { ExpenseCategory(rawValue: category) ?? .other }

    enum CodingKeys: String, CodingKey {
        case id, category, amount, note
        case spentAt = "spent_at"
    }
}

struct ExpensePayload: Encodable {
    var category: String
    var amount: Double
    var note: String = ""
    var spentAt: Double?

    enum CodingKeys: String, CodingKey {
        case category, amount, note
        case spentAt = "spent_at"
    }
}

// MARK: - Accounts

struct MonthFigures: Decodable, Identifiable, Equatable, Hashable {
    var id: String { month }
    let month: String
    var sales: Double
    var cashIn: Double
    var costOfGoods: Double
    var expenses: Double
    var profit: Double

    /// "2026-10" as a date, for the chart's axis.
    var date: Date {
        let parts = month.split(separator: "-").compactMap { Int($0) }
        var components = DateComponents()
        components.year = parts.first
        components.month = parts.count > 1 ? parts[1] : 1
        components.day = 1
        return Calendar.current.date(from: components) ?? Date()
    }

    enum CodingKeys: String, CodingKey {
        case month, sales, expenses, profit
        case cashIn = "cash_in"
        case costOfGoods = "cost_of_goods"
    }
}

struct ProductFigures: Decodable, Identifiable, Equatable, Hashable {
    var id: String { name }
    let name: String
    var units: Int
    var revenue: Double
    var profit: Double
}

struct Accounts: Decodable, Equatable {
    var currency: String
    var start: Double
    var end: Double
    var orders: Int
    var units: Int
    var sales: Double
    var costOfGoods: Double
    var grossProfit: Double
    var grossMarginPercent: Double
    var overheads: Double
    var netProfit: Double
    var cashIn: Double
    var cashOut: Double
    var cashProfit: Double
    var receivables: Double
    var averageOrder: Double
    var expensesByCategory: [String: Double]
    var topProducts: [ProductFigures]
    var months: [MonthFigures]

    enum CodingKeys: String, CodingKey {
        case currency, start, end, orders, units, sales, overheads, receivables, months
        case costOfGoods = "cost_of_goods"
        case grossProfit = "gross_profit"
        case grossMarginPercent = "gross_margin_percent"
        case netProfit = "net_profit"
        case cashIn = "cash_in"
        case cashOut = "cash_out"
        case cashProfit = "cash_profit"
        case averageOrder = "average_order"
        case expensesByCategory = "expenses_by_category"
        case topProducts = "top_products"
    }

    static let empty = Accounts(
        currency: "EGP", start: 0, end: 0, orders: 0, units: 0, sales: 0, costOfGoods: 0,
        grossProfit: 0, grossMarginPercent: 0, overheads: 0, netProfit: 0, cashIn: 0, cashOut: 0,
        cashProfit: 0, receivables: 0, averageOrder: 0, expensesByCategory: [:], topProducts: [], months: []
    )
}

/// The periods the books can be read for.
enum AccountsPeriod: String, CaseIterable, Identifiable {
    case thisMonth, lastMonth, thisYear

    var id: String { rawValue }
    var localizationKey: String { "business.period.\(rawValue)" }

    func range(now: Date = Date(), calendar: Calendar = .current) -> (Date, Date) {
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        switch self {
        case .thisMonth:
            return (monthStart, calendar.date(byAdding: .month, value: 1, to: monthStart) ?? now)
        case .lastMonth:
            return (calendar.date(byAdding: .month, value: -1, to: monthStart) ?? now, monthStart)
        case .thisYear:
            let yearStart = calendar.date(from: calendar.dateComponents([.year], from: now)) ?? now
            return (yearStart, calendar.date(byAdding: .year, value: 1, to: yearStart) ?? now)
        }
    }
}

// MARK: - Production

struct ProductionLine: Decodable, Identifiable, Equatable, Hashable {
    var id: String { orderItemID }
    let orderID: String
    let orderNumber: Int
    let orderItemID: String
    var customerName: String
    var name: String
    var itemID: String?
    var quantity: Int
    var printed: Int
    var remaining: Int
    var queued: Int
    var secondsEach: Double?
    var remainingSeconds: Double
    var dueDate: Double?
    var projectedFinish: Double?
    var late: Bool
    var hasGCode: Bool

    var progress: Double { quantity > 0 ? Double(printed) / Double(quantity) : 0 }

    enum CodingKeys: String, CodingKey {
        case name, quantity, printed, remaining, queued, late
        case orderID = "order_id"
        case orderNumber = "order_number"
        case orderItemID = "order_item_id"
        case customerName = "customer_name"
        case itemID = "item_id"
        case secondsEach = "seconds_each"
        case remainingSeconds = "remaining_seconds"
        case dueDate = "due_date"
        case projectedFinish = "projected_finish"
        case hasGCode = "has_gcode"
    }
}

struct Production: Decodable, Equatable {
    var lines: [ProductionLine]
    var openOrders: Int
    var unitsRemaining: Int
    var hoursRemaining: Double
    var projectedClear: Double?
    var lateLines: Int
    var utilisation7d: Double?
    var utilisation30d: Double?
    var printers: Int

    enum CodingKeys: String, CodingKey {
        case lines, printers
        case openOrders = "open_orders"
        case unitsRemaining = "units_remaining"
        case hoursRemaining = "hours_remaining"
        case projectedClear = "projected_clear"
        case lateLines = "late_lines"
        case utilisation7d = "utilisation_7d"
        case utilisation30d = "utilisation_30d"
    }

    static let empty = Production(lines: [], openOrders: 0, unitsRemaining: 0, hoursRemaining: 0,
                                  projectedClear: nil, lateLines: 0, utilisation7d: nil,
                                  utilisation30d: nil, printers: 1)
}

struct QueueOrderItemPayload: Encodable {
    var copies: Int?
    var gcodePath: String?

    enum CodingKeys: String, CodingKey {
        case copies
        case gcodePath = "gcode_path"
    }
}
