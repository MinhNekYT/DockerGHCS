#!/usr/bin/env bash
set -Eeuo pipefail

# Cài Docker hoặc QEMU/KVM, chuẩn bị ISO và khởi động Windows, macOS hoặc Proxmox.
# Script này được thiết kế cho DockerGHCS trên Ubuntu/GitHub Codespaces có quyền root.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WINDOWS_ISO_PATH="/mnt/custom.iso"
DRIVER_ISO_PATH="/mnt/driver.iso"
DRIVER_ISO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.285-1/virtio-win-0.1.285.iso"
PROXMOX_ISO_PATH="/mnt/proxmox-ve_9.2-1.iso"
PROXMOX_ISO_URL="https://enterprise.proxmox.com/iso/proxmox-ve_9.2-1.iso"
PROXMOX_ISO_SHA256="4e88fe416df9b527624a175f24c9aa07c714d3332afb1ee3dbf3879573ef2c6c"
PROXMOX_DISK_PATH="/mnt/a.img"
PROXMOX_DISK_SIZE="${PROXMOX_DISK_SIZE:-64G}"
MIN_FREE_KB=$((10 * 1024 * 1024))
DOCKER_APT_LOG="/tmp/windowsghcs-docker-apt.log"
PROXMOX_QEMU_LOG="/tmp/dockerghcs-proxmox-qemu.log"
PROXMOX_NOVNC_LOG="/tmp/dockerghcs-proxmox-novnc.log"
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
    for docker_env_name in DOCKER_HOST DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH PROXMOX_DISK_SIZE; do
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
    if ! curl -fL --retry 3 --retry-delay 5 --progress-bar \
        "${url}" -o "${temporary_file}"; then
        rm -f "${temporary_file}"
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
        echo "Đã tồn tại custom.iso trong /mnt."
        echo "Để tránh cài đè bản Windows khác, hãy tạo Codespace mới rồi chạy lại script."
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

