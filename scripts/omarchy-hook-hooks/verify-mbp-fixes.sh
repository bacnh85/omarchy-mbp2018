#!/bin/bash
# post-update hook: after `omarchy update`, verify all eleven fixes from docs/ and
# repair the ones a package upgrade silently undoes.
#
# WHAT BREAKS ON AN UPDATE
#   aquamarine   A package upgrade restores the buggy .so, undoing the multi-GPU
#                modifier fix (external monitor on the dGPU goes black). Repaired
#                here, since the script is idempotent.
#   linux-t2     Omarchy's epoch-1 build outranks arch-mact2's and has no macsmc
#                (doc 11), taking the battery charge limit, fan sensors and
#                macsmc-rtc with it. Held by IgnorePkg (pre-refresh-pacman hook);
#                REPORTED here, never silently reinstalled, because the hold
#                should have prevented it.
#   mkinitcpio   A kernel upgrade can rewrite the zz- drop-in and strip
#                t2bce_vhci again (doc 01), which kills the keyboard at the LUKS
#                prompt -- a failure you only meet on the next reboot.
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
  for c in "$here/../.." "$here/../../.." "${SUDO_USER:+/home/$SUDO_USER/Work/omarchy-mbp2018}" \
    "$HOME/Work/omarchy-mbp2018" "$HOME/omarchy-mbp2018" "$PWD"; do
    [[ -d $c/scripts ]] && { REPO=$(cd -- "$c" && pwd); break; }
  done
fi
S=$REPO/scripts
checks=0 fails=0
ok() { checks=$((checks + 1)); echo "  ok: $*"; }
bad() { checks=$((checks + 1)); fails=$((fails + 1)); echo "  FAIL: $*" >&2; }
skip() { echo "  --: $* (not verifiable from here)"; }

# Root only when this update already has it. `sudo -n` is the hook path.
root() {
  if ((EUID == 0)); then "$@"
  elif sudo -n true 2>/dev/null; then sudo -n "$@"
  else return 1; fi
}

[[ -d $S ]] || { echo "no scripts/ next to this checkout ($S); set REPO=/path/to/omarchy-mbp2018" >&2; exit 0; }

# 1 -- keyboard at the LUKS prompt (doc 01)
echo "=== 1. initramfs keeps the T2 keyboard ==="
dropin=$(cat /etc/mkinitcpio.conf.d/zz-omarchy-kernel-modules.conf 2>/dev/null)
if [[ $dropin == *'_omarchy_absent=(t2bce_vhci)'* ]] || [[ $dropin != *'modinfo -k'* ]]; then
  bad "zz- drop-in strips t2bce_vhci unconditionally — run $S/fix-initramfs-keyboard.sh"
elif uki=$(root lsinitcpio /boot/EFI/Linux/omarchy_linux-t2.efi 2>/dev/null); then
  # The drop-in being patched is not proof the flashed UKI was rebuilt from it.
  if [[ $uki == *t2bce_vhci* ]]; then
    ok "drop-in patched, t2bce_vhci present in the linux-t2 UKI"
  else
    bad "UKI has no t2bce_vhci — run $S/fix-initramfs-keyboard.sh and rebuild"
  fi
else
  ok "drop-in patched (UKI unreadable without root)"
fi

# 2 -- Wi-Fi firmware (doc 02)
echo "=== 2. Wi-Fi firmware + link ==="
if [[ -r /lib/firmware/brcm/brcmfmac4364b2-pcie.apple,ekans.bin ]] &&
  [[ -r /lib/firmware/brcm/brcmfmac4364b2-pcie.apple,ekans.clm_blob ]]; then
  if ip -br link show 2>/dev/null | grep -qE '^wl'; then
    ok "BCM4364 firmware present, wireless link up"
  else
    bad "firmware present but no wl* interface — check brcmfmac"
  fi
else
  bad "BCM4364 firmware missing — run $S/fix-wifi-firmware.sh"
fi

# 3 -- trackpad natural scroll (doc 03)
echo "=== 3. trackpad natural scroll ==="
if command -v hyprctl >/dev/null && hyprctl version >/dev/null 2>&1; then
  if [[ $(hyprctl getoption input:touchpad:natural_scroll 2>/dev/null) == *"bool: true"* ]]; then
    ok "natural_scroll is on"
  else
    bad "natural_scroll is off — run $S/fix-trackpad-scroll.sh"
  fi
else
  skip "no Hyprland session"
fi

# 4 -- dGPU not wedged (doc 04; the off/on choice is the user's, wedging is not)
echo "=== 4. dGPU state ==="
dgpu=/sys/bus/pci/devices/0000:01:00.0
if [[ -e $dgpu/power_state ]]; then
  state=$(cat "$dgpu/power_state")
  if [[ -n $(readlink -f "$dgpu/driver" 2>/dev/null) ]] && [[ $state != D3cold ]]; then
    ok "amdgpu bound, power_state=$state (not wedged)"
  else
    bad "dGPU wedged (power_state=$state, driver unbound) — reboot required"
  fi
else
  skip "no dGPU at 0000:01:00.0"
