"""Telling a power cut apart from a Klipper crash, and surviving both.

Klipper reports "shutdown" for a lot of unrelated reasons, and treating them
all as a power failure would cry wolf. There is a signal that separates them
cleanly on a USB-connected printer: **the serial device**.

    [mcu]
    serial: /dev/serial/by-id/usb-1a86_USB_Serial-if00-port0

That path is a symlink created by udev when the printer's USB interface
enumerates. Kill mains to the printer and the interface disappears, so the
symlink vanishes within a second or two. A Klipper firmware error, a failed
homing move, a thermal runaway shutdown - none of those unplug anything, so the
device is still there. One filesystem check, and a shutdown becomes either
"your printer has no power" or "Klipper stopped for its own reasons".

The second half of the problem is worse: if the same outage takes the Pi with
it, nothing on the Pi is running to notice anything. So the in-flight print is
mirrored to a small fsync'd file while it runs. When the Pi comes back it reads
that file, sees that the process never got to delete it, and can say exactly
what was lost and at which layer - which is the difference between "something
happened while you were out" and "the 7-hour print died at layer 412 of 900,
the part is still stuck to the bed".
"""

from __future__ import annotations

import contextlib
import json
import logging
import os
import time
import uuid
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional

log = logging.getLogger("neptune.outage")

SNAPSHOT_FILENAME = "inflight-print.json"
OUTAGE_LOG_FILENAME = "outages.json"
MAX_OUTAGE_RECORDS = 50

# Klipper's own wording when the MCU stops answering. Used only as a fallback:
# the serial-device check above is the reliable signal, and message matching is
# what this project has repeatedly had to stop relying on.
MCU_LOST_MARKERS = (
    "lost communication with mcu",
    "mcu 'mcu' shutdown",
    "unable to connect",
    "rescheduled timer in the past",
    "timer too close",
)


# --------------------------------------------------------------------------- #
# What was in flight
# --------------------------------------------------------------------------- #


@dataclass
class PrintSnapshot:
    """Enough to describe a print that died, written while it was alive."""

    filename: str = ""
    started_at: float = 0.0
    updated_at: float = 0.0
    progress: float = 0.0
    current_layer: Optional[int] = None
    total_layer: Optional[int] = None
    z_height: float = 0.0
    filament_used_mm: float = 0.0
    nozzle_target: float = 0.0
    bed_target: float = 0.0
    item_id: Optional[str] = None

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "PrintSnapshot":
        allowed = set(cls.__dataclass_fields__)
        return cls(**{key: value for key, value in data.items() if key in allowed})

    @property
    def layer_text(self) -> str:
        if self.current_layer is None:
            return ""
        if self.total_layer:
            return f"{self.current_layer}/{self.total_layer}"
        return str(self.current_layer)


