"""Local print-failure detection providers.

Everything runs on the Raspberry Pi. No frame ever leaves the machine and no
cloud service is contacted - there is deliberately no network code in here.

Three providers:

* ``OnnxVisionProvider``    - runs a user-supplied ONNX detector via onnxruntime.
                              Neptune Remote does not bundle weights; you point
                              ``vision.model_path`` at a model you trust and the
                              provider reports exactly what that model outputs.
* ``HeuristicVisionProvider`` - OpenCV/numpy image analysis. No model needed. It
                              only reports what it can actually measure, and it
                              labels itself as heuristic so the UI can say so.
* ``DisabledVisionProvider`` - honest "not available" with a reason.

None of them claims an accuracy number, because none has been measured here.
"""

from __future__ import annotations

import abc
import io
import logging
import math
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

log = logging.getLogger("neptune.vision")

try:
    import numpy as np
except ImportError:  # pragma: no cover
    np = None  # type: ignore

try:
    from PIL import Image
except ImportError:  # pragma: no cover
    Image = None  # type: ignore


# Failure classes the architecture supports. A provider only emits the ones it
# can genuinely distinguish.
FAILURE_KINDS = (
    "spaghetti",
    "detached",
    "knocked_over",
    "layer_shift",
    "extrusion_failure",
    "first_layer_failure",
    "unexpected_movement",
    "structure_anomaly",
)


@dataclass
class Detection:
    kind: str
    confidence: float
    detail: str = ""
    heuristic: bool = False
    box: Optional[Tuple[float, float, float, float]] = None  # x, y, w, h normalised

    def as_dict(self) -> Dict[str, Any]:
        return {
            "kind": self.kind,
            "confidence": round(self.confidence, 3),
            "detail": self.detail,
            "heuristic": self.heuristic,
            "box": list(self.box) if self.box else None,
        }


@dataclass
class ProviderInfo:
    name: str
    available: bool
    reason: str = ""
    details: Dict[str, Any] = field(default_factory=dict)


class VisionProvider(abc.ABC):
    name = "base"

    @abc.abstractmethod
    def info(self) -> ProviderInfo:
        ...

    @abc.abstractmethod
    def analyse(self, frame: bytes, *, roi: Optional[Sequence[float]] = None) -> List[Detection]:
        ...

    def reset(self) -> None:
        """Forget any state kept between frames (called when a print starts)."""

    @property
    def available(self) -> bool:
        return self.info().available


# --------------------------------------------------------------------------- #
# Image helpers
# --------------------------------------------------------------------------- #


def decode_frame(frame: bytes, size: Optional[Tuple[int, int]] = None) -> Optional["np.ndarray"]:
    """JPEG bytes -> float32 greyscale array in 0..1."""
    if Image is None or np is None:
        return None
    try:
        with Image.open(io.BytesIO(frame)) as image:
            image = image.convert("L")
            if size is not None:
                image = image.resize(size)
            return np.asarray(image, dtype=np.float32) / 255.0
    except Exception:
        return None


def decode_rgb(frame: bytes, size: Tuple[int, int]) -> Optional["np.ndarray"]:
    if Image is None or np is None:
        return None
    try:
        with Image.open(io.BytesIO(frame)) as image:
            image = image.convert("RGB").resize(size)
            return np.asarray(image, dtype=np.float32) / 255.0
    except Exception:
        return None


def crop_roi(array: "np.ndarray", roi: Optional[Sequence[float]]) -> "np.ndarray":
    """ROI is (x, y, w, h) with values 0..1 relative to the frame."""
    if roi is None or len(roi) != 4 or np is None:
        return array
    height, width = array.shape[:2]
    x = max(0, min(width - 1, int(roi[0] * width)))
    y = max(0, min(height - 1, int(roi[1] * height)))
    w = max(1, min(width - x, int(roi[2] * width)))
    h = max(1, min(height - y, int(roi[3] * height)))
    return array[y:y + h, x:x + w]


