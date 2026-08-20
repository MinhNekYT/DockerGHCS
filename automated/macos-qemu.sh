#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/common.sh"

OSX_KVM_DIR="${OSX_KVM_DIR:-${STORAGE_DIR}/dockerghcs-osx-kvm}"
MACOS_INSTALLER_DIR="${MACOS_INSTALLER_DIR:-${STORAGE_DIR}/macos-sequoia}"
BASESYSTEM_DMG="${MACOS_INSTALLER_DIR}/BaseSystem.dmg"
BASESYSTEM_IMG="${MACOS_INSTALLER_DIR}/BaseSystem.img"
OPENCORE_ISO="${OPENCORE_ISO:-${STORAGE_DIR}/LongQT-OpenCore-v0.7.iso}"
OPENCORE_ISO_URL="${OPENCORE_ISO_URL:-https://github.com/LongQT-sea/OpenCore-ISO/releases/download/v0.7/LongQT-OpenCore-v0.7.iso}"
MACOS_DISK_PATH="${MACOS_DISK_PATH:-${STORAGE_DIR}/mac_hdd_ng.img}"
MACOS_RAM="${MACOS_RAM:-8G}"
MACOS_CPUS="${MACOS_CPUS:-4}"
OSX_KVM_URL="${OSX_KVM_URL:-https://github.com/kholia/OSX-KVM.git}"

usage() {
    cat <<'EOF'
Usage:
  ./automated/macos-qemu.sh

This script uses kholia/OSX-KVM to fetch macOS Sequoia 15 recovery media,
then boots it with the LongQT OpenCore ISO in QEMU/KVM.

Environment:
  VM_DISK_SIZE=400G                 qcow2 macOS disk, mặc định 400G
  VM_NOVNC_PORT=8006                cổng noVNC
  VM_STORAGE_DIR=/mnt               thư mục lưu installer/OpenCore/disk
  MACOS_RAM=8G                      RAM QEMU
  MACOS_CPUS=4                      số vCPU
EOF
}

require_root "$@"
[[ "${1:-}" != "--help" && "${1:-}" != "-h" ]] || { usage; exit 0; }
validate_runtime
install_qemu_packages
configure_kvm_for_macos

if [[ ! -e /dev/kvm || ! -r /dev/kvm || ! -w /dev/kvm ]]; then
    echo "macOS QEMU yêu cầu /dev/kvm có quyền đọc/ghi; không dùng TCG fallback cho macOS." >&2
    exit 1
fi

mkdir -p "${OSX_KVM_DIR}" "${MACOS_INSTALLER_DIR}"
if [[ ! -x "${OSX_KVM_DIR}/fetch-macOS-v2.py" ]]; then
    rm -rf "${OSX_KVM_DIR}"
    echo "=== Tải tool kholia/OSX-KVM ==="
    git clone --depth 1 --recursive "${OSX_KVM_URL}" "${OSX_KVM_DIR}"
fi

if [[ ! -s "${BASESYSTEM_DMG}" ]]; then
    echo "=== Fetch macOS Sequoia 15 bằng fetch-macOS-v2.py ==="
    (cd "${OSX_KVM_DIR}" && python3 ./fetch-macOS-v2.py \
        --action download \
        --shortname sequoia \
        --outdir "${MACOS_INSTALLER_DIR}")
fi
validate_large_file "${BASESYSTEM_DMG}" $((50 * 1024 * 1024))

if [[ ! -s "${BASESYSTEM_IMG}" ]]; then
    command -v dmg2img >/dev/null 2>&1 || {
        echo "Thiếu dmg2img; hãy cài package dmg2img rồi chạy lại." >&2
        exit 1
    }
    echo "=== Chuyển BaseSystem.dmg thành BaseSystem.img ==="
    dmg2img -i "${BASESYSTEM_DMG}" "${BASESYSTEM_IMG}"
