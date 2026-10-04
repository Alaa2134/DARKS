import XCTest
@testable import NeptuneRemote

/// The workshop's arithmetic and plumbing, checked by hand.
final class BusinessTests: XCTestCase {

    // MARK: - Decoding what the Pi sends

    private let orderJSON = """
    {"id":"o1","number":12,"customer_id":"c1","customer_name":"سارة","status":"in_production",
     "due_date":1800000000,"discount":10,"shipping":30,"notes":"","currency":"EGP",
     "created_at":1790000000,"updated_at":1790000000,"delivered_at":null,
     "items":[{"id":"i1","order_id":"o1","product_id":null,"item_id":"lib1","name":"حامل","quantity":4,
               "unit_price":25,"unit_cost":5,"printed":1,"estimated_seconds":3600,"filament_g":40,"position":0,
               "line_total":100,"line_cost":20,"remaining":3,"queued":2}],
     "payments":[{"id":"p1","order_id":"o1","customer_id":"c1","amount":40,"method":"wallet","note":"deposit",
                  "paid_at":1790000000,"created_at":1790000000}],
     "subtotal":100,"total":120,"cost":20,"profit":100,"paid":40,"balance":80,"units":4,"printed":1,
     "progress":0.25,"remaining_seconds":10800,"overdue":false}
    """

    func testOrderDecodesFromThePi() throws {
        let order = try JSONDecoder().decode(Order.self, from: Data(orderJSON.utf8))
        XCTAssertEqual(order.title, "#12")
        XCTAssertEqual(order.status, .inProduction)
        XCTAssertEqual(order.items.first?.queued, 2)
        XCTAssertEqual(order.payments.first?.methodKey, "business.method.wallet")
        XCTAssertEqual(order.balance, 80)
        XCTAssertFalse(order.isPaid)
    }

    func testAnUnknownStatusReadsAsNew() throws {
        let json = orderJSON.replacingOccurrences(of: "in_production", with: "on_the_moon")
        XCTAssertEqual(try JSONDecoder().decode(Order.self, from: Data(json.utf8)).status, .new)
    }

    // MARK: - Arithmetic (must match app/business/store.py)

    func testRecomputedMatchesThePi() {
        let order = DemoBusiness.order(
            "x", 1, customer: nil, "", .new, due: nil, created: 0,
            lines: [DemoBusiness.line("l", "ميدالية", qty: 4, price: 25, cost: 5, printed: 9)],
            paid: [(40, "cash")], discount: 10, shipping: 30
        )
        XCTAssertEqual(order.subtotal, 100)
        XCTAssertEqual(order.total, 120)
        XCTAssertEqual(order.cost, 20)
        XCTAssertEqual(order.profit, 100)
        XCTAssertEqual(order.balance, 80)
        XCTAssertEqual(order.items[0].printed, 4, "printed is capped at the quantity")
        XCTAssertEqual(order.progress, 1)
    }

    func testACancelledOrderOwesNothing() {
        let order = DemoBusiness.order("x", 1, customer: nil, "", .cancelled, due: nil, created: 0,
                                       lines: [DemoBusiness.line("l", "قطعة", qty: 1, price: 50, cost: 5)],
                                       paid: [])
        XCTAssertEqual(order.balance, 0)
    }

    func testMadePartsMoveAnOrderAlongButNeverBack() {
        var order = DemoBusiness.order("x", 1, customer: nil, "", .new, due: nil, created: 0,
                                       lines: [DemoBusiness.line("l", "قطعة", qty: 2, price: 50, cost: 5)],
                                       paid: [])
        order.items[0].printed = 1
        XCTAssertEqual(DemoBusiness.advanced(order).status, .inProduction)
        order.items[0].printed = 2
        XCTAssertEqual(DemoBusiness.advanced(order).status, .ready)
        order.statusRaw = OrderStatus.delivered.rawValue
        XCTAssertEqual(DemoBusiness.advanced(order).status, .delivered)
    }

    func testStatusStepsForwardToDelivered() {
        XCTAssertEqual(OrderStatus.new.next, .inProduction)
        XCTAssertEqual(OrderStatus.inProduction.next, .ready)
        XCTAssertEqual(OrderStatus.ready.next, .delivered)
        XCTAssertNil(OrderStatus.delivered.next)
        XCTAssertNil(OrderStatus.cancelled.next)
    }

