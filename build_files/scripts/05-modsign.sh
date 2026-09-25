#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only

echo "::group::===========================> Sign NVIDIA modules"

# setup
# shellcheck source=build_files/config/00-functions
source /config/00-functions
set -euxo pipefail

# only the NVIDIA flavours ship NVIDIA modules, and the in-tree module
# signing key must be enrolled by the user at first boot
if [[ "$IMAGE_FLAVOR" != *saffron ]]; then
    echo "Skipping, image spice is not 'saffron'."
    echo "::endgroup::"
    exit 0
fi

# the module tree of the kernel that was actually installed
KERNEL_VERSION="$(kernel_version)"

# the headers package always follows the kernel package
if [[ ! -r /usr/lib/tartaria/kernel-info ]]; then
    die "no kernel info recorded; refusing to sign against a guessed kernel"
fi
# shellcheck source=/dev/null
source /usr/lib/tartaria/kernel-info
headers="$KERNEL_HEADERS"

# the signing tool lives in the kernel headers package
retry pacman -S --noconfirm --needed "$headers"
sign_file="/usr/lib/modules/${KERNEL_VERSION}/build/scripts/sign-file"
[[ -x "$sign_file" ]] || die "sign-file not found at $sign_file"

# Sign a single compressed module in place. The compressed original is kept
# until signing succeeded, so a failure never leaves a half-processed module
# behind for the next stage to trip over.
sign_module() {
    local module="$1" plain=""

    case "$module" in
        *.zst) plain="${module%.zst}" ;;
        *.xz)  plain="${module%.xz}" ;;
        *)     plain="$module" ;;
    esac

    if [[ "$plain" != "$module" ]]; then
        case "$module" in
            *.zst) zstd -d --rm "$module" ;;
            *.xz)  xz -d --rm "$module" ;;
        esac
    fi

    if ! "$sign_file" sha256 /run/secrets/module_key /run/secrets/module_cert "$plain"; then
        # put the original back before giving up
        case "$module" in
            *.zst) zstd -q "$plain" -o "$module" && rm -f "$plain" ;;
            *.xz)  xz -q "$plain" -o "$module" && rm -f "$plain" ;;
        esac
        die "failed to sign $plain"
    fi

    if [[ "$plain" != "$module" ]]; then
        case "$module" in
            *.zst) zstd -q --rm "$plain" ;;
            *.xz)  xz -q --rm "$plain" ;;
        esac
    fi
}

# collect the modules first: a pipeline that yields nothing must be an error
# here, because an unsigned module set means the machine does not boot under
# Secure Boot, and it would fail much later with a far less obvious error
mapfile -d '' modules < <(
    find "/usr/lib/modules/${KERNEL_VERSION}" \
        \( -name 'nvidia*.ko' -o -name 'nvidia*.ko.xz' -o -name 'nvidia*.ko.zst' \) \
        -print0
)

(( ${#modules[@]} > 0 )) || die "no NVIDIA modules found under /usr/lib/modules/${KERNEL_VERSION}"

printf '[build-note] signing %d NVIDIA module(s)\n' "${#modules[@]}"
for module in "${modules[@]}"; do
    sign_module "$module"
done

# the headers are only needed while signing
pacman -Rns --noconfirm "$headers"

# export the module signing certificate so the user can trust it at first boot
install -d -m 0755 /usr/share/tartaria/certs
openssl x509 -in /run/secrets/module_cert -outform DER -out /usr/share/tartaria/certs/modules.der

# verify what we just claimed: every module must now carry a signature
# appended by the in-tree module signer
unsigned=0
while IFS= read -r -d '' mod; do
    case "$mod" in
        *.zst) zstd -dc "$mod" >/tmp/.mod.check ;;
        *.xz)  xz -dc  "$mod" >/tmp/.mod.check ;;
        *)     cp "$mod" /tmp/.mod.check ;;
    esac
    # a signed module ends with the "~Module signature appended~" marker
    if ! tail -c 64 /tmp/.mod.check | grep -qa "Module signature appended"; then
        printf '[build-error] unsigned module: %s\n' "$mod" >&2
        unsigned=$(( unsigned + 1 ))
    fi
    rm -f /tmp/.mod.check
done < <(printf '%s\0' "${modules[@]}")

(( unsigned == 0 )) || die "$unsigned NVIDIA module(s) are still unsigned"

echo "::endgroup::"
