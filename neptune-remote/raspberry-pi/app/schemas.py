"""Pydantic request/response models shared by the REST API and the WebSocket."""

from __future__ import annotations

from typing import Any, Dict, List, Optional

from pydantic import BaseModel, Field, field_validator


# --------------------------------------------------------------------------- #
# Generic
# --------------------------------------------------------------------------- #


class OKResponse(BaseModel):
    ok: bool = True
    message: str = ""


class HealthResponse(BaseModel):
    ok: bool = True
    version: str
    moonraker_reachable: bool
    moonraker_url: str
    power_provider: str
    slicer_engine: str
    slicer_available: bool
    auth_required: bool
    server_time: float


# --------------------------------------------------------------------------- #
# System
# --------------------------------------------------------------------------- #


class TailscaleStatus(BaseModel):
    installed: bool = False
    running: bool = False
    hostname: str = ""
    ips: List[str] = Field(default_factory=list)
    backend_state: str = ""


class SystemResponse(BaseModel):
    hostname: str
    platform: str
    model: str = ""
    cpu_percent: float = 0.0
    cpu_temp_c: Optional[float] = None
    load_average: List[float] = Field(default_factory=list)
    memory_total_mb: float = 0.0
    memory_used_mb: float = 0.0
    memory_percent: float = 0.0
    disk_total_gb: float = 0.0
    disk_used_gb: float = 0.0
    disk_percent: float = 0.0
    uptime_seconds: float = 0.0
    ip_addresses: List[str] = Field(default_factory=list)
    tailscale: TailscaleStatus = Field(default_factory=TailscaleStatus)
    throttled: Optional[str] = None


# --------------------------------------------------------------------------- #
# Printer
# --------------------------------------------------------------------------- #


class TemperatureBlock(BaseModel):
    actual: float = 0.0
    target: float = 0.0
    power: float = 0.0


class NotificationPreferencesRequest(BaseModel):
    """The half of the notification settings the phone may change.

    Every field is optional so the app can send just the toggle the user
    touched; anything omitted keeps its current value.
    """

    enabled: Optional[bool] = None
    events: Optional[List[str]] = None
    min_priority: Optional[str] = None
    quiet_hours_enabled: Optional[bool] = None
    quiet_start_hour: Optional[int] = Field(default=None, ge=0, le=23)
    quiet_end_hour: Optional[int] = Field(default=None, ge=0, le=23)


class FilamentSensorState(BaseModel):
    """One Klipper filament sensor as it is right now."""

    name: str
    # switch | motion - a switch sees absence, a motion sensor also sees a jam.
    kind: str = "switch"
    enabled: bool = True
    filament_detected: bool = True


class PrinterStatusResponse(BaseModel):
    online: bool = False
    klippy_state: str = "unknown"  # ready | startup | shutdown | error | unknown
    klippy_message: str = ""
    state: str = "unknown"  # standby | printing | paused | complete | cancelled | error
    state_message: str = ""
    filename: str = ""
    progress: float = 0.0
    print_duration: float = 0.0
    total_duration: float = 0.0
    estimated_time_left: Optional[float] = None
    filament_used_mm: float = 0.0
    current_layer: Optional[int] = None
    total_layer: Optional[int] = None
    nozzle: TemperatureBlock = Field(default_factory=TemperatureBlock)
    bed: TemperatureBlock = Field(default_factory=TemperatureBlock)
    position: List[float] = Field(default_factory=lambda: [0.0, 0.0, 0.0])
    gcode_position: List[float] = Field(default_factory=lambda: [0.0, 0.0, 0.0])
    homed_axes: str = ""
    speed: float = 0.0
    speed_factor: float = 1.0
    extrude_factor: float = 1.0
    fan_speed: float = 0.0
    filament_sensors: Dict[str, FilamentSensorState] = Field(default_factory=dict)
    #: Whatever M117 last put on the printer's display.
    #:
    #: Carried because it is the only channel a running G-code file has for
    #: saying something to a human, and the colour-change stops use it: the
    #: message names the colour the printer is waiting for.
    display_message: str = ""
    #: How `estimated_time_left` was arrived at - the method, the confidence,
    #: and the calibration factor learned from this printer's own history.
    #: Reported so the UI can say where the number came from instead of
    #: presenting every guess with the same authority.
    estimate: Optional[Dict[str, Any]] = None
    thumbnail_path: Optional[str] = None
    error: Optional[str] = None
    raw: Dict[str, Any] = Field(default_factory=dict)


