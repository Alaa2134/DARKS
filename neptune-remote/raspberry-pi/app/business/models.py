"""Workshop models: customers, orders, payments and expenses.

Money is stored as plain floats in one currency (the cost settings' currency),
because this is a small workshop's book, not a bank: every figure the API
returns is derived from these rows with arithmetic you can check by hand.
"""

from __future__ import annotations

from typing import Dict, List, Optional

from pydantic import BaseModel, Field

ORDER_STATUSES = ("new", "in_production", "ready", "delivered", "cancelled")
#: Orders that still count as business. A cancelled order owes nothing and
#: earns nothing.
LIVE_STATUSES = ("new", "in_production", "ready", "delivered")
EXPENSE_CATEGORIES = (
    "materials", "electricity", "parts", "rent", "shipping", "marketing", "salaries", "other",
)
PAYMENT_METHODS = ("cash", "transfer", "wallet", "card", "other")


# ------------------------------------------------------------------ customers
class Customer(BaseModel):
    id: str
    name: str
    phone: str = ""
    email: str = ""
    address: str = ""
    notes: str = ""
    created_at: float = 0.0
    updated_at: float = 0.0
    # Derived
    order_count: int = 0
    total_ordered: float = 0.0
    total_paid: float = 0.0
    balance: float = 0.0


class CustomerCreate(BaseModel):
    name: str
    phone: str = ""
    email: str = ""
    address: str = ""
    notes: str = ""


class CustomerUpdate(BaseModel):
    name: Optional[str] = None
    phone: Optional[str] = None
    email: Optional[str] = None
    address: Optional[str] = None
    notes: Optional[str] = None


# --------------------------------------------------------------------- orders
class OrderItem(BaseModel):
    id: str
    order_id: str
    product_id: Optional[str] = None
    item_id: Optional[str] = None
    name: str
    quantity: int = 1
    unit_price: float = 0.0
    unit_cost: float = 0.0
    printed: int = 0
    estimated_seconds: Optional[float] = None
    filament_g: Optional[float] = None
    position: int = 0
    # Derived
    line_total: float = 0.0
    line_cost: float = 0.0
    remaining: int = 0
    queued: int = 0


class OrderItemCreate(BaseModel):
    product_id: Optional[str] = None
    item_id: Optional[str] = None
    name: str = ""
    quantity: int = 1
    #: Left out, the price comes from the product, or from the cost
    #: calculator's suggestion for a library item.
    unit_price: Optional[float] = None
    unit_cost: Optional[float] = None


class OrderItemUpdate(BaseModel):
    name: Optional[str] = None
    quantity: Optional[int] = None
    unit_price: Optional[float] = None
    unit_cost: Optional[float] = None
    printed: Optional[int] = None


class Payment(BaseModel):
    id: str
    order_id: Optional[str] = None
    customer_id: Optional[str] = None
    amount: float
    method: str = "cash"
    note: str = ""
    paid_at: float = 0.0
    created_at: float = 0.0


class PaymentCreate(BaseModel):
    amount: float
    method: str = "cash"
    note: str = ""
    paid_at: Optional[float] = None


class Order(BaseModel):
    id: str
    number: int
    customer_id: Optional[str] = None
    customer_name: str = ""
    status: str = "new"
    due_date: Optional[float] = None
    discount: float = 0.0
    shipping: float = 0.0
    notes: str = ""
    currency: str = "EGP"
    created_at: float = 0.0
    updated_at: float = 0.0
    delivered_at: Optional[float] = None
    items: List[OrderItem] = Field(default_factory=list)
    payments: List[Payment] = Field(default_factory=list)
    # Derived
    subtotal: float = 0.0
    total: float = 0.0
    cost: float = 0.0
    profit: float = 0.0
    paid: float = 0.0
    balance: float = 0.0
    units: int = 0
    printed: int = 0
    progress: float = 0.0
    remaining_seconds: float = 0.0
    overdue: bool = False


class OrderCreate(BaseModel):
    customer_id: Optional[str] = None
    #: A walk-in customer can be named without creating a record first.
    customer_name: str = ""
    due_date: Optional[float] = None
    discount: float = 0.0
    shipping: float = 0.0
    notes: str = ""
    items: List[OrderItemCreate] = Field(default_factory=list)
    deposit: float = 0.0
    deposit_method: str = "cash"


class OrderUpdate(BaseModel):
    customer_id: Optional[str] = None
    customer_name: Optional[str] = None
    status: Optional[str] = None
    due_date: Optional[float] = None
    discount: Optional[float] = None
    shipping: Optional[float] = None
    notes: Optional[str] = None


class QueueOrderItem(BaseModel):
    """Send copies of an order line to the print queue."""

    copies: Optional[int] = None
    gcode_path: Optional[str] = None


# ------------------------------------------------------------------- expenses
class Expense(BaseModel):
    id: str
    category: str = "other"
    amount: float
    note: str = ""
    spent_at: float = 0.0
    created_at: float = 0.0


class ExpenseCreate(BaseModel):
    category: str = "other"
    amount: float
    note: str = ""
    spent_at: Optional[float] = None


# ------------------------------------------------------------------- accounts
class MonthFigures(BaseModel):
    month: str               # "2026-10"
    sales: float = 0.0
    cash_in: float = 0.0
    cost_of_goods: float = 0.0
    expenses: float = 0.0
    profit: float = 0.0


class ProductFigures(BaseModel):
    name: str
    units: int = 0
    revenue: float = 0.0
    profit: float = 0.0


class Accounts(BaseModel):
    """The books for a period, in two honest views.

    *Orders view* (accrual): what was sold in the period, less what those
    parts cost to make, less the period's overheads.
    *Cash view*: money that actually came in, less money that actually went
    out. Neither is hidden inside the other; spool purchases logged as an
    expense are excluded from the orders view's overheads, because the cost of
    the plastic is already inside each part's cost.
    """

    currency: str = "EGP"
    start: float
    end: float
    orders: int = 0
    units: int = 0
    sales: float = 0.0
    cost_of_goods: float = 0.0
    gross_profit: float = 0.0
    gross_margin_percent: float = 0.0
    overheads: float = 0.0
    net_profit: float = 0.0
    cash_in: float = 0.0
    cash_out: float = 0.0
    cash_profit: float = 0.0
    receivables: float = 0.0
    average_order: float = 0.0
    expenses_by_category: Dict[str, float] = Field(default_factory=dict)
    top_products: List[ProductFigures] = Field(default_factory=list)
    months: List[MonthFigures] = Field(default_factory=list)


# ----------------------------------------------------------------- production
class ProductionLine(BaseModel):
    order_id: str
    order_number: int
    order_item_id: str
    customer_name: str = ""
    name: str
    item_id: Optional[str] = None
    quantity: int
    printed: int
    remaining: int
    queued: int = 0
    seconds_each: Optional[float] = None
    remaining_seconds: float = 0.0
    due_date: Optional[float] = None
    #: When this line would finish if the machine worked through the board in
    #: order, from now, without stopping.
    projected_finish: Optional[float] = None
    late: bool = False
    has_gcode: bool = False


class Production(BaseModel):
    lines: List[ProductionLine] = Field(default_factory=list)
    open_orders: int = 0
    units_remaining: int = 0
    hours_remaining: float = 0.0
    projected_clear: Optional[float] = None
    late_lines: int = 0
    utilisation_7d: Optional[float] = None
    utilisation_30d: Optional[float] = None
    printers: int = 1
