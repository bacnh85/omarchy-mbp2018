#!/bin/bash
# Fix: built-in keyboard dead before login (LUKS passphrase prompt), MacBookPro15,1.
#
# ROOT CAUSE
#   /etc/mkinitcpio.conf.d/apple-t2.conf (written by Omarchy's installer) adds
#   MODULES+=(t2bce_vhci usbhid hid_apple hid_generic xhci_pci xhci_hcd).
#   /etc/mkinitcpio.conf.d/zz-omarchy-kernel-modules.conf then strips t2bce_vhci
#   unconditionally, because linux-omarchy (the default kernel) has no such module
#   and mkinitcpio hard-fails on a missing module.
#
#   The bug: this machine boots linux-t2 (BOOT_ORDER="linux-t2, ..."), which DOES
#   have t2bce_vhci. Stripping it for that kernel too left the initramfs without
#   the T2 virtual-USB host controller, so /devices/.../usb7/7-5 (Apple Internal
#   Keyboard) never appeared at the LUKS prompt. Userspace loaded it later via
#   /etc/modules-load.d/t2.conf, which is why the keyboard worked after login.
#
# FIX
#   Strip t2bce_vhci only for kernels where modinfo cannot find it.
#
# ponytail: this overwrites an installer-owned file. A future Omarchy update may
# rewrite it; re-running this script is idempotent and safe.

set -euo pipefail

CONF=/etc/mkinitcpio.conf.d/zz-omarchy-kernel-modules.conf

as_root() {
  if ((EUID == 0)); then "$@"; else pkexec "$@" </dev/null; fi
}

echo "==> Writing $CONF"
cat >/tmp/zz-omarchy-kernel-modules.conf <<'EOF'
# Written by the Omarchy installer, patched to keep t2bce_vhci on kernels that
# have it. t2bce_vhci comes from linux-t2 and does not exist in linux-omarchy,
# and mkinitcpio fails on a module it cannot find — so strip it, but only for a
# kernel that really lacks it. Stripping it unconditionally left the internal T2
# keyboard out of the linux-t2 initramfs, so the LUKS passphrase prompt took no
# keys and needed an external keyboard.
_omarchy_kept=()
for _omarchy_module in "${MODULES[@]}"; do
  if [[ $_omarchy_module == "t2bce_vhci" ]] &&
    [[ $(modinfo -k "${KERNELVERSION:-$(uname -r)}" -F filename t2bce_vhci 2>/dev/null) != /* ]]; then
    continue
  fi
  _omarchy_kept+=("$_omarchy_module")
done
MODULES=("${_omarchy_kept[@]}")
unset _omarchy_kept _omarchy_module
EOF
as_root cp /tmp/zz-omarchy-kernel-modules.conf "$CONF"

echo "==> Rebuilding unified kernel images"
as_root limine-mkinitcpio

echo "==> Verifying t2bce stack is inside the linux-t2 UKI"
UKI=/boot/EFI/Linux/omarchy_linux-t2.efi
if as_root lsinitcpio "$UKI" 2>/dev/null | grep -q 't2bce_vhci.ko.zst'; then
  echo "    OK: t2bce_vhci.ko.zst present in $UKI"
else
  echo "    FAIL: t2bce_vhci.ko.zst missing from $UKI" >&2
  exit 1
fi

# linux-omarchy must NOT carry it (it has no such module), or its build breaks.
if as_root lsinitcpio /boot/EFI/Linux/omarchy_linux-omarchy.efi 2>/dev/null | grep -q 't2bce_vhci.ko.zst'; then
  echo "    WARN: t2bce_vhci leaked into the linux-omarchy UKI" >&2
fi

echo
echo "Done. REBOOT for the keyboard to work at the LUKS prompt."
