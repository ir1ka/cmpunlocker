#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="cmpunlocker"
CMPUNLOCKER_DIR="/var/cmpunlocker"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
INSTALL_DIR="/opt/cmpunlocker"
PASSTHROUGH_LIB="/usr/local/lib/cmpunlocker"

source "${SCRIPT_DIR}/common/lib.sh"

banner

if [[ "${1:-}" != "--yes" && "${1:-}" != "-y" ]]; then
    warn "This removes cmpunlocker patched kernel modules:"
    echo "  - Stops cmpunlocker systemd service"
    echo "  - Removes ${INSTALL_DIR} (legacy install dir, if present)"
    echo "  - Removes cmpretrain service / modprobe Gen2 helpers"
    echo "  - Removes VM passthrough helpers (service, udev rule, vfio modprobe conf)"
    echo "  - Rebuilds the stock nvidia DKMS modules that install.sh removed"
    echo "  - Reloads stock NVIDIA modules (brief display interruption)"
    echo "  - Restores the pre-install kernel command line (reverts IOMMU changes)"
    echo ""
    echo "Run: sudo ./remove.sh --yes"
    exit 1
fi

step_init 5

step "Verifying root privileges"
[[ "${EUID}" -eq 0 ]] || die "Run as root: sudo ./remove.sh --yes"
ok "Running as root"

LOG_DIR="${SCRIPT_DIR}/logs"
if ! mkdir -p "${LOG_DIR}" 2>/dev/null || [[ ! -w "${LOG_DIR}" ]]; then
    LOG_DIR="/tmp"
fi
LOG_FILE="${LOG_DIR}/remove_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "${LOG_FILE}") 2>&1

step "Stopping cmpunlocker service and PCIe/IOMMU helpers"
if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
    systemctl stop "${SERVICE_NAME}" || true
    ok "Service stopped"
else
    warn "Service not running"
fi
if systemctl is-enabled --quiet "${SERVICE_NAME}" 2>/dev/null; then
    systemctl disable "${SERVICE_NAME}" || true
    ok "Service disabled"
fi
if [[ -f "${SERVICE_FILE}" ]]; then
    rm -f "${SERVICE_FILE}"
    systemctl daemon-reload
    systemctl reset-failed "${SERVICE_NAME}" 2>/dev/null || true
    ok "Removed ${SERVICE_FILE}"
fi
pkill -f "${INSTALL_DIR}/daemon/watchdog.py" 2>/dev/null || true

info "Removing PCIe Gen2 helpers"
for legacy_unit in cmpretrain.service cmp-gen2-retrain.service; do
    systemctl disable --now "${legacy_unit}" 2>/dev/null || true
    systemctl reset-failed "${legacy_unit}" 2>/dev/null || true
done
rm -f /etc/systemd/system/cmpretrain.service /usr/local/sbin/retrain.sh
rm -f /etc/systemd/system/cmp-gen2-retrain.service /usr/local/sbin/cmp-gen2-retrain.sh
rm -f /etc/modprobe.d/cmp-pcie-gen2.conf
systemctl disable --now gen2.service 2>/dev/null || true
systemctl reset-failed gen2.service 2>/dev/null || true
rm -f /etc/systemd/system/gen2.service /usr/local/sbin/gen2-hammer
ok "Removed PCIe Gen2 helpers"

info "Removing VM passthrough helpers"
systemctl disable --now cmpunlocker-passthrough.service 2>/dev/null || true
systemctl reset-failed cmpunlocker-passthrough.service 2>/dev/null || true
rm -f /etc/systemd/system/cmpunlocker-passthrough.service \
      /etc/udev/rules.d/99-cmpunlocker-passthrough.rules \
      /etc/modprobe.d/cmpunlocker-vfio.conf
rm -rf "${PASSTHROUGH_LIB}"
udevadm control --reload-rules 2>/dev/null || true
if grep -q '^cmp_no_bus_reset ' /proc/modules; then
    rmmod cmp_no_bus_reset 2>/dev/null || true
fi
mapfile -t cmp_bdfs < <(lspci -Dn 2>/dev/null | awk '/10de:20c2|10de:2082/{print $1}')
for bdf in "${cmp_bdfs[@]}"; do
    printf 'default' > "/sys/bus/pci/devices/${bdf}/reset_method" 2>/dev/null || true
done
systemctl daemon-reload 2>/dev/null || true
ok "Removed VM passthrough helpers"

info "Restoring IOMMU kernel command line"
iommu_restored=0
for cfg in /etc/default/grub /etc/kernel/cmdline; do
    if [[ -f "${cfg}.cmpunlocker.bak" ]]; then
        mv -f "${cfg}.cmpunlocker.bak" "${cfg}"
        ok "Restored ${cfg} from pre-install backup"
        iommu_restored=1
    fi
done
if (( iommu_restored )); then
    if command -v update-grub &>/dev/null; then
        update-grub 2>/dev/null || true
    elif command -v grub2-mkconfig &>/dev/null; then
        grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || true
    elif command -v grub-mkconfig &>/dev/null; then
        grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || true
    fi
    ok "Reverted IOMMU kernel parameters (effective after reboot)"
