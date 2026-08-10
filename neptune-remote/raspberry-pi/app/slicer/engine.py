"""Slicing engines.

We never re-implement slicing: a real CLI slicer does the work.

* ``prusaslicer`` (default, recommended) - ``prusa-slicer`` builds ini config
  files. All parameters, including custom overrides, are written into a
  generated ``overrides.ini`` which is ``--load``ed last, so it wins over the
  printer/filament/print profiles. This avoids guessing CLI flag spellings.

* ``orcaslicer`` (optional) - ``orca-slicer`` uses JSON settings. We merge the
  base JSON profiles with the request overrides into temporary files and pass
  them with ``--load-settings`` / ``--load-filaments``.
"""

from __future__ import annotations

import asyncio
import json
import logging
import re
import shutil
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Awaitable, Callable, Dict, List, Optional

from ..schemas import SliceRequest, SliceStats
from .gcode_meta import parse_gcode
from .profiles import Profile, ProfileStore

log = logging.getLogger("neptune.slicer.engine")

ProgressCallback = Callable[[float, str, Optional[str]], Awaitable[None]]

SUPPORTED_MODEL_EXTENSIONS = {".stl", ".3mf", ".obj", ".amf", ".step", ".stp"}

# PrusaSlicer prints its pipeline stages on stdout; map them to a rough
# percentage. The CLI has no machine-readable progress channel, so this is an
# approximation by design (documented in docs/SLICER.md).
PRUSA_STAGES: List[tuple[re.Pattern[str], float, str]] = [
    (re.compile(r"processing triangulated mesh", re.I), 0.10, "Processing mesh"),
    (re.compile(r"generating perimeters", re.I), 0.25, "Generating perimeters"),
    (re.compile(r"preparing infill", re.I), 0.40, "Preparing infill"),
    (re.compile(r"infilling layers", re.I), 0.55, "Infilling layers"),
    (re.compile(r"generating (skirt|brim)", re.I), 0.65, "Skirt / brim"),
    (re.compile(r"generating support material", re.I), 0.72, "Support material"),
    (re.compile(r"searching for optimal orientation", re.I), 0.08, "Orienting"),
    (re.compile(r"estimating (printing )?time", re.I), 0.85, "Estimating time"),
    (re.compile(r"exporting g-?code", re.I), 0.90, "Exporting G-code"),
    (re.compile(r"slicing finished", re.I), 0.98, "Finishing"),
]

ORCA_STAGES: List[tuple[re.Pattern[str], float, str]] = [
    (re.compile(r"load_step|loading model", re.I), 0.10, "Loading model"),
    (re.compile(r"arrange|orient", re.I), 0.20, "Arranging"),
    (re.compile(r"slicing plate", re.I), 0.40, "Slicing"),
    (re.compile(r"generat", re.I), 0.60, "Generating toolpaths"),
    (re.compile(r"export", re.I), 0.90, "Exporting G-code"),
]


class SlicerError(RuntimeError):
    def __init__(self, message: str, logs: Optional[List[str]] = None) -> None:
        super().__init__(message)
        self.message = message
        self.logs = logs or []


@dataclass
class SliceOutcome:
    output_path: Path
    stats: SliceStats
    logs: List[str] = field(default_factory=list)
    engine: str = ""
    command: List[str] = field(default_factory=list)


# --------------------------------------------------------------------------- #
# Parameter mapping
# --------------------------------------------------------------------------- #

# SliceRequest field -> PrusaSlicer ini key
PRUSA_KEY_MAP: Dict[str, str] = {
    "layer_height": "layer_height",
    "first_layer_height": "first_layer_height",
    "nozzle_diameter": "nozzle_diameter",
    "infill_pattern": "fill_pattern",
    "perimeters": "perimeters",
    "nozzle_temperature": "temperature",
    "first_layer_nozzle_temperature": "first_layer_temperature",
    "bed_temperature": "bed_temperature",
    "first_layer_bed_temperature": "first_layer_bed_temperature",
    "retraction_length": "retract_length",
    "retraction_speed": "retract_speed",
}