@dataclass
class OutageRecord:
    """One detected interruption, and what it means for the part on the bed."""

    id: str
    # printer_power | mcu_lost | klipper_shutdown | pi_power | service_restart
    cause: str
    detected_at: float
    was_printing: bool
    snapshot: Optional[PrintSnapshot] = None
    detail: str = ""
    restored_at: Optional[float] = None
    acknowledged: bool = False

    def to_dict(self) -> Dict[str, Any]:
        data = asdict(self)
        data["snapshot"] = self.snapshot.to_dict() if self.snapshot else None
        data["cause_ar"] = CAUSE_AR.get(self.cause, self.cause)
        data["advice_ar"] = self.advice_ar()
        return data

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "OutageRecord":
        snapshot = data.get("snapshot")
        return cls(
            id=str(data.get("id") or uuid.uuid4().hex[:12]),
            cause=str(data.get("cause") or "klipper_shutdown"),
            detected_at=float(data.get("detected_at") or 0.0),
            was_printing=bool(data.get("was_printing", False)),
            snapshot=PrintSnapshot.from_dict(snapshot) if isinstance(snapshot, dict) else None,
            detail=str(data.get("detail") or ""),
            restored_at=data.get("restored_at"),
            acknowledged=bool(data.get("acknowledged", False)),
        )

    def advice_ar(self) -> str:
        """What to actually do - written for someone reading it on a phone.

        Klipper has no print-resume-after-power-loss, and on a printer whose Z
        is homed by a probe under [safe_z_home], the first G28 after a cut
        drives the nozzle down in the middle of the bed - into whatever is
        still printed there. So the advice is never "resume".
        """
        if not self.was_printing:
            return "مفيش طباعة كانت شغالة، فمفيش حاجة ضاعت."

        where = ""
        if self.snapshot and self.snapshot.layer_text:
            where = f" عند الطبقة {self.snapshot.layer_text}"

        return (
            f"الطباعة وقفت{where} ومش هتكمّل - Klipper مفيهوش استئناف بعد "
            "انقطاع الكهرباء. القطعة لسه على السرير: شيلها الأول قبل أي أمر "
            "تحريك، لأن أول G28 هينزل النوزل في نص السرير وهيخبط فيها."
        )


CAUSE_AR: Dict[str, str] = {
    "printer_power": "الكهرباء اتقطعت عن الطابعة",
    "mcu_lost": "الاتصال بلوحة التحكم اتقطع",
    "klipper_shutdown": "Klipper وقف",
    "pi_power": "الراسبيري باي نفسه فصل",
    "service_restart": "الخدمة اتعملها restart",
}


# --------------------------------------------------------------------------- #
# Durable little files
# --------------------------------------------------------------------------- #


