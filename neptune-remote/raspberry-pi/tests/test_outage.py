"""Power loss detection.

Two things are being tested, and the second is the one that is easy to get
wrong: that a Klipper crash is *not* reported as a power cut, and that a print
which died together with the Raspberry Pi can still be described afterwards.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from app.power.outage import (
    OutageWatcher,
    PrintSnapshot,
    atomic_write_json,
    read_json,
)


class FakeClock:
    def __init__(self, now: float = 1_000_000.0) -> None:
        self.now = now

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds


@pytest.fixture()
def watcher(tmp_path: Path) -> OutageWatcher:
    return OutageWatcher(
        tmp_path / "state",
        serial_path=str(tmp_path / "serial-device"),
        snapshot_interval=10.0,
        clock=FakeClock(),
    )


def touch_serial(watcher: OutageWatcher) -> None:
    Path(watcher.serial_path).write_text("present", encoding="utf-8")


def sample_snapshot(**overrides) -> PrintSnapshot:
    data = {
        "filename": "benchy.gcode",
        "started_at": 900_000.0,
        "progress": 0.45,
        "current_layer": 412,
        "total_layer": 900,
        "z_height": 82.4,
    }
    data.update(overrides)
    return PrintSnapshot(**data)


# --------------------------------------------------------------------------- #
# Classification
# --------------------------------------------------------------------------- #


class TestClassification:
    def test_a_healthy_printer_reports_nothing(self, watcher: OutageWatcher):
        touch_serial(watcher)
        assert (
            watcher.classify(klippy_state="ready", klippy_message="", online=True) is None
        )

    def test_a_vanished_serial_device_is_a_power_cut(self, watcher: OutageWatcher):
        """Mains dies -> the USB interface deenumerates -> the symlink goes."""
        detection = watcher.classify(
            klippy_state="shutdown",
            klippy_message="Lost communication with MCU 'mcu'",
            online=True,
        )
        assert detection is not None
        assert detection.cause == "printer_power"

    def test_a_klipper_crash_with_the_device_still_there_is_not_a_power_cut(
        self, watcher: OutageWatcher
    ):
        """The distinction the whole module exists for."""
        touch_serial(watcher)
        detection = watcher.classify(
            klippy_state="shutdown",
            klippy_message="Heater extruder not heating at expected rate",
            online=True,
        )
        assert detection is not None
        assert detection.cause == "klipper_shutdown"

    def test_lost_mcu_with_the_device_present_is_a_cable_not_the_mains(
        self, watcher: OutageWatcher
    ):
        touch_serial(watcher)
        detection = watcher.classify(
            klippy_state="shutdown",
            klippy_message="Lost communication with MCU 'mcu'",
            online=True,
        )
        assert detection.cause == "mcu_lost"

    def test_an_unconfigured_serial_path_refuses_to_guess(self, tmp_path: Path):
        """No device to watch means no evidence - and no invented diagnosis."""
        blind = OutageWatcher(tmp_path / "state", serial_path="", clock=FakeClock())
        detection = blind.classify(
            klippy_state="shutdown", klippy_message="MCU 'mcu' shutdown", online=True
        )
        assert detection.cause == "mcu_lost"

        detection = blind.classify(
            klippy_state="shutdown", klippy_message="Thermal runaway", online=True
        )
        assert detection.cause == "klipper_shutdown"

    def test_moonraker_being_unreachable_is_not_attributed_to_the_printer(
        self, watcher: OutageWatcher
    ):
        """We cannot see the printer at all, so we must not claim to know why."""
        detection = watcher.classify(klippy_state="unknown", klippy_message="", online=False)
        assert detection is not None
        assert detection.is_outage is False

    def test_serial_present_is_none_when_no_path_is_known(self, tmp_path: Path):
        blind = OutageWatcher(tmp_path / "state", serial_path="", clock=FakeClock())
        assert blind.serial_present() is None


# --------------------------------------------------------------------------- #
# Tracking
# --------------------------------------------------------------------------- #


class TestTracking:
    def test_the_snapshot_is_throttled(self, watcher: OutageWatcher):
        clock: FakeClock = watcher._clock  # type: ignore[assignment]
        assert watcher.track(sample_snapshot()) is True
        assert watcher.track(sample_snapshot()) is False

        clock.advance(11)
        assert watcher.track(sample_snapshot()) is True

    def test_a_layer_change_can_force_a_write(self, watcher: OutageWatcher):
        watcher.track(sample_snapshot())
        assert watcher.track(sample_snapshot(current_layer=413), force=True) is True

    def test_the_snapshot_records_where_the_print_had_reached(self, watcher: OutageWatcher):
        watcher.track(sample_snapshot())
        stored = read_json(watcher.snapshot_file)
        assert stored["current_layer"] == 412
        assert stored["filename"] == "benchy.gcode"

    def test_clearing_removes_the_file(self, watcher: OutageWatcher):
        watcher.track(sample_snapshot())
        assert watcher.snapshot_file.exists()
        watcher.clear()
        assert not watcher.snapshot_file.exists()

    def test_clearing_twice_is_harmless(self, watcher: OutageWatcher):
        watcher.clear()
        watcher.clear()


# --------------------------------------------------------------------------- #
# Recovering after the Pi itself went down
# --------------------------------------------------------------------------- #


class TestReconciliation:
    def test_nothing_to_report_on_a_clean_start(self, watcher: OutageWatcher):
        assert watcher.reconcile_on_start() is None

    def test_a_leftover_snapshot_means_something_died_mid_print(
        self, watcher: OutageWatcher, monkeypatch
    ):
        watcher.track(sample_snapshot())
        # The machine booted after the snapshot was written: the Pi went down.
        monkeypatch.setattr("app.power.outage.boot_time", lambda now=None: 1_000_500.0)

        clock: FakeClock = watcher._clock  # type: ignore[assignment]
        clock.advance(600)
        record = watcher.reconcile_on_start()

        assert record is not None
        assert record.cause == "pi_power"
        assert record.was_printing is True
        assert record.snapshot.current_layer == 412

    def test_a_service_restart_is_not_called_a_power_cut(
        self, watcher: OutageWatcher, monkeypatch
    ):
        """systemctl restart must not send someone home from work."""
        watcher.track(sample_snapshot())
        # Booted long before the snapshot: only the process restarted.
        monkeypatch.setattr("app.power.outage.boot_time", lambda now=None: 500_000.0)

        record = watcher.reconcile_on_start()
        assert record is not None
        assert record.cause == "service_restart"

    def test_the_snapshot_is_consumed_so_it_reports_once(
        self, watcher: OutageWatcher, monkeypatch
    ):
        watcher.track(sample_snapshot())
        monkeypatch.setattr("app.power.outage.boot_time", lambda now=None: 1_000_500.0)
        assert watcher.reconcile_on_start() is not None
        assert watcher.reconcile_on_start() is None

    def test_a_corrupt_snapshot_is_discarded_not_fatal(self, watcher: OutageWatcher):
        watcher.snapshot_file.parent.mkdir(parents=True, exist_ok=True)
        watcher.snapshot_file.write_text("{ this is not json", encoding="utf-8")
        assert watcher.reconcile_on_start() is None


# --------------------------------------------------------------------------- #
# Records and advice
# --------------------------------------------------------------------------- #


class TestRecords:
    def test_an_outage_opens_and_closes(self, watcher: OutageWatcher):
        detection = watcher.classify(
            klippy_state="shutdown", klippy_message="Lost communication", online=True
        )
        record = watcher.open_outage(detection, sample_snapshot())
        assert watcher.in_outage is True

        closed = watcher.close_outage()
        assert closed is record
        assert record.restored_at is not None
        assert watcher.in_outage is False

    def test_closing_without_an_outage_is_a_no_op(self, watcher: OutageWatcher):
        assert watcher.close_outage() is None

    def test_records_survive_a_restart(self, watcher: OutageWatcher, tmp_path: Path):
        detection = watcher.classify(
            klippy_state="shutdown", klippy_message="Lost communication", online=True
        )
        watcher.open_outage(detection, sample_snapshot())

        reopened = OutageWatcher(tmp_path / "state", clock=FakeClock())
        assert len(reopened.records) == 1
        assert reopened.records[0].cause == "printer_power"

    def test_the_advice_never_says_resume(self, watcher: OutageWatcher):
        """Klipper has no power-loss recovery, and on a probed Z the first G28
        after a cut drives the nozzle into the part that is still on the bed."""
        detection = watcher.classify(
            klippy_state="shutdown", klippy_message="Lost communication", online=True
        )
        record = watcher.open_outage(detection, sample_snapshot())
        advice = record.advice_ar()
        assert "412/900" in advice
        assert "استئناف" in advice  # says there is none, not that you should

    def test_advice_when_nothing_was_printing(self, watcher: OutageWatcher):
        detection = watcher.classify(
            klippy_state="shutdown", klippy_message="Lost communication", online=True
        )
        record = watcher.open_outage(detection, None)
        assert record.was_printing is False
        assert "مفيش حاجة ضاعت" in record.advice_ar()

    def test_acknowledging(self, watcher: OutageWatcher):
        detection = watcher.classify(
            klippy_state="shutdown", klippy_message="Lost communication", online=True
        )
        record = watcher.open_outage(detection, None)
        assert watcher.acknowledge(record.id) is True
        assert watcher.acknowledge("nope") is False
        assert watcher.records[0].acknowledged is True

    def test_the_record_log_is_bounded(self, watcher: OutageWatcher):
        from app.power.outage import MAX_OUTAGE_RECORDS

        detection = watcher.classify(
            klippy_state="shutdown", klippy_message="Lost communication", online=True
        )
        for _ in range(MAX_OUTAGE_RECORDS + 20):
            watcher.open_outage(detection, None)
            watcher._in_outage = False
        assert len(watcher.records) == MAX_OUTAGE_RECORDS


# --------------------------------------------------------------------------- #
# Durability
# --------------------------------------------------------------------------- #


class TestAtomicWrites:
    def test_a_failed_write_leaves_the_previous_file_intact(self, tmp_path: Path):
        target = tmp_path / "thing.json"
        atomic_write_json(target, {"version": 1})

        with pytest.raises(TypeError):
            atomic_write_json(target, {"bad": object()})

        assert json.loads(target.read_text())["version"] == 1
        assert list(tmp_path.glob("*.tmp")) == [], "a half-written temp file was left behind"

    def test_no_temporary_file_is_left_behind(self, tmp_path: Path):
        target = tmp_path / "thing.json"
        atomic_write_json(target, {"ok": True})
        assert list(tmp_path.glob("*.tmp")) == []

    def test_reading_a_missing_file_returns_the_default(self, tmp_path: Path):
        assert read_json(tmp_path / "nope.json", "fallback") == "fallback"
