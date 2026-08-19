#!/usr/bin/env bash
set -Eeuo pipefail

# Cài Docker hoặc QEMU/KVM, chuẩn bị ISO và khởi động Windows, macOS hoặc Proxmox.
# Script này được thiết kế cho DockerGHCS trên Ubuntu/GitHub Codespaces có quyền root.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WINDOWS_ISO_PATH="/mnt/custom.iso"
DRIVER_ISO_PATH="/mnt/driver.iso"
DRIVER_ISO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.285-1/virtio-win-0.1.285.iso"
PROXMOX_ISO_PATH="/mnt/proxmox-ve_9.2-1.iso"
PROXMOX_AUTO_ISO_PATH="/mnt/proxmox-ve_9.2-1-auto.iso"
PROXMOX_ANSWER_PATH="/mnt/dockerghcs-proxmox-answer.toml"
PROXMOX_FIRST_BOOT_PATH="/mnt/dockerghcs-proxmox-first-boot.sh"
PROXMOX_ISO_BOOT_PATH="${PROXMOX_ISO_PATH}"
PROXMOX_AUTO_INSTALL="${PROXMOX_AUTO_INSTALL:-1}"
PROXMOX_ROOT_PASSWORD="${PROXMOX_ROOT_PASSWORD:-}"
PROXMOX_FQDN="${PROXMOX_FQDN:-pve.local}"
PROXMOX_COUNTRY="${PROXMOX_COUNTRY:-vn}"
PROXMOX_TIMEZONE="${PROXMOX_TIMEZONE:-Asia/Ho_Chi_Minh}"
PROXMOX_ISO_URL="https://enterprise.proxmox.com/iso/proxmox-ve_9.2-1.iso"
PROXMOX_ISO_SHA256="4e88fe416df9b527624a175f24c9aa07c714d3332afb1ee3dbf3879573ef2c6c"
PROXMOX_DISK_PATH="/mnt/a.img"
PROXMOX_DISK_SIZE="${PROXMOX_DISK_SIZE:-400G}"
MIN_FREE_KB=$((10 * 1024 * 1024))
DOCKER_APT_LOG="/tmp/windowsghcs-docker-apt.log"
PROXMOX_QEMU_LOG="/tmp/dockerghcs-proxmox-qemu.log"
PROXMOX_NOVNC_LOG="/tmp/dockerghcs-proxmox-novnc.log"
NOVNC_PORT="${NOVNC_PORT:-8888}"
PROXMOX_GUEST_PORT="${PROXMOX_GUEST_PORT:-8006}"
QEMU_VNC_TIMEOUT="${QEMU_VNC_TIMEOUT:-60}"
WINDOWS_YAML_URL="https://raw.githubusercontent.com/MinhNekYT/DockerGHCS/refs/heads/main/windows.yaml"
MACOS_YAML_URL="https://raw.githubusercontent.com/MinhNekYT/DockerGHCS/refs/heads/main/macos.yaml"

on_error() {
    local exit_code=$?
    trap - ERR
    echo ""
    echo "Script dừng do lỗi (mã lỗi: ${exit_code})."
    if command -v dpkg > /dev/null 2>&1; then
        echo "Trạng thái package chưa hoàn tất:"
        dpkg --audit 2>/dev/null || true
    fi
    if [[ -s "${DOCKER_APT_LOG}" ]]; then
        echo "Nhật ký cài Docker gần nhất:"
        tail -n 30 "${DOCKER_APT_LOG}"
    fi
    if [[ -s /tmp/windowsghcs-dockerd.log ]]; then
        echo "Nhật ký Docker daemon gần nhất:"
        tail -n 30 /tmp/windowsghcs-dockerd.log
    fi
    if [[ -s "${PROXMOX_QEMU_LOG}" ]]; then
        echo "Nhật ký QEMU gần nhất:"
        tail -n 40 "${PROXMOX_QEMU_LOG}"
    fi
    if [[ -s "${PROXMOX_NOVNC_LOG}" ]]; then
        echo "Nhật ký noVNC gần nhất:"
        tail -n 40 "${PROXMOX_NOVNC_LOG}"
    fi
    exit "${exit_code}"
}
trap on_error ERR

confirm_once() {
    [[ "${WINDOWS_CONFIRMATION_DONE:-0}" == "1" ]] && return 0

    echo ""
    echo "LƯU Ý: Một khi chạy script này thì sẽ không thể cài bản Windows khác bằng script này,"
    echo "chỉ có thể tạo codespaces khác để cài bản Windows khác."
    echo "Script có thể thay đổi package Docker, mount /mnt và tải các file ISO dung lượng lớn."
    echo ""

    while true; do
        read -r -p "Nếu muốn chạy tiếp hãy nhập y, nếu không muốn chạy thì hãy nhập n: " answer
        case "${answer,,}" in
            y|yes)
                break
                ;;
            n|no)
                echo "Đã hủy."
                exit 0
                ;;
            *)
                echo "Vui lòng chỉ nhập y hoặc n."
                ;;
        esac
    done
}

confirm_once

# Khi chạy bằng user thường, xác nhận trước rồi re-exec một lần bằng root.
if [[ "${EUID}" -ne 0 ]]; then
    if ! command -v sudo > /dev/null 2>&1; then
        echo "Không tìm thấy sudo. Hãy chạy script bằng root hoặc cài sudo trước."
        exit 1
    fi
    sudo -v
    calling_user="${SUDO_USER:-${USER:-}}"
    sudo_environment=(
        "WINDOWS_CONFIRMATION_DONE=1"
        "WINDOWS_INSTALL_USER=${calling_user}"
    )
    # Codespaces có thể dùng DOCKER_HOST/DOCKER_CONTEXT để trỏ tới daemon bên ngoài.
    # Giữ các biến này khi chuyển sang root, nếu không script sẽ tưởng Docker bị hỏng.
    for docker_env_name in DOCKER_HOST DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH PROXMOX_DISK_SIZE NOVNC_PORT PROXMOX_GUEST_PORT QEMU_VNC_TIMEOUT PROXMOX_AUTO_INSTALL PROXMOX_FQDN PROXMOX_COUNTRY PROXMOX_TIMEZONE; do
        if [[ -n "${!docker_env_name:-}" ]]; then
            sudo_environment+=("${docker_env_name}=${!docker_env_name}")
        fi
    done
    exec sudo env "${sudo_environment[@]}" bash "$0"
