#!/usr/bin/env bash
set -Eeuo pipefail

# Cài XFCE4, Google Chrome và VNC server trên Ubuntu/Debian/Codespaces.
# TigerVNC được ưu tiên vì tương thích tốt hơn với XFCE4 hiện đại;
# tightvncserver là fallback khi TigerVNC không có trong apt repository.

SCRIPT_NAME="$(basename "$0")"
INSTALL_USER="${INSTALL_USER:-${SUDO_USER:-${_REMOTE_USER:-${USER:-}}}}"
VNC_DISPLAY="${VNC_DISPLAY:-:1}"
VNC_GEOMETRY="${VNC_GEOMETRY:-1920x1080}"
VNC_DEPTH="${VNC_DEPTH:-24}"
NOVNC_PORT="${NOVNC_PORT:-6080}"
ACTION="start"

case "${1:-}" in
    "")
        ACTION="start"
        ;;
    -start|--start)
        ACTION="start"
        shift
        ;;
    -h|--help)
        cat <<'EOF'
Usage:
  ./xfce4.sh             Install missing packages, then start VNC + noVNC + XFCE4
  ./xfce4.sh -start      Alias for the default behavior
  Press Ctrl+C while the script is running to stop VNC, noVNC and XFCE4.

Environment:
  VNC_DISPLAY=:1       VNC display; :1 maps to TCP 5901
  NOVNC_PORT=6080      noVNC HTTP/WebSocket port
  VNC_GEOMETRY=1920x1080
  VNC_DEPTH=24
EOF
        exit 0
        ;;
    *)
        echo "Tham số không hợp lệ: ${1}" >&2
        echo "Dùng ./xfce4.sh --help để xem hướng dẫn." >&2
        exit 2
        ;;
esac

CHROME_DEB="/tmp/google-chrome-stable_current_amd64.deb"
CHROME_URL="https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"

on_error() {
    local exit_code=$?
    trap - ERR
    echo "${SCRIPT_NAME}: cài đặt thất bại (mã lỗi ${exit_code})." >&2
    echo "Kiểm tra log apt bằng: sudo tail -n 100 /var/log/apt/term.log" >&2
    exit "${exit_code}"
}
trap on_error ERR

if [[ "${EUID}" -ne 0 ]]; then
    if ! command -v sudo >/dev/null 2>&1; then
        echo "Không tìm thấy sudo. Hãy chạy script bằng root hoặc cài sudo trước." >&2
        exit 1
    fi
    sudo -v
    exec sudo env \
        "DEBIAN_FRONTEND=noninteractive" \
        "INSTALL_USER=${INSTALL_USER}" \
        "VNC_DISPLAY=${VNC_DISPLAY}" \
        "VNC_GEOMETRY=${VNC_GEOMETRY}" \
        "VNC_DEPTH=${VNC_DEPTH}" \
        "NOVNC_PORT=${NOVNC_PORT}" \
        bash "$0" "$@"
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

if [[ "$(uname -m)" != "x86_64" ]]; then
    echo "Google Chrome Stable trong script này yêu cầu kiến trúc x86_64/amd64." >&2
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

if [[ "${ID:-}" != "ubuntu" && "${ID:-}" != "debian" \
    && "${ID:-}" != "linuxmint" && "${ID:-}" != "pop" ]]; then
    echo "Hệ điều hành hiện tại (${ID:-unknown}) chưa được kiểm thử; tiếp tục vì có apt/dpkg."
fi

if [[ -z "${INSTALL_USER}" || "${INSTALL_USER}" == "root" ]]; then
    echo "Không xác định được user desktop. Hãy chạy bằng user thường hoặc đặt INSTALL_USER=username." >&2
    exit 1
fi

if ! id "${INSTALL_USER}" >/dev/null 2>&1; then
    echo "User không tồn tại: ${INSTALL_USER}" >&2
    exit 1
fi

INSTALL_HOME="$(getent passwd "${INSTALL_USER}" | cut -d: -f6)"
INSTALL_GROUP="$(id -gn "${INSTALL_USER}")"
if [[ -z "${INSTALL_HOME}" || ! -d "${INSTALL_HOME}" ]]; then
    echo "Không tìm thấy home directory của ${INSTALL_USER}." >&2
    exit 1
fi

if [[ ! "${VNC_DISPLAY}" =~ ^:[0-9]+$ ]]; then
    echo "VNC_DISPLAY phải có dạng :1, :2, ...; giá trị hiện tại: ${VNC_DISPLAY}" >&2
    exit 1
