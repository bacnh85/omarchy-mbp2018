#!/bin/bash
# post-update hook: after `omarchy update`, report which machine fixes survived
# and repair the ones that a package upgrade silently undoes.
#
# WHAT BREAKS ON AN UPDATE
#   aquamarine   A package upgrade restores the buggy .so, undoing the multi-GPU
#                modifier fix (external monitor on the dGPU goes black). Repaired
#                here, since the script is idempotent.
#   linux-t2     Omarchy's epoch-1 build outranks arch-mact2's and has no macsmc.
#                Held by IgnorePkg (pre-refresh-pacman hook); REPORTED here, never
#                silently reinstalled, because the hold should have prevented it.
#
# Runs as the user, inside the update's sudo authorization, so the scripts'
# as_root() takes the `sudo -n` path and does not prompt.
#
# Every check captures output into a variable instead of piping into `grep -q`:
# under `set -o pipefail` a `grep -q` that exits early closes the pipe, the
# producer dies of SIGPIPE (141), and the whole check reports failure even when
# the match was found.
#
# Installed as: ~/.config/omarchy/hooks/post-update.d/verify-mbp-fixes.sh

set -uo pipefail

# Resolve the checkout from wherever this file sits: in the repo
# (scripts/omarchy-hook-hooks/) or installed into ~/.config/omarchy/hooks/<type>.d/,
# and whichever $HOME the caller has (pkexec makes it /root).
REPO=${REPO:-}
if [[ -z $REPO ]]; then
  here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
  for c in "$here/../.." "${SUDO_USER:+/home/$SUDO_USER/Work/homelab}" \
    "$HOME/Work/homelab" /home/bacnh/Work/homelab; do
    [[ -d $c/scripts ]] && { REPO=$(cd -- "$c" && pwd); break; }
  done
fi
S=$REPO/scripts
fails=0
bad() { echo "  FAIL: $*" >&2; fails=$((fails + 1)); }

[[ -d $S ]] || { echo "homelab scripts not at $S; skipping" >&2; exit 0; }

echo "=== kernel (macsmc drives battery, fans, rtc) ==="
kv=$(pacman -Q linux-t2 2>/dev/null | awk '{print $2}')
files=$(pacman -Ql linux-t2 2>/dev/null)
case $kv in
  7.*)
    if [[ $files == *macsmc-hwmon* ]]; then
      echo "  ok: $kv ships macsmc"
    else
      bad "linux-t2 $kv has no macsmc modules (battery limit + fan sensors gone)"
    fi
    ;;
  "") bad "linux-t2 is not installed" ;;
  *) bad "linux-t2 is $kv — Omarchy's epoch-1 build has no macsmc" ;;
esac
conf=$(cat /etc/pacman.conf 2>/dev/null)
# Belt and braces for the pre-refresh-pacman hook: that one runs where sudo may
# not be cached yet and can only warn, while this one runs inside the update's
# authorization. Repair the hold here so a lost IgnorePkg self-heals.
if [[ $conf != *IgnorePkg*linux-t2* ]]; then
  "$S/omarchy-hook-hooks/keep-linux-t2-held.sh" >/dev/null 2>&1 || true
  conf=$(cat /etc/pacman.conf 2>/dev/null)
fi
if [[ $conf == *IgnorePkg*linux-t2* ]]; then
  echo "  ok: linux-t2 held in IgnorePkg"
else
  bad "IgnorePkg lost linux-t2; the next update will downgrade the kernel"
fi

echo "=== aquamarine multi-GPU patch ==="
out=$("$S/verify-aquamarine-patch.sh" 2>&1)
if [[ $out == *PATCHED* ]]; then
  echo "  ok: patched"
else
  echo "  repairing: rebuilding aquamarine with the modifier fix"
  if "$S/fix-external-monitor.sh" >/dev/null 2>&1; then
    echo "  ok: repaired (restart the session to load it)"
  else
    bad "aquamarine rebuild failed; external display on the dGPU will be black"
  fi
fi

echo "=== suspend blacklist, brightness, lid wake, fan daemon ==="
# status_matches <script> <needle...>: the fix is in place when every needle is
# present in the script's --status output.
status_matches() {
  local script=$1; shift
  local out needle
  out=$("$S/$script" --status 2>&1)
  for needle; do
    [[ $out == *"$needle"* ]] || return 1
  done
}
status_matches fix-suspend-hang.sh "applied:" "not loaded" &&
  echo "  ok: applesmc blacklisted" ||
  bad "applesmc blacklist missing — run $S/fix-suspend-hang.sh"

status_matches fix-brightness-persist.sh "installed:" "brightness:" &&
  echo "  ok: brightness saved on change" ||
  bad "brightness rule missing — run $S/fix-brightness-persist.sh"

status_matches fix-lid-wake.sh "EC" "enabled" "unit installed" &&
  echo "  ok: lid wakes the machine" ||
  bad "lid wake missing — run $S/fix-lid-wake.sh"

if "$S/check-fan-daemon.sh" >/dev/null 2>&1; then
  echo "  ok: t2fanrd stays masked"
else
  bad "t2fanrd fix regressed — run $S/fix-fan-daemon.sh"
fi

if ((fails)); then
  echo "---"
  echo "$fails machine fix(es) need attention after the update." >&2
  omarchy-notification-send -u normal "Machine fixes" \
    "$fails fix(es) need attention after the update — see /tmp/omarchy-update.log" 2>/dev/null || true
  exit 0
fi
echo "all machine fixes intact"
