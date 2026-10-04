"""What actually reaches the slicer when a plate has copies on it.

The expansion happens inside the job runner, between the request and the
command line, and nothing else looks at it. A silent mistake here is four clips
sliced as one - which slices happily and prints as a lump.
"""

from __future__ import annotations

import asyncio
import struct
from pathlib import Path
from typing import List, Optional

import pytest

from app.schemas import ModelTransform, SliceRequest, SliceStats
from app.slicer.engine import SliceOutcome
from app.slicer.jobs import SliceJobManager
from app.storage import GCodeStore, ModelStore


def cube_stl() -> bytes:
    corner = {
        "a": (0, 0, 0), "b": (10, 0, 0), "c": (10, 10, 0), "d": (0, 10, 0),
        "e": (0, 0, 10), "f": (10, 0, 10), "g": (10, 10, 10), "h": (0, 10, 10),
    }
    faces = [
        ("a", "c", "b"), ("a", "d", "c"), ("e", "f", "g"), ("e", "g", "h"),
        ("a", "b", "f"), ("a", "f", "e"), ("b", "c", "g"), ("b", "g", "f"),
        ("c", "d", "h"), ("c", "h", "g"), ("d", "a", "e"), ("d", "e", "h"),
    ]
    data = bytearray(b"\0" * 80) + struct.pack("<I", len(faces))
    for names in faces:
        data += struct.pack("<3f", 0.0, 0.0, 0.0)
        for name in names:
            data += struct.pack("<3f", *corner[name])
        data += struct.pack("<H", 0)
    return bytes(data)


class RecordingEngine:
    """Stands in for the slicer and remembers what it was handed."""

    name = "recording"

    def __init__(self) -> None:
        self.model_paths: List[Path] = []

    async def verify(self, force: bool = False) -> bool:
        return True

    async def slice(
        self,
        model_paths: List[Path],
        output_path: Path,
        request: SliceRequest,
        workdir: Path,
        progress=None,
    ) -> SliceOutcome:
        self.model_paths = list(model_paths)
        output_path.write_text("; sliced\nM104 S0\n", encoding="utf-8")
        return SliceOutcome(
            output_path=output_path, stats=SliceStats(), engine=self.name
        )


@pytest.fixture()
def plate(tmp_path: Path):
    models = ModelStore(tmp_path / "models")
    gcodes = GCodeStore(tmp_path / "gcode")
    engine = RecordingEngine()
    manager = SliceJobManager(engine, models, gcodes)
    return manager, models, engine


async def run(manager: SliceJobManager, request: SliceRequest):
    job = manager.submit(request)
    for _ in range(400):
        if job.status in {"done", "failed", "cancelled"}:
            break
        await asyncio.sleep(0.01)
    return job


@pytest.mark.asyncio
async def test_one_model_reaches_the_slicer_once(plate):
    manager, models, engine = plate
    model = models.save("part.stl", cube_stl())

    job = await run(manager, SliceRequest(model_id=model.id))

    assert job.status == "done", job.error
    assert len(engine.model_paths) == 1


@pytest.mark.asyncio
async def test_a_quantity_hands_the_slicer_that_many_objects(plate):
    manager, models, engine = plate
    model = models.save("clip.stl", cube_stl())

    job = await run(
        manager, SliceRequest(model_id=model.id, quantities={model.id: 4})
    )

    assert job.status == "done", job.error
    assert len(engine.model_paths) == 4


@pytest.mark.asyncio
async def test_a_mixed_plate_asks_for_different_numbers_of_each(plate):
    # The case `copies` cannot express: four clips and one lid.
    manager, models, engine = plate
    clip = models.save("clip.stl", cube_stl())
    lid = models.save("lid.stl", cube_stl())

    job = await run(
        manager,
        SliceRequest(
            model_id=clip.id,
            extra_model_ids=[lid.id],
            quantities={clip.id: 4, lid.id: 1},
        ),
    )

    assert job.status == "done", job.error
    assert len(engine.model_paths) == 5


@pytest.mark.asyncio
async def test_each_copy_is_written_where_it_was_placed(plate):
    # Every copy needs its own file: one path handed over four times is four
    # objects on the same spot, which is what a lump is.
    manager, models, engine = plate
    model = models.save("clip.stl", cube_stl())

    job = await run(
        manager,
        SliceRequest(
            model_id=model.id,
            quantities={model.id: 2},
            transforms={
                model.id: ModelTransform(offset_xy=[-40.0, 0.0]),
                f"{model.id}#2": ModelTransform(offset_xy=[40.0, 0.0]),
            },
        ),
    )

    assert job.status == "done", job.error
    assert len(set(engine.model_paths)) == 2


@pytest.mark.asyncio
async def test_a_copy_with_no_transform_of_its_own_still_gets_sliced(plate):
    # It falls back to the model's transform, which stacks it - the plate
    # screen is what warns about that. Losing the copy entirely would be worse.
    manager, models, engine = plate
    model = models.save("clip.stl", cube_stl())

    job = await run(
        manager,
        SliceRequest(
            model_id=model.id,
            quantities={model.id: 3},
            transforms={model.id: ModelTransform(rotation_deg=[0.0, 0.0, 90.0])},
        ),
    )

    assert job.status == "done", job.error
    assert len(engine.model_paths) == 3


@pytest.mark.asyncio
async def test_a_quantity_naming_a_model_that_is_not_on_the_plate_is_ignored(plate):
    manager, models, engine = plate
    model = models.save("part.stl", cube_stl())

    job = await run(
        manager, SliceRequest(model_id=model.id, quantities={"somebody-else": 9})
    )

    assert job.status == "done", job.error
    assert len(engine.model_paths) == 1
