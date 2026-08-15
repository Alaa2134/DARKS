"""Filament inventory, cost calculator, products, maintenance and the print queue."""

from __future__ import annotations

from typing import Any, Dict, List, Optional

from fastapi import APIRouter, Body, Depends, HTTPException, Query

from ..cost.calculator import CostBreakdown, CostRequest, CostSettings
from ..deps import get_state
from ..filament.store import FilamentCheck, Spool, SpoolCreate, SpoolUpdate, grams_from_mm
from ..maintenance.store import MaintenanceStatus, MaintenanceTask
from ..printqueue.store import QueueJob, QueueJobCreate, QueueState
from ..products.store import Product, ProductCreate, ProductUpdate
from ..schemas import OKResponse
from ..security import require_token
from ..state import AppState

router = APIRouter(dependencies=[Depends(require_token)])


# --------------------------------------------------------------------------- #
# Filament
# --------------------------------------------------------------------------- #


@router.get("/filament", response_model=List[Spool])
async def list_spools(
    include_archived: bool = False, state: AppState = Depends(get_state)
) -> List[Spool]:
    return state.filament.list(include_archived=include_archived)


@router.get("/filament/summary")
async def filament_summary(state: AppState = Depends(get_state)) -> Dict[str, Any]:
    return state.filament.summary()


@router.post("/filament", response_model=Spool)
async def create_spool(payload: SpoolCreate, state: AppState = Depends(get_state)) -> Spool:
    return state.filament.create(payload)


@router.get("/filament/{spool_id}", response_model=Spool)
async def get_spool(spool_id: str, state: AppState = Depends(get_state)) -> Spool:
    spool = state.filament.get(spool_id)
    if spool is None:
        raise HTTPException(status_code=404, detail="Spool not found")
    return spool


@router.patch("/filament/{spool_id}", response_model=Spool)
async def update_spool(
    spool_id: str, payload: SpoolUpdate, state: AppState = Depends(get_state)
) -> Spool:
    spool = state.filament.update(spool_id, payload)
    if spool is None:
        raise HTTPException(status_code=404, detail="Spool not found")
    return spool


@router.post("/filament/{spool_id}/active", response_model=Spool)
async def activate_spool(spool_id: str, state: AppState = Depends(get_state)) -> Spool:
    spool = state.filament.set_active(spool_id)
    if spool is None:
        raise HTTPException(status_code=404, detail="Spool not found")
    return spool


@router.post("/filament/{spool_id}/consume", response_model=Spool)
async def consume_filament(
    spool_id: str,
    grams: float = Body(..., embed=True, gt=0),
    reason: str = Body("manual", embed=True),
    state: AppState = Depends(get_state),
) -> Spool:
    spool = state.filament.consume(grams, spool_id=spool_id, reason=reason)
    if spool is None:
        raise HTTPException(status_code=404, detail="Spool not found")
    return spool


@router.delete("/filament/{spool_id}", response_model=OKResponse)
async def delete_spool(spool_id: str, state: AppState = Depends(get_state)) -> OKResponse:
    if not state.filament.delete(spool_id):
        raise HTTPException(status_code=404, detail="Spool not found")
    return OKResponse(ok=True, message="Spool deleted")


@router.get("/filament/check/estimate", response_model=FilamentCheck)
async def check_filament(
    grams: Optional[float] = Query(None, ge=0),
    millimetres: Optional[float] = Query(None, ge=0),
    material: Optional[str] = None,
    spool_id: Optional[str] = None,
    state: AppState = Depends(get_state),
) -> FilamentCheck:
    """Is there enough filament for a print of this size?"""
    if grams is None and millimetres is None:
        raise HTTPException(status_code=400, detail="Provide grams or millimetres")
    required = grams if grams is not None else grams_from_mm(millimetres or 0.0, material or "PLA")
    return state.filament.check_enough(required, material=material, spool_id=spool_id)


# --------------------------------------------------------------------------- #
# Cost
# --------------------------------------------------------------------------- #


