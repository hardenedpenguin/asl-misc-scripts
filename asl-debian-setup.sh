#!/bin/sh
#
# Copyright (C) 2026 Jory A. Pratt, W5GLE <geekypenguin@gmail.com>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
#
# Detects Debian 12/13, configures the AllStarLink package repository,
# and optionally installs ASL3 or an appliance package (asl3-appliance,
# asl3-appliance-pc, asl3-appliance-pi).
#

set -e

REPO_BASE="https://repo.allstarlink.org/public"
TMP_DIR="/tmp"
DEB_FILE=""

if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    NC=''
fi

info() { printf '%s%s%s\n' "${GREEN}" "$*" "${NC}"; }
warn() { printf '%s%s%s\n' "${YELLOW}" "$*" "${NC}"; }
err()  { printf '%s%s%s\n' "${RED}" "$*" "${NC}"; }

check_privileges() {
    if [ "$(id -u)" -ne 0 ]; then
        if command -v sudo >/dev/null 2>&1; then
            SUDO="sudo"
        else
            err "This script must be run as root or with sudo."
            exit 1
        fi
    else
        SUDO=""
    fi
}

detect_os() {
    if [ ! -f /etc/os-release ]; then
        err "Cannot detect OS: /etc/os-release not found."
        exit 1
    fi

    # shellcheck disable=SC1091
    . /etc/os-release

    if [ "${ID}" != "debian" ]; then
        err "Unsupported OS: ${ID:-unknown}"
        err "AllStarLink repo setup currently supports Debian only."
        err "See: https://allstarlink.github.io/install/debian/install/"
        exit 1
    fi

    VERSION_MAJOR="${VERSION_ID%%.*}"
    case "${VERSION_MAJOR}" in
        13)
            DEB_FILE="asl-apt-repos.deb13_all.deb"
            info "Detected: Debian ${VERSION_ID} (Trixie)"
            ;;
        12)
            DEB_FILE="asl-apt-repos.deb12_all.deb"
            info "Detected: Debian ${VERSION_ID} (Bookworm)"
            ;;
        *)
            err "Unsupported Debian version: ${VERSION_ID}"
            err "AllStarLink supports Debian 12 (Bookworm) and Debian 13 (Trixie)."
            exit 1
            ;;
    esac
}

setup_repo() {
    info "Downloading ${DEB_FILE}..."
    DEB_PATH="${TMP_DIR}/${DEB_FILE}"
    if command -v curl >/dev/null 2>&1; then
        if ! curl -sSLf -o "${DEB_PATH}" "${REPO_BASE}/${DEB_FILE}"; then
            err "Failed to download ${DEB_FILE}"
            exit 1
        fi
    elif command -v wget >/dev/null 2>&1; then
        if ! wget -q -O "${DEB_PATH}" "${REPO_BASE}/${DEB_FILE}"; then
            err "Failed to download ${DEB_FILE}"
            exit 1
        fi
    else
        err "Neither curl nor wget found. Please install one of them."
        exit 1
    fi

    info "Installing AllStarLink package repository..."
    if ! ${SUDO} dpkg -i "${DEB_PATH}"; then
        err "dpkg install failed. You may need to run: ${SUDO} apt-get install -f"
        exit 1
    fi

    info "Updating package lists..."
    if ! ${SUDO} apt-get update; then
        err "apt-get update failed."
        exit 1
    fi

    rm -f "${DEB_PATH}"

    info "AllStarLink repository setup complete."
}

prompt_install() {
    # Piping the script (e.g. curl ... | sudo sh) leaves stdin as the pipe, not a
    # TTY, so read the menu choice from the controlling terminal when possible.
    if [ -t 0 ]; then
        READ_SOURCE=""
    elif [ -r /dev/tty ]; then
        READ_SOURCE="/dev/tty"
    else
        info "Run manually to install: ${SUDO} apt install asl3"
        return
    fi

    printf '\n'
    info "What would you like to install?"
    printf '\n'
    printf '  1) asl3              - Standard ASL3 (any platform)\n'
    printf '  2) asl3-appliance    - Appliance for VMs/VPS/generic hardware\n'
    printf '  3) asl3-appliance-pc - Appliance for PC hardware (mDNS, swap management)\n'
    printf '  4) asl3-appliance-pi - Appliance for Raspberry Pi\n'
    printf '  5) Skip              - Do not install now\n'
    printf '\n'
    printf 'Choice [1-5] (default 5): '

    if [ -n "${READ_SOURCE}" ]; then
        read -r choice < "${READ_SOURCE}"
    else
        read -r choice
    fi
    choice="${choice:-}"

    case "${choice}" in
        1) PKG="asl3" ;;
        2) PKG="asl3-appliance" ;;
        3) PKG="asl3-appliance-pc" ;;
        4) PKG="asl3-appliance-pi" ;;
        5|"") return ;;
        *) warn "Invalid choice. Skipping install."; return ;;
    esac

    info "Installing ${PKG}..."
    if ${SUDO} apt-get install -y "${PKG}"; then
        info "Installation complete."
    else
        err "Installation failed."
        exit 1
    fi
}

main() {
    check_privileges
    detect_os
    setup_repo
    prompt_install
}

main "$@"
