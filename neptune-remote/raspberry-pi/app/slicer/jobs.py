"""Slicing job manager: queues work, tracks progress, publishes events."""

from __future__ import annotations

import asyncio
import logging
import shutil
import tempfile
import time
import uuid
from pathlib import Path
from typing import Awaitable, Callable, Dict, List, Optional

from ..library import transform as transform_tools
from ..schemas import AppliedColorChange, ModelTransform, SliceJob, SliceJobSummary, SliceRequest
from ..storage import GCodeStore, ModelStore, safe_filename
from . import arrange as arrange_tools
from .colors import apply_color_changes
from .engine import BaseEngine, SlicerError, SUPPORTED_MODEL_EXTENSIONS

log = logging.getLogger("neptune.slicer.jobs")

JobListener = Callable[[SliceJob], Awaitable[None]]


class SliceJobManager:
    def __init__(
        self,
        engine: BaseEngine,
        models: ModelStore,
        gcodes: GCodeStore,
        *,
        max_concurrent: int = 1,
        keep_jobs: int = 40,
    ) -> None:
        self.engine = engine
        self.models = models
        self.gcodes = gcodes
        self.keep_jobs = keep_jobs
        self._semaphore = asyncio.Semaphore(max(1, max_concurrent))
        self._jobs: Dict[str, SliceJob] = {}
        self._tasks: Dict[str, asyncio.Task[None]] = {}
        self._listeners: List[JobListener] = []

    # ---------------------------------------------------------------- events
    def add_listener(self, listener: JobListener) -> None:
        self._listeners.append(listener)

    async def _publish(self, job: SliceJob) -> None:
        for listener in list(self._listeners):
            try:
                await listener(job)
            except Exception:  # never let a listener break slicing
                log.exception("Slice job listener failed")

    # ------------------------------------------------------------------ jobs
    def get(self, job_id: str) -> Optional[SliceJob]:
        return self._jobs.get(job_id)

    def list(self) -> List[SliceJobSummary]:
        jobs = sorted(self._jobs.values(), key=lambda j: j.created_at, reverse=True)
        return [
            SliceJobSummary(
                id=j.id,
                status=j.status,
                progress=j.progress,
                stage=j.stage,
                model_filename=j.model_filename,
                output_filename=j.output_filename,
                created_at=j.created_at,
                error=j.error,
            )
            for j in jobs
        ]

    def _prune(self) -> None:
        finished = [j for j in self._jobs.values() if j.status in {"done", "failed", "cancelled"}]
        if len(finished) <= self.keep_jobs:
            return
        finished.sort(key=lambda j: j.created_at)
        for job in finished[: len(finished) - self.keep_jobs]:
            self._jobs.pop(job.id, None)
            self._tasks.pop(job.id, None)

    def cancel(self, job_id: str) -> bool:
        task = self._tasks.get(job_id)
        job = self._jobs.get(job_id)
        if task is None or job is None or job.status in {"done", "failed", "cancelled"}:
            return False
        task.cancel()
        return True

    # --------------------------------------------------------------- submit
    def submit(
        self,
        request: SliceRequest,
        *,
        on_complete: Optional[Callable[[SliceJob], Awaitable[None]]] = None,
    ) -> SliceJob:
        model = self.models.get(request.model_id)
        if model is None:
            raise FileNotFoundError(f"Model '{request.model_id}' not found")

        # Every model on the plate is checked before any of them is queued.
        # Failing on the fourth file after the first three have been prepared
        # wastes the user's time and leaves a half-built job behind.
        plate = [model]
        for extra_id in request.extra_model_ids:
            if extra_id == request.model_id:
                continue
            extra = self.models.get(extra_id)
            if extra is None:
                raise FileNotFoundError(f"Model '{extra_id}' not found")
            plate.append(extra)

        for item in plate:
            extension = Path(item.filename).suffix.lower()
            if extension not in SUPPORTED_MODEL_EXTENSIONS:
                raise ValueError(
                    f"Unsupported model type '{extension}' in {item.filename}. Supported: "
                    + ", ".join(sorted(SUPPORTED_MODEL_EXTENSIONS))
                )

        job_id = uuid.uuid4().hex[:12]
        # A plate of four parts named after only the first one is a file you
        # cannot identify a week later.
        default_name = Path(model.filename).stem
        if len(plate) > 1:
            default_name += f"+{len(plate) - 1}"
        if int(request.copies or 1) > 1:
            default_name += f"-x{int(request.copies)}"
        output_name = safe_filename(
            request.output_name or f"{default_name}.gcode", "output.gcode"
        )
        if not output_name.lower().endswith((".gcode", ".gco", ".g")):
            output_name += ".gcode"

        job = SliceJob(
            id=job_id,
            status="queued",
            progress=0.0,
            stage="Queued",
            model_id=model.id,
            model_filename=model.filename,
            output_filename=output_name,
            created_at=time.time(),
            request=request,
            engine=self.engine.name,
        )
        self._jobs[job_id] = job
        self._prune()

        self._tasks[job_id] = asyncio.create_task(self._run(job, on_complete))
        return job

    async def _apply_color_changes(
        self,
        job: SliceJob,
        output_path: Path,
        progress: Callable[[float, str, Optional[str]], Awaitable[None]],
    ) -> None:
        """Place the filament swaps, after slicing and before anything reads the file.

        No slicer's command line can do this, so it is done to the finished
        G-code. Rewriting a large file is blocking work on a Raspberry Pi that
        is also serving the app, so it runs in a thread rather than stalling the
        event loop.

        A failure here fails the whole job. A three-colour print that quietly
        came out in one colour would be discovered six hours later, by which
        point the filament and the time are already spent.
        """
        assert job.request is not None
        requested = job.request.color_changes
        if not requested:
            return

        await progress(0.97, "Placing colour changes", None)
        applied = await asyncio.to_thread(
            apply_color_changes,
            output_path,
            [(item.layer, item.color) for item in requested],
        )
        job.color_changes = [
            AppliedColorChange(layer=item.layer, color=item.color, z=item.z)
            for item in applied
        ]
        for item in applied:
            height = f" (Z {item.z:.2f} mm)" if item.z is not None else ""
            job.logs.append(f"Colour change at layer {item.layer}{height}: {item.color}")

    def _placed(
        self,
        identifier: str,
        path: Path,
        request: SliceRequest,
        workdir: Path,
    ) -> Path:
        """The path the slicer should read for this model.

        Unchanged when there is no transform, so the common case costs nothing.
        Otherwise a turned copy is written into the job's own temporary
        directory - the file in the library is never modified, which is what
        makes a rotation something the user can take back.

        A transform that cannot be applied is not fatal. Refusing to slice
        because a stored rotation is malformed would strand a model the user
        can otherwise print; the original is sliced instead and the reason is
        logged.
        """
        # The instance's own transform first, then the model's. Copies of one
        # model are placed individually, and falling back to the model's
        # transform for each of them would stack them on the same spot.
        spec = request.transforms.get(identifier) or request.transforms.get(
            arrange_tools.base_id(identifier)
        )
        if spec is None:
            return path

        placement = transform_tools.Transform.from_dict(spec.model_dump())
        if placement.is_identity and not placement.drop_to_bed and not placement.center_on_bed:
            return path

        target = workdir / f"placed-{safe_filename(identifier)}.stl"
        try:
            written, _ = transform_tools.materialise(
                path, target, placement, name=identifier
            )
            return written
        except Exception as error:  # mesh, numpy or transform failure
            log.warning(
                "Could not place model %s (%s); slicing the original", identifier, error
            )
            return path

    async def _run(
        self,
        job: SliceJob,
        on_complete: Optional[Callable[[SliceJob], Awaitable[None]]],
    ) -> None:
        async with self._semaphore:
            job.status = "running"
            job.started_at = time.time()
            job.stage = "Preparing"
            job.progress = 0.02
            await self._publish(job)

            workdir = Path(tempfile.mkdtemp(prefix=f"neptune-slice-{job.id}-"))
            try:
                assert job.request is not None
                ordered = [job.model_id] + [
                    value for value in job.request.extra_model_ids if value != job.model_id
                ]
                # One entry per copy. Quantity is expanded here rather than
                # handed to the slicer's `--duplicate`, which multiplies the
                # whole plate: four clips and one lid cannot be asked for that
                # way at all.
                identifiers = arrange_tools.expand(ordered, job.request.quantities)
                model_paths = []
                for identifier in identifiers:
                    path = self.models.path_for(arrange_tools.base_id(identifier))
                    if path is None:
                        raise SlicerError(
                            f"Model file for '{identifier}' disappeared before slicing started"
                        )
                    model_paths.append(
                        self._placed(identifier, path, job.request, workdir)
                    )

                output_path = self.gcodes.unique_path(job.output_filename)
                job.output_filename = output_path.name

                last_publish = 0.0

                async def progress(value: float, stage: str, line: Optional[str]) -> None:
                    nonlocal last_publish
                    job.progress = max(job.progress, min(0.99, value))
                    if stage:
                        job.stage = stage
                    if line:
                        job.logs.append(line)
                        if len(job.logs) > 500:
                            del job.logs[: len(job.logs) - 500]
                    now = time.monotonic()
                    if stage or now - last_publish > 0.5:
                        last_publish = now
                        await self._publish(job)

                outcome = await self.engine.slice(
                    model_paths, output_path, job.request, workdir, progress
                )

                await self._apply_color_changes(job, Path(outcome.output_path), progress)

                job.output_path = str(outcome.output_path)
                job.stats = outcome.stats
                job.engine = outcome.engine
                job.progress = 1.0
                job.stage = "Completed"
                job.status = "done"
                job.finished_at = time.time()
                await self._publish(job)

                if on_complete is not None:
                    try:
                        await on_complete(job)
                    except Exception as exc:  # upload failures must not lose the G-code
                        log.exception("Post-slice hook failed")
                        job.logs.append(f"Post-slice step failed: {exc}")
                        await self._publish(job)

            except asyncio.CancelledError:
                job.status = "cancelled"
                job.stage = "Cancelled"
                job.finished_at = time.time()
                await self._publish(job)
                raise
            except (SlicerError, FileNotFoundError, ValueError, OSError) as exc:
                message = getattr(exc, "message", None) or str(exc)
                job.status = "failed"
                job.stage = "Failed"
                job.error = message
                job.finished_at = time.time()
                extra_logs = getattr(exc, "logs", None)
                if extra_logs:
                    job.logs.extend(extra_logs[-30:])
                await self._publish(job)
                log.error("Slice job %s failed: %s", job.id, message)
            finally:
                shutil.rmtree(workdir, ignore_errors=True)
