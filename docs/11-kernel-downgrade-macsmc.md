# 11 — `omarchy update` downgrades the kernel and takes macsmc with it

**Symptom.** After an update, the battery charge limit stops existing and the fan
sensors disappear. `fix-battery-charge-limit.sh` errors out with

```
/sys/class/power_supply/macsmc-battery/status: No such file or directory
```

and `hwmon` lists no `macsmc_hwmon`. Nothing was broken by hand: an update swapped
the kernel underneath the scripts.

**Fix:** an `IgnorePkg` hold, kept in place by two hooks —
[`../scripts/omarchy-hook-hooks/`](../scripts/omarchy-hook-hooks/).

## Root cause: epoch, not version

Two repositories both ship `linux-t2`, and pacman is told to prefer the wrong one:

| Repository | Version | `macsmc` modules |
|---|---|---|
| `omarchy` | `1:7.2.15.arch1-1` | **0** |
| `arch-mact2` | `7.3.4.arch1-2` | 9 |

Omarchy's build carries `epoch=1`, and an epoch outranks every other version
component:

```
$ vercmp 1:7.2.15.arch1-1 7.3.4.arch1-2
1                     # Omarchy's 7.2.15 is "newer"
$ vercmp   7.2.15.arch1-1 7.3.4.arch1-2
-1                    # without the epoch it is older, as it reads
```

`omarchy-update-system-pkgs` runs a plain `pacman -Syu`, so pacman did exactly what it
was told and logged the swap as an upgrade:

```
[ALPM] upgraded linux-t2 (7.3.4.arch1-2 -> 1:7.2.15.arch1-1)
```

The problem is not the downgrade as such, it is *what* the older package was built
without. `CONFIG_MACSMC_*` is off in Omarchy's kernel — `linux-omarchy` 7.2.15 has no
`macsmc` modules either — while the source header `macsmc.h` still ships in the
`-headers` package. So the drivers exist upstream, are present in 7.3.4, and are simply
not compiled in Omarchy's build.

That single config choice costs, on this machine:

| Capability | Driver | 7.2.15 | 7.3.4 |
|---|---|---|---|
| battery charge limit | `macsmc-power` → `charge_control_end_threshold` | — | 80% |
| fan tachometers | `macsmc-hwmon` (`fan1_input`, `fan2_input`) | — | 2472/2287 rpm |
| RTC | `rtc-macsmc` | generic `rtc_cmos` | `macsmc-rtc` |
| ambient light / accel / LEDs | `macsmc-light`, `macsmc-accel`, `leds-macsmc` | — | present |

The generic ACPI battery (`BAT0`, `ACPI0002`) still appears, which is what makes this
easy to miss: capacity and status look fine, and only the *threshold* attribute is
gone. `/sys/class/power_supply/BAT0/` has no `charge_control_end_threshold` at all, so
the limit is not merely unset, it is unsettable.

## The hold

```
/etc/pacman.conf
  IgnorePkg = linux-t2 linux-t2-headers
```

Pacman then reports the offered downgrade and declines it:

```
$ pacman -Qu linux-t2
linux-t2 7.3.4.arch1-2 -> 1:7.2.15.arch1-1 [ignored]
```

### Why `/etc/pacman.conf` alone is not enough

`omarchy refresh pacman` overwrites `/etc/pacman.conf` wholesale from its channel
template (it backs the old one up to `/etc/pacman.conf.bak`). Any hand-added
`IgnorePkg` line is gone on the next channel refresh. Omarchy provides a hook for
exactly this:

```bash
omarchy hook install pre-refresh-pacman ./scripts/omarchy-hook-hooks/keep-linux-t2-held.sh
omarchy hook install post-update       ./scripts/omarchy-hook-hooks/verify-mbp-fixes.sh
```

- **`pre-refresh-pacman`** runs after the template is written and *before* the package
  transaction, so the re-applied hold shapes that transaction. It performs a union
  with whatever `IgnorePkg` already holds, preserving the user's entries and never
  duplicating its own.
- **`post-update`** runs at the end of `omarchy update`, inside its sudo
  authorization. It verifies all eleven fixes, rebuilds aquamarine when a package
  upgrade restored the buggy `.so` (see `05`/`scripts/fix-external-monitor.sh`), and
  repairs a lost `IgnorePkg`.

Both are safe to run by hand:

```bash
omarchy-hook post-update            # full report
omarchy-hook pre-refresh-pacman     # re-assert the hold
```

### Why a hook must not use `pkexec`

`omarchy update` holds a `sudo` timestamp open for the whole run, so hooks run as the
user with `sudo` already authorized. `pkexec` knows nothing about that: it goes to
polkit, which needs a TTY to prompt, and with none it blocks instead of failing. The
scripts therefore resolve root as *root → cached `sudo -n` → `pkexec`*, and the
pre-refresh-pacman hook warns rather than hanging if none of the three is available —
that hook runs after Omarchy may have invalidated the sudo cache.

## Recovering a machine that already downgraded

The downgraded package is in the cache, so this needs no download:

```bash
sudo pacman -U /var/cache/pacman/pkg/linux-t2-7.3.4.arch1-2-x86_64.pkg.tar.zst \
               /var/cache/pacman/pkg/linux-t2-headers-7.3.4.arch1-2-x86_64.pkg.tar.zst
# then reboot into it
```

Give pacman **absolute** paths: `pkexec` chdirs to `/root`, and a relative filename is
then "could not find or read package".

The revert rebuilds the UKI and rewrites `/boot/limine.conf`; `t2bce_vhci` is present in
both kernels, so the LUKS keyboard fix (`01`) is unaffected. `default_entry` continues
to point at the `linux-t2` entry.

## Verify

```bash
uname -r                                        # 7.3.4-...-t2
pacman -Q linux-t2                              # 7.3.4.arch1-2
pacman -Ql linux-t2 | grep -c macsmc            # 9
lsmod | grep macsmc                             # macsmc_acpi, _power, _hwmon, _core
cat /sys/class/power_supply/macsmc-battery/charge_control_end_threshold   # 80
echo /sys/class/hwmon/hwmon*/fan*_input         # 2472 rpm 2287 rpm
./scripts/fix-battery-charge-limit.sh           # limit: stops at 80%
omarchy-hook post-update                        # all machine fixes intact
```

If `IgnorePkg` is ever lost, the post-update hook re-adds it; if this machine is
rebuilt from scratch, run both `omarchy hook install` lines after
`fix-battery-charge-limit.sh`.

## Alternative: stop using Omarchy's kernel

`IgnorePkg` freezes `linux-t2` at 7.3.4, so Omarchy's kernel fixes stop arriving. The
alternative is to run a kernel that does ship `macsmc` and keep updating it:

```bash
sudo pacman -S linux-lts-t2 linux-lts-t2-headers   # arch-mact2, 6.18.x
```

That trades a newer kernel for the LTS series. Either way the hold must name whichever
kernel is in use — the point is that the kernel carrying `macsmc` is the one that
boots.
