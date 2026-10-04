import Foundation

/// A small workshop's month, for demo mode: real-looking orders made from the
/// demo library's own models, so the factory screens open on something worth
/// reading instead of an empty ledger.
///
/// Totals are worked out here with the same arithmetic as the Pi
/// (`app/business/store.py`): subtotal less discount plus shipping, cost from
/// each line's unit cost, balance from what was paid.
enum DemoBusiness {
    static let currency = "EGP"
    private static let now = Date().timeIntervalSince1970
    private static let day: Double = 86_400

    static let customers: [Customer] = [
        customer("cus-1", "سارة محمود", phone: "01012345678", ordered: 1_040, paid: 400),
        customer("cus-2", "متجر بيكسل للهدايا", phone: "01155554444", ordered: 5_110, paid: 3_850, orders: 2),
        customer("cus-3", "كريم عادل", phone: "01222223333", ordered: 520, paid: 200),
        customer("cus-4", "مدرسة النور", phone: "0233334444", ordered: 2_460, paid: 1_900, orders: 2),
        customer("cus-5", "يوسف حسن", phone: "01099998888", ordered: 180, paid: 180),
    ]

    static var orders: [Order] {
        [
            order("ord-7", 7, customer: "cus-2", "متجر بيكسل للهدايا", .inProduction, due: now + 2 * day,
                  created: now - 2 * day,
                  lines: [line("o7-1", "حامل موبايل للمكتب", item: "demo-stand", qty: 20, price: 85, cost: 31, printed: 12, queued: 3, seconds: 5_400),
                          line("o7-2", "ميدالية مفاتيح", item: "demo-keychain", qty: 40, price: 25, cost: 6, printed: 40, seconds: 900)],
                  paid: [(1_500, "transfer")], shipping: 60),
            order("ord-6", 6, customer: "cus-4", "مدرسة النور", .inProduction, due: now + 5 * day,
                  created: now - 3 * day,
                  lines: [line("o6-1", "قاعدة روبوت أردوينو", item: "demo-robot", qty: 6, price: 260, cost: 95, printed: 2, queued: 1, seconds: 21_600)],
                  paid: [(1_000, "cash")]),
            order("ord-5", 5, customer: "cus-1", "سارة محمود", .ready, due: now + 1 * day,
                  created: now - 4 * day,
                  lines: [line("o5-1", "منظم أدراج", item: "demo-organizer", qty: 2, price: 320, cost: 118, printed: 2, seconds: 14_400),
                          line("o5-2", "فازة الموج", qty: 1, price: 450, cost: 140, printed: 1, seconds: 10_800)],
                  paid: [(400, "wallet")], discount: 50),
            order("ord-4", 4, customer: "cus-3", "كريم عادل", .new, due: now + 6 * day,
                  created: now - 0.3 * day,
                  lines: [line("o4-1", "ترس بديل للخلاط", qty: 4, price: 130, cost: 22, seconds: 2_700)],
                  paid: [(200, "cash")]),
            order("ord-3", 3, customer: "cus-2", "متجر بيكسل للهدايا", .delivered, due: now - 3 * day,
                  created: now - 9 * day,
                  lines: [line("o3-1", "ميدالية مفاتيح", item: "demo-keychain", qty: 60, price: 25, cost: 6, printed: 60, seconds: 900),
                          line("o3-2", "حامل موبايل للمكتب", item: "demo-stand", qty: 10, price: 85, cost: 31, printed: 10, seconds: 5_400)],
                  paid: [(2_350, "transfer")], delivered: now - 3 * day),
            order("ord-2", 2, customer: "cus-5", "يوسف حسن", .delivered, due: nil,
                  created: now - 12 * day,
                  lines: [line("o2-1", "ميدالية باسم", qty: 4, price: 45, cost: 7, printed: 4, seconds: 1_100)],
                  paid: [(180, "cash")], delivered: now - 11 * day),
            order("ord-1", 1, customer: "cus-4", "مدرسة النور", .delivered, due: now - 15 * day,
                  created: now - 20 * day,
                  lines: [line("o1-1", "منظم أدراج", item: "demo-organizer", qty: 3, price: 300, cost: 118, printed: 3, seconds: 14_400)],
                  paid: [(900, "transfer")], delivered: now - 16 * day),
        ]
    }