# SliceRequest field -> OrcaSlicer JSON key
ORCA_KEY_MAP: Dict[str, str] = {
    "layer_height": "layer_height",
    "first_layer_height": "initial_layer_print_height",
    "nozzle_diameter": "nozzle_diameter",
    "infill_pattern": "sparse_infill_pattern",
    "perimeters": "wall_loops",
    "nozzle_temperature": "nozzle_temperature",
    "first_layer_nozzle_temperature": "nozzle_temperature_initial_layer",
    "bed_temperature": "hot_plate_temp",
    "first_layer_bed_temperature": "hot_plate_temp_initial_layer",
    "retraction_length": "retraction_length",
    "retraction_speed": "retraction_speed",
}

# Normalised speed keys used by the iOS app -> slicer specific keys.
SPEED_KEY_MAP_PRUSA: Dict[str, str] = {
    "perimeter": "perimeter_speed",
    "external_perimeter": "external_perimeter_speed",
    "infill": "infill_speed",
    "solid_infill": "solid_infill_speed",
    "top_solid_infill": "top_solid_infill_speed",
    "first_layer": "first_layer_speed",
    "travel": "travel_speed",
    "acceleration": "default_acceleration",
}

SPEED_KEY_MAP_ORCA: Dict[str, str] = {
    "perimeter": "inner_wall_speed",
    "external_perimeter": "outer_wall_speed",
    "infill": "sparse_infill_speed",
    "solid_infill": "internal_solid_infill_speed",
    "top_solid_infill": "top_surface_speed",
    "first_layer": "initial_layer_speed",
    "travel": "travel_speed",
    "acceleration": "default_acceleration",
}

ADHESION_PRUSA: Dict[str, Dict[str, str]] = {
    "none": {"skirts": "0", "brim_width": "0", "raft_layers": "0"},
    "skirt": {"skirts": "2", "brim_width": "0", "raft_layers": "0"},
    "brim": {"skirts": "0", "brim_width": "5", "raft_layers": "0"},
    "raft": {"skirts": "0", "brim_width": "0", "raft_layers": "3"},
}

ADHESION_ORCA: Dict[str, Dict[str, Any]] = {
    "none": {"skirt_loops": 0, "brim_type": "no_brim", "raft_layers": 0},
    "skirt": {"skirt_loops": 2, "brim_type": "no_brim", "raft_layers": 0},
    "brim": {"skirt_loops": 0, "brim_type": "outer_only", "brim_width": 5, "raft_layers": 0},
    "raft": {"skirt_loops": 0, "brim_type": "no_brim", "raft_layers": 3},
}

SUPPORT_STYLE_PRUSA = {"grid": "grid", "snug": "snug", "organic": "organic"}
SUPPORT_STYLE_ORCA = {"grid": "grid", "snug": "snug", "organic": "tree_organic"}


def _num(value: float) -> str:
    if float(value).is_integer():
        return str(int(value))
    return f"{value:g}"


def build_prusa_overrides(request: SliceRequest) -> Dict[str, str]:
    """Turn a SliceRequest into PrusaSlicer ini keys."""
    out: Dict[str, str] = {}

    for field_name, key in PRUSA_KEY_MAP.items():
        value = getattr(request, field_name, None)
        if value is None:
            continue
        out[key] = _num(float(value)) if isinstance(value, (int, float)) else str(value)

    if request.infill_percent is not None:
        out["fill_density"] = f"{int(request.infill_percent)}%"

    out["support_material"] = "1" if request.supports else "0"
    if request.supports:
        out["support_material_auto"] = "1"
        if request.support_style and request.support_style in SUPPORT_STYLE_PRUSA:
            out["support_material_style"] = SUPPORT_STYLE_PRUSA[request.support_style]
        if request.support_placement:
            out["support_material_buildplate_only"] = (
                "1" if request.support_placement == "build_plate_only" else "0"
            )
        if request.support_threshold_angle is not None:
            out["support_material_threshold"] = str(int(request.support_threshold_angle))

    if request.adhesion:
        out.update(ADHESION_PRUSA.get(request.adhesion, {}))
    if request.brim_width is not None:
        out["brim_width"] = _num(request.brim_width)

    for key, value in request.speed_profile_overrides.items():
        mapped = SPEED_KEY_MAP_PRUSA.get(key, key)
        out[mapped] = _num(float(value))

    # Raw overrides always win.
    out.update({str(k): str(v) for k, v in request.custom_overrides.items()})
    return out