class GCodeCommandRequest(BaseModel):
    script: str = Field(min_length=1, max_length=2000)


class PrinterActionRequest(BaseModel):
    # start | pause | resume | cancel | emergency_stop |
    # restart_klipper | restart_firmware | restart_moonraker
    action: str
    filename: Optional[str] = None


# --------------------------------------------------------------------------- #
# Power
# --------------------------------------------------------------------------- #


class PowerStatusResponse(BaseModel):
    provider: str
    state: str = "unknown"  # on | off | unknown | error
    available: bool = False
    device: str = ""
    message: str = ""
    raw: Dict[str, Any] = Field(default_factory=dict)


class PowerSafetyReport(BaseModel):
    safe: bool
    blockers: List[str] = Field(default_factory=list)
    warnings: List[str] = Field(default_factory=list)
    nozzle_temp: float = 0.0
    bed_temp: float = 0.0
    max_nozzle_temp: float = 0.0
    max_bed_temp: float = 0.0
    printing: bool = False


class PowerOffRequest(BaseModel):
    force: bool = False


class PowerActionResponse(BaseModel):
    ok: bool
    state: str
    provider: str
    message: str = ""
    safety: Optional[PowerSafetyReport] = None


# --------------------------------------------------------------------------- #
# Model placement
#
# How a model is turned, sized and stood up before it reaches the slicer.
# Defined before Slicing, which is where it is asked for, and before Library,
# which is where it is remembered.
# --------------------------------------------------------------------------- #


class ModelTransform(BaseModel):
    """Rotation, scale and mirror, relative to the file on disk.

    The file itself is never modified: a transformed copy is written for the
    slicer to read, and this is what says how to write it. Stored beside the
    model, so the model stays turned the way the user left it.
    """

    #: Degrees about X, then Y, then Z. The order is fixed so the same values
    #: always reproduce the same orientation.
    rotation_deg: List[float] = Field(default_factory=lambda: [0.0, 0.0, 0.0])
    #: Per-axis multiplier, so a model can be stretched as well as resized.
    scale: List[float] = Field(default_factory=lambda: [1.0, 1.0, 1.0])
    mirror: List[bool] = Field(default_factory=lambda: [False, False, False])
    #: Sit the result on Z=0. Off only for a caller doing its own placement -
    #: a model left hovering above the plate has its first layer printed in air.
    drop_to_bed: bool = True
    center_on_bed: bool = True

    @field_validator("rotation_deg", "scale")
    @classmethod
    def _three_numbers(cls, value: List[float]) -> List[float]:
        if len(value) != 3:
            raise ValueError("لازم تكون ٣ قيم: X و Y و Z.")
        return [float(item) for item in value]

    @field_validator("mirror")
    @classmethod
    def _three_flags(cls, value: List[bool]) -> List[bool]:
        if len(value) != 3:
            raise ValueError("لازم تكون ٣ قيم: X و Y و Z.")
        return [bool(item) for item in value]


class OrientationReport(BaseModel):
    """What an orientation costs, in the numbers that decide between them."""

    #: Area that would sit flat on the bed, mm².
    base_area: float = 0.0
    #: Area that would need support, mm².
    overhang_area: float = 0.0
    height: float = 0.0
    width: float = 0.0
    depth: float = 0.0
    needs_support: bool = False
    #: True when the result is inside this printer's own build volume.
    fits: bool = True
    #: Plain Arabic, naming each axis that is over. Empty when it fits.
    problems_ar: List[str] = Field(default_factory=list)


