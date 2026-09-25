# SPDX-License-Identifier: GPL-3.0-only
#
# Atuin is initialized for every interactive fish shell on this system,
# including the shell inside a mutable subsystem. Both share the same home
# directory, so the history is shared as well.

if status is-interactive; and type -q atuin
    atuin init fish | source
end
