"""Static G-code analysis. The app never rewrites toolpaths - it only inspects."""

from .validator import (  # noqa: F401
    GCodeReport,
    GCodeVerdict,
    analyse_gcode,
    analyse_gcode_file,
)
