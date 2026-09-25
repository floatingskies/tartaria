# SPDX-License-Identifier: GPL-3.0-only
#
# You are running an immutable host. The system itself lives in a read-only,
# verified filesystem and is updated atomically, so packages are managed for
# you: there is no pacman transaction to run in a terminal here.
#
# Your own files are perfectly safe. ~ is backed by /var/home, which is
# persistent, and the dotfiles that ship with the image are applied to it with
# chezmoi. Put anything you would rather own yourself in conf.d/ instead of
# here.
#
# If you do want a system of your own to install into, the mutable subsystem
# is one command away:
#
#     synergy shell        # enter your mutable subsystem
#     synergy shell htop   # run a single command inside it
#     synergy status       # report the state of your subsystem
#     synergy --host       # come back to this host
#     synergy --help       # everything else
#
# It starts on demand and keeps running until you log out, so a second
# `synergy shell` is instant.

# sensible defaults, override these in conf.d/ instead of here
set -gx EDITOR nvim
set -gx VISUAL $EDITOR
set -gx PAGER less
set -gx LESS -R -F -X
