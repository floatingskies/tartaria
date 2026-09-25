registry := env("BUILD_REGISTRY", "ghcr.io/tartaria-dev")
image_name := env("BUILD_IMAGE_NAME", "tartaria")
image_tag := env("BUILD_IMAGE_TAG", "latest")
base_dir := env("BUILD_BASE_DIR", ".")
filesystem := env("BUILD_FILESYSTEM", "ext4")
channel := env("BUILD_CHANNEL", "unstable")

# A flavor is one of arch-berbere, arch-amchoor, arch-maraska, arch-saffron and
# their cachy counterparts. The edition picks the base image, the layout picks
# between the nonsealed and the sealed containerfile.

# print the edition and layout of a flavor, e.g. arch-nonsealed
pick-image flavor:
    #!/usr/bin/env bash
    set -euo pipefail
    flavor="{{ flavor }}"
    edition="${flavor%%-*}"
    suffix="${flavor##*-}"
    case "$edition" in
        arch|cachy) ;;
        *) echo "[!!!] Unknown edition in '$flavor'." >&2; exit 1 ;;
    esac
    case "$suffix" in
        berbere|amchoor) echo "$edition-nonsealed" ;;
        maraska|saffron) echo "$edition-sealed" ;;
        *) echo "[!!!] Unknown layout in '$flavor'." >&2; exit 1 ;;
    esac

# print the containerfile that builds a flavor
containerfile flavor:
    #!/usr/bin/env bash
    set -euo pipefail
    image="$(just pick-image "{{ flavor }}")"
    echo "build_files/images/Containerfile.$image"

# build an image, tagged <channel>-<flavor>
build flavor="arch-berbere":
    #!/usr/bin/env bash
    set -euo pipefail
    reference="{{ registry }}/{{ image_name }}:{{ channel }}-{{ flavor }}"
    sudo podman build \
        -f "$(just containerfile "{{ flavor }}")" \
        --build-arg IMAGE_FLAVOR="{{ flavor }}" \
        --build-arg IMAGE_VARIANT="{{ channel }}-{{ flavor }}" \
        -t "$reference" \
        .
    echo "[---] Built $reference"
    echo "[-i-] Point BUILD_IMAGE_TAG at <channel>-<flavor> to use it with 'just bootc'."

# run bootc against a built image, e.g. just bootc install to-disk /data/disk.img
bootc *ARGS:
    sudo podman run \
        --rm --privileged --pid=host \
        -it \
        -v /sys/fs/selinux:/sys/fs/selinux \
        -v /etc/containers:/etc/containers:Z \
        -v /var/lib/containers:/var/lib/containers:Z \
        -v /dev:/dev \
        -e RUST_LOG=debug \
        -v "{{ base_dir }}:/data" \
        --security-opt label=type:unconfined_t \
        "{{ registry }}/{{ image_name }}:{{ image_tag }}" bootc {{ARGS}}

# generate-bootable-image $base_dir $filesystem
generate-bootable-image base_dir=base_dir filesystem=filesystem:
    #!/usr/bin/env bash
    if [ ! -e "${base_dir}/bootable.img" ] ; then
        fallocate -l 50G "${base_dir}/bootable.img"
    fi
    just bootc install to-disk --composefs-backend --via-loopback /data/bootable.img --filesystem "${filesystem}" --wipe --bootloader systemd
