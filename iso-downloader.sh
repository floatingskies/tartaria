#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only

# once upon a time
set -euo pipefail

# make sure we can actually do any of this
if ! command -v podman >/dev/null 2>&1; then
    echo "[!!!] podman is required, but was not found in your PATH." >&2
    exit 1
fi

# clear term
clear

# define variants and their tags
bases=( "Arch" "CachyOSv3" )
base_prefixes=( "arch" "cachy" )
flavors=( "saffron" "amchoor" "maraska" "berbere" )

# define cleanup step
cleanup() {
    podman rmi -fi ghcr.io/sigstore/cosign/cosign:v3.1.3 >/dev/null 2>&1 || true
    podman rmi -fi ghcr.io/oras-project/oras:v1.3.4 >/dev/null 2>&1 || true
    trap - ERR
}

# choose <header> <question> <options-array> <answer-variable>
#
# ask until one of the numbered options is picked
choose() {
    local header="$1" question="$2" options_name="$3" answer_name="$4"
    local -n options="$options_name"
    local answer i

    while true; do
        echo "[---] $header"
        echo "[---] $question"
        echo
        for i in "${!options[@]}"; do
            printf "[-%d-] %s\n" "$((i + 1))" "${options[$i]}"
        done
        echo

        # read a whole line, a bare -n 1 would leave the trailing newline in the
        # buffer and hand an empty answer to the next question
        read -r -p "[-?-] >> " answer || answer=""
        answer="${answer:0:1}"
        echo

        if [[ "$answer" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= ${#options[@]} )); then
            printf -v "$answer_name" '%s' "$answer"
            clear
            return 0
        fi

        echo "[!!!] Invalid choice. Please try again."
        sleep 1
        clear
    done
}

# read user answer (base selection)
choose "ISO Selection" "What base of Tartaria do you want? (enter the corresponding number)" bases base_answer

# read user answer (NVIDIA drivers)
# shellcheck disable=SC2034  # read back through the nameref in choose()
nvidia_options=( "Yes" "No" )
# shellcheck disable=SC2154  # assigned by choose() via printf -v
choose "ISO Selection" "Do you need preinstalled NVIDIA drivers? (enter the corresponding number)" nvidia_options nvidia_answer

# read user answer (Sealed/Unsealed)
# shellcheck disable=SC2034  # read back through the nameref in choose()
sealed_options=( "Sealed" "Unsealed" )
# shellcheck disable=SC2154  # assigned by choose() via printf -v
choose "ISO Selection" "Do you want the sealed or unsealed variant? (enter the corresponding number)" sealed_options sealed_answer

# resolve tag & display name
# shellcheck disable=SC2154  # both assigned by choose() via printf -v
flavor_idx=$(( (nvidia_answer - 1) * 2 + (sealed_answer - 1) ))
flavor="${flavors[$flavor_idx]}"
tag="${base_prefixes[$((base_answer - 1))]}-${flavor}"
name="${bases[$((base_answer - 1))]}-${flavor^}"
iso="$HOME/Downloads/tartaria-iso"

# prepare download dir & pull images
echo "[1/3] Preparing."
trap 'cleanup && echo && echo "[!!!] Something went wrong during preparation. Please re-run this script."' ERR
rm -rf "$iso"
mkdir -p "$iso"
podman pull -q ghcr.io/sigstore/cosign/cosign:v3.1.3
podman pull -q ghcr.io/oras-project/oras:v1.3.4

echo "[2/3] Downloading ${name} ISO."
echo "[-i-] Please do not interrupt the download process. This may take a while."
trap 'cleanup && echo && echo "[!!!] ISO did not pass verification. Report this issue immediately."' ERR
podman run --rm -v "$iso":/workspace ghcr.io/sigstore/cosign/cosign:v3.1.3 verify \
  "ghcr.io/tartaria-dev/tartaria-iso:${tag}" \
  --certificate-identity="https://github.com/tartaria-dev/tartaria/.github/workflows/build-iso.yml@refs/heads/live" \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com" >/dev/null
trap 'cleanup && echo && echo "[!!!] ISO failed to download. Check your connection and re-run this script."' ERR
podman run --rm -v "$iso":/workspace ghcr.io/oras-project/oras:v1.3.4 \
    pull "ghcr.io/tartaria-dev/tartaria-iso:${tag}"

# finalize
if [[ ! -s "$iso/iso/tartaria-${tag}.iso" ]]; then
    echo "[!!!] $iso/iso/tartaria-${tag}.iso is missing, the download did not produce an image." >&2
    exit 1
fi

mv "$iso/iso/tartaria-${tag}.iso" "$iso/tartaria.iso"
rmdir "$iso/iso"

# cleanup
echo "[3/3] Cleaning up."
cleanup
clear

# say goodbye
echo "[-i-] Success!"
echo "[-i-] Your ${name} ISO is located at '$iso/tartaria.iso'."
