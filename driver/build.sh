#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mapfile -t SUPPORTED_VERSIONS < <(grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' "${SCRIPT_DIR}/VERSION")
DEFAULT_VERSION="${SUPPORTED_VERSIONS[0]:-}"
VERSION="${CMPUNLOCKER_DRIVER_VERSION:-${DEFAULT_VERSION}}"
PATCH_DIR="${SCRIPT_DIR}/patches"
KVER="$(uname -r)"
BUILD_ROOT="${CMPUNLOCKER_BUILD_DIR:-${SCRIPT_DIR}/.build}"
WORK_DIR="${BUILD_ROOT}/patch-work"
CMPUNLOCKER_DIR="/var/cmpunlocker"
DKMS_SRC="/usr/src/nvidia-${VERSION}"
SRC_BACKUP="${CMPUNLOCKER_DIR}/nvidia-${VERSION}"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; CYAN=""; NC=""
fi

info() { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()  { echo -e "${RED}[FAIL]${NC}  $*" >&2; exit 1; }

version_supported() {
    local v="$1"
    local s
    for s in "${SUPPORTED_VERSIONS[@]}"; do
        [[ "${v}" == "${s}" ]] && return 0
    done
    return 1
}

[[ "${EUID}" -eq 0 ]] || die "Run as root: sudo ${SCRIPT_DIR}/build.sh"
[[ ${#SUPPORTED_VERSIONS[@]} -gt 0 ]] || die "No supported versions listed in driver/VERSION"
[[ -n "${VERSION}" ]] || die "No driver version set (driver/VERSION empty and CMPUNLOCKER_DRIVER_VERSION unset)"
version_supported "${VERSION}" || die "Unsupported driver version '${VERSION}' (supported: ${SUPPORTED_VERSIONS[*]})"
[[ -d "${PATCH_DIR}" ]] || die "Missing patches directory: ${PATCH_DIR}"
command -v python3 &>/dev/null || die "python3 is required to apply the card memory profile"
python3 -c "import yaml" 2>/dev/null || die "python3 PyYAML is required to read common/constants.yaml (apt install python3-yaml)"
command -v sha256sum &>/dev/null || die "sha256sum is required"
command -v dkms &>/dev/null || die "dkms is required (install the dkms package)"

info "Target driver version: ${VERSION}"

[[ -d "${DKMS_SRC}" ]] || die \
    "DKMS source not found at ${DKMS_SRC}.
     Install nvidia-open-dkms ${VERSION} so the source tree appears there."
ok "DKMS source found: ${DKMS_SRC}"

PATCH_ORDER=(
    sec2-postbl-plm-ss-cfg.patch
    booter-verify.patch
    late-pma.patch
    bar0-pramin-clamp.patch
    ce-scrub-workarounds.patch
    persistent-sw-state.patch
    pcie-gen2.patch
    pcie-gen2-probe-retrain.patch
    name-string.patch
    bar1-resize-unlock.patch
    cmp-sku-mask.patch
)
PATCH_FILES=()
for name in "${PATCH_ORDER[@]}"; do
    p="${PATCH_DIR}/${name}"
    [[ -f "${p}" ]] || die "Missing patch: ${p}"
    PATCH_FILES+=("${p}")
done
PATCH_HASH="$(cat "${PATCH_FILES[@]}" | sha256sum | cut -d' ' -f1)"

PROFILE="${CMPUNLOCKER_CARD_PROFILE:-8gb}"
case "${PROFILE}" in
    8GB) PROFILE="8gb" ;;
    10GB) PROFILE="10gb" ;;
    MIXED) PROFILE="mixed" ;;
esac

CONSTANTS="${SCRIPT_DIR}/../common/constants.yaml"
[[ -r "${CONSTANTS}" ]] || die "Missing ${CONSTANTS}"
CONSTANTS_ENV="$(python3 "${SCRIPT_DIR}/../tools/read-constants.py" "${CONSTANTS}" "${PATCH_DIR}" "${SCRIPT_DIR}/build.sh" "${PROFILE}")" || die "common/constants.yaml rejected (see error above)"
eval "${CONSTANTS_ENV}"

# ============================================================
#  Build stamp  (detect whether re-patching is needed)
# ============================================================

BUILD_STAMP="${PROFILE}:${PATCH_HASH}:$(sha256sum "${SCRIPT_DIR}/build.sh" | cut -d' ' -f1)"
STAMP_FILE="${CMPUNLOCKER_DIR}/.cmpunlocker-stamp-${VERSION}"

mkdir -p "${BUILD_ROOT}"

# ============================================================
#  1) Backup original DKMS source (one-time)
# ============================================================

if [[ ! -d "${SRC_BACKUP}" ]]; then
    info "Backing up original DKMS source to ${SRC_BACKUP} ..."
    mkdir -p "${CMPUNLOCKER_DIR}"
    cp -a "${DKMS_SRC}" "${SRC_BACKUP}"
    ok "Original source backed up"
else
    ok "Original backup already exists: ${SRC_BACKUP}"
fi

# ============================================================
#  2) Patch source (skip if stamp matches)
# ============================================================

SKIP_PATCH=0
CURRENT_STAMP="$(cat "${STAMP_FILE}" 2>/dev/null || true)"
if [[ "${CURRENT_STAMP}" == "${BUILD_STAMP}" ]] && grep -rqF 'CMP Gen2:' "${DKMS_SRC}" 2>/dev/null; then
    SKIP_PATCH=1
    ok "Build stamp matches -- source is already patched for this configuration"
elif [[ "${CURRENT_STAMP}" == "${BUILD_STAMP}" ]]; then
    info "Build stamp matches but the live DKMS tree lacks the patch (source was reset) -- re-patching"
fi

if [[ "${SKIP_PATCH}" -eq 0 ]]; then
    # Copy original source into isolated work directory
    info "Preparing work directory ..."
    rm -rf "${WORK_DIR}"
    mkdir -p "${WORK_DIR}"
    cp -a "${SRC_BACKUP}/." "${WORK_DIR}/"
    ok "Original source copied to work directory"

    # Apply unlock patches
    info "Applying unlock patches ..."
    pushd "${WORK_DIR}"
    for i in "${!PATCH_ORDER[@]}"; do
        info "  ${PATCH_ORDER[$i]}"
        patch -p1 < "${PATCH_FILES[$i]}"
    done
    ok "All patches applied"

    # Locate kernel_gsp.c (search to tolerate tree-layout differences)
    GSP_C="$(find . -name kernel_gsp.c -path '*/gsp/*' | head -1)"
    [[ -n "${GSP_C}" ]] || die "kernel_gsp.c not found in patched source tree"

    # Apply memory profile geometry
    info "Applying memory profile ${PROFILE} (${UNLOCK_LABEL} geometry) ..."
    if [[ "${SKIP_GEOMETRY_REWRITE}" -eq 1 ]]; then
        info "mixed profile: runtime device-id geometry (no build-time CFG1/LMR rewrite)"
    else
        python3 - "${GSP_C}" "${CFG1}" "${LMR}" "${FB_BYTES}" "${UNLOCK_LABEL}" <<'PY'
import pathlib, re, sys
path, cfg1, lmr, fb, label = sys.argv[1:6]
text = pathlib.Path(path).read_text()
if (
    "SEC2_POSTBL_TIMING_CMP_170HX_8GB_PCI_DEVICE_ID" in text
    and "SEC2_POSTBL_TIMING_CMP_170HX_10GB_PCI_DEVICE_ID" in text
    and "0x02779000U" in text
    and "0x02669000U" in text
    and "0x0000001000000000ULL" in text
    and "0x0000000A00000000ULL" in text
):
    print(f"runtime device-id geometry (profile metadata={label})")
    raise SystemExit(0)

text2, n1 = re.subn(
    r"(NvU32 cfg1Value = )0x[0-9A-Fa-f]+(U;)",
    rf"\g<1>{cfg1}\g<2>",
    text,
    count=1,
)
text2, n2 = re.subn(
    r"(NvU32 lmrValue\s*=\s*)0x[0-9A-Fa-f]+(U;)",
    rf"\g<1>{lmr}\g<2>",
    text2,
    count=1,
)
text2, n3 = re.subn(
    r"(NvU64 targetFbBytes = )0x[0-9A-Fa-f]+ULL;\s*/\*[^*]*\*/",
    rf"\g<1>{fb}ULL;  /* {label} */",
    text2,
    count=1,
)
if n1 != 1 or n2 != 1 or n3 != 1:
    raise SystemExit(
        f"geometry rewrite failed (cfg1={n1} lmr={n2} fb={n3}); check kernel_gsp.c markers"
    )
pathlib.Path(path).write_text(text2)
print(f"cfg1={cfg1} lmr={lmr} fb={fb} ({label})")
PY
    fi
    ok "Memory profile ${PROFILE}: unlock_geometry=${UNLOCK_LABEL}"
    popd

    # Copy patched source back to the live DKMS directory
    info "Copying patched source back to ${DKMS_SRC} ..."
    cp -a "${WORK_DIR}/." "${DKMS_SRC}/"
    find "${DKMS_SRC}" -name "*.sh" -exec chmod +x {} + 2>/dev/null || true
    ok "Patched source installed"

    # Verify critical patch landed in the live DKMS tree
    if ! grep -rqF 'CMP Gen2:' "${DKMS_SRC}" 2>/dev/null; then
        die "Verification failed: patched DKMS source at ${DKMS_SRC} does not contain the Gen2 probe-retrain strings. cp may have been blocked (e.g. immutable attribute or overlay fs). Run: sudo chattr -R -i ${DKMS_SRC} and retry."
    fi
    ok "Patched DKMS source verified"

    # Clean up work directory
    rm -rf "${WORK_DIR}"

    # Save stamp so future runs can skip re-patching
    printf '%s\n' "${BUILD_STAMP}" > "${STAMP_FILE}"
    ok "Build stamp saved"
fi

# ============================================================
#  3) DKMS build + install
# ============================================================

info "Building via DKMS for kernel ${KVER} ..."
dkms build -m nvidia -v "${VERSION}"
ok "DKMS build complete"

info "Installing via DKMS ..."
dkms install -m nvidia -v "${VERSION}"
ok "DKMS install complete"

# ============================================================
#  4) Write metadata (for verify.sh / remove.sh)
# ============================================================

mkdir -p "${CMPUNLOCKER_DIR}"
printf '%s\n' "${VERSION}" > "${CMPUNLOCKER_DIR}/driver_version"
printf '%s\n' "${PROFILE}" > "${CMPUNLOCKER_DIR}/card_profile"
printf '%s\n' "${UNLOCK_LABEL}" > "${CMPUNLOCKER_DIR}/unlock_geometry"
if [[ -n "${CMPUNLOCKER_GPU_INVENTORY:-}" ]]; then
    printf '%s\n' "${CMPUNLOCKER_GPU_INVENTORY}" > "${CMPUNLOCKER_DIR}/gpu_inventory"
    ok "Wrote gpu_inventory ($(echo "${CMPUNLOCKER_GPU_INVENTORY}" | grep -c . || true) GPU(s))"
else
    : > "${CMPUNLOCKER_DIR}/gpu_inventory"
fi

# ============================================================
#  5) depmod
# ============================================================

depmod -a "${KVER}"
ok "depmod complete"

# ============================================================
#  6) Rebuild initramfs
# ============================================================

rebuild_initramfs() {
    if command -v update-initramfs &>/dev/null; then
        info "Rebuilding initramfs (update-initramfs)..."
        update-initramfs -u -k "${KVER}"
        ok "initramfs rebuilt"
        return 0
    fi
    if command -v dracut &>/dev/null; then
        info "Rebuilding initramfs (dracut)..."
        dracut --force --kver "${KVER}"
        ok "initramfs rebuilt"
        return 0
    fi
    if command -v mkinitcpio &>/dev/null; then
        info "Rebuilding initramfs (mkinitcpio)..."
        mkinitcpio -P
        ok "initramfs rebuilt"
        return 0
    fi
    warn "No initramfs tool found — rebuild manually before rebooting"
    return 1
}

rebuild_initramfs || true

# ============================================================
#  7) Hot-reload modules (best-effort)
# ============================================================

resolved="$(modprobe -n -v nvidia 2>/dev/null | awk '/insmod/ {print $2; exit}' || true)"
if [[ -n "${resolved}" ]]; then
    info "modprobe will load: ${resolved}"
fi
info "Attempting to unload NVIDIA modules..."
systemctl stop nvidia-persistenced 2>/dev/null || true
systemctl stop nvidia-fabricmanager 2>/dev/null || true
reload_ok=0
if grep -q '^nvidia' /proc/modules; then
    for mod in nvidia_drm nvidia_uvm nvidia_modeset nvidia; do
        modprobe -r "${mod}" 2>/dev/null || true
    done
    sleep 1
fi

if ! grep -q '^nvidia ' /proc/modules; then
    if modprobe nvidia && modprobe nvidia-modeset; then
        modprobe nvidia-uvm 2>/dev/null || true
        modprobe nvidia-drm 2>/dev/null || true
        reload_ok=1
        ok "Patched NVIDIA modules loaded"
        running_src="$(cat /sys/module/nvidia/srcversion 2>/dev/null || true)"
        dkms_dir="/lib/modules/${KVER}/updates/dkms"
        installed_ko="${dkms_dir}/nvidia.ko.xz"
        [[ -f "${installed_ko}" ]] || installed_ko="${dkms_dir}/nvidia.ko"
        patched_src="$(modinfo -F srcversion "${installed_ko}" 2>/dev/null || true)"
        if [[ -n "${running_src}" && -n "${patched_src}" && "${running_src}" != "${patched_src}" ]]; then
            warn "Loaded nvidia srcversion (${running_src}) != patched (${patched_src})"
            reload_ok=0
        fi
    else
        warn "modprobe failed"
    fi
else
    warn "Could not unload nvidia modules"
fi
echo ""
if [[ "${reload_ok}" -eq 1 ]]; then
    ok "Build and install finished. Verify with: nvidia-smi"
    info "If memory shows stock size, do cold reboot."
else
    warn "Modules installed but running driver is still stock."
    info "Perform cold reboot: shutdown -h now"
fi
echo ""
