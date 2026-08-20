#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

# Proxmox vẫn dùng luồng unattended/QEMU ổn định trong a.sh, bao gồm answer file,
# pve-no-subscription, disk raw và hostfwd 8006 -> guest 8006.
exec env \
    DOCKERGHCS_AUTOMATED_CHOICE=3 \
    DOCKERGHCS_SKIP_DISK_PROMPT=1 \
    VM_DISK_SIZE="${VM_DISK_SIZE:-400G}" \
    bash "${REPO_DIR}/a.sh" "$@"