def build_orca_overrides(request: SliceRequest) -> Dict[str, Any]:
    out: Dict[str, Any] = {}
    for field_name, key in ORCA_KEY_MAP.items():
        value = getattr(request, field_name, None)
        if value is None:
            continue
        out[key] = value

    if request.infill_percent is not None:
        out["sparse_infill_density"] = f"{int(request.infill_percent)}%"

    out["enable_support"] = request.supports
    if request.supports:
        if request.support_style:
            out["support_style"] = SUPPORT_STYLE_ORCA.get(
                request.support_style, request.support_style
            )
        if request.support_placement:
            out["support_on_build_plate_only"] = (
                request.support_placement == "build_plate_only"
            )
        if request.support_threshold_angle is not None:
            out["support_threshold_angle"] = int(request.support_threshold_angle)

    if request.adhesion:
        out.update(ADHESION_ORCA.get(request.adhesion, {}))
    if request.brim_width is not None:
        out["brim_width"] = request.brim_width

    for key, value in request.speed_profile_overrides.items():
        out[SPEED_KEY_MAP_ORCA.get(key, key)] = value

    out.update(dict(request.custom_overrides))
    return out


def write_override_ini(path: Path, overrides: Dict[str, str]) -> Path:
    lines = ["# generated by neptune-remote, do not edit"]
    for key in sorted(overrides):
        lines.append(f"{key} = {overrides[key]}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return path


def bed_center(printer: Profile) -> Optional[str]:
    """Derive ``--center X,Y`` from the profile's ``bed_shape``."""
    shape = printer.values.get("bed_shape") or ""
    points: List[tuple[float, float]] = []
    for token in shape.split(","):
        token = token.strip()
        if "x" not in token:
            continue
        left, _, right = token.partition("x")
        try:
            points.append((float(left), float(right)))
        except ValueError:
            continue
    if len(points) < 2:
        return None
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    return f"{(min(xs) + max(xs)) / 2:g},{(min(ys) + max(ys)) / 2:g}"


# --------------------------------------------------------------------------- #
# Engines
# --------------------------------------------------------------------------- #


class BaseEngine:
    name = "base"

    def __init__(self, binary: str, store: ProfileStore, timeout: int = 1800) -> None:
        self.binary = binary
        self.store = store
        self.timeout = timeout
        self._verified: Optional[bool] = None
        self._verify_error: str = ""

    def resolve_binary(self) -> Optional[str]:
        direct = Path(self.binary)
        if direct.is_file():
            return str(direct)
        return shutil.which(self.binary)

    def subprocess_env(self) -> Dict[str, str]:
        """Environment for every slicer invocation.

        ``LC_ALL``/``LANG`` are pinned to ``C`` on purpose. PrusaSlicer calls
        ``setlocale`` at startup and aborts with

            locale::facet::_S_create_c_locale name not valid

        when the inherited locale has not been generated on the host - which is
        the default state of a fresh Raspberry Pi OS image, and also what
        happens when an SSH client forwards a locale the Pi does not have. The
        C locale always exists, so pinning it makes slicing independent of how
        the host and the calling shell happen to be configured.
        """
        return {
            "QT_QPA_PLATFORM": "offscreen",
            "PATH": _path_env(),
            "HOME": str(Path.home()),
            "LC_ALL": "C",
            "LANG": "C",
        }

    @property
    def available(self) -> bool:
        """Whether a slicer binary exists on disk.

        Existing is not the same as working - see :meth:`verify`.
        """
        return self.resolve_binary() is not None

    async def verify(self, force: bool = False) -> bool:
        """Whether the slicer actually runs.

        A binary that is present but crashes on startup used to be reported as
        available, so the app offered slicing and the job failed later with a
        confusing error. This runs it once and caches the answer.
        """
        if self._verified is not None and not force:
            return self._verified

        binary = self.resolve_binary()
        if binary is None:
            self._verified = False
            self._verify_error = f"{self.binary} was not found on PATH"
            return False

        try:
            process = await asyncio.create_subprocess_exec(
                binary,
                "--help",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
                env=self.subprocess_env(),
            )
            data, _ = await asyncio.wait_for(process.communicate(), timeout=30)
        except (OSError, asyncio.TimeoutError) as exc:
            self._verified = False
            self._verify_error = f"{binary} could not be started: {exc}"
            return False

        output = data.decode("utf-8", errors="replace")
        if process.returncode not in (0, 1):
            # Report the slicer's own words - they name the actual problem, a
            # missing locale being the usual one.
            self._verified = False
            self._verify_error = output.strip().splitlines()[-1] if output.strip() else (
                f"{binary} exited with status {process.returncode}"
            )
            return False

        self._verified = True
        self._verify_error = ""
        return True

    @property
    def verify_error(self) -> str:
        return self._verify_error

    async def version(self) -> str:
        binary = self.resolve_binary()
        if binary is None:
            return ""
        try:
            process = await asyncio.create_subprocess_exec(
                binary,
                "--help",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
                env=self.subprocess_env(),
            )
            data, _ = await asyncio.wait_for(process.communicate(), timeout=30)
        except (OSError, asyncio.TimeoutError):
            return ""
        text = data.decode("utf-8", errors="replace")
        match = re.search(r"(PrusaSlicer|OrcaSlicer|SuperSlicer)[- ]?([\d.]+\S*)", text)
        return match.group(0) if match else text.splitlines()[0] if text else ""

    async def _run(
        self,
        command: List[str],
        stages: List[tuple[re.Pattern[str], float, str]],
        progress: Optional[ProgressCallback],
        workdir: Path,
    ) -> List[str]:
        binary = self.resolve_binary()
        if binary is None:
            raise SlicerError(
                f"Slicer binary '{self.binary}' was not found on this Raspberry Pi. "
                "Run raspberry-pi/install.sh or set slicer.prusaslicer_bin in config.yaml."
            )
        command = [binary] + command[1:]
        log.info("Running slicer: %s", " ".join(command))

        try:
            process = await asyncio.create_subprocess_exec(
                *command,
                cwd=str(workdir),
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
                env=self.subprocess_env(),
            )
        except OSError as exc:
            raise SlicerError(f"Failed to launch slicer: {exc}") from exc

        logs: List[str] = []
        highest = 0.0

        async def pump() -> None:
            nonlocal highest
            assert process.stdout is not None
            while True:
                raw = await process.stdout.readline()
                if not raw:
                    break
                line = raw.decode("utf-8", errors="replace").rstrip()
                if not line:
                    continue
                logs.append(line)
                if len(logs) > 4000:
                    del logs[: len(logs) - 4000]
                if progress is None:
                    continue
                for pattern, value, stage in stages:
                    if pattern.search(line) and value > highest:
                        highest = value
                        await progress(value, stage, line)
                        break
                else:
                    await progress(highest, "", line)

        try:
            await asyncio.wait_for(pump(), timeout=self.timeout)
            returncode = await asyncio.wait_for(process.wait(), timeout=60)
        except asyncio.TimeoutError:
            process.kill()
            raise SlicerError(f"Slicing timed out after {self.timeout}s", logs)

        if returncode != 0:
            tail = "\n".join(logs[-15:]) or "no output"
            raise SlicerError(f"Slicer exited with code {returncode}:\n{tail}", logs)

        return logs


def _path_env() -> str:
    import os

    return os.environ.get("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")


class PrusaSlicerEngine(BaseEngine):
    name = "prusaslicer"

    async def slice(
        self,
        model_path: Path,
        output_path: Path,
        request: SliceRequest,
        workdir: Path,
        progress: Optional[ProgressCallback] = None,
    ) -> SliceOutcome:
        printer = self.store.require("printer", request.printer_profile)
        filament = self.store.require("filament", request.filament_profile)
        print_profile = self.store.require("print", request.print_profile)

        overrides = build_prusa_overrides(request)
        override_path = write_override_ini(workdir / "overrides.ini", overrides)

        command = [
            self.binary,
            "--export-gcode",
            "--load",
            str(printer.path),
            "--load",
            str(filament.path),
            "--load",
            str(print_profile.path),
            "--load",
            str(override_path),
        ]

        center = bed_center(printer)
        if center:
            command += ["--center", center]

        command += ["--output", str(output_path), str(model_path)]

        logs = await self._run(command, PRUSA_STAGES, progress, workdir)

        if not output_path.is_file():
            raise SlicerError(
                "The slicer finished but produced no G-code. "
                "The model may be outside the build volume or not manifold.",
                logs,
            )

        stats = stats_from_gcode(output_path)
        return SliceOutcome(
            output_path=output_path, stats=stats, logs=logs, engine=self.name, command=command
        )


class OrcaSlicerEngine(BaseEngine):
    name = "orcaslicer"

    def _merged_json(self, base: Optional[Profile], overrides: Dict[str, Any], target: Path) -> Path:
        data: Dict[str, Any] = {}
        if base is not None:
            try:
                data = json.loads(base.path.read_text(encoding="utf-8"))
            except (OSError, ValueError) as exc:
                raise SlicerError(f"Could not read Orca profile {base.path}: {exc}") from exc
        data.update(overrides)
        target.write_text(json.dumps(data, indent=2), encoding="utf-8")
        return target

    async def slice(
        self,
        model_path: Path,
        output_path: Path,
        request: SliceRequest,
        workdir: Path,
        progress: Optional[ProgressCallback] = None,
    ) -> SliceOutcome:
        machine = self.store.orca_profile("printer", request.printer_profile)
        process = self.store.orca_profile("print", request.print_profile)
        filament = self.store.orca_profile("filament", request.filament_profile)

        missing = [
            name
            for name, profile in (
                ("printer", machine),
                ("print", process),
                ("filament", filament),
            )
            if profile is None
        ]
        if missing:
            raise SlicerError(
                "OrcaSlicer needs JSON profiles in profiles/orca/<kind>/. Missing: "
                + ", ".join(missing)
                + ". Use the prusaslicer engine, or export the profiles from OrcaSlicer desktop."
            )

        overrides = build_orca_overrides(request)
        assert machine is not None and process is not None and filament is not None

        machine_path = self._merged_json(machine, {}, workdir / "machine.json")
        process_path = self._merged_json(process, overrides, workdir / "process.json")
        filament_path = self._merged_json(filament, {}, workdir / "filament.json")

        outdir = workdir / "out"
        outdir.mkdir(parents=True, exist_ok=True)

        command = [
            self.binary,
            "--load-settings",
            f"{machine_path};{process_path}",
            "--load-filaments",
            str(filament_path),
            "--slice",
            "0",
            "--outputdir",
            str(outdir),
            str(model_path),
        ]

        logs = await self._run(command, ORCA_STAGES, progress, workdir)

        produced = sorted(
            list(outdir.glob("*.gcode")) + list(outdir.glob("*.gcode.3mf")),
            key=lambda p: p.stat().st_mtime,
        )
        if not produced:
            raise SlicerError("OrcaSlicer produced no G-code in the output directory", logs)

        output_path.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(produced[-1]), str(output_path))

        stats = stats_from_gcode(output_path)
        return SliceOutcome(
            output_path=output_path, stats=stats, logs=logs, engine=self.name, command=command
        )


