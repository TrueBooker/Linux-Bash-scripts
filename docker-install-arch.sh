#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Hardened Docker + Portainer Deployment Script for Arch Linux
# Includes:
# - Docker & NVIDIA support
# - Portainer CE/EE + Agent
# - Docker Compose v2
# - fail2ban hardening
# - KDE/GNOME launchers
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

# Auto elevate and force Bash
if [[ -z ${BASH_VERSION:-} ]]; then
    exec /bin/bash "$0" "$@"

fi

set -euo pipefail
shopt -s nullglob

info()    { echo -e "\e[34m[INFO]\e[0m $*"; }
warn()    { echo -e "\e[33m[WARN]\e[0m $*"; }
error()   { echo -e "\e[31m[ERROR]\e[0m $*"; }
success() { echo -e "\e[32m[✓]\e[0m $*"; }
ask()     { read -rp $'\e[36m[?]\e[0m '"$1 "; }

# Check Docker Compose availability
if command -v docker-compose &>/dev/null; then
  success "Docker Compose is available."
else
  warn "Docker Compose not found. Please install it before proceeding."
fi

# Check for existing Portainer container
EXISTING_CONTAINER=$(docker ps -a --format '{{.Names}}' | grep '^portainer$' || true)
if [[ -n "$EXISTING_CONTAINER" ]]; then
  warn "Portainer container already exists."
  ask "Do you want to remove and recreate it? [y/N]: "
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    info "Exiting without changes."
    exit 0
  else
    info "Removing existing Portainer container..."
    docker rm -f portainer || true
    docker volume rm portainer_portainer_data || true
  fi
fi

# Select Portainer edition
echo
ask "Select Portainer Edition:
1) Community (CE)
2) Enterprise (EE)
#? "
PORTAINER_IMAGE="portainer/portainer-ce:latest"
[[ "$REPLY" == "2" ]] && PORTAINER_IMAGE="portainer/portainer-ee:latest"

# Install dependencies
info "Installing Docker and dependencies..."
sudo pacman -Sy --needed --noconfirm docker docker-compose curl whois fail2ban nvidia-container-toolkit

# Enable and start Docker service
info "Enabling and starting Docker service..."
sudo systemctl enable --now docker

# Configure NVIDIA Docker runtime
info "Configuring NVIDIA container runtime..."
sudo mkdir -p /etc/docker
cat <<EOF | sudo tee /etc/docker/daemon.json >/dev/null
{
  "default-runtime": "nvidia",
  "runtimes": {
    "nvidia": {
      "path": "nvidia-container-runtime",
      "runtimeArgs": []
    }
  }
}
EOF
sudo systemctl restart docker

# Enable fail2ban service
info "Enabling fail2ban service..."
sudo systemctl enable --now fail2ban

# Prepare directories
PORTAINER_DIR="/docker/portainer"
mkdir -p "$PORTAINER_DIR"

# Write docker-compose.yml 
cat <<EOF > "$PORTAINER_DIR/docker-compose.yml"

services:
  portainer:
    image: $PORTAINER_IMAGE
    container_name: portainer
    restart: always
    ports:
      - "9443:9443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /docker/portainer_data:/data
    environment:
      - NVIDIA_VISIBLE_DEVICES=all

volumes:
  portainer_data:
EOF

# Deploy Portainer container
info "Deploying Portainer container..."
cd "$PORTAINER_DIR"
docker compose up -d

# Download Portainer icon for launcher
ICON_URL="https://raw.githubusercontent.com/mustay/dashboard-icons/master/png/portainer.png"
ICON_PATH="$HOME/.local/share/icons/portainer.png"
mkdir -p "$(dirname "$ICON_PATH")"
info "Downloading Portainer icon..."
curl -fsSL "$ICON_URL" -o "$ICON_PATH"

# Create desktop and menu launcher entries
create_launcher() {
  local target_path="$1"
  cat <<EOF > "$target_path"
[Desktop Entry]
Version=1.0
Type=Application
Name=Portainer
Comment=Manage Docker containers via Portainer
Exec=xdg-open http://localhost:9443
Icon=$ICON_PATH
Terminal=false
Categories=System;Utility;
EOF
  chmod +x "$target_path"
}

info "Creating desktop launcher on Desktop and in Application Menu..."
create_launcher "$HOME/Desktop/Portainer.desktop"
create_launcher "$HOME/.local/share/applications/Portainer.desktop"

success "Portainer installation and configuration complete!"
echo
echo "Access Portainer Web UI at: http://localhost:9443"
echo
echo "Launchers created:"
echo "  • Desktop: ~/Desktop/Portainer.desktop"
echo "  • Application Menu: ~/.local/share/applications/Portainer.desktop"
echo
echo "To use Docker without sudo, log out and back in (or reboot)."