    // MARK: - The demo book adds up

    func testDemoAccountsAreTheDemoOrders() {
        let live = DemoBusiness.orders.filter { $0.status != .cancelled }
        let books = DemoBusiness.accounts
        XCTAssertEqual(books.orders, live.count)
        XCTAssertEqual(books.sales, live.reduce(0) { $0 + $1.total }, accuracy: 0.01)
        XCTAssertEqual(books.costOfGoods, live.reduce(0) { $0 + $1.cost }, accuracy: 0.01)
        XCTAssertEqual(books.units, live.reduce(0) { $0 + $1.units })
        XCTAssertEqual(books.cashIn, live.reduce(0) { $0 + $1.paid }, accuracy: 0.01)
        XCTAssertEqual(books.receivables, live.reduce(0) { $0 + max(0, $1.balance) }, accuracy: 0.01)
        XCTAssertEqual(books.grossProfit, books.sales - books.costOfGoods, accuracy: 0.01)
        XCTAssertEqual(books.netProfit, books.grossProfit - books.overheads, accuracy: 0.01)
        XCTAssertEqual(books.cashOut, DemoBusiness.expenses.reduce(0) { $0 + $1.amount }, accuracy: 0.01)
        XCTAssertEqual(books.overheads,
                       DemoBusiness.expenses.filter { $0.kind != .materials }.reduce(0) { $0 + $1.amount },
                       accuracy: 0.01)
        XCTAssertEqual(books.months.last?.sales ?? 0, books.sales, accuracy: 0.01)
    }

    func testDemoCustomersAreTheirOrders() {
        for customer in DemoBusiness.customers {
            let theirs = DemoBusiness.orders.filter { $0.customerID == customer.id && $0.status != .cancelled }
            XCTAssertEqual(customer.orderCount, theirs.count, customer.name)
            XCTAssertEqual(customer.totalOrdered, theirs.reduce(0) { $0 + $1.total }, accuracy: 0.01, customer.name)
            XCTAssertEqual(customer.totalPaid, theirs.reduce(0) { $0 + $1.paid }, accuracy: 0.01, customer.name)
        }
    }

    func testDemoFloorIsOrderedByDueDate() {
        let lines = DemoBusiness.production.lines
        XCTAssertFalse(lines.isEmpty)
        let dues = lines.compactMap(\.dueDate)
        XCTAssertEqual(dues, dues.sorted())
        XCTAssertTrue(lines.allSatisfy { $0.remaining > 0 })
    }

    // MARK: - Small things that matter

    func testAmountsTypedInArabicDigits() {
        XCTAssertEqual(Amount.parse("٣٤٫٥"), 34.5)
        XCTAssertEqual(Amount.parse("۱۲۰"), 120)
        XCTAssertEqual(Amount.parse("1,5"), 1.5)
        XCTAssertEqual(Amount.parse("250 ج"), 250)
        XCTAssertNil(Amount.parse(""))
        XCTAssertNil(Amount.parse("abc"))
        XCTAssertEqual(Amount.text(120), "120")
        XCTAssertEqual(Amount.text(12.5), "12.50")
    }

    func testWhatsAppTurnsALocalEgyptianNumberInternational() {
        let customer = DemoBusiness.customers[0]
        XCTAssertEqual(customer.whatsAppURL?.absoluteString, "https://wa.me/201012345678")
        XCTAssertNotNil(customer.phoneURL)
    }

    func testPeriodsAreWholeMonthsAndYears() {
        var components = DateComponents()
        components.year = 2026; components.month = 3; components.day = 15
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: components)!
        let (start, end) = AccountsPeriod.lastMonth.range(now: now, calendar: calendar)
        XCTAssertEqual(calendar.component(.month, from: start), 2)
        XCTAssertEqual(calendar.component(.day, from: start), 1)
        XCTAssertEqual(calendar.component(.month, from: end), 3)
        let (yearStart, yearEnd) = AccountsPeriod.thisYear.range(now: now, calendar: calendar)
        XCTAssertEqual(calendar.component(.month, from: yearStart), 1)
        XCTAssertEqual(calendar.component(.year, from: yearEnd), 2027)
    }
}
