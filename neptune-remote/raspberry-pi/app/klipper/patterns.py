"""Calibration test prints, generated from the printer's own configuration.

Every calibration this project had was about the *bed* - Z offset, screws, mesh.
None of it touches what the plastic actually looks like, and that is decided by
four numbers almost nobody measures: flow, pressure advance, temperature and
retraction. They go unmeasured because measuring them means finding a test
model, slicing it with exactly the right settings, and not making a mistake.

So the G-code is generated here instead. Every coordinate comes from
``printer.cfg`` - the bed size, the travel limits, the nozzle and filament
diameter - so the pattern fits *this* machine and is centred on *this* bed.
No slicer is involved, which also means no chance of a slicer setting quietly
invalidating the measurement.

The extrusion maths, once, since everything below depends on it:

    a move of length L lays down a rectangle of plastic L x W x H
    (W = extrusion width, H = layer height)

    that volume has to come out of a filament of diameter D:

        E = L * W * H / (pi * (D/2)^2)

Nothing here is written to the printer and nothing is saved to the config. The
generator returns G-code and the measurement instructions that go with it;
applying a result is a separate, explicitly confirmed step.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Dict, List, Optional

from .model import ParsedConfig

# Klipper's defaults when [extruder] leaves them out.
DEFAULT_FILAMENT_DIAMETER = 1.75
DEFAULT_NOZZLE_DIAMETER = 0.4
DEFAULT_MIN_EXTRUDE_TEMP = 170.0

# Extrusion width as a multiple of the nozzle. 1.2 is the usual compromise:
# wide enough to bond, narrow enough to stay dimensionally honest.
WIDTH_RATIO = 1.2
# Layer height as a multiple of the nozzle.
HEIGHT_RATIO = 0.5

EDGE_MARGIN_MM = 10.0


@dataclass
class Geometry:
    """The parts of printer.cfg the patterns actually need."""

    min_x: float
    min_y: float
    max_x: float
    max_y: float
    max_z: float
    nozzle: float
    filament: float
    min_extrude_temp: float
    has_bed: bool
    has_mesh_profile: bool

    @property
    def centre_x(self) -> float:
        return (self.min_x + self.max_x) / 2

    @property
    def centre_y(self) -> float:
        return (self.min_y + self.max_y) / 2

    @property
    def width(self) -> float:
        return WIDTH_RATIO * self.nozzle

    @property
    def layer_height(self) -> float:
        return HEIGHT_RATIO * self.nozzle

    @property
    def filament_area(self) -> float:
        return math.pi * (self.filament / 2) ** 2

    def extrusion_for(self, length_mm: float, *, width: Optional[float] = None,
                      height: Optional[float] = None) -> float:
        """Millimetres of filament to feed for a move of this length."""
        w = width if width is not None else self.width
        h = height if height is not None else self.layer_height
        return length_mm * w * h / self.filament_area

    def fits(self, size_mm: float) -> bool:
        return (
            size_mm + 2 * EDGE_MARGIN_MM <= (self.max_x - self.min_x)
            and size_mm + 2 * EDGE_MARGIN_MM <= (self.max_y - self.min_y)
        )


def read_geometry(config: ParsedConfig) -> Optional[Geometry]:
    """Everything the generator needs, or None if the config cannot supply it.

    Returning None rather than filling in defaults is deliberate: a test print
    positioned by guesswork is a nozzle crash, and this generator only ever
    emits coordinates it can justify.
    """
    x = config.axis_limits("x")
    y = config.axis_limits("y")
    z = config.axis_limits("z")
    extruder = config.section("extruder")

    if not x.is_known or not y.is_known or extruder is None:
        return None

    nozzle = extruder.get_float("nozzle_diameter") or DEFAULT_NOZZLE_DIAMETER
    filament = extruder.get_float("filament_diameter") or DEFAULT_FILAMENT_DIAMETER
    if nozzle <= 0 or filament <= 0:
        return None

    return Geometry(
        # position_min is homing overtravel on most machines, not printable
        # surface - the bed starts at 0 in Klipper's coordinates.
        min_x=max(x.position_min, 0.0),
        min_y=max(y.position_min, 0.0),
        max_x=x.position_max,
        max_y=y.position_max,
        max_z=z.position_max if z.is_known else 100.0,
        nozzle=nozzle,
        filament=filament,
        min_extrude_temp=extruder.get_float("min_extrude_temp") or DEFAULT_MIN_EXTRUDE_TEMP,
        has_bed=config.has("heater_bed"),
        has_mesh_profile=bool(config.saved_mesh_profiles),
    )


@dataclass
class TestPrint:
    """A generated calibration print and what to do with the result."""

    id: str
    title_ar: str
    title_en: str
    gcode: str
    #: What the user measures, and what they do with the number.
    instructions_ar: List[str] = field(default_factory=list)
    #: Values baked into the pattern the result has to be interpreted against.
    parameters: Dict[str, float] = field(default_factory=dict)
    estimated_minutes: float = 0.0
    blockers: List[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not self.blockers

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "title_ar": self.title_ar,
            "title_en": self.title_en,
            "gcode": self.gcode,
            "instructions_ar": self.instructions_ar,
            "parameters": self.parameters,
            "estimated_minutes": round(self.estimated_minutes, 1),
            "blockers": self.blockers,
            "ok": self.ok,
        }


# --------------------------------------------------------------------------- #
# Shared building blocks
# --------------------------------------------------------------------------- #


def _preamble(geometry: Geometry, *, nozzle_temp: float, bed_temp: float) -> List[str]:
    lines = [
        "; Generated by Neptune Remote from your printer.cfg",
        "; Nothing here was copied from another machine.",
        "M104 S{:.0f}".format(max(geometry.min_extrude_temp - 20, 140)),
    ]
    if geometry.has_bed:
        lines += [f"M140 S{bed_temp:.0f}", f"M190 S{bed_temp:.0f}"]
    lines += ["G28"]
    if geometry.has_mesh_profile:
        lines.append("BED_MESH_PROFILE LOAD=default")
    lines += [
        f"M109 S{nozzle_temp:.0f}",
        "G90",
        "M83                              ; relative extrusion",
        "G92 E0",
    ]
    return lines


def _purge_line(geometry: Geometry) -> List[str]:
    start_x = geometry.min_x + EDGE_MARGIN_MM
    start_y = geometry.min_y + EDGE_MARGIN_MM
    end_x = min(start_x + (geometry.max_x - geometry.min_x) * 0.5,
                geometry.max_x - EDGE_MARGIN_MM)
    length = end_x - start_x
    return [
        "; prime",
        f"G1 Z{geometry.layer_height:.3f} F1200",
        f"G1 X{start_x:.2f} Y{start_y:.2f} F5000",
        f"G1 X{end_x:.2f} E{geometry.extrusion_for(length, width=geometry.width * 2):.4f} F1200",
        f"G1 Y{start_y + geometry.width * 2:.2f} F5000",
        f"G1 X{start_x:.2f} E{geometry.extrusion_for(length, width=geometry.width * 2):.4f} F1200",
        "G92 E0",
        "G1 Z1.0 F1200",
    ]


def _epilogue(geometry: Geometry) -> List[str]:
    return [
        "",
        "; done",
        "G91",
        "G1 E-3 F1800",
        "G1 Z10 F3000",
        "G90",
        f"G1 X{geometry.max_x - 5:.1f} Y{geometry.max_y - 5:.1f} F6000",
        "TURN_OFF_HEATERS",
        "M107",
        "M84",
    ]


def _square_layer(
    geometry: Geometry,
    *,
    size: float,
    z: float,
    feedrate: float,
    walls: int = 1,
) -> List[str]:
    """One layer of a hollow square, walking inwards for extra walls."""
    lines = [f"G1 Z{z:.3f} F1200"]
    for wall in range(walls):
        inset = wall * geometry.width
        half = size / 2 - inset
        left = geometry.centre_x - half
        right = geometry.centre_x + half
        bottom = geometry.centre_y - half
        top = geometry.centre_y + half
        side = right - left
        extrusion = geometry.extrusion_for(side)

        lines.append(f"G1 X{left:.3f} Y{bottom:.3f} F6000")
        lines.append(f"G1 X{right:.3f} Y{bottom:.3f} E{extrusion:.4f} F{feedrate:.0f}")
        lines.append(f"G1 X{right:.3f} Y{top:.3f} E{extrusion:.4f} F{feedrate:.0f}")
        lines.append(f"G1 X{left:.3f} Y{top:.3f} E{extrusion:.4f} F{feedrate:.0f}")
        lines.append(f"G1 X{left:.3f} Y{bottom:.3f} E{extrusion:.4f} F{feedrate:.0f}")
    return lines


# --------------------------------------------------------------------------- #
# Flow
# --------------------------------------------------------------------------- #


def flow_cube(
    config: ParsedConfig,
    *,
    size: float = 30.0,
    height: float = 10.0,
    nozzle_temp: float = 205.0,
    bed_temp: float = 60.0,
) -> TestPrint:
    """A single-wall open cube whose wall thickness *is* the measurement.

    One wall, so the printed thickness should equal the extrusion width exactly.
    Anything else is the flow being wrong by that ratio, and calipers read it
    directly - no judgement, no comparing photographs, just a number.
    """
    geometry = read_geometry(config)
    if geometry is None:
        return TestPrint(
            id="flow", title_ar="معايرة التدفق", title_en="Flow calibration", gcode="",
            blockers=["printer.cfg does not define the travel limits or the extruder"],
        )
    if not geometry.fits(size):
        size = max(15.0, min(geometry.max_x - geometry.min_x,
                             geometry.max_y - geometry.min_y) - 2 * EDGE_MARGIN_MM)

    layers = max(4, int(height / geometry.layer_height))
    lines = _preamble(geometry, nozzle_temp=nozzle_temp, bed_temp=bed_temp)
    lines += _purge_line(geometry)
    lines += ["", f"; {size:.0f} mm single-wall cube, {layers} layers"]

    for layer in range(layers):
        z = geometry.layer_height * (layer + 1)
        # The first layer goes down slower, as every first layer should.
        feedrate = 900.0 if layer == 0 else 1800.0
        lines += _square_layer(geometry, size=size, z=z, feedrate=feedrate, walls=1)

    lines += _epilogue(geometry)

    perimeter = 4 * size * layers
    minutes = perimeter / 30.0 / 60.0 + 3

    return TestPrint(
        id="flow",
        title_ar="معايرة التدفق (Flow)",
        title_en="Flow calibration",
        gcode="\n".join(lines) + "\n",
        parameters={
            "expected_wall_mm": round(geometry.width, 4),
            "size_mm": round(size, 1),
            "layer_height_mm": round(geometry.layer_height, 3),
            "nozzle_mm": geometry.nozzle,
        },
        instructions_ar=[
            f"اطبع المكعب ده — جدار واحد بس، المفروض سمكه {geometry.width:.3f} مم بالظبط.",
            "استنى يبرد، وقيس سمك الجدار بالفرجار في ٤ أماكن مختلفة وخد المتوسط.",
            "اكتب الرقم في التطبيق وهو يحسبلك معامل التدفق الجديد.",
            "لو الجدار أتخن من المتوقع يبقى التدفق زيادة، ولو أرفع يبقى ناقص.",
        ],
        estimated_minutes=minutes,
    )


def flow_from_measurement(expected_mm: float, measured_mm: float,
                          current_flow: float = 1.0) -> Optional[float]:
    """The corrected flow multiplier, or None if the measurement is implausible.

    A reading half or double the expected width is not a flow error - it is a
    mismeasurement, the wrong wall, or a different pattern. Refusing it is
    safer than writing a wildly wrong multiplier into the slicer profile.
    """
    if expected_mm <= 0 or measured_mm <= 0:
        return None
    ratio = measured_mm / expected_mm
    if not 0.5 <= ratio <= 2.0:
        return None
    return round(current_flow * (expected_mm / measured_mm), 4)


# --------------------------------------------------------------------------- #
# Pressure advance
# --------------------------------------------------------------------------- #


def pressure_advance_tower(
    config: ParsedConfig,
    *,
    size: float = 40.0,
    start: float = 0.0,
    step: float = 0.005,
    layers: int = 60,
    slow: float = 1200.0,
    fast: float = 6000.0,
    nozzle_temp: float = 205.0,
    bed_temp: float = 60.0,
) -> TestPrint:
    """A tower printed with alternating slow and fast sides.

    Pressure advance shows up at the transition between the two speeds: too
    little and the corners under-extrude, too much and they bulge. Klipper's
    own ``TUNING_TOWER`` steps the value with height, so the height at which
    the corners look cleanest reads straight off the print.
    """
    geometry = read_geometry(config)
    if geometry is None:
        return TestPrint(
            id="pressure_advance", title_ar="معايرة Pressure Advance",
            title_en="Pressure advance", gcode="",
            blockers=["printer.cfg does not define the travel limits or the extruder"],
        )
    if not config.has("extruder"):
        return TestPrint(
            id="pressure_advance", title_ar="معايرة Pressure Advance",
            title_en="Pressure advance", gcode="",
            blockers=["No [extruder] section"],
        )
    if not geometry.fits(size):
        size = max(20.0, min(geometry.max_x - geometry.min_x,
                             geometry.max_y - geometry.min_y) - 2 * EDGE_MARGIN_MM)

    band = geometry.layer_height
    lines = _preamble(geometry, nozzle_temp=nozzle_temp, bed_temp=bed_temp)
    lines += _purge_line(geometry)
    lines += [
        "",
        "; Klipper steps pressure_advance with height for us.",
        f"SET_PRESSURE_ADVANCE ADVANCE={start:.4f}",
        f"TUNING_TOWER COMMAND=SET_PRESSURE_ADVANCE PARAMETER=ADVANCE "
        f"START={start:.4f} FACTOR={step / band:.6f}",
        "",
    ]

    for layer in range(layers):
        z = geometry.layer_height * (layer + 1)
        feedrate = 900.0 if layer == 0 else fast
        # Two of the four sides slow, so every layer has two speed changes -
        # which is the thing pressure advance is being judged on.
        lines.append(f"G1 Z{z:.3f} F1200")
        half = size / 2
        left, right = geometry.centre_x - half, geometry.centre_x + half
        bottom, top = geometry.centre_y - half, geometry.centre_y + half
        extrusion = geometry.extrusion_for(size)

        lines.append(f"G1 X{left:.3f} Y{bottom:.3f} F6000")
        lines.append(f"G1 X{right:.3f} Y{bottom:.3f} E{extrusion:.4f} F{feedrate:.0f}")
        lines.append(f"G1 X{right:.3f} Y{top:.3f} E{extrusion:.4f} F{slow:.0f}")
        lines.append(f"G1 X{left:.3f} Y{top:.3f} E{extrusion:.4f} F{feedrate:.0f}")
        lines.append(f"G1 X{left:.3f} Y{bottom:.3f} E{extrusion:.4f} F{slow:.0f}")

    lines += ["", "SET_PRESSURE_ADVANCE ADVANCE={:.4f}".format(start)]
    lines += _epilogue(geometry)

    return TestPrint(
        id="pressure_advance",
        title_ar="معايرة Pressure Advance",
        title_en="Pressure advance",
        gcode="\n".join(lines) + "\n",
        parameters={
            "start": start,
            "step_per_layer": step,
            "layer_height_mm": round(geometry.layer_height, 3),
            "layers": layers,
            "max_value": round(start + step * layers, 4),
        },
        instructions_ar=[
            "البرج ده كل وجهين منه بيتطبعوا بسرعة مختلفة، والقيمة بتزيد كل طبقة.",
            "بص على الأركان: تحت هتلاقيها ناقصة مادة، وفوق هتلاقيها منتفخة.",
            "دوّر على الارتفاع اللي الأركان فيه أنضف حاجة، وقيس ارتفاعه بالفرجار.",
            f"القيمة = {start:.3f} + (الارتفاع بالمم ÷ {geometry.layer_height:.2f}) × {step:.4f}",
            "التطبيق هيحسبهالك لو كتبت الارتفاع.",
        ],
        estimated_minutes=(4 * size * layers) / 40.0 / 60.0 + 3,
    )


def pressure_advance_from_height(
    height_mm: float, *, start: float, step: float, layer_height: float
) -> Optional[float]:
    """Turn "it looked best at 12 mm" into a pressure advance value."""
    if height_mm < 0 or layer_height <= 0:
        return None
    layers = height_mm / layer_height
    value = start + layers * step
    # Klipper's own documented range for a direct or bowden setup. Outside it
    # the height was misread, not the extruder made exotic.
    if not 0.0 <= value <= 2.0:
        return None
    return round(value, 4)


# --------------------------------------------------------------------------- #
# Temperature
# --------------------------------------------------------------------------- #


def temperature_tower(
    config: ParsedConfig,
    *,
    size: float = 25.0,
    start_temp: float = 220.0,
    step_temp: float = -5.0,
    bands: int = 5,
    band_height: float = 8.0,
    bed_temp: float = 60.0,
) -> TestPrint:
    """A tower whose temperature drops in bands as it goes up."""
    geometry = read_geometry(config)
    if geometry is None:
        return TestPrint(
            id="temperature", title_ar="برج الحرارة", title_en="Temperature tower",
            gcode="", blockers=["printer.cfg does not define the travel limits or the extruder"],
        )

    extruder = config.section("extruder")
    max_temp = (extruder.get_float("max_temp") if extruder else None) or 250.0
    if start_temp > max_temp:
        return TestPrint(
            id="temperature", title_ar="برج الحرارة", title_en="Temperature tower",
            gcode="",
            blockers=[
                f"Start temperature {start_temp:.0f}C is above the configured "
                f"max_temp of {max_temp:.0f}C"
            ],
        )
    if not geometry.fits(size):
        size = max(15.0, min(geometry.max_x - geometry.min_x,
                             geometry.max_y - geometry.min_y) - 2 * EDGE_MARGIN_MM)

    layers_per_band = max(2, int(band_height / geometry.layer_height))
    lines = _preamble(geometry, nozzle_temp=start_temp, bed_temp=bed_temp)
    lines += _purge_line(geometry)

    temperatures = []
    layer = 0
    for band in range(bands):
        temperature = start_temp + step_temp * band
        # Clamped rather than skipped: a band the hotend cannot reach would
        # otherwise stall the whole print waiting for M109.
        temperature = max(geometry.min_extrude_temp + 5, min(temperature, max_temp))
        temperatures.append(temperature)
        lines += ["", f"; band {band + 1}: {temperature:.0f}C",
                  f"M104 S{temperature:.0f}"]
        for _ in range(layers_per_band):
            layer += 1
            z = geometry.layer_height * layer
            feedrate = 900.0 if layer == 1 else 1800.0
            lines += _square_layer(geometry, size=size, z=z, feedrate=feedrate, walls=2)

    lines += _epilogue(geometry)

    return TestPrint(
        id="temperature",
        title_ar="برج الحرارة",
        title_en="Temperature tower",
        gcode="\n".join(lines) + "\n",
        parameters={
            "start_temp": start_temp,
            "step_temp": step_temp,
            "bands": bands,
            "band_height_mm": round(layers_per_band * geometry.layer_height, 2),
            "temperatures": 0,  # kept numeric; the list is in the instructions
        },
        instructions_ar=[
            "كل جزء من البرج اتطبع بحرارة مختلفة، من تحت لفوق: "
            + " ← ".join(f"{t:.0f}°" for t in temperatures),
            "شوف أنهي جزء سطحه أنضف ومفيهوش خيوط، وفي نفس الوقت الطبقات لازقة كويس.",
            "جرّب تكسر البرج بإيدك — الجزء اللي بيقاوم أكتر هو الحرارة الصح.",
            "الحرارة العالية بتلزق أحسن بس بتعمل خيوط؛ الواطية العكس.",
        ],
        estimated_minutes=(4 * size * layers_per_band * bands * 2) / 30.0 / 60.0 + 4,
    )


# --------------------------------------------------------------------------- #
# Retraction
# --------------------------------------------------------------------------- #


def retraction_tower(
    config: ParsedConfig,
    *,
    size: float = 12.0,
    gap: float = 40.0,
    start: float = 0.0,
    step: float = 0.5,
    bands: int = 8,
    band_height: float = 5.0,
    nozzle_temp: float = 205.0,
    bed_temp: float = 60.0,
) -> TestPrint:
    """Two small towers with a travel between them, retraction stepping up.

    The gap between the towers is where stringing shows, so the height at which
    the strings stop is the retraction length.
    """
    geometry = read_geometry(config)
    if geometry is None:
        return TestPrint(
            id="retraction", title_ar="برج الـ Retraction", title_en="Retraction tower",
            gcode="", blockers=["printer.cfg does not define the travel limits or the extruder"],
        )

    span = gap + size
    if not geometry.fits(span):
        gap = max(15.0, min(geometry.max_x - geometry.min_x,
                            geometry.max_y - geometry.min_y) - 2 * EDGE_MARGIN_MM - size)

    layers_per_band = max(2, int(band_height / geometry.layer_height))
    left_centre = geometry.centre_x - gap / 2
    right_centre = geometry.centre_x + gap / 2

    lines = _preamble(geometry, nozzle_temp=nozzle_temp, bed_temp=bed_temp)
    lines += _purge_line(geometry)
    lines += [
        "",
        "; Klipper's firmware retraction, stepped by height.",
        f"SET_RETRACTION RETRACT_LENGTH={start:.2f} RETRACT_SPEED=35",
        f"TUNING_TOWER COMMAND=SET_RETRACTION PARAMETER=RETRACT_LENGTH "
        f"START={start:.2f} FACTOR={step / (layers_per_band * geometry.layer_height):.6f}",
        "",
    ]

    layer = 0
    for _ in range(bands):
        for _ in range(layers_per_band):
            layer += 1
            z = geometry.layer_height * layer
            feedrate = 900.0 if layer == 1 else 1800.0
            for centre in (left_centre, right_centre):
                half = size / 2
                left, right = centre - half, centre + half
                bottom = geometry.centre_y - half
                top = geometry.centre_y + half
                extrusion = geometry.extrusion_for(size)
                lines.append(f"G1 Z{z:.3f} F1200")
                lines.append("G11                              ; unretract")
                lines.append(f"G1 X{left:.3f} Y{bottom:.3f} F6000")
                lines.append(f"G1 X{right:.3f} Y{bottom:.3f} E{extrusion:.4f} F{feedrate:.0f}")
                lines.append(f"G1 X{right:.3f} Y{top:.3f} E{extrusion:.4f} F{feedrate:.0f}")
                lines.append(f"G1 X{left:.3f} Y{top:.3f} E{extrusion:.4f} F{feedrate:.0f}")
                lines.append(f"G1 X{left:.3f} Y{bottom:.3f} E{extrusion:.4f} F{feedrate:.0f}")
                lines.append("G10                              ; retract")

    lines += _epilogue(geometry)

    return TestPrint(
        id="retraction",
        title_ar="برج الـ Retraction",
        title_en="Retraction tower",
        gcode="\n".join(lines) + "\n",
        parameters={
            "start": start,
            "step_mm": step,
            "bands": bands,
            "band_height_mm": round(layers_per_band * geometry.layer_height, 2),
            "max_value": round(start + step * bands, 2),
        },
        instructions_ar=[
            "برجين صغيرين والنوزل بيتنقل بينهم كل طبقة — والخيوط بتبان في الفراغ ده.",
            f"قيمة الـ retraction بتزيد {step:.1f} مم كل {layers_per_band * geometry.layer_height:.1f} مم ارتفاع.",
            "دوّر على أول ارتفاع الخيوط اختفت عنده تقريبًا.",
            "متزوّدش أكتر من كده — الزيادة بتسبب انسداد وطقطقة في الإكستروجن.",
            "⚠️ ده محتاج [firmware_retraction] في printer.cfg.",
        ],
        estimated_minutes=(8 * size * layers_per_band * bands) / 30.0 / 60.0 + 4,
    )


# --------------------------------------------------------------------------- #
# Catalogue
# --------------------------------------------------------------------------- #

BUILDERS = {
    "flow": flow_cube,
    "pressure_advance": pressure_advance_tower,
    "temperature": temperature_tower,
    "retraction": retraction_tower,
}


def available(config: ParsedConfig) -> List[dict]:
    """What this printer can actually run, with the reason when it cannot."""
    results = []
    for name, builder in BUILDERS.items():
        test = builder(config)
        entry = {
            "id": test.id,
            "title_ar": test.title_ar,
            "title_en": test.title_en,
            "ok": test.ok,
            "blockers": list(test.blockers),
            "estimated_minutes": round(test.estimated_minutes, 1),
        }
        # Firmware retraction is a config section, not a capability we can fake.
        if name == "retraction" and not config.has("firmware_retraction"):
            entry["ok"] = False
            entry["blockers"] = entry["blockers"] + [
                "No [firmware_retraction] section in printer.cfg, so the "
                "retraction length cannot be changed mid-print."
            ]
        results.append(entry)
    return results