fi
if [[ ! "${VNC_GEOMETRY}" =~ ^[0-9]+x[0-9]+$ ]]; then
    echo "VNC_GEOMETRY phải có dạng 1920x1080; giá trị hiện tại: ${VNC_GEOMETRY}" >&2
    exit 1
fi
if [[ ! "${VNC_DEPTH}" =~ ^(16|24|32)$ ]]; then
    echo "VNC_DEPTH phải là 16, 24 hoặc 32; giá trị hiện tại: ${VNC_DEPTH}" >&2
    exit 1
fi
if [[ ! "${NOVNC_PORT}" =~ ^[1-9][0-9]*$ ]] || ((NOVNC_PORT > 65535)); then
    echo "NOVNC_PORT phải là số nguyên trong khoảng 1-65535; giá trị hiện tại: ${NOVNC_PORT}" >&2
    exit 1
fi
if ((NOVNC_PORT >= 5900 && NOVNC_PORT <= 5999)); then
    echo "NOVNC_PORT không được dùng dải VNC 5900-5999; giá trị hiện tại: ${NOVNC_PORT}" >&2
    exit 1
fi

VNC_NUMBER="${VNC_DISPLAY#:}"
VNC_PORT=$((5900 + VNC_NUMBER))
if ((VNC_PORT > 65535)); then
    echo "VNC_DISPLAY tạo ra port vượt quá 65535: ${VNC_DISPLAY}" >&2
    exit 1
fi
if ((NOVNC_PORT == VNC_PORT)); then
    echo "NOVNC_PORT không được trùng với VNC port ${VNC_PORT}." >&2
    exit 1
fi

VNC_DIR="${INSTALL_HOME}/.vnc"
VNC_XSTARTUP="${VNC_DIR}/xstartup"
VNC_CONFIG="${VNC_DIR}/config"
NOVNC_LOG="${VNC_DIR}/novnc.log"
NOVNC_PID_FILE="${VNC_DIR}/novnc.pid"

export HOME="${INSTALL_HOME}"
export USER="${INSTALL_USER}"
export LOGNAME="${INSTALL_USER}"

sudo -u "${INSTALL_USER}" mkdir -p "${VNC_DIR}"
chown "${INSTALL_USER}:${INSTALL_GROUP}" "${VNC_DIR}"
chmod 700 "${VNC_DIR}"

packages_ready=1
if command -v tigervncserver >/dev/null 2>&1; then
    VNC_SERVER_BIN="tigervncserver"
elif command -v tightvncserver >/dev/null 2>&1; then
    VNC_SERVER_BIN="tightvncserver"
else
    VNC_SERVER_BIN="tigervncserver"
    packages_ready=0
fi
for required_command in startxfce4 vncpasswd google-chrome; do
    if ! command -v "${required_command}" >/dev/null 2>&1; then
        packages_ready=0
    fi
done
if ! command -v novnc_proxy >/dev/null 2>&1 \
    && [[ ! -x /usr/share/novnc/utils/novnc_proxy ]] \
    && [[ ! -x /usr/share/novnc/utils/novnc_proxy.py ]]; then
    packages_ready=0
fi

if ((packages_ready == 0)); then
    echo "=== Cài các package XFCE4/VNC/noVNC còn thiếu ==="
    dpkg --configure -a
    apt-get -f install -y
    apt-get update -o Acquire::Retries=3

    VNC_PACKAGES=()
    if apt-cache show tigervnc-standalone-server >/dev/null 2>&1 \
        && apt-cache show tigervnc-tools >/dev/null 2>&1; then
        VNC_PACKAGES+=(tigervnc-standalone-server tigervnc-tools)
        VNC_SERVER_BIN="tigervncserver"
    else
        VNC_PACKAGES+=(tightvncserver)
        VNC_SERVER_BIN="tightvncserver"
    fi

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
        gnupg \
        novnc \
        websockify \
        "${VNC_PACKAGES[@]}"
else
    echo "XFCE4, VNC, noVNC, websockify và Google Chrome đã có; bỏ qua apt install."
fi

if ! command -v "${VNC_SERVER_BIN}" >/dev/null 2>&1; then
    echo "Không tìm thấy VNC server sau khi cài: ${VNC_SERVER_BIN}" >&2
    exit 1
fi
if ! command -v vncpasswd >/dev/null 2>&1; then
    echo "Không tìm thấy vncpasswd sau khi cài VNC server." >&2
    exit 1
fi

