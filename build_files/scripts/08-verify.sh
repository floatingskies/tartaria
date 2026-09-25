#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
#
# Self-check for the assembled image. Runs last, after every other stage, and
# verifies the things that are easy to get quietly wrong: a unit that is
# enabled but does not exist, a kernel tree that is not the one that was
# recorded, a module that is not actually signed, an identity that still
# claims to be plain Arch.
#
# Every check either passes or stops the build. Nothing here is advisory.

echo "::group::===========================> Verify image"

# setup
# shellcheck source=build_files/config/00-functions
source /config/00-functions
set -euo pipefail

failures=0

fail() {
    printf '[build-error] %s\n' "$*" >&2
    failures=$(( failures + 1 ))
}

## host identity

if [[ -r /usr/lib/os-release ]]; then
    # shellcheck disable=SC1091
    . /usr/lib/os-release
    [[ "${ID:-}" == "arch" || "${ID:-}" == "cachyos" ]] \
        || fail "unexpected ID='${ID:-}' in os-release"
    [[ -n "${PRETTY_NAME:-}" ]] || fail "PRETTY_NAME is unset"
    case "${PRETTY_NAME:-}" in
        *Tartaria*) ;;
        *) fail "PRETTY_NAME does not identify the image: ${PRETTY_NAME:-}" ;;
    esac
    # the privacy policy URL must still point at the real policy
    case "${PRIVACY_POLICY_URL:-}" in
        *archlinux.org*) ;;
        *) fail "PRIVACY_POLICY_URL was mangled: ${PRIVACY_POLICY_URL:-}" ;;
    esac
else
    fail "/usr/lib/os-release is missing"
fi

[[ -s /usr/lib/tartaria/variant ]] || fail "variant file is missing"

## kernel

kver="$(kernel_version)" || fail "no usable kernel module tree"
if [[ -n "${kver:-}" ]]; then
    [[ -d "/usr/lib/modules/$kver" ]] || fail "module tree $kver is not on disk"
    [[ -e "/usr/lib/modules/$kver/initramfs.img" ]] \
        || fail "no initramfs was built for $kver"
fi

## Secure Boot material

if [[ "$IMAGE_VARIANT" == *saffron || "$IMAGE_VARIANT" == *maraska ]]; then
    [[ -s /usr/share/tartaria/certs/secureboot.der ]] \
        || fail "secureboot certificate was not exported"
fi

if [[ "$IMAGE_FLAVOR" == *saffron ]]; then
    [[ -s /usr/share/tartaria/certs/modules.der ]] \
        || fail "module signing certificate was not exported"
fi

## modules

# every nvidia module in the tree must carry a signature, or the machine
# refuses to boot under Secure Boot and says nothing useful about why
while IFS= read -r -d '' mod; do
    case "$mod" in
        *.zst) zstd -dc "$mod" >/tmp/.verify.mod 2>/dev/null || true ;;
        *.xz)  xz -dc  "$mod" >/tmp/.verify.mod 2>/dev/null || true ;;
        *)     cp "$mod" /tmp/.verify.mod 2>/dev/null || true ;;
    esac
    if [[ -s /tmp/.verify.mod ]] && \
       ! tail -c 64 /tmp/.verify.mod | grep -qa "Module signature appended"; then
        fail "unsigned NVIDIA module: ${mod}"
    fi
    rm -f /tmp/.verify.mod
done < <(find /usr/lib/modules -name 'nvidia*.ko*' -print0 2>/dev/null)

## units the shell model depends on

# these are the units whose absence silently changes what the user gets, so
# they are checked by name rather than inferred from the enabled set
for unit in \
    home.mount mnt.mount opt.mount root.mount srv.mount \
    usr-share-tartaria-cherries.mount \
    refresh-font-cache.service subsystem-filesystemd.service \
    greetd.service NetworkManager.service
do
    systemctl cat "$unit" >/dev/null 2>&1 \
        || fail "expected unit is not shipped: ${unit}"
done

# the mutable subsystem must start on demand, never at login
if [[ -e /etc/systemd/user/subsystem-containerd.service \
   || -e /usr/lib/systemd/user/subsystem-containerd.service ]]; then
    if [[ -L /etc/systemd/user/default.target.wants/subsystem-containerd.service \
       || -L /etc/systemd/user/graphical-session.target.wants/subsystem-containerd.service ]]; then
        fail "subsystem-containerd is enabled at login; it must start on demand"
    fi
fi

# an enabled unit whose ExecStart target does not exist fails at boot, not at
# build time
while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    [[ -e "$path" ]] || fail "enabled unit points at a missing executable: ${path}"
done < <(
    grep -rhoE '^ExecStart=.*' /usr/lib/systemd/system /etc/systemd/system 2>/dev/null \
        | sed -E 's|^ExecStart=[^ ]* *||; s|^-[a-zA-Z]+ *||' \
        | awk '{print $1}' | grep '^/' | sort -u
)

## root account

# the image ships with root locked on purpose
if passwd -S root 2>/dev/null | grep -q '^root P '; then
    fail "root has a usable password; it must be locked"
fi

(( failures == 0 )) || die "$failures verification failure(s) above"

echo "[build-note] all image checks passed"
echo "::endgroup::"
