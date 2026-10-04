"""The workshop's book: customers, orders, production, payments and expenses.

It sits on top of what the app already knows - products and their prices,
library items and their slices, the cost calculator, the print queue - so an
order line knows what it costs to make, and a part that comes off the bed is
counted against the order it was printed for.
"""

from __future__ import annotations

import time
import uuid
from datetime import datetime
from typing import Callable, Dict, List, Optional, Tuple

from ..cost.calculator import CostCalculator, CostRequest
from ..db import Database
from .models import (
    EXPENSE_CATEGORIES,
    LIVE_STATUSES,
    ORDER_STATUSES,
    PAYMENT_METHODS,
    Accounts,
    Customer,
    CustomerCreate,
    CustomerUpdate,
    Expense,
    ExpenseCreate,
    MonthFigures,
    Order,
    OrderCreate,
    OrderItem,
    OrderItemCreate,
    OrderItemUpdate,
    OrderUpdate,
    Payment,
    PaymentCreate,
    Production,
    ProductionLine,
    ProductFigures,
)

SCHEMA = """
CREATE TABLE IF NOT EXISTS customers (
    id         TEXT PRIMARY KEY,
    name       TEXT NOT NULL,
    phone      TEXT NOT NULL DEFAULT '',
    email      TEXT NOT NULL DEFAULT '',
    address    TEXT NOT NULL DEFAULT '',
    notes      TEXT NOT NULL DEFAULT '',
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL
);

CREATE TABLE IF NOT EXISTS orders (
    id            TEXT PRIMARY KEY,
    number        INTEGER NOT NULL UNIQUE,
    customer_id   TEXT,
    customer_name TEXT NOT NULL DEFAULT '',
    status        TEXT NOT NULL DEFAULT 'new',
    due_date      REAL,
    discount      REAL NOT NULL DEFAULT 0,
    shipping      REAL NOT NULL DEFAULT 0,
    notes         TEXT NOT NULL DEFAULT '',
    currency      TEXT NOT NULL DEFAULT 'EGP',
    created_at    REAL NOT NULL,
    updated_at    REAL NOT NULL,
    delivered_at  REAL,
    FOREIGN KEY(customer_id) REFERENCES customers(id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS idx_orders_created ON orders(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_orders_status ON orders(status);

CREATE TABLE IF NOT EXISTS order_items (
    id                TEXT PRIMARY KEY,
    order_id          TEXT NOT NULL,
    product_id        TEXT,
    item_id           TEXT,
    name              TEXT NOT NULL,
    quantity          INTEGER NOT NULL DEFAULT 1,
    unit_price        REAL NOT NULL DEFAULT 0,
    unit_cost         REAL NOT NULL DEFAULT 0,
    printed           INTEGER NOT NULL DEFAULT 0,
    estimated_seconds REAL,
    filament_g        REAL,
    position          INTEGER NOT NULL DEFAULT 0,
    FOREIGN KEY(order_id) REFERENCES orders(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_order_items_order ON order_items(order_id);

CREATE TABLE IF NOT EXISTS payments (
    id          TEXT PRIMARY KEY,
    order_id    TEXT,
    customer_id TEXT,
    amount      REAL NOT NULL,
    method      TEXT NOT NULL DEFAULT 'cash',
    note        TEXT NOT NULL DEFAULT '',
    paid_at     REAL NOT NULL,
    created_at  REAL NOT NULL,
    FOREIGN KEY(order_id) REFERENCES orders(id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS idx_payments_paid ON payments(paid_at);

CREATE TABLE IF NOT EXISTS expenses (
    id         TEXT PRIMARY KEY,
    category   TEXT NOT NULL DEFAULT 'other',
    amount     REAL NOT NULL,
    note       TEXT NOT NULL DEFAULT '',
    spent_at   REAL NOT NULL,
    created_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_expenses_spent ON expenses(spent_at);
"""


class BusinessError(Exception):
    """A refusal with a localisation key the app can show as is."""

    def __init__(self, key: str, status: int = 409) -> None:
        super().__init__(key)
        self.key = key
        self.status = status


def _new_id() -> str:
    return uuid.uuid4().hex[:12]


def _money(value: float) -> float:
    return round(float(value or 0.0), 2)


