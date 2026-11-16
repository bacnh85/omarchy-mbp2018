#!/bin/bash
# Fix: suspend hangs on this MacBook — the machine freezes part-way into sleep
# and only a long power-button press gets it back.
#
#   fix-suspend-hang.sh            apply the fix
#   fix-suspend-hang.sh --status   show whether it is applied and what loaded
#   fix-suspend-hang.sh --test     exercise the freeze path without really sleeping
#   fix-suspend-hang.sh --revert   remove the blacklist
#
# ROOT CAUSE
#   applesmc, the *pre-T2* Apple SMC driver, keeps getting loaded on this box.
#   Its ACPI id is APP0001 (alias acpi*:APP0001:*), and the platform device that
#   macsmc-acpi now owns is  /sys/devices/pci0000:00/0000:00:1f.0/APP0001:00
#   (modalias acpi:APP0001:SMC-HURONRIVER:). Every time udev emits an "add" for
#   that device its kmod builtin calls modprobe with the modalias, so applesmc
#   is loaded -- and its probe cannot talk to the T2 SMC. applesmc_init() sits
#   in smc_sane()'s usleep loop for a full minute in uninterruptible (D) state.
#
#   A task in D state cannot be frozen, so pm-suspend dies on the way down:
#
#     PM: suspend entry (deep)
#     Freezing user space processes
#     Freezing user space processes failed after 20.001 seconds
#       (1 tasks refusing to freeze, wq_busy=0):
#     task:(udev-worker) state:D
#       smc_sane+0x3d/0x110 [applesmc]
#       applesmc_init_smcreg_try+0x6c/0x400 [applesmc]
#       applesmc_init+0xa8/0xff0 [applesmc]
#
#   The panel is already dark by then, so the box looks asleep but never is: it
#   burns battery until the power button is held down. And because that is not a
#   clean shutdown, systemd-backlight's ExecStop never runs -- which is why
#   brightness looked like it was "not saved" too (see fix-brightness-persist.sh).
#
#   applesmc is the wrong driver for this hardware anyway: macsmc-core /
#   macsmc-acpi / macsmc-power / macsmc-hwmon drive the same SMC through ACPI and
#   are what the battery and sensors already run on. applesmc has never once
#   probed successfully here ("probe with driver applesmc failed with error -5").
#
# FIX
#   Blacklist applesmc and make modprobe a no-op for it. `blacklist` alone is not
#   enough: it only suppresses alias-based loading, and udev's modalias lookup is
#   alias-based but kmod still honours a direct request. The `install applesmc
#   /bin/true` line is what actually stops it.
#
# SAFETY: nothing depends on applesmc. It has never bound on this machine, so no
# fan, sensor or backlight goes away -- fan control is macsmc-hwmon (and see the
# note in docs/06 about t2fanrd being broken for an unrelated reason).
#
# SAFETY: --test runs the kernel's own freeze test (pm_test=freezer), which
# freezes and thaws userspace in ~5 seconds and never enters S3. It reproduces
# the failing step exactly, and it cannot leave the machine asleep.

set -euo pipefail

BLACKLIST=/etc/modprobe.d/blacklist-applesmc.conf
MODE=${1:-apply}

as_root() { pkexec "$@" </dev/null; }
# Root installs only what this script itself wrote: mktemp gives an unpredictable
# name this user owns, so a pre-created symlink in /tmp cannot redirect the copy
# (a `>` onto a symlink would let another local user choose what root installs).
tmpfile() { mktemp "${TMPDIR:-/tmp}/blacklist-applesmc.XXXXXX"; }

read -r -d '' BLACKLIST_BODY <<'EOF' || true
# applesmc is the pre-T2 Apple SMC driver. On this T2 Mac its probe spins in
# smc_sane() for a minute in uninterruptible sleep, and a task in D state cannot
# be frozen -- which is what hangs pm-suspend (see docs/06-suspend-hang.md).
#
# macsmc-core/macsmc-acpi/macsmc-power/macsmc-hwmon drive the same SMC through
# ACPI and are what the battery, RTC and fan sensors already use. applesmc has
# never probed successfully on this machine.
#
# `blacklist` only stops alias-based auto-loading; udev asks modprobe by ACPI
# modalias (acpi:APP0001:SMC-HURONRIVER:) on every "add" for APP0001:00, so the
# install line is what actually refuses the load.
blacklist applesmc
install applesmc /bin/true
EOF