cat > "${VNC_XSTARTUP}" <<'EOF'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
export XDG_CURRENT_DESKTOP="XFCE"
export XDG_SESSION_DESKTOP="xfce"
export XDG_SESSION_TYPE="x11"
export XDG_CONFIG_DIRS="/etc/xdg/xdg-xfce4:/etc/xdg:${XDG_CONFIG_DIRS:-}"
export XDG_DATA_DIRS="/usr/share/xfce4:/usr/local/share:/usr/share:${XDG_DATA_DIRS:-}"

runtime_dir="${XDG_RUNTIME_DIR:-/tmp/runtime-${USER}}"
mkdir -p "${runtime_dir}"
chmod 700 "${runtime_dir}"
export XDG_RUNTIME_DIR="${runtime_dir}"

if command -v dbus-launch >/dev/null 2>&1; then
    exec dbus-launch --exit-with-session startxfce4
fi
exec startxfce4
EOF
chown "${INSTALL_USER}:${INSTALL_GROUP}" "${VNC_XSTARTUP}"
chmod 700 "${VNC_XSTARTUP}"

cat > "${VNC_CONFIG}" <<EOF
geometry=${VNC_GEOMETRY}
depth=${VNC_DEPTH}
localhost=no
EOF
chown "${INSTALL_USER}:${INSTALL_GROUP}" "${VNC_CONFIG}"
chmod 600 "${VNC_CONFIG}"

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

cat > /usr/local/bin/google-chrome-xfce <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

: "${DISPLAY:=:1}"
export DISPLAY
export XDG_CURRENT_DESKTOP="${XDG_CURRENT_DESKTOP:-XFCE}"
export XDG_SESSION_DESKTOP="${XDG_SESSION_DESKTOP:-xfce}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-}"
if [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
    export XDG_RUNTIME_DIR="/tmp/runtime-${USER}"
    mkdir -p "${XDG_RUNTIME_DIR}"
    chmod 700 "${XDG_RUNTIME_DIR}"
fi

if [[ "${EUID}" -eq 0 ]]; then
    echo "Không nên chạy Chrome bằng root trong XFCE4/VNC." >&2
    echo "Hãy chạy bằng user desktop: ${INSTALL_USER}." >&2
    exit 1
fi

CHROME_PROFILE="${CHROME_PROFILE:-${HOME}/.config/google-chrome-codespace}"
mkdir -p "${CHROME_PROFILE}"
CHROME_FLAGS=(
    "--user-data-dir=${CHROME_PROFILE}"
    --disable-dev-shm-usage
    --ozone-platform=x11
    --disable-gpu
    --disable-gpu-compositing
    --use-gl=swiftshader
    --no-first-run
    --no-default-browser-check
)
if [[ "${CHROME_NO_SANDBOX:-0}" == "1" ]]; then
    CHROME_FLAGS+=(--no-sandbox --disable-setuid-sandbox)
fi

set +e
/usr/bin/google-chrome "${CHROME_FLAGS[@]}" "$@"
chrome_status=$?
set -e
if ((chrome_status == 0)); then
    exit 0
fi
if [[ "${CHROME_NO_SANDBOX:-0}" != "1" ]]; then
    echo "Chrome thoát bất thường (mã ${chrome_status}); thử lại với sandbox fallback cho môi trường VNC/Codespaces." >&2
    exec /usr/bin/google-chrome \
        "${CHROME_FLAGS[@]}" \
        --no-sandbox --disable-setuid-sandbox "$@"
fi
exit "${chrome_status}"
EOF
chmod 0755 /usr/local/bin/google-chrome-xfce

command -v startxfce4 >/dev/null 2>&1
command -v google-chrome >/dev/null 2>&1
runuser -u "${INSTALL_USER}" -- env \
    HOME="${INSTALL_HOME}" USER="${INSTALL_USER}" LOGNAME="${INSTALL_USER}" \
    google-chrome --version

NOVNC_PROXY_BIN=""
if command -v novnc_proxy >/dev/null 2>&1; then
    NOVNC_PROXY_BIN="$(command -v novnc_proxy)"
elif [[ -x /usr/share/novnc/utils/novnc_proxy ]]; then
    NOVNC_PROXY_BIN="/usr/share/novnc/utils/novnc_proxy"
elif [[ -x /usr/share/novnc/utils/novnc_proxy.py ]]; then
    NOVNC_PROXY_BIN="/usr/share/novnc/utils/novnc_proxy.py"
fi
if [[ -z "${NOVNC_PROXY_BIN}" ]]; then
    echo "Không tìm thấy novnc_proxy sau khi cài package novnc." >&2
    exit 1
fi

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

cleanup_vnc() {
    local exit_code=$?
    trap - INT TERM EXIT
    if [[ -f "${NOVNC_PID_FILE}" ]]; then
        local novnc_pid
        novnc_pid="$(cat "${NOVNC_PID_FILE}" 2>/dev/null || true)"
        if [[ "${novnc_pid}" =~ ^[0-9]+$ ]]; then
            kill "${novnc_pid}" 2>/dev/null || true
        fi
        rm -f "${NOVNC_PID_FILE}"
    fi
    runuser -u "${INSTALL_USER}" -- env \
        HOME="${INSTALL_HOME}" USER="${INSTALL_USER}" LOGNAME="${INSTALL_USER}" \
        "${VNC_SERVER_BIN}" -kill "${VNC_DISPLAY}" \
        >/dev/null 2>&1 || true
    echo "Đã dừng noVNC, VNC và XFCE4." >&2
    exit "${exit_code}"
}

case "${ACTION}" in
    install)
        cat <<EOF

