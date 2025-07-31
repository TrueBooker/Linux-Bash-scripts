#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# ZFS Single Pool Setup and Configuration Script
# Copyright (C) 2025 Sergio Yanez <sergio.yanez@gmail.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
# Licensed under the GNU GPL v3 or later.
# -----------------------------------------------------------------------------

set -euo pipefail

# Auto elevate and force Bash
if [[ -z ${BASH_VERSION:-} ]]; then
    exec /bin/bash "$0" "$@"
set -euo pipefail
fi

# Auto elevate
if [[ $EUID -ne 0 ]]; then
    echo "🛑 This script must be run as root. Re-running with sudo..."
    exec sudo bash "$0" "$@"
fi


trap 'echo "❌ Error on line $LINENO"; exit 1' ERR

echo ">>> Checking for required tools..."
for cmd in zpool zfs lsblk numfmt udevadm; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "❌ Required command '$cmd' is not installed."
        exit 1
    fi
done

echo ">>> Enabling ZFS systemd services..."
systemctl enable --now zfs-import-cache zfs-import-scan zfs-mount zfs-zed zfs.target

# ─────────────────────────────────────────────────────────────────────────────
echo ">>> Detecting available unmounted block devices..."

available_disks=()
mapfile -t available_disks < <(
    lsblk -dpno NAME,TYPE,MOUNTPOINT | awk '$2=="disk" && $3=="" { print $1 }'
)

if [[ ${#available_disks[@]} -eq 0 ]]; then
    echo "❌ No unmounted disks found."
    exit 1
fi

echo -e "\nAvailable unmounted disks:\n"

for i in "${!available_disks[@]}"; do
    dev="${available_disks[$i]}"
    model=$(udevadm info --query=property --name="$dev" | grep ID_MODEL= | cut -d= -f2-)
    size=$(lsblk -dnbo SIZE "$dev")
    size_hr=$(numfmt --to=iec --suffix=B "$size")
    
    # Detect ZFS pool label (if previously in a pool)
    zfs_label=$(zdb -l "$dev" 2>/dev/null | grep -m1 'name:' | awk -F\' '{print $2}' || true)
    pool_info=""
    if [[ -n "$zfs_label" ]]; then
        pool_info="(ZFS Pool: $zfs_label)"
    fi

    echo "[$i] $dev - $size_hr - ${model:-Unknown} $pool_info"
done

echo
read -rp "Select disk number to use: " disk_index
disk="${available_disks[$disk_index]}"
echo ">>> Selected disk: $disk"

# Confirm disk wipe
read -rp "⚠️ Are you sure you want to wipe and use $disk for a new ZFS pool? (yes/NO): " confirm
[[ "$confirm" == "yes" ]] || { echo "Aborted."; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
read -rp "Enter ZFS pool name (alphanumeric, no spaces): " pool_name
mountpoint="/mnt/$pool_name"

# Check if pool exists
if zpool list -H -o name | grep -qx "$pool_name"; then
    echo "❌ A pool named '$pool_name' already exists."
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ">>> Creating ZFS pool: $pool_name on $disk"
zpool create -f -o ashift=12 \
  -O compression=zstd \
  -O atime=off \
  -O mountpoint="$mountpoint" \
  "$pool_name" "$disk"

echo ">>> Setting quota to 95% of disk size..."
total_bytes=$(blockdev --getsize64 "$disk")
quota_bytes=$(( total_bytes * 95 / 100 ))
zfs set quota="${quota_bytes}" "$pool_name"

echo ">>> Pool '$pool_name' created and mounted at $mountpoint"

# ─────────────────────────────────────────────────────────────────────────────
# Optional: create a README.txt with pool info
cat <<EOF > "$mountpoint/README.txt"
ZFS Pool: $pool_name
Disk: $disk
Mountpoint: $mountpoint
Compression: zstd
Quota: 95% of $((total_bytes / 1024 / 1024 / 1024)) GiB
Model: ${model:-Unknown}
Created on: $(date)
EOF

echo "✅ Pool setup complete."