class OrientationSuggestion(BaseModel):
    """The way up the app recommends, with the evidence for it."""

    transform: ModelTransform
    suggested: OrientationReport
    #: The same measurements for the model as it stands now, so the app can
    #: show what the change actually buys rather than asking for trust.
    current: OrientationReport


# --------------------------------------------------------------------------- #
# Colour changes
#
# Defined before Files because a G-code file carries its own colour plan, and
# before Slicing because that is where the plan is asked for.
# --------------------------------------------------------------------------- #


class ColorChange(BaseModel):
    """Stop the print at a layer and ask for a different filament colour.

    One nozzle prints as many colours as you are willing to stand next to it
    for: the print pauses, you swap the spool, it carries on. `layer` is the
    first layer printed in the new colour, counting the way the app shows it -
    the first layer of the print is 1.
    """

    #: 2 and up. A change at layer 1 is just the colour you load before you
    #: press print, so there is nothing to stop for - the API says so rather
    #: than silently accepting a stop that does nothing.
    layer: int = Field(ge=2)
    #: Free text, in whatever language the user thinks in. It is repeated back
    #: to them on the phone and on the printer's display when the pause comes.
    color: str = Field(min_length=1, max_length=40)


class AppliedColorChange(BaseModel):
    """A colour change that was really placed, with the height it lands at."""

    layer: int
    color: str
    #: Height above the bed, read from the sliced file rather than multiplied
    #: out from the layer height - first layers are usually a different
    #: thickness, so the arithmetic would be wrong by exactly that much.
    z: Optional[float] = None



# --------------------------------------------------------------------------- #
# Files
# --------------------------------------------------------------------------- #


class ModelFile(BaseModel):
    id: str
    filename: str
    size: int
    modified: float
    extension: str


class GCodeFile(BaseModel):
    path: str
    filename: str
    size: int = 0
    modified: float = 0.0
    estimated_time: Optional[float] = None
    filament_total_mm: Optional[float] = None
    filament_weight_g: Optional[float] = None
    layer_height: Optional[float] = None
    first_layer_height: Optional[float] = None
    object_height: Optional[float] = None
    filament_type: Optional[str] = None
    filament_name: Optional[str] = None
    slicer: Optional[str] = None
    thumbnail_path: Optional[str] = None
    layer_count: Optional[int] = None
    #: Filament swaps this file will stop for, read from its own header. Any
    #: file carries its plan with it, so a G-code sliced last week still shows
    #: what it is going to ask for.
    color_changes: List[AppliedColorChange] = Field(default_factory=list)
    source: str = "moonraker"  # moonraker | backend


class UploadResponse(BaseModel):
    ok: bool = True
    id: str = ""
    filename: str
    size: int
    path: str = ""


# --------------------------------------------------------------------------- #
# Slicing
# --------------------------------------------------------------------------- #


class SliceOverrides(BaseModel):
    """Free-form PrusaSlicer/OrcaSlicer key=value overrides applied last."""

    values: Dict[str, str] = Field(default_factory=dict)