fi

# 5 -- external monitor on the dGPU (doc 05)
echo "=== 5. aquamarine multi-GPU patch ==="
out=$("$S/verify-aquamarine-patch.sh" 2>&1)
if [[ $out == *PATCHED* ]]; then
  ok "libaquamarine patched"
else
  echo "  repairing: rebuilding aquamarine with the modifier fix"
  if "$S/fix-external-monitor.sh" >/dev/null 2>&1; then
    ok "rebuilt with the fix (restart the session to load it)"
  else
    bad "rebuild failed; external display on the dGPU will be black"
  fi
fi

# 6 -- suspend (doc 06)
echo "=== 6. suspend does not hang ==="
out=$("$S/fix-suspend-hang.sh" --status 2>&1)
if [[ $out == *"applied:"* ]] && [[ $out == *"not loaded"* ]]; then
  ok "applesmc blacklisted and not loaded"
else
  bad "applesmc blacklist missing — run $S/fix-suspend-hang.sh"
fi

# 7 -- brightness persistence (doc 07)
echo "=== 7. brightness survives a reboot ==="
out=$("$S/fix-brightness-persist.sh" --status 2>&1)
if [[ $out == *"installed:"* ]] && [[ $out == *"brightness:"* ]]; then
  ok "udev save rule installed, level tracked"
else
  bad "brightness rule missing — run $S/fix-brightness-persist.sh"
fi

# 8 -- battery charge limit (doc 08) -- the one doc 11 breaks
echo "=== 8. battery charge limit ==="
thr=/sys/class/power_supply/macsmc-battery/charge_control_end_threshold
if [[ ! -e $thr ]]; then
  bad "no macsmc-battery threshold (generic ACPI battery) — see doc 11"
else
  end=$(cat "$thr" 2>/dev/null)
  conf=$(cat /etc/omarchy-battery-limit.conf 2>/dev/null)
  want=$(sed -n 's/^END_THRESHOLD=//p' /etc/omarchy-battery-limit.conf 2>/dev/null)
  if [[ -n $want ]] && [[ $end != "$want" ]]; then
    bad "threshold is $end, config wants $want — run $S/fix-battery-charge-limit.sh $want"
  elif [[ $conf == *END_THRESHOLD* ]] && systemctl is-enabled battery-charge-limit.service >/dev/null 2>&1; then
    ok "threshold ${end}% applied and re-applied at boot"
  else
    bad "threshold node exists but config/boot unit missing — run $S/fix-battery-charge-limit.sh"
  fi
fi

# 9 -- fan daemon (doc 09)
echo "=== 9. t2fanrd stays out of the way ==="
if "$S/check-fan-daemon.sh" >/dev/null 2>&1; then
  ok "masked; the SMC owns the fans"
else
  bad "t2fanrd fix regressed — run $S/fix-fan-daemon.sh"
fi

# 10 -- lid wake (doc 10)
echo "=== 10. opening the lid wakes the machine ==="
out=$("$S/fix-lid-wake.sh" --status 2>&1)
if [[ $out == *"EC"*"enabled"* ]] && [[ $out == *"unit installed"* ]]; then
  ok "EC wake source enabled, unit installed"
else
  bad "lid wake missing — run $S/fix-lid-wake.sh"
fi

# 11 -- kernel carries macsmc, and cannot be downgraded away (doc 11)
echo "=== 11. kernel keeps macsmc, and stays held ==="
kv=$(pacman -Q linux-t2 2>/dev/null | awk '{print $2}')
files=$(pacman -Ql linux-t2 2>/dev/null)
case $kv in
  7.*)
    if [[ $files == *macsmc-hwmon* ]]; then
      ok "$kv ships macsmc"
    else
      bad "linux-t2 $kv has no macsmc modules (battery limit + fan sensors gone)"
    fi
    ;;
  "") bad "linux-t2 is not installed" ;;
  *) bad "linux-t2 is $kv — Omarchy's epoch-1 build has no macsmc" ;;
esac
# Belt and braces for the pre-refresh-pacman hook: that one runs where sudo may
# not be cached yet and can only warn, while this one runs inside the update's
# authorization. Repair the hold here so a lost IgnorePkg self-heals.
if [[ $(cat /etc/pacman.conf 2>/dev/null) != *IgnorePkg*linux-t2* ]]; then
  "$S/omarchy-hook-hooks/keep-linux-t2-held.sh" >/dev/null 2>&1 || true
fi
if [[ $(cat /etc/pacman.conf 2>/dev/null) == *IgnorePkg*linux-t2* ]]; then
  ok "linux-t2 held in IgnorePkg"
else
  bad "IgnorePkg lost linux-t2; the next update will downgrade the kernel"
fi

echo "---"
if ((fails)); then
  echo "$fails of $checks checks failed — the machine needs attention after this update." >&2
  omarchy-notification-send -u normal "Machine fixes" \
    "$fails of $checks checks failed after the update — see /tmp/omarchy-update.log" 2>/dev/null || true
  exit 0
fi
echo "all $checks checks passed (docs 01-11)"
