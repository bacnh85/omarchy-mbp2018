# MacBookPro15,1 (2018 15") — Omarchy fixes

Machine: `MBPSori` · MacBookPro15,1 · Apple T2 (iBridge 24.16.6005.0.0) · Omarchy (Arch), kernel `linux-t2`.

Eleven problems were fixed on this box. Each one had a distinct root cause; none were
"Omarchy bugs" in the usual sense — three were config gaps, one was a genuine installer
bug, one was a driver claiming hardware it cannot drive on this machine, one was a
kernel driver leaving a task unfreezable, one was a missing setting, one was a save that
only ever ran at a clean shutdown, one was a third-party daemon chasing an interface
that no longer exists, one was a wake source the firmware needs and the kernel leaves
off, and one was a repository shipping an older kernel under a newer epoch.

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
| 9 | `t2fanrd` never starts — "Fan not found" every 2 s, 8800+ restarts a boot | The daemon globs `/sys/devices/pci*/*/*/*/APP0001:00/fan*`, but `macsmc-hwmon` publishes the fans under `.../APP0001:00/macsmc-hwmon/hwmon/hwmon4/`; known upstream gap (T2FanRD #21/#22) | `scripts/fix-fan-daemon.sh` |
| 10 | Lid close sleeps, lid open does not wake — the power button has to be pressed first | S3 arms only the GPEs a *wakeup-enabled* `_PRW` device claims. The lid rides the **EC's** GPE (`gpe6E`), not LID0's own (`gpe6F`, 0 events), and `EC` was `*disabled`, so that GPE was cleared at S3 entry | `scripts/fix-lid-wake.sh` |
| 11 | After `omarchy update`, the battery charge limit and fan sensors silently stop existing | Omarchy's repo ships `linux-t2` at `1:7.2.15.arch1-1` (epoch 1) built **without** `CONFIG_MACSMC_*` — 0 of 9 `macsmc` modules. arch-mact2's `7.3.4` has all 9 but no epoch, so `pacman -Syu` treats the older code as the newer package and "upgrades" into it (`vercmp 1:7.2.15 7.3.4` → `1`) | `IgnorePkg` hold + `scripts/omarchy-hook-hooks/` |

Details: [`docs/`](docs/README.md) · Patches and upstream status: [`patches/`](patches/README.md).

## Surviving `omarchy update`

An update is the one event that can silently undo the fixes above, so two hooks are
installed into `~/.config/omarchy/hooks/`:

| Hook | When | What it does |
|---|---|---|
| `pre-refresh-pacman.d/keep-linux-t2-held.sh` | after `omarchy refresh pacman` rewrites `pacman.conf`, before the transaction | re-applies the `IgnorePkg` hold that the rewrite drops |
| `post-update.d/verify-mbp-fixes.sh` | end of `omarchy update` | one check per doc 01–11 (12 assertions); rebuilds aquamarine when a package upgrade restored the buggy `.so`; repairs a lost `IgnorePkg` |

```bash
omarchy hook install pre-refresh-pacman ./scripts/omarchy-hook-hooks/keep-linux-t2-held.sh
omarchy hook install post-update       ./scripts/omarchy-hook-hooks/verify-mbp-fixes.sh
omarchy-hook post-update    # run it by hand any time
```

The hold is visible to pacman, so an update reports the kernel as `[ignored]` rather
than downgrading it:

```bash
$ pacman -Qu linux-t2
linux-t2 7.3.4.arch1-2 -> 1:7.2.15.arch1-1 [ignored]
```

Everything else here is idempotent, so re-running a script is always safe.

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
./scripts/fix-fan-daemon.sh           # instant — stops t2fanrd's restart loop
./scripts/fix-lid-wake.sh             # instant — opening the lid wakes the machine
```

Then install the two update hooks so the next `omarchy update` cannot undo any of it:

```bash
omarchy hook install pre-refresh-pacman ./scripts/omarchy-hook-hooks/keep-linux-t2-held.sh
omarchy hook install post-update       ./scripts/omarchy-hook-hooks/verify-mbp-fixes.sh
omarchy-hook post-update               # expect: all machine fixes intact
```

`fix-wifi-firmware.sh` prefers a saved tarball at
`~/.local/share/mbp-t2-firmware/firmware-renamed.tar` (there is one on this machine,
sha256 in `firmware-renamed.tar.sha256`). If it's missing it re-downloads Apple's
recovery image (~850 MB) and re-extracts — the same Method 5 path used originally.
