# MacBookPro15,1 (2018 15") — Omarchy fixes

Machine: `MBPSori` · MacBookPro15,1 · Apple T2 (iBridge 24.16.6005.0.0) · Omarchy (Arch), kernel `linux-t2`.

Three problems were fixed on this box. Each one had a distinct root cause; none were
"Omarchy bugs" in the usual sense — two were config gaps, one was a genuine installer bug.

| # | Symptom | Root cause | Fix |
|---|---------|-----------|-----|
| 1 | Built-in keyboard dead before login (needed a USB keyboard for the LUKS passphrase) | `/etc/mkinitcpio.conf.d/zz-omarchy-kernel-modules.conf` stripped `t2bce_vhci` from `MODULES` **unconditionally**, so the linux-t2 initramfs contained no T2 keyboard driver | `scripts/fix-initramfs-keyboard.sh` |
| 2 | No Wi-Fi; Bluetooth appeared broken | BCM4364 firmware (`brcmfmac4364b2-pcie.apple,*`) is **not** in `linux-firmware`; it must be harvested from a macOS image | `scripts/fix-wifi-firmware.sh` |
| 3 | Trackpad two-finger scroll direction "wrong" (traditional instead of macOS-style) | Omarchy ships `touchpad.natural_scroll = false` | `config/hypr/input.lua` |
| 4 | dGPU runs from boot and burns ~7.4 W idle, but cannot be toggled at runtime | Polaris has no `amdgpu` runtime PM (no `_PR3` on `\_SB_.PCI0.PEG0.GFX0`) | `scripts/fix-dgpu-power.sh off` + reboot |
| 5 | USB-C/DP monitor detected (EDID, mode, workspace) but shows no picture | `aquamarine` 0.15.1 compares a buffer *modifier* against `DRM_FORMAT_INVALID` (0) instead of `DRM_FORMAT_MOD_INVALID`, so every cross-GPU blit to Polaris is rejected as "external-only" and the atomic commit never lands | `scripts/fix-external-monitor.sh` |

Details: [`docs/`](docs/README.md) · Patches and upstream status: [`patches/`](patches/README.md).

## Rebuilding this machine from scratch

After reinstalling Omarchy, run in this order:

```bash
./scripts/fix-initramfs-keyboard.sh   # then reboot — keyboard works at the LUKS prompt
./scripts/fix-wifi-firmware.sh        # Wi-Fi up immediately, no reboot
./scripts/fix-trackpad-scroll.sh      # instant, hyprctl reload
./scripts/fix-dgpu-power.sh off       # then reboot — dGPU off, best battery
./scripts/fix-external-monitor.sh     # external monitor; re-run after aquamarine upgrades
```

`fix-wifi-firmware.sh` prefers a saved tarball at
`~/.local/share/mbp-t2-firmware/firmware-renamed.tar` (there is one on this machine,
sha256 in `firmware-renamed.tar.sha256`). If it's missing it re-downloads Apple's
recovery image (~850 MB) and re-extracts — the same Method 5 path used originally.