@router.get("/cost/settings", response_model=CostSettings)
async def cost_settings(state: AppState = Depends(get_state)) -> CostSettings:
    return state.cost.settings()


@router.put("/cost/settings", response_model=CostSettings)
async def save_cost_settings(
    settings: CostSettings, state: AppState = Depends(get_state)
) -> CostSettings:
    return state.cost.save_settings(settings)


@router.post("/cost/calculate", response_model=CostBreakdown)
async def calculate_cost(request: CostRequest, state: AppState = Depends(get_state)) -> CostBreakdown:
    price_per_kg: Optional[float] = None
    if request.spool_id:
        spool = state.filament.get(request.spool_id)
        if spool is not None and spool.initial_grams > 0 and spool.price > 0:
            price_per_kg = spool.price / (spool.initial_grams / 1000.0)
    return state.cost.calculate(request, filament_price_per_kg=price_per_kg)


# --------------------------------------------------------------------------- #
# Products
# --------------------------------------------------------------------------- #


@router.get("/products", response_model=List[Product])
async def list_products(state: AppState = Depends(get_state)) -> List[Product]:
    return state.products.list()


@router.get("/products/summary")
async def products_summary(state: AppState = Depends(get_state)) -> Dict[str, Any]:
    return state.products.summary()


@router.post("/products", response_model=Product)
async def create_product(payload: ProductCreate, state: AppState = Depends(get_state)) -> Product:
    if payload.item_id and state.library.get_item(payload.item_id) is None:
        raise HTTPException(status_code=404, detail="Linked model not found")
    return state.products.create(payload)


@router.get("/products/{product_id}", response_model=Product)
async def get_product(product_id: str, state: AppState = Depends(get_state)) -> Product:
    product = state.products.get(product_id)
    if product is None:
        raise HTTPException(status_code=404, detail="Product not found")
    return product


@router.patch("/products/{product_id}", response_model=Product)
async def update_product(
    product_id: str, payload: ProductUpdate, state: AppState = Depends(get_state)
) -> Product:
    product = state.products.update(product_id, payload)
    if product is None:
        raise HTTPException(status_code=404, detail="Product not found")
    return product


@router.delete("/products/{product_id}", response_model=OKResponse)
async def delete_product(product_id: str, state: AppState = Depends(get_state)) -> OKResponse:
    if not state.products.delete(product_id):
        raise HTTPException(status_code=404, detail="Product not found")
    return OKResponse(ok=True, message="Product deleted")


# --------------------------------------------------------------------------- #
# Maintenance
# --------------------------------------------------------------------------- #


@router.get("/maintenance", response_model=MaintenanceStatus)
async def maintenance_status(state: AppState = Depends(get_state)) -> MaintenanceStatus:
    totals = state.totals()
    return state.maintenance.status(
        total_prints=int(totals["total_prints"]),
        total_print_hours=totals["total_print_hours"],
        total_filament_grams=totals["total_filament_grams"],
    )


@router.post("/maintenance/{task_id}/complete", response_model=MaintenanceTask)
async def complete_maintenance(
    task_id: str,
    note: str = Body("", embed=True),
    state: AppState = Depends(get_state),
) -> MaintenanceTask:
    totals = state.totals()
    task = state.maintenance.complete(
        task_id,
        total_prints=int(totals["total_prints"]),
        total_print_hours=totals["total_print_hours"],
        note=note,
    )
    if task is None:
        raise HTTPException(status_code=404, detail="Task not found")
    return task


@router.post("/maintenance", response_model=MaintenanceTask)
async def create_maintenance_task(
    name_ar: str = Body(..., embed=True),
    name_en: str = Body("", embed=True),
    icon: str = Body("wrench", embed=True),
    interval_hours: Optional[float] = Body(None, embed=True),
    interval_prints: Optional[int] = Body(None, embed=True),
    interval_days: Optional[int] = Body(None, embed=True),
    state: AppState = Depends(get_state),
) -> MaintenanceTask:
    return state.maintenance.create(
        name_ar=name_ar, name_en=name_en, icon=icon,
        interval_hours=interval_hours, interval_prints=interval_prints,
        interval_days=interval_days,
    )


