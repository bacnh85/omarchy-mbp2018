# MacBookPro15,1 (2018 15") — Omarchy fixes

Running Omarchy (Arch) on an Apple T2 MacBook Pro leaves twelve problems. Each has a
distinct root cause and a script here that fixes it, idempotently, and verifies itself.

| | |
|---|---|
| Model | MacBookPro15,1 — 2018 15", Apple T2 / iBridge 24.16.6005.0.0 |
| Kernel | `linux-t2` (not `linux-omarchy` — `BOOT_ORDER` puts `linux-t2` first) |
| Bootloader | limine, unified kernel images in `/boot/EFI/Linux/` |
| Disk | single boot: LUKS → btrfs. **No APFS, no macOS** |
| Wi-Fi | Broadcom BCM4364 `[14e4:4464]` → `brcmfmac` (never `broadcom-wl`) |
| GPU | Intel UHD 630 (`eDP-1`) + AMD Baffin 555X/560X `[1002:67ef]`, no runtime PM |

Tested on exactly this model and distro. Two neighbouring machines share the T2,
`macsmc` and dGPU quirks — **MacBookPro15,1 / MacBookPro16,x (AMD dGPU + T2)** — but
re-check the symptom before applying a fix: doc 04/05/12 assume the AMD card, doc 02
assumes the BCM4364.

---

## For an agent: run this

