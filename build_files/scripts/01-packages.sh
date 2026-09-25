#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only

echo "::group::===========================> Install system packages"

# setup
source /config/00-functions
set -euxo pipefail

# build logs are kept for inspection, 00-base.sh created the directory
mkdir -p /tmp/build

# kernel package, recorded for the later build stages
KERNEL_PACKAGE=""

## Non-AUR packages

# import package list as an array
mapfile -t packages < <(grep -vE '^[[:space:]]*(#|$)' /config/01-sys-pkgs)

# based on image flavor, install arch/cachy kernel and/or nvidia-open drivers
case "$IMAGE_FLAVOR" in
    arch-maraska|arch-berbere)
        packages+=("linux")
        KERNEL_PACKAGE="linux"
        ;;
    arch-saffron|arch-amchoor)
        packages+=("linux" "nvidia-open" "nvidia-utils")
        KERNEL_PACKAGE="linux"
        ;;
    cachy-maraska|cachy-berbere)
        packages+=("linux-cachyos-bore" "scx-scheds" "scx-manager")
        KERNEL_PACKAGE="linux-cachyos-bore"
        ;;
    cachy-saffron|cachy-amchoor)
        packages+=("linux-cachyos-bore-nvidia-open" "linux-cachyos-bore" "scx-scheds" "scx-manager" "nvidia-utils")
        KERNEL_PACKAGE="linux-cachyos-bore"
        ;;
esac

# install non-AUR packages
retry pacman -S --noconfirm --needed "${packages[@]}" >/dev/null
retry pacman -S --noconfirm --needed libva-mesa-driver >/dev/null

# remember which kernel was installed, modsign and finalize need it
record_kernel "$KERNEL_PACKAGE"

## AUR packages

# create build user
useradd -m builder
mkdir -p /etc/sudoers.d
echo "builder ALL=(ALL) NOPASSWD: ALL" >/etc/sudoers.d/builder

# clone yay-bin and install it
retry runuser -u builder -- bash -c "git clone https://aur.archlinux.org/yay-bin.git /home/builder/yay-bin" >/dev/null
retry runuser -u builder -- bash -c "cd /home/builder/yay-bin && makepkg -si --noconfirm" >/dev/null
rm -rf /home/builder/yay-bin

# install AUR packages
if ! retry runuser -u builder -- bash -c "xargs -a /config/02-aur-pkgs yay -S --noconfirm --needed" >/tmp/build/yay.log 2>&1; then
    cat /tmp/build/yay.log
    exit 1
fi
rm -f /tmp/build/yay.log

# cleanup
rm -f /etc/sudoers.d/builder
userdel -r builder 2>/dev/null || userdel builder

echo "::endgroup::"
