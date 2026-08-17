#!/usr/bin/env bash
set -Eeuo pipefail

# Script cài Docker, tải Windows ISO/VirtIO driver và khởi động Docker Compose.
# Chạy script này trong một Codespace mới theo hướng dẫn của repository.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WINDOWS_ISO_PATH="/mnt/custom.iso"
DRIVER_ISO_PATH="/mnt/driver.iso"
DRIVER_ISO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.285-1/virtio-win-0.1.285.iso"

on_error() {
    local exit_code=$?
    trap - ERR
    echo ""
    echo "Script dừng do lỗi (mã lỗi: ${exit_code})."
    exit "${exit_code}"
}
trap on_error ERR

# Xác nhận trước khi thực hiện thay đổi hệ thống và tải ISO dung lượng lớn.
if [[ "${1:-}" != "--root" && "${EUID}" -ne 0 ]]; then
    echo ""
    echo "LƯU Ý: Một khi chạy script này thì sẽ không thể cài bản Windows khác bằng script này,"
    echo "chỉ có thể tạo codespaces khác để cài bản Windows khác."
    echo "Script cũng sẽ gỡ các gói Docker cũ/xung đột trước khi cài Docker chính thức."
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

    sudo -v
    calling_user="${SUDO_USER:-${USER:-}}"
    exec sudo env "WINDOWS_INSTALL_USER=${calling_user}" bash "$0" --root
fi

if [[ "${EUID}" -ne 0 ]]; then
    echo "Không thể lấy quyền root."
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive
INSTALL_USER="${WINDOWS_INSTALL_USER:-${SUDO_USER:-}}"

install_docker() {
    echo ""
    echo "=== Gỡ các gói Docker có thể xung đột ==="
    for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
        apt-get remove -y "${pkg}" || true
    done

    echo ""
    echo "=== Cập nhật package database ==="
    apt-get update

    echo ""
    echo "=== Cài các package cần thiết ==="
    apt-get install -y ca-certificates curl gnupg lsb-release

    echo ""
    echo "=== Thêm Docker official GPG key ==="
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor --batch --yes -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo ""
    echo "=== Cấu hình Docker stable repository ==="
    # Xóa cấu hình Docker cũ để tránh duplicate repository hoặc xung đột keyring.
    rm -f /etc/apt/sources.list.d/docker.sources \
          /etc/apt/sources.list.d/docker.list

    docker_arch="$(dpkg --print-architecture)"
    ubuntu_codename="$(lsb_release -cs)"
    echo "deb [arch=${docker_arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${ubuntu_codename} stable" \
        | tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update

    echo ""
    echo "=== Cài Docker Engine, CLI, Containerd và Compose plugin ==="
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

    # groupadd sẽ lỗi nếu group đã tồn tại, vì vậy chỉ tạo khi cần.
    if ! getent group docker > /dev/null; then
        groupadd docker
    fi

    # Thêm user đã chạy script vào docker group. Không dùng newgrp trong script,
    # vì newgrp mở một shell tương tác và có thể làm script bị treo.
    if [[ -n "${INSTALL_USER}" && "${INSTALL_USER}" != "root" ]] \
        && id "${INSTALL_USER}" > /dev/null 2>&1; then
        usermod -aG docker "${INSTALL_USER}"
        echo "Đã thêm ${INSTALL_USER} vào group docker. Quyền mới có hiệu lực sau khi đăng nhập lại."
    fi

    # Codespaces thường không chạy systemd đầy đủ; thử systemctl trước rồi service.
    if command -v systemctl > /dev/null 2>&1; then
        systemctl enable --now docker 2>/dev/null || true
    fi
    if ! docker info > /dev/null 2>&1 && command -v service > /dev/null 2>&1; then
        service docker start 2>/dev/null || true
    fi

    # Một số Codespaces không có systemd. Thử khởi động dockerd nền trong trường hợp đó.
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

    docker --version
    docker compose version

    if ! docker info > /dev/null 2>&1; then
        echo "Docker Engine đã được cài nhưng daemon chưa chạy hoặc không khả dụng."
        if [[ -s /tmp/windowsghcs-dockerd.log ]]; then
            echo "Nhật ký Docker daemon gần nhất:"
            tail -n 20 /tmp/windowsghcs-dockerd.log
        fi
        exit 1
    fi

    echo "Đã cài và kiểm tra Docker thành công."
}

