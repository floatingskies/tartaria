#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only

echo "::group::===========================> Prepare image build"

# setup
# shellcheck source=build_files/config/00-functions
source /config/00-functions
set -euxo pipefail

# build logs are kept for inspection
install -d -m 0755 /tmp/build

# relocate the /var paths pacman uses into /usr/lib/sysimage, which is what
# bootc's usroverlay expects: a read-only /usr cannot own a live package
# database or log. The paths come from pacman.conf itself rather than a
# hardcoded list, so a distro that moves them is followed automatically.
relocate_var_paths() {
    local path="" target="" moved=0

    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        [[ -e "$path" ]] || continue

        target="/usr/lib/sysimage${path#/var}"
        [[ -e "$target" ]] && continue

        # pacman.conf points at the new location whether the entry was a
        # directory (database, cache) or a file (the log), so both move
        install -d -m 0755 "$(dirname "$target")"
        mv -v "$path" "$target"
        moved=$(( moved + 1 ))
    done < <(
        # any option whose value is an absolute /var path, whatever it is
        # named, commented or not, with or without padding around '='
        sed -nE 's|^[[:space:]]*#?[[:space:]]*[A-Za-z][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*(/var/[^[:space:]]*)[[:space:]]*$|\1|p' \
            /etc/pacman.conf \
            | sed 's|/*$||' | sort -u
    )

    (( moved > 0 )) || die "no /var paths relocated; pacman.conf layout changed?"
    printf '[build-note] relocated %d /var path(s) into /usr/lib/sysimage\n' "$moved"
}

relocate_var_paths

# Uncomment the relocated /var options and repoint them, keeping the option
# name and its alignment. The key must survive: a line that lost its name is
# silently ignored by pacman, which then reads a database that is no longer
# where it expects.
sed -i \
    -e 's|^\([[:space:]]*\)#[[:space:]]*\([[:space:]]*[A-Za-z][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*\)/var/|\1\2/usr/lib/sysimage/|' \
    -e '/DownloadUser/d' \
    /etc/pacman.conf

# sanity check: the paths pacman was told to use must now be the paths that
# were actually moved
while IFS= read -r path; do
    [[ -e "$path" ]] || die "pacman.conf points at $path, which does not exist"
done < <(
    sed -nE 's|^[[:space:]]*#?[[:space:]]*[A-Za-z][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*(/usr/lib/sysimage/[^[:space:]]*)[[:space:]]*$|\1|p' \
        /etc/pacman.conf
)
pacman -Q bash >/dev/null 2>&1 || die "pacman database unreadable after relocation"

# CachyOS sandboxes network access in the downloader by default, which breaks
# the HTTP mirror used below
if [[ $IMAGE_FLAVOR == cachy* ]]; then
    sed -i '/^\[options\]/a DisableSandboxNetwork' /etc/pacman.conf

    # Replace the base image's mirrorlist with the CachyOS-operated nodes.
    #
    # The shipped list has two dozen community mirrors with cdn77.cachyos.org
    # first, and that node lags: it serves current repository databases but not
    # yet the packages they name, so pacman gets a burst of 404s, gives up on
    # the node, and fails the whole transaction with "failed to commit". Which
    # packages trip it changes week to week, so this is not reproducible.
    #
    # These three are CachyOS's own CDN and geo nodes. They are listed rather
    # than reduced to one so pacman can still fail over between them.
    cat >/etc/pacman.d/cachyos-v3-mirrorlist <<'MIRRORLIST'
# Managed by 00-base.sh. CachyOS-operated mirrors only; see the comment there
# for why the base image's list is not used.
Server = https://cdn.cachyos.org/repo/$arch_v3/$repo
Server = https://us.cachyos.org/repo/$arch_v3/$repo
Server = https://at.cachyos.org/repo/$arch_v3/$repo
MIRRORLIST
    printf '[build-note] using CachyOS-operated mirrors for the package set\n'
fi

# init keys
pacman-key --init
if [[ $IMAGE_FLAVOR == cachy* ]]; then
    pacman-key --populate archlinux cachyos
else
    pacman-key --populate archlinux
fi

# add the bootc package repo, pinned by key id
retry pacman-key --recv-key 5DE6BF3EBC86402E7A5C5D241FA48C960F9604CB --keyserver keyserver.ubuntu.com
retry pacman-key --lsign-key 5DE6BF3EBC86402E7A5C5D241FA48C960F9604CB
printf '\n[bootc]\nSigLevel = Required\nServer=https://github.com/hecknt/arch-bootc-pkgs/releases/download/$repo\n' >> /etc/pacman.conf

# perform system update
retry pacman -Syu --noconfirm --needed >/dev/null

echo "::endgroup::"
