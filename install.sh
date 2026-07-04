#!/bin/bash
# KernelSU Waydroid installer - 1-liner for bash
# Usage: curl -fsSL https://raw.githubusercontent.com/Yuu-DevID/KSU-Waydroid/waydroid/install.sh | bash
#
# References:
#   https://github.com/supechicken/KernelSU/tree/waydroid
#   https://github.com/Yuu-DevID/KSU-Waydroid

set -eu

RED='\e[1;31m'
YELLOW='\e[1;33m'
GREEN='\e[1;32m'
BLUE='\e[1;34m'
RESET='\e[0m'

WORK_DIR="${TMPDIR:-/tmp}/kernelsu-waydroid"
KSU_GIT="https://github.com/Yuu-DevID/KSU-Waydroid.git"
KSU_BRANCH="waydroid"
DKMS_GIT="https://aur.archlinux.org/kernelsu-dkms.git"
MODLOADER_URL="https://github.com/shadichy/modloader/releases/download/v2.0.0/modloader-x86_64-glibc"
REPO_URL="https://github.com/Yuu-DevID/KSU-Waydroid"
RELEASE_API="https://api.github.com/repos/Yuu-DevID/KSU-Waydroid/releases"
INSTALL_DIR="${HOME}/.local/share/KSU-Waydroid"

# root check
if [[ ${EUID} != 0 ]]; then
  echo -e "${RED}[!] Please run this script as root!${RESET}"
  exit 1
fi