def atomic_write_json(path: Path, payload: Any) -> None:
    """Write so that a power cut leaves either the old file or the new one.

    A plain ``write_text`` can leave a truncated file: the metadata update and
    the data blocks reach the card at different times, and the whole reason
    this file exists is to be read after exactly that kind of interruption.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")

    try:
        with open(temporary, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, indent=2)
            handle.flush()
            os.fsync(handle.fileno())
    except Exception:
        # Half a file is worse than none: leaving it would be picked up as a
        # stale temporary on a later run.
        with contextlib.suppress(OSError):
            temporary.unlink()
        raise

    os.replace(temporary, path)

    # Renames need their own flush, otherwise the directory entry can still be
    # the old one after a cut.
    try:
        directory = os.open(str(path.parent), os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    except OSError:  # pragma: no cover - not every filesystem allows this
        pass


def read_json(path: Path, default: Any = None) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default


def boot_time(now: Optional[float] = None) -> Optional[float]:
    """When this machine last booted, from /proc/uptime.

    Used to answer one question: did the whole machine go down, or did just
    this process restart? A snapshot written before the last boot means the Pi
    itself went away - which on a printer setup nearly always means the mains
    went with it.
    """
    try:
        with open("/proc/uptime", "r", encoding="utf-8") as handle:
            uptime = float(handle.read().split()[0])
    except (OSError, ValueError, IndexError):
        return None
    return (now if now is not None else time.time()) - uptime


# --------------------------------------------------------------------------- #
# The watcher
# --------------------------------------------------------------------------- #


@dataclass
class Detection:
    cause: str
    detail: str = ""
    # False for causes that are informational rather than an interruption.
    is_outage: bool = True


class OutageWatcher:
    """Classifies interruptions and remembers what was lost."""

    def __init__(
        self,
        state_dir: Path,
        *,
        serial_path: str = "",
        snapshot_interval: float = 20.0,
        clock=time.time,
    ) -> None:
        self.state_dir = Path(state_dir)
        self.state_dir.mkdir(parents=True, exist_ok=True)
        self.serial_path = serial_path or ""
        self.snapshot_interval = max(5.0, float(snapshot_interval))
        self._clock = clock

        self.snapshot_file = self.state_dir / SNAPSHOT_FILENAME
        self.log_file = self.state_dir / OUTAGE_LOG_FILENAME

        self._last_snapshot_write: float = 0.0
        self._live: Optional[PrintSnapshot] = None
        self._in_outage: bool = False
        self.records: List[OutageRecord] = self._load_records()

    # ------------------------------------------------------------ persistence
    def _load_records(self) -> List[OutageRecord]:
        raw = read_json(self.log_file, [])
        if not isinstance(raw, list):
            return []
        records = []
        for item in raw:
            if isinstance(item, dict):
                try:
                    records.append(OutageRecord.from_dict(item))
                except (TypeError, ValueError):
                    continue
        return records

    def _save_records(self) -> None:
        trimmed = self.records[-MAX_OUTAGE_RECORDS:]
        self.records = trimmed
        atomic_write_json(self.log_file, [record.to_dict() for record in trimmed])

    # -------------------------------------------------------- serial presence
    def serial_present(self) -> Optional[bool]:
        """Whether the MCU's USB device is currently attached.

        ``None`` means we were not told which device to look at, and an
        unanswerable question must not be answered with a guess - without this
        path every Klipper shutdown would be reported as a power cut.
        """
        if not self.serial_path:
            return None
        try:
            return Path(self.serial_path).exists()
        except OSError:
            return None

    # -------------------------------------------------------------- classify
    def classify(
        self,
        *,
        klippy_state: str,
        klippy_message: str,
        online: bool,
        serial_present: Optional[bool] = None,
    ) -> Optional[Detection]:
        """What kind of interruption this is, or None if nothing is wrong."""
        healthy = online and klippy_state in {"ready", "startup"}
        if healthy:
            return None

        if not online:
            # Moonraker itself is unreachable. That is a backend/network
            # problem, not evidence about the printer's mains - saying "power
            # cut" here would be inventing a diagnosis.
            return Detection(
                cause="klipper_shutdown",
                detail="Moonraker is unreachable, so the printer's state is unknown.",
                is_outage=False,
            )

        present = serial_present if serial_present is not None else self.serial_present()
        message = (klippy_message or "").lower()

        if present is False:
            return Detection(
                cause="printer_power",
                detail=(
                    f"The MCU device {self.serial_path} is no longer attached. "
                    "The printer is not powered, or its USB cable came out."
                ),
            )

        if any(marker in message for marker in MCU_LOST_MARKERS):
            return Detection(
                cause="mcu_lost",
                detail=klippy_message or "Klipper lost contact with the MCU.",
            )

        if klippy_state in {"shutdown", "error", "disconnected"}:
            return Detection(
                cause="klipper_shutdown",
                detail=klippy_message or f"Klipper reported state '{klippy_state}'.",
            )

        return None

    # --------------------------------------------------------------- tracking
    def track(self, snapshot: PrintSnapshot, *, force: bool = False) -> bool:
        """Mirror the running print to disk. Returns whether it wrote."""
        now = self._clock()
        snapshot.updated_at = now
        self._live = snapshot

        if not force and now - self._last_snapshot_write < self.snapshot_interval:
            return False

        atomic_write_json(self.snapshot_file, snapshot.to_dict())
        self._last_snapshot_write = now
        return True

    def clear(self) -> None:
        """The print ended in a way we saw. Nothing was lost, so forget it."""
        self._live = None
        self._last_snapshot_write = 0.0
        try:
            self.snapshot_file.unlink()
        except FileNotFoundError:
            pass
        except OSError as exc:  # pragma: no cover - permissions only
            log.warning("could not clear the in-flight snapshot: %s", exc)

    @property
    def live_snapshot(self) -> Optional[PrintSnapshot]:
        return self._live

    # --------------------------------------------------------------- outages
    def open_outage(self, detection: Detection, snapshot: Optional[PrintSnapshot]) -> OutageRecord:
        record = OutageRecord(
            id=uuid.uuid4().hex[:12],
            cause=detection.cause,
            detected_at=self._clock(),
            was_printing=snapshot is not None,
            snapshot=snapshot,
            detail=detection.detail,
        )
        self.records.append(record)
        self._save_records()
        self._in_outage = True
        return record

    def close_outage(self) -> Optional[OutageRecord]:
        """Printer is answering again."""
        if not self._in_outage:
            return None
        self._in_outage = False
        if not self.records:
            return None
        record = self.records[-1]
        if record.restored_at is None:
            record.restored_at = self._clock()
            self._save_records()
        return record

    @property
    def in_outage(self) -> bool:
        return self._in_outage

    @property
    def last_record(self) -> Optional[OutageRecord]:
        return self.records[-1] if self.records else None

    def acknowledge(self, record_id: str) -> bool:
        for record in self.records:
            if record.id == record_id:
                record.acknowledged = True
                self._save_records()
                return True
        return False

    # ------------------------------------------------------------ reconciling
    def reconcile_on_start(self, now: Optional[float] = None) -> Optional[OutageRecord]:
        """Read the snapshot left behind by a process that never got to exit.

        Its mere existence is the finding: a clean shutdown deletes it, and a
        finished print deletes it. So if it is here on startup, something
        interrupted a running print without warning.
        """
        moment = now if now is not None else self._clock()
        data = read_json(self.snapshot_file, None)
        if not isinstance(data, dict):
            return None

        try:
            snapshot = PrintSnapshot.from_dict(data)
        except (TypeError, ValueError):
            self.clear()
            return None

        booted = boot_time(moment)
        if booted is not None and snapshot.updated_at and booted > snapshot.updated_at:
            # The machine came up *after* the last thing we wrote, so the whole
            # Pi went down - not just this service.
            cause = "pi_power"
            detail = (
                "The Raspberry Pi rebooted while a print was running, and the "
                "backend never got a chance to shut down cleanly. That is what "
                "a power cut looks like from in here."
            )
        else:
            cause = "service_restart"
            detail = (
                "The backend restarted while a print was tracked. The Pi itself "
                "did not reboot, so this was most likely a service restart or a "
                "crash rather than a power cut."
            )

        record = OutageRecord(
            id=uuid.uuid4().hex[:12],
            cause=cause,
            detected_at=snapshot.updated_at or moment,
            was_printing=True,
            snapshot=snapshot,
            detail=detail,
        )
        self.records.append(record)
        self._save_records()
        self.clear()
        return record

    # ----------------------------------------------------------------- status
    def status(self) -> Dict[str, Any]:
        return {
            "enabled": True,
            "serial_path": self.serial_path,
            "serial_present": self.serial_present(),
            "in_outage": self._in_outage,
            "tracking": self._live.to_dict() if self._live else None,
            "last": self.last_record.to_dict() if self.last_record else None,
            "records": [record.to_dict() for record in reversed(self.records[-20:])],
        }


def snapshot_from_status(status: Any, *, started_at: float = 0.0, item_id: Optional[str] = None) -> PrintSnapshot:
    """Build a snapshot from a PrinterStatusResponse without importing it."""
    position = list(getattr(status, "position", []) or [])
    z_height = float(position[2]) if len(position) >= 3 else 0.0
    return PrintSnapshot(
        filename=getattr(status, "filename", "") or "",
        started_at=started_at,
        progress=float(getattr(status, "progress", 0.0) or 0.0),
        current_layer=getattr(status, "current_layer", None),
        total_layer=getattr(status, "total_layer", None),
        z_height=z_height,
        filament_used_mm=float(getattr(status, "filament_used_mm", 0.0) or 0.0),
        nozzle_target=float(getattr(getattr(status, "nozzle", None), "target", 0.0) or 0.0),
        bed_target=float(getattr(getattr(status, "bed", None), "target", 0.0) or 0.0),
        item_id=item_id,
    )
