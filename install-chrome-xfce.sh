#!/usr/bin/env bash
set -Eeuo pipefail

# Cài Google Chrome Stable và XFCE4 trên Ubuntu/Debian, bao gồm GitHub Codespaces.
# Script không cài display manager và không tự khởi động desktop session.

SCRIPT_NAME="$(basename "$0")"
INSTALL_USER="${INSTALL_USER:-${SUDO_USER:-${_REMOTE_USER:-${USER:-}}}}"
CHROME_DEB="/tmp/google-chrome-stable_current_amd64.deb"
CHROME_URL="https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"

on_error() {
    local exit_code=$?
    trap - ERR
    echo "${SCRIPT_NAME}: cài đặt thất bại (mã lỗi ${exit_code})." >&2
    echo "Hãy kiểm tra log apt bằng: sudo tail -n 100 /var/log/apt/term.log" >&2
    exit "${exit_code}"
}
trap on_error ERR

if [[ "${EUID}" -ne 0 ]]; then
    if ! command -v sudo >/dev/null 2>&1; then
        echo "Không tìm thấy sudo. Hãy chạy script bằng root hoặc cài sudo trước." >&2
        exit 1
    fi
    sudo -v
    exec sudo --preserve-env=DEBIAN_FRONTEND,INSTALL_USER bash "$0" "$@"
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

if [[ "$(uname -m)" != "x86_64" ]]; then
    echo "Google Chrome Stable cho Linux trong script này yêu cầu kiến trúc x86_64/amd64." >&2
    echo "Kiến trúc hiện tại: $(uname -m)" >&2
    exit 1
fi

if ! command -v apt-get >/dev/null 2>&1 || ! command -v dpkg >/dev/null 2>&1; then
    echo "Script chỉ hỗ trợ hệ Debian/Ubuntu có apt-get và dpkg." >&2
    exit 1
fi

if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
else
    echo "Không xác định được hệ điều hành." >&2
    exit 1
fi

case "${ID:-}" in
    ubuntu|debian|linuxmint|pop)
        ;;
    *)
        echo "Hệ điều hành hiện tại (${ID:-unknown}) chưa được kiểm thử; chỉ tiếp tục nếu có apt tương thích Debian/Ubuntu." >&2
        ;;
esac

echo "=== Chuẩn bị apt/dpkg ==="
dpkg --configure -a || true
apt-get -f install -y || true
apt-get update -o Acquire::Retries=3

echo "=== Cài XFCE4 và các thành phần X11 cần thiết ==="
apt-get install -y --no-install-recommends \
    xfce4 \
    xfce4-goodies \
    xfce4-terminal \
    dbus-x11 \
    x11-xserver-utils \
    xauth \
    xvfb \
    ca-certificates \
    curl \
    gnupg

echo "=== Cài Google Chrome Stable ==="
if command -v google-chrome >/dev/null 2>&1; then
    echo "Google Chrome đã được cài: $(google-chrome --version)"
else
    rm -f "${CHROME_DEB}"
    curl --fail --location --retry 3 --retry-delay 2 \
        --output "${CHROME_DEB}" "${CHROME_URL}"
    apt-get install -y "${CHROME_DEB}"
    rm -f "${CHROME_DEB}"
fi

# Cho phép Chrome chạy trong container/Codespace không có sandbox setuid.
# Không tắt sandbox mặc định; chỉ tạo một lệnh tiện dụng khi người dùng chủ động cần.
if [[ -n "${INSTALL_USER}" && "${INSTALL_USER}" != "root" ]] \
    && id "${INSTALL_USER}" >/dev/null 2>&1; then
    install -d -m 0755 -o "${INSTALL_USER}" -g "${INSTALL_USER}" \
        "/home/${INSTALL_USER}/.config/xfce4"
fi

# Xác minh các binary quan trọng sau khi cài.
command -v google-chrome >/dev/null 2>&1
google-chrome --version
command -v startxfce4 >/dev/null 2>&1
startxfce4 --version 2>/dev/null | head -n 1 || true

cat <<'EOF'

Đã cài xong Google Chrome Stable và XFCE4.

Lưu ý cho GitHub Codespaces:
  - Codespaces không tự hiển thị desktop GUI sau khi cài package.
  - Có thể kiểm thử Chrome headless bằng:
      google-chrome --headless=new --no-sandbox --disable-gpu --dump-dom https://example.com
  - Để dùng XFCE4 tương tác, cần chạy thêm một máy chủ X/VNC/RDP phù hợp với cách expose port của Codespace.
  - Script này không cài hoặc bật display manager để tránh làm treo môi trường Codespaces.
EOF