# cleanup on exit
cleanup() {
  echo -e "${BLUE}[*] Cleaning up temp files...${RESET}"
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

# detect distro / package manager
install_pkg() {
  if command -v apt-get &>/dev/null; then
    apt-get install -y "$@"
  elif command -v pacman &>/dev/null; then
    pacman -S --noconfirm "$@"
  elif command -v dnf &>/dev/null; then
    dnf install -y "$@"
  elif command -v zypper &>/dev/null; then
    zypper install -y "$@"
  else
    echo -e "${RED}[!] Unsupported package manager. Install dependencies manually: git dkms make gcc linux-headers${RESET}"
    exit 1
  fi
}

echo -e "${GREEN}=== KernelSU Waydroid Installer ===${RESET}"
echo -e "${BLUE}[*] Source: ${REPO_URL}${RESET}"
echo

# install deps
echo -e "${BLUE}[*] Installing dependencies...${RESET}"
install_pkg git dkms make gcc 2>/dev/null || true

# detect linux headers package
if ! ls /usr/src/linux-headers-* &>/dev/null 2>&1 && ! ls /usr/lib/modules/*/build &>/dev/null 2>&1; then
  echo -e "${YELLOW}[!] No kernel headers found. Installing headers...${RESET}"
  KERNEL_VER="$(uname -r)"
  if command -v apt-get &>/dev/null; then
    install_pkg "linux-headers-${KERNEL_VER}" 2>/dev/null || install_pkg linux-headers-generic 2>/dev/null || true
  elif command -v pacman &>/dev/null; then
    install_pkg linux-headers 2>/dev/null || true
  fi
fi

mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"

echo -e "${BLUE}[*] Cloning KernelSU (waydroid branch)...${RESET}"
git clone "${KSU_GIT}" -b "${KSU_BRANCH}" --depth=1 KernelSU

echo -e "${BLUE}[*] Cloning kernelsu-dkms PKGBUILD...${RESET}"
git clone "${DKMS_GIT}" -b master --depth=1 2>/dev/null || true

echo -e "${BLUE}[*] Downloading modloader...${RESET}"
curl -fsSL "${MODLOADER_URL}" -o modloader
chmod +x modloader

# extract version info
KSU_VER="$(grep -m1 '^pkgver=' kernelsu-dkms/PKGBUILD 2>/dev/null | cut -d'=' -f2 || echo '0.0.1')"
KSU_GIT_VER="$(git -C KernelSU rev-list --count HEAD)"
DKMS_DIR="/usr/src/kernelsu-${KSU_VER}"

echo -e "${BLUE}[*] KernelSU version: ${KSU_VER} (git rev: ${KSU_GIT_VER})${RESET}"

# setup dkms source
rm -rf "${DKMS_DIR}"
cp -r KernelSU/kernel "${DKMS_DIR}"
cp -r kernelsu-dkms/{dkms.conf,Makefile} "${DKMS_DIR}" 2>/dev/null || true

sed -i "s|@PKGVER@|${KSU_VER}|g; s|@KSU_GIT_VERSION@|${KSU_GIT_VER}|g;" "${DKMS_DIR}/dkms.conf"

# remove old DKMS module if exists
echo -e "${BLUE}[*] Checking for existing KernelSU DKMS module...${RESET}"
OLD_VER="$(dkms status 2>/dev/null | grep -oP 'kernelsu/\K[^ ]+' | head -1)"
if [[ -n "${OLD_VER}" ]]; then
  echo -e "${YELLOW}[!] Found existing module: kernelsu/${OLD_VER}, removing...${RESET}"
  dkms remove "kernelsu/${OLD_VER}" --all 2>/dev/null || true
  rm -rf /usr/src/kernelsu-* /var/lib/dkms/kernelsu 2>/dev/null || true
fi

# build with dkms
echo -e "${BLUE}[*] Building KernelSU with DKMS...${RESET}"
dkms install "kernelsu/${KSU_VER}" --force 2>/dev/null || dkms build "kernelsu/${KSU_VER}" --force

# install utilities
echo -e "${BLUE}[*] Installing utilities...${RESET}"
install -Dm755 kernelsu-dkms/00-kernelsu.conf /etc/modprobe.d/00-kernelsu.conf 2>/dev/null || true
install -Dm755 KernelSU/load-ksu /usr/bin/load-ksu
install -Dm755 modloader /usr/bin/modloader

# relax seccomp for waydroid
if [[ -f /var/lib/waydroid/lxc/waydroid/waydroid.seccomp ]]; then
  echo -e "${BLUE}[*] Relaxing seccomp restrictions for Waydroid...${RESET}"
  sed -i '/reboot/d' /var/lib/waydroid/lxc/waydroid/waydroid.seccomp
fi

# download manager APK
echo -e "${BLUE}[*] Downloading KernelSU Manager APK...${RESET}"
mkdir -p "${INSTALL_DIR}"
MANAGER_PATH="${INSTALL_DIR}/KernelSU-Manager.apk"

# find APK asset from all GitHub releases (scan both manager-build and latest tags)
APK_URL="$(
  curl -fsSL "${RELEASE_API}" 2>/dev/null \
    | grep -oP '"browser_download_url":\s*"\K[^"]*KernelSU[^"]*\.apk' \
    | head -1
)"

if [[ -n "${APK_URL}" ]]; then
  echo -e "${BLUE}[*] Found APK: ${APK_URL##*/}${RESET}"
  curl -fsSL "${APK_URL}" -o "${MANAGER_PATH}"
else
  echo -e "${YELLOW}[!] Could not find manager APK in releases. Build it from the workflow.${RESET}"
  MANAGER_PATH="(not downloaded - trigger workflow build first)"
fi

echo
echo -e "${GREEN}============================================${RESET}"
echo -e "${GREEN}[+] KernelSU Waydroid installed successfully!${RESET}"
echo
echo -e "${GREEN}[+] Load KernelSU:${RESET}  sudo load-ksu"
echo -e "${GREEN}[+] Repo:${RESET}           ${REPO_URL}"
if [[ -f "${MANAGER_PATH}" ]]; then
  echo -e "${GREEN}[+] Manager APK:${RESET}    ${MANAGER_PATH}"
fi
echo -e "${GREEN}============================================${RESET}"
echo
