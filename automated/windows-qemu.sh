#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/common.sh"

WINDOWS_ISO_PATH="${WINDOWS_ISO_PATH:-${STORAGE_DIR}/custom.iso}"
DRIVER_ISO_PATH="${DRIVER_ISO_PATH:-${STORAGE_DIR}/driver.iso}"
WINDOWS_DISK_PATH="${WINDOWS_DISK_PATH:-${STORAGE_DIR}/windows.img}"
DRIVER_ISO_URL="${DRIVER_ISO_URL:-https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.285-1/virtio-win-0.1.285.iso}"
WINDOWS_RAM="${WINDOWS_RAM:-8G}"
WINDOWS_CPUS="${WINDOWS_CPUS:-4}"
WINDOWS_ISO_URL="${WINDOWS_ISO_URL:-}"

usage() {
    cat <<'EOF'
Usage:
  ./automated/windows-qemu.sh

Environment:
  WINDOWS_ISO_URL=https://...       URL Windows ISO nếu custom.iso chưa tồn tại
  VM_DISK_SIZE=400G                 kích thước raw disk, mặc định 400G
  WINDOWS_RAM=8G                    RAM QEMU
  WINDOWS_CPUS=4                    số vCPU
  VM_NOVNC_PORT=8006                cổng noVNC
  VM_STORAGE_DIR=/mnt               thư mục lưu ISO/disk
EOF
}

require_root "$@"
[[ "${1:-}" != "--help" && "${1:-}" != "-h" ]] || { usage; exit 0; }
validate_runtime
install_qemu_packages
mkdir -p "${STORAGE_DIR}"

if [[ ! -e "${WINDOWS_ISO_PATH}" ]]; then
    if [[ -z "${WINDOWS_ISO_URL}" ]]; then
        read -r -p "Dán link ISO Windows: " WINDOWS_ISO_URL
    fi
    [[ "${WINDOWS_ISO_URL}" == http://* || "${WINDOWS_ISO_URL}" == https://* ]] || {
        echo "WINDOWS_ISO_URL phải bắt đầu bằng http:// hoặc https://." >&2
        exit 1
    }
    echo "=== Tải Windows ISO ==="
    download_file "${WINDOWS_ISO_URL}" "${WINDOWS_ISO_PATH}"
fi
validate_large_file "${WINDOWS_ISO_PATH}"

if [[ ! -e "${DRIVER_ISO_PATH}" ]]; then
    echo "=== Tải VirtIO driver ISO ==="
    download_file "${DRIVER_ISO_URL}" "${DRIVER_ISO_PATH}"
fi
validate_large_file "${DRIVER_ISO_PATH}"

find_ovmf_assets
create_or_resize_disk "${WINDOWS_DISK_PATH}" raw
kill_previous_qemu_for_disk "${WINDOWS_DISK_PATH}"
start_pulseaudio
common_qemu_log_start

cpu_arg="max"
accel_args=()
if [[ -e /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
    cpu_arg="host"
    accel_args=(-enable-kvm)
else
    echo "Không có KVM; Windows sẽ chạy bằng TCG fallback." >&2
fi

boot_args=(-boot 'menu=on,once=d')
if disk_has_partition_table "${WINDOWS_DISK_PATH}"; then
    boot_args=(-boot 'order=c')
    echo "Phát hiện Windows disk đã có partition table; boot từ disk hiện tại."
else
    echo "Windows disk chưa có partition table; boot installer từ ISO."
fi

pflash_args=(
    -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE_PATH}"
)
vars_path="${STORAGE_DIR}/windows-ovmf-vars.fd"
if [[ ! -e "${vars_path}" ]]; then
    cp "${OVMF_VARS_TEMPLATE}" "${vars_path}"
fi
pflash_args+=(
    -drive "if=pflash,format=raw,readonly=off,file=${vars_path}"
)

trap cleanup_automated_vm INT TERM EXIT
: > "${VM_QEMU_LOG}"
echo "=== Khởi động Windows qua QEMU/KVM ==="
PULSE_SERVER="unix:${VM_PULSE_SOCKET}" qemu-system-x86_64 \
    "${accel_args[@]}" \
    -machine q35,usb=on \
    -cpu "${cpu_arg}" \
    -m "${WINDOWS_RAM}" \
    -smp "${WINDOWS_CPUS}" \
    -nodefaults \
    -device qemu-xhci,id=xhci \
    -device usb-kbd,bus=xhci.0 \
    -device usb-tablet,bus=xhci.0 \
    -device ich9-intel-hda \
    -audiodev "driver=pa,id=pa0,server=unix:${VM_PULSE_SOCKET}" \
    -device hda-duplex,audiodev=pa0 \
    -drive "file=${WINDOWS_DISK_PATH},format=raw,if=none,id=windowsdisk" \
    -device virtio-blk-pci,drive=windowsdisk \
    -drive "file=${WINDOWS_ISO_PATH},media=cdrom,readonly=on" \
    -drive "file=${DRIVER_ISO_PATH},media=cdrom,readonly=on" \
    -netdev "user,id=n0,ipv4=on,ipv6=off,dns=10.0.2.3,hostfwd=tcp::3389-:3389" \
    -device virtio-net-pci,netdev=n0 \
    -device virtio-rng-pci \
    "${pflash_args[@]}" \
    "${boot_args[@]}" \
    -vga virtio \
    -vnc "127.0.0.1:${VM_VNC_DISPLAY}" \
    > "${VM_QEMU_LOG}" 2>&1 &
QEMU_PID=$!
wait_for_tcp_port "${VM_VNC_PORT}" 60 || {
    echo "QEMU Windows không mở VNC ${VM_VNC_PORT}." >&2
    exit 1
}
start_novnc
echo "Windows QEMU đang chạy: VNC ${VM_VNC_PORT}, noVNC ${VM_NOVNC_PORT}, RDP hostfwd 3389."
echo "Nhấn Ctrl+C để dừng QEMU, noVNC và PulseAudio."
wait "${QEMU_PID}"
