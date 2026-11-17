#!/bin/bash
# pre-refresh-pacman hook: keep linux-t2 held after `omarchy refresh pacman`
# rewrites /etc/pacman.conf from its channel template.
#
# WHY THIS EXISTS
#   Omarchy's repo ships linux-t2 with `epoch=1` (1:7.2.15.arch1-1) and builds it
#   WITHOUT CONFIG_MACSMC_*, so it has none of the 9 macsmc modules this machine
#   needs. arch-mact2 ships 7.3.4 with all of them, but has no epoch, so pacman
#   treats Omarchy's older code as the newer package:
#
#       $ vercmp 1:7.2.15.arch1-1 7.3.4.arch1-2  ->  1   (an "upgrade")
#
#   `omarchy update` runs plain `pacman -Syu`, so every update quietly downgrades
#   the kernel and takes the battery charge limit, the fan sensors and macsmc-rtc
#   with it. IgnorePkg is the hold; this hook re-applies it, because
#   `omarchy refresh pacman` overwrites /etc/pacman.conf wholesale.
#
#   Runs BEFORE the package transaction, so the hold shapes that transaction.
#
# Installed as: ~/.config/omarchy/hooks/pre-refresh-pacman.d/keep-linux-t2-held.sh

set -euo pipefail

CONF=${CONF:-/etc/pacman.conf}
PKGS="linux-t2 linux-t2-headers"

# Prefer the sudo timestamp this refresh already established; fall back to pkexec
# and, with no TTY to prompt on, just say so instead of hanging the update.
as_root() {
  if ((EUID == 0)); then "$@"
  elif sudo -n true 2>/dev/null; then sudo -n "$@"
  elif [[ -t 0 ]]; then pkexec "$@"
  else return 1; fi
}

# Union of what is already ignored and what we require: order preserved,
# duplicates dropped. A user's own entries must survive, and ours must not be
# appended twice on the next update.
existing=$(sed -n 's/^IgnorePkg[[:space:]]*=[[:space:]]*//p' "$CONF" | tr ',' ' ')
line="IgnorePkg = $(printf '%s\n' $existing $PKGS | awk 'NF && !seen[$0]++' | tr '\n' ' ')"
line=${line% }

# Already exactly right: quiet no-op, which is every update after the first.
grep -qxF "$line" "$CONF" && exit 0

# Replace an existing line, else insert after HoldPkg (a stock [options] anchor,
# so the entry lands in [options] and not inside a repository stanza). sed exits
# 0 even when it matches nothing, so test for the line rather than the exit code.
if grep -qE '^IgnorePkg[[:space:]]*=' "$CONF"; then
  as_root sed -i "s|^IgnorePkg[[:space:]]*=.*|$line|" "$CONF" || true
else
  as_root sed -i "s|^HoldPkg[[:space:]]*=.*|&\n$line|" "$CONF" || true
fi

if grep -qxF "$line" "$CONF"; then
  echo "linux-t2 held back from Omarchy's epoch-1 build (it has no macsmc modules)."
else
  echo "WARNING: could not hold linux-t2 in $CONF; the next update will downgrade it." >&2
fi
