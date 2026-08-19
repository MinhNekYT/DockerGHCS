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
ACTION="install"

case "${1:-}" in
    "")
        ;;
    -start|--start)
        ACTION="start"
        shift
        ;;
    -stop|--stop)
        ACTION="stop"
        shift
        ;;
    -status|--status)
        ACTION="status"
        shift
        ;;
    -password|--password)
        ACTION="password"
        shift
        ;;
    -h|--help)
        cat <<'EOF'
Usage:
  ./xfce4.sh             Install XFCE4, VNC, noVNC and Google Chrome
  ./xfce4.sh -start      Start VNC + noVNC + XFCE4
  ./xfce4.sh -password   Create or change the VNC password
  ./xfce4.sh -status     Show VNC/noVNC status
  ./xfce4.sh -stop       Stop VNC and noVNC

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

echo "=== Chuẩn bị apt/dpkg ==="
dpkg --configure -a
apt-get -f install -y
apt-get update -o Acquire::Retries=3

echo "=== Cài XFCE4 và thành phần X11 ==="
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
    "${VNC_PACKAGES[@]}"

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
    --no-first-run
    --no-default-browser-check
)
if [[ "${CHROME_NO_SANDBOX:-0}" == "1" ]]; then
    CHROME_FLAGS+=(--no-sandbox)
fi
exec /usr/bin/google-chrome "${CHROME_FLAGS[@]}" "$@"
EOF
chmod 0755 /usr/local/bin/google-chrome-xfce

cat > /usr/local/bin/xfce4-vnc-start <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
VNC_USER="${INSTALL_USER}"
VNC_HOME="${INSTALL_HOME}"
VNC_SERVER="${VNC_SERVER_BIN}"
VNC_DISPLAY="${VNC_DISPLAY}"
VNC_GEOMETRY="${VNC_GEOMETRY}"
VNC_DEPTH="${VNC_DEPTH}"

if [[ "\${EUID}" -eq 0 ]]; then
    exec runuser -u "\${VNC_USER}" -- env HOME="\${VNC_HOME}" USER="\${VNC_USER}" LOGNAME="\${VNC_USER}" "\$0" "\$@"
fi
if [[ "\${USER}" != "\${VNC_USER}" ]]; then
    echo "Hãy chạy lệnh này bằng user \${VNC_USER} hoặc dùng sudo." >&2
    exit 1
fi
if [[ ! -f "\${HOME}/.vnc/passwd" ]]; then
    echo "Chưa có VNC password. Chạy: xfce4-vnc-password" >&2
    exit 1
fi
"\${VNC_SERVER}" -kill "\${VNC_DISPLAY}" >/dev/null 2>&1 || true
exec "\${VNC_SERVER}" "\${VNC_DISPLAY}" -geometry "\${VNC_GEOMETRY}" -depth "\${VNC_DEPTH}" -localhost no
EOF
chmod 0755 /usr/local/bin/xfce4-vnc-start

cat > /usr/local/bin/xfce4-vnc-stop <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
VNC_USER="${INSTALL_USER}"
VNC_HOME="${INSTALL_HOME}"
VNC_SERVER="${VNC_SERVER_BIN}"
VNC_DISPLAY="${VNC_DISPLAY}"
if [[ "\${EUID}" -eq 0 ]]; then
    exec runuser -u "\${VNC_USER}" -- env HOME="\${VNC_HOME}" USER="\${VNC_USER}" LOGNAME="\${VNC_USER}" "\$0" "\$@"
fi
"\${VNC_SERVER}" -kill "\${VNC_DISPLAY}" || true
EOF
chmod 0755 /usr/local/bin/xfce4-vnc-stop

cat > /usr/local/bin/xfce4-vnc-password <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
VNC_USER="${INSTALL_USER}"
VNC_HOME="${INSTALL_HOME}"
if [[ "\${EUID}" -eq 0 ]]; then
    exec runuser -u "\${VNC_USER}" -- env HOME="\${VNC_HOME}" USER="\${VNC_USER}" LOGNAME="\${VNC_USER}" "\$0" "\$@"
fi
mkdir -p "\${HOME}/.vnc"
chmod 700 "\${HOME}/.vnc"
exec vncpasswd "\${HOME}/.vnc/passwd"
EOF
chmod 0755 /usr/local/bin/xfce4-vnc-password

cat > /usr/local/bin/xfce4-vnc-status <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
VNC_USER="${INSTALL_USER}"
VNC_DISPLAY="${VNC_DISPLAY}"
if pgrep -u "\${VNC_USER}" -af "(tigervnc|tightvnc|Xvnc).*\${VNC_DISPLAY}"; then
    echo "XFCE4 VNC đang chạy cho \${VNC_USER} tại \${VNC_DISPLAY}."
    exit 0
fi
echo "XFCE4 VNC chưa chạy cho \${VNC_USER} tại \${VNC_DISPLAY}."
exit 1
EOF
chmod 0755 /usr/local/bin/xfce4-vnc-status

NOVNC_PROXY_BIN=""
if command -v novnc_proxy >/dev/null 2>&1; then
    NOVNC_PROXY_BIN="$(command -v novnc_proxy)"
elif [[ -x /usr/share/novnc/utils/novnc_proxy ]]; then
    NOVNC_PROXY_BIN="/usr/share/novnc/utils/novnc_proxy"
