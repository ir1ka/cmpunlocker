#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SERVICE_NAME="gen2.service"
SERVICE_SOURCE="${PROJECT_DIR}/systemd/${SERVICE_NAME}"
SERVICE_TARGET="/etc/systemd/system/${SERVICE_NAME}"
HAMMER_SOURCE="${SCRIPT_DIR}/hammer.sh"
HAMMER_TARGET="/usr/local/sbin/gen2-hammer"
LOG_FILE="/var/log/gen2.log"

source "${PROJECT_DIR}/common/lib.sh"

usage() {
    cat <<EOF
Usage:
  sudo $0 install   Install and enable the early-boot Gen2 service
  sudo $0 remove    Disable and remove the service (driver remains installed)
  sudo $0 verify    Verify negotiated link speed and show the boot log
  $0 status         Show whether the service is installed and enabled

install never starts the retrain loop in the current session; it only arms
the service for the next boot.
EOF
}

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "Run this action as root"
}

supported_gpus() {
    for id in 20c2 2082; do
        lspci -D -d "10de:${id}" 2>/dev/null | awk '{print $1}'
    done
}

link_generation() {
    local status
    status="$(setpci -s "$1" CAP_EXP+12.w 2>/dev/null || true)"
    if [[ "${status}" =~ ^[[:xdigit:]]{4}$ ]]; then
        echo $((0x${status} & 0x0f))
    else
        echo "?"
    fi
}