    static let expenses: [Expense] = [
        Expense(id: "exp-1", category: "materials", amount: 1_400, note: "بكرتين PETG + بكرة PLA", spentAt: now - 6 * day),
        Expense(id: "exp-2", category: "electricity", amount: 320, note: "فاتورة الكهربا", spentAt: now - 10 * day),
        Expense(id: "exp-3", category: "parts", amount: 260, note: "فوهات وقطعة PEI", spentAt: now - 4 * day),
        Expense(id: "exp-4", category: "shipping", amount: 180, note: "شحن طلب #3", spentAt: now - 3 * day),
        Expense(id: "exp-5", category: "marketing", amount: 250, note: "إعلان إنستجرام", spentAt: now - 8 * day),
    ]

    static var accounts: Accounts {
        Accounts(
            currency: currency,
            start: now - 30 * day, end: now,
            orders: 7, units: 150,
            sales: 9_310, costOfGoods: 2_946, grossProfit: 6_364, grossMarginPercent: 68.4,
            overheads: 1_010, netProfit: 5_354,
            cashIn: 6_530, cashOut: 2_410, cashProfit: 4_120,
            receivables: 2_780, averageOrder: 1_330,
            expensesByCategory: ["materials": 1_400, "electricity": 320, "parts": 260, "shipping": 180, "marketing": 250],
            topProducts: [
                ProductFigures(name: "حامل موبايل للمكتب", units: 30, revenue: 2_550, profit: 1_620),
                ProductFigures(name: "ميدالية مفاتيح", units: 100, revenue: 2_500, profit: 1_900),
                ProductFigures(name: "قاعدة روبوت أردوينو", units: 6, revenue: 1_560, profit: 990),
                ProductFigures(name: "منظم أدراج", units: 5, revenue: 1_540, profit: 950),
            ],
            months: [
                MonthFigures(month: monthKey(-5), sales: 3_200, cashIn: 2_900, costOfGoods: 1_050, expenses: 600, profit: 1_550),
                MonthFigures(month: monthKey(-4), sales: 4_100, cashIn: 3_700, costOfGoods: 1_300, expenses: 640, profit: 2_160),
                MonthFigures(month: monthKey(-3), sales: 3_800, cashIn: 4_000, costOfGoods: 1_200, expenses: 700, profit: 1_900),
                MonthFigures(month: monthKey(-2), sales: 5_600, cashIn: 5_100, costOfGoods: 1_750, expenses: 820, profit: 3_030),
                MonthFigures(month: monthKey(-1), sales: 7_300, cashIn: 6_400, costOfGoods: 2_250, expenses: 900, profit: 4_150),
                MonthFigures(month: monthKey(0), sales: 9_310, cashIn: 6_530, costOfGoods: 2_946, expenses: 1_010, profit: 5_354),
            ]
        )
    }

    static var production: Production { floorPlan(from: orders) }

    private static func floorPlan(from current: [Order]) -> Production {
        let now = Date().timeIntervalSince1970
        var elapsed = 0.0
        var lines: [ProductionLine] = []
        let open = current.filter { $0.status.isOpen }.sorted { ($0.dueDate ?? .infinity) < ($1.dueDate ?? .infinity) }
        for order in open {
            for item in order.items where item.remaining > 0 {
                let seconds = (item.estimatedSeconds ?? 0) * Double(item.remaining)
                elapsed += seconds
                let finish = now + elapsed
                lines.append(ProductionLine(
                    orderID: order.id, orderNumber: order.number, orderItemID: item.id,
                    customerName: order.customerName, name: item.name, itemID: item.itemID,
                    quantity: item.quantity, printed: item.printed, remaining: item.remaining,
                    queued: item.queued, secondsEach: item.estimatedSeconds, remainingSeconds: seconds,
                    dueDate: order.dueDate, projectedFinish: finish,
                    late: (order.dueDate ?? .infinity) < finish, hasGCode: item.itemID != nil
                ))
            }
        }
        return Production(
            lines: lines, openOrders: Set(lines.map(\.orderID)).count,
            unitsRemaining: lines.reduce(0) { $0 + $1.remaining },
            hoursRemaining: elapsed / 3600, projectedClear: now + elapsed,
            lateLines: lines.filter(\.late).count, utilisation7d: 0.71, utilisation30d: 0.58, printers: 1
        )
    }

    // MARK: - Local changes (demo mode)

    /// The floor recomputed from the orders as they stand now.
    static func productionFrom(_ current: [Order]) -> Production {
        floorPlan(from: current)
    }

    /// The same automatic step the Pi takes when parts come off the bed.
    static func advanced(_ order: Order) -> Order {
        let fresh = recomputed(order)
        guard ![.delivered, .cancelled, .ready].contains(fresh.status) else { return fresh }
        var copy = fresh
        if fresh.units > 0 && fresh.printed >= fresh.units {
            copy.statusRaw = OrderStatus.ready.rawValue
        } else if fresh.printed > 0 {
            copy.statusRaw = OrderStatus.inProduction.rawValue
        }
        return copy
    }

