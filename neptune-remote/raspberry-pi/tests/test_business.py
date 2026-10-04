"""The workshop: orders, production, payments, expenses and the books."""

from __future__ import annotations

import time
from datetime import datetime
from pathlib import Path
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from app.business.models import (
    CustomerCreate,
    CustomerUpdate,
    ExpenseCreate,
    OrderCreate,
    OrderItemCreate,
    OrderItemUpdate,
    OrderUpdate,
    PaymentCreate,
)
from app.business.store import BusinessError, BusinessStore
from app.cost.calculator import CostCalculator, CostSettings
from app.db import Database
from app.printqueue.store import PrintQueueStore, QueueJobCreate

from .test_api_extended import client, upload_model  # noqa: F401  (fixture)

STAND = SimpleNamespace(id="lib-stand", name_ar="حامل موبايل", name_en="Phone stand",
                        estimated_seconds=3600.0, estimated_filament_g=40.0)
GCODE = SimpleNamespace(moonraker_path="stand.gcode", filename="stand.gcode")
PRODUCT = SimpleNamespace(id="prod-1", item_id="lib-stand", name_ar="حامل موبايل مميز",
                          name_en="", selling_price=150.0, print_cost=45.0)


@pytest.fixture()
def database(tmp_path: Path) -> Database:
    db = Database(tmp_path / "shop.db")
    yield db
    db.close()


@pytest.fixture()
def shop(database: Database) -> BusinessStore:
    cost = CostCalculator(database)
    cost.save_settings(CostSettings(currency="EGP", filament_price_per_kg=1000.0, labour_per_print=0.0,
                                    machine_hourly_rate=0.0, electricity_price_per_kwh=0.0,
                                    failure_rate_percent=0.0, profit_percent=100.0,
                                    round_selling_price_to=0.0))
    return BusinessStore(
        database, cost,
        library_item=lambda item_id: STAND if item_id == "lib-stand" else None,
        library_gcodes=lambda item_id: [GCODE] if item_id == "lib-stand" else [],
        product=lambda product_id: PRODUCT if product_id == "prod-1" else None,
    )


def make_order(shop: BusinessStore, **overrides):
    payload = dict(customer_name="أحمد", items=[OrderItemCreate(name="ميدالية", quantity=4, unit_price=25.0,
                                                               unit_cost=5.0)])
    payload.update(overrides)
    return shop.create_order(OrderCreate(**payload))


# --------------------------------------------------------------------------- orders
def test_an_order_adds_up_by_hand(shop: BusinessStore):
    order = make_order(shop, discount=10.0, shipping=30.0)
    assert order.number == 1
    assert order.subtotal == 100.0
    assert order.total == 120.0            # 100 - 10 + 30
    assert order.cost == 20.0
    assert order.profit == 100.0
    assert order.balance == 120.0
    assert order.status == "new"


def test_order_numbers_count_up(shop: BusinessStore):
    assert [make_order(shop).number for _ in range(3)] == [1, 2, 3]


def test_a_product_line_takes_its_price_and_cost_from_the_product(shop: BusinessStore):
    order = make_order(shop, items=[OrderItemCreate(product_id="prod-1", quantity=2)])
    line = order.items[0]
    assert line.name == "حامل موبايل مميز"
    assert (line.unit_price, line.unit_cost) == (150.0, 45.0)
    assert line.item_id == "lib-stand"        # so it can be queued from the library's slice


def test_a_library_line_is_priced_by_the_cost_calculator(shop: BusinessStore):
    order = make_order(shop, items=[OrderItemCreate(item_id="lib-stand", quantity=1)])
    line = order.items[0]
    assert line.unit_cost == pytest.approx(40.0)     # 40 g at 1000/kg, nothing else charged
    assert line.unit_price == pytest.approx(80.0)    # +100 %
    assert line.estimated_seconds == 3600.0


def test_a_line_without_a_name_is_refused(shop: BusinessStore):
    with pytest.raises(BusinessError) as error:
        make_order(shop, items=[OrderItemCreate(quantity=1, unit_price=5)])
    assert error.value.key == "business.item.name_required"


