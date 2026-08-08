#!/usr/bin/env bash
#
# Neptune 3 Plus Remote - Raspberry Pi backend installer.
#
#   curl / git clone the repo, then:
#       cd neptune-remote/raspberry-pi
#       ./install.sh
#
# The script is idempotent: run it again after a git pull to upgrade.
# It NEVER touches Klipper, Moonraker, Mainsail, nginx or printer.cfg.
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${NEPTUNE_INSTALL_DIR:-/opt/neptune-remote}"
SERVICE_NAME="neptune-remote"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
RUN_USER="${SUDO_USER:-$(id -un)}"
RUN_GROUP="$(id -gn "${RUN_USER}")"
RUN_HOME="$(getent passwd "${RUN_USER}" | cut -d: -f6)"
DATA_DIR="${NEPTUNE_DATA_DIR:-${RUN_HOME}/neptune-remote-data}"
SKIP_SLICER="${SKIP_SLICER:-0}"
SKIP_SERVICE="${SKIP_SERVICE:-0}"

C_OK=$'\033[0;32m'; C_WARN=$'\033[0;33m'; C_ERR=$'\033[0;31m'; C_INFO=$'\033[0;36m'; C_OFF=$'\033[0m'
step()  { printf '%s==>%s %s\n' "${C_INFO}" "${C_OFF}" "$*"; }
ok()    { printf '%s  ok%s %s\n' "${C_OK}"   "${C_OFF}" "$*"; }
warn()  { printf '%s warn%s %s\n' "${C_WARN}" "${C_OFF}" "$*"; }
fail()  { printf '%s fail%s %s\n' "${C_ERR}"  "${C_OFF}" "$*" >&2; exit 1; }

trap 'fail "install.sh aborted on line ${LINENO}"' ERR

as_root() {
    if [[ "$(id -u)" -eq 0 ]]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        fail "This step needs root and sudo is not available: $*"
    fi
}

# --------------------------------------------------------------------------- #
# 1. Detect the platform
# --------------------------------------------------------------------------- #
step "Detecting platform"
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    ok "OS: ${PRETTY_NAME:-unknown}"
else
    warn "/etc/os-release not found - assuming Debian-like"
    ID_LIKE="debian"
fi

case "${ID:-}${ID_LIKE:-}" in
    *debian*|*raspbian*|*ubuntu*) ok "Debian-family package manager detected" ;;
    *) warn "Unrecognised distribution. apt steps may fail; install python3-venv manually if so." ;;
esac

if [[ -r /proc/device-tree/model ]]; then
    ok "Board: $(tr -d '\0' < /proc/device-tree/model)"
fi
ok "Architecture: $(uname -m)"
ok "Service will run as user: ${RUN_USER}"

# --------------------------------------------------------------------------- #
# 2. Warn about (but never touch) the existing printer stack
# --------------------------------------------------------------------------- #
step "Checking the existing printer stack (read only)"
for unit in klipper moonraker nginx; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${unit}\.service"; then
        ok "${unit}.service present - it will NOT be modified"
    fi
done
[[ -f "${RUN_HOME}/printer_data/config/printer.cfg" ]] && ok "printer.cfg found - it will NOT be modified"

# --------------------------------------------------------------------------- #
# 3. System packages
# --------------------------------------------------------------------------- #
step "Installing system packages"
APT_PACKAGES=(python3 python3-venv python3-pip python3-dev build-essential curl ca-certificates)
MISSING=()
for pkg in "${APT_PACKAGES[@]}"; do
    dpkg -s "${pkg}" >/dev/null 2>&1 || MISSING+=("${pkg}")
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
    if command -v apt-get >/dev/null 2>&1; then
        as_root apt-get update -qq
        as_root apt-get install -y "${MISSING[@]}"
        ok "Installed: ${MISSING[*]}"
    else
        warn "apt-get unavailable; please install manually: ${MISSING[*]}"
    fi
else
    ok "All required system packages already installed"
fi

# --------------------------------------------------------------------------- #
# 4. Copy the backend into /opt
# --------------------------------------------------------------------------- #
step "Installing backend into ${INSTALL_DIR}"
as_root mkdir -p "${INSTALL_DIR}"
as_root chown "${RUN_USER}:${RUN_GROUP}" "${INSTALL_DIR}"