Đã cài xong XFCE4, ${VNC_SERVER_BIN}, noVNC và Google Chrome Stable.

User desktop: ${INSTALL_USER}
VNC display: ${VNC_DISPLAY} (TCP ${VNC_PORT})
noVNC port: ${NOVNC_PORT}

Khi chạy '-start', script sẽ tự tạo VNC password nếu chưa có.

Khởi động toàn bộ VNC + noVNC + XFCE4:
  ./xfce4.sh -start
EOF
        ;;
    start)
        if [[ ! -f "${VNC_DIR}/passwd" ]]; then
            echo "Chưa có VNC password; hãy tạo password ngay bây giờ."
            runuser -u "${INSTALL_USER}" -- env \
                HOME="${INSTALL_HOME}" USER="${INSTALL_USER}" LOGNAME="${INSTALL_USER}" \
                vncpasswd "${VNC_DIR}/passwd"
            chown "${INSTALL_USER}:${INSTALL_GROUP}" "${VNC_DIR}/passwd"
            chmod 600 "${VNC_DIR}/passwd"
        fi

        trap cleanup_vnc INT TERM EXIT
        runuser -u "${INSTALL_USER}" -- env \
            HOME="${INSTALL_HOME}" USER="${INSTALL_USER}" LOGNAME="${INSTALL_USER}" \
            "${VNC_SERVER_BIN}" -kill "${VNC_DISPLAY}" >/dev/null 2>&1 || true
        runuser -u "${INSTALL_USER}" -- env \
            HOME="${INSTALL_HOME}" USER="${INSTALL_USER}" LOGNAME="${INSTALL_USER}" \
            "${VNC_SERVER_BIN}" "${VNC_DISPLAY}" \
            -geometry "${VNC_GEOMETRY}" -depth "${VNC_DEPTH}" -localhost no

        runuser -u "${INSTALL_USER}" -- env \
            HOME="${INSTALL_HOME}" USER="${INSTALL_USER}" LOGNAME="${INSTALL_USER}" \
            touch "${NOVNC_LOG}"
        chmod 644 "${NOVNC_LOG}"
        : > "${NOVNC_LOG}"
        runuser -u "${INSTALL_USER}" -- env \
            HOME="${INSTALL_HOME}" USER="${INSTALL_USER}" LOGNAME="${INSTALL_USER}" \
            "${NOVNC_PROXY_BIN}" --listen "${NOVNC_PORT}" --vnc "127.0.0.1:${VNC_PORT}" \
            >> "${NOVNC_LOG}" 2>&1 &
        NOVNC_PID=$!
        printf '%s\n' "${NOVNC_PID}" > "${NOVNC_PID_FILE}"
        if ! wait_for_tcp_port "${VNC_PORT}" 30; then
            echo "VNC chưa mở port ${VNC_PORT}; xem phiên XFCE4/VNC và ${VNC_XSTARTUP}." >&2
            exit 1
        fi
        if ! wait_for_tcp_port "${NOVNC_PORT}" 30; then
            echo "noVNC chưa mở port ${NOVNC_PORT}; xem ${NOVNC_LOG}." >&2
            tail -n 50 "${NOVNC_LOG}" >&2 || true
            exit 1
        fi
        if ! kill -0 "${NOVNC_PID}" 2>/dev/null; then
            echo "noVNC không khởi động được; xem ${NOVNC_LOG}." >&2
            exit 1
        fi
        echo "XFCE4 + VNC + noVNC đang chạy ở foreground."
        echo "VNC port: ${VNC_PORT}"
        echo "noVNC host port: ${NOVNC_PORT}"
        echo "Nhấn Ctrl+C để dừng toàn bộ VNC, noVNC và XFCE4."
        while :; do
            sleep 3600
        done
        ;;
esac
