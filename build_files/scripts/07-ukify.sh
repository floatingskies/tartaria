#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only

echo "::group::===========================> Create Signed UKI"

# setup
# shellcheck source=build_files/config/00-functions
source /config/00-functions
set -euo pipefail

# the kernel to sign for: exactly one tree must have been split off
mapfile -t kernels < <(find /kernel -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
case ${#kernels[@]} in
    1) kver="${kernels[0]}" ;;
    0) die "no kernel directory found under /kernel" ;;
    *) die "expected exactly one kernel under /kernel, found: ${kernels[*]}" ;;
esac

printf '[build-note] signing UKI for kernel %s\n' "$kver"
[[ -f "/kernel/${kver}/vmlinuz" ]] || die "vmlinuz missing for kernel ${kver}"

# output layout expected by the calling stage
install -d -m 0755 /out/uki /out/boot /var/tmp

retry pacman -S --noconfirm --needed systemd-ukify sbsigntool

bootc container ukify \
    --rootfs /target \
    --kernel-dir "/kernel/${kver}" \
    -- \
    --output "/out/uki/${kver}.efi" \
    --signtool sbsign \
    --secureboot-private-key /run/secrets/secureboot_key \
    --secureboot-certificate /run/secrets/secureboot_cert

[[ -s "/out/uki/${kver}.efi" ]] || die "ukify produced no UKI at /out/uki/${kver}.efi"

# sign the systemd-boot binary that the UKI chain loads
bootctl="/target/usr/lib/systemd/boot/efi/systemd-bootx64.efi"
[[ -f "$bootctl" ]] || die "systemd-boot binary not found at $bootctl"

sbsign \
    --key /run/secrets/secureboot_key \
    --cert /run/secrets/secureboot_cert \
    --output /out/boot/grubx64.efi \
    "$bootctl"

[[ -s /out/boot/grubx64.efi ]] || die "sbsign produced no signed bootloader"

rm -rf /var/tmp

echo "::endgroup::"
