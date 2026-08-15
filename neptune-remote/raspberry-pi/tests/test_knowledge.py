"""Error translator, troubleshooting trees and configuration backups."""

from __future__ import annotations

import zipfile
from pathlib import Path

import pytest

from app.backup.service import REDACTED, BackupService, redact
from app.config import AppConfig
from app.knowledge import translate_error, topic, topics
from app.paths import StorageLayout


# --------------------------------------------------------------------------- #
# Error translation
# --------------------------------------------------------------------------- #


@pytest.mark.parametrize(
    "message,expected_code",
    [
        ("Timer too close (m=... c=...)", "mcu_shutdown_timer_too_close"),
        ("Lost communication with MCU 'mcu'", "mcu_shutdown_lost_communication"),
        ("Heater extruder not heating at expected rate", "heater_not_heating"),
        ("ADC out of range", "thermistor_shorted"),
        ("Probe triggered prior to movement", "probe_failed"),
        ("Must home axis first: 100.000 0.000 0.000 [0.000]", "must_home_first"),
        ("Extrude below minimum temp", "extrude_below_min_temp"),
        ("Move out of range: 400.000 0.000 0.000 [0.000]", "move_out_of_range"),
        ("Klipper is not ready", "klipper_not_ready"),
        ("Shutdown due to webhooks request", "shutdown_by_user"),
        ("No space left on device", "no_space_left"),
    ],
)
def test_known_errors_are_translated(message, expected_code):
    result = translate_error(message)
    assert result.matched is True
    assert result.code == expected_code
    assert result.title_ar
    assert result.explanation_ar
    assert result.original == message


def test_translation_always_keeps_the_original():
    raw = "Some brand new Klipper error nobody has seen"
    result = translate_error(raw)
    assert result.matched is False
    assert result.original == raw
    assert result.title_ar  # still gives the user something readable


def test_empty_message():
    result = translate_error("")
    assert result.matched is False
    assert result.original == ""


def test_critical_errors_are_marked_critical():
    assert translate_error("Timer too close").severity == "critical"
    assert translate_error("Must home axis first").severity == "warning"


def test_every_rule_has_arabic_causes_and_checks():
    from app.knowledge import ERROR_RULES

    for rule in ERROR_RULES:
        assert rule["title_ar"], rule["code"]
        assert rule["explanation_ar"], rule["code"]
        assert rule["causes_ar"], rule["code"]
        assert rule["checks_ar"], rule["code"]


# --------------------------------------------------------------------------- #
# Troubleshooting trees
# --------------------------------------------------------------------------- #


def test_topics_cover_the_common_problems():
    ids = {item.id for item in topics()}
    assert {
        "adhesion", "stringing", "warping", "layer_shift", "clog",
        "under_extrusion", "tpu", "printer_offline",
    } <= ids


def test_topic_lookup():
    found = topic("adhesion")
    assert found is not None
    assert found.title_ar
    assert found.quick_fixes_ar
    assert topic("nope") is None


def test_decision_trees_are_well_formed():
    """Every branch must lead to a real step, and every path must end in advice."""
    for item in topics():
        steps = {step.id: step for step in item.steps}
        assert item.first_step in steps, f"{item.id}: bad first_step"

        for step in item.steps:
            for target in (step.yes_next, step.no_next):
                if target is not None:
                    assert target in steps, f"{item.id}/{step.id} -> {target} does not exist"
            # A leaf must give advice, a question must have both branches.
            if step.yes_next is None and step.no_next is None:
                assert step.advice_ar, f"{item.id}/{step.id} is a dead end with no advice"
            else:
                assert step.question_ar, f"{item.id}/{step.id} has branches but no question"


def test_every_step_is_reachable():
    for item in topics():
        steps = {step.id: step for step in item.steps}
        reachable = set()
        stack = [item.first_step]
        while stack:
            current = stack.pop()
            if current in reachable or current not in steps:
                continue
            reachable.add(current)
            step = steps[current]
            stack.extend(target for target in (step.yes_next, step.no_next) if target)
        assert reachable == set(steps), f"{item.id}: unreachable steps {set(steps) - reachable}"


# --------------------------------------------------------------------------- #
# Backups
# --------------------------------------------------------------------------- #


def test_redact_strips_secrets():
    data = {
        "tuya": {"access_id": "abc", "access_secret": "xyz", "endpoint": "https://x"},
        "server": {"api_token": "t0ken", "port": 8710},
        "list": [{"password": "p"}],
    }
    cleaned = redact(data)
    assert cleaned["tuya"]["access_secret"] == REDACTED
    assert cleaned["tuya"]["access_id"] == REDACTED
    assert cleaned["tuya"]["endpoint"] == "https://x"
    assert cleaned["server"]["api_token"] == REDACTED
    assert cleaned["server"]["port"] == 8710
    assert cleaned["list"][0]["password"] == REDACTED


def test_redact_leaves_empty_secrets_alone():
    assert redact({"api_token": ""})["api_token"] == ""


def test_backup_contains_config_and_never_the_secrets(tmp_path: Path):
    printer_cfg = tmp_path / "printer.cfg"
    printer_cfg.write_text("[printer]\nkinematics: cartesian\n", encoding="utf-8")

    config = AppConfig()
    config.storage.root = str(tmp_path / "storage")
    config.storage.backup_sources = [str(printer_cfg)]
    config.paths.profiles_dir = str(Path(__file__).resolve().parent.parent / "profiles")
    config.tuya.access_secret = "super-secret-value"
    config.server.api_token = "my-token"

    layout = StorageLayout.create(config.storage.root)
    service = BackupService(config, layout)
    info = service.create()

    assert info.filename.endswith(".zip")
    archive_path = layout.backups / info.filename
    assert archive_path.is_file()

    with zipfile.ZipFile(archive_path) as archive:
        names = archive.namelist()
        assert "printer_config/printer.cfg" in names
        assert "neptune_remote/config.redacted.yaml" in names
        assert any(name.startswith("profiles/") for name in names)

        payload = archive.read("neptune_remote/config.redacted.yaml").decode()
        assert "super-secret-value" not in payload
        assert "my-token" not in payload
        assert REDACTED in payload

        # And the original printer.cfg is byte-for-byte unchanged.
        assert archive.read("printer_config/printer.cfg").decode() == printer_cfg.read_text()

    # The source file must not have been touched.
    assert printer_cfg.read_text() == "[printer]\nkinematics: cartesian\n"


def test_backup_list_and_delete(tmp_path: Path):
    config = AppConfig()
    config.storage.root = str(tmp_path / "storage")
    config.storage.backup_sources = []
    layout = StorageLayout.create(config.storage.root)
    service = BackupService(config, layout)

    info = service.create(include_profiles=False)
    assert len(service.list()) == 1
    assert service.get(info.filename) is not None
    assert service.delete(info.filename) is True
    assert service.list() == []
    assert service.delete("nope.zip") is False


def test_backup_pruning(tmp_path: Path):
    config = AppConfig()
    config.storage.root = str(tmp_path / "storage")
    config.storage.backup_sources = []
    config.storage.max_backups = 3
    layout = StorageLayout.create(config.storage.root)
    service = BackupService(config, layout)

    import time

    for _ in range(5):
        service.create(include_profiles=False)
        time.sleep(1.01)  # backup names carry a one-second timestamp

    assert len(service.list()) <= 3
