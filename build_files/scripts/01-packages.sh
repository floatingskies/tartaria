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

## AUR

# Every AUR package is a git repository that can change at any time, and its
# PKGBUILD runs arbitrary code at build time, so each one is pinned by commit
# in 02-aur-pkgs. The list is the contract: it says exactly what goes in.
#
# makepkg can only satisfy dependencies from the configured repositories, and
# several of these packages depend on other AUR packages, which pacman cannot
# see. So a helper is needed for that one job.
#
# yay is used only to satisfy AUR-to-AUR dependencies that makepkg reports as
# missing, and it is itself pinned: the original code cloned its branch head,
# so the helper silently changed under the build. Direct dependencies stay
# pinned; transitive AUR dependencies are resolved by yay at their branch
# heads, which is a known limit of doing this without a full solver.
YAY_PIN="13e0a4754d106a9252b7479bf1b370fbe454fc48"

# build an AUR package at its pin, retrying after asking yay to satisfy any
# AUR dependency makepkg cannot see
build_aur_repo() {
    local repo="$1" workdir="$2" log="/tmp/build/aur-${1}.log"
    local dep=""

    for _ in 1 2 3 4 5; do
        if runuser -u builder -- bash -c \
            "cd '$workdir' && makepkg -s --noconfirm --cleanbuild --noprepare" \
            >"$log" 2>&1; then
            return 0
        fi

        # "error: target not found: <name>" for something that is not in any
        # configured repository is an AUR dependency. Hand it to yay and try
        # again; anything else is a real build failure.
        dep=$(grep -oE "^error: target not found: [^ ]+" "$log" \
            | head -1 | sed 's/^error: target not found: //' \
            | sed 's/[<>=].*$//' || true)

        if [[ -z "$dep" ]]; then
            printf '[build-error] AUR %s failed to build\n' "$repo" >&2
            cat "$log" >&2
            return 1
        fi

        printf '[build-note] AUR %s needs %s; asking yay for it\n' "$repo" "$dep" >&2
        if ! runuser -u builder -- yay -S --noconfirm --needed --asdeps "$dep" \
            >"$log.dep" 2>&1; then
            printf '[build-error] could not satisfy AUR dependency %s of %s\n' \
                "$dep" "$repo" >&2
            cat "$log.dep" >&2
            return 1
        fi
    done

    printf '[build-error] AUR %s still failing after resolving its dependencies\n' \
        "$repo" >&2
    cat "$log" >&2
    return 1
}

