#!/usr/bin/env bash
set -Eeuo pipefail

STORAGE_DIR="${VM_STORAGE_DIR:-/mnt}"
VM_DISK_SIZE="${VM_DISK_SIZE:-400G}"
VM_NOVNC_PORT="${VM_NOVNC_PORT:-8006}"
VM_VNC_DISPLAY="${VM_VNC_DISPLAY:-0}"
VM_VNC_PORT=$((5900 + VM_VNC_DISPLAY))
VM_QEMU_LOG="${VM_QEMU_LOG:-/tmp/dockerghcs-qemu.log}"
VM_NOVNC_LOG="${VM_NOVNC_LOG:-/tmp/dockerghcs-novnc.log}"
VM_PULSE_LOG="${VM_PULSE_LOG:-/tmp/dockerghcs-pulseaudio.log}"
VM_PULSE_SOCKET="${VM_PULSE_SOCKET:-/run/pulse/native}"
VM_PULSE_PID_FILE="${VM_PULSE_PID_FILE:-/run/dockerghcs-pulseaudio.pid}"
VM_PULSE_STARTED=0
QEMU_PID=""
NOVNC_PID=""

on_automated_error() {
    local exit_code=$?
    trap - ERR
    echo "automated: script dừng do lỗi (mã ${exit_code})." >&2
    if [[ -s "${VM_QEMU_LOG}" ]]; then
        tail -n 80 "${VM_QEMU_LOG}" >&2
    fi
    if [[ -s "${VM_NOVNC_LOG}" ]]; then
        tail -n 50 "${VM_NOVNC_LOG}" >&2
    fi
    if [[ -s "${VM_PULSE_LOG}" ]]; then
        tail -n 50 "${VM_PULSE_LOG}" >&2
    fi
    exit "${exit_code}"
}
trap on_automated_error ERR

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        if ! command -v sudo >/dev/null 2>&1; then
            echo "Cần sudo hoặc chạy script bằng root." >&2
            exit 1
        fi
        sudo -v
        local target_user="${SUDO_USER:-${USER:-}}"
        exec sudo env \
            "DOCKERGHCS_AUTOMATED_ROOT=1" \
            "DOCKERGHCS_TARGET_USER=${target_user}" \
            "VM_STORAGE_DIR=${STORAGE_DIR}" \
            "VM_DISK_SIZE=${VM_DISK_SIZE}" \
            "VM_NOVNC_PORT=${VM_NOVNC_PORT}" \
            "VM_VNC_DISPLAY=${VM_VNC_DISPLAY}" \
            bash "$0" "$@"
    fi
}

validate_runtime() {
    [[ "${VM_DISK_SIZE}" =~ ^[1-9][0-9]*(G|T|M)$ ]] || {
        echo "VM_DISK_SIZE phải có dạng như 400G, 128G hoặc 1T: ${VM_DISK_SIZE}" >&2
        exit 1
    }
    if [[ ! "${VM_NOVNC_PORT}" =~ ^[1-9][0-9]*$ ]] || ((VM_NOVNC_PORT > 65535)); then
        echo "VM_NOVNC_PORT không hợp lệ: ${VM_NOVNC_PORT}" >&2
        exit 1
    fi
    ((VM_NOVNC_PORT != VM_VNC_PORT)) || {
        echo "VM_NOVNC_PORT không được trùng với VNC port ${VM_VNC_PORT}." >&2
        exit 1
    }
    ((VM_NOVNC_PORT < 5900 || VM_NOVNC_PORT > 5999)) || {
        echo "VM_NOVNC_PORT không được nằm trong dải VNC 5900-5999." >&2
        exit 1
    }
    mkdir -p "${STORAGE_DIR}"
    [[ -w "${STORAGE_DIR}" ]] || {
        echo "Không có quyền ghi vào ${STORAGE_DIR}." >&2
        exit 1
    }
}