class SliceRequest(BaseModel):
    model_id: str
    #: More models to put on the same plate, sliced into one G-code file.
    #:
    #: One print job instead of four means one heat-up, one purge and one
    #: chance for the first layer to go wrong. It also means one failure takes
    #: everything with it, which is why the app says so rather than treating a
    #: full plate as free.
    extra_model_ids: List[str] = Field(default_factory=list)
    #: Copies of everything on the plate. 1 leaves the arrangement alone.
    copies: int = 1

    #: How each model is turned and sized, keyed by model id.
    #:
    #: A model named here is transformed into a temporary copy before slicing;
    #: one that is not falls back to whatever transform is stored against it in
    #: the library, and then to none. The original file is never modified.
    transforms: Dict[str, ModelTransform] = Field(default_factory=dict)
    printer_profile: str = "neptune3plus_0.4"
    filament_profile: str = "pla"
    print_profile: str = "standard"

    #: A print mode - draft | fast | balanced | quality | strong | miniature.
    #:
    #: Naming one fills in the layer height, perimeters, infill, speeds and
    #: acceleration, resolved against this nozzle, this material's melt rate
    #: and the machine's own limits. Any field the caller also sets explicitly
    #: wins, so a mode is a starting point rather than a cage.
    mode: Optional[str] = None

    layer_height: Optional[float] = None
    first_layer_height: Optional[float] = None
    nozzle_diameter: Optional[float] = None
    infill_percent: Optional[int] = None
    infill_pattern: Optional[str] = None
    perimeters: Optional[int] = None
    supports: bool = False
    support_style: Optional[str] = None  # grid | snug | organic
    #: Where support may grow from: everywhere, or only up from the bed.
    #:
    #: "grid/snug/organic" is the *shape* of the support, which is what the
    #: app used to offer on its own - and it is the less consequential of the
    #: two choices. Support that starts on the model itself marks the surface
    #: it sits on, so a part with an overhang above another feature comes out
    #: differently depending on this, whatever the style.
    support_placement: Optional[str] = None  # everywhere | build_plate_only
    #: Overhang steeper than this gets support, in degrees from vertical.
    #: None leaves the engine's own automatic threshold alone.
    support_threshold_angle: Optional[int] = None
    adhesion: Optional[str] = None  # none | skirt | brim | raft
    brim_width: Optional[float] = None

    nozzle_temperature: Optional[int] = None
    first_layer_nozzle_temperature: Optional[int] = None
    bed_temperature: Optional[int] = None
    first_layer_bed_temperature: Optional[int] = None

    retraction_length: Optional[float] = None
    retraction_speed: Optional[float] = None
    #: Z lift on retraction. Stops the nozzle dragging over what it just
    #: printed; costs a little time per travel move.
    retraction_z_hop: Optional[float] = None

    # --- Shell -----------------------------------------------------------
    top_solid_layers: Optional[int] = None
    bottom_solid_layers: Optional[int] = None
    #: Smooths top surfaces by running the nozzle over them again.
    ironing: Optional[bool] = None
    #: aligned | nearest | rear | random - where the layer's start point goes.
    seam_position: Optional[str] = None
    #: Single-wall vase mode. Nothing else survives it: no infill, no top
    #: layers, one perimeter, and the model has to be built for it.
    spiral_vase: Optional[bool] = None

    # --- Support detail --------------------------------------------------
    #: Gap between support and the part, in mm. Larger releases more easily
    #: and leaves a rougher surface.
    support_z_distance: Optional[float] = None
    support_interface_layers: Optional[int] = None

    # --- Cooling ---------------------------------------------------------
    fan_min_percent: Optional[int] = None
    fan_max_percent: Optional[int] = None
    #: Layers printed with the fan off so the first layers stay stuck down.
    disable_fan_first_layers: Optional[int] = None

    # --- Travel ----------------------------------------------------------
    #: Route travel moves around walls instead of across them. Slower, and it
    #: keeps stringing off visible surfaces.
    avoid_crossing_perimeters: Optional[bool] = None

    speed_profile_overrides: Dict[str, float] = Field(default_factory=dict)
    custom_overrides: Dict[str, str] = Field(default_factory=dict)

    # --- Colour ----------------------------------------------------------
    #: Layers at which the print stops for a filament swap.
    #:
    #: Applied to the sliced G-code afterwards, because no slicer's command
    #: line can place them. Requires a COLOR_CHANGE macro on the printer, which
    #: the API checks for before accepting the job - a call to a macro that
    #: does not exist ends the print with "Unknown command".
    color_changes: List[ColorChange] = Field(default_factory=list)

    output_name: Optional[str] = None
    upload_to_moonraker: bool = True
    start_print_after_upload: bool = False


