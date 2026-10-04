"""Filament inventory, cost calculator, products, maintenance and the queue."""

from __future__ import annotations

import time
from pathlib import Path

import pytest

from app.cost.calculator import CostCalculator, CostRequest, CostSettings
from app.db import Database
from app.filament.store import SAFETY_MARGIN_GRAMS, FilamentStore, SpoolCreate, SpoolUpdate, grams_from_mm
from app.library.models import LibraryItemCreate
from app.library.store import LibraryStore
from app.maintenance.store import MaintenanceStore
from app.paths import StorageLayout
from app.printqueue.store import PrintQueueStore, QueueJobCreate
from app.products.store import ProductCreate, ProductStore, ProductUpdate


@pytest.fixture()
def database(tmp_path: Path) -> Database:
    db = Database(tmp_path / "test.db")
    yield db
    db.close()


# --------------------------------------------------------------------------- #
# Filament
# --------------------------------------------------------------------------- #


def test_grams_from_mm_matches_physics():
    # 1000 mm of 1.75 mm PLA: pi * 0.0875^2 cm^2 * 100 cm * 1.24 g/cm3
    grams = grams_from_mm(1000, "PLA")
    assert grams == pytest.approx(2.983, rel=0.01)
    assert grams_from_mm(0) == 0.0
    # Denser materials weigh more for the same length.
    assert grams_from_mm(1000, "PETG") > grams_from_mm(1000, "TPU")


def test_unknown_material_uses_the_default_density():
    assert grams_from_mm(1000, "UNOBTANIUM") == pytest.approx(grams_from_mm(1000, "PLA"))


def test_create_and_list_spools(database: Database):
    store = FilamentStore(database)
    spool = store.create(
        SpoolCreate(brand="eSun", material="pla", color_name="أسود", color_hex="#101010",
                    initial_grams=1000, price=700, active=True)
    )
    assert spool.material == "PLA"
    assert spool.remaining_grams == 1000
    assert spool.active is True
    assert store.active_spool().id == spool.id
    assert len(store.list()) == 1


def test_only_one_spool_is_active(database: Database):
    store = FilamentStore(database)
    first = store.create(SpoolCreate(brand="A", active=True))
    second = store.create(SpoolCreate(brand="B", active=True))
    assert store.active_spool().id == second.id
    assert store.get(first.id).active is False


def test_set_active(database: Database):
    store = FilamentStore(database)
    first = store.create(SpoolCreate(brand="A", active=True))
    second = store.create(SpoolCreate(brand="B"))
    store.set_active(second.id)
    assert store.active_spool().id == second.id


def test_consume_subtracts_and_logs(database: Database):
    store = FilamentStore(database)
    spool = store.create(SpoolCreate(initial_grams=1000, active=True))
    updated = store.consume(120.5)
    assert updated.remaining_grams == pytest.approx(879.5)
    assert store.usage_history()[0]["grams"] == pytest.approx(120.5)


def test_consume_never_goes_negative(database: Database):
    store = FilamentStore(database)
    store.create(SpoolCreate(initial_grams=50, remaining_grams=50, active=True))
    updated = store.consume(500)
    assert updated.remaining_grams == 0.0


def test_consume_without_a_spool_is_safe(database: Database):
    store = FilamentStore(database)
    assert store.consume(50) is None


def test_check_enough_filament(database: Database):
    store = FilamentStore(database)
    store.create(SpoolCreate(initial_grams=1000, remaining_grams=100, material="PLA", active=True))

    ok = store.check_enough(50)
    assert ok.ok is True
    assert ok.message_key == "filament.check.ok"

    # 90 g needed + the safety margin exceeds the 100 g left.
    short = store.check_enough(90)
    assert short.ok is False
    assert short.message_key == "filament.check.not_enough"
    assert short.margin_grams == SAFETY_MARGIN_GRAMS


def test_check_warns_on_material_mismatch(database: Database):
    store = FilamentStore(database)
    store.create(SpoolCreate(initial_grams=1000, remaining_grams=900, material="PETG", active=True))
    result = store.check_enough(50, material="TPU")
    assert result.ok is True
    assert result.message_key == "filament.check.material_mismatch"


