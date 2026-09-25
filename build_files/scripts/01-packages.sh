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

# Every AUR package is a mutable git repository whose PKGBUILD runs arbitrary
# code at build time, so each is pinned by commit in 02-aur-pkgs. That list is
# the contract: it says exactly what goes into the image, and building the
# pinned commit is what makes it reviewable.
#
# The list has an ordering problem of its own. A package can depend on another
# package that is also on the list, and if the dependent happens to come first
# then the dependency is not installed yet. Asking a helper to fetch it works,
# but the helper takes the branch head, so the build ends up with an unpinned
# version that may not match what the dependent was written against.
#
# So a missing dependency that is on the list is built from its pin first, and
# the helper is only reached for a dependency the list does not cover. That
# keeps every listed package pinned, which is the point of pinning it.

YAY_PIN="13e0a4754d106a9252b7479bf1b370fbe454fc48"
AUR_LIST=/config/02-aur-pkgs
AUR_WORK=/var/cache/aur

# splits_for <repo> -> the splits to install, or "-" when the repo is not split
splits_for() {
    local repo="$1"
    awk -v r="$repo" '$1 == r { print $2; exit }' "$AUR_LIST"
}

# commit_for <repo> -> the pinned commit
commit_for() {
    local repo="$1"
    awk -v r="$repo" '$1 == r { print $3; exit }' "$AUR_LIST"
}

# prepare <repo>
#
# clone at the pin and prove we are on it. Idempotent, so a package pulled in
# as a dependency is not cloned twice.
prepare() {
    local repo="$1" commit="$2" workdir="$AUR_WORK/$1" actual=""

    [[ -f "$workdir/PKGBUILD" ]] && return 0

    [[ "$commit" =~ ^[0-9a-f]{40}$ ]] \
        || die "no valid pin for AUR ${repo}: '${commit}'; refresh 02-aur-pkgs"

    printf '[build-note] AUR %s @ %.12s\n' "$repo" "$commit"
    rm -rf "$workdir"
    retry runuser -u builder -- git clone --no-checkout \
        "https://aur.archlinux.org/${repo}.git" "$workdir"
    runuser -u builder -- git -C "$workdir" fetch --depth 1 origin "$commit"

    # the pin must be reachable, otherwise this is a stale lock and the build
    # would silently fall back to the branch head
    runuser -u builder -- git -C "$workdir" checkout --detach "$commit" \
        || die "AUR pin ${repo}@${commit} is not reachable; refresh 02-aur-pkgs"

    actual=$(runuser -u builder -- git -C "$workdir" rev-parse HEAD)
    [[ "$actual" == "$commit" ]] \
        || die "AUR ${repo} checked out ${actual}, expected ${commit}"
    [[ -f "$workdir/PKGBUILD" ]] || die "AUR ${repo}@${commit} has no PKGBUILD"
}

