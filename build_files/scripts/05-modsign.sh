#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only

echo "::group::===========================> Sign NVIDIA modules"

# setup
source /config/00-functions
set -euxo pipefail

# if image spice is not saffron, skip
if [[ "$IMAGE_FLAVOR" != *saffron ]]; then
    echo "Skipping, image spice is not 'saffron'."
    echo "::endgroup::"
    exit 0
fi

# set kernel version
KERNEL_VERSION="$(kernel_version)"

# the headers package always follows the kernel package
headers=""
if [[ -r /usr/lib/tartaria/kernel-info ]]; then
    # shellcheck source=/dev/null
    source /usr/lib/tartaria/kernel-info
    headers="$KERNEL_HEADERS"
else
    case "$IMAGE_FLAVOR" in
        arch*)  headers="linux-headers" ;;
        cachy*) headers="linux-cachyos-bore-headers" ;;
    esac
    echo "[!!!] No kernel info recorded, assuming $headers." >&2
fi

# install headers
retry pacman -S --noconfirm --needed "$headers"

# sign nvidia kernel modules
while IFS= read -r -d '' mod; do
    orig="$mod"
    case "$mod" in
        *.zst) zstd -d --rm "$mod"; mod="${mod%.zst}" ;;
        *.xz)  xz -d --rm "$mod";   mod="${mod%.xz}" ;;
    esac

    /usr/lib/modules/${KERNEL_VERSION}/build/scripts/sign-file sha256 /run/secrets/module_key /run/secrets/module_cert "$mod"

    case "$orig" in
        *.zst) zstd --rm "$mod" ;;
        *.xz)  xz --rm "$mod" ;;
    esac
done < <(find "/usr/lib/modules/${KERNEL_VERSION}" -name 'nvidia*.ko*' -print0)

# remove headers
pacman -Rns --noconfirm "$headers"

# export module cert
mkdir -p /usr/share/tartaria/certs
openssl x509 -in /run/secrets/module_cert -outform DER -out /usr/share/tartaria/certs/modules.der

echo "::endgroup::"