def test_check_without_inventory_never_blocks(database: Database):
    store = FilamentStore(database)
    result = store.check_enough(500)
    assert result.ok is True
    assert result.has_active_spool is False
    assert result.message_key == "filament.check.no_spool"


def test_spool_percentages_and_cost(database: Database):
    store = FilamentStore(database)
    spool = store.create(SpoolCreate(initial_grams=1000, remaining_grams=250, price=800))
    assert spool.percent_remaining == pytest.approx(0.25)
    assert spool.cost_per_gram == pytest.approx(0.8)


def test_update_and_delete_spool(database: Database):
    store = FilamentStore(database)
    spool = store.create(SpoolCreate(brand="X"))
    updated = store.update(spool.id, SpoolUpdate(brand="Y", remaining_grams=400))
    assert updated.brand == "Y"
    assert updated.remaining_grams == 400
    assert store.delete(spool.id) is True
    assert store.get(spool.id) is None


def test_summary(database: Database):
    store = FilamentStore(database)
    store.create(SpoolCreate(material="PLA", initial_grams=1000, remaining_grams=600, price=700, active=True))
    store.create(SpoolCreate(material="PETG", initial_grams=1000, remaining_grams=300, price=900))
    summary = store.summary()
    assert summary["spool_count"] == 2
    assert summary["total_remaining_grams"] == pytest.approx(900)
    assert summary["by_material"]["PLA"] == pytest.approx(600)


# --------------------------------------------------------------------------- #
# Cost
# --------------------------------------------------------------------------- #


def test_cost_breakdown_is_arithmetically_correct(database: Database):
    calculator = CostCalculator(database)
    settings = CostSettings(
        currency="EGP", filament_price_per_kg=700, electricity_price_per_kwh=1.5,
        printer_watts=200, machine_hourly_rate=5, failure_rate_percent=10,
        labour_per_print=10, packaging_per_print=0, other_per_print=0,
        profit_percent=50, round_selling_price_to=5,
    )
    result = calculator.calculate(
        CostRequest(filament_grams=100, print_seconds=7200), settings=settings
    )

    # filament 0.1 kg * 700 = 70
    # electricity 2 h * 0.2 kW * 1.5 = 0.6
    # machine 2 h * 5 = 10
    # labour 10  -> subtotal 90.6, +10% failure = 99.66
    assert result.cost_per_unit == pytest.approx(99.66, abs=0.01)
    assert result.suggested_price_per_unit == pytest.approx(150.0)   # 149.49 rounded up to 5
    assert result.profit_per_unit == pytest.approx(50.34, abs=0.01)
    assert result.currency == "EGP"
    assert result.print_hours == 2.0


def test_cost_quantity_multiplies(database: Database):
    calculator = CostCalculator(database)
    single = calculator.calculate(CostRequest(filament_grams=50, print_seconds=3600))
    ten = calculator.calculate(CostRequest(filament_grams=50, print_seconds=3600, quantity=10))
    assert ten.total_cost == pytest.approx(single.cost_per_unit * 10, abs=0.05)


def test_cost_settings_round_trip(database: Database):
    calculator = CostCalculator(database)
    saved = calculator.save_settings(CostSettings(currency="USD", profit_percent=25))
    assert saved.currency == "USD"
    assert calculator.settings().profit_percent == 25


def test_cost_with_zero_print_is_not_negative(database: Database):
    calculator = CostCalculator(database)
    result = calculator.calculate(CostRequest())
    assert result.cost_per_unit >= 0
    assert result.suggested_price_per_unit >= result.cost_per_unit


def test_spool_price_overrides_the_default(database: Database):
    calculator = CostCalculator(database)
    cheap = calculator.calculate(
        CostRequest(filament_grams=1000, print_seconds=0), filament_price_per_kg=100
    )
    expensive = calculator.calculate(
        CostRequest(filament_grams=1000, print_seconds=0), filament_price_per_kg=1000
    )
    assert expensive.cost_per_unit > cheap.cost_per_unit


