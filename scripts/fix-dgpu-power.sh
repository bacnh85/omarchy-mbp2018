#!/bin/bash
# Control the AMD dGPU (Radeon Pro 555X/560X, 01:00.0) on MacBookPro15,1.
#
#   fix-dgpu-power.sh off      disable dGPU before the display manager (needs reboot)
#   fix-dgpu-power.sh on       re-enable it (needs reboot)
#   fix-dgpu-power.sh status   show current state
#
# WHY A BOOT TOGGLE AND NOT A RUNTIME SWITCH
#   amdgpu on Polaris has no runtime PM on this machine:
#       amdgpu 0000:01:00.0: Runtime PM not available
#   because \_SB_.PCI0.PEG0.GFX0 exposes no _PR3/power resources. So the card is
#   either powered on from boot (~7.4 W idle, measured) or off until the next boot.
#   vgaswitcheroo OFF at runtime does work, but turning it back ON in a live session
#   wedges the card permanently (D3cold, unrecoverable without reboot) -- see
#   docs/04-dgpu-power.md. Hence: toggle the boot service, reboot.
#
# SAFETY: this script never writes to vgaswitcheroo in a live session.

set -euo pipefail

UNIT=/etc/systemd/system/amdgpu-off.service
MODE=${1:-status}

as_root() { pkexec "$@" </dev/null; }

write_unit() {
  cat <<'EOF' > /tmp/amdgpu-off.service
[Unit]
Description=Power off AMD dGPU via vgaswitcheroo
After=systemd-modules-load.service
Before=display-manager.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for i in $(seq 1 30); do [ -e /sys/kernel/debug/vgaswitcheroo/switch ] && exec sh -c "echo OFF > /sys/kernel/debug/vgaswitcheroo/switch"; sleep 1; done; exit 1'

[Install]
WantedBy=multi-user.target
EOF
  as_root install -m644 /tmp/amdgpu-off.service "$UNIT"
  rm -f /tmp/amdgpu-off.service
  as_root systemctl daemon-reload
}

case "$MODE" in
off)
  [[ -f $UNIT ]] || write_unit
  as_root systemctl enable amdgpu-off.service
  echo "==> dGPU will be powered off at next boot."
  echo "    Reboot to apply. External display on the dGPU port will stop working."
  ;;
on)
  [[ -f $UNIT ]] || { echo "==> amdgpu-off.service not installed; dGPU is already enabled."; exit 0; }
  as_root systemctl disable amdgpu-off.service
  echo "==> dGPU will be powered at next boot (idle ~7.4 W). Reboot to apply."
  ;;
status)
  echo "=== vgaswitcheroo ==="
  as_root cat /sys/kernel/debug/vgaswitcheroo/switch 2>/dev/null || echo "  (unavailable)"
  echo "=== dGPU 01:00.0 ==="
  for f in power_state; do echo "  $f=$(cat /sys/bus/pci/devices/0000:01:00.0/$f 2>&1)"; done
  for f in runtime_status control; do echo "  $f=$(cat /sys/bus/pci/devices/0000:01:00.0/power/$f 2>&1)"; done
  if [[ -e /sys/bus/pci/devices/0000:01:00.0/driver ]]; then
    echo "  driver=$(basename "$(readlink -f /sys/bus/pci/devices/0000:01:00.0/driver)")"
  else
    echo "  driver=UNBOUND (unrecoverable without reboot; see docs/04-dgpu-power.md)"
  fi
  echo "=== amdgpu-off.service ==="
  systemctl is-enabled amdgpu-off.service 2>/dev/null || echo "disabled (not installed)"
  echo "=== renderers ==="
  echo -n "  iGPU: "; timeout 20 glxinfo -B 2>/dev/null | sed -n 's/^ *OpenGL renderer string: //p' || echo "?"
  echo -n "  dGPU: "; timeout 20 env DRI_PRIME=1 glxinfo -B 2>/dev/null | sed -n 's/^ *OpenGL renderer string: //p' || echo "(unavailable / dGPU off)"
  ;;
*)
  echo "usage: $0 {off|on|status}" >&2
  exit 2
  ;;
esac