fi

if [[ "${EUID}" -ne 0 ]]; then
    echo "Không thể lấy quyền root."
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive
INSTALL_USER="${WINDOWS_INSTALL_USER:-${SUDO_USER:-}}"

validate_runtime_settings() {
    local variable value
    for variable in NOVNC_PORT PROXMOX_GUEST_PORT QEMU_VNC_TIMEOUT; do
        value="${!variable}"
        if [[ ! "${value}" =~ ^[1-9][0-9]*$ ]]; then
            echo "${variable} phải là số nguyên dương: ${value}" >&2
            exit 1
        fi
    done
    if ((NOVNC_PORT > 65535 || PROXMOX_GUEST_PORT > 65535)); then
        echo "NOVNC_PORT và PROXMOX_GUEST_PORT phải nằm trong khoảng 1-65535." >&2
        exit 1
    fi
    if ((NOVNC_PORT == PROXMOX_GUEST_PORT)); then
        echo "NOVNC_PORT và PROXMOX_GUEST_PORT không được trùng nhau." >&2
        exit 1
    fi
    if ((NOVNC_PORT >= 5900 && NOVNC_PORT <= 5999)) \
        || ((PROXMOX_GUEST_PORT >= 5900 && PROXMOX_GUEST_PORT <= 5999)); then
        echo "Không dùng cổng 5900-5999 cho noVNC/hostfwd vì đây là dải VNC được script dọn trước khi chạy." >&2
        exit 1
    fi
    if ((QEMU_VNC_TIMEOUT > 3600)); then
        echo "QEMU_VNC_TIMEOUT không được lớn hơn 3600 giây." >&2
        exit 1
    fi
}

validate_runtime_settings

read_proxmox_root_password() {
    [[ "${PROXMOX_AUTO_INSTALL}" == "1" ]] || return 0
    if [[ -n "${PROXMOX_ROOT_PASSWORD}" ]]; then
        return 0
    fi
    while true; do
        read -r -s -p "Nhập mật khẩu root Proxmox (tối thiểu 8 ký tự): " PROXMOX_ROOT_PASSWORD
        echo
        if [[ "${#PROXMOX_ROOT_PASSWORD}" -ge 8 ]]; then
            break
        fi
        echo "Mật khẩu phải có ít nhất 8 ký tự." >&2
    done
}

