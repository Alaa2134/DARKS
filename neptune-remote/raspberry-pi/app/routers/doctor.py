"""Fix My Printer, guided calibration workflows, config versioning, G-code
inspection and the pre-print check.

Every endpoint that can move the printer routes through ``state.safety``.
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional

from fastapi import APIRouter, Body, Depends, HTTPException, Query
from pydantic import BaseModel, Field

from ..deps import get_state
from ..klipper import patterns
from ..vision import firstlayer
from ..klipper.calibration_status import build_status as build_calibration_status
from ..klipper.probe_check import (
    diagnose_accuracy as diagnose_probe_accuracy,
    diagnose_wiring as diagnose_probe_wiring,
    parse_probe_accuracy,
)
from ..klipper.macros import suggest as suggest_macros_for
from ..klipper.validator import NEPTUNE_3_PLUS, diff_configs, validate
from ..moonraker import MoonrakerError
from ..safety.engine import SafetyBlocked
from ..schemas import OKResponse
from ..security import require_token
from ..state import AppState

router = APIRouter(dependencies=[Depends(require_token)])


# --------------------------------------------------------------------------- #
# Fix My Printer
# --------------------------------------------------------------------------- #


@router.get("/doctor/diagnose")
async def diagnose(
    deep: bool = Query(default=False, description="Also query the probe and endstops"),
    state: AppState = Depends(get_state),
) -> Dict[str, Any]:
    """Full inspection. Read-only: it never moves the printer."""
    return await state.diagnose(deep=deep)


@router.get("/doctor/health")
async def health_cards(state: AppState = Depends(get_state)) -> Dict[str, Any]:
    """The Printer Health page: one card per subsystem."""
    report = await state.diagnose(deep=False)
    return {"overall": report["overall"], "cards": report["cards"], "summary": report["summary"]}


@router.post("/doctor/probe/query")
async def probe_query(state: AppState = Depends(get_state)) -> Dict[str, Any]:
    triggered = await state.query_probe()
    return {
        "triggered": triggered,
        "known": triggered is not None,
        "message": (
            "Probe is triggered" if triggered
            else "Probe is open" if triggered is False
            else "Could not read the probe"
        ),
    }


@router.post("/doctor/probe/diagnose")
async def probe_diagnose(
    pressed: bool = False,
    state: AppState = Depends(get_state),
) -> Dict[str, Any]:
    """Why the probe is not working, from what it actually reads.

    Called twice: once with the probe untouched, then again with `pressed=true`
    while the user holds something against it. Two readings separate four faults
    that Klipper reports identically as "homing failed" - a probe stuck on, a
    probe that never fires, an inverted pin, and one that is simply fine.

    Read-only. Nothing moves, nothing heats, and the config change it suggests
    is text for the user to apply.
    """
    reading = await state.query_probe()
    config = await state.refresh_live_config()
    probe_pin = ""
    if config is not None:
        section = config.probe_section
        probe_pin = (section.get("pin") or "") if section else ""

    if pressed:
        # The first reading is remembered so the pair can be judged together;
        # asking for it again would mean asking the user to let go.
        result = diagnose_probe_wiring(state.probe_at_rest, reading, probe_pin=probe_pin)
    else:
        state.probe_at_rest = reading
        result = diagnose_probe_wiring(reading, None, probe_pin=probe_pin)

    return result.to_dict()


@router.post("/doctor/probe/accuracy")
async def probe_accuracy(state: AppState = Depends(get_state)) -> Dict[str, Any]:
    """Measure how repeatable the probe is, and what tolerance it can meet.

    PROBE_ACCURACY drops the probe ten times in one spot. Its range is the thing
    `samples_tolerance` has to live with, so this is the one honest way to pick
    that number - and picking it without measuring is how this printer ended up
    unable to home at all.

    Moves Z, so it goes through the safety engine like every other command, and
    it needs the printer homed first.
    """
    try:
        output = await state.moonraker.run_gcode_and_collect(
            "PROBE_ACCURACY", settle=1.0, count=120
        )
    except MoonrakerError as exc:
        raise HTTPException(status_code=502, detail=exc.message) from exc

    measurement = parse_probe_accuracy(output)
    configured: Optional[float] = None
    config = await state.refresh_live_config()
    if config is not None and config.probe_section is not None:
        configured = config.probe_section.get_float("samples_tolerance")

    result = diagnose_probe_accuracy(measurement, configured)
    payload = result.to_dict()
    payload["raw"] = output[-2000:]
    return payload


@router.post("/doctor/endstops/query")
async def endstops_query(state: AppState = Depends(get_state)) -> Dict[str, Any]:
    return {"endstops": await state.query_endstops()}


# --------------------------------------------------------------------------- #
# Safe command execution
# --------------------------------------------------------------------------- #


class CommandRequest(BaseModel):
    command: str = Field(min_length=1, max_length=500)
    force: bool = False


@router.post("/doctor/command/evaluate")
async def evaluate_command(
    payload: CommandRequest,
    state: AppState = Depends(get_state),
) -> Dict[str, Any]:
    """What would happen if this command ran? Nothing is sent."""
    await state.ensure_status_fresh()
    await state.refresh_live_config()
    return state.safety.evaluate(payload.command, state.safety_context()).as_dict()


@router.post("/doctor/command/execute")
async def execute_command(
    payload: CommandRequest,
    state: AppState = Depends(get_state),
) -> Dict[str, Any]:
    """Run a command through the safety engine. A blocked command returns 409
    with the reasons, and nothing is sent to the printer."""
    await state.ensure_status_fresh()
    await state.refresh_live_config()
    try:
        decision = await state.safety.execute(
            payload.command, state.safety_context(), force=payload.force
        )
    except SafetyBlocked as blocked:
        raise HTTPException(status_code=409, detail=blocked.decision.as_dict()) from blocked
    return decision.as_dict()


@router.get("/doctor/command/audit")
async def command_audit(
    limit: int = Query(default=100, ge=1, le=400),
    state: AppState = Depends(get_state),
) -> Dict[str, Any]:
    return {"entries": state.safety.audit_log[-limit:]}


# --------------------------------------------------------------------------- #
# Guided workflows
# --------------------------------------------------------------------------- #


class WorkflowStartRequest(BaseModel):
    kind: str


@router.get("/doctor/workflows")
async def list_workflows(state: AppState = Depends(get_state)) -> Dict[str, Any]:
    from ..doctor.workflows import WORKFLOW_TITLES

    active = state.workflows.active
    return {
        "available": [{"kind": k, "title": v} for k, v in WORKFLOW_TITLES.items()],
        "active": active.as_dict() if active is not None else None,
    }


@router.post("/doctor/workflows/start")
async def start_workflow(
    payload: WorkflowStartRequest,
    state: AppState = Depends(get_state),
) -> Dict[str, Any]:
    await state.ensure_status_fresh()
    await state.refresh_live_config()
    try:
        workflow = state.workflows.start(payload.kind, config=state.live_config)
    except ValueError as error:
        raise HTTPException(status_code=404, detail=str(error)) from error
    except RuntimeError as error:
        raise HTTPException(status_code=409, detail=str(error)) from error
    return workflow.as_dict()


@router.post("/doctor/workflows/advance")
async def advance_workflow(
    force: bool = Query(default=False),
    state: AppState = Depends(get_state),
) -> Dict[str, Any]:
    await state.ensure_status_fresh()
    await state.refresh_live_config()
    try:
        workflow = await state.workflows.advance(force=force)
    except RuntimeError as error:
        raise HTTPException(status_code=409, detail=str(error)) from error
    return workflow.as_dict()


@router.post("/doctor/workflows/confirm")
async def confirm_workflow_step(
    payload: Dict[str, Any] = Body(default_factory=dict),
    state: AppState = Depends(get_state),
) -> Dict[str, Any]:
    try:
        workflow = await state.workflows.confirm(payload=payload)
    except RuntimeError as error:
        raise HTTPException(status_code=409, detail=str(error)) from error
    return workflow.as_dict()


@router.post("/doctor/workflows/repeat")
async def repeat_workflow_step(state: AppState = Depends(get_state)) -> Dict[str, Any]:
    try:
        workflow = await state.workflows.repeat_step()
    except RuntimeError as error:
        raise HTTPException(status_code=409, detail=str(error)) from error
    return workflow.as_dict()


@router.post("/doctor/workflows/goto/{step_id}")
async def goto_workflow_step(
    step_id: str,
    state: AppState = Depends(get_state),
) -> Dict[str, Any]:
    try:
        workflow = state.workflows.go_to_step(step_id)
    except (RuntimeError, ValueError) as error:
        raise HTTPException(status_code=409, detail=str(error)) from error
    return workflow.as_dict()


@router.post("/doctor/workflows/cancel")
async def cancel_workflow(state: AppState = Depends(get_state)) -> Dict[str, Any]:
    workflow = state.workflows.cancel()
    return workflow.as_dict() if workflow is not None else {"state": "idle"}


class TestZRequest(BaseModel):
    """One step of the Z Offset wizard."""

    delta: float = Field(description="Millimetres; negative moves the nozzle down")


@router.post("/doctor/calibrate/testz")
async def testz(
    payload: TestZRequest,
    state: AppState = Depends(get_state),
) -> Dict[str, Any]:
    await state.ensure_status_fresh()
    await state.refresh_live_config()
    command = f"TESTZ Z={payload.delta:+.3f}".replace("+", "+")
    try:
        decision = await state.safety.execute(command, state.safety_context(), force=True)
    except SafetyBlocked as blocked:
        raise HTTPException(status_code=409, detail=blocked.decision.as_dict()) from blocked
    return {
        "decision": decision.as_dict(),
        "session": state.calibration_session,
        "total_down_mm": round(state.testz_total_down, 3),
    }


# --------------------------------------------------------------------------- #
# printer.cfg versions
# --------------------------------------------------------------------------- #


@router.get("/config/live")
async def live_config(state: AppState = Depends(get_state)) -> Dict[str, Any]:
    config = await state.refresh_live_config(force=True)
    if config is None:
        raise HTTPException(status_code=503, detail=state.live_config_error or "printer.cfg unavailable")
    report = validate(config, profile=NEPTUNE_3_PLUS)
    known_good = state.config_store.last_known_good()
    return {
        "text": state.live_config_text,
        "sha256": state.live_config_sha,
        "sections": [s.raw_name for s in config.sections],
        "validation": report.as_dict(),
        "matches_known_good": bool(known_good and known_good.sha256 == state.live_config_sha),
        "known_good": known_good.as_dict() if known_good else None,
    }


@router.get("/config/macros/suggest")
async def suggest_macros(state: AppState = Depends(get_state)) -> Dict[str, Any]:
    """PRINT_START / PRINT_END built from this printer's own configuration.

    Read-only. Every coordinate and temperature comes from the live
    printer.cfg, and nothing is written - the response is text for the user to
    review, together with the reasoning behind each line.
    """
    config = await state.refresh_live_config(force=True)
    if config is None:
        raise HTTPException(
            status_code=503,
            detail=state.live_config_error or "printer.cfg unavailable",
        )
    return suggest_macros_for(config)


@router.get("/calibration/status")
async def calibration_status(state: AppState = Depends(get_state)) -> Dict[str, Any]:
    """Whether this printer is actually calibrated, and what to do first.

    The wizards for all three of these have existed for a while. What did not
    exist was an answer to the question people actually have - "is my printer
    calibrated?" - which meant the only way to find out was to open each wizard
    and run it.

    Read from the live printer.cfg, plus the last bed screw measurement, which
    is the one part of levelling the config records nothing about.
    """
    config = await state.refresh_live_config()
    if config is None:
        raise HTTPException(
            status_code=503,
            detail=state.live_config_error or "printer.cfg unavailable",
        )
    return build_calibration_status(config, state.last_screws_measurement())


@router.get("/calibration/tests")
async def calibration_tests(state: AppState = Depends(get_state)) -> Dict[str, Any]:
    """The extrusion calibrations this printer can run, and why not when it cannot.

    Every calibration this project had was about the bed. These four are about
    what the plastic looks like, and they are the ones nobody measures because
    measuring them normally means finding a test model and slicing it exactly
    right. Here the G-code is generated from printer.cfg instead.
    """
    config = await state.refresh_live_config()
    if config is None:
        raise HTTPException(
            status_code=503, detail=state.live_config_error or "printer.cfg unavailable"
        )
    return {"tests": patterns.available(config)}


@router.get("/calibration/tests/{test_id}")
async def calibration_test(
    test_id: str,
    nozzle_temp: float = Query(205.0, ge=150, le=350),
    bed_temp: float = Query(60.0, ge=0, le=130),
    state: AppState = Depends(get_state),
) -> Dict[str, Any]:
    """Generate one calibration print. Nothing is sent to the printer here."""
    builder = patterns.BUILDERS.get(test_id)
    if builder is None:
        raise HTTPException(status_code=404, detail=f"No calibration test '{test_id}'")

    config = await state.refresh_live_config()
    if config is None:
        raise HTTPException(
            status_code=503, detail=state.live_config_error or "printer.cfg unavailable"
        )

    kwargs: Dict[str, Any] = {"bed_temp": bed_temp}
    # The temperature tower sets its own hotend temperature per band.
    if test_id != "temperature":
        kwargs["nozzle_temp"] = nozzle_temp

    result = builder(config, **kwargs)
    if not result.ok:
        raise HTTPException(status_code=422, detail="; ".join(result.blockers))
    return result.to_dict()


@router.post("/calibration/flow/result")
async def calibration_flow_result(
    measured_mm: float = Query(..., gt=0, le=5),
    expected_mm: float = Query(..., gt=0, le=5),
    current_flow: float = Query(1.0, gt=0, le=2),
) -> Dict[str, Any]:
    """Turn a caliper reading into a flow multiplier.

    Refuses a reading half or double the expected width: that is a
    mismeasurement or the wrong wall, not a flow error, and acting on it would
    write a badly wrong multiplier into the profile.
    """
    flow = patterns.flow_from_measurement(expected_mm, measured_mm, current_flow)
    if flow is None:
        raise HTTPException(
            status_code=422,
            detail=(
                f"A {measured_mm:.2f} mm wall against an expected {expected_mm:.2f} mm "
                "is too far off to be flow. Check you measured a single wall, on the "
                "flat, and not across a seam."
            ),
        )
    return {
        "flow": flow,
        "previous_flow": current_flow,
        "change_percent": round((flow / current_flow - 1) * 100, 1),
        "note_ar": "الرقم ده بيتحط في بروفايل السلايسر، مش في printer.cfg.",
    }


@router.post("/calibration/pressure_advance/result")
async def calibration_pa_result(
    height_mm: float = Query(..., ge=0, le=500),
    start: float = Query(0.0, ge=0, le=2),
    step: float = Query(0.005, gt=0, le=0.5),
    layer_height: float = Query(0.2, gt=0, le=2),
) -> Dict[str, Any]:
    value = patterns.pressure_advance_from_height(
        height_mm, start=start, step=step, layer_height=layer_height
    )
    if value is None:
        raise HTTPException(
            status_code=422,
            detail=(
                "That height gives a pressure advance outside Klipper's usable "
                "range. Measure from the bottom of the tower, not the bed."
            ),
        )
    return {
        "pressure_advance": value,
        "command": f"SET_PRESSURE_ADVANCE ADVANCE={value}",
        "config_ar": (
            f"عشان تثبته، ضيف في [extruder] في printer.cfg:\n"
            f"pressure_advance: {value}"
        ),
        # Deliberately not offered as a one-tap write: this edits printer.cfg,
        # and this project never rewrites that file without an explicit,
        # separately-confirmed step that snapshots it first.
        "applies_immediately": False,
    }


@router.post("/calibration/first_layer/inspect")
async def inspect_first_layer(state: AppState = Depends(get_state)) -> Dict[str, Any]:
    """Photograph the printed first-layer patch and measure it.

    Returns a millimetre correction and the SET_GCODE_OFFSET command that
    applies it - or, when the image cannot support a measurement, says so and
    returns nothing to apply. There is deliberately no middle ground: a Z
    offset taken from a bad reading drives the nozzle into the bed, so a low
    confidence number is more dangerous here than no number at all.

    The command is returned, not executed. Applying it is a separate step the
    user takes after seeing what it is.
    """
    if not state.camera.status(probe_devices=False).available:
        raise HTTPException(
            status_code=503,
            detail="No camera is configured, so the first layer cannot be measured.",
        )

    config = await state.refresh_live_config()
    if config is None:
        raise HTTPException(
            status_code=503, detail=state.live_config_error or "printer.cfg unavailable"
        )

    pattern = patterns.first_layer_patch(config)
    if not pattern.ok:
        raise HTTPException(status_code=422, detail="; ".join(pattern.blockers))

    frame = await state.camera.snapshot()
    if not frame:
        raise HTTPException(status_code=503, detail="The camera returned no image.")

    result = firstlayer.analyse(
        frame,
        expected_spacing_mm=pattern.parameters["spacing_mm"],
        expected_width_mm=pattern.parameters["expected_width_mm"],
        first_layer_height_mm=pattern.parameters["first_layer_height_mm"],
        roi=state.config.camera.roi,
    )
    payload = result.to_dict()
    payload["pattern"] = pattern.parameters
    return payload


@router.get("/config/versions")
async def config_versions(state: AppState = Depends(get_state)) -> Dict[str, Any]:
    return {
        "versions": [v.as_dict() for v in state.config_store.list()],
        "golden": (state.config_store.golden().as_dict() if state.config_store.golden() else None),
    }


@router.post("/config/versions")
async def snapshot_config(
    payload: Dict[str, str] = Body(default_factory=dict),
    state: AppState = Depends(get_state),
) -> Dict[str, Any]:
    config = await state.refresh_live_config(force=True)
    if config is None:
        raise HTTPException(status_code=503, detail="printer.cfg unavailable")
    version = state.config_store.snapshot(
        state.live_config_text,
        label=payload.get("label", ""),
        reason="manual",
        note=payload.get("note", ""),
    )
    return version.as_dict()


@router.get("/config/versions/{version_id}")
async def config_version(version_id: str, state: AppState = Depends(get_state)) -> Dict[str, Any]:
    version = state.config_store.get(version_id)
    if version is None:
        raise HTTPException(status_code=404, detail="No such config version")
    payload = version.as_dict()
    payload["text"] = state.config_store.text(version_id) or ""
    return payload


@router.post("/config/versions/{version_id}/label")
async def label_config_version(
    version_id: str,
    payload: Dict[str, str] = Body(default_factory=dict),
    state: AppState = Depends(get_state),
) -> Dict[str, Any]:
    version = state.config_store.set_label(
        version_id, payload.get("label", ""), payload.get("note", "")
    )
    if version is None:
        raise HTTPException(status_code=404, detail="No such config version")
    return version.as_dict()


@router.post("/config/versions/{version_id}/golden")
async def mark_config_golden(version_id: str, state: AppState = Depends(get_state)) -> Dict[str, Any]:
    version = state.config_store.mark_golden(version_id)
    if version is None:
        raise HTTPException(status_code=404, detail="No such config version")
    return version.as_dict()


@router.delete("/config/versions/{version_id}", response_model=OKResponse)
async def delete_config_version(version_id: str, state: AppState = Depends(get_state)) -> OKResponse:
    if not state.config_store.delete(version_id):
        raise HTTPException(
            status_code=409,
            detail="A Golden config cannot be deleted. Clear the Golden flag first.",
        )
    return OKResponse(ok=True, message="Deleted")


@router.get("/config/diff")
async def config_diff(
    from_id: str = Query(...),
    to_id: Optional[str] = Query(default=None, description="Omit to diff against the live config"),
    state: AppState = Depends(get_state),
) -> Dict[str, Any]:
    if to_id is None:
        await state.refresh_live_config(force=True)
        result = state.config_store.diff_against(from_id, state.live_config_text)
    else:
        result = state.config_store.diff(from_id, to_id)
    if result is None:
        raise HTTPException(status_code=404, detail="One of the versions was not found")
    return result


class RestoreRequest(BaseModel):
    version_id: Optional[str] = None
    confirm: bool = False


@router.post("/config/restore")
async def restore_config(
    payload: RestoreRequest,
    state: AppState = Depends(get_state),
) -> Dict[str, Any]:
    """Write a stored version back to the printer and restart Klipper.

    Refuses while a print is running, and always snapshots the current config
    first so the restore itself can be undone.
    """
    if state.last_status.state in {"printing", "paused"}:
        raise HTTPException(status_code=409, detail="Cannot restore a config while a print is loaded.")

    version = (
        state.config_store.get(payload.version_id)
        if payload.version_id
        else state.config_store.last_known_good()
    )
    if version is None:
        raise HTTPException(
            status_code=404,
            detail="No known-good configuration is recorded. Mark one as Golden first.",
        )
    text = state.config_store.text(version.id)
    if text is None:
        raise HTTPException(status_code=410, detail="That version's file is no longer on disk")

    if not payload.confirm:
        await state.refresh_live_config(force=True)
        return {
            "requires_confirmation": True,
            "version": version.as_dict(),
            "diff": diff_configs(state.live_config_text, text),
        }

    await state.ensure_status_fresh()
    await state.refresh_live_config(force=True)
    state.config_store.snapshot(state.live_config_text, reason="pre_restore", label="Before restore")
    await state.moonraker.write_config_file("printer.cfg", text)
    await state.moonraker.restart_firmware()
    return {"restored": True, "version": version.as_dict()}


# --------------------------------------------------------------------------- #
# G-code inspection and preflight
# --------------------------------------------------------------------------- #


@router.get("/gcode/inspect")
async def inspect_gcode(
    filename: str = Query(...),
    state: AppState = Depends(get_state),
) -> Dict[str, Any]:
    """The G-code Inspector screen. Reads only."""
    try:
        report = await state.analyse_gcode_path(filename)
    except Exception as error:                            # noqa: BLE001
        raise HTTPException(status_code=404, detail=f"Could not read {filename}: {error}") from error
    return report.as_dict()


@router.get("/gcode/preflight")
async def preflight(
    filename: str = Query(...),
    strict: bool = Query(default=False),
    state: AppState = Depends(get_state),
) -> Dict[str, Any]:
    return await state.preflight(filename, strict=strict)


# --------------------------------------------------------------------------- #
# Golden slicer profiles
# --------------------------------------------------------------------------- #


class SlicerProfileRequest(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    settings: Dict[str, Any] = Field(default_factory=dict)
    engine: str = "prusaslicer"
    note: str = ""


@router.get("/slicer/profiles")
async def slicer_profiles(state: AppState = Depends(get_state)) -> Dict[str, Any]:
    return {
        "profiles": [p.as_dict() for p in state.slicer_profiles.list()],
        "golden_names": state.slicer_profiles.golden_names(),
    }


@router.post("/slicer/profiles")
async def save_slicer_profile(
    payload: SlicerProfileRequest,
    state: AppState = Depends(get_state),
) -> Dict[str, Any]:
    """Saving under an existing name creates a new version; it never modifies a
    stored one, Golden or otherwise."""
    profile = state.slicer_profiles.save(
        payload.name, payload.settings, engine=payload.engine, note=payload.note
    )
    return profile.as_dict()


@router.post("/slicer/profiles/{profile_id}/golden")
async def mark_profile_golden(profile_id: str, state: AppState = Depends(get_state)) -> Dict[str, Any]:
    profile = state.slicer_profiles.mark_golden(profile_id)
    if profile is None:
        raise HTTPException(status_code=404, detail="No such slicer profile")
    return profile.as_dict()


@router.delete("/slicer/profiles/{profile_id}", response_model=OKResponse)
async def delete_slicer_profile(profile_id: str, state: AppState = Depends(get_state)) -> OKResponse:
    if not state.slicer_profiles.delete(profile_id):
        raise HTTPException(
            status_code=409,
            detail="A Golden profile cannot be deleted. Clear the Golden flag first.",
        )
    return OKResponse(ok=True, message="Deleted")