fi
validate_large_file "${BASESYSTEM_IMG}" $((50 * 1024 * 1024))

if [[ ! -s "${OPENCORE_ISO}" ]]; then
    echo "=== Tải OpenCore ISO cho macOS ==="
    download_file "${OPENCORE_ISO_URL}" "${OPENCORE_ISO}"
fi
validate_large_file "${OPENCORE_ISO}" $((10 * 1024 * 1024))

find_ovmf_assets
create_or_resize_disk "${MACOS_DISK_PATH}" qcow2
kill_previous_qemu_for_disk "${MACOS_DISK_PATH}"
start_pulseaudio
common_qemu_log_start

vars_path="${STORAGE_DIR}/macos-ovmf-vars.fd"
if [[ ! -e "${vars_path}" ]]; then
    cp "${OVMF_VARS_TEMPLATE}" "${vars_path}"
fi

trap cleanup_automated_vm INT TERM EXIT
: > "${VM_QEMU_LOG}"
echo "=== Khởi động macOS Sequoia 15 qua QEMU/KVM + OpenCore ==="
PULSE_SERVER="unix:${VM_PULSE_SOCKET}" qemu-system-x86_64 \
    -enable-kvm \
    -machine q35 \
    -cpu 'Skylake-Client,-hle,-rtm,kvm=on,vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on,+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,check' \
    -m "${MACOS_RAM}" \
    -smp "${MACOS_CPUS}",cores="${MACOS_CPUS}",sockets=1 \
    -device qemu-xhci,id=xhci \
    -device usb-kbd,bus=xhci.0 \
    -device usb-tablet,bus=xhci.0 \
    -device isa-applesmc,osk='ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc' \
    -smbios type=2 \
    -device ich9-intel-hda \
    -audiodev "driver=pa,id=pa0,server=unix:${VM_PULSE_SOCKET}" \
    -device hda-duplex,audiodev=pa0 \
    -device ich9-ahci,id=sata \
    -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE_PATH}" \
    -drive "if=pflash,format=raw,readonly=off,file=${vars_path}" \
    -drive "id=OpenCoreISO,if=none,media=cdrom,format=raw,readonly=on,file=${OPENCORE_ISO}" \
    -device ide-cd,bus=sata.2,drive=OpenCoreISO \
    -drive "id=InstallMedia,if=none,media=cdrom,format=raw,readonly=on,file=${BASESYSTEM_IMG}" \
    -device ide-cd,bus=sata.3,drive=InstallMedia \
    -drive "id=MacHDD,if=none,format=qcow2,file=${MACOS_DISK_PATH}" \
    -device ide-hd,bus=sata.4,drive=MacHDD \
    -netdev "user,id=net0,ipv4=on,ipv6=off,dns=10.0.2.3,hostfwd=tcp::2222-:22" \
    -device virtio-net-pci,netdev=net0,id=net0,mac=52:54:00:c9:18:27 \
    -device virtio-rng-pci \
    -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off \
    -vga vmware \
    -boot menu=on,once=d \
    -vnc "127.0.0.1:${VM_VNC_DISPLAY}" \
    > "${VM_QEMU_LOG}" 2>&1 &
QEMU_PID=$!
wait_for_tcp_port "${VM_VNC_PORT}" 60 || {
    echo "QEMU macOS không mở VNC ${VM_VNC_PORT}." >&2
    exit 1
}
start_novnc
echo "macOS Sequoia 15 QEMU đang chạy: VNC ${VM_VNC_PORT}, noVNC ${VM_NOVNC_PORT}."
echo "Lần đầu: chọn OpenCore → BaseSystem, mở Disk Utility, format disk APFS rồi cài macOS."
echo "Sau khi cài xong, hãy giữ OpenCore ISO để boot; có thể cài EFI OpenCore vào disk theo tài liệu upstream."
echo "Nhấn Ctrl+C để dừng QEMU, noVNC và PulseAudio."
wait "${QEMU_PID}"