class BusinessStore:
    def __init__(
        self,
        database: Database,
        cost: CostCalculator,
        *,
        library_item: Optional[Callable[[str], object]] = None,
        library_gcodes: Optional[Callable[[str], list]] = None,
        product: Optional[Callable[[str], object]] = None,
    ) -> None:
        self.db = database
        self.cost = cost
        # Lookups are injected so this module does not import the library or
        # products stores, and tests can hand in plain functions.
        self._library_item = library_item or (lambda _id: None)
        self._library_gcodes = library_gcodes or (lambda _id: [])
        self._product = product or (lambda _id: None)
        self.db.executescript(SCHEMA)

    @property
    def currency(self) -> str:
        return self.cost.settings().currency

    # ================================================================ customers
    def create_customer(self, payload: CustomerCreate) -> Customer:
        name = payload.name.strip()
        if not name:
            raise BusinessError("business.customer.name_required", 422)
        now = time.time()
        customer_id = _new_id()
        self.db.execute(
            "INSERT INTO customers(id, name, phone, email, address, notes, created_at, updated_at) "
            "VALUES (?,?,?,?,?,?,?,?)",
            (customer_id, name, payload.phone.strip(), payload.email.strip(),
             payload.address.strip(), payload.notes, now, now),
        )
        customer = self.get_customer(customer_id)
        assert customer is not None
        return customer

    def get_customer(self, customer_id: str) -> Optional[Customer]:
        row = self.db.query_one("SELECT * FROM customers WHERE id = ?", (customer_id,))
        return self._customer(dict(row)) if row else None

    def list_customers(self, search: str = "") -> List[Customer]:
        if search.strip():
            like = f"%{search.strip()}%"
            rows = self.db.query(
                "SELECT * FROM customers WHERE name LIKE ? OR phone LIKE ? ORDER BY name",
                (like, like),
            )
        else:
            rows = self.db.query("SELECT * FROM customers ORDER BY updated_at DESC")
        return [self._customer(dict(row)) for row in rows]

    def update_customer(self, customer_id: str, payload: CustomerUpdate) -> Optional[Customer]:
        current = self.get_customer(customer_id)
        if current is None:
            return None
        data = current.model_dump()
        for key, value in payload.model_dump(exclude_none=True).items():
            data[key] = value.strip() if isinstance(value, str) and key != "notes" else value
        if not data["name"]:
            raise BusinessError("business.customer.name_required", 422)
        now = time.time()
        self.db.execute(
            "UPDATE customers SET name=?, phone=?, email=?, address=?, notes=?, updated_at=? WHERE id=?",
            (data["name"], data["phone"], data["email"], data["address"], data["notes"], now, customer_id),
        )
        # Keep the name printed on their orders in step.
        self.db.execute(
            "UPDATE orders SET customer_name = ? WHERE customer_id = ?", (data["name"], customer_id)
        )
        return self.get_customer(customer_id)

    def delete_customer(self, customer_id: str) -> bool:
        """Remove the record. Their orders stay, still under their name."""
        cursor = self.db.execute("DELETE FROM customers WHERE id = ?", (customer_id,))
        return cursor.rowcount > 0

    def _customer(self, data: dict) -> Customer:
        orders = [
            self._assemble(dict(row))
            for row in self.db.query(
                "SELECT * FROM orders WHERE customer_id = ? AND status != 'cancelled'", (data["id"],)
            )
        ]
        data["order_count"] = len(orders)
        data["total_ordered"] = _money(sum(order.total for order in orders))
        data["total_paid"] = _money(sum(order.paid for order in orders))
        data["balance"] = _money(sum(order.balance for order in orders))
        return Customer(**data)

    # =================================================================== orders
    def create_order(self, payload: OrderCreate) -> Order:
        customer_name = payload.customer_name.strip()
        if payload.customer_id:
            customer = self.db.query_one("SELECT name FROM customers WHERE id = ?", (payload.customer_id,))
            if customer is None:
                raise BusinessError("business.customer.not_found", 404)
            customer_name = customer["name"]
        now = time.time()
        order_id = _new_id()
        row = self.db.query_one("SELECT COALESCE(MAX(number), 0) AS top FROM orders")
        number = int(row["top"] or 0) + 1 if row else 1
        self.db.execute(
            """
            INSERT INTO orders(id, number, customer_id, customer_name, status, due_date, discount,
                shipping, notes, currency, created_at, updated_at, delivered_at)
            VALUES (?,?,?,?, 'new', ?,?,?,?,?,?,?, NULL)
            """,
            (order_id, number, payload.customer_id, customer_name, payload.due_date,
             max(0.0, payload.discount), max(0.0, payload.shipping), payload.notes,
             self.currency, now, now),
        )
        for position, item in enumerate(payload.items):
            self._insert_item(order_id, item, position)
        if payload.deposit > 0:
            self.add_payment(order_id, PaymentCreate(amount=payload.deposit, method=payload.deposit_method,
                                                     note="deposit"))
        order = self.get_order(order_id)
        assert order is not None
        return order

    def get_order(self, order_id: str) -> Optional[Order]:
        row = self.db.query_one("SELECT * FROM orders WHERE id = ?", (order_id,))
        return self._assemble(dict(row)) if row else None

    def list_orders(
        self,
        *,
        status: Optional[str] = None,
        customer_id: Optional[str] = None,
        open_only: bool = False,
        limit: int = 200,
    ) -> List[Order]:
        clauses: List[str] = []
        params: List[object] = []
        if status:
            clauses.append("status = ?")
            params.append(status)
        if customer_id:
            clauses.append("customer_id = ?")
            params.append(customer_id)
        if open_only:
            clauses.append("status IN ('new', 'in_production', 'ready')")
        where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
        rows = self.db.query(
            f"SELECT * FROM orders {where} ORDER BY created_at DESC LIMIT ?", (*params, int(limit))
        )
        return [self._assemble(dict(row)) for row in rows]

    def update_order(self, order_id: str, payload: OrderUpdate) -> Optional[Order]:
        order = self.get_order(order_id)
        if order is None:
            return None
        changes = payload.model_dump(exclude_none=True)
        if "status" in changes and changes["status"] not in ORDER_STATUSES:
            raise BusinessError("business.order.bad_status", 422)
        if "customer_id" in changes:
            customer = self.db.query_one("SELECT name FROM customers WHERE id = ?", (changes["customer_id"],))
            if customer is None:
                raise BusinessError("business.customer.not_found", 404)
            changes["customer_name"] = customer["name"]

        data = order.model_dump()
        data.update(changes)
        delivered_at = order.delivered_at
        if changes.get("status") == "delivered" and order.status != "delivered":
            delivered_at = time.time()
        elif "status" in changes and changes["status"] != "delivered":
            delivered_at = None
        self.db.execute(
            """
            UPDATE orders SET customer_id=?, customer_name=?, status=?, due_date=?, discount=?,
                shipping=?, notes=?, updated_at=?, delivered_at=? WHERE id=?
            """,
            (data["customer_id"], data["customer_name"], data["status"], data["due_date"],
             max(0.0, data["discount"]), max(0.0, data["shipping"]), data["notes"],
             time.time(), delivered_at, order_id),
        )
        return self.get_order(order_id)

    def delete_order(self, order_id: str) -> bool:
        """Delete an order that has no money against it.

        An order somebody paid for is part of the books: it is cancelled, not
        erased, so the payment still has something to belong to.
        """
        order = self.get_order(order_id)
        if order is None:
            return False
        if order.payments:
            raise BusinessError("business.order.has_payments")
        self.db.execute("DELETE FROM orders WHERE id = ?", (order_id,))
        return True

    # -------------------------------------------------------------- order items
    def add_item(self, order_id: str, payload: OrderItemCreate) -> Optional[Order]:
        if self.db.query_one("SELECT id FROM orders WHERE id = ?", (order_id,)) is None:
            return None
        row = self.db.query_one(
            "SELECT COALESCE(MAX(position), -1) AS top FROM order_items WHERE order_id = ?", (order_id,)
        )
        self._insert_item(order_id, payload, int(row["top"]) + 1 if row else 0)
        self._touch(order_id)
        return self.get_order(order_id)

    def update_item(self, order_item_id: str, payload: OrderItemUpdate) -> Optional[Order]:
        row = self.db.query_one("SELECT * FROM order_items WHERE id = ?", (order_item_id,))
        if row is None:
            return None
        data = dict(row)
        for key, value in payload.model_dump(exclude_none=True).items():
            data[key] = value
        data["quantity"] = max(1, int(data["quantity"]))
        data["printed"] = min(max(0, int(data["printed"])), data["quantity"])
        self.db.execute(
            "UPDATE order_items SET name=?, quantity=?, unit_price=?, unit_cost=?, printed=? WHERE id=?",
            (data["name"], data["quantity"], max(0.0, data["unit_price"]), max(0.0, data["unit_cost"]),
             data["printed"], order_item_id),
        )
        self._advance(data["order_id"])
        self._touch(data["order_id"])
        return self.get_order(data["order_id"])

    def remove_item(self, order_item_id: str) -> Optional[Order]:
        row = self.db.query_one("SELECT order_id FROM order_items WHERE id = ?", (order_item_id,))
        if row is None:
            return None
        self.db.execute("DELETE FROM order_items WHERE id = ?", (order_item_id,))
        self._touch(row["order_id"])
        return self.get_order(row["order_id"])

    def record_printed(self, order_item_id: str, count: int = 1) -> Optional[Order]:
        """Count finished parts against an order line (never past its quantity)."""
        row = self.db.query_one("SELECT order_id, quantity, printed FROM order_items WHERE id = ?",
                                (order_item_id,))
        if row is None:
            return None
        printed = min(int(row["quantity"]), max(0, int(row["printed"]) + int(count)))
        self.db.execute("UPDATE order_items SET printed = ? WHERE id = ?", (printed, order_item_id))
        self._advance(row["order_id"])
        self._touch(row["order_id"])
        return self.get_order(row["order_id"])

    def _insert_item(self, order_id: str, payload: OrderItemCreate, position: int) -> None:
        name = payload.name.strip()
        item_id = payload.item_id
        unit_price = payload.unit_price
        unit_cost = payload.unit_cost
        seconds: Optional[float] = None
        grams: Optional[float] = None

        if payload.product_id:
            product = self._product(payload.product_id)
            if product is None:
                raise BusinessError("business.product.not_found", 404)
            name = name or getattr(product, "name_ar", "") or getattr(product, "name_en", "")
            item_id = item_id or getattr(product, "item_id", None)
            if unit_price is None:
                unit_price = float(getattr(product, "selling_price", 0.0) or 0.0)
            if unit_cost is None:
                unit_cost = float(getattr(product, "print_cost", 0.0) or 0.0)

        if item_id:
            item = self._library_item(item_id)
            if item is not None:
                name = name or getattr(item, "name_ar", "") or getattr(item, "name_en", "")
                seconds = getattr(item, "estimated_seconds", None)
                grams = getattr(item, "estimated_filament_g", None)
                if (unit_price is None or unit_cost is None) and (seconds or grams):
                    breakdown = self.cost.calculate(
                        CostRequest(filament_grams=grams or 0.0, print_seconds=seconds or 0.0)
                    )
                    if unit_cost is None:
                        unit_cost = breakdown.cost_per_unit
                    if unit_price is None:
                        unit_price = breakdown.suggested_price_per_unit

        if not name:
            raise BusinessError("business.item.name_required", 422)
        self.db.execute(
            """
            INSERT INTO order_items(id, order_id, product_id, item_id, name, quantity, unit_price,
                unit_cost, printed, estimated_seconds, filament_g, position)
            VALUES (?,?,?,?,?,?,?,?,0,?,?,?)
            """,
            (_new_id(), order_id, payload.product_id, item_id, name, max(1, int(payload.quantity)),
             max(0.0, unit_price or 0.0), max(0.0, unit_cost or 0.0), seconds, grams, position),
        )

    def _advance(self, order_id: str) -> None:
        """Move an order along as its parts get made - never backwards past
        what a person set, and never out of delivered or cancelled."""
        order = self.get_order(order_id)
        if order is None or order.status in ("delivered", "cancelled", "ready"):
            return
        if order.units and order.printed >= order.units:
            status = "ready"
        elif order.printed > 0 or any(item.queued for item in order.items):
            status = "in_production"
        else:
            return
        if status != order.status:
            self.db.execute("UPDATE orders SET status = ? WHERE id = ?", (status, order_id))

    def _touch(self, order_id: str) -> None:
        self.db.execute("UPDATE orders SET updated_at = ? WHERE id = ?", (time.time(), order_id))

    # ------------------------------------------------------------- the queue
    def queue_plan(self, order_item_id: str, *, copies: Optional[int], gcode_path: Optional[str]
                   ) -> Tuple[OrderItem, str, int]:
        """What to send to the print queue for an order line.

        Returns (line, G-code path, copies). Refuses a line with nothing left
        to make, or with no sliced file to print it from.
        """
        order_id_row = self.db.query_one("SELECT order_id FROM order_items WHERE id = ?", (order_item_id,))
        if order_id_row is None:
            raise BusinessError("business.item.not_found", 404)
        order = self.get_order(order_id_row["order_id"])
        assert order is not None
        if order.status in ("delivered", "cancelled"):
            raise BusinessError("business.queue.order_closed")
        line = next(item for item in order.items if item.id == order_item_id)
        available = line.remaining - line.queued
        if available <= 0:
            raise BusinessError("business.queue.nothing_left")
        wanted = available if copies is None else max(1, min(int(copies), available))

        path = (gcode_path or "").strip()
        if not path and line.item_id:
            gcodes = self._library_gcodes(line.item_id)
            if gcodes:
                newest = gcodes[0]
                path = getattr(newest, "moonraker_path", None) or getattr(newest, "filename", "")
        if not path:
            raise BusinessError("business.queue.no_gcode")
        return line, path, wanted

    # ================================================================= payments
    def add_payment(self, order_id: str, payload: PaymentCreate) -> Optional[Order]:
        row = self.db.query_one("SELECT customer_id FROM orders WHERE id = ?", (order_id,))
        if row is None:
            return None
        if payload.amount <= 0:
            raise BusinessError("business.payment.amount", 422)
        method = payload.method if payload.method in PAYMENT_METHODS else "other"
        now = time.time()
        self.db.execute(
            "INSERT INTO payments(id, order_id, customer_id, amount, method, note, paid_at, created_at) "
            "VALUES (?,?,?,?,?,?,?,?)",
            (_new_id(), order_id, row["customer_id"], _money(payload.amount), method, payload.note,
             payload.paid_at or now, now),
        )
        self._touch(order_id)
        return self.get_order(order_id)

    def delete_payment(self, payment_id: str) -> bool:
        cursor = self.db.execute("DELETE FROM payments WHERE id = ?", (payment_id,))
        return cursor.rowcount > 0

    # ================================================================= expenses
    def add_expense(self, payload: ExpenseCreate) -> Expense:
        if payload.amount <= 0:
            raise BusinessError("business.expense.amount", 422)
        category = payload.category if payload.category in EXPENSE_CATEGORIES else "other"
        now = time.time()
        expense_id = _new_id()
        self.db.execute(
            "INSERT INTO expenses(id, category, amount, note, spent_at, created_at) VALUES (?,?,?,?,?,?)",
            (expense_id, category, _money(payload.amount), payload.note, payload.spent_at or now, now),
        )
        row = self.db.query_one("SELECT * FROM expenses WHERE id = ?", (expense_id,))
        return Expense(**dict(row))

    def list_expenses(self, start: Optional[float] = None, end: Optional[float] = None) -> List[Expense]:
        rows = self.db.query(
            "SELECT * FROM expenses WHERE spent_at >= ? AND spent_at < ? ORDER BY spent_at DESC",
            (start or 0.0, end or 1e12),
        )
        return [Expense(**dict(row)) for row in rows]

    def delete_expense(self, expense_id: str) -> bool:
        cursor = self.db.execute("DELETE FROM expenses WHERE id = ?", (expense_id,))
        return cursor.rowcount > 0

    # ================================================================= accounts
    def accounts(self, start: float, end: float, *, months: int = 6) -> Accounts:
        figures = self._period(start, end)
        orders = figures["orders"]
        receivables = sum(
            order.balance for order in (self._assemble(dict(row)) for row in self.db.query(
                "SELECT * FROM orders WHERE status != 'cancelled'"))
            if order.balance > 0
        )

        products: Dict[str, ProductFigures] = {}
        for order in orders:
            share = (order.total / order.subtotal) if order.subtotal else 0.0
            for item in order.items:
                entry = products.setdefault(item.name, ProductFigures(name=item.name))
                entry.units += item.quantity
                entry.revenue += item.line_total * share
                entry.profit += item.line_total * share - item.line_cost
        top = sorted(products.values(), key=lambda entry: entry.revenue, reverse=True)[:5]
        for entry in top:
            entry.revenue = _money(entry.revenue)
            entry.profit = _money(entry.profit)

        sales = figures["sales"]
        gross = sales - figures["cogs"]
        return Accounts(
            currency=self.currency,
            start=start,
            end=end,
            orders=len(orders),
            units=sum(order.units for order in orders),
            sales=_money(sales),
            cost_of_goods=_money(figures["cogs"]),
            gross_profit=_money(gross),
            gross_margin_percent=round(gross / sales * 100.0, 1) if sales else 0.0,
            overheads=_money(figures["overheads"]),
            net_profit=_money(gross - figures["overheads"]),
            cash_in=_money(figures["cash_in"]),
            cash_out=_money(figures["cash_out"]),
            cash_profit=_money(figures["cash_in"] - figures["cash_out"]),
            receivables=_money(receivables),
            average_order=_money(sales / len(orders)) if orders else 0.0,
            expenses_by_category={key: _money(value) for key, value in figures["by_category"].items()},
            top_products=top,
            months=self._months(end, months),
        )

    def _period(self, start: float, end: float) -> Dict[str, object]:
        orders = [
            self._assemble(dict(row)) for row in self.db.query(
                "SELECT * FROM orders WHERE created_at >= ? AND created_at < ? AND status != 'cancelled'",
                (start, end),
            )
        ]
        expenses = self.list_expenses(start, end)
        by_category: Dict[str, float] = {}
        for expense in expenses:
            by_category[expense.category] = by_category.get(expense.category, 0.0) + expense.amount
        cash_row = self.db.query_one(
            "SELECT COALESCE(SUM(amount), 0) AS total FROM payments WHERE paid_at >= ? AND paid_at < ?",
            (start, end),
        )
        return {
            "orders": orders,
            "sales": sum(order.total for order in orders),
            "cogs": sum(order.cost for order in orders),
            # Plastic is already inside each part's cost; counting the spool
            # purchase again here would charge for it twice.
            "overheads": sum(e.amount for e in expenses if e.category != "materials"),
            "cash_in": float(cash_row["total"] or 0.0) if cash_row else 0.0,
            "cash_out": sum(e.amount for e in expenses),
            "by_category": by_category,
        }

    def _months(self, end: float, count: int) -> List[MonthFigures]:
        anchor = datetime.fromtimestamp(max(end - 1, 0))
        year, month = anchor.year, anchor.month
        result: List[MonthFigures] = []
        for _ in range(max(0, count)):
            start = datetime(year, month, 1).timestamp()
            next_year, next_month = (year + 1, 1) if month == 12 else (year, month + 1)
            finish = datetime(next_year, next_month, 1).timestamp()
            figures = self._period(start, finish)
            sales = float(figures["sales"])
            result.append(MonthFigures(
                month=f"{year:04d}-{month:02d}",
                sales=_money(sales),
                cash_in=_money(figures["cash_in"]),
                cost_of_goods=_money(figures["cogs"]),
                expenses=_money(figures["overheads"]),
                profit=_money(sales - float(figures["cogs"]) - float(figures["overheads"])),
            ))
            year, month = (year - 1, 12) if month == 1 else (year, month - 1)
        return list(reversed(result))

    # =============================================================== production
    def production(
        self,
        *,
        now: Optional[float] = None,
        printing_seconds: Optional[Callable[[float], float]] = None,
    ) -> Production:
        """The factory floor: every part still to make, in the order it will
        be made (soonest due first), and when the machine gets to each."""
        moment = now if now is not None else time.time()
        orders = self.list_orders(open_only=True, limit=1000)
        lines: List[ProductionLine] = []
        for order in orders:
            for item in order.items:
                if item.remaining <= 0:
                    continue
                seconds_each = item.estimated_seconds
                if seconds_each is None and item.item_id:
                    library = self._library_item(item.item_id)
                    seconds_each = getattr(library, "estimated_seconds", None) if library else None
                lines.append(ProductionLine(
                    order_id=order.id,
                    order_number=order.number,
                    order_item_id=item.id,
                    customer_name=order.customer_name,
                    name=item.name,
                    item_id=item.item_id,
                    quantity=item.quantity,
                    printed=item.printed,
                    remaining=item.remaining,
                    queued=item.queued,
                    seconds_each=seconds_each,
                    remaining_seconds=(seconds_each or 0.0) * item.remaining,
                    due_date=order.due_date,
                    has_gcode=bool(item.item_id and self._library_gcodes(item.item_id)),
                ))
        lines.sort(key=lambda line: (line.due_date is None, line.due_date or 0.0, line.order_number))

        elapsed = 0.0
        for line in lines:
            if line.seconds_each:
                elapsed += line.remaining_seconds
                line.projected_finish = moment + elapsed
                line.late = bool(line.due_date and line.projected_finish > line.due_date)

        def utilisation(days: int) -> Optional[float]:
            if printing_seconds is None:
                return None
            window = days * 86400.0
            busy = printing_seconds(moment - window)
            return round(min(1.0, max(0.0, busy / window)), 3)

        hours = sum(line.remaining_seconds for line in lines) / 3600.0
        return Production(
            lines=lines,
            open_orders=len({line.order_id for line in lines}),
            units_remaining=sum(line.remaining for line in lines),
            hours_remaining=round(hours, 2),
            projected_clear=(moment + elapsed) if elapsed else None,
            late_lines=sum(1 for line in lines if line.late),
            utilisation_7d=utilisation(7),
            utilisation_30d=utilisation(30),
        )

    # ================================================================ assembly
    def _assemble(self, data: dict) -> Order:
        item_rows = self.db.query(
            "SELECT * FROM order_items WHERE order_id = ? ORDER BY position", (data["id"],)
        )
        queued = {
            row["order_item_id"]: int(row["total"])
            for row in self.db.query(
                "SELECT order_item_id, COUNT(*) AS total FROM print_queue "
                "WHERE order_item_id IS NOT NULL AND status IN ('waiting', 'printing') "
                "GROUP BY order_item_id"
            )
        }
        items: List[OrderItem] = []
        for row in item_rows:
            item = dict(row)
            item["line_total"] = _money(item["quantity"] * item["unit_price"])
            item["line_cost"] = _money(item["quantity"] * item["unit_cost"])
            item["remaining"] = max(0, item["quantity"] - item["printed"])
            item["queued"] = min(queued.get(item["id"], 0), item["remaining"])
            items.append(OrderItem(**item))
        payments = [
            Payment(**dict(row)) for row in self.db.query(
                "SELECT * FROM payments WHERE order_id = ? ORDER BY paid_at", (data["id"],)
            )
        ]
        subtotal = sum(item.line_total for item in items)
        total = max(0.0, subtotal - data["discount"] + data["shipping"])
        cost = sum(item.line_cost for item in items)
        paid = sum(payment.amount for payment in payments)
        units = sum(item.quantity for item in items)
        printed = sum(item.printed for item in items)
        remaining_seconds = sum((item.estimated_seconds or 0.0) * item.remaining for item in items)
        open_order = data["status"] in ("new", "in_production", "ready")
        return Order(
            **data,
            items=items,
            payments=payments,
            subtotal=_money(subtotal),
            total=_money(total),
            cost=_money(cost),
            profit=_money(total - cost),
            paid=_money(paid),
            balance=_money(total - paid) if data["status"] != "cancelled" else 0.0,
            units=units,
            printed=printed,
            progress=round(printed / units, 3) if units else 0.0,
            remaining_seconds=remaining_seconds,
            overdue=bool(open_order and data["due_date"] and data["due_date"] < time.time()
                         and data["status"] != "ready"),
        )


__all__ = ["BusinessStore", "BusinessError", "LIVE_STATUSES"]
