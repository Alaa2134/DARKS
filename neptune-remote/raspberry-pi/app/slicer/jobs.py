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

from ..schemas import SliceJob, SliceJobSummary, SliceRequest
from ..storage import GCodeStore, ModelStore, safe_filename
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

        extension = Path(model.filename).suffix.lower()
        if extension not in SUPPORTED_MODEL_EXTENSIONS:
            raise ValueError(
                f"Unsupported model type '{extension}'. Supported: "
                + ", ".join(sorted(SUPPORTED_MODEL_EXTENSIONS))
            )

        job_id = uuid.uuid4().hex[:12]
        output_name = safe_filename(
            request.output_name or f"{Path(model.filename).stem}.gcode", "output.gcode"
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
                model_path = self.models.path_for(job.model_id)
                if model_path is None:
                    raise SlicerError("Model file disappeared before slicing started")

                assert job.request is not None
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
                    model_path, output_path, job.request, workdir, progress
                )

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