# --------------------------------------------------------------------------- #
# Products
# --------------------------------------------------------------------------- #


def test_product_lifecycle(database: Database, tmp_path: Path):
    layout = StorageLayout.create(tmp_path / "storage")
    library = LibraryStore(database, layout)
    item = library.create_item(payload=LibraryItemCreate(name_ar="ميدالية", name_en="Keychain"))

    products = ProductStore(database)
    product = products.create(
        ProductCreate(item_id=item.id, print_cost=12.0, selling_price=40.0, colors=["أسود", "أحمر"])
    )
    assert product.name_ar == "ميدالية"
    assert product.colors == ["أسود", "أحمر"]
    assert product.margin == pytest.approx(28.0)
    assert product.margin_percent == pytest.approx(233.33, abs=0.1)

    # Linking marks the library item as a product and files it in the collection.
    refreshed = library.get_item(item.id)
    assert refreshed.is_product is True
    assert "products" in refreshed.collections

    updated = products.update(product.id, ProductUpdate(selling_price=50.0, stock=3))
    assert updated.selling_price == 50.0
    assert updated.stock == 3

    assert products.summary()["count"] == 1
    assert products.delete(product.id) is True
    assert library.get_item(item.id).is_product is False


def test_product_without_a_linked_model(database: Database):
    products = ProductStore(database)
    product = products.create(ProductCreate(name_ar="منتج مستقل", selling_price=10))
    assert product.item_id is None
    assert products.get(product.id) is not None


# --------------------------------------------------------------------------- #
# Maintenance
# --------------------------------------------------------------------------- #


def test_builtin_maintenance_tasks_exist(database: Database):
    store = MaintenanceStore(database)
    status = store.status(total_prints=0, total_print_hours=0)
    ids = {task.id for task in status.tasks}
    assert {"clean_bed", "clean_nozzle", "lubricate_z_screws", "check_belts"} <= ids
    assert all(task.name_ar for task in status.tasks)


def test_lubrication_guidance_names_the_z_screws_and_warns_off_the_wheels(database: Database):
    """POM V wheels and the aluminium V-slot must run dry; only Z screws get grease.

    Getting this wrong wears the wheels out, so the guidance has to be explicit
    rather than a generic "lubricate the axes".
    """
    store = MaintenanceStore(database)
    status = store.status(total_prints=0, total_print_hours=0)
    task = next(t for t in status.tasks if t.id == "lubricate_z_screws")

    assert "lead screw" in task.name_en.lower()
    guidance = task.guidance_en.lower()
    assert "ptfe" in guidance or "lithium" in guidance
    assert "do not lubricate" in guidance
    assert "pom" in guidance
    assert "v-slot" in guidance or "v slot" in guidance

    # And nowhere in the app does lubrication and a wheel or rail appear together
    # without a prohibition attached.
    for candidate in status.tasks:
        text = f"{candidate.name_en} {candidate.guidance_en}".lower()
        mentions_lubrication = "lubricat" in text
        mentions_dry_parts = "wheel" in text or "v-slot" in text or "rail" in text
        if mentions_lubrication and mentions_dry_parts:
            assert any(word in text for word in ("do not", "never", "must stay dry")), candidate.id


def test_the_maintenance_checklist_covers_what_the_frame_needs(database: Database):
    store = MaintenanceStore(database)
    ids = {task.id for task in store.status(total_prints=0, total_print_hours=0).tasks}
    for required in (
        "check_wheels", "check_eccentric_nuts", "check_belts", "lubricate_z_screws",
        "clean_nozzle", "check_hotend", "clean_fans", "check_bed_screws",
        "inspect_wiring", "check_filament_sensor",
    ):
        assert required in ids, required


def test_every_task_explains_what_to_do(database: Database):
    store = MaintenanceStore(database)
    for task in store.status(total_prints=0, total_print_hours=0).tasks:
        assert task.guidance_en, task.id
        assert task.guidance_ar, task.id