else
    warn "No IOMMU config backup found — kernel command line left as-is"
fi

step "Removing patched modules, DKMS cleanup, and restoring original source"

if [ -e "${CMPUNLOCKER_DIR}" ]; then
    # Read driver versions from metadata
    REMOVED_VERSIONS=()
    if [[ -f "${CMPUNLOCKER_DIR}/driver_version" ]]; then
        REMOVED_VERSIONS+=("$(cat "${CMPUNLOCKER_DIR}/driver_version")")
    fi

    # Remove patched modules via DKMS
    if command -v dkms &>/dev/null; then
        for ver in "${REMOVED_VERSIONS[@]}"; do
            info "dkms remove nvidia/${ver} --all"
            dkms remove -m nvidia -v "${ver}" --all 2>/dev/null || true
            ok "DKMS modules removed for nvidia/${ver}"
        done
    fi

    # Restore original DKMS source from backup
    for ver in "${REMOVED_VERSIONS[@]}"; do
        backup="${CMPUNLOCKER_DIR}/nvidia-${ver}"
        src="/usr/src/nvidia-${ver}"
        if [[ -d "${backup}" ]]; then
            info "Restoring original DKMS source from ${backup} ..."
            rm -rf "${src}"
            cp -a "${backup}" "${src}"
            ok "Original DKMS source restored for nvidia-${ver}"

            # Rebuild stock modules via DKMS
            if command -v dkms &>/dev/null; then
                info "Rebuilding stock nvidia/${ver} via DKMS ..."
                dkms build -m nvidia -v "${ver}" 2>/dev/null || true
                dkms install -m nvidia -v "${ver}" 2>/dev/null || true
                ok "Stock DKMS modules rebuilt for nvidia/${ver}"
            fi

            # Clean up backup
            rm -rf "${backup}"
            ok "Backup removed: ${backup}"
        else
            warn "No backup found at ${backup} — source not restored"
        fi
        rm -f "${CMPUNLOCKER_DIR}/.cmpunlocker-stamp-${ver}"
    done

    rm -rf "${CMPUNLOCKER_DIR}"
    ok "Removed cmpunlocker config"

    # Rebuild initramfs
    if command -v update-initramfs &>/dev/null; then
        update-initramfs -u -k all 2>/dev/null || true
    elif command -v dracut &>/dev/null; then
        dracut --force --regenerate-all 2>/dev/null || true
    elif command -v mkinitcpio &>/dev/null; then
        mkinitcpio -P 2>/dev/null || true
    fi
    ok "depmod and initramfs refresh attempted"
else
    warn "No patched kernel modules found"
fi

for gsp in /lib/firmware/nvidia/*/gsp_tu10x.bin; do
    rm -f \
        "${gsp}.cmpunlocker.bak" \
        "${gsp}.cmpunlocker.patched" \
        "${gsp}.cmpunlocker.tmp" \
        "${gsp}.cmpunlocker.cleanup" \
        "${gsp}.cmpunlocker.pat"
done

if [[ -d "${INSTALL_DIR}" ]]; then
    rm -rf "${INSTALL_DIR}"
    ok "Removed ${INSTALL_DIR}"
else
    warn "${INSTALL_DIR} not found (ok for module-only installs)"
fi

step "Reloading stock NVIDIA driver"
nvidia_was_loaded=0
if grep -q '^nvidia' /proc/modules; then
    nvidia_was_loaded=1
    warn "Unloading NVIDIA modules (display may flicker)"
    for svc in gdm3 sddm lightdm display-manager; do
        systemctl stop "${svc}" 2>/dev/null || true
    done
    systemctl stop nvidia-persistenced 2>/dev/null || true
    killall -9 Xorg Xwayland nvidia-persistenced 2>/dev/null || true
    sleep 1

    for mod in nvidia_drm nvidia_uvm nvidia_modeset nvidia; do
        modprobe -r "${mod}" 2>/dev/null || true
    done
    sleep 1

    if grep -q '^nvidia' /proc/modules; then
        for mod in nvidia_uvm nvidia_drm nvidia_modeset nvidia; do
            rmmod -f "${mod}" 2>/dev/null || true
        done
    fi
else
    warn "NVIDIA modules not loaded"
fi

if modprobe nvidia 2>/dev/null; then
    modprobe nvidia-modeset 2>/dev/null || true
    modprobe nvidia-uvm 2>/dev/null || true
    modprobe nvidia-drm 2>/dev/null || true
    ok "Stock NVIDIA driver loaded: $(modinfo -n nvidia 2>/dev/null || true)"
else
    warn "Could not load NVIDIA driver — reboot to finish cleanup"
fi

if (( nvidia_was_loaded )); then
    for svc in gdm3 sddm lightdm display-manager; do
        if systemctl is-enabled --quiet "${svc}" 2>/dev/null; then
            systemctl start "${svc}" 2>/dev/null || true
            break
        fi
    done
fi

step "Done"
banner
echo "cmpunlocker has been removed from system."
echo "Log saved to: ${LOG_FILE}"
echo ""
echo "If the GPU or display is not working, reboot once:"
echo -e "  ${CYAN}sudo reboot${NC}"
echo ""