install_service() {
    local meta_dir="/var/cmpunlocker"
    local -a gpus=()

    require_root
    command -v install >/dev/null || die "install command not found"
    command -v lspci >/dev/null || die "lspci not found (install pciutils)"
    command -v setpci >/dev/null || die "setpci not found (install pciutils)"
    [[ -f "${HAMMER_SOURCE}" ]] || die "Missing ${HAMMER_SOURCE}"
    [[ -f "${SERVICE_SOURCE}" ]] || die "Missing ${SERVICE_SOURCE}"

    mapfile -t gpus < <(supported_gpus)
    [[ ${#gpus[@]} -gt 0 ]] || die "No supported CMP 170HX found (10de:20c2 / 10de:2082)"
    info "Detected: ${gpus[*]}"

    # Read driver version from metadata to locate the DKMS source tree
    local version
    version="$(cat "${meta_dir}/driver_version" 2>/dev/null || true)"
    if [[ -z "${version}" ]]; then
        die "Cannot read driver version from ${meta_dir}/driver_version"
    fi

    # --- Helper: search for 'CMP Gen2:' in various module forms ---
    grep_module() {
        local target="$1"
        local keyword="CMP Gen2:"
        if test -d "${target}"; then
            grep -rFq "${keyword}" "${target}" && return 0
        elif [[ "${target}" == *.xz ]]; then
            command -v xzgrep >/dev/null || die "xz-utils (xzgrep) is required to inspect the compressed module ${target}"
            xzgrep -aFq "${keyword}" "${target}" && return 0
        else
            grep -aFq "${keyword}" "${target}" && return 0
        fi
        return 1
    }

    # 1) DKMS source tree
    local dkms_src="/usr/src/nvidia-${version}"
    if [[ -d "${dkms_src}" ]]; then
        if grep_module "${dkms_src}"; then
            ok "DKMS source (${dkms_src}) contains the Gen2 probe-retrain patch"
        else
            die "DKMS source (${dkms_src}) does not contain the Gen2 probe-retrain patch"
        fi
    else
        warn "DKMS source (${dkms_src}) not found"
    fi

    # 2) DKMS build tree (uncompressed .ko)
    local build_ko
    build_ko="$(find "/var/lib/dkms/nvidia/${version}" \
        \( -name 'nvidia.ko' -o -name 'nvidia.ko.xz' \) 2>/dev/null | head -1 || true)"
    if [[ -n "${build_ko}" ]]; then
        if grep_module "${build_ko}"; then
            ok "DKMS build module (${build_ko}) contains the Gen2 probe-retrain patch"
        else
            die "DKMS build module (${build_ko}) does not contain the Gen2 probe-retrain patch"
        fi
    else
        warn "DKMS build module (nvidia.ko) not found"
    fi

    # 3) DKMS installs modules to updates/dkms/ (possibly xz-compressed)
    local module
    module="$(find "/lib/modules/$(uname -r)/updates/dkms" -maxdepth 1 \
        \( -name 'nvidia.ko' -o -name 'nvidia.ko.xz' \) 2>/dev/null | head -1 || true)"
    if [[ -z "${module}" ]]; then
        die "Patched cmpunlocker module not found in /lib/modules/$(uname -r)/updates/dkms/"
    fi
    if grep_module "${module}"; then
        ok "Installed module (${module}) contains the Gen2 probe-retrain patch"
    else
        die "Installed module (${module}) does not contain the Gen2 probe-retrain patch; refusing to arm a useless retrain service"
    fi

    install -m 0755 "${HAMMER_SOURCE}" "${HAMMER_TARGET}"
    install -m 0644 "${SERVICE_SOURCE}" "${SERVICE_TARGET}"
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}" >/dev/null
    ok "Enabled ${SERVICE_NAME} for the next boot"
    info "The service was not started now; the active desktop PCIe link was not touched."
    info "Recovery boot option: systemd.mask=${SERVICE_NAME}"
}

remove_service() {
    require_root
    systemctl disable --now "${SERVICE_NAME}" 2>/dev/null || true
    rm -f "${SERVICE_TARGET}" "${HAMMER_TARGET}"
    systemctl daemon-reload
    systemctl reset-failed "${SERVICE_NAME}" 2>/dev/null || true
    ok "Removed ${SERVICE_NAME}; cmpunlocker driver and memory unlock were left intact"
    if [[ -f "${LOG_FILE}" ]]; then
        info "Preserved diagnostic log: ${LOG_FILE}"
    fi
}

show_status() {
    if [[ -f "${SERVICE_TARGET}" ]]; then
        ok "Service file installed: ${SERVICE_TARGET}"
    else
        warn "Service file is not installed"
    fi
    systemctl is-enabled "${SERVICE_NAME}" 2>/dev/null || true
    systemctl status "${SERVICE_NAME}" --no-pager 2>/dev/null || true
}

verify_links() {
    local gpu bridge status generation speed width max_speed result
    local failures=0
    local -a gpus=()

    require_root
    mapfile -t gpus < <(supported_gpus)
    [[ ${#gpus[@]} -gt 0 ]] || die "No supported CMP 170HX found"

    printf '%-16s %-16s %-8s %-14s %-8s %s\n'         "GPU" "Upstream" "LnkSta" "Current speed" "Width" "Result"
    for gpu in "${gpus[@]}"; do
        bridge="$(basename "$(dirname "$(readlink -f "/sys/bus/pci/devices/${gpu}")")")"
        status="$(setpci -s "${gpu}" CAP_EXP+12.w 2>/dev/null || echo unreadable)"
        generation="$(link_generation "${gpu}")"
        speed="$(cat "/sys/bus/pci/devices/${gpu}/current_link_speed" 2>/dev/null || echo unknown)"
        width="$(cat "/sys/bus/pci/devices/${gpu}/current_link_width" 2>/dev/null || echo unknown)"
        max_speed="$(cat "/sys/bus/pci/devices/${gpu}/max_link_speed" 2>/dev/null || echo unknown)"
        if [[ "${generation}" =~ ^[0-9]+$ ]] && (( generation >= 2 )); then
            result="GEN2 OK"
        else
            result="GEN1"
            failures=$((failures + 1))
        fi
        printf '%-16s %-16s %-8s %-14s x%-7s %s\n'             "${gpu}" "${bridge}" "0x${status}" "${speed}" "${width}" "${result}"
        info "${gpu}: sysfs max=${max_speed}; negotiated generation is authoritative"
    done

    if command -v nvidia-smi >/dev/null; then
        echo
        nvidia-smi             --query-gpu=pci.bus_id,memory.total,pcie.link.gen.current,pcie.link.gen.max             --format=csv 2>/dev/null || true
    fi

    echo
    if [[ -f "${LOG_FILE}" ]]; then
        info "Last early-retrain log:"
        tail -n 30 "${LOG_FILE}"
    else
        warn "No ${LOG_FILE}; the early service has not run yet"
    fi

    if (( failures > 0 )); then
        die "${failures} GPU(s) are still negotiated at Gen1"
    fi
    ok "All supported GPUs are negotiated at Gen2 or better"
}

case "${1:-}" in
    install) install_service ;;
    remove) remove_service ;;
    verify) verify_links ;;
    status) show_status ;;
    -h|--help|"") usage ;;
    *) usage >&2; exit 1 ;;
esac