copy_tree() {
    local src="$1" dst="$2"
    if command -v rsync >/dev/null 2>&1; then
        as_root rsync -a --delete "${src}/" "${dst}/"
    else
        as_root rm -rf "${dst}"
        as_root mkdir -p "${dst}"
        as_root cp -a "${src}/." "${dst}/"
    fi
}

copy_tree "${SCRIPT_DIR}/app" "${INSTALL_DIR}/app"
copy_tree "${SCRIPT_DIR}/profiles" "${INSTALL_DIR}/profiles"
as_root cp -f "${SCRIPT_DIR}/requirements.txt" "${INSTALL_DIR}/requirements.txt"
as_root cp -f "${SCRIPT_DIR}/config.example.yaml" "${INSTALL_DIR}/config.example.yaml"
as_root cp -f "${SCRIPT_DIR}/.env.example" "${INSTALL_DIR}/.env.example"
as_root chown -R "${RUN_USER}:${RUN_GROUP}" "${INSTALL_DIR}"
ok "Backend files copied"

# Never overwrite an existing configuration.
if [[ -f "${INSTALL_DIR}/config.yaml" ]]; then
    ok "config.yaml already exists - left untouched"
else
    as_root cp "${SCRIPT_DIR}/config.example.yaml" "${INSTALL_DIR}/config.yaml"
    as_root chown "${RUN_USER}:${RUN_GROUP}" "${INSTALL_DIR}/config.yaml"
    as_root chmod 600 "${INSTALL_DIR}/config.yaml"
    ok "Created ${INSTALL_DIR}/config.yaml from the example"
fi

# Point the profiles path at the installed copy without clobbering other edits.
if grep -q '^\s*profiles_dir:' "${INSTALL_DIR}/config.yaml" 2>/dev/null; then
    as_root sed -i "s|^\(\s*\)profiles_dir:.*|\1profiles_dir: \"${INSTALL_DIR}/profiles\"|" "${INSTALL_DIR}/config.yaml"
fi

# --------------------------------------------------------------------------- #
# 5. Data directories
# --------------------------------------------------------------------------- #
step "Creating data directories"
for dir in "${DATA_DIR}" "${DATA_DIR}/models" "${DATA_DIR}/gcode"; do
    as_root mkdir -p "${dir}"
done
as_root chown -R "${RUN_USER}:${RUN_GROUP}" "${DATA_DIR}"
ok "Data directory: ${DATA_DIR}"

# --------------------------------------------------------------------------- #
# 6. Python virtual environment
# --------------------------------------------------------------------------- #
step "Creating the Python virtual environment"
VENV_DIR="${INSTALL_DIR}/venv"
if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
    if [[ "$(id -un)" == "${RUN_USER}" ]]; then
        python3 -m venv "${VENV_DIR}"
    elif command -v sudo >/dev/null 2>&1; then
        sudo -H -u "${RUN_USER}" python3 -m venv "${VENV_DIR}"
    else
        python3 -m venv "${VENV_DIR}"
    fi
    ok "Virtualenv created at ${VENV_DIR}"
else
    ok "Virtualenv already present"
fi
as_root chown -R "${RUN_USER}:${RUN_GROUP}" "${VENV_DIR}"

step "Installing Python dependencies (this can take a few minutes on a Pi)"
"${VENV_DIR}/bin/pip" install --upgrade pip setuptools wheel >/dev/null
"${VENV_DIR}/bin/pip" install -r "${INSTALL_DIR}/requirements.txt"
ok "Python dependencies installed"

# --------------------------------------------------------------------------- #
# 7. Slicer
# --------------------------------------------------------------------------- #
step "Checking for a CLI slicer"
if [[ "${SKIP_SLICER}" == "1" ]]; then
    warn "SKIP_SLICER=1 - skipping slicer installation"
elif command -v prusa-slicer >/dev/null 2>&1; then
    ok "prusa-slicer found: $(command -v prusa-slicer)"
elif command -v PrusaSlicer >/dev/null 2>&1; then
    ok "PrusaSlicer found: $(command -v PrusaSlicer)"
    warn "Set slicer.prusaslicer_bin: \"PrusaSlicer\" in config.yaml"
