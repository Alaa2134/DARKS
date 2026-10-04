#!/usr/bin/env bash
#
# Optional: install ONNX Runtime so the local print-failure monitor can use a
# trained model instead of the built-in image heuristic.
#
# Nothing here is required. Without ONNX Runtime the monitor still works - it
# falls back to the heuristic detector and says so in the app. Nothing is ever
# uploaded anywhere: inference runs entirely on this Raspberry Pi.
#
# Usage:
#   ./install_vision.sh                     # install onnxruntime into the venv
#   MODEL_URL=https://... ./install_vision.sh   # also fetch a model you trust
#
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/neptune-remote}"
VENV_PY="${INSTALL_DIR}/venv/bin/python"
DATA_DIR="${DATA_DIR:-${HOME}/printer_data/neptune_remote}"
MODEL_DIR="${DATA_DIR}/models_ai"
SERVICE_NAME="${SERVICE_NAME:-neptune-remote}"

C_OK="$(tput setaf 2 2>/dev/null || true)"
C_WARN="$(tput setaf 3 2>/dev/null || true)"
C_ERR="$(tput setaf 1 2>/dev/null || true)"
C_OFF="$(tput sgr0 2>/dev/null || true)"

ok()   { printf '%s✓%s %s\n' "${C_OK}" "${C_OFF}" "$*"; }
warn() { printf '%s!%s %s\n' "${C_WARN}" "${C_OFF}" "$*"; }
die()  { printf '%s✗%s %s\n' "${C_ERR}" "${C_OFF}" "$*" >&2; exit 1; }

as_root() {
    if [[ "$(id -u)" -eq 0 ]]; then "$@"; else sudo "$@"; fi
}

# --------------------------------------------------------------------------- #
# 1. Locate the backend virtualenv
# --------------------------------------------------------------------------- #
if [[ ! -x "${VENV_PY}" ]]; then
    die "Backend virtualenv not found at ${VENV_PY}.
    Run raspberry-pi/install.sh first, or set INSTALL_DIR=/path/to/neptune-remote."
fi
ok "Using ${VENV_PY}"

if "${VENV_PY}" -c "import onnxruntime" >/dev/null 2>&1; then
    VERSION="$("${VENV_PY}" -c 'import onnxruntime; print(onnxruntime.__version__)')"
    ok "onnxruntime ${VERSION} already installed"
else
    echo "Installing onnxruntime (a few minutes on a Pi)…"
    # onnxruntime publishes aarch64 wheels; on 32-bit or unusual platforms pip
    # will fail rather than silently install something that does not work.
    if as_root "${VENV_PY}" -m pip install --upgrade onnxruntime; then
        ok "onnxruntime installed"
    else
        warn "onnxruntime could not be installed on this platform."
        warn "The monitor will keep using its built-in heuristic - it stays usable."
        warn "Check: $(uname -m) wheels at https://pypi.org/project/onnxruntime/#files"
        exit 1
    fi
fi

# --------------------------------------------------------------------------- #
# 2. Model directory
# --------------------------------------------------------------------------- #
mkdir -p "${MODEL_DIR}"
ok "Model directory: ${MODEL_DIR}"

if [[ -n "${MODEL_URL:-}" ]]; then
    TARGET="${MODEL_DIR}/failure.onnx"
    echo "Downloading model from ${MODEL_URL}…"
    if curl -fL --retry 3 -o "${TARGET}.part" "${MODEL_URL}"; then
        mv "${TARGET}.part" "${TARGET}"
        ok "Saved ${TARGET}"
    else
        rm -f "${TARGET}.part"
        die "Download failed. Nothing was installed."
    fi
else
    cat <<'MODELHELP'

No MODEL_URL given, so no model was downloaded.

  This project does not ship a print-failure model, and does not pretend to:
  a model you have not chosen yourself would be a black box making decisions
  about your printer. Two honest options:

    1. Keep the built-in heuristic (default). It watches edge density, frame
       change and frozen frames. Rough, but entirely explainable, and every
       detection says "[heuristic]" in the app.

    2. Point this script at a spaghetti-detection ONNX model you trust:
         MODEL_URL=https://example.com/failure.onnx ./install_vision.sh

  Expected input: a single RGB image tensor. Expected output: one failure
  probability, or a small set of class scores. The backend reports a clear
  error and falls back to the heuristic if the model's shape does not match.

MODELHELP
fi

# --------------------------------------------------------------------------- #
# 3. Point the config at it
# --------------------------------------------------------------------------- #
cat <<CONFIGHELP

Next, in ${INSTALL_DIR}/config.yaml:

  vision:
    provider: "onnx"                       # or "heuristic" / "disabled"
    model_path: "${MODEL_DIR}/failure.onnx"
    mode: "warn"                           # off | monitor | warn | auto_pause
    interval_seconds: 5                    # never faster than 5 s
    confirmations: 3                       # repeated agreement before acting

Then restart the backend:

  sudo systemctl restart ${SERVICE_NAME}

Reminder: in auto_pause mode the monitor pauses the print. It never switches
mains power, by design - that path does not exist in the code.

CONFIGHELP
