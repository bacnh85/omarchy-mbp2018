#!/bin/bash
# Keep the battery inside a charge window to slow down calendar ageing.
#
#   fix-battery-charge-limit.sh              show the current window
#   fix-battery-charge-limit.sh 80           charge only up to 80%
#   fix-battery-charge-limit.sh --off        back to a full charge
#
# A second argument is accepted for compatibility but is only *validated*: this
# kernel exposes no start threshold, so there is nothing to write it to. The
# script says so rather than pretending it applied.
#
# The limit is applied now and re-applied on every boot.
#
# WHY
#   A lithium pack held at 100% and warm loses capacity fastest. Keeping it
#   between roughly 55% and 80% is the usual desktop compromise: enough for an
#   unplugged hour, a fraction of the wear.
#
# WHAT THE HARDWARE GIVES US
#   The battery driver (macsmc-power) exposes only
#   /sys/class/power_supply/macsmc-battery/charge_control_end_threshold.
#   There is no charge_control_start_threshold on this kernel, so the *start*
#   level cannot be set from Linux: the SMC picks its own hysteresis (75% here)
#   and starts charging again once the pack falls below it.
#   Writing 100 means "no limit" (the firmware default). Note that 0 is NOT a
#   synonym for it -- this driver rejects 0 with EINVAL, and 1-100 are accepted.
#
#   Verified on this machine: writing the end threshold takes effect at once
#   (status goes Not charging -> Charging when capacity is below the new limit),
#   it survives a driver reload, and UPower picks the value up on restart
#   without writing back over it.
#
# WHY NOT UPower
#   UPower exposes ChargeEndThreshold over D-Bus, but only as a readable property
#   behind EnableChargeThreshold -- there is no supported setter, and its cache can
#   disagree with sysfs (it kept reporting 80% while sysfs said 55%). Writing the
#   sysfs attribute is the interface the kernel actually offers.

set -euo pipefail

BAT=/sys/class/power_supply/macsmc-battery
END=$BAT/charge_control_end_threshold
CONF=/etc/omarchy-battery-limit.conf
UNIT=/etc/systemd/system/battery-charge-limit.service
MODE=${1:-}

as_root() { pkexec "$@" </dev/null; }
# Root installs only what this script itself wrote: mktemp gives an unpredictable
# name this user owns, so a pre-created symlink in /tmp cannot redirect the copy
# (and a `>` onto a symlink would let another local user choose what root installs).
tmpfile() { mktemp "${TMPDIR:-/tmp}/battery-limit.XXXXXX"; }

write_conf() {
  # $1 = end threshold (100 = no limit)
  local tmp
  tmp=$(tmpfile) || return 1
  printf '# Managed by fix-battery-charge-limit.sh.\n# 100 means "no limit" (charge to full).\nEND_THRESHOLD=%s\n' "$1" > "$tmp"
  as_root install -Dm644 "$tmp" "$CONF"
  rm -f "$tmp"
}

write_unit() {
  local tmp
  tmp=$(tmpfile) || return 1
  cat > "$tmp" <<EOF
[Unit]
Description=Apply the battery charge limit from $CONF
# The battery appears with the macsmc-power driver, well before this point.
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '. $CONF; [ -w $END ] && echo "\$END_THRESHOLD" > $END || true'

[Install]
WantedBy=multi-user.target
EOF
  as_root install -m644 "$tmp" "$UNIT"
  rm -f "$tmp"
  as_root systemctl daemon-reload
}

show() {
  echo "=== battery ==="
  echo "  charge:    $(<"$BAT/capacity")%  ($(<"$BAT/status"))"
  echo "  cycles:    $(<"$BAT/cycle_count")"
  echo "  health:    $(<"$BAT/health")"
  local end=0
  [[ -r $END ]] && end=$(<"$END")
  # 0 is what the attribute reads before anything has ever set it, and the driver
  # rejects writing 0 -- so it means "unset", not "limit to zero".
  if (( end >= 100 )); then
    echo "  limit:     none (charges to 100%)"
  elif (( end < 1 )); then
    echo "  limit:     not set (charges to 100%)"
  else
    echo "  limit:     stops at ${end}%"
  fi
  # The SMC's own restart level, when the kernel exposes it.
  if [[ -r $BAT/charge_control_start_threshold ]]; then
    echo "  restarts:  below $(<"$BAT/charge_control_start_threshold")%"
  fi
  echo "=== boot unit ==="
  systemctl is-enabled battery-charge-limit.service 2>/dev/null || echo "  not installed"
  if [[ -f $CONF ]]; then sed 's/^/  /' "$CONF"; fi
}

case "$MODE" in
""|--status)
  show
  ;;

--off)
  write_conf 100
  as_root sh -c "echo 100 > $END"
  write_unit
  as_root systemctl enable battery-charge-limit.service >/dev/null
  echo "==> Charge limit removed; the battery will charge to 100%."
  show
  ;;

*)
  # Match the range by pattern, not bash arithmetic: (( 080 )) is an octal parse
  # error and (( <20 digits> )) overflows, and both would slip past a numeric
  # comparison and reach write_conf unvalidated.
  if [[ ! $MODE =~ ^[5-9][0-9]$ ]]; then
    echo "usage: $0 [END_PERCENT 50-99 | --off | --status]" >&2
    exit 2
  fi

  start=${2:-}
  if [[ -n $start ]]; then
    if [[ ! $start =~ ^[4-9][0-9]$ ]] || (( 10#$start >= 10#$MODE )); then
      echo "error: the restart level must be a number below the limit (40-89, and below $MODE)" >&2
      exit 2
    fi
    echo "note: this kernel has no charge_control_start_threshold, so the restart" >&2
    echo "      level cannot be set; the SMC keeps its own hysteresis. Ignoring $start." >&2
  fi

  write_conf "$MODE"
  as_root sh -c "echo $MODE > $END"
  write_unit
  as_root systemctl enable battery-charge-limit.service >/dev/null

  echo "==> Charge limit set to ${MODE}%, applied now and on every boot."
  if (( $(<"$BAT/capacity") > MODE )); then
    echo "    Capacity is already above ${MODE}%; it will stop charging and drain to the limit."
  fi
  show
  ;;
esac
