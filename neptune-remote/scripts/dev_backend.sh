#!/usr/bin/env bash
#
# Run the backend locally (on the Pi or on any machine) without systemd.
#
#   ./scripts/dev_backend.sh            # http://0.0.0.0:8710
#   NEPTUNE_POWER_PROVIDER=demo ./scripts/dev_backend.sh
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND="$(cd "${SCRIPT_DIR}/../raspberry-pi" && pwd)"
VENV="${BACKEND}/.venv"

cd "${BACKEND}"

if [[ ! -x "${VENV}/bin/python" ]]; then
    echo "==> Creating a development virtualenv in ${VENV}"
    python3 -m venv "${VENV}"
    "${VENV}/bin/pip" install --upgrade pip >/dev/null
    "${VENV}/bin/pip" install -r requirements-dev.txt
fi

if [[ ! -f "${BACKEND}/config.yaml" ]]; then
    echo "==> No config.yaml yet; copying the example"
    cp "${BACKEND}/config.example.yaml" "${BACKEND}/config.yaml"
fi

echo "==> Starting uvicorn with autoreload"
exec "${VENV}/bin/python" -m uvicorn app.main:app \
    --host "${NEPTUNE_HOST:-0.0.0.0}" \
    --port "${NEPTUNE_PORT:-8710}" \
    --reload
