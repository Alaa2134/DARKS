"""The workshop: customers, orders, production, payments, expenses and accounts.

Every refusal carries a localisation key in ``detail`` so the app can say
exactly why ("this order has payments - cancel it instead") rather than
showing a status code.
"""

from __future__ import annotations

import time
from datetime import datetime
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, Query

from ..business.models import (
    Accounts,
    Customer,
    CustomerCreate,
    CustomerUpdate,
    Expense,
    ExpenseCreate,
    Order,
    OrderCreate,
    OrderItemCreate,
    OrderItemUpdate,
    OrderUpdate,
    PaymentCreate,
    Production,
    QueueOrderItem,
)
from ..business.store import BusinessError
from ..deps import get_state
from ..printqueue.store import QueueJob, QueueJobCreate
from ..schemas import OKResponse
from ..security import require_token
from ..state import AppState

router = APIRouter(prefix="/business", dependencies=[Depends(require_token)])


def _refuse(error: BusinessError) -> HTTPException:
    return HTTPException(status_code=error.status, detail=error.key)


def _found(value, what: str):
    if value is None:
        raise HTTPException(status_code=404, detail=f"business.{what}.not_found")
    return value


# --------------------------------------------------------------------------- customers
@router.get("/customers", response_model=List[Customer])
async def list_customers(search: str = "", state: AppState = Depends(get_state)) -> List[Customer]:
    return state.business.list_customers(search)


@router.post("/customers", response_model=Customer)
async def create_customer(payload: CustomerCreate, state: AppState = Depends(get_state)) -> Customer:
    try:
        return state.business.create_customer(payload)
    except BusinessError as error:
        raise _refuse(error)


@router.get("/customers/{customer_id}", response_model=Customer)
async def get_customer(customer_id: str, state: AppState = Depends(get_state)) -> Customer:
    return _found(state.business.get_customer(customer_id), "customer")


@router.patch("/customers/{customer_id}", response_model=Customer)
async def update_customer(customer_id: str, payload: CustomerUpdate,
                          state: AppState = Depends(get_state)) -> Customer:
    try:
        return _found(state.business.update_customer(customer_id, payload), "customer")
    except BusinessError as error:
        raise _refuse(error)


@router.delete("/customers/{customer_id}", response_model=OKResponse)
async def delete_customer(customer_id: str, state: AppState = Depends(get_state)) -> OKResponse:
    _found(state.business.delete_customer(customer_id) or None, "customer")
    return OKResponse(message="deleted")


# ------------------------------------------------------------------------------ orders
@router.get("/orders", response_model=List[Order])
async def list_orders(
    status: Optional[str] = None,
    customer_id: Optional[str] = None,
    open_only: bool = False,
    limit: int = Query(200, ge=1, le=1000),
    state: AppState = Depends(get_state),
) -> List[Order]:
    return state.business.list_orders(status=status, customer_id=customer_id,
                                      open_only=open_only, limit=limit)


@router.post("/orders", response_model=Order)
async def create_order(payload: OrderCreate, state: AppState = Depends(get_state)) -> Order:
    try:
        return state.business.create_order(payload)
    except BusinessError as error:
        raise _refuse(error)


@router.get("/orders/{order_id}", response_model=Order)
async def get_order(order_id: str, state: AppState = Depends(get_state)) -> Order:
    return _found(state.business.get_order(order_id), "order")


@router.patch("/orders/{order_id}", response_model=Order)
async def update_order(order_id: str, payload: OrderUpdate, state: AppState = Depends(get_state)) -> Order:
    try:
        return _found(state.business.update_order(order_id, payload), "order")
    except BusinessError as error:
        raise _refuse(error)


@router.delete("/orders/{order_id}", response_model=OKResponse)
async def delete_order(order_id: str, state: AppState = Depends(get_state)) -> OKResponse:
    try:
        _found(state.business.delete_order(order_id) or None, "order")
    except BusinessError as error:
        raise _refuse(error)
    return OKResponse(message="deleted")


@router.post("/orders/{order_id}/items", response_model=Order)
async def add_order_item(order_id: str, payload: OrderItemCreate,
                         state: AppState = Depends(get_state)) -> Order:
    try:
        return _found(state.business.add_item(order_id, payload), "order")
    except BusinessError as error:
        raise _refuse(error)