# install_built <repo>
#
# install whatever makepkg produced for a prepared repo, taking only the
# splits that were asked for.
install_built() {
    local repo="$1" split_list="$2"
    local workdir="$AUR_WORK/$repo"
    local pkg="" found="" candidate=""
    local -a built=() wanted=() chosen=()

    if [[ "$split_list" == "-" ]]; then
        mapfile -t built < <(find "$workdir" -maxdepth 1 -name '*.pkg.tar.*' -type f | sort)
        (( ${#built[@]} > 0 )) || die "AUR ${repo} produced no package"
        # install as root: this stage already is root and pacman -U needs to
        # be. makepkg was only ever used to build here.
        pacman -U --noconfirm --needed "${built[@]}"
        return 0
    fi

    # A split: makepkg builds every split of the base, so install only the
    # ones that were asked for.
    #
    # The glob is anchored on a digit right after the package name, and the
    # [0-9] has to stay outside the quotes or it is literal. A plain "${pkg}-*"
    # would also match a longer split whose name starts with this one, so
    # asking for maplemono-ttf would happily install maplemono-ttf-autohint.
    IFS=',' read -r -a wanted <<<"$split_list"
    for pkg in "${wanted[@]}"; do
        pkg="${pkg//[[:space:]]/}"
        [[ -n "$pkg" ]] || continue
        found=""
        for candidate in "$workdir/${pkg}"-[0-9]*.pkg.tar.*; do
            [[ -f "$candidate" ]] || continue
            found="$candidate"
            break
        done
        [[ -n "$found" ]] || die "split '${pkg}' was not produced by AUR ${repo}"
        chosen+=("$found")
    done
    (( ${#chosen[@]} > 0 )) || die "no splits selected for AUR ${repo}"
    printf '[build-note] installing split(s): %s\n' "${chosen[*]##*/}"
    pacman -U --noconfirm --needed "${chosen[@]}"
}

# build_and_install <repo> [visiting...]
#
# Build one listed package. When makepkg reports a target it cannot find, that
# dependency is built from its own pin first if the list covers it, so the
# dependent is always compiled against the version that was pinned rather than
# whatever the branch held. Only a dependency the list does not cover goes to
# the helper.
build_and_install() {
    local repo="$1"; shift
    local visiting=("$@")
    local dep="" log="/tmp/build/aur-${repo}.log"
    local local_split="" commit=""
    local -a seen=("${visiting[@]}")

    for dep in "${seen[@]}"; do
        [[ "$dep" == "$repo" ]] && die "AUR dependency cycle: ${seen[*]} -> $repo"
    done

    local_split="$(splits_for "$repo")"
    commit="$(commit_for "$repo")"
    prepare "$repo" "$commit"

    for _ in 1 2 3 4 5; do
        if runuser -u builder -- bash -c \
            "cd '$AUR_WORK/$repo' && makepkg -s --noconfirm --cleanbuild --noprepare" \
            >"$log" 2>&1; then
            install_built "$repo" "$local_split"
            return 0
        fi

        # "error: target not found: <name>" is a dependency makepkg cannot
        # satisfy from the configured repositories. Anything else is a real
        # build failure and must not be retried into looking like one.
        dep=$(grep -oE "^error: target not found: [^ ]+" "$log" \
            | head -1 | sed 's/^error: target not found: //' \
            | sed 's/[<>=].*$//' || true)

        if [[ -z "$dep" ]]; then
            printf '[build-error] AUR %s failed to build\n' "$repo" >&2
            cat "$log" >&2
            return 1
        fi

        if [[ -n "$(commit_for "$dep")" ]]; then
            printf '[build-note] AUR %s needs %s, which is pinned here; building it first\n' \
                "$repo" "$dep" >&2
            build_and_install "$dep" "${seen[@]}" "$repo" || return 1
            continue
        fi

        printf '[build-note] AUR %s needs %s, which is not on the list; asking the helper\n' \
            "$repo" "$dep" >&2
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
    local -a repos=()
    local repo="" commit=""

    while read -r repo _ commit; do
        [[ -n "$repo" ]] || continue
        repos+=("$repo")
        # every pin must be a real commit, never the literal that marks an
        # unresolved entry
        [[ "$commit" =~ ^[0-9a-f]{40}$ ]] \
            || die "AUR pin for ${repo} is not a commit: '${commit}'"
    done < <(grep -vE '^[[:space:]]*(#|$)' "$AUR_LIST")

    (( ${#repos[@]} > 0 )) || { echo "no AUR packages configured"; return 0; }

    # AUR packages must never be built as root, so the build runs as an
    # unprivileged user. The user has to exist before its scratch directory is
    # created, because the directory has to be owned by them: git clone refuses
    # to create a work tree inside a root-owned 0755 directory.
    install -d -m 0755 /etc/sudoers.d
    useradd --create-home --shell /bin/bash builder
    printf 'builder ALL=(ALL) NOPASSWD: ALL\n' >/etc/sudoers.d/builder
    chmod 0440 /etc/sudoers.d/builder
    install -d -m 0755 -o builder -g builder "$AUR_WORK"

    # the helper, at its own pin: the original code cloned yay-bin's branch
    # head, so the tool doing the installing could change underneath the build
    # without any commit mentioning it
    printf '[build-note] building yay @ %.12s\n' "$YAY_PIN"
    retry runuser -u builder -- git clone --no-checkout \
        https://aur.archlinux.org/yay-bin.git "$AUR_WORK/yay"
    runuser -u builder -- git -C "$AUR_WORK/yay" fetch --depth 1 origin "$YAY_PIN"
    runuser -u builder -- git -C "$AUR_WORK/yay" checkout --detach "$YAY_PIN" \
        || die "yay pin $YAY_PIN is not reachable"
    runuser -u builder -- bash -c \
        "cd '$AUR_WORK/yay' && makepkg -s --noconfirm --cleanbuild --noprepare" \
        >/tmp/build/yay.log 2>&1 \
        || { cat /tmp/build/yay.log >&2; die "failed to build yay"; }
    local -a yaypkg=()
    mapfile -t yaypkg < <(find "$AUR_WORK/yay" -maxdepth 1 -name 'yay-*.pkg.tar.*' -type f | sort)
    (( ${#yaypkg[@]} > 0 )) || die "yay produced no package"
    pacman -U --noconfirm --needed "${yaypkg[@]}"

    for repo in "${repos[@]}"; do
        build_and_install "$repo" || exit 1
    done

    # cleanup
    rm -rf "$AUR_WORK"
    rm -f /etc/sudoers.d/builder
    userdel -r builder 2>/dev/null || userdel builder
}

build_aur_packages

echo "::endgroup::"