def sobel_edges(gray: "np.ndarray") -> "np.ndarray":
    """Edge magnitude without needing OpenCV."""
    if np is None:
        raise RuntimeError("numpy required")
    dx = np.zeros_like(gray)
    dy = np.zeros_like(gray)
    dx[:, 1:-1] = gray[:, 2:] - gray[:, :-2]
    dy[1:-1, :] = gray[2:, :] - gray[:-2, :]
    return np.sqrt(dx * dx + dy * dy)


# --------------------------------------------------------------------------- #
# Disabled
# --------------------------------------------------------------------------- #


class DisabledVisionProvider(VisionProvider):
    name = "disabled"

    def __init__(self, reason: str = "AI detection is switched off") -> None:
        self.reason = reason

    def info(self) -> ProviderInfo:
        return ProviderInfo(name=self.name, available=False, reason=self.reason)

    def analyse(self, frame: bytes, *, roi: Optional[Sequence[float]] = None) -> List[Detection]:
        return []


# --------------------------------------------------------------------------- #
# Heuristic (no model required)
# --------------------------------------------------------------------------- #


class HeuristicVisionProvider(VisionProvider):
    """Statistical image analysis over the print-bed region.

    What it actually measures, frame to frame:

    * edge-density growth - stringy "spaghetti" failures add a lot of high
      frequency detail over the bed compared with a clean print;
    * large sudden change  - the print detaching or being knocked over changes a
      big fraction of the ROI at once;
    * frozen frame         - the camera stopped updating (reported as an
      anomaly, never as a print failure).

    It is honest about being a heuristic: every detection is flagged
    ``heuristic=True`` and the UI labels it "مراقبة بدون نموذج" / "rule based".
    """

    name = "heuristic"
    WORK_SIZE = (320, 240)

    def __init__(
        self,
        *,
        edge_growth_threshold: float = 1.55,
        change_threshold: float = 0.28,
        warmup_frames: int = 4,
    ) -> None:
        self.edge_growth_threshold = edge_growth_threshold
        self.change_threshold = change_threshold
        self.warmup_frames = warmup_frames
        self._baseline_edges: Optional[float] = None
        self._previous: Optional["np.ndarray"] = None
        self._frames = 0
        self._identical_frames = 0

    def info(self) -> ProviderInfo:
        if np is None or Image is None:
            return ProviderInfo(
                name=self.name,
                available=False,
                reason="numpy and Pillow are required for heuristic detection",
            )
        return ProviderInfo(
            name=self.name,
            available=True,
            details={
                "type": "rule-based",
                "model_required": False,
                "measures": ["edge_density", "frame_change", "frozen_frame"],
                "accuracy": "not measured - use as an early warning, not a guarantee",
            },
        )

    def reset(self) -> None:
        self._baseline_edges = None
        self._previous = None
        self._frames = 0
        self._identical_frames = 0

    def analyse(self, frame: bytes, *, roi: Optional[Sequence[float]] = None) -> List[Detection]:
        if np is None or Image is None:
            return []

        gray = decode_frame(frame, self.WORK_SIZE)
        if gray is None:
            return []
        region = crop_roi(gray, roi)
        if region.size == 0:
            return []

        detections: List[Detection] = []
        edges = sobel_edges(region)
        edge_density = float(np.mean(edges > 0.12))

        self._frames += 1

        # ---- frozen camera -------------------------------------------------
        if self._previous is not None and self._previous.shape == region.shape:
            difference = np.abs(region - self._previous)
            changed_fraction = float(np.mean(difference > 0.08))
            mean_change = float(np.mean(difference))

            if mean_change < 0.0015:
                self._identical_frames += 1
                if self._identical_frames >= 3:
                    detections.append(
                        Detection(
                            kind="unexpected_movement",
                            confidence=0.55,
                            detail="camera image has not changed for several samples",
                            heuristic=True,
                        )
                    )
            else:
                self._identical_frames = 0

            # ---- large sudden change --------------------------------------
            if self._frames > self.warmup_frames and changed_fraction > self.change_threshold:
                confidence = min(0.9, 0.45 + changed_fraction)
                detections.append(
                    Detection(
                        kind="structure_anomaly",
                        confidence=confidence,
                        detail=f"{changed_fraction * 100:.0f}% of the print area changed at once",
                        heuristic=True,
                    )
                )

        # ---- edge density growth ------------------------------------------
        if self._baseline_edges is None:
            if self._frames >= self.warmup_frames:
                self._baseline_edges = max(edge_density, 0.005)
        else:
            # Slow adaptation so a normally growing print does not trip it.
            growth = edge_density / max(self._baseline_edges, 0.005)
            if self._frames > self.warmup_frames and growth > self.edge_growth_threshold:
                confidence = min(0.92, 0.4 + (growth - self.edge_growth_threshold) * 0.5)
                detections.append(
                    Detection(
                        kind="spaghetti",
                        confidence=confidence,
                        detail=f"edge detail grew {growth:.2f}x above the print baseline",
                        heuristic=True,
                    )
                )
            self._baseline_edges = self._baseline_edges * 0.97 + edge_density * 0.03

        self._previous = region
        return detections


