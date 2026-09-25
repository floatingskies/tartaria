#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only

# setup
source /config/00-functions
set -euxo pipefail

# preconfigure basic system settings
echo "uninitialized" > /etc/machine-id
ln -sfn /usr/share/zoneinfo/UTC /etc/localtime

# lock the root account: this is a graphical image with greetd, there is no
# legitimate console root login, and a known root password on a published
# image is a straight escalation path. Recovery goes through the live image.
passwd --lock root >/dev/null 2>&1 || true

# re-enable pacman network sandbox
sed -i '/DisableSandboxNetwork/d' /etc/pacman.conf

# set correct permissions on polkit rules dir
chmod 750 /etc/polkit-1/rules.d
chown -R root:polkitd /etc/polkit-1/rules.d

# remove base-devel, keep sudo
pacman -Rns --noconfirm base-devel cmake extra-cmake-modules || true
pacman -S --noconfirm --needed sudo

# fix ttys not starting correctly
ln -sfnT /usr/lib/systemd/system/getty@.service /usr/lib/systemd/system/autovt@.service

# configure useradd defaults
sed -i -e 's|^HOME=.*|HOME=/var/home|' -e 's|^SHELL=.*|SHELL=/usr/bin/fish|' /etc/default/useradd

# set plymouth theme
plymouth-set-default-theme tartaria

# remove any .pacnew files
find /etc/ -name "*.pacnew" -type f -delete

# disable uupd distrobox updates
sed -i 's|uupd|& --disable-module-distrobox|' /usr/lib/systemd/system/uupd.service

# pick random gender flag and set it as default face
cp "/usr/share/tartaria/faces/face-$(shuf -i 1-10 -n 1).png" /usr/share/tartaria/faces/default-face.png

# set the identity of this installation, this must not touch upstream urls
rm -f /etc/os-release
set_os_release "Tartaria" "$IMAGE_VARIANT"
ln -sfnT /usr/lib/os-release /etc/os-release

# record the variant so that synergy and friends can report and change it
install -d /usr/lib/tartaria
printf '%s\n' "$IMAGE_VARIANT" >/usr/lib/tartaria/variant

# install default icon theme, pinned so the same commit always yields the
# same icons
MACTAHOE_REPO="https://github.com/vinceliuice/MacTahoe-icon-theme"
MACTAHOE_COMMIT="839848b9a8a38a92a6936e30c4abe35cc6f2546d"
retry git clone --no-checkout --filter=blob:none "$MACTAHOE_REPO"
git -C MacTahoe-icon-theme fetch --depth 1 origin "$MACTAHOE_COMMIT"
git -C MacTahoe-icon-theme checkout --detach "$MACTAHOE_COMMIT"
bash ./MacTahoe-icon-theme/install.sh -t grey -n default-icons -d /usr/share/icons
rm -rf MacTahoe-icon-theme

# set default niri config
install -d /etc/niri/
ln -sfnT /usr/share/tartaria/cherries/dot_config/niri/config.kdl /etc/niri/config.kdl

# install flatpak's preinstall file
mkdir -p /usr/share/flatpak/preinstall.d
cp /config/03-flatpaks /usr/share/flatpak/preinstall.d/sysapps.preinstall

# apply gschema overrides
glib-compile-schemas /usr/share/glib-2.0/schemas

# install host-spawn, pinned so a swapped release asset fails the build
HOST_SPAWN_URL="https://github.com/1player/host-spawn/releases/download/v1.6.2/host-spawn-x86_64"
HOST_SPAWN_SHA256="077bc09a087292447ba17cfe2156a93f71bf56c4c6be8e38d3abe65c1240f34c"
retry wget -q "$HOST_SPAWN_URL" -O /usr/lib/subsystem/bin/host-spawn
echo "${HOST_SPAWN_SHA256}  /usr/lib/subsystem/bin/host-spawn" | sha256sum -c -
chmod +x /usr/lib/subsystem/bin/host-spawn

# hide some desktop entries, the ones that are not shipped are skipped
for entry in avahi-discover bssh bvnc lstopo nvim dev.noctalia.Noctalia tuned-gui assistant designer linguist mpv qdbusviewer qv4l2 qvidcap vim; do
    desktop="/usr/share/applications/$entry.desktop"
    [[ -f "$desktop" ]] || continue
    sed -i '/^NoDisplay=/d;$aNoDisplay=true' "$desktop"
done
update-desktop-database

# replace the upstream brew update and upgrade units, they run as uid 1000 and
# would fail for everyone else, the setup unit is patched by a drop-in instead
rm -f \
    /usr/lib/systemd/system/brew-update.service \
    /usr/lib/systemd/system/brew-update.timer \
    /usr/lib/systemd/system/brew-upgrade.service \
    /usr/lib/systemd/system/brew-upgrade.timer \
    /usr/lib/systemd/system-preset/01-homebrew.preset

# export secureboot cert for saffron/maraska
if [[ "$IMAGE_VARIANT" == *saffron || "$IMAGE_VARIANT" == *maraska ]]; then
    mkdir -p /usr/share/tartaria/certs
    openssl x509 -in /run/secrets/secureboot_cert -outform DER -out /usr/share/tartaria/certs/secureboot.der
fi

# add nvidia-drm modprobe config for saffron/amchoor
if [[ "$IMAGE_VARIANT" == *saffron || "$IMAGE_VARIANT" == *amchoor ]]; then
    mkdir -p /etc/modprobe.d
    echo "options nvidia-drm modeset=1" > /etc/modprobe.d/nvidia.conf
fi

echo "::endgroup::"