def test_a_deposit_is_recorded_as_a_payment(shop: BusinessStore):
    order = make_order(shop, deposit=40.0)
    assert order.paid == 40.0 and order.balance == 60.0
    assert order.payments[0].note == "deposit"


def test_printed_parts_move_the_order_along(shop: BusinessStore):
    order = make_order(shop)
    line = order.items[0]
    assert shop.record_printed(line.id, 1).status == "in_production"
    assert shop.record_printed(line.id, 10).items[0].printed == 4   # capped at the quantity
    assert shop.get_order(order.id).status == "ready"


def test_a_delivered_order_is_never_moved_back_by_a_count(shop: BusinessStore):
    order = make_order(shop)
    shop.update_order(order.id, OrderUpdate(status="delivered"))
    after = shop.record_printed(order.items[0].id, 1)
    assert after.status == "delivered" and after.delivered_at


def test_an_unknown_status_is_refused(shop: BusinessStore):
    order = make_order(shop)
    with pytest.raises(BusinessError):
        shop.update_order(order.id, OrderUpdate(status="shipped-maybe"))


def test_an_order_with_money_against_it_is_cancelled_not_deleted(shop: BusinessStore):
    paid = make_order(shop, deposit=10.0)
    with pytest.raises(BusinessError) as error:
        shop.delete_order(paid.id)
    assert error.value.key == "business.order.has_payments"
    unpaid = make_order(shop)
    assert shop.delete_order(unpaid.id) is True


def test_a_cancelled_order_owes_nothing(shop: BusinessStore):
    order = make_order(shop)
    assert shop.update_order(order.id, OrderUpdate(status="cancelled")).balance == 0.0


def test_editing_a_line_keeps_printed_inside_the_quantity(shop: BusinessStore):
    order = make_order(shop)
    line = order.items[0]
    shop.record_printed(line.id, 3)
    updated = shop.update_item(line.id, OrderItemUpdate(quantity=2))
    assert updated.items[0].quantity == 2 and updated.items[0].printed == 2


# ------------------------------------------------------------------------ customers
def test_a_customer_carries_their_balance(shop: BusinessStore):
    customer = shop.create_customer(CustomerCreate(name="  منى  ", phone="0100"))
    assert customer.name == "منى"
    make_order(shop, customer_id=customer.id, customer_name="", deposit=30.0)
    fresh = shop.get_customer(customer.id)
    assert (fresh.order_count, fresh.total_ordered, fresh.total_paid, fresh.balance) == (1, 100.0, 30.0, 70.0)


def test_renaming_a_customer_renames_their_orders(shop: BusinessStore):
    customer = shop.create_customer(CustomerCreate(name="منى"))
    order = make_order(shop, customer_id=customer.id)
    shop.update_customer(customer.id, CustomerUpdate(name="منى علي"))
    assert shop.get_order(order.id).customer_name == "منى علي"


def test_deleting_a_customer_keeps_their_orders_under_their_name(shop: BusinessStore):
    customer = shop.create_customer(CustomerCreate(name="منى"))
    order = make_order(shop, customer_id=customer.id)
    shop.delete_customer(customer.id)
    kept = shop.get_order(order.id)
    assert kept.customer_id is None and kept.customer_name == "منى"


def test_a_nameless_customer_is_refused(shop: BusinessStore):
    with pytest.raises(BusinessError):
        shop.create_customer(CustomerCreate(name="   "))


# ---------------------------------------------------------------------------- queue
def test_queue_plan_uses_the_library_slice_and_only_what_is_left(shop: BusinessStore, database: Database):
    order = make_order(shop, items=[OrderItemCreate(product_id="prod-1", quantity=3)])
    line = order.items[0]
    shop.record_printed(line.id, 1)
    _, path, copies = shop.queue_plan(line.id, copies=None, gcode_path=None)
    assert (path, copies) == ("stand.gcode", 2)

    queue = PrintQueueStore(database)
    queue.add(QueueJobCreate(gcode_path=path, order_item_id=line.id))
    _, _, copies = shop.queue_plan(line.id, copies=None, gcode_path=None)
    assert copies == 1                     # one is already waiting


