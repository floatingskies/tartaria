<p align="center">
  <img src="system_files/usr/share/pixmaps/tartaria-text-logo.svg" alt="Tartaria Logo" width="450">
<h3 align="center">/tɑːrˈtɛəriə/</h3>
<h3 align="center">Arch/CachyOSv3 Bootc | Niri | Noctalia</h3>
<p align="center">
  <img width="1920" height="1080" alt="Desktop image" src="https://github.com/user-attachments/assets/833bd2bd-bd2d-4f90-a2d3-80e9f08a6a12" />
</p>


> [!WARNING]
> Tartaria is currently unstable and not safe to install due to the efforts towards v2. Please wait for v2 to exit beta and release.

## Description
Tartaria is a custom Arch/CachyOSv3 bootc image built for (optimized) general-day-to-day usage, providing a sleek, modern, unobtrusive experience that lets you get your work done.

The name is inspired by my favorite species of cherries, the [Black Tartarian](https://shop.arborday.org/treeguide/210) species - tender, juicy, and sweet.


## Shells

Tartaria is split in two, and `synergy` is what connects them.

Your login shell is the **immutable host**, and it stays that way unless you ask for something else. That is the whole point of a bootc image: the system is updated atomically as a whole, and no package transaction you can start by accident will touch it.

The **mutable subsystem** is a per-user Podman container that borrows the host's `/usr` but owns its own `/etc`, `/var` and home-local state. Install what you like in there, tweak the dotfiles, and nothing about it can damage the host. It is started on demand, never at login.

```
synergy status               # which variant, which shell, is the subsystem running
synergy shell                # drop into the mutable subsystem's fish
synergy shell htop           # run a single command inside the subsystem
synergy --host               # explicitly go back to the immutable host
synergy htop                 # any unknown command runs on the host
synergy rebase               # switch to another variant, then reboot
```

`fish` is the default shell for new users, and [Atuin](https://atuin.sh/) keeps your shell history on the host, shared with the subsystem.


## Variants

In total, there are sixteen variants of Tartaria.

Variants marked as **sealed** are **only installable by an ISO.** Variants marked as **nonsealed** are **installable by ISO or rebasing.**

Variants are composed as follows:

```
tartaria:<channel>-<edition>-<flavor>
```

### Channels

- `stable`: Built every **72 hours** and on **every new release**. Does not receive the latest, untested changes immediately.
- `unstable`: Built **daily** and on **every new change**. Not recommended for usage, unless you are testing changes and/or like to live on the edge. Be aware that your system may break at any moment in time.

### Editions

- `arch`: Based on **Arch Linux** with the **Arch kernel**.
- `cachy`: Based on **CachyOS-v3** with the **CachyOS-v3 BORE kernel**.

### Flavors

- `berbere`: **Nonsealed** image layout and nothing extra.
- `amchoor`: **Nonsealed** image layout with preinstalled NVIDIA drivers.
- `maraska`: **Sealed** image layout with secure boot support.
- `saffron`: **Sealed** image layout with secure boot support, and preinstalled NVIDIA drivers.

### Notes

**Sealed** variants provide E2E integrity verification via UKIs, Secure Boot, and fs-verity–backed composefs on top of what nonsealed has. Sealed variants are only installable via ISO, and are experimental.

**Nonsealed** variants do not have E2E integrity verification but still get bootc's atomic updates, rollback, and composefs filesystem. Nonsealed variants are installable by rebasing or installing via an ISO.


## Installing

### ISO

> [!WARNING]
> ISO installation is still being tested/improved. The below instructions will update over time.

Run the following in a Linux terminal and go through the selection/download process:

```
curl -fsSLO https://raw.githubusercontent.com/tartaria-dev/tartaria/refs/heads/live/iso-downloader.sh
less iso-downloader.sh   # read it before you run it
bash iso-downloader.sh
```

### Rebasing

If you are already running an OS such as Fedora Atomic or one of the Universal Blue projects, you can rebase with one of the following commands:

```
bootc switch ghcr.io/tartaria-dev/tartaria:<variant> # fedora atomic and universal blue projects
```
```
rpm-ostree rebase ostree-unverified-registry:ghcr.io/tartaria-dev/tartaria:<variant> # fedora atomic only
```

### Notes

If after installation you don't like the variant you chose, run `synergy rebase` in the terminal and go through the selection process. Rebasing keeps your current deployment available for rollback until you reboot, so reboot into the new deployment when it is done.

Rebasing is only offered between **nonsealed** variants of the same channel. Sealed variants must be reinstalled from an ISO.

Refer to the [Variants](https://github.com/tartaria-dev/tartaria#Variants) section above for choosing a variant.


## Credits
Thank you to the [Bootcrew](https://discord.gg/52Qcb4x2w3) team for making this project possible (and for general help)! I'd also like to thank the [XeniaOS](https://github.com/XeniaMeraki/XeniaOS/) and [Zirconium](https://github.com/zirconium-dev/zirconium/) projects for inspiring the creation of Tartaria!

## Metrics
![Alt](https://repobeats.axiom.co/api/embed/e1ddc95a13421c83c1bb9958fb3fc28c8fb02cce.svg "Repobeats analytics image")

## Building

Every flavour builds from a pinned base, and the build verifies itself before
the image is published.

```
just refresh-pins        # re-resolve pinned base image digests
just check-pins          # fail if any base image has moved
just build arch-berbere  # requires podman and root
```

What the build guarantees:

- **Base images are pinned by digest**, not by tag, in
  `build_files/images/BASE-IMAGES.lock`. A floating tag means the same commit
  can produce two different images.
- **AUR packages are pinned by commit** in `build_files/config/02-aur-pkgs`.
  There is no helper such as `yay`, so the package set is exactly the list in
  that file. Packages ending in `-git` pin the recipe but not the upstream
  source it fetches, and are therefore not fully reproducible.
- **`08-verify.sh` runs last** and stops the build on a mangled
  `PRIVACY_POLICY_URL`, a missing initramfs, an unsigned NVIDIA module, a
  missing unit the shell model needs, or a root account with a usable
  password.
- **The CI builds the ref that triggered it.** A tag push builds that tag;
  a schedule or manual run builds the branch head.

Sealed flavours need `SECUREBOOT_KEY`, `SECUREBOOT_CERT`, `MODULE_KEY` and
`MODULE_CERT` in the repository secrets. When they are absent the sealed jobs
are skipped with a notice rather than failing, so a fork without Secure Boot
material still builds the nonsealed flavours.

The root account is locked. There is no console root login on a graphical
image; recovery goes through a live image.
