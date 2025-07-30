#!/bin/bash
# -----------------------------------------------------------------------------
# Script to mount unmounted ext4, xfs, and btrfs partitions with proper labels
# and subvolume support, updating /etc/fstab with optimized mount settings.
#
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
# License: GNU GPLv3 or later
# -----------------------------------------------------------------------------

set -euo pipefail
trap 'echo -e "${RED}❌ Error at line $LINENO: \"$BASH_COMMAND\"${NC}"; exit 1' ERR

# ────────────────────────────────────────────────────────────────
# Color definitions
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m' # No Color

# ────────────────────────────────────────────────────────────────
# Ensure root
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}🛑 Must be run as root. Re-running with sudo...${NC}"
    exec sudo "$0" "$@"
fi

echo -e "${YELLOW}🚫 NTFS support removed. Only ext4, xfs, and btrfs will be mounted.${NC}"

# ────────────────────────────────────────────────────────────────
# Validate required tools
for tool in blkid lsblk findmnt e2label xfs_admin btrfs mountpoint; do
    if ! command -v "$tool" &>/dev/null; then
        echo -e "${RED}❌ Required tool '$tool' not found. Install it and try again.${NC}"
        exit 1
    fi
done

# ────────────────────────────────────────────────────────────────
# Backup fstab
timestamp=$(date +%F)
seq=0
backup_file="/etc/fstab.bak_${timestamp}_$seq"

while [[ -e "$backup_file" ]]; do
    seq=$((seq + 1))
    backup_file="/etc/fstab.bak_${timestamp}_$seq"
done

cp /etc/fstab "$backup_file"
echo -e "${GREEN}📦 Backup saved to $backup_file${NC}"
# ────────────────────────────────────────────────────────────────
TARGET_FS=("ext4" "btrfs" "xfs")
declare -A used_labels
declare -A used_mounts
disk_index=0
found_new_entries=false

get_next_disk_label() {
    while true; do
        candidate="Disk$disk_index"
        ((disk_index++))
        if [[ -z "${used_labels[$candidate]:-}" ]]; then
            echo "$candidate"
            return
        fi
        ((disk_index > 99)) && { echo -e "${RED}❌ Too many disks labeled.${NC}"; exit 1; }
    done
}

# ────────────────────────────────────────────────────────────────
# Detect and mount partitions
while read -r name type mount; do
    [[ "$type" != "part" || -n "$mount" ]] && continue

    device="/dev/$name"
    mountpoint -q "$device" && continue

    fstype=$(blkid -s TYPE -o value "$device" || true)
    uuid=$(blkid -s UUID -o value "$device" || true)
    [[ -z "$fstype" || -z "$uuid" ]] && continue
    [[ ! " ${TARGET_FS[*]} " =~ " $fstype " ]] && continue
    grep -q "$uuid" /etc/fstab && continue

    label=$(blkid -s LABEL -o value "$device" || true)
    label=${label//[^[:alnum:]_-]/}
    original_label="$label"

    if [[ ! "$label" =~ ^Disk[0-9]+$ ]]; then
        echo -e "${YELLOW}📝 Partition $device has non-standard label '${original_label:-<none>}'${NC}"
        label=$(get_next_disk_label)
        echo -e "${BLUE}🔁 Suggested label: $label${NC}"
        read -rp "Rename $device to '$label'? (y/n): " ans
        [[ "$ans" =~ ^[Yy]$ ]] || { echo -e "${YELLOW}⏭️ Skipping $device${NC}"; continue; }

        case "$fstype" in
            ext4) e2label "$device" "$label" ;;
            xfs)  xfs_admin -L "$label" "$device" ;;
            btrfs) btrfs filesystem label "$device" "$label" ;;
        esac
    fi

    used_labels["$label"]=1
    mountpoint="/mnt/$label"
    [[ -d "$mountpoint" ]] || mkdir -p "$mountpoint"
    used_mounts["$mountpoint"]=1

    echo -e "${GREEN}📄 Processing $device ($fstype) with label '$label'${NC}"

    case "$fstype" in
        ext4)
            opts="defaults,nofail,noatime,data=ordered,commit=60,errors=remount-ro"
            ;;
        xfs)
            opts="defaults,nofail,noatime,attr2,inode64,allocsize=1m,logbufs=8"
            ;;
        btrfs)
            temp_mount="/mnt/.btrfs-$label-tmp"
            subvol="@${label}"

            echo -e "${BLUE}🔧 Mounting temporarily at $temp_mount${NC}"
            mkdir -p "$temp_mount"
            mount "$device" "$temp_mount"

            if [[ ! -d "$temp_mount/$subvol" ]]; then
                echo -e "${YELLOW}📁 Creating subvolume $subvol${NC}"
                btrfs subvolume create "$temp_mount/$subvol"
            else
                echo -e "${GREEN}✅ Subvolume $subvol already exists${NC}"
            fi

            echo -e "${BLUE}🔽 Unmounting temporary mount${NC}"
            umount "$temp_mount"
            rmdir "$temp_mount"

            opts="nofail,noatime,compress=zstd,autodefrag,space_cache=v2,subvol=$subvol"
            ;;
    esac

    echo -e "${BLUE}➕ Adding to /etc/fstab:${NC} UUID=$uuid $mountpoint $fstype $opts 0 2"
    echo "UUID=$uuid $mountpoint $fstype $opts 0 2" >> /etc/fstab
    found_new_entries=true

done < <(lsblk -o NAME,TYPE,MOUNTPOINT -nr)

# ────────────────────────────────────────────────────────────────
# Post-processing
if $found_new_entries; then
    echo -e "${GREEN}✅ New entries added to /etc/fstab.${NC}"
    echo -e "${BLUE}🔍 Validating with findmnt...${NC}"
    if findmnt --verify --fstab; then
        echo -e "${GREEN}✔️ fstab validation passed.${NC}"
    else
        echo -e "${RED}❌ fstab validation failed.${NC}"
    fi

    read -rp "👉 Run 'mount -a' now to mount new partitions? (y/n): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] && mount -a && echo -e "${GREEN}✅ All partitions mounted.${NC}"
else
    echo -e "${YELLOW}ℹ️ No new entries added.${NC}"
fi

echo -e "${GREEN}🎉 All done!${NC}"
