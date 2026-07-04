#!/usr/bin/env fish
# KernelSU Waydroid installer - 1-liner for fish shell
# Usage: curl -fsSL https://raw.githubusercontent.com/Yuu-DevID/KSU-Waydroid/waydroid/install.fish | fish
#
# References:
#   https://github.com/supechicken/KernelSU/tree/waydroid
#   https://github.com/Yuu-DevID/KSU-Waydroid

set -e

set RED '\e[1;31m'
set YELLOW '\e[1;33m'
set GREEN '\e[1;32m'
set BLUE '\e[1;34m'
set RESET '\e[0m'

set WORK_DIR "$TMPDIR/kernelsu-waydroid"
if test -z "$TMPDIR"
  set WORK_DIR /tmp/kernelsu-waydroid
end

set KSU_GIT "https://github.com/supechicken/KernelSU.git"
set KSU_BRANCH "waydroid"
set DKMS_GIT "https://aur.archlinux.org/kernelsu-dkms.git"
set MODLOADER_URL "https://github.com/shadichy/modloader/releases/download/v2.0.0/modloader-x86_64-glibc"
set REPO_URL "https://github.com/Yuu-DevID/KSU-Waydroid"
set MANAGER_URL "https://github.com/Yuu-DevID/KSU-Waydroid/releases/download/manager-build/KernelSU-Manager.apk"
set INSTALL_DIR "$HOME/.local/share/KSU-Waydroid"

# root check
if test (id -u) -ne 0
  echo -e "$RED[!] Please run this script as root!$RESET"
  exit 1
end

# cleanup on exit
function cleanup
  echo -e "$BLUE[*] Cleaning up temp files...$RESET"
  rm -rf "$WORK_DIR"
end
trap cleanup EXIT

# detect package manager
function install_pkg
  if command -v apt-get >/dev/null 2>&1
    apt-get install -y $argv
  else if command -v pacman >/dev/null 2>&1
    pacman -S --noconfirm $argv
  else if command -v dnf >/dev/null 2>&1
    dnf install -y $argv
  else if command -v zypper >/dev/null 2>&1
    zypper install -y $argv
  else
    echo -e "$RED[!] Unsupported package manager. Install dependencies manually: git dkms make gcc linux-headers$RESET"
    exit 1
  end
end

echo -e "$GREEN=== KernelSU Waydroid Installer ===$RESET"
echo -e "$BLUE[*] Source: $REPO_URL$RESET"
echo

# install deps
echo -e "$BLUE[*] Installing dependencies...$RESET"
install_pkg git dkms make gcc 2>/dev/null; or true

# detect linux headers
if not ls /usr/src/linux-headers-* >/dev/null 2>&1; and not ls /usr/lib/modules/*/build >/dev/null 2>&1
  echo -e "$YELLOW[!] No kernel headers found. Installing headers...$RESET"
  set KERNEL_VER (uname -r)
  if command -v apt-get >/dev/null 2>&1
    install_pkg "linux-headers-$KERNEL_VER" 2>/dev/null; or install_pkg linux-headers-generic 2>/dev/null; or true
  else if command -v pacman >/dev/null 2>&1
    install_pkg linux-headers 2>/dev/null; or true
  end
end

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

echo -e "$BLUE[*] Cloning KernelSU (waydroid branch)...$RESET"
git clone "$KSU_GIT" -b "$KSU_BRANCH" --depth=1

echo -e "$BLUE[*] Cloning kernelsu-dkms PKGBUILD...$RESET"
git clone "$DKMS_GIT" -b master --depth=1 2>/dev/null; or true

echo -e "$BLUE[*] Downloading modloader...$RESET"
curl -fsSL "$MODLOADER_URL" -o modloader
chmod +x modloader

# extract version info
set KSU_VER (grep -m1 '^pkgver=' kernelsu-dkms/PKGBUILD 2>/dev/null | cut -d'=' -f2; or echo '0.0.1')
set KSU_GIT_VER (git -C KernelSU rev-list --count HEAD)
set DKMS_DIR "/usr/src/kernelsu-$KSU_VER"

echo -e "$BLUE[*] KernelSU version: $KSU_VER (git rev: $KSU_GIT_VER)$RESET"

# setup dkms source
rm -rf "$DKMS_DIR"
cp -r KernelSU/kernel "$DKMS_DIR"
cp -r kernelsu-dkms/{dkms.conf,Makefile} "$DKMS_DIR" 2>/dev/null; or true

sed -i "s|@PKGVER@|$KSU_VER|g; s|@KSU_GIT_VERSION@|$KSU_GIT_VER|g;" "$DKMS_DIR/dkms.conf"

# build with dkms
echo -e "$BLUE[*] Building KernelSU with DKMS...$RESET"
dkms install "kernelsu/$KSU_VER" 2>/dev/null; or dkms build "kernelsu/$KSU_VER"

# install utilities
echo -e "$BLUE[*] Installing utilities...$RESET"
install -Dm755 kernelsu-dkms/00-kernelsu.conf /etc/modprobe.d/00-kernelsu.conf 2>/dev/null; or true
install -Dm755 kernelsu-dkms/load-kernelsu.in /usr/bin/load-kernelsu 2>/dev/null; or true
install -Dm755 modloader /usr/bin/modloader

# relax seccomp for waydroid
if test -f /var/lib/waydroid/lxc/waydroid/waydroid.seccomp
  echo -e "$BLUE[*] Relaxing seccomp restrictions for Waydroid...$RESET"
  sed -i '/reboot/d' /var/lib/waydroid/lxc/waydroid/waydroid.seccomp
end

# download manager APK
echo -e "$BLUE[*] Downloading KernelSU Manager APK...$RESET"
mkdir -p "$INSTALL_DIR"
set MANAGER_PATH "$INSTALL_DIR/KernelSU-Manager.apk"
curl -fsSL "$MANAGER_URL" -o "$MANAGER_PATH" 2>/dev/null
if test $status -ne 0
  echo -e "$YELLOW[!] Could not download manager APK from release. Build it from the workflow.$RESET"
  set MANAGER_PATH "(not downloaded - trigger workflow build first)"
end

echo
echo -e "$GREEN============================================$RESET"
echo -e "$GREEN[+] KernelSU Waydroid installed successfully!$RESET"
echo
echo -e "$GREEN[+] Load KernelSU:$RESET  sudo load-kernelsu"
echo -e "$GREEN[+] Repo:$RESET           $REPO_URL"
if test -f "$MANAGER_PATH"
  echo -e "$GREEN[+] Manager APK:$RESET    $MANAGER_PATH"
end
echo -e "$GREEN============================================$RESET"
echo