@router.patch("/order-items/{order_item_id}", response_model=Order)
async def update_order_item(order_item_id: str, payload: OrderItemUpdate,
                            state: AppState = Depends(get_state)) -> Order:
    return _found(state.business.update_item(order_item_id, payload), "item")


@router.delete("/order-items/{order_item_id}", response_model=Order)
async def remove_order_item(order_item_id: str, state: AppState = Depends(get_state)) -> Order:
    return _found(state.business.remove_item(order_item_id), "item")


@router.post("/order-items/{order_item_id}/printed", response_model=Order)
async def record_printed(order_item_id: str, count: int = Query(1, ge=-1000, le=1000),
                         state: AppState = Depends(get_state)) -> Order:
    """Count parts made outside the queue (or take back a miscount)."""
    return _found(state.business.record_printed(order_item_id, count), "item")


@router.post("/order-items/{order_item_id}/queue", response_model=List[QueueJob])
async def queue_order_item(order_item_id: str, payload: QueueOrderItem,
                           state: AppState = Depends(get_state)) -> List[QueueJob]:
    """Put copies of an order line on the print queue.

    Queuing never starts a print: the queue's own rules (a confirmed clear bed,
    or the opt-in sweep) still decide when each copy begins.
    """
    try:
        line, path, copies = state.business.queue_plan(
            order_item_id, copies=payload.copies, gcode_path=payload.gcode_path
        )
    except BusinessError as error:
        raise _refuse(error)
    order = state.business.get_order(line.order_id)
    label = f"#{order.number} · {line.name}" if order else line.name
    jobs = [
        state.queue.add(QueueJobCreate(
            gcode_path=path,
            item_id=line.item_id,
            display_name=label,
            estimated_seconds=line.estimated_seconds,
            filament_g=line.filament_g,
            order_item_id=line.id,
        ))
        for _ in range(copies)
    ]
    state.business.record_printed(line.id, 0)   # moves a new order into production
    return jobs


@router.post("/orders/{order_id}/payments", response_model=Order)
async def add_payment(order_id: str, payload: PaymentCreate, state: AppState = Depends(get_state)) -> Order:
    try:
        return _found(state.business.add_payment(order_id, payload), "order")
    except BusinessError as error:
        raise _refuse(error)


@router.delete("/payments/{payment_id}", response_model=OKResponse)
async def delete_payment(payment_id: str, state: AppState = Depends(get_state)) -> OKResponse:
    _found(state.business.delete_payment(payment_id) or None, "payment")
    return OKResponse(message="deleted")


# ---------------------------------------------------------------------------- expenses
@router.get("/expenses", response_model=List[Expense])
async def list_expenses(start: Optional[float] = None, end: Optional[float] = None,
                        state: AppState = Depends(get_state)) -> List[Expense]:
    return state.business.list_expenses(start, end)


@router.post("/expenses", response_model=Expense)
async def add_expense(payload: ExpenseCreate, state: AppState = Depends(get_state)) -> Expense:
    try:
        return state.business.add_expense(payload)
    except BusinessError as error:
        raise _refuse(error)


@router.delete("/expenses/{expense_id}", response_model=OKResponse)
async def delete_expense(expense_id: str, state: AppState = Depends(get_state)) -> OKResponse:
    _found(state.business.delete_expense(expense_id) or None, "expense")
    return OKResponse(message="deleted")


# ---------------------------------------------------------------------------- accounts
@router.get("/accounts", response_model=Accounts)
async def accounts(
    start: Optional[float] = None,
    end: Optional[float] = None,
    months: int = Query(6, ge=0, le=24),
    state: AppState = Depends(get_state),
) -> Accounts:
    """The books. Defaults to this calendar month."""
    if start is None or end is None:
        today = datetime.now()
        first = datetime(today.year, today.month, 1)
        following = datetime(today.year + (today.month == 12), today.month % 12 + 1, 1)
        start = start if start is not None else first.timestamp()
        end = end if end is not None else following.timestamp()
    if end <= start:
        raise HTTPException(status_code=422, detail="business.accounts.bad_period")
    return state.business.accounts(start, end, months=months)


# -------------------------------------------------------------------------- production
@router.get("/production", response_model=Production)
async def production(state: AppState = Depends(get_state)) -> Production:
    history = state.history
    return state.business.production(
        now=time.time(),
        printing_seconds=history.printing_seconds_since if history is not None else None,
    )
