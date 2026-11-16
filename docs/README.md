# Fixes — MacBookPro15,1 on Omarchy

Each doc is self-contained: symptom, how the root cause was found, the fix, and how
to verify it. Read the one matching the symptom.

- [01 — Built-in keyboard dead before login](01-keyboard-before-login.md)
- [02 — Wi-Fi / Bluetooth](02-wifi-bluetooth.md)
- [03 — Trackpad scroll direction](03-trackpad-scroll.md)
- [04 — The AMD dGPU: does it work, on-demand use, battery](04-dgpu-power.md)
- [05 — External monitor over USB-C/DP detected but black](05-external-monitor-black.md)
- [06 — Suspend hangs: panel dark but the machine never sleeps](06-suspend-hang.md)
- [07 — Brightness not restored after a reboot](07-brightness-persist.md)
- [08 — Battery charge limit (stop at 80%)](08-battery-charge-limit.md)
- [09 — t2fanrd restarts forever ("Fan not found")](09-fan-daemon.md)

## Machine facts worth knowing before debugging anything

```
Model          MacBookPro15,1 (2018 15"), Apple T2 / iBridge 24.16.6005.0.0
Kernel         linux-t2 7.3.4 (NOT linux-omarchy — BOOT_ORDER puts linux-t2 first)
Bootloader     limine, unified kernel images in /boot/EFI/Linux/
Disk            nvme0n1p2 = LUKS -> btrfs. Single boot, **no APFS / no macOS**
Wi-Fi          Broadcom BCM4364 [14e4:4464] -> brcmfmac (never broadcom-wl)
Bluetooth      BCM4364B0 over hci_uart/btbcm on serial0 (ACPI BCM2E7C)
Keyboard/trackpad, Touch Bar   internal USB devices via t2bce_vhci (T2 PCIe)
GPUs           iGPU Intel UHD 630 (eDP-1) + dGPU AMD Baffin 555X/560X [1002:67ef]
               dGPU has **no runtime PM** on Polaris — on from boot or off until reboot
```

Two traps that cost time:

1. **`/etc/mkinitcpio.conf.d/` files are sourced *after* `mkinitcpio.conf` in name
   order**, and `zz-` sorts last. A `zz-` drop-in can silently undo what an earlier
   drop-in set. To see the effective result:
   ```bash
   KERNELVERSION=$(uname -r) bash -c 'MODULES=(); HOOKS=(); . /etc/mkinitcpio.conf
     for f in /etc/mkinitcpio.conf.d/*.conf; do . "$f"; done
     echo "MODULES: ${MODULES[*]}"'
   ```
2. **`limine-mkinitcpio` rebuilds every installed kernel** (here linux-t2 *and*
   linux-omarchy). A change that fixes one kernel's UKI can break the other's build,
   and a failed hook leaves a **stale UKI** on the ESP that still boots. Always verify
   inside the image afterwards with `lsinitcpio`.

## Root shell on this machine

`sudo` needs a password and there is no askpass, so from an agent session use
`pkexec <cmd> </dev/null` — it authenticates via the polkit agent (slow, ~4 s, but
works non-interactively once authorised). A password prompt is required the first
time; after that polkit caches it briefly.