def test_a_line_with_no_slice_cannot_be_queued(shop: BusinessStore):
    order = make_order(shop)
    with pytest.raises(BusinessError) as error:
        shop.queue_plan(order.items[0].id, copies=None, gcode_path=None)
    assert error.value.key == "business.queue.no_gcode"


def test_a_finished_line_cannot_be_queued(shop: BusinessStore):
    order = make_order(shop)
    shop.record_printed(order.items[0].id, 4)
    with pytest.raises(BusinessError) as error:
        shop.queue_plan(order.items[0].id, copies=None, gcode_path="x.gcode")
    assert error.value.key == "business.queue.nothing_left"


# ------------------------------------------------------------------------- accounts
def _month() -> tuple:
    today = datetime.now()
    start = datetime(today.year, today.month, 1).timestamp()
    end = datetime(today.year + (today.month == 12), today.month % 12 + 1, 1).timestamp()
    return start, end


def test_the_books_balance_by_hand(shop: BusinessStore):
    start, end = _month()
    make_order(shop, deposit=60.0)                                     # sale 100, cost 20
    make_order(shop, items=[OrderItemCreate(name="فازة", quantity=1, unit_price=200.0, unit_cost=50.0)])
    cancelled = make_order(shop)
    shop.update_order(cancelled.id, OrderUpdate(status="cancelled"))
    shop.add_expense(ExpenseCreate(category="rent", amount=30.0))
    shop.add_expense(ExpenseCreate(category="materials", amount=500.0))  # a spool

    books = shop.accounts(start, end, months=3)
    assert books.orders == 2
    assert books.sales == 300.0
    assert books.cost_of_goods == 70.0
    assert books.gross_profit == 230.0
    assert books.overheads == 30.0          # the spool is inside the parts' cost already
    assert books.net_profit == 200.0
    assert books.cash_in == 60.0
    assert books.cash_out == 530.0
    assert books.cash_profit == -470.0
    assert books.receivables == 240.0       # 40 + 200, the cancelled one owes nothing
    assert books.expenses_by_category == {"rent": 30.0, "materials": 500.0}
    assert books.top_products[0].name == "فازة"
    assert len(books.months) == 3 and books.months[-1].sales == 300.0


def test_an_empty_month_is_all_zeros(shop: BusinessStore):
    start, end = _month()
    books = shop.accounts(start, end)
    assert (books.sales, books.net_profit, books.gross_margin_percent, books.average_order) == (0, 0, 0, 0)


def test_expenses_and_payments_must_be_positive(shop: BusinessStore):
    with pytest.raises(BusinessError):
        shop.add_expense(ExpenseCreate(amount=0))
    order = make_order(shop)
    with pytest.raises(BusinessError):
        shop.add_payment(order.id, PaymentCreate(amount=-5))


# ----------------------------------------------------------------------- production
def test_the_floor_is_ordered_by_due_date_and_flags_what_will_be_late(shop: BusinessStore):
    now = time.time()
    later = make_order(shop, due_date=now + 10 * 86400,
                       items=[OrderItemCreate(product_id="prod-1", quantity=2)])
    urgent = make_order(shop, due_date=now + 3600,
                        items=[OrderItemCreate(product_id="prod-1", quantity=3)])
    floor = shop.production(now=now, printing_seconds=lambda since: 7 * 86400 * 0.25)
    assert [line.order_id for line in floor.lines] == [urgent.id, later.id]
    assert floor.lines[0].remaining_seconds == 3 * 3600
    assert floor.lines[0].late is True       # 3 h of printing, due in 1 h
    assert floor.lines[1].late is False
    assert floor.units_remaining == 5 and floor.hours_remaining == 5.0
    assert floor.late_lines == 1
    assert floor.utilisation_7d == 0.25
    assert floor.lines[0].has_gcode is True


def test_finished_and_closed_orders_leave_the_floor(shop: BusinessStore):
    done = make_order(shop)
    shop.record_printed(done.items[0].id, 4)
    gone = make_order(shop)
    shop.update_order(gone.id, OrderUpdate(status="delivered"))
    assert shop.production(now=time.time()).lines == []


