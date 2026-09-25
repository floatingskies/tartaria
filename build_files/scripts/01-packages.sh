#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only

echo "::group::===========================> Install system packages"

# setup
# shellcheck source=build_files/config/00-functions
source /config/00-functions
set -euxo pipefail

# build logs are kept for inspection, 00-base.sh created the directory
install -d -m 0755 /tmp/build

## Official repositories

mapfile -t packages < <(grep -vE '^[[:space:]]*(#|$)' /config/01-sys-pkgs)

# kernel per flavour. CachyOS keeps the NVIDIA driver in a split package that
# shares the base kernel's module tree, so the tree is always recorded from the
# base package, never from the -nvidia-open one.
KERNEL_PACKAGE=""
case "$IMAGE_FLAVOR" in
    arch-maraska|arch-berbere)
        packages+=(linux)
        KERNEL_PACKAGE="linux"
        ;;
    arch-saffron|arch-amchoor)
        packages+=(linux nvidia-open nvidia-utils)
        KERNEL_PACKAGE="linux"
        ;;
    cachy-maraska|cachy-berbere)
        packages+=(linux-cachyos-bore scx-scheds scx-manager)
        KERNEL_PACKAGE="linux-cachyos-bore"
        ;;
    cachy-saffron|cachy-amchoor)
        packages+=(linux-cachyos-bore linux-cachyos-bore-nvidia-open scx-scheds scx-manager nvidia-utils)
        KERNEL_PACKAGE="linux-cachyos-bore"
        ;;
    *)
        die "unknown IMAGE_FLAVOR '$IMAGE_FLAVOR'"
        ;;
esac

# Keep the transaction log so a failure is diagnosable rather than a bare
# exit status. pacman's exit code is what says whether the transaction
# committed; the log is kept for when it did not.
pacman_log="/tmp/build/pacman.log"
if ! retry pacman -S --noconfirm --needed "${packages[@]}" >"$pacman_log" 2>&1; then
    cat "$pacman_log" >&2
    die "pacman failed to install the system package set; see $pacman_log"
fi

# A hook or scriptlet that cannot be executed prints "error: command failed to
# execute correctly" and pacman still exits 0, having committed the
# transaction. That is not a reason to fail the build: some hooks expect a
# running systemd, which a build container does not have. Report it, and let
# record_kernel and 08-verify.sh decide whether anything is actually missing.
if grep -q '^error:' "$pacman_log"; then
    printf '[build-warning] pacman reported errors during the transaction:\n' >&2
    grep '^error:' "$pacman_log" | sort -u | sed 's/^/  /' >&2
fi

# remember which kernel was installed; modsign and finalize need the tree
record_kernel "$KERNEL_PACKAGE"

## AUR packages

# Upstream's approach: clone yay-bin, then let it install the list in
# 02-aur-pkgs. yay is what resolves the AUR-to-AUR dependencies, and it is
# what handles split packages, since it clones the package base rather than
# the empty per-package repository.
#
# AUR repositories are mutable and their PKGBUILDs run arbitrary code during
# the build, so this is not reproducible. That is a deliberate trade: the list
# of what goes in is explicit and reviewable, but the exact tree behind each
# name is whatever the branch held that day.

# create build user
useradd -m builder
mkdir -p /etc/sudoers.d
echo "builder ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/builder
chmod 0440 /etc/sudoers.d/builder

# clone yay-bin and install it
retry runuser -u builder -- bash -c "git clone https://aur.archlinux.org/yay-bin.git /home/builder/yay-bin" >/dev/null
retry runuser -u builder -- bash -c "cd /home/builder/yay-bin && makepkg -si --noconfirm" >/dev/null
rm -rf /home/builder/yay-bin

# install AUR packages
#
# The log is written to /tmp/build/yay.log, so the failure path reads and
# cleans up that same path. Upstream pointed both at /tmp/yay.log, which does
# not exist, so a failing AUR install printed no reason at all.
if ! retry runuser -u builder -- bash -c "xargs -a /config/02-aur-pkgs yay -S --noconfirm --needed" >/tmp/build/yay.log 2>&1; then
    cat /tmp/build/yay.log >&2
    exit 1
fi

# cleanup
userdel -r builder 2>/dev/null || userdel builder
rm -f /tmp/build/yay.log

build_aur_packages

echo "::endgroup::"
