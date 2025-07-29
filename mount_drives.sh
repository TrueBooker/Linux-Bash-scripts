#!/bin/bash
# -----------------------------------------------------------------------------
# Script to detect unmounted ext4, btrfs, ntfs, and xfs partitions and
# update /etc/fstab with optimized mount options.
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
# -----------------------------------------------------------------------------

set -e

echo ">>> Detecting unmounted ext4, btrfs, ntfs, and xfs partitions and updating /etc/fstab..."

# Backup current fstab
backup_file="/etc/fstab.bak_$(date +%F_%T)"
sudo cp /etc/fstab "$backup_file"
echo ">>> Backup created at: $backup_file"

# Target filesystems
TARGET_FS=("ext4" "btrfs" "ntfs" "xfs")

# Scan all unmounted partitions
lsblk -o NAME,TYPE,MOUNTPOINT,FSTYPE -nr | while read -r name type mount fstype; do
    if [[ "$type" == "part" && -z "$mount" && " ${TARGET_FS[*]} " == *" $fstype "* ]]; then
        device="/dev/$name"
        uuid=$(blkid -s UUID -o value "$device")

        if [[ -z "$uuid" ]]; then
            echo ">>> Skipping $device (no UUID found)"
            continue
        fi

        # Skip if already in fstab
        if grep -q "$uuid" /etc/fstab; then
            echo ">>> UUID=$uuid already in /etc/fstab, skipping."
            continue
        fi

        # Create mount point
        mountpoint="/mnt/$name"
        sudo mkdir -p "$mountpoint"

        # Define optimized mount options
        case "$fstype" in
            ext4)
                options="defaults,nofail,noatime,data=writeback,commit=120"
                ;;
            btrfs)
                options="defaults,nofail,noatime,compress=zstd,autodefrag,space_cache=v2"
                ;;
            ntfs)
                fstype="ntfs3"
                options="defaults,nofail,noatime,prealloc,windows_names,uid=1000,gid=1000,dmask=027,fmask=137,locale=en_US.utf8"
                ;;
            xfs)
                options="defaults,nofail,noatime,attr2,inode64"
                ;;
        esac

        # Append to /etc/fstab
        echo "UUID=$uuid $mountpoint $fstype $options 0 2" | sudo tee -a /etc/fstab > /dev/null
        echo ">>> Added $device (UUID=$uuid) to /etc/fstab at $mountpoint [$fstype]"
    fi
done

echo
echo ">>> Done. Run 'sudo mount -a' to mount newly added entries."
