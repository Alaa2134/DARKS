"""Print history endpoints backed by SQLite."""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Query

from ..deps import get_state
from ..schemas import HistoryResponse, HistoryStats, OKResponse
from ..security import require_token
from ..state import AppState

router = APIRouter(dependencies=[Depends(require_token)])


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