class SliceStats(BaseModel):
    estimated_time_seconds: Optional[float] = None
    filament_grams: Optional[float] = None
    filament_meters: Optional[float] = None
    filament_cm3: Optional[float] = None
    layer_count: Optional[int] = None
    layer_height: Optional[float] = None
    object_height: Optional[float] = None
    gcode_size: Optional[int] = None


class SliceJob(BaseModel):
    id: str
    status: str = "queued"  # queued | running | done | failed | cancelled
    progress: float = 0.0
    stage: str = ""
    model_id: str = ""
    model_filename: str = ""
    output_filename: str = ""
    output_path: str = ""
    moonraker_path: Optional[str] = None
    created_at: float = 0.0
    started_at: Optional[float] = None
    finished_at: Optional[float] = None
    error: Optional[str] = None
    logs: List[str] = Field(default_factory=list)
    stats: SliceStats = Field(default_factory=SliceStats)
    #: Where the stops actually landed, with their real heights. Not a copy of
    #: the request: a layer that turned out not to exist fails the job instead
    #: of appearing here.
    color_changes: List[AppliedColorChange] = Field(default_factory=list)
    request: Optional[SliceRequest] = None
    engine: str = ""


class SliceJobSummary(BaseModel):
    id: str
    status: str
    progress: float
    stage: str
    model_filename: str
    output_filename: str
    created_at: float
    error: Optional[str] = None


# --------------------------------------------------------------------------- #
# Profiles
# --------------------------------------------------------------------------- #


class ProfileInfo(BaseModel):
    id: str
    name: str
    kind: str  # printer | filament | print
    description: str = ""
    values: Dict[str, str] = Field(default_factory=dict)


class ProfileListResponse(BaseModel):
    printers: List[ProfileInfo] = Field(default_factory=list)
    filaments: List[ProfileInfo] = Field(default_factory=list)
    prints: List[ProfileInfo] = Field(default_factory=list)


# --------------------------------------------------------------------------- #
# History
# --------------------------------------------------------------------------- #


class HistoryEntry(BaseModel):
    id: int
    filename: str
    start_time: float
    finish_time: Optional[float] = None
    duration: Optional[float] = None
    result: str = "in_progress"  # in_progress | completed | cancelled | error
    filament_used_mm: Optional[float] = None
    estimated_filament_mm: Optional[float] = None
    #: What the slicer predicted for this file. With `duration` it forms one
    #: calibration sample: how wrong the slicer is on this machine.
    estimated_seconds: Optional[float] = None
    #: Read from the G-code metadata at print start, so results can be
    #: attributed to a material and a profile rather than to a filename.
    filament_type: Optional[str] = None
    print_profile: Optional[str] = None
    layer_height: Optional[float] = None
    nozzle_temp: Optional[float] = None
    bed_temp: Optional[float] = None
    speed_profile: Optional[str] = None
    thumbnail_path: Optional[str] = None
    note: str = ""


class HistoryStats(BaseModel):
    total_prints: int = 0
    successful: int = 0
    failed: int = 0
    cancelled: int = 0
    total_print_seconds: float = 0.0
    total_filament_mm: float = 0.0
    longest_print_seconds: float = 0.0


class HistoryResponse(BaseModel):
    entries: List[HistoryEntry] = Field(default_factory=list)
    stats: HistoryStats = Field(default_factory=HistoryStats)


# --------------------------------------------------------------------------- #
# Events (WebSocket)
# --------------------------------------------------------------------------- #


class SocketEvent(BaseModel):
    type: str  # printer | power | slice | system | notice | hello
    timestamp: float
    payload: Dict[str, Any] = Field(default_factory=dict)


class PrinterEvent(BaseModel):
    """Discrete printer events the app turns into local notifications."""

    id: str
    kind: str  # print_started | print_paused | print_resumed | print_finished |
    # print_failed | klipper_error | disconnected | target_reached
    timestamp: float
    title: str
    message: str = ""
    filename: str = ""
