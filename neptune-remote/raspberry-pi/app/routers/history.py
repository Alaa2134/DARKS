"""Print history endpoints backed by SQLite."""

from __future__ import annotations

from typing import Any, Dict

from fastapi import APIRouter, Depends, HTTPException, Query

from ..deps import get_state
from ..schemas import HistoryResponse, HistoryStats, OKResponse
from ..security import require_token
from ..state import AppState

router = APIRouter(dependencies=[Depends(require_token)])


@router.get("/history/learning")
async def history_learning(state: AppState = Depends(get_state)) -> Dict[str, Any]:
    """What this printer's own results say about what works on it.

    Not general advice - a count of what happened on this machine, with this
    filament, at this layer height. Which makes the sample size the whole
    story: nothing is claimed below the minimum, and everything claimed carries
    its count, because "PETG fails half the time" from two prints is noise
    wearing a percentage sign.
    """
    return state.learning_report()


@router.get("/history", response_model=HistoryResponse)
async def history(
    limit: int = Query(100, ge=1, le=500),
    offset: int = Query(0, ge=0),
    state: AppState = Depends(get_state),
) -> HistoryResponse:
    if state.history is None:
        return HistoryResponse(entries=[], stats=HistoryStats())
    return HistoryResponse(
        entries=state.history.list(limit=limit, offset=offset),
        stats=state.history.stats(),
    )


@router.get("/history/stats", response_model=HistoryStats)
async def history_stats(state: AppState = Depends(get_state)) -> HistoryStats:
    if state.history is None:
        return HistoryStats()
    return state.history.stats()


@router.delete("/history/{entry_id}", response_model=OKResponse)
async def delete_history(entry_id: int, state: AppState = Depends(get_state)) -> OKResponse:
    if state.history is None:
        raise HTTPException(status_code=404, detail="History is disabled")
    if not state.history.delete(entry_id):
        raise HTTPException(status_code=404, detail="History entry not found")
    return OKResponse(ok=True, message="Deleted")
