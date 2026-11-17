#!/bin/bash
# Fix: opening the lid does not wake this MacBook from sleep — the power button
# has to be pressed first.
#
#   fix-lid-wake.sh            apply, and keep it applied across reboots
#   fix-lid-wake.sh --status   show the wake sources and what woke the last sleep
#   fix-lid-wake.sh --revert   back to power-button-only wake
#
# ROOT CAUSE
#   Sleeping (S3, "deep") arms only the wake GPEs that a *wakeup-enabled* device
#   claims through its _PRW. Two places do it:
#
#     acpi_enable_wakeup_devices(S3)   drivers/acpi/wakeup.c
#         for each _PRW device with device_may_wakeup() (or prepare_count):
#             acpi_set_gpe_wake_mask(gpe, ACPI_GPE_ENABLE)   -> enable_for_wake
#     acpi_hw_enable_all_wakeup_gpes() drivers/acpi/acpica/hwsleep.c
#         writes that enable_for_wake set into the GPE registers just before the
#         SLP_TYP write, *clearing every other* GPE bit.
#
#   So a GPE wakes the machine only if (a) a _PRW names it and (b) that device
#   has wakeup enabled. It is not enough for the device to exist and be enabled
#   by default — and it is not enough to enable the *lid*, which is what every
#   "enable LID0" recipe says.
#
#   On this machine the lid has no GPE of its own:
#
#     gpe6F   LID0's own _PRW GPE     0 events, disabled   <- nothing ever here
#     gpe6E   the EC's GPE           3000+ events          <- "ACPI: EC: GPE=0x6e"
#
#   The lid is polled by the embedded controller and reported as an ACPI query on
#   the EC's GPE. LID0's own GPE never fires, so leaving LID0 *enabled (its
#   default) arms a line the lid does not use.
#
#   The EC's _PRW names that same GPE 0x6E, so enabling EC is the one that arms
#   the lid's real wake line. It was *disabled — so device_may_wakeup(EC) was
#   false, acpi_set_gpe_wake_mask(0x6E, ENABLE) never ran, and 0x6E was cleared
#   at S3 entry. An EC event could then never raise a wake SCI: the lid query sat
#   queued until some other wakeup delivered it.
#
#   That is exactly what the journal of the two recorded lid cycles shows: each
#   "Lid opened." is logged by logind ~25 s into the sleep and only ~0.7 s before
#   "PM: suspend exit", and LNXPWRBN:00 (the power button) counts exactly two
#   events — one per cycle. The lid event was *delivered by* the resume the power
#   button caused, it did not cause it.
#
# FIX
#   Enable EC as a wakeup source:  echo EC > /proc/acpi/wakeup
#
#   Nothing else changes. LID0 stays enabled (harmless, and it is what the
#   machine reports), S3/`deep` stays (see docs/06), and the EC keeps doing its
#   normal work — this only sets the wakeup flag on a device the kernel already
#   drives.
#
# TRADE-OFF
#   Arming the EC GPE arms everything the EC reports, not just the lid: plugging
#   the charger in will wake the machine too. That is the price of a working lid
#   wake on this design, and it is why the flag is off by default upstream.
#   `--revert` puts it back.

set -euo pipefail

UNIT=/etc/systemd/system/lid-wake-ec.service
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
tmpfile() { mktemp "${TMPDIR:-/tmp}/lid-wake.XXXXXX"; }

# /proc/acpi/wakeup is a toggle, not a setter: writing a name flips its state.
# So every caller reads first and writes only when the state says so — running
# this twice must not undo it.
wakeup_state() {  # $1 = device name -> enabled | disabled | absent
  awk -v d="$1" '
    $1 == d { print ($3 == "*enabled" ? "enabled" : "disabled"); found = 1 }
    END     { if (!found) print "absent" }
  ' /proc/acpi/wakeup
}

event_count() {  # $1 = wakeup source name, e.g. PNP0C0D:00 -> summed event count
  local dir total=0 seen=0
  # ACPI registers some devices twice (the acpi device and its physical child),
  # both under the same name -- PNP0C0D:00 is wakeup41 *and* wakeup42. Reading
  # only the first match reports 0 for a lid that did fire, so sum them.
  for dir in /sys/class/wakeup/wakeup*; do
    [[ -r $dir/name && -r $dir/event_count ]] || continue
    [[ $(<"$dir/name") == "$1" ]] || continue
    total=$(( total + $(<"$dir/event_count") ))
    seen=1
  done
  (( seen )) && echo "$total" || echo "?"
}