# --------------------------------------------------------------------------- #
# ONNX Runtime
# --------------------------------------------------------------------------- #


class OnnxVisionProvider(VisionProvider):
    """Runs a user-supplied ONNX classifier/detector.

    The model contract is deliberately simple and documented in docs/AI.md:

        input : float32 NCHW image, 1x3xHxW, values 0..1
        output: either
                (a) 1xN class scores, mapped to ``labels`` from the config, or
                (b) Nx6 detections [x, y, w, h, score, class]

    Whatever the model says is what gets reported. If the file is missing or
    onnxruntime is not installed, the provider is simply unavailable.
    """

    name = "onnx"

    def __init__(
        self,
        model_path: str,
        *,
        labels: Optional[List[str]] = None,
        input_size: int = 320,
        providers: Optional[List[str]] = None,
    ) -> None:
        self.model_path = Path(model_path).expanduser() if model_path else None
        self.labels = labels or list(FAILURE_KINDS)
        self.input_size = input_size
        self.requested_providers = providers or ["CPUExecutionProvider"]
        self._session: Any = None
        self._load_error = ""
        self._input_name = ""

    # ------------------------------------------------------------- loading
    def _ensure_session(self) -> bool:
        if self._session is not None:
            return True
        if self._load_error:
            return False

        try:
            import onnxruntime  # type: ignore
        except ImportError:
            self._load_error = "onnxruntime is not installed (run scripts/install_vision.sh)"
            return False

        if self.model_path is None or not self.model_path.is_file():
            self._load_error = f"model file not found: {self.model_path or '(unset)'}"
            return False

        try:
            available = onnxruntime.get_available_providers()
            chosen = [name for name in self.requested_providers if name in available] or ["CPUExecutionProvider"]
            options = onnxruntime.SessionOptions()
            options.intra_op_num_threads = 2  # leave headroom for Klipper
            options.graph_optimization_level = onnxruntime.GraphOptimizationLevel.ORT_ENABLE_ALL
            self._session = onnxruntime.InferenceSession(
                str(self.model_path), sess_options=options, providers=chosen
            )
            self._input_name = self._session.get_inputs()[0].name
        except Exception as exc:
            self._load_error = f"could not load the ONNX model: {exc}"
            self._session = None
            return False
        return True

    def info(self) -> ProviderInfo:
        if np is None or Image is None:
            return ProviderInfo(name=self.name, available=False, reason="numpy and Pillow are required")
        if not self._ensure_session():
            return ProviderInfo(
                name=self.name,
                available=False,
                reason=self._load_error,
                details={"model_path": str(self.model_path or "")},
            )
        try:
            providers = self._session.get_providers()
        except Exception:
            providers = []
        return ProviderInfo(
            name=self.name,
            available=True,
            details={
                "model_path": str(self.model_path),
                "execution_providers": providers,
                "input_size": self.input_size,
                "labels": self.labels,
                "accuracy": "depends entirely on the model you installed",
            },
        )

    # ------------------------------------------------------------ inference
    def analyse(self, frame: bytes, *, roi: Optional[Sequence[float]] = None) -> List[Detection]:
        if not self._ensure_session() or np is None:
            return []

        rgb = decode_rgb(frame, (self.input_size, self.input_size))
        if rgb is None:
            return []
        if roi is not None:
            rgb = crop_roi(rgb, roi)
            if rgb.size == 0:
                return []
            # Re-decode at the model size after cropping.
            if Image is not None:
                pil = Image.fromarray((rgb * 255).astype("uint8"))
                pil = pil.resize((self.input_size, self.input_size))
                rgb = np.asarray(pil, dtype=np.float32) / 255.0

        tensor = np.transpose(rgb, (2, 0, 1))[None, ...].astype(np.float32)

        try:
            outputs = self._session.run(None, {self._input_name: tensor})
        except Exception as exc:
            log.warning("ONNX inference failed: %s", exc)
            return []

        return self._interpret(outputs)

    def _interpret(self, outputs: List[Any]) -> List[Detection]:
        if not outputs:
            return []
        array = np.asarray(outputs[0])
        detections: List[Detection] = []

        squeezed = array.squeeze()
        if squeezed.ndim == 1:
            # Class scores.
            scores = _softmax(squeezed) if squeezed.max() > 1.0 or squeezed.min() < 0.0 else squeezed
            for index, score in enumerate(scores.tolist()):
                if index >= len(self.labels):
                    break
                label = self.labels[index]
                if label in {"ok", "normal", "background"}:
                    continue
                if score >= 0.35:
                    detections.append(Detection(kind=label, confidence=float(score)))
        elif squeezed.ndim == 2 and squeezed.shape[1] >= 6:
            for row in squeezed.tolist():
                x, y, w, h, score, class_index = row[:6]
                if score < 0.35:
                    continue
                index = int(class_index)
                label = self.labels[index] if 0 <= index < len(self.labels) else "structure_anomaly"
                detections.append(
                    Detection(kind=label, confidence=float(score), box=(x, y, w, h))
                )

        detections.sort(key=lambda item: -item.confidence)
        return detections[:5]


