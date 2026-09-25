#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
#
# Re-resolve the pinned base image digests from the registry and rewrite the
# FROM / COPY --from lines in the containerfiles.
#
#   build_files/images/refresh-pins.sh          # update the pins in place
#   build_files/images/refresh-pins.sh --check  # fail if anything drifted
#
# This talks to the registry directly so it needs nothing but curl and python,
# and it never guesses: an image it cannot resolve is an error, not a skip.

set -euo pipefail

cd "$(dirname "$0")/../.."

LOCK="build_files/images/BASE-IMAGES.lock"
CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

# resolve <ref> -> digest, using the registry's anonymous pull token
resolve() {
    local ref="$1" tag="latest" first reg path tok digest

    if [[ "$ref" == *:* && "$ref" != *::* ]]; then
        case "${ref##*:}" in
            latest|[0-9]*|[a-z]*) tag="${ref##*:}"; ref="${ref%:*}" ;;
        esac
    fi

    first="${ref%%/*}"
    if [[ "$ref" == */* && ( "$first" == *.* || "$first" == *:* || "$first" == "localhost" ) ]]; then
        reg="$first"; path="${ref#*/}"
    elif [[ "$ref" == */* ]]; then
        reg="registry-1.docker.io"; path="$ref"
    else
        reg="registry-1.docker.io"; path="library/$ref"
    fi

    # normalise the Docker Hub hostname so the token lookup below matches
    case "$reg" in
        docker.io|index.docker.io|registry.hub.docker.com) reg="registry-1.docker.io" ;;
    esac

    case "$reg" in
        registry-1.docker.io)
            tok=$(curl -fsS "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${path}:pull" \
                  | python3 -c 'import json,sys;print(json.load(sys.stdin).get("token",""))')
            ;;
        ghcr.io)
            tok=$(curl -fsS "https://ghcr.io/token?scope=repository:${path}:pull" \
                  | python3 -c 'import json,sys;print(json.load(sys.stdin).get("token",""))')
            ;;
        quay.io)
            tok=$(curl -fsS "https://quay.io/v2/auth?service=quay.io&scope=repository:${path}:pull" \
                  | python3 -c 'import json,sys;print(json.load(sys.stdin).get("token",""))')
            ;;
        *)
            tok=""
            ;;
    esac

    local -a auth=()
    [[ -n "$tok" ]] && auth=(-H "Authorization: Bearer $tok")

    digest=$(curl -fsS "${auth[@]}" -D- -o /dev/null \
        -H 'Accept: application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json' \
        "https://${reg}/v2/${path}/manifests/${tag}" \
        | tr -d '\r' | awk 'tolower($1)=="docker-content-digest:"{print $2}')

    [[ -n "$digest" ]] || { printf 'could not resolve %s\n' "$ref" >&2; return 1; }
    printf '%s\n' "$digest"
}

mapfile -t pins < <(grep -E '^[a-z0-9./-]+:[a-z0-9.-]+[[:space:]]+sha256:' "$LOCK")

drift=0
declare -A resolved=()

for line in "${pins[@]}"; do
    read -r ref _ <<<"$line"
    printf 'resolving %-45s ' "$ref"
    if digest=$(resolve "$ref"); then
        printf '%s\n' "$digest"
        resolved["$ref"]="$digest"
    else
        printf 'FAILED\n' >&2
        exit 1
    fi
done

if (( CHECK_ONLY )); then
    for ref in "${!resolved[@]}"; do
        if ! grep -rqF "${ref}@${resolved[$ref]}" build_files/images build_files/addons; then
            printf 'drift: %s should be %s\n' "$ref" "${resolved[$ref]}" >&2
            drift=1
        fi
    done
    (( drift == 0 )) && echo "all base image pins are current"
    exit "$drift"
fi

for ref in "${!resolved[@]}"; do
    old=$(grep -rhoE "${ref}@sha256:[0-9a-f]{64}" build_files/images build_files/addons | sort -u | head -1)
    [[ -n "$old" ]] || { printf 'no pinned reference found for %s\n' "$ref" >&2; continue; }
    new="${ref}@${resolved[$ref]}"
    if [[ "$old" == "$new" ]]; then
        printf 'unchanged %s\n' "$ref"
        continue
    fi
    grep -rlF "$old" build_files/images build_files/addons | while read -r f; do
        sed -i "s|$old|$new|g" "$f"
    done
    printf 'updated   %s\n  %s\n  -> %s\n' "$ref" "$old" "$new"

    # keep the lock file in step with what the containerfiles now use
    sed -i "s|^${ref}[[:space:]]\+sha256:.*|${ref} ${resolved[$ref]}|" "$LOCK"
done
