"""Application service container and background orchestration.

The monitor polls Moonraker, derives discrete printer events, and drives every
subsystem from one place:

    print started   -> history entry, recording, timelapse, vision monitor,
                       library print counter
    layer change    -> timelapse frame (layer mode), recording edge modes
    print finished  -> stop recording, render timelapse, stop vision,
                       subtract filament, close history, arm auto power off

Ordering rule enforced here: printer control and safety always win. Recording,
timelapse and vision failures are logged and surfaced, never fatal.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import time
import uuid
from pathlib import Path
from typing import Any, Dict, List, Optional

from . import system_info
from .backup.service import BackupService
from .camera.service import CameraService
from .config import AppConfig
from .cost.calculator import CostCalculator
from .db import Database
from .filament.store import FilamentStore, grams_from_mm
from .hub import EventHub
from .knowledge import translate_error
from .doctor.engine import DiagnosticInput, DiagnosticsEngine
from .doctor.workflows import WorkflowRunner
from .gcode.validator import GCodeReport, analyse_gcode
from .klipper.model import ParsedConfig, parse_config
from .klipper.store import ConfigStore
from .klipper.validator import NEPTUNE_3_PLUS
from .library.store import LibraryStore
from .preflight import PreflightReport, run_preflight
from .safety.engine import PrinterSafetyEngine, SafetyContext
from .slicer.golden import GoldenProfileStore
from .maintenance.store import MaintenanceStore
from .moonraker import MoonrakerClient, MoonrakerError
from .paths import StorageLayout
from .notify import HeartbeatPinger, NotificationService
from .power import (
    OutageWatcher,
    PowerError,
    PowerProvider,
    PowerState,
    build_power_provider,
    evaluate_power_off,
    snapshot_from_status,
)
from .printer_state import fetch_status
from .printqueue.store import PrintQueueStore
from .products.store import ProductStore
from .recording.service import RecordingError, RecordingService
from .recording.store import VideoStore
from .schemas import PrinterEvent, PrinterStatusResponse, SliceJob
from .slicer import ProfileStore, SliceJobManager, build_engine
from .storage import GCodeStore, HistoryDB, ModelStore
from .timelapse.service import TimelapseService
from .vision.detector import VisionDetector, VisionEvent

log = logging.getLogger("neptune.state")

PRINTER_POLL_SECONDS = 1.0
POWER_POLL_SECONDS = 15.0
TARGET_REACHED_TOLERANCE = 2.0

STATE_KEY_TOTAL_HOURS = "printer.total_print_hours"
STATE_KEY_TOTAL_PRINTS = "printer.total_prints"
STATE_KEY_TOTAL_FILAMENT = "printer.total_filament_grams"


class AppState:
    def __init__(self, config: AppConfig) -> None:
        self.config = config
        config.ensure_directories()
        paths = config.paths.resolved()

        # ---- storage ------------------------------------------------------
        self.layout = StorageLayout.create(config.storage.root)
        self.db = Database(self.layout.database / "neptune.db")

        # ---- printer ------------------------------------------------------
        self.moonraker = MoonrakerClient(config.moonraker)
        self.power: PowerProvider = build_power_provider(config, self.moonraker)
        self.profiles = ProfileStore(paths["profiles_dir"])
        # The library's own model folder is registered as a read-only extra
        # source so a library item can be sliced by its id directly.
        self.models = ModelStore(paths["models_dir"], extra_directories=[self.layout.models])
        self.gcodes = GCodeStore(paths["gcode_dir"])
        self.history = HistoryDB(paths["database"]) if config.history.enabled else None
        self.hub = EventHub()

        # ---- slicing ------------------------------------------------------
        self.engine = build_engine(
            config.slicer.engine,
            self.profiles,
            prusaslicer_bin=config.slicer.prusaslicer_bin,
            orcaslicer_bin=config.slicer.orcaslicer_bin,
            timeout=config.slicer.timeout_seconds,
        )
        self.slice_jobs = SliceJobManager(
            self.engine,
            self.models,
            self.gcodes,
            max_concurrent=config.slicer.max_concurrent_jobs,
            keep_jobs=config.slicer.keep_jobs,
        )
        self.slice_jobs.add_listener(self._on_slice_progress)

        # ---- product / library domain -------------------------------------
        self.library = LibraryStore(self.db, self.layout)
        self.filament = FilamentStore(self.db)
        self.cost = CostCalculator(self.db)
        self.products = ProductStore(self.db)
        self.maintenance = MaintenanceStore(self.db)
        self.queue = PrintQueueStore(self.db)
        self.backups = BackupService(config, self.layout)

        # ---- safety, diagnosis and calibration ----------------------------
        # Every printer command in this project goes through `self.safety`.
        # Nothing calls moonraker.run_gcode directly for movement.
        self.config_store = ConfigStore(self.db, self.layout.root / "config_versions")
        self.slicer_profiles = GoldenProfileStore(self.db)
        self.printer_profile = NEPTUNE_3_PLUS
        self.diagnostics = DiagnosticsEngine(profile=self.printer_profile)
        self.safety = PrinterSafetyEngine(
            runner=self._run_safe_gcode,
            on_backup=self._backup_before_save_config,
        )
        self.workflows = WorkflowRunner(
            self.safety, self.moonraker, context_factory=self.safety_context
        )
        #: Parsed live printer.cfg, refreshed on demand and cached.
        self.live_config: Optional[ParsedConfig] = None
        self.live_config_text: str = ""
        self.live_config_error: str = ""
        self.live_config_fetched_at: float = 0.0
        #: Probe / endstop readings, only ever set from a real query.
        self.probe_triggered: Optional[bool] = None
        self.endstop_states: Dict[str, str] = {}
        self.calibration_session: Optional[str] = None
        self.testz_total_down: float = 0.0
        self._last_status_at: float = 0.0

        # ---- alerting -----------------------------------------------------
        # The WebSocket only reaches a phone with the app open in the
        # foreground. Everything that matters when nobody is home goes out
        # through these instead.
        self.notifications = NotificationService(config.notifications, db=self.db)
        self.heartbeat = HeartbeatPinger(config.notifications.heartbeat)
        self.outage = OutageWatcher(
            self.layout.state,
            serial_path=config.outage.serial_path,
            snapshot_interval=config.outage.snapshot_interval_seconds,
        )
        #: Set once printer.cfg has been read, so [mcu] serial is discovered
        #: rather than assumed.
        self._outage_serial_resolved = bool(config.outage.serial_path)

        # ---- media --------------------------------------------------------
        self.camera = CameraService(config.camera, self.layout)
        self.videos = VideoStore(self.db, self.layout)
        self.recording = RecordingService(config.recording, self.camera, self.videos, self.layout)
        self.timelapse = TimelapseService(config.timelapse, self.camera, self.videos, self.layout)
        self.vision = VisionDetector(config.vision, self.camera, self.db, self.layout)

        self.recording.on_status = self._broadcast_recording
        self.timelapse.on_status = self._broadcast_timelapse
        self.vision.on_event = self._on_vision_event
        self.vision.on_pause_requested = self._vision_pause_print
        self.vision.printer_status = self._vision_printer_status
        self.vision.system_load = self._vision_system_load

        # ---- live state ---------------------------------------------------
        self.last_status: PrinterStatusResponse = PrinterStatusResponse(online=False)
        self.last_power: PowerState = PowerState()
        self.last_system: Dict[str, Any] = {}
        self.events: List[PrinterEvent] = []
        self.current_item_id: Optional[str] = None

        self._previous_state: Optional[str] = None
        self._previous_online: Optional[bool] = None
        self._previous_klippy: Optional[str] = None
        self._previous_layer: Optional[int] = None
        self._nozzle_target_pending = False
        self._bed_target_pending = False
        self._active_history_id: Optional[int] = None
        self._cooldown_started_at: Optional[float] = None
        self._auto_power_off_armed = False
        self._notified_halfway = False
        self._notified_first_layer = False
        self._print_started_at: Optional[float] = None
        self._extra_objects_ready = False

        self._tasks: List[asyncio.Task[Any]] = []
        self._stopping = asyncio.Event()

    # ------------------------------------------------------------- lifecycle
    async def start(self) -> None:
        self._stopping.clear()

        # Before anything else: did we come back from something that killed us
        # mid-print? This is the only chance to notice, because the evidence is
        # a file that the next print would overwrite.
        await self._reconcile_interrupted_print()

        self._tasks = [
            asyncio.create_task(self._printer_loop(), name="printer-loop"),
            asyncio.create_task(self._power_loop(), name="power-loop"),
            asyncio.create_task(self._system_loop(), name="system-loop"),
        ]
        if self.heartbeat.enabled:
            self._tasks.append(asyncio.create_task(self.heartbeat.run(), name="heartbeat"))
        log.info(
            "Neptune Remote started (moonraker=%s power=%s slicer=%s camera=%s vision=%s)",
            self.config.moonraker.base_url,
            self.power.name,
            self.engine.name,
            self.camera.status(probe_devices=False).source,
            self.vision.provider.name,
        )

    async def stop(self) -> None:
        self._stopping.set()
        for task in self._tasks:
            task.cancel()
        for task in self._tasks:
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await task
        self._tasks.clear()

        with contextlib.suppress(Exception):
            await self.vision.shutdown()
        with contextlib.suppress(Exception):
            await self.recording.shutdown()
        with contextlib.suppress(Exception):
            await self.timelapse.shutdown()
        with contextlib.suppress(Exception):
            await self.camera.aclose()

        # A clean stop means nothing was interrupted. Deleting the snapshot is
        # what makes its presence on the next boot meaningful.
        with contextlib.suppress(Exception):
            self.outage.clear()
        with contextlib.suppress(Exception):
            await self.notifications.aclose()
        with contextlib.suppress(Exception):
            await self.heartbeat.aclose()

        await self.moonraker.aclose()
        await self.power.aclose()
        if self.history is not None:
            self.history.close()
        self.db.close()

    # ---------------------------------------------------------------- events
    def _record_event(self, kind: str, title: str, message: str = "", filename: str = "") -> PrinterEvent:
        event = PrinterEvent(
            id=uuid.uuid4().hex[:12],
            kind=kind,
            timestamp=time.time(),
            title=title,
            message=message,
            filename=filename,
        )
        self.events.append(event)
        if len(self.events) > 200:
            del self.events[: len(self.events) - 200]
        return event

    async def _emit_event(self, kind: str, title: str, message: str = "", filename: str = "") -> None:
        event = self._record_event(kind, title, message, filename)
        await self.hub.broadcast("event", event.model_dump())

        # Same event, second delivery path. The broadcast above reaches an open
        # app; this one reaches a phone in a pocket on another network, which
        # is the only one that matters when something goes wrong at 3am.
        # A notification failure must never disturb the printer loop.
        with contextlib.suppress(Exception):
            await self.notifications.dispatch_event(
                kind,
                title=title,
                message=message,
                filename=filename,
                timestamp=event.timestamp,
            )

    # ------------------------------------------------------------ slice jobs
    async def _on_slice_progress(self, job: SliceJob) -> None:
        await self.hub.broadcast(
            "slice",
            {
                "id": job.id,
                "status": job.status,
                "progress": job.progress,
                "stage": job.stage,
                "stage_key": _slice_stage_key(job.stage, job.status),
                "output_filename": job.output_filename,
                "error": job.error,
                "stats": job.stats.model_dump(),
                "log_tail": job.logs[-5:],
            },
        )

    async def upload_sliced_gcode(self, job: SliceJob) -> None:
        """Post-slice hook: push into Moonraker and attach to the library."""
        request = job.request
        if request is None:
            return

        path = Path(job.output_path)
        moonraker_path: Optional[str] = None

        if request.upload_to_moonraker and path.is_file():
            try:
                result = await self.moonraker.upload_gcode(
                    path.name, path.read_bytes(), start_print=request.start_print_after_upload
                )
                item = result.get("item") if isinstance(result, dict) else None
                moonraker_path = str(item.get("path")) if isinstance(item, dict) else path.name
                job.moonraker_path = moonraker_path
                job.logs.append(f"Uploaded to Moonraker as {moonraker_path}")
            except (MoonrakerError, OSError) as exc:
                message = getattr(exc, "message", None) or str(exc)
                job.logs.append(f"Upload to Moonraker failed: {message}")

        # Link the slice back to the library item so the printing screen can
        # show the model picture instead of a filename.
        item_id = (request.custom_overrides or {}).get("__library_item_id") or None
        if item_id:
            self.library.add_gcode(
                item_id,
                filename=path.name,
                path=self.layout.relative(path) if path.is_file() else "",
                moonraker_path=moonraker_path,
                material=request.filament_profile,
                quality=request.print_profile,
                layer_height=job.stats.layer_height or request.layer_height,
                estimated_seconds=job.stats.estimated_time_seconds,
                filament_g=job.stats.filament_grams,
                layer_count=job.stats.layer_count,
                profile={
                    "printer_profile": request.printer_profile,
                    "filament_profile": request.filament_profile,
                    "print_profile": request.print_profile,
                    "layer_height": request.layer_height,
                    "infill_percent": request.infill_percent,
                    "supports": request.supports,
                },
            )

        await self._on_slice_progress(job)

    # ---------------------------------------------------------- printer loop
    async def _printer_loop(self) -> None:
        while not self._stopping.is_set():
            try:
                await self._ensure_extra_objects()
                status = await fetch_status(self.moonraker)
                await self._handle_status(status)
            except asyncio.CancelledError:
                raise
            except Exception:
                log.exception("Printer poll failed")
            with contextlib.suppress(asyncio.TimeoutError):
                await asyncio.wait_for(self._stopping.wait(), timeout=PRINTER_POLL_SECONDS)

    async def _handle_status(self, status: PrinterStatusResponse) -> None:
        previous = self.last_status
        self.last_status = status
        self._last_status_at = time.time()

        payload = status.model_dump()
        payload["item"] = self._current_item_payload()
        await self.hub.broadcast("printer", payload)

        # ---- connectivity --------------------------------------------------
        if self._previous_online is not None and self._previous_online != status.online:
            if status.online:
                await self._emit_event("connected", "Printer reconnected")
            else:
                await self._emit_event(
                    "disconnected", "Printer disconnected",
                    status.error or "Moonraker is unreachable",
                )
        self._previous_online = status.online

        # ---- power loss, told apart from a Klipper crash --------------------
        detection = await self._check_outage(status)

        # ---- klipper errors ------------------------------------------------
        klippy = status.klippy_state
        if klippy != self._previous_klippy and klippy in {"shutdown", "error"}:
            already_reported = detection is not None and detection.cause in {
                "printer_power",
                "mcu_lost",
            }
            if not already_reported:
                raw = status.klippy_message or status.state_message or klippy
                translated = translate_error(raw)
                await self._emit_event("klipper_error", translated.title_en or "Klipper error", raw)
        self._previous_klippy = klippy

        # ---- mirror the running print to disk -------------------------------
        self._track_inflight_print(status)

        # ---- filament ------------------------------------------------------
        await self._check_filament(previous, status)

        # ---- print lifecycle -----------------------------------------------
        state = status.state
        if self._previous_state is not None and state != self._previous_state:
            await self._handle_state_transition(self._previous_state, state, status)
        elif self._previous_state is None and state == "printing":
            self._ensure_history_entry(status)
            self.current_item_id = self._resolve_item_id(status.filename)
        self._previous_state = state

        # ---- layer changes -------------------------------------------------
        if status.current_layer is not None and status.current_layer != self._previous_layer:
            previous_layer = self._previous_layer
            self._previous_layer = status.current_layer
            if previous_layer is not None and status.state == "printing":
                await self._handle_layer_change(status)

        # ---- progress milestones -------------------------------------------
        if status.state == "printing" and status.progress >= 0.5 and not self._notified_halfway:
            self._notified_halfway = True
            await self._emit_event("print_halfway", "Print is 50% done", status.filename, status.filename)

        # ---- target temperature reached -------------------------------------
        await self._check_targets(previous, status)

        # ---- automatic power off --------------------------------------------
        await self._check_auto_power_off(status)

    async def _ensure_extra_objects(self) -> None:
        """Ask Klipper once what else it has worth polling.

        Deferred to the loop rather than done at construction because Klipper
        is frequently not up yet when the backend starts, and retried until it
        answers - a printer that gains a filament sensor after a config change
        is picked up on the next Klipper restart.
        """
        if self._extra_objects_ready:
            return
        if not self.last_status.online or self.last_status.klippy_state != "ready":
            return
        with contextlib.suppress(Exception):
            discovered = await self.moonraker.discover_extra_objects()
            self._extra_objects_ready = True
            if discovered:
                log.info("Also polling: %s", ", ".join(discovered))

    # ------------------------------------------------------------- filament
    async def _check_filament(
        self, previous: PrinterStatusResponse, status: PrinterStatusResponse
    ) -> None:
        """Report a runout as itself, not as a generic pause.

        Klipper's `pause_on_runout: True` calls PAUSE, so without this the only
        thing anyone sees is "print paused" - which is also what a person
        pressing pause produces. The sensor state is read from the printer
        objects; the pause is the consequence, not the evidence.
        """
        for name, sensor in status.filament_sensors.items():
            if not sensor.enabled:
                continue
            was = previous.filament_sensors.get(name)
            if was is None or was.filament_detected == sensor.filament_detected:
                continue
            if sensor.filament_detected:
                continue

            # A switch cannot see a jam - only that the filament is gone. Say
            # exactly which of the two this printer can actually detect rather
            # than implying a safety net that is not installed.
            detail = (
                "الفيلامنت خلص أو اتقطع، والطباعة اتوقفت أوتوماتيك."
                if sensor.kind == "switch"
                else "الفيلامنت وقف عن الحركة (خلص أو حصل انحشار)."
            )
            await self._emit_event("filament_runout", "Filament runout", detail, status.filename)

    # ------------------------------------------------------------- outages
    async def _resolve_outage_serial(self) -> None:
        """Learn the MCU device path from printer.cfg rather than assuming it.

        Without it every Klipper shutdown looks the same, so the watcher
        deliberately refuses to guess a cause - see OutageWatcher.serial_present.
        """
        if self._outage_serial_resolved:
            return
        config = self.live_config
        if config is None:
            with contextlib.suppress(Exception):
                config = await self.refresh_live_config()
        if config is None:
            return

        section = config.section("mcu")
        serial = (section.get("serial") if section else "") or ""
        self._outage_serial_resolved = True
        if serial:
            self.outage.serial_path = serial.strip()
            log.info("Outage detection is watching %s", self.outage.serial_path)
        else:
            # A CAN-bus or network MCU has no serial device to watch. Say so
            # once instead of silently reporting every shutdown as a power cut.
            log.info(
                "No [mcu] serial: in printer.cfg - power loss cannot be told "
                "apart from a Klipper shutdown on this machine."
            )

    async def _check_outage(self, status: PrinterStatusResponse):
        if not self.config.outage.enabled:
            return None

        await self._resolve_outage_serial()

        detection = self.outage.classify(
            klippy_state=status.klippy_state,
            klippy_message=status.klippy_message or status.state_message,
            online=status.online,
        )

        if detection is None:
            if self.outage.in_outage:
                record = self.outage.close_outage()
                if self.config.outage.notify_on_restore and record is not None:
                    await self._emit_event(
                        "power_restored",
                        "Power is back",
                        record.advice_ar(),
                        record.snapshot.filename if record.snapshot else "",
                    )
                    await self._maybe_power_off_after_outage(record)
            return None

        if not detection.is_outage or self.outage.in_outage:
            return detection

        snapshot = self.outage.live_snapshot if self._was_printing(status) else None
        record = self.outage.open_outage(detection, snapshot)

        kind = "power_lost" if detection.cause == "printer_power" else "print_interrupted"
        if not record.was_printing and detection.cause != "printer_power":
            # Klipper stopped with nothing running. Real, but not an emergency.
            kind = "klipper_error"

        await self._emit_event(
            kind,
            detection.cause.replace("_", " ").title(),
            f"{detection.detail}\n{record.advice_ar()}".strip(),
            record.snapshot.filename if record.snapshot else "",
        )

        # Tell the external watchdog too: if the outage also takes the Pi down
        # a moment later, this is the last thing that gets out.
        if record.was_printing:
            with contextlib.suppress(Exception):
                await self.heartbeat.ping(failing=True, body=record.detail)

        return detection

    def _was_printing(self, status: PrinterStatusResponse) -> bool:
        """Was a print running immediately before this?

        Read from the tracked snapshot, not from the current status: by the
        time Klipper reports a shutdown it has already forgotten the job.
        """
        if self.outage.live_snapshot is not None:
            return True
        return status.state in {"printing", "paused"}

    async def _maybe_power_off_after_outage(self, record) -> None:
        """Optionally cut mains once we know the print is dead.

        Off by default. Turning someone's printer off is an action, and the
        printer coming back to an idle, powered, un-homed state is not itself
        dangerous - Klipper starts with the heaters off.
        """
        if not self.config.outage.power_off_after_outage or not record.was_printing:
            return
        try:
            await self.power.turn_off()
            await self._emit_event(
                "auto_power_off", "Printer powered off after the outage", record.detail
            )
        except PowerError as exc:
            await self._emit_event(
                "auto_power_off_failed", "Could not power off after the outage", exc.message
            )

    def _track_inflight_print(self, status: PrinterStatusResponse) -> None:
        """Keep the on-disk mirror of the running print current."""
        if not self.config.outage.enabled:
            return
        if status.state not in {"printing", "paused"}:
            return
        with contextlib.suppress(Exception):
            self.outage.track(
                snapshot_from_status(
                    status,
                    started_at=self._print_started_at or 0.0,
                    item_id=self.current_item_id,
                )
            )

    async def _reconcile_interrupted_print(self) -> None:
        """Startup: find out whether we died in the middle of something."""
        if not self.config.outage.enabled:
            return

        record = None
        try:
            record = self.outage.reconcile_on_start()
        except Exception:
            # Suppressed so a bad snapshot cannot stop the backend starting,
            # but logged loudly: a silent failure here means the one thing this
            # whole path exists for - telling someone their print died while
            # they were out - just does not happen, and nothing says so.
            log.exception("Could not reconcile the interrupted print")
            return
        if record is None:
            return

        log.warning("Recovered an interrupted print: %s", record.detail)
        await self._emit_event(
            "print_interrupted" if record.cause == "pi_power" else "klipper_error",
            "A print was interrupted",
            f"{record.detail}\n{record.advice_ar()}".strip(),
            record.snapshot.filename if record.snapshot else "",
        )

        # Close the history row so the print does not sit "in progress" forever
        # and skew every total after it.
        if self.history is not None and record.snapshot:
            try:
                closed = self.history.close_open_entries(result="interrupted")
                if closed:
                    log.info("Closed %d interrupted print(s) in the history", closed)
            except Exception:
                log.exception("Could not close the interrupted print in the history")

    async def _handle_layer_change(self, status: PrinterStatusResponse) -> None:
        layer = status.current_layer or 0

        # Forced write: a layer boundary is the most useful moment to know
        # about after the fact, and it is the number a person actually asks
        # for - "how far did it get?"
        if self.config.outage.enabled:
            with contextlib.suppress(Exception):
                self.outage.track(
                    snapshot_from_status(
                        status,
                        started_at=self._print_started_at or 0.0,
                        item_id=self.current_item_id,
                    ),
                    force=True,
                )

        if layer == 2 and not self._notified_first_layer:
            self._notified_first_layer = True
            await self._emit_event(
                "first_layer_complete", "First layer complete", status.filename, status.filename
            )

        with contextlib.suppress(Exception):
            await self.timelapse.handle_layer_change()
        with contextlib.suppress(Exception):
            await self.recording.handle_layer_change(layer, status.total_layer)

    async def _handle_state_transition(
        self, old: str, new: str, status: PrinterStatusResponse
    ) -> None:
        filename = status.filename

        if new == "printing" and old in {"standby", "complete", "cancelled", "error", "unknown"}:
            self._print_started_at = time.time()
            self._notified_halfway = False
            self._notified_first_layer = False
            self._previous_layer = None
            self.current_item_id = self._resolve_item_id(filename)

            await self._emit_event("print_started", "Print started", filename, filename)
            self._ensure_history_entry(status)
            self._auto_power_off_armed = False
            self._cooldown_started_at = None

            with contextlib.suppress(Exception):
                await self.recording.handle_print_started(filename, self.current_item_id)
            with contextlib.suppress(Exception):
                await self.timelapse.handle_print_started(filename, self.current_item_id)
            with contextlib.suppress(Exception):
                await self.vision.handle_print_started()

        elif new == "printing" and old == "paused":
            await self._emit_event("print_resumed", "Print resumed", filename, filename)

        elif new == "paused":
            await self._emit_event("print_paused", "Print paused", filename, filename)

        elif new in {"complete", "cancelled", "error"}:
            result = {"complete": "completed", "cancelled": "cancelled", "error": "error"}[new]
            await self._finish_print(status, result=result)

    async def _finish_print(self, status: PrinterStatusResponse, *, result: str) -> None:
        filename = status.filename

        # We watched this print end, so nothing was lost to an outage. Removing
        # the mirror is what keeps a leftover file on the next boot meaningful.
        with contextlib.suppress(Exception):
            self.outage.clear()

        if result == "completed":
            await self._emit_event("print_finished", "Print finished", filename, filename)
        elif result == "cancelled":
            await self._emit_event("print_failed", "Print cancelled", filename, filename)
        else:
            await self._emit_event(
                "print_failed", "Print failed",
                status.state_message or "Printer reported an error", filename,
            )

        # Media first so the video is finalised while we still have the context.
        with contextlib.suppress(Exception):
            await self.recording.handle_print_finished(result)
        with contextlib.suppress(Exception):
            await self.timelapse.handle_print_finished(result)
        with contextlib.suppress(Exception):
            await self.vision.handle_print_finished()

        # Completion snapshot for the history card.
        snapshot_path: Optional[Path] = None
        if result == "completed" and self.camera.status(probe_devices=False).available:
            with contextlib.suppress(Exception):
                snapshot_path = await self.camera.save_snapshot(prefix="complete")

        history_id = self._close_history_entry(result, status, snapshot_path)

        # Filament accounting.
        used_grams = 0.0
        if status.filament_used_mm > 0:
            material = ""
            if self.current_item_id:
                item = self.library.get_item(self.current_item_id)
                material = item.recommended_material if item else ""
            active = self.filament.active_spool()
            used_grams = grams_from_mm(
                status.filament_used_mm, material or (active.material if active else "PLA")
            )
            if used_grams > 0:
                with contextlib.suppress(Exception):
                    self.filament.consume(used_grams, reason="print", history_id=history_id)

        # Library counters + totals for maintenance.
        if self.current_item_id and result == "completed":
            with contextlib.suppress(Exception):
                self.library.record_print(self.current_item_id)

        self._update_totals(status, used_grams, result)

        # Queue: mark the running job finished and require a clear bed.
        with contextlib.suppress(Exception):
            for job in self.queue.list():
                if job.status == "printing":
                    self.queue.mark(job.id, "done" if result == "completed" else "failed")
            self.queue.set_bed_clear(False)

        # Maintenance reminders.
        with contextlib.suppress(Exception):
            due = self._maintenance_due()
            if due:
                await self._emit_event(
                    "maintenance_due", "Maintenance due", ", ".join(due[:3])
                )

        if result == "completed" and self.config.auto_power_off.enabled:
            self._auto_power_off_armed = True
            self._cooldown_started_at = None
        elif (
            result == "cancelled"
            and self.config.auto_power_off.enabled
            and not self.config.auto_power_off.only_after_successful_print
        ):
            self._auto_power_off_armed = True

        self.current_item_id = None
        self._print_started_at = None

    def _update_totals(self, status: PrinterStatusResponse, used_grams: float, result: str) -> None:
        hours = self.db.get_state(STATE_KEY_TOTAL_HOURS, 0.0) or 0.0
        prints = self.db.get_state(STATE_KEY_TOTAL_PRINTS, 0) or 0
        filament = self.db.get_state(STATE_KEY_TOTAL_FILAMENT, 0.0) or 0.0

        self.db.set_state(STATE_KEY_TOTAL_HOURS, float(hours) + status.print_duration / 3600.0)
        self.db.set_state(STATE_KEY_TOTAL_PRINTS, int(prints) + 1)
        self.db.set_state(STATE_KEY_TOTAL_FILAMENT, float(filament) + used_grams)

    def totals(self) -> Dict[str, float]:
        return {
            "total_print_hours": float(self.db.get_state(STATE_KEY_TOTAL_HOURS, 0.0) or 0.0),
            "total_prints": int(self.db.get_state(STATE_KEY_TOTAL_PRINTS, 0) or 0),
            "total_filament_grams": float(self.db.get_state(STATE_KEY_TOTAL_FILAMENT, 0.0) or 0.0),
        }

    def _maintenance_due(self) -> List[str]:
        totals = self.totals()
        status = self.maintenance.status(
            total_prints=int(totals["total_prints"]),
            total_print_hours=totals["total_print_hours"],
            total_filament_grams=totals["total_filament_grams"],
        )
        return [task.name_ar for task in status.tasks if task.due and task.enabled]

    # ------------------------------------------------------- library linking
    def _resolve_item_id(self, filename: str) -> Optional[str]:
        if not filename:
            return None
        try:
            item = self.library.find_item_for_gcode(filename)
        except Exception:
            return None
        return item.id if item else None

    def _current_item_payload(self) -> Optional[Dict[str, Any]]:
        if not self.current_item_id:
            return None
        item = self.library.get_item(self.current_item_id)
        if item is None:
            return None
        return {
            "id": item.id,
            "name_ar": item.name_ar,
            "name_en": item.name_en,
            "thumbnail": item.thumbnail,
            "hero_image": item.hero_image,
            "category": item.category,
            "recommended_material": item.recommended_material,
        }

    # ---------------------------------------------------------- temperature
    async def _check_targets(
        self, previous: PrinterStatusResponse, status: PrinterStatusResponse
    ) -> None:
        if status.nozzle.target > 0:
            if status.nozzle.actual < status.nozzle.target - TARGET_REACHED_TOLERANCE:
                self._nozzle_target_pending = True
            elif self._nozzle_target_pending:
                self._nozzle_target_pending = False
                await self._emit_event(
                    "target_reached", "Nozzle at target",
                    f"{status.nozzle.actual:.0f}C / {status.nozzle.target:.0f}C",
                )
        else:
            self._nozzle_target_pending = False

        if status.bed.target > 0:
            if status.bed.actual < status.bed.target - TARGET_REACHED_TOLERANCE:
                self._bed_target_pending = True
            elif self._bed_target_pending:
                self._bed_target_pending = False
                await self._emit_event(
                    "target_reached", "Bed at target",
                    f"{status.bed.actual:.0f}C / {status.bed.target:.0f}C",
                )
        else:
            self._bed_target_pending = False

    # -------------------------------------------------------------- history
    def _ensure_history_entry(self, status: PrinterStatusResponse) -> None:
        if self.history is None or not status.filename:
            return
        if self._active_history_id is not None:
            return
        existing = self.history.active_entry()
        if existing is not None and existing.filename == status.filename:
            self._active_history_id = existing.id
            return
        self._active_history_id = self.history.start_print(
            status.filename,
            start_time=time.time() - status.print_duration,
            nozzle_temp=status.nozzle.target or status.nozzle.actual,
            bed_temp=status.bed.target or status.bed.actual,
        )

    def _close_history_entry(
        self,
        result: str,
        status: PrinterStatusResponse,
        snapshot: Optional[Path] = None,
    ) -> Optional[int]:
        if self.history is None:
            return None
        entry_id = self._active_history_id
        if entry_id is None:
            active = self.history.active_entry()
            entry_id = active.id if active else None
        if entry_id is None:
            return None

        self.history.finish_print(
            entry_id,
            result=result,
            filament_used_mm=status.filament_used_mm or None,
            duration=status.print_duration or None,
        )
        if snapshot is not None:
            with contextlib.suppress(Exception):
                self.history.set_thumbnail(entry_id, self.layout.relative(snapshot))
        self.history.prune(self.config.history.max_entries)
        self._active_history_id = None
        return entry_id

    # ---------------------------------------------------------- power loops
    async def _power_loop(self) -> None:
        while not self._stopping.is_set():
            try:
                state = await self.power.status()
                changed = state.state != self.last_power.state
                self.last_power = state
                if changed:
                    await self.hub.broadcast("power", _power_payload(self.power.name, state))
            except PowerError as exc:
                self.last_power = PowerState(
                    state="error", available=False, message=exc.message, device=self.power.name
                )
                await self.hub.broadcast("power", _power_payload(self.power.name, self.last_power))
            except asyncio.CancelledError:
                raise
            except Exception:
                log.exception("Power poll failed")
            with contextlib.suppress(asyncio.TimeoutError):
                await asyncio.wait_for(self._stopping.wait(), timeout=POWER_POLL_SECONDS)

    async def _check_auto_power_off(self, status: PrinterStatusResponse) -> None:
        settings = self.config.auto_power_off
        if not settings.enabled or not self._auto_power_off_armed:
            return
        if status.state in {"printing", "paused"}:
            self._auto_power_off_armed = False
            self._cooldown_started_at = None
            return
        if not status.online:
            return

        cool = (
            status.nozzle.actual < settings.nozzle_below
            and status.bed.actual < settings.bed_below
        )
        if not cool:
            self._cooldown_started_at = None
            return

        now = time.time()
        if self._cooldown_started_at is None:
            self._cooldown_started_at = now
            await self._emit_event(
                "auto_power_off_pending", "Auto power off armed",
                f"Printer cooled down; switching off in {settings.delay_seconds}s",
            )
            return

        if now - self._cooldown_started_at < settings.delay_seconds:
            return

        self._auto_power_off_armed = False
        self._cooldown_started_at = None
        report = evaluate_power_off(status, self.config.power.safety)
        if not report.safe:
            await self._emit_event(
                "auto_power_off_blocked", "Automatic power off cancelled",
                "; ".join(report.blockers),
            )
            return
        try:
            state = await self.power.turn_off()
            self.last_power = state
            await self.hub.broadcast("power", _power_payload(self.power.name, state))
            await self._emit_event("auto_power_off", "Printer powered off automatically")
        except PowerError as exc:
            await self._emit_event("auto_power_off_failed", "Automatic power off failed", exc.message)

    # --------------------------------------------------------- system loop
    async def _system_loop(self) -> None:
        while not self._stopping.is_set():
            try:
                info = system_info.collect()
                self.last_system = info.model_dump()
                await self.hub.broadcast("system", self.last_system)
            except asyncio.CancelledError:
                raise
            except Exception:
                log.exception("System poll failed")
            with contextlib.suppress(asyncio.TimeoutError):
                await asyncio.wait_for(self._stopping.wait(), timeout=20.0)

    # ------------------------------------------------------------- media IO
    async def _broadcast_recording(self, status: Dict[str, Any]) -> None:
        await self.hub.broadcast("recording", status)

    async def _broadcast_timelapse(self, status: Dict[str, Any]) -> None:
        await self.hub.broadcast("timelapse", status)

    # ---------------------------------------------------------------- vision
    def _vision_printer_status(self) -> Dict[str, Any]:
        return {
            "state": self.last_status.state,
            "filename": self.last_status.filename,
            "current_layer": self.last_status.current_layer,
            "progress": self.last_status.progress,
        }

    def _vision_system_load(self) -> Dict[str, Any]:
        return {
            "cpu_percent": self.last_system.get("cpu_percent", 0.0),
            "cpu_temp_c": self.last_system.get("cpu_temp_c") or 0.0,
        }

    async def _on_vision_event(self, event: VisionEvent) -> None:
        await self.hub.broadcast("vision", event.as_dict())
        await self._emit_event(
            "ai_anomaly",
            "Possible print problem",
            f"{event.kind} ({event.confidence:.0%})",
            event.gcode_name,
        )

    async def _vision_pause_print(self) -> None:
        """Only ever pauses. Mains power is never touched by the detector."""
        try:
            await self.moonraker.pause_print()
            await self._emit_event(
                "ai_paused", "Print paused by the failure monitor",
                "A confirmed anomaly paused the print. Check the camera.",
            )
        except MoonrakerError as exc:
            log.error("Vision pause failed: %s", exc.message)
            await self._emit_event("ai_pause_failed", "Could not pause the print", exc.message)

    # ------------------------------------------------------------ utilities
    async def safety_report(self):
        return evaluate_power_off(self.last_status, self.config.power.safety)

    async def capture_snapshot(self, *, prefix: str = "snapshot") -> Optional[Path]:
        return await self.camera.save_snapshot(prefix=prefix)

    async def start_recording_manual(self) -> Any:
        return await self.recording.start(
            gcode_name=self.last_status.filename, item_id=self.current_item_id, mode="manual"
        )

    # --------------------------------------------------------------- safety
    async def _run_safe_gcode(self, command: str) -> Any:
        """The only path from this project to a printer movement command.

        Called by the safety engine after it has approved and possibly adjusted
        the command. Nothing else should call ``moonraker.run_gcode`` for motion.
        """
        log.info("safe gcode: %s", command)
        result = await self.moonraker.run_gcode(command)
        self._track_calibration_session(command)
        return result

    def _track_calibration_session(self, command: str) -> None:
        """Follow PROBE_CALIBRATE / TESTZ / ACCEPT so the engine's session rules
        reflect what actually ran."""
        word = command.strip().split()[0].upper() if command.strip() else ""
        if word in {"PROBE_CALIBRATE", "Z_ENDSTOP_CALIBRATE"}:
            self.calibration_session = word.lower()
            self.testz_total_down = 0.0
        elif word in {"ACCEPT", "ABORT"}:
            self.calibration_session = None
            self.testz_total_down = 0.0
        elif word == "TESTZ":
            from .safety.engine import parse_named_params

            step = parse_named_params(command).get("Z")
            if step is not None and step < 0:
                self.testz_total_down += abs(step)

    async def _backup_before_save_config(self, _command: str) -> None:
        """SAVE_CONFIG rewrites printer.cfg, so snapshot it first."""
        try:
            text = await self.moonraker.read_config_file("printer.cfg")
        except Exception as error:                        # noqa: BLE001
            log.warning("Could not back up printer.cfg before SAVE_CONFIG: %s", error)
            return
        self.config_store.snapshot(text, reason="pre_save_config")

    async def ensure_status_fresh(self, *, max_age: float = 5.0) -> PrinterStatusResponse:
        """Make sure ``last_status`` is recent enough to make a safety decision on.

        The poll loop normally keeps it current, but a request that arrives
        immediately after startup would otherwise see ``klippy_state: unknown``
        and be refused for the wrong reason. Refusing because we genuinely do
        not know is correct; refusing because nobody has looked yet is not.
        """
        # A cached *good* reading can be reused. A cached offline/unknown one
        # cannot: it may simply predate the connection coming up, and refusing
        # a command on stale bad news is the wrong kind of caution.
        cached_is_usable = self.last_status.online and self.last_status.klippy_state == "ready"
        if cached_is_usable and time.time() - self._last_status_at <= max_age:
            return self.last_status
        try:
            status = await fetch_status(self.moonraker)
        except Exception as error:                        # noqa: BLE001
            log.debug("Status refresh failed: %s", error)
            return self.last_status
        self.last_status = status
        self._last_status_at = time.time()
        return status

    def safety_context(self) -> SafetyContext:
        """Assemble the engine's view of the printer from live state."""
        status = self.last_status
        return SafetyContext(
            klippy_ready=status.klippy_state == "ready",
            klippy_state=status.klippy_state,
            klippy_message=status.klippy_message,
            printing=status.state == "printing",
            paused=status.state == "paused",
            homed_axes=status.homed_axes,
            position=tuple(status.position or (0.0, 0.0, 0.0)),
            nozzle_temp=status.nozzle.actual,
            nozzle_target=status.nozzle.target,
            bed_temp=status.bed.actual,
            bed_target=status.bed.target,
            probe_triggered=self.probe_triggered,
            endstops=dict(self.endstop_states),
            config=self.live_config,
            calibration_session=self.calibration_session,
            testz_total_down=self.testz_total_down,
        )

    # ---------------------------------------------------------- live config
    async def refresh_live_config(self, *, force: bool = False) -> Optional[ParsedConfig]:
        """Read printer.cfg from Moonraker and parse it.

        Cached for 30 s: the safety engine consults it on every command, and
        re-reading the file each time would hammer Moonraker for no benefit.
        """
        fresh_enough = time.time() - self.live_config_fetched_at < 30.0
        if not force and self.live_config is not None and fresh_enough:
            return self.live_config

        try:
            text = await self.moonraker.read_config_file("printer.cfg")
        except Exception as error:                        # noqa: BLE001
            self.live_config_error = str(error)
            log.warning("Could not read printer.cfg: %s", error)
            return self.live_config

        self.live_config_text = text
        self.live_config = parse_config(text)
        self.live_config_error = ""
        self.live_config_fetched_at = time.time()

        # First sight of a config with no history: record it so there is
        # something to roll back to.
        if self.config_store.latest() is None:
            self.config_store.snapshot(text, reason="imported", label="First seen")
        return self.live_config

    @property
    def live_config_sha(self) -> str:
        import hashlib

        if not self.live_config_text:
            return ""
        return hashlib.sha256(self.live_config_text.encode("utf-8")).hexdigest()

    # ------------------------------------------------------------ readings
    async def query_probe(self) -> Optional[bool]:
        """Read the probe. Sets ``probe_triggered`` only from a real answer -
        a failed query leaves it None, which the engine treats as unknown."""
        try:
            output = await self.moonraker.run_gcode_and_collect("QUERY_PROBE")
        except Exception as error:                        # noqa: BLE001
            log.warning("QUERY_PROBE failed: %s", error)
            self.probe_triggered = None
            return None
        lowered = output.lower()
        if "probe: triggered" in lowered:
            self.probe_triggered = True
        elif "probe: open" in lowered:
            self.probe_triggered = False
        else:
            self.probe_triggered = None
        return self.probe_triggered

    async def query_endstops(self) -> Dict[str, str]:
        try:
            output = await self.moonraker.run_gcode_and_collect("QUERY_ENDSTOPS")
        except Exception as error:                        # noqa: BLE001
            log.warning("QUERY_ENDSTOPS failed: %s", error)
            return {}
        states: Dict[str, str] = {}
        for part in output.replace("\n", " ").split():
            if ":" in part:
                name, _, value = part.partition(":")
                if name.strip().lower() in {"x", "y", "z"} and value.strip():
                    states[name.strip().lower()] = value.strip().lower()
        if states:
            self.endstop_states = states
        return states

    # ---------------------------------------------------------- diagnosis
    async def diagnose(self, *, deep: bool = False) -> Dict[str, Any]:
        """Run the full "Fix My Printer" inspection.

        ``deep`` additionally queries the probe and endstops, which sends
        read-only G-code. It still never moves the printer.
        """
        await self.ensure_status_fresh()
        await self.refresh_live_config()

        if deep:
            await self.query_probe()
            await self.query_endstops()

        klipper_log: List[str] = []
        try:
            klipper_log = await self.moonraker.klipper_log_tail(200)
        except Exception:                                 # noqa: BLE001
            pass

        status = self.last_status
        raw = status.raw or {}
        mcu = raw.get("mcu", {}) if isinstance(raw, dict) else {}
        heaters: Dict[str, Dict[str, float]] = {}
        for key in ("extruder", "heater_bed"):
            block = raw.get(key) if isinstance(raw, dict) else None
            if isinstance(block, dict):
                heaters[key] = {
                    "temperature": block.get("temperature", 0.0),
                    "target": block.get("target", 0.0),
                    "power": block.get("power", 0.0),
                }

        fans: Dict[str, float] = {}
        if isinstance(raw, dict):
            for key, block in raw.items():
                if key.startswith("fan") and isinstance(block, dict):
                    fans[key] = block.get("speed", 0.0)

        sensor = None
        sensor_enabled = None
        if isinstance(raw, dict):
            for key, block in raw.items():
                if key.startswith(("filament_switch_sensor", "filament_motion_sensor")):
                    if isinstance(block, dict):
                        sensor = block.get("filament_detected")
                        sensor_enabled = block.get("enabled")
                    break

        system = self.last_system or {}
        known_good = self.config_store.last_known_good()

        data = DiagnosticInput(
            moonraker_reachable=status.online,
            klippy_state=status.klippy_state,
            klippy_message=status.klippy_message,
            printing=status.state == "printing",
            paused=status.state == "paused",
            config=self.live_config,
            config_error=self.live_config_error,
            homed_axes=status.homed_axes,
            endstops=dict(self.endstop_states),
            probe_triggered=self.probe_triggered,
            heaters=heaters,
            fans=fans,
            filament_detected=sensor,
            filament_sensor_enabled=sensor_enabled,
            mcu_awake=bool(mcu) if mcu else (True if status.online and status.klippy_state == "ready" else None),
            mcu_version=str(mcu.get("mcu_version", "")) if isinstance(mcu, dict) else "",
            mcu_load=(mcu.get("last_stats", {}) or {}).get("mcu_task_avg") if isinstance(mcu, dict) else None,
            host_cpu_percent=system.get("cpu_percent"),
            host_temp_c=system.get("cpu_temp_c"),
            disk_free_gb=(
                (system.get("disk_total_gb", 0.0) - system.get("disk_used_gb", 0.0))
                if system.get("disk_total_gb") is not None
                else None
            ),
            camera_available=self.camera.status(probe_devices=False).available,
            accelerometer_present=None,
            klipper_log_tail=klipper_log,
            config_sha=self.live_config_sha,
            known_good_sha=known_good.sha256 if known_good else "",
            known_good_label=known_good.label if known_good else "",
        )
        return self.diagnostics.run(data).as_dict()

    # ----------------------------------------------------------- preflight
    async def analyse_gcode_path(self, filename: str) -> GCodeReport:
        """Statically analyse a G-code file. Reads only - never rewrites."""
        await self.refresh_live_config()
        text = ""
        local = self.gcodes.path_for(filename)
        if local.is_file():
            text = local.read_text(encoding="utf-8", errors="replace")
        else:
            data = await self.moonraker.download_gcode(filename)
            text = data.decode("utf-8", errors="replace")
        return analyse_gcode(
            text,
            config=self.live_config,
            golden_profiles=self.slicer_profiles.golden_names(),
        )

    async def preflight(self, filename: str, *, strict: bool = False) -> Dict[str, Any]:
        await self.ensure_status_fresh()
        await self.refresh_live_config()
        health = self.diagnostics.run(
            DiagnosticInput(
                moonraker_reachable=self.last_status.online,
                klippy_state=self.last_status.klippy_state,
                klippy_message=self.last_status.klippy_message,
                config=self.live_config,
                homed_axes=self.last_status.homed_axes,
                probe_triggered=self.probe_triggered,
                mcu_awake=True if self.last_status.klippy_state == "ready" else None,
            )
        )
        try:
            gcode = await self.analyse_gcode_path(filename)
        except Exception as error:                        # noqa: BLE001
            log.warning("Could not analyse %s: %s", filename, error)
            gcode = None

        filament_ok = None
        filament_message = ""
        if gcode is not None and gcode.filament_mm:
            check = self.filament.check_enough(grams_from_mm(gcode.filament_mm))
            filament_ok = check.get("ok")
            filament_message = check.get("message_key", "")

        report = run_preflight(
            health=health,
            gcode=gcode,
            strict=strict,
            filament_ok=filament_ok,
            filament_message=filament_message,
        )
        return report.as_dict()

    def status_summary(self) -> Dict[str, Any]:
        """Everything the Home screen needs in one payload."""
        totals = self.totals()
        return {
            "printer": self.last_status.model_dump(),
            "item": self._current_item_payload(),
            "power": _power_payload(self.power.name, self.last_power),
            "camera": self.camera.status(probe_devices=False).as_dict(),
            "recording": self.recording.status(),
            "timelapse": self.timelapse.status(),
            "vision": self.vision.status(),
            "queue": self.queue.summary(),
            "filament": self.filament.summary(),
            "library": self.library.stats(),
            "totals": totals,
            "maintenance_due": len(self._maintenance_due()),
        }