install_qemu_packages() {
    local packages=(
        qemu-system-x86 qemu-system-gui qemu-utils ovmf novnc websockify
        pulseaudio pulseaudio-utils curl wget git python3 python3-pip
    )
    for package in dmg2img p7zip-full; do
        apt-cache show "${package}" >/dev/null 2>&1 && packages+=("${package}")
    done
    echo "=== Cài/kiểm tra QEMU, OVMF, noVNC và PulseAudio ==="
    apt-get update -o Acquire::Retries=3
    apt-get install -y "${packages[@]}"
    for command_name in qemu-system-x86_64 qemu-img pulseaudio pactl; do
        command -v "${command_name}" >/dev/null 2>&1 || {
            echo "Thiếu command sau khi cài package: ${command_name}" >&2
            exit 1
        }
    done
}

configure_kvm_for_macos() {
    local target_user="${DOCKERGHCS_TARGET_USER:-${SUDO_USER:-${USER:-}}}"
    local cpu_vendor
    cpu_vendor="$(lscpu 2>/dev/null | awk -F: '/Vendor ID/ {gsub(/[[:space:]]/, "", $2); print tolower($2); exit}')"
    local kvm_conf_url
    if [[ "${cpu_vendor}" == *amd* ]]; then
        kvm_conf_url="https://raw.githubusercontent.com/kholia/OSX-KVM/master/kvm_amd.conf"
        echo "CPU AMD: dùng kvm_amd.conf của osx-kvm."
    else
        kvm_conf_url="https://raw.githubusercontent.com/kholia/OSX-KVM/master/kvm.conf"
        echo "CPU Intel/không xác định: dùng kvm.conf của osx-kvm."
    fi
    curl -fsSL --retry 3 "${kvm_conf_url}" -o /etc/modprobe.d/kvm.conf
    modprobe kvm >/dev/null 2>&1 || true
    if [[ "${cpu_vendor}" == *amd* ]]; then
        modprobe kvm_amd nested=1 ignore_msrs=1 report_ignored_msrs=0 >/dev/null 2>&1 || true
    else
        modprobe kvm_intel nested=1 ignore_msrs=1 report_ignored_msrs=0 >/dev/null 2>&1 || true
    fi
    if [[ -n "${target_user}" && "${target_user}" != root ]] && id "${target_user}" >/dev/null 2>&1; then
        for group_name in kvm libvirt input; do
            getent group "${group_name}" >/dev/null 2>&1 || groupadd "${group_name}"
            usermod -aG "${group_name}" "${target_user}"
        done
        echo "Đã thêm ${target_user} vào kvm, libvirt và input; group mới có hiệu lực sau khi đăng nhập lại."
    fi
}

find_ovmf_assets() {
    if [[ -f /usr/share/OVMF/OVMF_CODE_4M.fd ]]; then
        # shellcheck disable=SC2034
        OVMF_CODE_PATH=/usr/share/OVMF/OVMF_CODE_4M.fd
        OVMF_VARS_TEMPLATE=/usr/share/OVMF/OVMF_VARS_4M.ms.fd
        [[ -f "${OVMF_VARS_TEMPLATE}" ]] || OVMF_VARS_TEMPLATE=/usr/share/OVMF/OVMF_VARS_4M.fd
    elif [[ -f /usr/share/OVMF/OVMF_CODE.fd ]]; then
        # shellcheck disable=SC2034
        OVMF_CODE_PATH=/usr/share/OVMF/OVMF_CODE.fd
        OVMF_VARS_TEMPLATE=/usr/share/OVMF/OVMF_VARS.ms.fd
        [[ -f "${OVMF_VARS_TEMPLATE}" ]] || OVMF_VARS_TEMPLATE=/usr/share/OVMF/OVMF_VARS.fd
    else
        echo "Không tìm thấy OVMF firmware." >&2
        exit 1
    fi
}