fi
if [[ -z "${NOVNC_PROXY_BIN}" ]]; then
    echo "Không tìm thấy novnc_proxy. Hãy cài package novnc trước." >&2
    exit 1
fi

cat > /usr/local/bin/xfce4-novnc-start <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
VNC_USER="${INSTALL_USER}"
VNC_HOME="${INSTALL_HOME}"
NOVNC_PROXY="${NOVNC_PROXY_BIN}"
NOVNC_PORT="${NOVNC_PORT}"
VNC_PORT="${VNC_PORT}"
NOVNC_LOG="${NOVNC_LOG}"
NOVNC_PID_FILE="${NOVNC_PID_FILE}"

if [[ "\${EUID}" -eq 0 ]]; then
    exec runuser -u "\${VNC_USER}" -- env HOME="\${VNC_HOME}" USER="\${VNC_USER}" LOGNAME="\${VNC_USER}" "\$0" "\$@"
fi
if [[ "\${USER}" != "\${VNC_USER}" ]]; then
    echo "Hãy chạy lệnh này bằng user \${VNC_USER} hoặc dùng sudo." >&2
    exit 1
fi
mkdir -p "\${HOME}/.vnc"
if [[ -f "\${NOVNC_PID_FILE}" ]]; then
    old_pid="\$(cat "\${NOVNC_PID_FILE}" 2>/dev/null || true)"
    if [[ "\${old_pid}" =~ ^[0-9]+$ ]]; then
        kill "\${old_pid}" 2>/dev/null || true
    fi
fi
: > "\${NOVNC_LOG}"
nohup "\${NOVNC_PROXY}" --listen "\${NOVNC_PORT}" --vnc "127.0.0.1:\${VNC_PORT}" \
    >> "\${NOVNC_LOG}" 2>&1 &
echo \$! > "\${NOVNC_PID_FILE}"
sleep 2
if ! kill -0 "\$(cat "\${NOVNC_PID_FILE}")" 2>/dev/null; then
    echo "noVNC không khởi động được; xem \${NOVNC_LOG}." >&2
    exit 1
fi
echo "noVNC đang chạy tại cổng \${NOVNC_PORT}; VNC origin 127.0.0.1:\${VNC_PORT}."
EOF
chmod 0755 /usr/local/bin/xfce4-novnc-start

cat > /usr/local/bin/xfce4-novnc-stop <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
VNC_USER="${INSTALL_USER}"
VNC_HOME="${INSTALL_HOME}"
NOVNC_PID_FILE="${NOVNC_PID_FILE}"
if [[ "\${EUID}" -eq 0 ]]; then
    exec runuser -u "\${VNC_USER}" -- env HOME="\${VNC_HOME}" USER="\${VNC_USER}" LOGNAME="\${VNC_USER}" "\$0" "\$@"
fi
if [[ -f "\${NOVNC_PID_FILE}" ]]; then
    pid="\$(cat "\${NOVNC_PID_FILE}" 2>/dev/null || true)"
    if [[ "\${pid}" =~ ^[0-9]+$ ]]; then
        kill "\${pid}" 2>/dev/null || true
    fi
    rm -f "\${NOVNC_PID_FILE}"
fi
EOF
chmod 0755 /usr/local/bin/xfce4-novnc-stop

command -v startxfce4 >/dev/null 2>&1
command -v google-chrome >/dev/null 2>&1
google-chrome --version

case "${ACTION}" in
    install)
        cat <<EOF

Đã cài xong XFCE4, ${VNC_SERVER_BIN}, noVNC và Google Chrome Stable.

User desktop: ${INSTALL_USER}
VNC display: ${VNC_DISPLAY} (TCP ${VNC_PORT})
noVNC port: ${NOVNC_PORT}

Tạo hoặc đổi VNC password:
  ./xfce4.sh -password

Khởi động toàn bộ VNC + noVNC + XFCE4:
  ./xfce4.sh -start
EOF
        ;;
    password)
        exec /usr/local/bin/xfce4-vnc-password
        ;;
    start)
        if [[ ! -f "${VNC_DIR}/passwd" ]]; then
            echo "Chưa có VNC password; hãy tạo password ngay bây giờ."
            /usr/local/bin/xfce4-vnc-password
        fi
        /usr/local/bin/xfce4-vnc-start
        /usr/local/bin/xfce4-novnc-start
        echo "XFCE4 + VNC + noVNC đã khởi động."
        echo "VNC port: ${VNC_PORT}"
        echo "noVNC đã lắng nghe tại host port ${NOVNC_PORT}; hãy mở URL do Codespaces/forwarded host cung cấp từ máy client."
        ;;
    stop)
        /usr/local/bin/xfce4-novnc-stop || true
        /usr/local/bin/xfce4-vnc-stop || true
        echo "Đã dừng noVNC và VNC/XFCE4."
        ;;
    status)
        /usr/local/bin/xfce4-vnc-status || true
        if [[ -f "${NOVNC_PID_FILE}" ]] \
            && kill -0 "$(cat "${NOVNC_PID_FILE}" 2>/dev/null)" 2>/dev/null; then
            echo "noVNC đang chạy tại cổng ${NOVNC_PORT}."
        else
            echo "noVNC chưa chạy tại cổng ${NOVNC_PORT}."
            exit 1
        fi
        ;;
esac