install_proxmox_packages() {
    echo ""
    echo "=== Cài package Proxmox/QEMU/KVM ==="
    apt-get update
    qemu_packages=(qemu-system-x86 qemu-utils unzip cpulimit python3-pip ovmf novnc websockify)
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
        OVMF_VARS_TEMPLATE="/usr/share/OVMF/OVMF_VARS_4M.ms.fd"
    elif [[ -f /usr/share/OVMF/OVMF_CODE.fd ]]; then
        OVMF_CODE_PATH="/usr/share/OVMF/OVMF_CODE.fd"
        OVMF_VARS_TEMPLATE="/usr/share/OVMF/OVMF_VARS.ms.fd"
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

ensure_proxmox_disk() {
    echo ""
    echo "=== Chuẩn bị ổ đĩa Proxmox ==="
    if [[ -e "${PROXMOX_DISK_PATH}" ]]; then
        echo "Đã tồn tại ${PROXMOX_DISK_PATH}; giữ nguyên để không mất dữ liệu."
        qemu-img info "${PROXMOX_DISK_PATH}" > /dev/null
    else
        echo "Tạo raw disk ${PROXMOX_DISK_PATH} với dung lượng ${PROXMOX_DISK_SIZE}..."
        qemu-img create -f raw "${PROXMOX_DISK_PATH}" "${PROXMOX_DISK_SIZE}"
    fi
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
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq '(^|:)8006$'; then
        echo "Cổng 8006 đang được sử dụng; không thể khởi động noVNC."
        exit 1
    fi

    echo "Khởi động noVNC: --listen 8006 --vnc localhost:5900"
    nohup "${novnc_proxy}" --listen 8006 --vnc localhost:5900 \
        > "${PROXMOX_NOVNC_LOG}" 2>&1 &
    NOVNC_PID=$!
    sleep 2
    if ! kill -0 "${NOVNC_PID}" 2>/dev/null; then
        echo "noVNC không khởi động được."
        tail -n 30 "${PROXMOX_NOVNC_LOG}" 2>/dev/null || true
        exit 1
    fi
    echo "noVNC đang chạy với PID ${NOVNC_PID}; mở cổng 8006."
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
    check_kvm
    mount_storage
    download_proxmox_iso
    ensure_proxmox_disk
    find_ovmf

    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq '(^|:)5900$'; then
        echo "Cổng 5900 đang được sử dụng; hãy dừng VNC process cũ trước khi chạy Proxmox."
        exit 1
    fi

    local cpu_flags="host,+topoext,hv_relaxed,hv_spinlocks=0x1fff,hv-passthrough,+pae,+nx,kvm=on"
    if grep -qi 'GenuineIntel' /proc/cpuinfo 2>/dev/null; then
        echo "CPU Intel được phát hiện; bỏ +svm vì đây là cờ AMD."
    elif grep -qi 'AuthenticAMD' /proc/cpuinfo 2>/dev/null; then
        cpu_flags+=",+svm"
    fi

    local qemu_bin=""
    if command -v kvm > /dev/null 2>&1; then
        qemu_bin="$(command -v kvm)"
    elif command -v qemu-system-x86_64 > /dev/null 2>&1; then
        qemu_bin="$(command -v qemu-system-x86_64)"
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
    else
        pflash_args=(
            -drive "if=pflash,format=raw,readonly=off,file=${OVMF_CODE_PATH}"
        )
    fi

    echo ""
    echo "=== Khởi động Proxmox qua QEMU/KVM ==="
    echo "Bỏ hostfwd theo yêu cầu; mạng user-mode vẫn được bật cho outbound traffic."
    : > "${PROXMOX_QEMU_LOG}"
    # Boot từ CD-ROM Proxmox ISO để cài đặt; sau khi cài xong có thể đổi thành -boot c.
    cpulimit -l 80 -- "${qemu_bin}" \
        -cpu "${cpu_flags}" \
        -smp 2,cores=2 \
        -M q35,usb=on \
        -device usb-tablet \
        -m 8G \
        -device virtio-balloon-pci \
        -vga virtio \
        -net nic,netdev=n0,model=virtio-net-pci \
        -netdev user,id=n0 \
        -boot order=d,menu=on \
        -device virtio-serial-pci \
        -device virtio-rng-pci \
        -enable-kvm \
        -drive "file=${PROXMOX_DISK_PATH},format=raw" \
        "${pflash_args[@]}" \
        -cdrom "${PROXMOX_ISO_PATH}" \
        -uuid e47ddb84-fb4d-46f9-b531-14bb15156336 \
        -vnc :0 \
        > "${PROXMOX_QEMU_LOG}" 2>&1 &
    QEMU_PID=$!
    sleep 3
    if ! kill -0 "${QEMU_PID}" 2>/dev/null; then
        echo "QEMU/Proxmox không khởi động được."
        tail -n 40 "${PROXMOX_QEMU_LOG}" 2>/dev/null || true
        exit 1
    fi
    echo "QEMU/Proxmox đang chạy với PID ${QEMU_PID}; VNC nội bộ localhost:5900."
    start_novnc
    echo "noVNC: cổng 8006; không có hostfwd cổng 3389."
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
else
    echo ""
    echo "Đã chọn macOS. macos.yaml không dùng USERNAME/PASSWORD và không cần Windows ISO."
    echo "Lần khởi động đầu tiên sẽ tải bộ cài macOS từ dockur/macos."
fi

cd "${SCRIPT_DIR}"
echo ""
echo "=== Kiểm tra Docker Compose cho ${OS_NAME} ==="
docker compose -f "${COMPOSE_FILE}" config -q
echo "=== Khởi động Docker Compose cho ${OS_NAME} ==="
echo "Chạy lệnh 1: docker compose -f ${COMPOSE_FILE} up -d"
docker compose -f "${COMPOSE_FILE}" up -d
echo ""
echo "Chạy lệnh 2: docker compose -f ${COMPOSE_FILE} up"
docker compose -f "${COMPOSE_FILE}" up