mount_storage() {
    echo ""
    echo "=== Kiểm tra phân vùng đã được mount vào /mnt ==="
    mkdir -p /mnt

    if findmnt -rn -M /mnt > /dev/null 2>&1; then
        echo "Phân vùng đã được mount vào /mnt. Tiếp tục..."
        return 0
    fi

    echo "Phân vùng chưa được mount. Đang tìm phân vùng lớn hơn 500GB..."

    # Ưu tiên một partition chưa mount trực tiếp; cách này xử lý được cả NVMe.
    target_partition="$(lsblk -b -nrpo NAME,SIZE,TYPE,MOUNTPOINT | \
        awk '$2 > 500000000000 && $3 == "part" && $4 == "" {print $1; exit}')"

    # Nếu chưa có partition phù hợp, tìm disk lớn chưa mount và partition đầu tiên của disk đó.
    if [[ -z "${target_partition}" ]]; then
        disk="$(lsblk -b -nrpo NAME,SIZE,TYPE,MOUNTPOINT | \
            awk '$2 > 500000000000 && $3 == "disk" && $4 == "" {print $1; exit}')"
        if [[ -n "${disk}" ]]; then
            target_partition="$(lsblk -nrpo NAME,TYPE "${disk}" | \
                awk '$2 == "part" {print $1; exit}')"
        fi
    fi

    if [[ -z "${target_partition}" ]]; then
        echo "Không tìm thấy phân vùng có dung lượng lớn hơn 500GB chưa được mount."
        echo "Vui lòng kiểm tra bằng lệnh lsblk hoặc chạy trong GitHub Codespaces."
        exit 1
    fi

    echo "Đã tìm thấy phân vùng: ${target_partition}"
    mount "${target_partition}" /mnt
    echo "Phân vùng ${target_partition} đã được mount vào /mnt."
}

download_file() {
    local url="$1"
    local destination="$2"
    local temporary_file

    temporary_file="$(mktemp "${destination}.part.XXXXXX")"
    if ! curl -fL --retry 3 --retry-delay 5 --progress-bar \
        "${url}" -o "${temporary_file}"; then
        rm -f "${temporary_file}"
        echo "Không thể tải file từ URL: ${url}"
        exit 1
    fi

    mv -f "${temporary_file}" "${destination}"
}

download_isos() {
    local windows_iso_url="$1"

    # Không ghi đè ISO đã có, đúng với cảnh báo chạy một lần trên Codespace.
    if [[ -e "${WINDOWS_ISO_PATH}" ]]; then
        echo "Đã tồn tại custom.iso trong /mnt."
        echo "Để tránh cài đè hoặc cài nhầm bản Windows khác, hãy tạo Codespace mới rồi chạy lại script."
        exit 1
    fi

    echo ""
    echo "=== Tải Windows ISO ==="
    echo "Đang tải Windows ISO vào ${WINDOWS_ISO_PATH}..."
    download_file "${windows_iso_url}" "${WINDOWS_ISO_PATH}"

    if [[ -e "${DRIVER_ISO_PATH}" ]]; then
        echo "driver.iso đã tồn tại, giữ nguyên file hiện có."
    else
        echo "Đang tải VirtIO driver ISO vào ${DRIVER_ISO_PATH}..."
        download_file "${DRIVER_ISO_URL}" "${DRIVER_ISO_PATH}"
    fi

    echo "Đã tải xong hai file ISO."
}

install_docker

# Hỏi URL sau khi Docker đã cài xong, theo đúng luồng cài đặt yêu cầu.
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

mount_storage
download_isos "${windows_iso_url}"

cd "${SCRIPT_DIR}"
if [[ ! -f "docker-compose.yaml" && ! -f "docker-compose.yml" ]]; then
    echo "Không tìm thấy docker-compose.yaml hoặc docker-compose.yml trong thư mục script:"
    echo "  ${SCRIPT_DIR}"
    exit 1
fi

echo ""
echo "=== Khởi động Docker Compose ==="
echo "Chạy lệnh 1: docker compose up -d"
docker compose up -d

echo ""
echo "Chạy lệnh 2: docker compose up"
docker compose up