elif command -v orca-slicer >/dev/null 2>&1; then
    ok "orca-slicer found: $(command -v orca-slicer)"
    warn "Set slicer.engine: \"orcaslicer\" in config.yaml (needs JSON profiles, see docs/SLICER.md)"
else
    warn "No CLI slicer found - attempting to install prusa-slicer from apt"
    if command -v apt-get >/dev/null 2>&1 && as_root apt-get install -y prusa-slicer; then
        ok "prusa-slicer installed from apt: $(command -v prusa-slicer || echo 'not on PATH')"
    else
        warn "Could not install prusa-slicer automatically."
        cat <<'SLICERHELP'

    The backend runs fine without a slicer - only /api/slice is disabled.
    To add slicing later, pick one:

      Debian 12 (bookworm) / Raspberry Pi OS 64-bit:
          sudo apt install prusa-slicer

      Any arm64 Linux, official AppImage:
          wget -O ~/PrusaSlicer.AppImage \
            https://github.com/prusa3d/PrusaSlicer/releases/latest/download/PrusaSlicer-Linux-aarch64.AppImage
          chmod +x ~/PrusaSlicer.AppImage
          # AppImages need FUSE, or extract it once:
          ~/PrusaSlicer.AppImage --appimage-extract
          sudo ln -sf ~/squashfs-root/AppRun /usr/local/bin/prusa-slicer

    Then set slicer.prusaslicer_bin in config.yaml and restart the service.

SLICERHELP
    fi
fi

# --------------------------------------------------------------------------- #
# 8. systemd service
# --------------------------------------------------------------------------- #
if [[ "${SKIP_SERVICE}" == "1" ]]; then
    warn "SKIP_SERVICE=1 - not installing the systemd unit"
else
    step "Installing the systemd service"
    TMP_UNIT="$(mktemp)"
    sed -e "s|__USER__|${RUN_USER}|g" \
        -e "s|__GROUP__|${RUN_GROUP}|g" \
        -e "s|__INSTALL_DIR__|${INSTALL_DIR}|g" \
        -e "s|__DATA_DIR__|${DATA_DIR}|g" \
        "${SCRIPT_DIR}/${SERVICE_NAME}.service" > "${TMP_UNIT}"

    if [[ -f "${SERVICE_FILE}" ]] && cmp -s "${TMP_UNIT}" "${SERVICE_FILE}"; then
        ok "systemd unit already up to date"
    else
        as_root cp "${TMP_UNIT}" "${SERVICE_FILE}"
        as_root systemctl daemon-reload
        ok "Wrote ${SERVICE_FILE}"
    fi
    rm -f "${TMP_UNIT}"

    as_root systemctl enable "${SERVICE_NAME}" >/dev/null
    as_root systemctl restart "${SERVICE_NAME}"
    sleep 2
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        ok "${SERVICE_NAME}.service is running"
    else
        warn "${SERVICE_NAME}.service did not start - check: journalctl -u ${SERVICE_NAME} -n 50"
    fi
fi

# --------------------------------------------------------------------------- #
# 9. Summary
# --------------------------------------------------------------------------- #
PORT="$(grep -E '^\s*port:' "${INSTALL_DIR}/config.yaml" | head -1 | tr -dc '0-9' || true)"
PORT="${PORT:-8710}"
TS_IP="$(command -v tailscale >/dev/null 2>&1 && tailscale ip -4 2>/dev/null | head -1 || true)"

cat <<SUMMARY

$(printf '%s' "${C_OK}")Neptune Remote backend installed.$(printf '%s' "${C_OFF}")

  Install dir : ${INSTALL_DIR}
  Config      : ${INSTALL_DIR}/config.yaml
  Data        : ${DATA_DIR}
  Service     : systemctl status ${SERVICE_NAME}
  Logs        : journalctl -u ${SERVICE_NAME} -f
  Local URL   : http://127.0.0.1:${PORT}/api/health
  Docs (API)  : http://127.0.0.1:${PORT}/docs
$( [[ -n "${TS_IP}" ]] && echo "  Tailscale   : http://${TS_IP}:${PORT}/api/health" )

Next steps:
  1. Edit ${INSTALL_DIR}/config.yaml (power provider, Tuya credentials, API token).
  2. sudo systemctl restart ${SERVICE_NAME}
  3. In the iOS app: Settings -> Raspberry Pi address -> this Pi's Tailscale IP.

SUMMARY
