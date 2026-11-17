#!/bin/bash
# Fix: display brightness should come back at the level it was left at, not at
# whatever the firmware picked.
#
#   fix-brightness-persist.sh           apply (save on every change)
#   fix-brightness-persist.sh --status  show the rule, state file and live level
#   fix-brightness-persist.sh --save    save the current level now
#   fix-brightness-persist.sh --revert  drop the rule
#
# ROOT CAUSE
#   systemd's save/restore for backlights is wired up by 99-systemd.rules:
#
#     SUBSYSTEM=="backlight", TAG+="systemd", IMPORT{builtin}="path_id", \
#       ENV{SYSTEMD_WANTS}+="systemd-backlight@backlight:$name.service"
#
#   That rule works here (this systemd's path_id does emit acpi-APP000B:00 for
#   the gmux, so the unit exists and runs), and saving/restoring works when asked
#   directly. What does not work is *when* it is asked:
#
#   - Restore at boot is reliable, but the saved file is only written by
#     systemd-backlight@.service's ExecStop at shutdown.
#   - Anything that is not a clean systemd shutdown therefore loses the level.
#     On this machine suspend was hanging and being recovered with a long
#     power-button press (see fix-suspend-hang.sh) -- i.e. exactly the dirty
#     shutdown that skips ExecStop. Brightness "not persisting" was a symptom of
#     that, not a second bug.
#   - It is still worth closing on its own: a saved level is only ever as fresh
#     as the last clean shutdown, so a crash or a forced power-off falls back to
#     a much older value.
#
# FIX
#   Also save on every brightness *change*, from udev, the moment it happens:
#
#     ACTION=="change", SUBSYSTEM=="backlight", KERNEL=="gmux_backlight", \
#       RUN+="/usr/lib/systemd/systemd-backlight save backlight:gmux_backlight"
#
#   The backlight driver emits a "change" uevent on each write to
#   /sys/class/backlight/gmux_backlight/brightness, so the state file tracks the
#   knob as it is used and any kind of shutdown restores the last level.
#
#   Only gmux_backlight is covered: appletb_backlight is the Touch Bar, not the
#   panel, and Omarchy keeps its own state for the keyboard backlight.

set -euo pipefail

RULE=/etc/udev/rules.d/99-gmux-backlight-save.rules
STATE=/var/lib/systemd/backlight/acpi-APP000B:00:backlight:gmux_backlight
SYSFS=/sys/class/backlight/gmux_backlight/brightness
MODE=${1:-apply}

# omarchy update runs its hooks under the update's own sudo authorization, where
# pkexec would prompt again (and polkit with no TTY simply hangs). Prefer a sudo
# that already works, then pkexec for an interactive shell.
as_root() {
  if ((EUID == 0)); then "$@"
  elif sudo -n true 2>/dev/null; then sudo -n "$@"
  else pkexec "$@" </dev/null
  fi
}
# Root installs only what this script itself wrote: mktemp gives an unpredictable
# name this user owns, so a pre-created symlink in /tmp cannot redirect the copy
# (a `>` onto a symlink would let another local user choose what root installs).
tmpfile() { mktemp "${TMPDIR:-/tmp}/gmux-backlight-save.XXXXXX"; }

read -r -d '' RULE_BODY <<'EOF' || true
# Save the panel brightness as soon as it changes instead of only at a clean
# shutdown, so a crash, a forced power-off, or a broken suspend cannot lose it.
#
# systemd's own 99-systemd.rules runs systemd-backlight@backlight:gmux_backlight
# only for load (boot) and save (ExecStop, clean shutdown). The gmux driver emits
# a "change" uevent on every write to brightness, which gives us the earliest
# point at which the new value is known.
#
# Only the panel: appletb_backlight is the Touch Bar, and the keyboard backlight
# is handled by Omarchy.
ACTION=="change", SUBSYSTEM=="backlight", KERNEL=="gmux_backlight", \
  RUN+="/usr/lib/systemd/systemd-backlight save backlight:gmux_backlight"
EOF

percent() { awk -v v="${1:-0}" -v m="${2:-65535}" 'BEGIN { printf "%.0f", (m > 0 ? 100 * v / m : 0) }'; }

case "$MODE" in
apply)
  if [[ -f $RULE ]] && grep -qF 'systemd-backlight save backlight:gmux_backlight' "$RULE"; then
    echo "==> Already applied: $RULE"
  else
    tmp=$(tmpfile) || exit 1
    printf '%s\n' "$RULE_BODY" > "$tmp"
    as_root install -Dm644 "$tmp" "$RULE"
    rm -f "$tmp"
    echo "==> Installed $RULE"
  fi

  as_root udevadm control --reload-rules
  echo "==> udev rules reloaded"

  # Seed the state file from the live register so the current level is not lost
  # before the user next touches brightness.
  as_root /usr/lib/systemd/systemd-backlight save backlight:gmux_backlight
  echo "==> Saved the current level now"

  echo
  echo "Brightness now survives any shutdown. Verify it tracks changes:"
  echo "    brightnessctl -d gmux_backlight set 50%"
  echo "    $0 --status"
  ;;

--status)
  echo "=== rule ==="
  if [[ -f $RULE ]]; then echo "  installed: $RULE"; else echo "  NOT installed"; fi
  echo "=== live panel ==="
  if [[ -r $SYSFS ]]; then
    local_cur=$(<"$SYSFS")
    local_max=$(</sys/class/backlight/gmux_backlight/max_brightness)
    echo "  brightness: $local_cur / $local_max ($(percent "$local_cur" "$local_max")%)"
  else
    echo "  gmux_backlight missing"
  fi
  echo "=== saved state ==="
  if [[ -r $STATE ]]; then
    saved=$(<"$STATE")
    echo "  file: $STATE"
    echo "  value: $saved (updated $(stat -c %y "$STATE" | cut -d. -f1))"
  else
    echo "  no state file yet: $STATE"
  fi
  echo "=== load unit ==="
  state=$(systemctl is-active systemd-backlight@backlight:gmux_backlight.service 2>/dev/null || true)
  echo "  systemd-backlight@backlight:gmux_backlight: ${state:-unknown}"
  ;;

--save)
  as_root /usr/lib/systemd/systemd-backlight save backlight:gmux_backlight
  echo "==> Saved: $(<"$STATE")"
  ;;

--revert)
  if [[ -f $RULE ]]; then
    as_root rm -f "$RULE"
    as_root udevadm control --reload-rules
    echo "==> Removed $RULE (brightness is saved only at a clean shutdown again)"
  else
    echo "==> Nothing to remove."
  fi
  ;;

*)
  echo "usage: $0 [--status|--save|--revert]" >&2
  exit 2
  ;;
esac