    static func newOrder(from payload: OrderPayload, number: Int, customers: [Customer]) -> Order {
        let id = UUID().uuidString
        let name = customers.first { $0.id == payload.customerID }?.name ?? payload.customerName
        let lines = payload.items.enumerated().map { index, item in
            line("\(id)-\(index)", item.name.isEmpty ? L.t("business.item.untitled") : item.name,
                 item: item.itemID, qty: max(1, item.quantity), price: item.unitPrice ?? 0,
                 cost: item.unitCost ?? 0)
        }
        let paid: [(Double, String)] = payload.deposit > 0 ? [(payload.deposit, payload.depositMethod)] : []
        return order(id, number, customer: payload.customerID, name, .new, due: payload.dueDate,
                     created: Date().timeIntervalSince1970, lines: lines, paid: paid,
                     discount: payload.discount, shipping: payload.shipping)
    }

    // MARK: - Builders

    private static func monthKey(_ offset: Int) -> String {
        let date = Calendar.current.date(byAdding: .month, value: offset, to: Date()) ?? Date()
        let parts = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 2026, parts.month ?? 1)
    }

    private static func customer(_ id: String, _ name: String, phone: String, ordered: Double,
                                 paid: Double, orders: Int = 1) -> Customer {
        Customer(id: id, name: name, phone: phone, email: "", address: "", notes: "",
                 createdAt: now - 40 * day, orderCount: orders, totalOrdered: ordered,
                 totalPaid: paid, balance: ordered - paid)
    }

    static func line(_ id: String, _ name: String, item: String? = nil, qty: Int, price: Double,
                     cost: Double, printed: Int = 0, queued: Int = 0, seconds: Double? = nil) -> OrderItem {
        OrderItem(id: id, orderID: "", productID: nil, itemID: item, name: name, quantity: qty,
                  unitPrice: price, unitCost: cost, printed: printed, estimatedSeconds: seconds,
                  lineTotal: Double(qty) * price, lineCost: Double(qty) * cost,
                  remaining: max(0, qty - printed), queued: queued)
    }

    static func order(_ id: String, _ number: Int, customer: String?, _ name: String, _ status: OrderStatus,
                      due: Double?, created: Double, lines: [OrderItem], paid: [(Double, String)],
                      discount: Double = 0, shipping: Double = 0, delivered: Double? = nil) -> Order {
        let payments = paid.enumerated().map { index, entry in
            Payment(id: "\(id)-p\(index)", orderID: id, amount: entry.0, method: entry.1,
                    note: index == 0 ? "deposit" : "", paidAt: created + Double(index) * day)
        }
        return recomputed(Order(
            id: id, number: number, customerID: customer, customerName: name, statusRaw: status.rawValue,
            dueDate: due, discount: discount, shipping: shipping, notes: "", currency: currency,
            createdAt: created, deliveredAt: delivered, items: lines, payments: payments,
            subtotal: 0, total: 0, cost: 0, profit: 0, paid: 0, balance: 0, units: 0, printed: 0,
            progress: 0, remainingSeconds: 0, overdue: false
        ))
    }

    /// The Pi's arithmetic, for orders changed locally in demo mode.
    static func recomputed(_ order: Order) -> Order {
        var result = order
        result.items = order.items.map { item in
            var line = item
            line.printed = min(max(0, line.printed), line.quantity)
            line.lineTotal = Double(line.quantity) * line.unitPrice
            line.lineCost = Double(line.quantity) * line.unitCost
            line.remaining = max(0, line.quantity - line.printed)
            line.queued = min(line.queued, line.remaining)
            return line
        }
        result.subtotal = result.items.reduce(0) { $0 + $1.lineTotal }
        result.total = max(0, result.subtotal - result.discount + result.shipping)
        result.cost = result.items.reduce(0) { $0 + $1.lineCost }
        result.profit = result.total - result.cost
        result.paid = result.payments.reduce(0) { $0 + $1.amount }
        result.balance = result.status == .cancelled ? 0 : result.total - result.paid
        result.units = result.items.reduce(0) { $0 + $1.quantity }
        result.printed = result.items.reduce(0) { $0 + $1.printed }
        result.progress = result.units > 0 ? Double(result.printed) / Double(result.units) : 0
        result.remainingSeconds = result.items.reduce(0) { $0 + ($1.estimatedSeconds ?? 0) * Double($1.remaining) }
        result.overdue = result.status.isOpen && result.status != .ready
            && (result.dueDate ?? .infinity) < Date().timeIntervalSince1970
        return result
    }
}