install_docker() {
    echo ""
    echo "=== Kiểm tra Docker hiện có ==="
    # Codespaces thường đã có Docker/Moby. Nếu Compose hoạt động thì không
    # thay thế package, tránh lỗi dpkg khi cài docker-ce lần nữa.
    if command -v docker > /dev/null 2>&1 \
        && docker compose version > /dev/null 2>&1 \
        && docker info > /dev/null 2>&1; then
        echo "Docker Compose và Docker daemon đã hoạt động. Không cài đè Docker package."
    else
        echo ""
        echo "=== Khôi phục trạng thái apt/dpkg nếu lần chạy trước bị gián đoạn ==="
        dpkg --configure -a || true
        apt-get -f install -y || true

        echo ""
        echo "=== Gỡ package Docker/Moby xung đột ==="
        official_packages=(
            docker-ce docker-ce-cli containerd.io docker-buildx-plugin
            docker-compose-plugin docker-ce-rootless-extras
        )
        distro_packages=(
            docker.io docker-doc docker-compose docker-compose-v2 docker-buildx
            podman-docker containerd runc moby-engine moby-cli moby-buildx
            moby-compose moby-containerd moby-runc
        )

        # Purge các package Docker CE bị cài dở sau lỗi mã 100.
        apt-get purge -y "${official_packages[@]}" || true
        installed_distro_packages=()
        for pkg in "${distro_packages[@]}"; do
            if dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null \
                | grep -q 'install ok installed'; then
                installed_distro_packages+=("${pkg}")
            fi
        done
        if ((${#installed_distro_packages[@]} > 0)); then
            apt-get remove -y "${installed_distro_packages[@]}" || true
        fi
        dpkg --configure -a || true
        apt-get -f install -y || true

        apt-get update
        apt-get install -y ca-certificates curl gnupg lsb-release

        echo ""
        echo "=== Cấu hình Docker official stable repository ==="
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
            -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
        rm -f /etc/apt/sources.list.d/docker.sources \
              /etc/apt/sources.list.d/docker.list

        docker_arch="$(dpkg --print-architecture)"
        ubuntu_codename="$(lsb_release -cs)"
        tee /etc/apt/sources.list.d/docker.sources > /dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${ubuntu_codename}
Components: stable
Architectures: ${docker_arch}
Signed-By: /etc/apt/keyrings/docker.asc
EOF
        apt-get update

        echo ""
        echo "=== Cài Docker CE, CLI, Containerd, Buildx và Compose ==="
        : > "${DOCKER_APT_LOG}"
        if ! apt-get install -y --no-install-recommends \
            docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
            2>&1 | tee "${DOCKER_APT_LOG}"; then
            echo "Docker CE cài thất bại; đang phục hồi package và chuyển sang fallback Ubuntu."
            apt-get purge -y "${official_packages[@]}" || true
            dpkg --configure -a || true
            apt-get -f install -y || true
            apt-get update
            apt-get install -y docker.io docker-compose-v2
        fi
    fi

    if ! command -v docker > /dev/null 2>&1; then
        echo "Không tìm thấy Docker CLI sau khi cài đặt."
        exit 1
    fi
    if ! docker compose version > /dev/null 2>&1; then
        echo "Không tìm thấy Docker Compose sau khi cài đặt."
        exit 1
    fi

    if ! getent group docker > /dev/null; then
        groupadd docker
    fi
    if [[ -n "${INSTALL_USER}" && "${INSTALL_USER}" != "root" ]] \
        && id "${INSTALL_USER}" > /dev/null 2>&1; then
        usermod -aG docker "${INSTALL_USER}"
        echo "Đã thêm ${INSTALL_USER} vào group docker. Quyền mới có hiệu lực sau khi đăng nhập lại."
    fi

    echo ""
    echo "=== Kiểm tra Docker daemon ==="
    if docker info > /dev/null 2>&1; then
        echo "Docker daemon đang hoạt động."
    else
        if command -v systemctl > /dev/null 2>&1; then
            systemctl enable --now docker 2>/dev/null || true
        fi
        if ! docker info > /dev/null 2>&1 && command -v service > /dev/null 2>&1; then
            service docker start 2>/dev/null || true
        fi
        if ! docker info > /dev/null 2>&1 && command -v dockerd > /dev/null 2>&1; then
            echo "Đang thử khởi động Docker daemon trực tiếp..."
            nohup dockerd > /tmp/windowsghcs-dockerd.log 2>&1 &
            dockerd_pid=$!
            for _ in {1..30}; do
                if docker info > /dev/null 2>&1; then
                    break
                fi
                if ! kill -0 "${dockerd_pid}" 2>/dev/null; then
                    break
                fi
                sleep 1
            done
        fi
    fi

    docker --version
    docker compose version
    if ! docker info > /dev/null 2>&1; then
        echo "Docker CLI/Compose đã cài nhưng Docker daemon chưa chạy hoặc Codespace không cấp quyền daemon."
        exit 1
    fi
    echo "Đã cài và kiểm tra Docker thành công."
}

check_kvm() {
    echo ""
    echo "=== Kiểm tra KVM ==="
    if [[ ! -e /dev/kvm ]]; then
        echo "Không tìm thấy /dev/kvm. Host/Codespace chưa cấp KVM hoặc nested virtualization."
        echo "Windows container sẽ không chạy được; hãy dùng máy/runner có KVM rồi chạy lại."
        exit 1
    fi
    if [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
        echo "Không có quyền đọc/ghi /dev/kvm dù thiết bị đã tồn tại."
        echo "Hãy chạy trong môi trường có quyền KVM hoặc điều chỉnh quyền thiết bị."
        exit 1
    fi
    echo "KVM khả dụng."
}

check_kvm_for_proxmox() {
    echo ""
    echo "=== Kiểm tra accelerator QEMU ==="
    if [[ -e /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
        QEMU_ACCELERATOR="kvm"
        echo "KVM khả dụng; sẽ dùng -cpu host và -enable-kvm."
    else
        QEMU_ACCELERATOR="tcg"
        echo "KVM không khả dụng; sẽ dùng TCG fallback (-cpu max)."
        echo "Proxmox có thể chạy chậm hơn trong Codespace không hỗ trợ nested virtualization."
    fi
}

mount_storage() {
    echo ""
    echo "=== Kiểm tra storage tại /mnt ==="
    mkdir -p /mnt

    if { command -v findmnt > /dev/null 2>&1 && findmnt -rn -M /mnt > /dev/null 2>&1; } \
        || { command -v mountpoint > /dev/null 2>&1 && mountpoint -q /mnt; }; then
        echo "Một phân vùng đã được mount trực tiếp vào /mnt."
    else
        echo "Chưa có phân vùng riêng tại /mnt; đang tìm phân vùng trống lớn hơn 500GB..."
        target_partition="$(lsblk -b -nrpo NAME,SIZE,TYPE,MOUNTPOINT 2>/dev/null \
            | awk '$2 > 500000000000 && $3 == "part" && $4 == "" {print $1; exit}')"

        if [[ -z "${target_partition}" ]]; then
            disk="$(lsblk -b -nrpo NAME,SIZE,TYPE,MOUNTPOINT 2>/dev/null \
                | awk '$2 > 500000000000 && $3 == "disk" && $4 == "" {print $1; exit}')"
            if [[ -n "${disk}" ]]; then
                target_partition="$(lsblk -nrpo NAME,TYPE "${disk}" \
                    | awk '$2 == "part" {print $1; exit}')"
            fi
        fi

        if [[ -n "${target_partition}" ]]; then
            echo "Đã tìm thấy phân vùng: ${target_partition}"
            mount "${target_partition}" /mnt
            echo "Đã mount ${target_partition} vào /mnt."
        else
            echo "Không tìm thấy phân vùng riêng trên 500GB."
            echo "Sử dụng thư mục /mnt hiện có; Codespaces thường dùng storage trong container."
        fi
    fi

    if [[ ! -d /mnt || ! -w /mnt ]]; then
        echo "/mnt không tồn tại hoặc không có quyền ghi."
        exit 1
    fi
    available_kb="$(df -Pk /mnt | awk 'NR == 2 {print $4}')"
    if [[ ! "${available_kb}" =~ ^[0-9]+$ ]] || ((available_kb < MIN_FREE_KB)); then
        echo "Dung lượng trống tại /mnt thấp hơn 10GiB; không đủ an toàn để tải ISO."
        exit 1
    fi
    echo "Dung lượng trống tại /mnt đủ để tiếp tục."
}

download_file() {
    local url="$1"
    local destination="$2"
    local temporary_file

    temporary_file="$(mktemp "${destination}.part.XXXXXX")"
    if command -v curl > /dev/null 2>&1; then
        if ! curl -fL --retry 3 --retry-delay 5 --progress-bar \
            "${url}" -o "${temporary_file}"; then
            rm -f "${temporary_file}"
            return 1
        fi
    elif command -v wget > /dev/null 2>&1; then
        if ! wget --tries=3 --waitretry=5 --show-progress \
            -O "${temporary_file}" "${url}"; then
            rm -f "${temporary_file}"
            return 1
        fi
    else
        rm -f "${temporary_file}"
        echo "Cần curl hoặc wget để tải ${url}." >&2
        return 1
    fi
    mv -f "${temporary_file}" "${destination}"
}

validate_iso_file() {
    local path="$1"
    local size_bytes
    size_bytes="$(stat -c '%s' "${path}" 2>/dev/null || echo 0)"
    if ((size_bytes < 10 * 1024 * 1024)); then
        echo "File ISO có kích thước bất thường hoặc tải chưa hoàn tất: ${path}"
        return 1
    fi
}

download_isos() {
    local windows_iso_url="$1"
    local windows_created=0

    if [[ -e "${WINDOWS_ISO_PATH}" ]]; then
        echo "Đã tồn tại ${WINDOWS_ISO_PATH}; giữ nguyên và không ghi đè."
        if ! validate_iso_file "${WINDOWS_ISO_PATH}"; then
            echo "custom.iso hiện có không hợp lệ hoặc tải dở. Hãy xóa file này rồi chạy lại với link ISO mới."
            exit 1
        fi
    else
        if [[ -z "${windows_iso_url}" ]]; then
            echo "Chưa có custom.iso và chưa cung cấp link Windows ISO."
            exit 1
        fi
        echo ""
        echo "=== Tải Windows ISO ==="
        echo "Đang tải Windows ISO vào ${WINDOWS_ISO_PATH}..."
        if ! download_file "${windows_iso_url}" "${WINDOWS_ISO_PATH}"; then
            echo "Không thể tải Windows ISO."
            exit 1
        fi
        windows_created=1
        if ! validate_iso_file "${WINDOWS_ISO_PATH}"; then
            rm -f "${WINDOWS_ISO_PATH}"
            exit 1
        fi
    fi

    if [[ -e "${DRIVER_ISO_PATH}" ]]; then
        echo "driver.iso đã tồn tại, đang kiểm tra file hiện có."
        if ! validate_iso_file "${DRIVER_ISO_PATH}"; then
            echo "driver.iso hiện có không hợp lệ. Hãy xóa file này hoặc tạo Codespace mới rồi chạy lại."
            exit 1
        fi
        echo "driver.iso hợp lệ, giữ nguyên file hiện có."
    else
        echo "Đang tải VirtIO driver ISO vào ${DRIVER_ISO_PATH}..."
        if ! download_file "${DRIVER_ISO_URL}" "${DRIVER_ISO_PATH}"; then
            [[ "${windows_created}" == "1" ]] && rm -f "${WINDOWS_ISO_PATH}"
            echo "Không thể tải VirtIO driver ISO; đã xóa Windows ISO mới tải để có thể chạy lại an toàn."
            exit 1
        fi
        if ! validate_iso_file "${DRIVER_ISO_PATH}"; then
            rm -f "${DRIVER_ISO_PATH}"
            [[ "${windows_created}" == "1" ]] && rm -f "${WINDOWS_ISO_PATH}"
            exit 1
        fi
    fi
    echo "Đã tải và kiểm tra xong hai file ISO."
}

proxmox_tools_ready() {
    local qemu_ready=0
    local novnc_ready=0
    local ovmf_ready=0

    if command -v kvm > /dev/null 2>&1 || command -v qemu-system-x86_64 > /dev/null 2>&1; then
        qemu_ready=1
    fi
    if command -v novnc_proxy > /dev/null 2>&1 \
        || [[ -x /usr/share/novnc/utils/novnc_proxy ]] \
        || [[ -x /usr/share/novnc/utils/novnc_proxy.py ]]; then
        novnc_ready=1
    fi
    if ! command -v fuser > /dev/null 2>&1; then
        return 1
    fi
    if [[ -f /usr/share/OVMF/OVMF_CODE_4M.fd \
        || -f /usr/share/OVMF/OVMF_CODE.fd \
        || -f /usr/share/ovmf/OVMF.fd ]]; then
        ovmf_ready=1
    fi

    [[ "${qemu_ready}" == "1" \
        && "${novnc_ready}" == "1" \
        && "${ovmf_ready}" == "1" ]] \
        && command -v qemu-img > /dev/null 2>&1 \
        && command -v cpulimit > /dev/null 2>&1
}

install_proxmox_packages() {
    if proxmox_tools_ready; then
        echo ""
        echo "=== QEMU/KVM, OVMF và noVNC đã sẵn sàng ==="
        echo "Bỏ qua cài package; chạy tiếp với các file/ổ đĩa hiện có."
        return 0
    fi

    echo ""
    echo "=== Cài package Proxmox/QEMU/KVM ==="
    apt-get update
    qemu_packages=(qemu-system-x86 qemu-utils unzip cpulimit python3-pip ovmf novnc websockify psmisc)
    if apt-cache show qemu-kvm > /dev/null 2>&1; then
        qemu_packages+=(qemu-kvm)
    fi
    apt-get install -y "${qemu_packages[@]}"

    if ! command -v qemu-img > /dev/null 2>&1; then
        echo "Không tìm thấy qemu-img sau khi cài qemu-utils."
        exit 1
    fi
    if ! command -v cpulimit > /dev/null 2>&1; then
        echo "Không tìm thấy cpulimit sau khi cài đặt."
        exit 1
    fi
}

find_ovmf() {
    if [[ -f /usr/share/OVMF/OVMF_CODE_4M.fd ]]; then
        OVMF_CODE_PATH="/usr/share/OVMF/OVMF_CODE_4M.fd"
        if [[ -f /usr/share/OVMF/OVMF_VARS_4M.ms.fd ]]; then
            OVMF_VARS_TEMPLATE="/usr/share/OVMF/OVMF_VARS_4M.ms.fd"
        else
            OVMF_VARS_TEMPLATE="/usr/share/OVMF/OVMF_VARS_4M.fd"
        fi
    elif [[ -f /usr/share/OVMF/OVMF_CODE.fd ]]; then
        OVMF_CODE_PATH="/usr/share/OVMF/OVMF_CODE.fd"
        if [[ -f /usr/share/OVMF/OVMF_VARS.ms.fd ]]; then
            OVMF_VARS_TEMPLATE="/usr/share/OVMF/OVMF_VARS.ms.fd"
        else
            OVMF_VARS_TEMPLATE="/usr/share/OVMF/OVMF_VARS.fd"
        fi
    elif [[ -f /usr/share/ovmf/OVMF.fd ]]; then
        OVMF_CODE_PATH="/usr/share/ovmf/OVMF.fd"
        OVMF_VARS_TEMPLATE=""
    else
        echo "Không tìm thấy firmware OVMF sau khi cài package ovmf."
        exit 1
    fi

    OVMF_VARS_PATH="/mnt/proxmox-ovmf-vars.fd"
    if [[ -n "${OVMF_VARS_TEMPLATE}" && -f "${OVMF_VARS_TEMPLATE}" ]]; then
        if [[ ! -e "${OVMF_VARS_PATH}" ]]; then
            cp "${OVMF_VARS_TEMPLATE}" "${OVMF_VARS_PATH}"
        fi
    fi
}

download_proxmox_iso() {
    echo ""
    echo "=== Chuẩn bị Proxmox VE ISO ==="
    if [[ -e "${PROXMOX_ISO_PATH}" ]]; then
        echo "Đã tìm thấy ${PROXMOX_ISO_PATH}; đang kiểm tra SHA256..."
    else
        echo "Đang tải Proxmox VE 9.2-1 ISO..."
        download_file "${PROXMOX_ISO_URL}" "${PROXMOX_ISO_PATH}"
    fi

    if ! validate_iso_file "${PROXMOX_ISO_PATH}"; then
        rm -f "${PROXMOX_ISO_PATH}"
        echo "Proxmox ISO không hợp lệ hoặc tải chưa hoàn tất."
        exit 1
    fi
    if ! printf '%s  %s\n' "${PROXMOX_ISO_SHA256}" "${PROXMOX_ISO_PATH}" \
        | sha256sum -c - > /dev/null 2>&1; then
        echo "SHA256 Proxmox ISO không khớp. Đang xóa file để tránh dùng ISO hỏng."
        rm -f "${PROXMOX_ISO_PATH}"
        exit 1
    fi
    echo "Proxmox ISO hợp lệ."
}

install_proxmox_auto_install_assistant() {
    if command -v proxmox-auto-install-assistant > /dev/null 2>&1; then
        return 0
    fi

    echo "=== Cài Proxmox Automated Install Assistant ==="
    apt-get install -y xorriso openssl

    local package_index package_block package_filename package_sha256 package_deb
    package_index="$(mktemp)"
    package_deb="$(mktemp --suffix=.deb)"
    download_file \
        "http://download.proxmox.com/debian/pve/dists/trixie/pve-no-subscription/binary-amd64/Packages.gz" \
        "${package_index}"
    package_block="$(gzip -dc "${package_index}" \
        | awk '
            /^Package: proxmox-auto-install-assistant$/ { found=1 }
            found { print }
            found && /^$/ { found=0 }
        ')"
    rm -f "${package_index}"
    package_filename="$(printf '%s\n' "${package_block}" \
        | sed -n 's/^Filename: //p' | head -n 1)"
    package_sha256="$(printf '%s\n' "${package_block}" \
        | sed -n 's/^SHA256: //p' | head -n 1)"
    if [[ -z "${package_filename}" || ! "${package_sha256}" =~ ^[0-9a-fA-F]{64}$ ]]; then
        echo "Không tìm thấy metadata hợp lệ của proxmox-auto-install-assistant." >&2
        rm -f "${package_deb}"
        exit 1
    fi
    download_file "http://download.proxmox.com/debian/pve/${package_filename}" "${package_deb}"
    if ! printf '%s  %s\n' "${package_sha256}" "${package_deb}" \
        | sha256sum -c - > /dev/null 2>&1; then
        echo "SHA256 proxmox-auto-install-assistant không khớp." >&2
        rm -f "${package_deb}"
        exit 1
    fi
    dpkg -i "${package_deb}" || apt-get -f install -y
    rm -f "${package_deb}"
    command -v proxmox-auto-install-assistant > /dev/null 2>&1 || {
        echo "Cài proxmox-auto-install-assistant thất bại." >&2
        exit 1
    }
}

prepare_proxmox_auto_install_iso() {
    PROXMOX_ISO_BOOT_PATH="${PROXMOX_ISO_PATH}"
    if [[ "${PROXMOX_AUTO_INSTALL}" != "1" ]]; then
        echo "PROXMOX_AUTO_INSTALL=${PROXMOX_AUTO_INSTALL}; dùng cài đặt Proxmox thủ công."
        return 0
    fi
    if [[ -e "${PROXMOX_AUTO_ISO_PATH}" ]]; then
        echo "Đã tìm thấy auto-install ISO ${PROXMOX_AUTO_ISO_PATH}; giữ nguyên."
        validate_iso_file "${PROXMOX_AUTO_ISO_PATH}"
        PROXMOX_ISO_BOOT_PATH="${PROXMOX_AUTO_ISO_PATH}"
        return 0
    fi

    read_proxmox_root_password
    install_proxmox_auto_install_assistant

    local root_password_hash escaped_fqdn escaped_country escaped_timezone
    root_password_hash="$(printf '%s\n' "${PROXMOX_ROOT_PASSWORD}" \
        | openssl passwd -6 -stdin)"
    escaped_fqdn="${PROXMOX_FQDN//\\/\\\\}"
    escaped_fqdn="${escaped_fqdn//\"/\\\"}"
    escaped_country="${PROXMOX_COUNTRY//\"/\\\"}"
    escaped_timezone="${PROXMOX_TIMEZONE//\"/\\\"}"

    cat > "${PROXMOX_ANSWER_PATH}" <<EOF
[global]
keyboard = "us"
country = "${escaped_country}"
fqdn = "${escaped_fqdn}"
timezone = "${escaped_timezone}"
root-password-hashed = "${root_password_hash}"
mailto = "root@${escaped_fqdn}"
reboot-mode = "reboot"

[network]
source = "from-dhcp"

[disk-setup]
filesystem = "ext4"
disk-list = ["sda"]

[first-boot]
source = "from-iso"
ordering = "fully-up"
EOF
    chmod 600 "${PROXMOX_ANSWER_PATH}"

    cat > "${PROXMOX_FIRST_BOOT_PATH}" <<'EOF'
#!/bin/sh
set -eu

FQDN="__PROXMOX_FQDN__"
TIMEZONE="__PROXMOX_TIMEZONE__"

hostnamectl set-hostname "${FQDN}" 2>/dev/null || true
printf '%s\n' "${FQDN}" > /etc/hostname
if ! grep -Eq "(^|[[:space:]])${FQDN}([[:space:]]|$)" /etc/hosts; then
    printf '127.0.1.1 %s %s\n' "${FQDN}" "${FQDN%%.*}" >> /etc/hosts
fi
timedatectl set-timezone "${TIMEZONE}" 2>/dev/null || true
localectl set-keymap us 2>/dev/null || true

for source in /etc/apt/sources.list.d/pve-enterprise.sources \
              /etc/apt/sources.list.d/pve-enterprise.list; do
    if [ -f "${source}" ]; then
        mv "${source}" "${source}.disabled"
    fi
done
if [ -f /etc/apt/sources.list.d/ceph.sources ]; then
    mv /etc/apt/sources.list.d/ceph.sources \
       /etc/apt/sources.list.d/ceph.sources.disabled
fi

cat > /etc/apt/sources.list.d/proxmox.sources <<'REPO'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
REPO

apt-get update
EOF
    sed -i \
        -e "s|__PROXMOX_FQDN__|${escaped_fqdn}|g" \
        -e "s|__PROXMOX_TIMEZONE__|${escaped_timezone}|g" \
        "${PROXMOX_FIRST_BOOT_PATH}"
    chmod 700 "${PROXMOX_FIRST_BOOT_PATH}"

    echo "=== Tạo Proxmox unattended ISO ==="
    proxmox-auto-install-assistant prepare-iso \
        "${PROXMOX_ISO_PATH}" \
        --fetch-from iso \
        --answer-file "${PROXMOX_ANSWER_PATH}" \
        --on-first-boot "${PROXMOX_FIRST_BOOT_PATH}" \
        --output "${PROXMOX_AUTO_ISO_PATH}"
    validate_iso_file "${PROXMOX_AUTO_ISO_PATH}"
    PROXMOX_ISO_BOOT_PATH="${PROXMOX_AUTO_ISO_PATH}"
    echo "Auto-install ISO đã sẵn sàng: ${PROXMOX_ISO_BOOT_PATH}"
}

ensure_proxmox_disk() {
    local requested_bytes current_bytes
    echo ""
    echo "=== Chuẩn bị ổ đĩa Proxmox ==="
    requested_bytes="$(numfmt --from=iec "${PROXMOX_DISK_SIZE}" 2>/dev/null || echo 0)"
    if [[ ! "${requested_bytes}" =~ ^[0-9]+$ || "${requested_bytes}" -le 0 ]]; then
        echo "PROXMOX_DISK_SIZE không hợp lệ: ${PROXMOX_DISK_SIZE}"
        exit 1
    fi

    if [[ -e "${PROXMOX_DISK_PATH}" ]]; then
        current_bytes="$(qemu-img info --output=json "${PROXMOX_DISK_PATH}" 2>/dev/null \
            | tr -d '[:space:]' \
            | sed -n 's/.*"virtual-size":\([0-9][0-9]*\).*/\1/p')"
        if [[ "${current_bytes}" =~ ^[0-9]+$ ]] \
            && ((current_bytes < requested_bytes)); then
            echo "Ổ hiện tại nhỏ hơn ${PROXMOX_DISK_SIZE}; đang mở rộng an toàn..."
            qemu-img resize "${PROXMOX_DISK_PATH}" "${PROXMOX_DISK_SIZE}"
        elif [[ "${current_bytes}" =~ ^[0-9]+$ ]] \
            && ((current_bytes > requested_bytes)); then
            echo "Ổ hiện tại lớn hơn ${PROXMOX_DISK_SIZE}; giữ nguyên, không thu nhỏ để tránh mất dữ liệu."
        else
            echo "Đã tồn tại ${PROXMOX_DISK_PATH}; giữ nguyên để không mất dữ liệu."
        fi
        qemu-img info "${PROXMOX_DISK_PATH}" > /dev/null
    else
        echo "Tạo raw disk ${PROXMOX_DISK_PATH} với dung lượng ${PROXMOX_DISK_SIZE}..."
        qemu-img create -f raw "${PROXMOX_DISK_PATH}" "${PROXMOX_DISK_SIZE}"
    fi
}

wait_for_tcp_port() {
    local port="$1"
    local timeout_seconds="${2:-30}"
    local elapsed=0
    while ((elapsed < timeout_seconds)); do
        if ss -ltn 2>/dev/null \
            | awk '{print $4}' \
            | grep -Eq "(^|:)${port}$"; then
            return 0
        fi
        sleep 1
        ((elapsed += 1))
    done
    return 1
}

start_novnc() {
    local novnc_proxy=""
    if command -v novnc_proxy > /dev/null 2>&1; then
        novnc_proxy="$(command -v novnc_proxy)"
    elif [[ -x /usr/share/novnc/utils/novnc_proxy ]]; then
        novnc_proxy="/usr/share/novnc/utils/novnc_proxy"
    elif [[ -x /usr/share/novnc/utils/novnc_proxy.py ]]; then
        novnc_proxy="/usr/share/novnc/utils/novnc_proxy.py"
    fi

    if [[ -z "${novnc_proxy}" ]]; then
        echo "Không tìm thấy novnc_proxy sau khi cài noVNC/websockify."
        exit 1
    fi
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${NOVNC_PORT}$"; then
        echo "Cổng ${NOVNC_PORT} đang được sử dụng; không thể khởi động noVNC."
        exit 1
    fi

    echo "Khởi động noVNC: --listen ${NOVNC_PORT} --vnc localhost:5900"
    nohup "${novnc_proxy}" --listen "${NOVNC_PORT}" --vnc localhost:5900 \
        > "${PROXMOX_NOVNC_LOG}" 2>&1 &
    NOVNC_PID=$!
    sleep 2
    if ! kill -0 "${NOVNC_PID}" 2>/dev/null; then
        echo "noVNC không khởi động được."
        tail -n 30 "${PROXMOX_NOVNC_LOG}" 2>/dev/null || true
        exit 1
    fi
    if ! wait_for_tcp_port "${NOVNC_PORT}" 30; then
        echo "noVNC process còn chạy nhưng cổng ${NOVNC_PORT} chưa mở."
        tail -n 40 "${PROXMOX_NOVNC_LOG}" 2>/dev/null || true
        exit 1
    fi
    echo "noVNC đang chạy với PID ${NOVNC_PID}; mở cổng ${NOVNC_PORT}."
}

stop_port_range_5900_5999() {
    local protocol port pid pids
    for protocol in tcp udp; do
        for ((port = 5900; port <= 5999; port++)); do
            pids="$(fuser -n "${protocol}" "${port}" 2>/dev/null || true)"
            for pid in ${pids}; do
                [[ "${pid}" =~ ^[0-9]+$ ]] || continue
                [[ "${pid}" == "$$" || "${pid}" == "${PPID}" ]] && continue
                echo "Dừng PID ${pid} đang giữ ${protocol}/${port}."
                kill "${pid}" 2>/dev/null || true
            done
        done
    done
    sleep 1

    for protocol in tcp udp; do
        for ((port = 5900; port <= 5999; port++)); do
            pids="$(fuser -n "${protocol}" "${port}" 2>/dev/null || true)"
            for pid in ${pids}; do
                [[ "${pid}" =~ ^[0-9]+$ ]] || continue
                [[ "${pid}" == "$$" || "${pid}" == "${PPID}" ]] && continue
                if kill -0 "${pid}" 2>/dev/null; then
                    echo "Buộc dừng PID ${pid} còn giữ ${protocol}/${port}."
                    kill -KILL "${pid}" 2>/dev/null || true
                fi
            done
        done
    done
}

stop_stale_processes() {
    stop_port_range_5900_5999
    local pattern pid
    local patterns=(
        "novnc_proxy.*--listen[[:space:]]+${NOVNC_PORT}.*--vnc[[:space:]]+localhost:5900"
        'qemu.*proxmox-ve_9\.2-1\.iso'
        'qemu.*dockerghcs-proxmox'
        'cpulimit.*qemu.*a\.img'
    )

    for pattern in "${patterns[@]}"; do
        while read -r pid; do
            [[ -z "${pid}" || "${pid}" == "$$" || "${pid}" == "${PPID}" ]] && continue
            echo "Dừng tiến trình cũ PID ${pid}: ${pattern}"
            kill "${pid}" 2>/dev/null || true
        done < <(pgrep -f "${pattern}" 2>/dev/null || true)
    done
    sleep 1
}

cleanup_proxmox() {
    if [[ -n "${NOVNC_PID:-}" ]] && kill -0 "${NOVNC_PID}" 2>/dev/null; then
        kill "${NOVNC_PID}" 2>/dev/null || true
    fi
    if [[ -n "${QEMU_PID:-}" ]] && kill -0 "${QEMU_PID}" 2>/dev/null; then
        kill "${QEMU_PID}" 2>/dev/null || true
    fi
}

start_proxmox() {
    trap cleanup_proxmox EXIT
    trap 'cleanup_proxmox; exit 130' INT
    trap 'cleanup_proxmox; exit 143' TERM
    install_proxmox_packages
    stop_stale_processes
    check_kvm_for_proxmox
    mount_storage
    download_proxmox_iso
    prepare_proxmox_auto_install_iso
    ensure_proxmox_disk
    find_ovmf

    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq '(^|:)5900$'; then
        echo "Cổng 5900 đang được sử dụng; hãy dừng VNC process cũ trước khi chạy Proxmox."
        exit 1
    fi

    local cpu_flags="host"
    local qemu_accel_args=(-accel "${QEMU_ACCELERATOR}")
    if [[ "${QEMU_ACCELERATOR}" == "tcg" ]]; then
        cpu_flags="max"
        echo "QEMU sẽ dùng CPU model max với TCG fallback."
    else
        echo "QEMU sẽ dùng CPU model host với KVM."
    fi

    local qemu_bin=""
    if command -v qemu-system-x86_64 > /dev/null 2>&1; then
        qemu_bin="$(command -v qemu-system-x86_64)"
    elif command -v kvm > /dev/null 2>&1; then
        qemu_bin="$(command -v kvm)"
    else
        echo "Không tìm thấy kvm hoặc qemu-system-x86_64."
        exit 1
    fi

    local pflash_args=(
        -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE_PATH}"
    )
    if [[ -n "${OVMF_VARS_TEMPLATE}" && -e "${OVMF_VARS_PATH}" ]]; then
        pflash_args+=(
            -drive "if=pflash,format=raw,readonly=off,file=${OVMF_VARS_PATH}"
        )
    elif [[ -n "${OVMF_VARS_TEMPLATE}" && -f "${OVMF_VARS_TEMPLATE}" ]]; then
        pflash_args=(
            -drive "if=pflash,format=raw,readonly=off,file=${OVMF_VARS_PATH}"
        )
    else
        pflash_args=(
            -bios "${OVMF_CODE_PATH}"
        )
    fi

    echo ""
    echo "=== Khởi động Proxmox qua QEMU/KVM ==="
    echo "Phương án 2: hostfwd host:${PROXMOX_GUEST_PORT} -> guest:8006; NIC virtio dùng QEMU user-mode IPv4, DNS 10.0.2.3 và tắt IPv6 để ổn định truy cập repository."
    : > "${PROXMOX_QEMU_LOG}"
    printf 'qemu=%s\naccel=%s\ncpu=%s\ndisk=%s\niso=%s\n' \
        "${qemu_bin}" "${QEMU_ACCELERATOR}" "${cpu_flags}" \
        "${PROXMOX_DISK_PATH}" "${PROXMOX_ISO_PATH}" \
        >> "${PROXMOX_QEMU_LOG}"
    # Boot từ CD-ROM Proxmox ISO để cài đặt; sau khi cài xong có thể đổi thành -boot c.
    # PipeWire không cần thiết cho Proxmox; tắt audio để thiếu client.conf không làm QEMU lỗi.
    QEMU_AUDIO_DRV=none "${qemu_bin}" \
        "${qemu_accel_args[@]}" \
        -cpu "${cpu_flags}" \
        -smp 2,cores=2 \
        -M q35,usb=on \
        -device usb-tablet \
        -m 8G \
        -device virtio-balloon-pci \
        -vga virtio \
        -netdev "user,id=n0,ipv4=on,ipv6=off,dns=10.0.2.3,hostfwd=tcp::${PROXMOX_GUEST_PORT}-:8006" \
        -device virtio-net-pci,netdev=n0 \
        -boot menu=on,once=d \
        -device virtio-serial-pci \
        -device virtio-rng-pci \
        -audiodev driver=none,id=noaudio \
        -drive "file=${PROXMOX_DISK_PATH},format=raw" \
        "${pflash_args[@]}" \
        -cdrom "${PROXMOX_ISO_BOOT_PATH}" \
        -uuid e47ddb84-fb4d-46f9-b531-14bb15156336 \
        -vnc 127.0.0.1:0 \
        > "${PROXMOX_QEMU_LOG}" 2>&1 &
    QEMU_PID=$!
    sleep 2
    if ! kill -0 "${QEMU_PID}" 2>/dev/null; then
        echo "QEMU/Proxmox không khởi động được."
        tail -n 80 "${PROXMOX_QEMU_LOG}" 2>/dev/null || true
        exit 1
    fi
    if ! wait_for_tcp_port 5900 "${QEMU_VNC_TIMEOUT}"; then
        echo "QEMU process vẫn tồn tại nhưng VNC localhost:5900 chưa mở."
        tail -n 80 "${PROXMOX_QEMU_LOG}" 2>/dev/null || true
        kill "${QEMU_PID}" 2>/dev/null || true
        exit 1
    fi
    echo "QEMU/Proxmox đang chạy với PID ${QEMU_PID}; VNC nội bộ localhost:5900."
    start_novnc
    echo "noVNC: cổng ${NOVNC_PORT}; Proxmox hostfwd: cổng ${PROXMOX_GUEST_PORT} -> guest:8006."
    echo "Paste không cần clipboard hệ điều hành: mở panel Clipboard trong noVNC, nhập text rồi bấm Send."
    echo "Clipboard chỉ được dùng khi bạn chủ động Copy/Send nội dung trong panel noVNC."
    wait "${QEMU_PID}"
}

download_compose_file() {
    local url="$1"
    local destination="$2"
    local temporary_file

    temporary_file="$(mktemp "${destination}.part.XXXXXX")"
    echo "Không tìm thấy ${destination}; đang tải từ raw GitHub..."
    if command -v curl > /dev/null 2>&1; then
        if ! curl -fL --retry 3 --retry-delay 2 --progress-bar "${url}" -o "${temporary_file}"; then
            rm -f "${temporary_file}"
            echo "Không thể tải ${url}"
            exit 1
        fi
    elif command -v wget > /dev/null 2>&1; then
        if ! wget --progress=dot:giga -O "${temporary_file}" "${url}"; then
            rm -f "${temporary_file}"
            echo "Không thể tải ${url}"
            exit 1
        fi
    else
        rm -f "${temporary_file}"
        echo "Cần curl hoặc wget để tải file cấu hình Docker Compose."
        exit 1
    fi

    if [[ ! -s "${temporary_file}" ]] || ! grep -q '^services:' "${temporary_file}"; then
        rm -f "${temporary_file}"
        echo "File YAML tải về không hợp lệ: ${url}"
        exit 1
    fi
    mv -f "${temporary_file}" "${destination}"
    echo "Đã tải ${destination}."
}

ensure_compose_file() {
    [[ "${OS_NAME}" == "Proxmox" ]] && return 0
    if [[ -f "${COMPOSE_FILE}" ]]; then
        return 0
    fi

    case "${OS_NAME}" in
        Windows)
            download_compose_file "${WINDOWS_YAML_URL}" "${COMPOSE_FILE}"
            ;;
        macOS)
            download_compose_file "${MACOS_YAML_URL}" "${COMPOSE_FILE}"
            ;;
        *)
            echo "Không xác định được hệ điều hành đã chọn: ${OS_NAME}"
            exit 1
            ;;
    esac
}

select_os() {
    echo ""
    echo "=== Chọn hệ điều hành cần cài ==="
    echo "1) Windows"
    echo "2) macOS"
    echo "3) Proxmox (QEMU/KVM)"
    while true; do
        read -r -p "Hãy nhập 1 để cài Windows, 2 để cài macOS hoặc 3 để cài Proxmox: " os_choice
        case "${os_choice}" in
            1)
                OS_NAME="Windows"
                COMPOSE_FILE="${SCRIPT_DIR}/windows.yaml"
                break
                ;;
            2)
                OS_NAME="macOS"
                COMPOSE_FILE="${SCRIPT_DIR}/macos.yaml"
                break
                ;;
            3)
                OS_NAME="Proxmox"
                COMPOSE_FILE=""
                break
                ;;
            *)
                echo "Lựa chọn không hợp lệ. Vui lòng nhập 1, 2 hoặc 3."
                ;;
        esac
    done

}