def _softmax(values: "np.ndarray") -> "np.ndarray":
    shifted = values - values.max()
    exponentials = np.exp(shifted)
    total = exponentials.sum()
    return exponentials / total if total else exponentials


# --------------------------------------------------------------------------- #
# Factory
# --------------------------------------------------------------------------- #


def build_provider(config: Any) -> VisionProvider:
    """Create the provider named in ``vision.provider``.

    Falls back to the heuristic provider (with a clear reason) rather than
    silently pretending detection works.
    """
    name = (getattr(config, "provider", "") or "disabled").strip().lower()

    if name in {"off", "none", "disabled", ""}:
        return DisabledVisionProvider("AI detection is switched off in config.yaml")

    if name == "onnx":
        provider = OnnxVisionProvider(
            getattr(config, "model_path", ""),
            labels=list(getattr(config, "labels", []) or []) or None,
            input_size=int(getattr(config, "input_size", 320)),
            providers=list(getattr(config, "execution_providers", []) or []) or None,
        )
        if provider.available:
            return provider
        reason = provider.info().reason
        if getattr(config, "fallback_to_heuristic", True):
            log.warning("ONNX provider unavailable (%s); falling back to the heuristic provider", reason)
            return HeuristicVisionProvider()
        return DisabledVisionProvider(reason)

    if name in {"heuristic", "opencv", "rules"}:
        return HeuristicVisionProvider(
            edge_growth_threshold=float(getattr(config, "edge_growth_threshold", 1.55)),
            change_threshold=float(getattr(config, "change_threshold", 0.28)),
        )

    return DisabledVisionProvider(f"Unknown vision provider: {name}")
