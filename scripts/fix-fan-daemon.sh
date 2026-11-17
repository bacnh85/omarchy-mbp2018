#!/bin/bash
# Stop t2fanrd's restart loop on this machine.
#
#   fix-fan-daemon.sh            mask t2fanrd (the SMC keeps controlling the fans)
#   fix-fan-daemon.sh --status   show the unit state and live fan readings
#   fix-fan-daemon.sh --revert   unmask it again
#
# SYMPTOM
#   systemctl status t2fanrd is stuck in activating (auto-restart), and the
#   journal is nothing but:
#
#     t2fanrd[49330]: Error: Fan not found
#     systemd[1]: t2fanrd.service: Main process exited, code=exit, status=1/FAILURE
#     systemd[1]: t2fanrd.service: Scheduled restart job, restart counter is at 5348.
#
#   Over 6900 restarts on a single boot, one every two seconds.
#
# ROOT CAUSE
#   t2fanrd looks for fan attributes under the SMC ACPI device:
#
#     /sys/devices/pci*/*/*/*/APP0001:00/fan*
#
#   On this kernel they are not there. macsmc-hwmon publishes them a level
#   deeper, under the standard hwmon interface:
#
#     .../APP0001:00/macsmc-hwmon/hwmon/hwmon4/fan1_input   (+ fan2_input)
#
#   So the glob matches nothing, the daemon exits, and the shipped unit's
#   Restart=always / RestartSec=2 turns one failure into a permanent loop.
#
#   This is a known upstream gap, not a local misconfiguration: T2FanRD has
#   "Add macsmc support" (#21) and "Hwmon support" (#22) open, and a third-party
#   fork exists specifically because "the new linux kernel 7.3 broke t2fanrd".
#   Nothing in /etc/t2fand.conf can fix it -- both [Fan1]/[Fan2] sections already
#   match the two fans that exist.
#
# WHY MASKING IS SAFE
#   t2fanrd is not what turns the fans. The SMC runs its own curve through
#   macsmc-hwmon, and that curve was measured working under full load (12
#   threads, 75 s): 2732 -> 5828 rpm on fan1 and 2555 -> 5409 on fan2 as the CPU
#   rose to 100 C. With the daemon unable to find a fan at all, it has never
#   contributed any control -- it only produced the loop.
#
#   `mask` rather than `disable` on purpose: disable would be undone by the next
#   `omarchy update` / `pacman -S t2fanrd`, and the loop would come back.

set -euo pipefail

UNIT=t2fanrd.service
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

# `systemctl is-enabled` prints "masked" but exits 1 for a masked unit, so under
# `pipefail` a `... | grep -qx masked` test is always false. Capture the string
# and ignore the exit status rather than testing a pipeline.
unit_state() { systemctl is-enabled "$UNIT" 2>/dev/null || true; }

# The hwmon device that actually owns the fans, wherever it landed this boot.
fan_dir() {
  local d
  for d in /sys/class/hwmon/hwmon*; do
    [[ -r $d/fan1_input ]] && { echo "$d"; return 0; }
  done
  return 1
}

show_fans() {
  local dir
  if ! dir=$(fan_dir); then
    echo "  no hwmon fan device found"
    return 0
  fi
  local f label cur min max
  for f in "$dir"/fan*_input; do
    [[ -e $f ]] || continue
    # $(<file) is a bash fast path, not a command: it cannot be given `|| fallback`.
    label=$(cat "${f%_input}_label" 2>/dev/null || true)
    cur=$(cat "$f" 2>/dev/null || echo 0)
    min=$(cat "${f%_input}_min" 2>/dev/null || true)
    max=$(cat "${f%_input}_max" 2>/dev/null || true)
    printf '  %s (%s): %s rpm   (min %s, max %s)\n' \
      "$(basename "${f%_input}")" "${label:-?}" "$cur" "$min" "$max"
  done
}

case "$MODE" in
apply)
  if [[ $(unit_state) == masked ]]; then
    echo "==> Already masked: $UNIT"
  else
    as_root systemctl mask "$UNIT" >/dev/null
    echo "==> Masked $UNIT (the restart loop is gone)"
  fi
  as_root systemctl stop "$UNIT" 2>/dev/null || true

  echo "==> Fans are the SMC's own curve, via macsmc-hwmon:"
  show_fans
  ;;

--status)
  echo "=== $UNIT ==="
  case "$(unit_state)" in
  masked) echo "  masked (no restart loop)" ;;
  enabled) echo "  enabled (the loop is back unless t2fanrd can find the fans)" ;;
  *) echo "  ${state:-unknown}" ;;
  esac
  echo "  restarts this boot: $(systemctl show "$UNIT" -p NRestarts --value 2>/dev/null || echo 0)"
  echo "=== fans (macsmc-hwmon, SMC-controlled) ==="
  show_fans
  echo "=== package ==="
  pacman -Q t2fanrd 2>/dev/null | sed 's/^/  /' || echo "  t2fanrd not installed"
  ;;

--revert)
  if [[ $(unit_state) == masked ]]; then
    as_root systemctl unmask "$UNIT" >/dev/null
    as_root systemctl enable --now "$UNIT" 2>/dev/null || true
    echo "==> Unmasked $UNIT — expect 'Fan not found' every 2 s again until upstream"
    echo "    adds macsmc/hwmon support (T2FanRD issues #21, #22)."
  else
    echo "==> Not masked; nothing to do."
  fi
  ;;

*)
  echo "usage: $0 [--status|--revert]" >&2
  exit 2
  ;;
esac
