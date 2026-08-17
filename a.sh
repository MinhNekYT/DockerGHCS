#!/usr/bin/env bash
set -Eeuo pipefail

# Script cài Docker, tải Windows ISO/VirtIO driver và khởi động Docker Compose.
# Script sẽ tự chạy lại bằng quyền root sau khi người dùng xác nhận.

WINDOWS_ISO_PATH="/mnt/custom.iso"
DRIVER_ISO_PATH="/mnt/driver.iso"
DRIVER_ISO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.285-1/virtio-win-0.1.285.iso"

cleanup_on_error() {
    local exit_code=$?
    echo ""
    echo "Script dừng do lỗi (mã lỗi: ${exit_code})."
    exit "${exit_code}"
}
trap cleanup_on_error ERR

if [[ "${1:-}" != "--root" && "${EUID}" -ne 0 ]]; then
    echo ""
    echo "LƯU Ý: Một khi chạy script này thì sẽ không thể cài bản Windows khác bằng script này,"
    echo "chỉ có thể tạo codespaces khác để cài bản Windows khác."
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

    echo "Đang yêu cầu quyền sudo..."
    sudo -v
    exec sudo bash "$0" --root
fi

# Khi đã chạy bằng root, mọi lệnh bên dưới đều thực thi trong phiên sudo.
if [[ "${EUID}" -ne 0 ]]; then
    echo "Không thể lấy quyền root."
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

install_docker() {
    echo ""
    echo "=== Cài đặt Docker ==="
    apt update
    apt install -y ca-certificates curl
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    # Add Docker's official repository to Apt sources.
    tee /etc/apt/sources.list.d/docker.sources > /dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    apt update
    apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker 2>/dev/null || true

    docker --version
    docker compose version
    echo "Đã cài Docker và Docker Compose."
}

mount_storage() {
    echo ""
    echo "=== Kiểm tra phân vùng đã được mount vào /mnt ==="
    mkdir -p /mnt

    if mount | grep -q "on /mnt "; then
        echo "Phân vùng đã được mount vào /mnt. Tiếp tục..."
        return 0
    fi

    echo "Phân vùng chưa được mount. Đang tìm phân vùng lớn hơn 500GB..."

    # Tìm một phân vùng chưa mount có dung lượng trên 500GB.
    # Ưu tiên phân vùng trực tiếp; cách này cũng xử lý được tên NVMe như nvme0n1p1.
    target_partition="$(lsblk -b -nrpo NAME,SIZE,TYPE,MOUNTPOINT | awk '$2 > 500000000000 && $3 == "part" && $4 == "" {print $1; exit}')"

    # Nếu không tìm thấy partition trực tiếp, tìm disk lớn rồi lấy partition đầu tiên.
    if [[ -z "${target_partition}" ]]; then
        disk="$(lsblk -b -nrpo NAME,SIZE,TYPE,MOUNTPOINT | awk '$2 > 500000000000 && $3 == "disk" && $4 == "" {print $1; exit}')"
        if [[ -n "${disk}" ]]; then
            target_partition="$(lsblk -nrpo NAME,TYPE "${disk}" | awk '$2 == "part" {print $1; exit}')"
        fi
    fi

    if [[ -n "${target_partition}" ]]; then
        echo "Đã tìm thấy phân vùng: ${target_partition}"
        mount "${target_partition}" /mnt
        echo "Phân vùng ${target_partition} đã được mount vào /mnt."
    else
        echo "Không tìm thấy phân vùng có dung lượng lớn hơn 500GB chưa được mount."
        echo "Vui lòng chạy script trong Github Codespaces hoặc kiểm tra bằng lệnh lsblk."
        exit 1
    fi
}

download_isos() {
    local windows_iso_url="$1"

    echo ""
    echo "=== Tải Windows ISO ==="
    echo "Đang tải Windows ISO vào ${WINDOWS_ISO_PATH}..."
    curl -fL --retry 3 --retry-delay 5 --progress-bar \
        "${windows_iso_url}" -o "${WINDOWS_ISO_PATH}"

    echo "Đang tải VirtIO driver ISO vào ${DRIVER_ISO_PATH}..."
    curl -fL --retry 3 --retry-delay 5 --progress-bar \
        "${DRIVER_ISO_URL}" -o "${DRIVER_ISO_PATH}"

    echo "Đã tải xong hai file ISO:"
    echo "  - ${WINDOWS_ISO_PATH}"
    echo "  - ${DRIVER_ISO_PATH}"
}

install_docker

mount_storage

echo ""
read -r -p "Bạn muốn cài bản Windows nào? Hãy dán link ISO Windows mà bạn muốn: " windows_iso_url
if [[ -z "${windows_iso_url}" ]]; then
    echo "Link ISO không được để trống."
    exit 1
fi

if [[ "${windows_iso_url}" != http://* && "${windows_iso_url}" != https://* ]]; then
    echo "Link ISO phải bắt đầu bằng http:// hoặc https://."
    exit 1
fi

download_isos "${windows_iso_url}"

echo ""
echo "=== Khởi động Docker Compose ==="
if [[ ! -f "docker-compose.yaml" && ! -f "docker-compose.yml" ]]; then
    echo "Không tìm thấy docker-compose.yaml hoặc docker-compose.yml trong thư mục hiện tại:"
    echo "  ${PWD}"
    exit 1
fi

echo "Chạy lệnh 1: docker compose up -d"
docker compose up -d

echo ""
echo "Chạy lệnh 2: docker compose up"
docker compose up