def stats_from_gcode(path: Path) -> SliceStats:
    meta = parse_gcode(path)
    filament_mm = meta.get("filament_mm")
    return SliceStats(
        estimated_time_seconds=_as_float(meta.get("estimated_time")),
        filament_grams=_as_float(meta.get("filament_grams")),
        filament_meters=(float(filament_mm) / 1000.0) if isinstance(filament_mm, (int, float)) else None,
        filament_cm3=_as_float(meta.get("filament_cm3")),
        layer_count=int(meta["layer_count"]) if isinstance(meta.get("layer_count"), (int, float)) else None,
        layer_height=_as_float(meta.get("layer_height")),
        object_height=_as_float(meta.get("object_height")),
        gcode_size=int(meta["gcode_size"]) if isinstance(meta.get("gcode_size"), (int, float)) else None,
    )


def _as_float(value: Any) -> Optional[float]:
    if isinstance(value, (int, float)):
        return float(value)
    return None


def build_engine(
    engine_name: str,
    store: ProfileStore,
    *,
    prusaslicer_bin: str,
    orcaslicer_bin: str,
    timeout: int,
) -> BaseEngine:
    name = (engine_name or "prusaslicer").strip().lower()
    if name in {"orca", "orcaslicer", "orca-slicer"}:
        return OrcaSlicerEngine(orcaslicer_bin, store, timeout)
    return PrusaSlicerEngine(prusaslicer_bin, store, timeout)