build_aur_packages() {
    local -a repos=() splits=() commits=()
    local repo="" split_list="" commit="" workdir="" actual="" pkg="" found="" candidate=""
    local -a built=() wanted=()

    while read -r repo split_list commit; do
        [[ -n "$repo" ]] || continue
        repos+=("$repo")
        splits+=("$split_list")
        commits+=("$commit")
    done < <(grep -vE '^[[:space:]]*(#|$)' /config/02-aur-pkgs)

    (( ${#repos[@]} > 0 )) || { echo "no AUR packages configured"; return 0; }

    # every pin must be a real commit, never the literal that marks an
    # unresolved entry
    for i in "${!repos[@]}"; do
        [[ "${commits[$i]}" =~ ^[0-9a-f]{40}$ ]] \
            || die "AUR pin for ${repos[$i]} is not a commit: '${commits[$i]}'"
    done

    # AUR packages must never be built as root, so the build runs as an
    # unprivileged user. The user has to exist before its scratch directory is
    # created, because the directory has to be owned by them: git clone refuses
    # to create a work tree inside a root-owned 0755 directory.
    install -d -m 0755 /etc/sudoers.d
    useradd --create-home --shell /bin/bash builder
    printf 'builder ALL=(ALL) NOPASSWD: ALL\n' >/etc/sudoers.d/builder
    chmod 0440 /etc/sudoers.d/builder
    install -d -m 0755 -o builder -g builder /var/cache/aur

    # build the helper at its pin, not from whatever the branch holds
    printf '[build-note] building yay @ %.12s\n' "$YAY_PIN"
    retry runuser -u builder -- git clone --no-checkout \
        https://aur.archlinux.org/yay-bin.git /var/cache/aur/yay
    runuser -u builder -- git -C /var/cache/aur/yay fetch --depth 1 origin "$YAY_PIN"
    runuser -u builder -- git -C /var/cache/aur/yay checkout --detach "$YAY_PIN" \
        || die "yay pin $YAY_PIN is not reachable"
    runuser -u builder -- bash -c \
        "cd /var/cache/aur/yay && makepkg -s --noconfirm --cleanbuild --noprepare" \
        >/tmp/build/yay.log 2>&1 \
        || { cat /tmp/build/yay.log >&2; die "failed to build yay"; }
    mapfile -t -O "${#built[@]}" built < <(
        find /var/cache/aur/yay -maxdepth 1 -name 'yay-*.pkg.tar.*' -type f | sort
    )
    (( ${#built[@]} > 0 )) || die "yay produced no package"
    pacman -U --noconfirm --needed "${built[@]}"
    built=()

    for i in "${!repos[@]}"; do
        repo="${repos[$i]}"
        split_list="${splits[$i]}"
        commit="${commits[$i]}"
        workdir="/var/cache/aur/${repo}"

        printf '[build-note] AUR %s @ %.12s\n' "$repo" "$commit"
        rm -rf "$workdir"
        retry runuser -u builder -- git clone --no-checkout \
            "https://aur.archlinux.org/${repo}.git" "$workdir"
        runuser -u builder -- git -C "$workdir" fetch --depth 1 origin "$commit"

        # the pin must be reachable, otherwise this is a stale lock and the
        # build would silently fall back to the branch head
        runuser -u builder -- git -C "$workdir" checkout --detach "$commit" \
            || die "AUR pin ${repo}@${commit} is not reachable; refresh 02-aur-pkgs"

        # verify we really are building the pinned tree
        actual=$(runuser -u builder -- git -C "$workdir" rev-parse HEAD)
        [[ "$actual" == "$commit" ]] || die "AUR ${repo} checked out ${actual}, expected ${commit}"

        [[ -f "$workdir/PKGBUILD" ]] || die "AUR ${repo}@${commit} has no PKGBUILD"

        build_aur_repo "$repo" "$workdir" || exit 1

        if [[ "$split_list" == "-" ]]; then
            # not a split: install everything makepkg produced for it
            mapfile -t built < <(find "$workdir" -maxdepth 1 \
                -name '*.pkg.tar.*' -type f | sort)
            (( ${#built[@]} > 0 )) || die "AUR ${repo} produced no package"
            # install as root: this stage already is root, and pacman -U needs
            # to be. makepkg was only used to build, not to install.
            pacman -U --noconfirm --needed "${built[@]}"
        else
            # A split: makepkg builds every split of the base, so install only
            # the ones that were actually asked for.
            #
            # The glob is anchored on a digit right after the package name,
            # and the [0-9] must stay outside the quotes or it is literal.
            # A plain "${pkg}-*" would also match a longer split whose name
            # starts with this one, so asking for maplemono-ttf would happily
            # install maplemono-ttf-autohint.
            IFS=',' read -r -a wanted <<<"$split_list"
            local -a chosen=()
            for pkg in "${wanted[@]}"; do
                pkg="${pkg//[[:space:]]/}"
                [[ -n "$pkg" ]] || continue
                found=""
                for candidate in "$workdir/${pkg}"-[0-9]*.pkg.tar.*; do
                    [[ -f "$candidate" ]] || continue
                    found="$candidate"
                    break
                done
                [[ -n "$found" ]] \
                    || die "split '${pkg}' was not produced by AUR ${repo}@${commit}"
                chosen+=("$found")
            done
            (( ${#chosen[@]} > 0 )) || die "no splits selected for AUR ${repo}"
            printf '[build-note] installing split(s): %s\n' "${chosen[*]##*/}"
            pacman -U --noconfirm --needed "${chosen[@]}"
        fi
    done

    # cleanup
    rm -rf /var/cache/aur
    rm -f /etc/sudoers.d/builder
    userdel -r builder 2>/dev/null || userdel builder
}

build_aur_packages

echo "::endgroup::"