create_or_resize_disk() {
    local disk_path="$1"
    local format="$2"
    local requested_bytes current_bytes
    requested_bytes="$(numfmt --from=iec "${VM_DISK_SIZE}" 2>/dev/null || echo 0)"
    [[ "${requested_bytes}" =~ ^[0-9]+$ && "${requested_bytes}" -gt 0 ]] || {
        echo "Không thể chuyển VM_DISK_SIZE thành bytes: ${VM_DISK_SIZE}" >&2
        exit 1
    }
    if [[ ! -e "${disk_path}" ]]; then
        echo "Tạo ${format} disk ${disk_path} (${VM_DISK_SIZE})."
        qemu-img create -f "${format}" "${disk_path}" "${VM_DISK_SIZE}"
        return 0
    fi
    current_bytes="$(qemu-img info --output=json "${disk_path}" 2>/dev/null \
        | tr -d '[:space:]' \
        | sed -n 's/.*"virtual-size":\([0-9][0-9]*\).*/\1/p')"
    if [[ "${current_bytes}" =~ ^[0-9]+$ ]] && ((current_bytes < requested_bytes)); then
        echo "Mở rộng ${disk_path} lên ${VM_DISK_SIZE}."
        qemu-img resize "${disk_path}" "${VM_DISK_SIZE}"
    elif [[ "${current_bytes}" =~ ^[0-9]+$ ]] && ((current_bytes > requested_bytes)); then
        echo "${disk_path} lớn hơn ${VM_DISK_SIZE}; giữ nguyên, không thu nhỏ."
    else
        echo "Giữ disk hiện có: ${disk_path}."
    fi
    qemu-img info "${disk_path}" >/dev/null
}

download_file() {
    local url="$1"
    local destination="$2"
    local temporary_file
    temporary_file="$(mktemp "${destination}.part.XXXXXX")"
    if ! curl -fL --retry 3 --retry-delay 3 --progress-bar "${url}" -o "${temporary_file}"; then
        rm -f "${temporary_file}"
        echo "Không thể tải ${url}." >&2
        return 1
    fi
    mv -f "${temporary_file}" "${destination}"
}

validate_large_file() {
    local path="$1"
    local min_bytes="${2:-10485760}"
    local size_bytes
    size_bytes="$(stat -c '%s' "${path}" 2>/dev/null || echo 0)"
    [[ "${size_bytes}" =~ ^[0-9]+$ && "${size_bytes}" -ge "${min_bytes}" ]] || {
        echo "File không hợp lệ hoặc tải chưa hoàn tất: ${path}" >&2
        return 1
    }
}

disk_has_partition_table() {
    local image_path="$1"
    local mbr_signature gpt_signature
    [[ -s "${image_path}" ]] || return 1
    mbr_signature="$(dd if="${image_path}" bs=1 skip=510 count=2 2>/dev/null | od -An -tx1 | tr -d '[:space:]')"
    gpt_signature="$(dd if="${image_path}" bs=1 skip=512 count=8 2>/dev/null | od -An -tx1 | tr -d '[:space:]')"
    [[ "${mbr_signature}" == 55aa || "${gpt_signature}" == 4546492050415254 ]]
}

start_pulseaudio() {
    if [[ -S "${VM_PULSE_SOCKET}" ]] \
        && PULSE_SERVER="unix:${VM_PULSE_SOCKET}" pactl info >/dev/null 2>&1; then
        return 0
    fi
    install -d -m 0755 /run/pulse
    rm -f "${VM_PULSE_PID_FILE}"
    : > "${VM_PULSE_LOG}"
    pulseaudio --system --daemonize=yes --disallow-exit --exit-idle-time=-1 \
        --pid-file="${VM_PULSE_PID_FILE}" \
        --log-target="file:${VM_PULSE_LOG}"
    VM_PULSE_STARTED=1
    local elapsed=0
    while ((elapsed < 15)); do
        if [[ -S "${VM_PULSE_SOCKET}" ]] \
            && PULSE_SERVER="unix:${VM_PULSE_SOCKET}" pactl info >/dev/null 2>&1; then
            echo "PulseAudio đã sẵn sàng: ${VM_PULSE_SOCKET}"
            return 0
        fi
        sleep 1
        ((elapsed += 1))
    done
    echo "PulseAudio không mở socket ${VM_PULSE_SOCKET}." >&2
    return 1
}

