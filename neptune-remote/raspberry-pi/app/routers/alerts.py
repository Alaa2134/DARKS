"""Notifications, the heartbeat, and the record of what the power cut off.

Everything a phone needs to answer three questions: will I be told, was I told,
and what happened while I was out.

Secrets never come back out of here. Channel credentials - ntfy tokens,
Telegram bot tokens, the heartbeat URL - live in ``config.yaml`` on the Pi and
are reported only as "configured" or "not configured". The phone can change
*which events* notify and *when*, because that is a preference; it cannot read
or set the credentials, because a sideloaded app is not a good place to keep
them.
"""

from __future__ import annotations

from typing import Any, Dict

from fastapi import APIRouter, Depends, HTTPException

from ..deps import get_state
from ..notify import all_event_kinds
from ..schemas import NotificationPreferencesRequest
from ..security import require_token
from ..state import AppState

router = APIRouter(dependencies=[Depends(require_token)])


@router.get("/alerts/status")
async def alerts_status(state: AppState = Depends(get_state)) -> Dict[str, Any]:
    """Is anything actually going to reach a phone that is out of the house?"""
    notifications = state.notifications.status()
    heartbeat = state.heartbeat.status()

    # Stated plainly rather than left for the app to infer: a printer with no
    # channel configured is a printer that will fail silently.
    reachable = notifications["configured"]
    return {
        "notifications": notifications,
        "heartbeat": heartbeat,
        "reachable_when_app_is_closed": reachable,
        "advice": _advice(reachable, heartbeat["enabled"]),
    }


def _advice(reachable: bool, heartbeat_enabled: bool) -> Dict[str, str]:
    if not reachable:
        return {
            "level": "warning",
            "ar": (
                "مفيش أي قناة إشعارات متظبطة. الإشعارات هتوصلك بس والتطبيق "
                "مفتوح قدامك - ولو حصلت مشكلة وانت بره مش هتعرف."
            ),
            "en": "No notification channel is configured; alerts only arrive while the app is open.",
        }
    if not heartbeat_enabled:
        return {
            "level": "info",
            "ar": (
                "الإشعارات شغالة. فاضل الـ heartbeat: لو الكهرباء فصلت عن "
                "الراسبيري نفسه، مفيش حاجة عليه تقدر تبعتلك - الحل إن خدمة "
                "برة تراقب توقف النبضات."
            ),
            "en": (
                "Notifications work. Without the heartbeat, an outage that "
                "takes the Pi down cannot report itself."
            ),
        }
    return {
        "level": "ok",
        "ar": "الإشعارات والـ heartbeat الاتنين شغالين.",
        "en": "Notifications and the heartbeat are both active.",
    }


@router.get("/alerts/preferences")
async def get_preferences(state: AppState = Depends(get_state)) -> Dict[str, Any]:
    return {
        "preferences": state.notifications.preferences.to_dict(),
        "available_events": all_event_kinds(),
        "critical_events": state.notifications.status()["critical_events"],
    }


@router.put("/alerts/preferences")
async def put_preferences(
    request: NotificationPreferencesRequest,
    state: AppState = Depends(get_state),
) -> Dict[str, Any]:
    updated = state.notifications.update_preferences(
        request.model_dump(exclude_none=True)
    )
    return {"preferences": updated.to_dict()}


@router.post("/alerts/test")
async def send_test(state: AppState = Depends(get_state)) -> Dict[str, Any]:
    """Prove delivery end to end, bypassing every filter.

    A test that quiet hours could silently swallow would be worse than no test
    at all: it would report success for a message nobody received.
    """
    if not state.notifications.available:
        raise HTTPException(
            status_code=409,
            detail=(
                "No notification channel is configured. Set notifications.ntfy "
                "or notifications.telegram in config.yaml on the Pi."
            ),
        )
    return await state.notifications.send_test()


@router.post("/alerts/heartbeat/test")
async def test_heartbeat(state: AppState = Depends(get_state)) -> Dict[str, Any]:
    if not state.heartbeat.enabled:
        raise HTTPException(
            status_code=409,
            detail="No heartbeat URL is configured (notifications.heartbeat.url).",
        )
    ok = await state.heartbeat.ping()
    return {"ok": ok, **state.heartbeat.status()}


@router.get("/alerts/history")
async def alert_history(limit: int = 25, state: AppState = Depends(get_state)) -> Dict[str, Any]:
    """Recent notifications *including the ones that were not sent*.

    The suppressed ones carry the reason, which is the only way to tell "the
    printer never said anything" apart from "quiet hours ate it".
    """
    return {"notifications": state.notifications.recent(max(1, min(limit, 100)))}


@router.get("/alerts/outage")
async def outage_status(state: AppState = Depends(get_state)) -> Dict[str, Any]:
    return state.outage.status()


@router.post("/alerts/outage/{record_id}/acknowledge")
async def acknowledge_outage(
    record_id: str, state: AppState = Depends(get_state)
) -> Dict[str, Any]:
    if not state.outage.acknowledge(record_id):
        raise HTTPException(status_code=404, detail="No outage with that id")
    return {"ok": True, "outage": state.outage.status()}
