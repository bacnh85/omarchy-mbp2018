# MacBookPro15,1 (2018 15") — Omarchy fixes

Machine: `MBPSori` · MacBookPro15,1 · Apple T2 (iBridge 24.16.6005.0.0) · Omarchy (Arch), kernel `linux-t2`.

Eight problems were fixed on this box. Each one had a distinct root cause; none were
"Omarchy bugs" in the usual sense — three were config gaps, one was a genuine installer
bug, one was a driver claiming hardware it cannot drive on this machine, one was a
kernel driver leaving a task unfreezable, one was a missing setting, and one was a
save that only ever ran at a clean shutdown.

| # | Symptom | Root cause | Fix |
|---|---------|-----------|-----|
| 1 | Built-in keyboard dead before login (needed a USB keyboard for the LUKS passphrase) | `/etc/mkinitcpio.conf.d/zz-omarchy-kernel-modules.conf` stripped `t2bce_vhci` from `MODULES` **unconditionally**, so the linux-t2 initramfs contained no T2 keyboard driver | `scripts/fix-initramfs-keyboard.sh` |
| 2 | No Wi-Fi; Bluetooth appeared broken | BCM4364 firmware (`brcmfmac4364b2-pcie.apple,*`) is **not** in `linux-firmware`; it must be harvested from a macOS image | `scripts/fix-wifi-firmware.sh` |
| 3 | Trackpad two-finger scroll direction "wrong" (traditional instead of macOS-style) | Omarchy ships `touchpad.natural_scroll = false` | `config/hypr/input.lua` |
| 4 | dGPU runs from boot and burns ~7.4 W idle, but cannot be toggled at runtime | Polaris has no `amdgpu` runtime PM (no `_PR3` on `\_SB_.PCI0.PEG0.GFX0`) | `scripts/fix-dgpu-power.sh off` + reboot |
| 5 | USB-C/DP monitor detected (EDID, mode, workspace) but shows no picture | `aquamarine` 0.15.1 compares a buffer *modifier* against `DRM_FORMAT_INVALID` (0) instead of `DRM_FORMAT_MOD_INVALID`, so every cross-GPU blit to Polaris is rejected as "external-only" and the atomic commit never lands | `scripts/fix-external-monitor.sh` |
| 6 | Suspend hangs: panel goes dark but the machine never sleeps, then needs a long power-button press | `applesmc` (the pre-T2 SMC driver) claims the `APP0001` ACPI id that `macsmc-acpi` owns; its probe spins in `smc_sane()` for 60 s in D state, and a D-state task cannot be frozen, so `pm-suspend` aborts after 20 s | `scripts/fix-suspend-hang.sh` |
| 7 | Brightness comes back at the firmware default after a reboot | `systemd-backlight@.service` only saves in `ExecStop`, so any non-clean shutdown loses the level — and #6 was forcing exactly those | `scripts/fix-brightness-persist.sh` |
| 8 | No way to stop charging below 100%, to slow battery ageing | Not a bug: the driver exposes `charge_control_end_threshold`, but nothing was setting it (and there is no *start* threshold on this kernel) | `scripts/fix-battery-charge-limit.sh 80` |

Details: [`docs/`](docs/README.md) · Patches and upstream status: [`patches/`](patches/README.md).

## Rebuilding this machine from scratch

After reinstalling Omarchy, run in this order:

```bash
./scripts/fix-initramfs-keyboard.sh   # then reboot — keyboard works at the LUKS prompt
./scripts/fix-wifi-firmware.sh        # Wi-Fi up immediately, no reboot
./scripts/fix-trackpad-scroll.sh      # instant, hyprctl reload
./scripts/fix-dgpu-power.sh off       # then reboot — dGPU off, best battery
./scripts/fix-external-monitor.sh     # external monitor; re-run after aquamarine upgrades
./scripts/fix-suspend-hang.sh         # instant — sleep actually sleeps again
./scripts/fix-suspend-hang.sh --test  # proves it without entering S3
./scripts/fix-brightness-persist.sh   # instant — brightness survives any shutdown
./scripts/fix-battery-charge-limit.sh 80   # instant, and re-applied at boot
```

`fix-wifi-firmware.sh` prefers a saved tarball at
`~/.local/share/mbp-t2-firmware/firmware-renamed.tar` (there is one on this machine,
sha256 in `firmware-renamed.tar.sha256`). If it's missing it re-downloads Apple's
recovery image (~850 MB) and re-extracts — the same Method 5 path used originally.