find_novnc_proxy() {
    if command -v novnc_proxy >/dev/null 2>&1; then
        NOVNC_PROXY_BIN="$(command -v novnc_proxy)"
    elif [[ -x /usr/share/novnc/utils/novnc_proxy ]]; then
        NOVNC_PROXY_BIN=/usr/share/novnc/utils/novnc_proxy
    elif [[ -x /usr/share/novnc/utils/novnc_proxy.py ]]; then
        NOVNC_PROXY_BIN=/usr/share/novnc/utils/novnc_proxy.py
    else
        echo "Không tìm thấy novnc_proxy." >&2
        exit 1
    fi
}

start_novnc() {
    find_novnc_proxy
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${VM_NOVNC_PORT}$"; then
        echo "Cổng noVNC ${VM_NOVNC_PORT} đang được sử dụng." >&2
        exit 1
    fi
    echo "Khởi động noVNC ${VM_NOVNC_PORT} -> VNC 127.0.0.1:${VM_VNC_PORT}."
    : > "${VM_NOVNC_LOG}"
    nohup "${NOVNC_PROXY_BIN}" --listen "${VM_NOVNC_PORT}" --vnc "127.0.0.1:${VM_VNC_PORT}" \
        > "${VM_NOVNC_LOG}" 2>&1 &
    NOVNC_PID=$!
    wait_for_tcp_port "${VM_NOVNC_PORT}" 30 || {
        echo "noVNC không mở cổng ${VM_NOVNC_PORT}." >&2
        return 1
    }
}

wait_for_tcp_port() {
    local port="$1"
    local timeout_seconds="${2:-30}"
    local elapsed=0
    while ((elapsed < timeout_seconds)); do
        if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}$"; then
            return 0
        fi
        sleep 1
        ((elapsed += 1))
    done
    return 1
}

cleanup_automated_vm() {
    local exit_code=$?
    trap - INT TERM EXIT
    if [[ -n "${NOVNC_PID:-}" ]] && kill -0 "${NOVNC_PID}" 2>/dev/null; then
        kill "${NOVNC_PID}" 2>/dev/null || true
    fi
    if [[ -n "${QEMU_PID:-}" ]] && kill -0 "${QEMU_PID}" 2>/dev/null; then
        kill "${QEMU_PID}" 2>/dev/null || true
    fi
    if [[ "${VM_PULSE_STARTED:-0}" == 1 && -f "${VM_PULSE_PID_FILE}" ]]; then
        local pulse_pid
        pulse_pid="$(cat "${VM_PULSE_PID_FILE}" 2>/dev/null || true)"
        if [[ "${pulse_pid}" =~ ^[0-9]+$ ]]; then
            kill "${pulse_pid}" 2>/dev/null || true
        fi
        rm -f "${VM_PULSE_PID_FILE}"
    fi
    exit "${exit_code}"
}

prepare_vm_runtime() {
    validate_runtime
    install_qemu_packages
    start_pulseaudio
    trap cleanup_automated_vm INT TERM EXIT
}

qemu_accel_args() {
    if [[ -e /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
        printf '%s\n' '-enable-kvm'
    else
        echo "Không có quyền KVM; dùng TCG fallback, VM sẽ chậm hơn." >&2
    fi
}

common_qemu_log_start() {
    : > "${VM_QEMU_LOG}"
    printf 'disk_size=%s\nvnc_display=%s\nnovnc_port=%s\n' \
        "${VM_DISK_SIZE}" "${VM_VNC_DISPLAY}" "${VM_NOVNC_PORT}" >> "${VM_QEMU_LOG}"
}

kill_previous_qemu_for_disk() {
    local disk_path="$1"
    local pid
    while read -r pid; do
        [[ "${pid}" =~ ^[0-9]+$ && "${pid}" != "$$" && "${pid}" != "${PPID}" ]] || continue
        echo "Dừng QEMU cũ PID ${pid} dùng ${disk_path}."
        kill "${pid}" 2>/dev/null || true
    done < <(pgrep -f "qemu.*${disk_path}" 2>/dev/null || true)
    sleep 1
}