def _power_payload(provider: str, state: PowerState) -> Dict[str, Any]:
    return {
        "provider": provider,
        "state": state.state,
        "available": state.available,
        "device": state.device,
        "message": state.message,
    }


# Localisation keys for the Arabic slicing stages the app displays.
SLICE_STAGE_KEYS = {
    "queued": "slicer.stage.queued",
    "preparing": "slicer.stage.uploading",
    "processing mesh": "slicer.stage.analysing",
    "orienting": "slicer.stage.analysing",
    "generating perimeters": "slicer.stage.layers",
    "preparing infill": "slicer.stage.layers",
    "infilling layers": "slicer.stage.layers",
    "skirt / brim": "slicer.stage.layers",
    "support material": "slicer.stage.layers",
    "estimating time": "slicer.stage.gcode",
    "exporting g-code": "slicer.stage.gcode",
    "finishing": "slicer.stage.saving",
    "completed": "slicer.stage.ready",
    "failed": "slicer.stage.failed",
    "cancelled": "slicer.stage.cancelled",
}


def _slice_stage_key(stage: str, status: str) -> str:
    if status == "failed":
        return "slicer.stage.failed"
    if status == "cancelled":
        return "slicer.stage.cancelled"
    if status == "done":
        return "slicer.stage.ready"
    return SLICE_STAGE_KEYS.get((stage or "").strip().lower(), "slicer.stage.working")