write_unit() {
  local tmp
  tmp=$(tmpfile) || return 1
  cat >"$tmp" <<EOF
[Unit]
Description=Arm the EC as a wakeup source so the lid wakes this machine
# /proc/acpi/wakeup is up as soon as ACPI is, which is before this point.
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
# The interface toggles, so only write when the state is what we want changed.
ExecStart=/bin/sh -c 'grep -qE "^EC[[:space:]]+S[0-9]+[[:space:]]+[*]disabled" /proc/acpi/wakeup && echo EC > /proc/acpi/wakeup || true'

[Install]
WantedBy=multi-user.target
EOF
  as_root install -m644 "$tmp" "$UNIT"
  rm -f "$tmp"
  as_root systemctl daemon-reload
}

show() {
  local ec lid gpe6e gpe6f

  ec=$(wakeup_state EC)
  lid=$(wakeup_state LID0)
  gpe6e=$(awk '{print $1}' /sys/firmware/acpi/interrupts/gpe6E 2>/dev/null || echo "?")
  gpe6f=$(awk '{print $1}' /sys/firmware/acpi/interrupts/gpe6F 2>/dev/null || echo "?")

  echo "=== wake sources ==="
  printf '  EC    (the lid rides this GPE): %s\n' "$ec"
  printf '  LID0  (its own GPE never fires): %s\n' "$lid"

  echo "=== the two GPEs ==="
  printf '  gpe6E  EC            %s events   <- the lid arrives here\n' "$gpe6e"
  printf '  gpe6F  LID0 _PRW     %s events   <- silent, which is why LID0 alone never worked\n' "$gpe6f"

  echo "=== events since boot (one press = one event) ==="
  printf '  PNP0C0D:00 (lid reported by logind): %s\n' "$(event_count PNP0C0D:00)"
  printf '  LNXPWRBN:00 (power button)         : %s\n' "$(event_count LNXPWRBN:00)"

  echo "=== persistence ==="
  if [[ -f $UNIT ]]; then
    printf '  unit installed: %s (%s)\n' "$UNIT" "$(systemctl is-enabled lid-wake-ec.service 2>/dev/null || echo 'not enabled')"
  else
    echo "  unit not installed (the setting lasts until reboot)"
  fi

  if [[ $ec == enabled ]]; then
    echo
    echo "  Applied. Test it: close the lid, wait a few seconds, open it — it"
    echo "  should come back with no button press."
    echo "  If LNXPWRBN:00 goes up during that cycle, a button was still involved."
  fi
}

case "$MODE" in
apply)
  if [[ $(wakeup_state EC) == enabled ]]; then
    echo "==> EC is already a wakeup source"
  else
    as_root sh -c 'echo EC > /proc/acpi/wakeup'
    echo "==> Enabled EC as a wakeup source"
  fi

  if [[ $(wakeup_state EC) != enabled ]]; then
    echo "    FAIL: /proc/acpi/wakeup did not take it" >&2
    exit 1
  fi

  write_unit
  as_root systemctl enable lid-wake-ec.service >/dev/null
  echo "==> Persisted as lid-wake-ec.service (re-applied on every boot)"

  echo
  echo "Test it now — no reboot needed:"
  echo "    close the lid, wait a few seconds, open it"
  echo "Then check what actually woke it:"
  echo "    $0 --status"
  ;;

--status)
  show
  ;;

--revert)
  if [[ $(wakeup_state EC) == enabled ]]; then
    as_root sh -c 'echo EC > /proc/acpi/wakeup'
    echo "==> EC is no longer a wakeup source (the lid will not wake the machine)"
  else
    echo "==> EC was already not a wakeup source"
  fi
  if [[ -f $UNIT ]]; then
    as_root systemctl disable lid-wake-ec.service >/dev/null 2>&1 || true
    as_root rm -f "$UNIT"
    as_root systemctl daemon-reload
    echo "==> Removed $UNIT"
  fi
  ;;

*)
  echo "usage: $0 [--status|--revert]" >&2
  exit 2
  ;;
esac