# ------------------------------------------------------------------------------ API
def test_the_whole_flow_over_the_api(client: TestClient):
    item = upload_model(client)
    customer = client.post("/api/business/customers", json={"name": "سارة", "phone": "0111"}).json()
    order = client.post("/api/business/orders", json={
        "customer_id": customer["id"],
        "items": [{"item_id": item["id"], "quantity": 2, "unit_price": 120, "unit_cost": 30}],
        "deposit": 100,
    })
    assert order.status_code == 200, order.text
    order = order.json()
    assert order["customer_name"] == "سارة" and order["balance"] == 140.0

    # No slice yet: the app is told why in words it can show.
    line_id = order["items"][0]["id"]
    refused = client.post(f"/api/business/order-items/{line_id}/queue", json={})
    assert refused.status_code == 409 and refused.json()["detail"] == "business.queue.no_gcode"

    jobs = client.post(f"/api/business/order-items/{line_id}/queue", json={"gcode_path": "stand.gcode"})
    assert jobs.status_code == 200, jobs.text
    assert len(jobs.json()) == 2 and jobs.json()[0]["order_item_id"] == line_id
    assert client.get(f"/api/business/orders/{order['id']}").json()["status"] == "in_production"

    printed = client.post(f"/api/business/order-items/{line_id}/printed", params={"count": 2}).json()
    assert printed["status"] == "ready"

    paid = client.post(f"/api/business/orders/{order['id']}/payments", json={"amount": 140, "method": "wallet"})
    assert paid.json()["balance"] == 0.0
    delivered = client.patch(f"/api/business/orders/{order['id']}", json={"status": "delivered"}).json()
    assert delivered["delivered_at"]

    client.post("/api/business/expenses", json={"category": "shipping", "amount": 25})
    books = client.get("/api/business/accounts").json()
    assert books["sales"] == 240.0 and books["cash_in"] == 240.0 and books["overheads"] == 25.0
    floor = client.get("/api/business/production").json()
    assert floor["lines"] == []


def test_api_refusals_carry_keys(client: TestClient):
    assert client.get("/api/business/orders/nope").json()["detail"] == "business.order.not_found"
    bad = client.post("/api/business/customers", json={"name": " "})
    assert bad.status_code == 422 and bad.json()["detail"] == "business.customer.name_required"
    start = time.time()
    bad_period = client.get("/api/business/accounts", params={"start": start, "end": start - 1})
    assert bad_period.status_code == 422


def test_a_queued_part_that_finishes_is_counted_against_its_order(client: TestClient):
    """The whole point of linking the queue: nobody has to tick parts off."""
    import asyncio

    from app.schemas import PrinterStatusResponse

    order = client.post("/api/business/orders", json={
        "customer_name": "كريم", "items": [{"name": "ترس", "quantity": 2, "unit_price": 50}],
    }).json()
    line_id = order["items"][0]["id"]
    job = client.post(f"/api/business/order-items/{line_id}/queue",
                      json={"gcode_path": "gear.gcode", "copies": 1}).json()[0]

    services = client.app.state.services
    services.queue.mark(job["id"], "printing")
    status = PrinterStatusResponse(online=True, state="complete", filename="gear.gcode")
    asyncio.run(services._finish_print(status, result="completed"))

    after = client.get(f"/api/business/orders/{order['id']}").json()
    assert after["items"][0]["printed"] == 1
    assert after["status"] == "in_production"


def test_a_failed_part_is_not_counted(client: TestClient):
    import asyncio

    from app.schemas import PrinterStatusResponse

    order = client.post("/api/business/orders", json={
        "customer_name": "كريم", "items": [{"name": "ترس", "quantity": 1, "unit_price": 50}],
    }).json()
    line_id = order["items"][0]["id"]
    job = client.post(f"/api/business/order-items/{line_id}/queue", json={"gcode_path": "gear.gcode"}).json()[0]
    services = client.app.state.services
    services.queue.mark(job["id"], "printing")
    status = PrinterStatusResponse(online=True, state="error", filename="gear.gcode")
    asyncio.run(services._finish_print(status, result="error"))
    assert client.get(f"/api/business/orders/{order['id']}").json()["items"][0]["printed"] == 0
