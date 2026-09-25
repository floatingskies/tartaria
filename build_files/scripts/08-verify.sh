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

# a unit whose ExecStart target does not exist fails at boot, not at build time
#
# systemd lets the executable carry a prefix that changes how it is run, so a
# bare "ExecStart=" match drops everything: "-" and "@" ignore failure, "+"
# raises privileges, "!" runs in a namespace. The prefix has to be stripped
# before the path is tested, or those units silently escape the check.
while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    [[ -e "$path" ]] || fail "unit points at a missing executable: ${path}"
done < <(
    grep -rhoE '^ExecStart=[^[:space:]]+' /usr/lib/systemd/system /etc/systemd/system 2>/dev/null \
        | sed -E 's|^ExecStart=||' \
        | sed -E 's|^[-+@!]+||' \
        | grep '^/' | sort -u
)

## default shell and home

# Nothing in the image creates a user: the greeter is a login screen, not a
# setup flow. Whoever does it has to land on fish in /var/home, and that comes
# from these two values, so they are checked rather than assumed.
  if [[ -r /etc/default/useradd ]]; then
      # read each value out first so the failure message can name it, instead
      # of building a multiline string with a command substitution inside it
      useradd_value() { grep -E "^$1=" /etc/default/useradd | head -1 | cut -d= -f2-; }
      for pair in "SHELL=/usr/bin/fish" "HOME=/var/home" "SKEL=/etc/skel"; do
          key="${pair%%=*}"
          want="${pair#*=}"
          got="$(useradd_value "$key")"
          [[ "$got" == "$want" ]] \
              || fail "/etc/default/useradd sets $key='${got}', expected '$want'"
      done
  else
      fail "/etc/default/useradd is missing"
  fi

[[ -s /usr/bin/fish ]] || fail "fish is not installed but is the default shell"
[[ -d /etc/skel/.config/fish ]] || fail "skel has no fish configuration"

## bootloader chain

# the sealed images copy shim out of this package; if it did not build, the
# UKI is produced and the machine still cannot boot
if [[ "$IMAGE_VARIANT" == *maraska || "$IMAGE_VARIANT" == *saffron ]]; then
    [[ -f /usr/share/shim-signed/shimx64.efi ]] \
        || fail "shim-signed is missing; the sealed bootloader chain is incomplete"
fi

## root account

# the image ships with root locked on purpose
if passwd -S root 2>/dev/null | grep -q '^root P '; then
    fail "root has a usable password; it must be locked"
fi

(( failures == 0 )) || die "$failures verification failure(s) above"

echo "[build-note] all image checks passed"
echo "::endgroup::"