Prerequisite: Omarchy installed on `linux-t2`, a working non-interactive root path
(see [Running things as root](#running-things-as-root)), checkout cloned anywhere.

```bash
git clone https://github.com/bacnh85/omarchy-mbp2018.git
cd omarchy-mbp2018
./scripts/omarchy-hook-hooks/verify-mbp-fixes.sh   # already fixed / still broken?
```

That is the same checker `omarchy update` runs. Unprivileged it prints `--:` for the
checks it cannot make; with `sudo -n` it checks all of them.

Then apply, in this order. Reboot where marked, and re-run the checker at the end —
every script is idempotent, so re-running is always safe.

```bash
./scripts/fix-initramfs-keyboard.sh   # keyboard at the LUKS prompt   -> reboot
./scripts/fix-wifi-firmware.sh        # Wi-Fi (downloads ~850 MB unless cached)
./scripts/fix-trackpad-scroll.sh      # natural scroll, live, no logout
./scripts/fix-dgpu-power.sh off       # dGPU off, best battery        -> reboot
./scripts/fix-external-monitor.sh     # external monitor; re-run after aquamarine upgrades
./scripts/fix-suspend-hang.sh         # sleep actually sleeps
./scripts/fix-brightness-persist.sh   # brightness survives a dirty shutdown
./scripts/fix-battery-charge-limit.sh 80
./scripts/fix-fan-daemon.sh           # stops t2fanrd's restart loop
./scripts/fix-lid-wake.sh             # opening the lid wakes the machine
```

Then install the two update hooks, so the next `omarchy update` cannot undo any of it:

```bash
omarchy hook install pre-refresh-pacman ./scripts/omarchy-hook-hooks/keep-linux-t2-held.sh
omarchy hook install post-update       ./scripts/omarchy-hook-hooks/verify-mbp-fixes.sh
omarchy-hook post-update              # expect: all machine fixes intact
```

Notes that save a failed run:

- **Do the keyboard fix first.** Until it's applied, a reboot leaves no working
  keyboard at the LUKS prompt and needs a USB one.
- `fix-wifi-firmware.sh` reuses `~/.local/share/mbp-t2-firmware/firmware-renamed.tar`
  (sha256 alongside). Without it, it re-downloads Apple's recovery image
  (Method 5, the only path on a single-boot machine) and re-extracts.
- `fix-dgpu-power.sh` is a **boot toggle**, never a runtime one: turning the dGPU back
  on in a live session wedges it until reboot (doc 04).
- Any monitor/aquamarine fix needs the graphical session restarted — the patched
  `.so` is already mapped by the running compositor.

## What each fix is

Details, diagnosis and verification steps per fix: [`docs/`](docs/README.md).
Upstream status of the two patches: [`patches/`](patches/README.md).

| # | Symptom | Root cause | Fix |
|---|---------|-----------|-----|
| 1 | Built-in keyboard dead before login (needs a USB keyboard for the LUKS passphrase) | `zz-omarchy-kernel-modules.conf` strips `t2bce_vhci` **unconditionally**, so the `linux-t2` initramfs has no T2 keyboard driver | `fix-initramfs-keyboard.sh` |
| 2 | No Wi-Fi; Bluetooth looks broken but isn't | BCM4364 firmware is **not** in `linux-firmware`; only a macOS image has it | `fix-wifi-firmware.sh` |
| 3 | Two-finger scroll is Windows-style, not macOS-style | Omarchy ships `touchpad.natural_scroll = false` | `fix-trackpad-scroll.sh` |
| 4 | dGPU runs from boot and burns ~7.4 W idle, with no runtime toggle | Polaris has no `amdgpu` runtime PM (no `_PR3` on `GFX0`) | `fix-dgpu-power.sh off` + reboot |
| 5 | USB-C/DP monitor detected (EDID, mode, workspace) but black | `aquamarine` 0.15.1 tests a buffer modifier against `DRM_FORMAT_INVALID` instead of `DRM_FORMAT_MOD_INVALID`, so cross-GPU blits to Polaris are rejected and the atomic commit never lands | `fix-external-monitor.sh` |
| 6 | Suspend hangs — panel dark, machine never sleeps, long power-button press | `applesmc` claims the `APP0001` id owned by `macsmc-acpi`; its probe spins 60 s in D state, and a D-state task cannot be frozen, so `pm-suspend` aborts | `fix-suspend-hang.sh` |
| 7 | Brightness returns to the firmware default after a reboot | `systemd-backlight@` only saves in `ExecStop`, so dirty shutdowns lose the level — which #6 was forcing | `fix-brightness-persist.sh` |
| 8 | Charging cannot be capped below 100 % | Not a bug: `charge_control_end_threshold` exists but nothing set it (no *start* threshold on this kernel) | `fix-battery-charge-limit.sh 80` |
| 9 | `t2fanrd` never starts — "Fan not found" every 2 s, thousands of restarts | The daemon globs `APP0001:00/fan*`, but `macsmc-hwmon` publishes under `APP0001:00/macsmc-hwmon/hwmon/hwmonN/` (T2FanRD #21/#22) | `fix-fan-daemon.sh` |
| 10 | Lid close sleeps, lid open does not wake it | S3 arms only GPEs from wakeup-enabled `_PRW` devices; the lid rides the **EC's** `gpe6E`, not `LID0`'s, and `EC` was `*disabled` | `fix-lid-wake.sh` |
| 11 | After `omarchy update` the charge limit and fan sensors vanish | Omarchy ships `linux-t2` at `1:7.2.15` (epoch 1) **without** `CONFIG_MACSMC_*`; arch-mact2's `7.3.4` has all 9 modules but no epoch, so pacman "upgrades" into the older code | `IgnorePkg` hold + hooks |
| 12 | Wanted a CPU/dGPU undervolt for less heat and noise | Neither is reachable: MSR `0x150` ignores writes (microcode `0xfa`), and the dGPU has no OD node (`PP_OVERDRIVE_MASK` clear) — its 7.1 W idle is leakage, not switching power | Nothing to undvolt; use `powerprofilesctl` (`12.5 W → 9.4 W`) and dGPU off (`−7.1 W`) — [12](docs/12-undervolt-heat-fan.md) |
| 13 | Touch ID | Sensor and bridge work; the SEP holds **no** fingerprint this install can bind to, and only macOS can enrol one | Blocked — needs one macOS boot first ([13](docs/13-touchid-sep.md)) |

## Surviving `omarchy update`

An update is the one event that silently undoes the fixes above. Two hooks handle it:

| Hook | When | Does |
|---|---|---|
| `pre-refresh-pacman.d/keep-linux-t2-held.sh` | after `omarchy refresh pacman` rewrites `pacman.conf` | re-applies the `IgnorePkg` hold the rewrite drops |
| `post-update.d/verify-mbp-fixes.sh` | end of `omarchy update` | one check per fix 01–11; rebuilds aquamarine when an upgrade restored the buggy `.so`; reports a lost `IgnorePkg` |

The hold is visible to pacman, so the kernel shows as `[ignored]` instead of being
downgraded:

```bash
$ pacman -Qu linux-t2
linux-t2 7.3.4.arch1-2 -> 1:7.2.15.arch1-1 [ignored]
```

## Debugging traps on this machine

1. **`/etc/mkinitcpio.conf.d/` files are sourced in name order, after `mkinitcpio.conf`**
   — so a `zz-` drop-in silently undoes an earlier drop-in (that is fix #1). Print the
   effective result instead of reading one file:
   ```bash
   KERNELVERSION=$(uname -r) bash -c 'MODULES=(); HOOKS=(); . /etc/mkinitcpio.conf
     for f in /etc/mkinitcpio.conf.d/*.conf; do . "$f"; done
     echo "MODULES: ${MODULES[*]}"'
   ```
2. **`limine-mkinitcpio` rebuilds every installed kernel** (`linux-t2` *and*
   `linux-omarchy`). A fix for one can break the other's build, and a failed hook leaves
   a **stale but bootable UKI** on the ESP — always confirm inside the image with
   `lsinitcpio`.
3. **Effects you can only see after a reboot** (keyboard, dGPU, lid wake) cannot be
   verified from the live session — say so instead of claiming success.

### Running things as root

`sudo` may need a password and there is no askpass. The scripts resolve root as
**root → `sudo -n` → `pkexec <cmd> </dev/null`**. Keep that order in anything a hook may
call. Two things bite:

1. **`pkexec` chdirs to `/root`** and re-formats the environment — pass absolute paths
   only, or get "cannot stat" / "could not find or read package".
2. **`pkexec` hangs rather than failing without a TTY.** It works from an agent session
   once the polkit agent has authorised it (~4 s), but it will never return inside a
   hook that has no cached credentials.

## Updating this repo

```bash
./scripts/omarchy-hook-hooks/verify-mbp-fixes.sh   # add a check here too
git add -A && git commit -m "fix(09): <what and why>"
git push origin master
```

Keep the shape: a new fix needs `scripts/fix-<thing>.sh` (idempotent, `as_root`
helpers, a self-verification block, root cause in the header comment), a
`docs/<nn>-<thing>.md` (symptom → how the root cause was found → fix → verify) added to
`docs/README.md`, a row in the table above, and one check in
`scripts/omarchy-hook-hooks/verify-mbp-fixes.sh`. Anything that can regress on
`omarchy update` belongs in the post-update hook, not only in prose.

Firmware tarballs (`*.tar`, `*.dmg`, `*.img`) stay out of git — `.gitignore` covers them;
they live in `~/.local/share/mbp-t2-firmware/`.