select_os
ensure_compose_file

if [[ "${OS_NAME}" == "Proxmox" ]]; then
    start_proxmox
    exit 0
fi

install_docker
check_kvm
mount_storage

if [[ "${OS_NAME}" == "Windows" ]]; then
    if [[ -e "${WINDOWS_ISO_PATH}" ]]; then
        echo "Đã có ${WINDOWS_ISO_PATH}; bỏ qua hỏi link và tải lại Windows ISO."
        download_isos ""
    else
        echo ""
        read -r -p "Bạn muốn cài bản Windows nào? Hãy dán link ISO Windows mà bạn muốn: " windows_iso_url
        windows_iso_url="${windows_iso_url//$'\r'/}"
        if [[ -z "${windows_iso_url}" ]]; then
            echo "Link ISO không được để trống."
            exit 1
        fi
        if [[ "${windows_iso_url}" != http://* && "${windows_iso_url}" != https://* ]]; then
            echo "Link ISO phải bắt đầu bằng http:// hoặc https://."
            exit 1
        fi
        download_isos "${windows_iso_url}"
    fi
else
    echo ""
    echo "Đã chọn macOS. macos.yaml không dùng USERNAME/PASSWORD và không cần Windows ISO."
    echo "Lần khởi động đầu tiên sẽ tải bộ cài macOS từ dockur/macos."
fi

cd "${SCRIPT_DIR}"
echo ""
echo "=== Kiểm tra Docker Compose cho ${OS_NAME} ==="
docker compose -f "${COMPOSE_FILE}" config -q
echo "=== Dừng container/tiến trình cũ của ${OS_NAME} ==="
docker compose -f "${COMPOSE_FILE}" down --remove-orphans || true
echo "=== Khởi động Docker Compose cho ${OS_NAME} ==="
echo "Chạy lệnh 1: docker compose -f ${COMPOSE_FILE} up -d"
docker compose -f "${COMPOSE_FILE}" up -d
echo ""
echo "Chạy lệnh 2: docker compose -f ${COMPOSE_FILE} up"
docker compose -f "${COMPOSE_FILE}" up