applied() { [[ -f $BLACKLIST ]] && grep -qx 'install applesmc /bin/true' "$BLACKLIST"; }

# The most recent freeze result line in this boot. It is the only evidence that
# matters: an older "failed" from before the fix is not a current failure, and
# grepping a window of lines cannot tell the two apart.
last_freeze() {
  journalctl -k -b -o cat 2>/dev/null |
    grep -E 'Freezing user space processes (failed|completed)' | tail -1 || true
}

case "$MODE" in
apply)
  if applied; then
    echo "==> Already applied: $BLACKLIST"
  else
    tmp=$(tmpfile) || exit 1
    printf '%s\n' "$BLACKLIST_BODY" > "$tmp"
    as_root install -Dm644 "$tmp" "$BLACKLIST"
    rm -f "$tmp"
    echo "==> Installed $BLACKLIST"
  fi

  # Take the module out of a running session too, so the next suspend is fixed
  # without waiting for a reboot. Unloading is safe precisely because its probe
  # never succeeded: nothing is bound to it.
  if grep -q '^applesmc ' /proc/modules; then
    echo "==> Unloading applesmc from this session"
    as_root modprobe -r applesmc || echo "    (busy; the blacklist applies from the next boot)"
  fi

  echo "==> Verifying modprobe now refuses it"
  if modprobe -n -v applesmc 2>&1 | grep -q 'install /bin/true'; then
    echo "    applesmc -> install /bin/true  (OK)"
  else
    echo "    FAIL: modprobe would still load applesmc" >&2
    exit 1
  fi

  echo
  echo "Suspend is fixed for the next sleep. Prove it without sleeping:"
  echo "    $0 --test"
  ;;

--status)
  echo "=== blacklist ==="
  if applied; then echo "  applied: $BLACKLIST"; else echo "  NOT applied"; fi
  echo "=== applesmc loaded? ==="
  if grep -q '^applesmc ' /proc/modules; then
    echo "  LOADED (will block suspend)"
  else
    echo "  not loaded"
  fi
  echo "=== probe failures this boot ==="
  n=$(journalctl -k -b -o cat 2>/dev/null | grep -c 'applesmc' || true)
  echo "  ${n:-0}"
  echo "=== sleep mode ==="
  echo "  mem_sleep: $(cat /sys/power/mem_sleep)"
  echo "=== last freeze attempt ==="
  line=$(last_freeze)
  echo "  ${line:-(none this boot)}"  ;;

--test)
  # pm_test=freezer runs the failing step (freeze userspace) and thaws again,
  # waiting 5 s. It never enters S3, so it cannot strand the machine -- and it is
  # the exact step applesmc used to break.
  #
  # It does NOT touch pm_freeze_timeout: that attribute is in milliseconds (20000
  # by default, which is the 20.001 s in the failure trace), and lowering it would
  # weaken the very timeout this test relies on. The 5 s wait is the kernel's own.
  applied || { echo "Run $0 first (the blacklist is not in place)." >&2; exit 1; }

  echo "==> Freezing userspace for 5s (pm_test=freezer, no real sleep)"
  as_root sh -c 'echo freezer > /sys/power/pm_test'
  trap 'pkexec sh -c "echo none > /sys/power/pm_test" </dev/null >/dev/null 2>&1 || true' EXIT
  as_root sh -c 'echo mem > /sys/power/state' || true
  as_root sh -c 'echo none > /sys/power/pm_test'
  trap - EXIT

  echo "==> Kernel said:"
  line=$(last_freeze)
  if [[ -z $line ]]; then
    echo "    FAIL: the kernel logged no freeze result, so this proves nothing" >&2
    exit 1
  fi
  echo "    $line"
  if [[ $line == *failed* ]]; then
    echo "    FAIL: something still refuses to freeze" >&2
    exit 1
  fi
  echo "    OK — userspace froze cleanly. Real sleep should now work."
  ;;

--revert)
  if [[ -f $BLACKLIST ]]; then
    as_root rm -f "$BLACKLIST"
    echo "==> Removed $BLACKLIST (applesmc can load again, and suspend will hang again)"
  else
    echo "==> Nothing to remove."
  fi
  ;;

*)
  echo "usage: $0 [--status|--test|--revert]" >&2
  exit 2
  ;;
esac