def test_task_becomes_due_from_print_hours(database: Database):
    store = MaintenanceStore(database)
    status = store.status(total_prints=0, total_print_hours=0)
    nozzle = next(task for task in status.tasks if task.id == "clean_nozzle")
    assert nozzle.due is False

    status = store.status(total_prints=0, total_print_hours=61)
    nozzle = next(task for task in status.tasks if task.id == "clean_nozzle")
    assert nozzle.due is True
    assert nozzle.due_reason == "maintenance.reason.hours"


def test_task_becomes_due_from_print_count(database: Database):
    store = MaintenanceStore(database)
    status = store.status(total_prints=11, total_print_hours=0)
    bed = next(task for task in status.tasks if task.id == "clean_bed")
    assert bed.due is True


def test_completing_a_task_resets_it(database: Database):
    store = MaintenanceStore(database)
    assert store.status(total_prints=0, total_print_hours=61).due_count >= 1

    store.complete("clean_nozzle", total_prints=0, total_print_hours=61, note="نظفت النوزل")
    status = store.status(total_prints=0, total_print_hours=61)
    nozzle = next(task for task in status.tasks if task.id == "clean_nozzle")
    assert nozzle.due is False
    assert store.log()[0]["note"] == "نظفت النوزل"


def test_custom_task_can_be_created_and_deleted(database: Database):
    store = MaintenanceStore(database)
    task = store.create(name_ar="تغيير النوزل", interval_hours=500)
    assert task.builtin is False
    assert store.delete(task.id) is True


def test_builtin_task_cannot_be_deleted(database: Database):
    store = MaintenanceStore(database)
    assert store.delete("clean_bed") is False


# --------------------------------------------------------------------------- #
# Print queue
# --------------------------------------------------------------------------- #


def test_queue_add_and_order(database: Database):
    queue = PrintQueueStore(database)
    first = queue.add(QueueJobCreate(gcode_path="a.gcode", display_name="A", estimated_seconds=600))
    second = queue.add(QueueJobCreate(gcode_path="b.gcode", display_name="B", estimated_seconds=1200))

    jobs = queue.list()
    assert [job.id for job in jobs] == [first.id, second.id]

    queue.reorder([second.id, first.id])
    assert [job.id for job in queue.list()] == [second.id, first.id]


def test_queue_never_auto_starts_without_a_clear_bed(database: Database):
    queue = PrintQueueStore(database)
    queue.add(QueueJobCreate(gcode_path="a.gcode"))

    state = queue.state(printer_state="standby")
    assert state.blocked_reason_key == "queue.blocked.bed_not_clear"
    assert state.next_job is None
    assert queue.take_next(printer_state="standby") is None


def test_queue_starts_after_bed_is_confirmed(database: Database):
    queue = PrintQueueStore(database)
    job = queue.add(QueueJobCreate(gcode_path="a.gcode"))
    queue.set_bed_clear(True)

    state = queue.state(printer_state="standby")
    assert state.blocked_reason_key == ""
    assert state.next_job.id == job.id

    started = queue.take_next(printer_state="standby")
    assert started is not None and started.status == "printing"
    # Starting consumes the confirmation, so the next one needs a fresh check.
    assert queue.bed_clear() is False


def test_queue_blocked_while_printing(database: Database):
    queue = PrintQueueStore(database)
    queue.add(QueueJobCreate(gcode_path="a.gcode"))
    queue.set_bed_clear(True)
    state = queue.state(printer_state="printing")
    assert state.blocked_reason_key == "queue.blocked.printing"
    assert queue.take_next(printer_state="printing") is None


def test_queue_totals_and_removal(database: Database):
    queue = PrintQueueStore(database)
    queue.add(QueueJobCreate(gcode_path="a.gcode", estimated_seconds=600, filament_g=10))
    job = queue.add(QueueJobCreate(gcode_path="b.gcode", estimated_seconds=1200, filament_g=20))

    state = queue.state()
    assert state.total_seconds == 1800
    assert state.total_filament_g == 30

    assert queue.remove(job.id) is True
    assert len(queue.list()) == 1
    assert queue.clear() == 1