@router.delete("/maintenance/{task_id}", response_model=OKResponse)
async def delete_maintenance_task(task_id: str, state: AppState = Depends(get_state)) -> OKResponse:
    if not state.maintenance.delete(task_id):
        raise HTTPException(status_code=400, detail="Built-in tasks cannot be deleted")
    return OKResponse(ok=True, message="Task deleted")


@router.get("/maintenance/log")
async def maintenance_log(
    limit: int = Query(50, ge=1, le=500), state: AppState = Depends(get_state)
) -> List[Dict[str, Any]]:
    return state.maintenance.log(limit=limit)


# --------------------------------------------------------------------------- #
# Print queue
# --------------------------------------------------------------------------- #


@router.get("/queue", response_model=QueueState)
async def queue_state(state: AppState = Depends(get_state)) -> QueueState:
    return state.queue.state(printer_state=state.last_status.state)


@router.post("/queue", response_model=QueueJob)
async def add_to_queue(payload: QueueJobCreate, state: AppState = Depends(get_state)) -> QueueJob:
    return state.queue.add(payload)


@router.post("/queue/reorder", response_model=List[QueueJob])
async def reorder_queue(
    ids: List[str] = Body(..., embed=True), state: AppState = Depends(get_state)
) -> List[QueueJob]:
    return state.queue.reorder(ids)


@router.delete("/queue/{job_id}", response_model=OKResponse)
async def remove_from_queue(job_id: str, state: AppState = Depends(get_state)) -> OKResponse:
    if not state.queue.remove(job_id):
        raise HTTPException(status_code=404, detail="Job not found")
    return OKResponse(ok=True, message="Removed from the queue")


@router.post("/queue/bed-clear", response_model=QueueState)
async def confirm_bed_clear(
    clear: bool = Body(True, embed=True), state: AppState = Depends(get_state)
) -> QueueState:
    """The user confirms the finished part has been removed."""
    state.queue.set_bed_clear(clear)
    return state.queue.state(printer_state=state.last_status.state)


@router.get("/queue/auto")
async def queue_auto_status(state: AppState = Depends(get_state)) -> Dict[str, Any]:
    """Whether the queue may run itself, and what is stopping it."""
    from ..printqueue import auto

    conditions = await state.queue_auto_conditions()
    decision = auto.decide(conditions)
    return {
        "enabled": conditions.enabled,
        "has_eject_macro": conditions.has_eject_macro,
        "action": decision.action,
        "reason_key": decision.reason_key,
        "detail_ar": decision.detail_ar,
        "blockers_ar": auto.blockers(conditions),
    }


@router.post("/queue/auto")
async def set_queue_auto(
    enabled: bool = Body(..., embed=True), state: AppState = Depends(get_state)
) -> Dict[str, Any]:
    """Turn the automatic queue on or off.

    Turning it on with no ejector macro installed is allowed and reported
    rather than refused: the switch is the user saying what they want, and the
    screen shows what is still missing for it to happen.
    """
    state.set_queue_auto_continue(enabled)
    return await queue_auto_status(state)


@router.post("/queue/start-next")
async def start_next_job(state: AppState = Depends(get_state)) -> Dict[str, Any]:
    """Start the next queued print - only if the bed was confirmed clear."""
    from ..moonraker import MoonrakerError

    queue_state = state.queue.state(printer_state=state.last_status.state)
    if queue_state.blocked_reason_key:
        raise HTTPException(status_code=409, detail=queue_state.blocked_reason_key)

    job = state.queue.take_next(printer_state=state.last_status.state)
    if job is None:
        raise HTTPException(status_code=409, detail="queue.blocked.empty")

    try:
        await state.moonraker.start_print(job.gcode_path)
    except MoonrakerError as exc:
        state.queue.mark(job.id, "waiting")
        raise HTTPException(status_code=502, detail=exc.message) from exc

    return {"ok": True, "job": job.model_dump()}
