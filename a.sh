#!/usr/bin/env bash
set -Eeuo pipefail

# Cài Docker, chuẩn bị storage/ISO và khởi động dockur/windows.
# Script này được thiết kế cho GitHub Codespaces hoặc Ubuntu có quyền root,
# Docker daemon và KVM khả dụng.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WINDOWS_ISO_PATH="/mnt/custom.iso"
DRIVER_ISO_PATH="/mnt/driver.iso"
DRIVER_ISO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.285-1/virtio-win-0.1.285.iso"
MIN_FREE_KB=$((10 * 1024 * 1024))
DOCKER_APT_LOG="/tmp/windowsghcs-docker-apt.log"

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
    for docker_env_name in DOCKER_HOST DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH; do
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

select_os() {
    echo ""
    echo "=== Chọn hệ điều hành cần cài ==="
    echo "1) Windows"
    echo "2) macOS"
    while true; do
        read -r -p "Hãy nhập 1 để cài Windows hoặc 2 để cài macOS: " os_choice
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
            *)
                echo "Lựa chọn không hợp lệ. Vui lòng nhập 1 hoặc 2."
                ;;
        esac
    done

    if [[ ! -f "${COMPOSE_FILE}" ]]; then
        echo "Không tìm thấy file cấu hình cho ${OS_NAME}: ${COMPOSE_FILE}"
        exit 1
    fi
}

install_docker
check_kvm
mount_storage
select_os

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
