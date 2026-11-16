# 09 — t2fanrd restarts forever ("Fan not found")

**Symptom.** `systemctl status t2fanrd` never reaches `active` — it sits in
`activating (auto-restart)` — and the journal is nothing but:

```
t2fanrd[49330]: Error: Fan not found
systemd[1]: t2fanrd.service: Main process exited, code=exit, status=1/FAILURE
systemd[1]: t2fanrd.service: Scheduled restart job, restart counter is at 5348.
```

One restart every two seconds. This boot reached **8826** of them.

Harmless for cooling (see below), but it is a permanent 2-second wakeup plus endless
journal writes, and it makes `systemctl --failed` / journal review useless.

**Fix script:** [`../scripts/fix-fan-daemon.sh`](../scripts/fix-fan-daemon.sh)

## Root cause

`t2fanrd` looks for the fans under the SMC ACPI device:

```bash
$ strings /usr/bin/t2fanrd | grep APP0001
/sys/devices/pci*/*/*/*/APP0001:00/fan*
```

On this kernel the fans are not published there. `macsmc-hwmon` exposes them one level
deeper, through the standard hwmon interface:

```
/sys/devices/pci0000:00/0000:00:1f.0/APP0001:00/macsmc-hwmon/hwmon/hwmon4/fan1_input
                              ... /macsmc-hwmon/hwmon/hwmon4/fan2_input
```

```
$ ls -d /sys/devices/pci*/*/*/*/APP0001:00/fan*
ls: cannot access '/sys/devices/pci*/*/*/*/APP0001:00/fan*': No such file or directory
```

So the glob matches nothing, the daemon exits 1, and the shipped unit's
`Restart=always` / `RestartSec=2` turns a single failure into a loop.

This is **not** a local misconfiguration and nothing in `/etc/t2fand.conf` can fix it —
both `[Fan1]` and `[Fan2]` sections already match the two fans that exist. It is a known
upstream gap: T2FanRD has **"Add macsmc support" (#21)** and **"Hwmon support" (#22)**
open, and there is a third-party fork (`miercolesv/t2linux-fix-for-t2fanrd`) whose whole
description is *"Fix for the new linux kernel 7.3 which broke t2fanrd, so until there's
an official fix…"*.

`applesmc` is not an alternative source either: it is the pre-T2 driver and has never
probed on this machine (see [06](06-suspend-hang.md)) — which is why its `fan*` nodes
do not exist.

## Fix

Mask the unit. The fans were never under the daemon's control anyway.

```bash
./scripts/fix-fan-daemon.sh
```

**Why masking is safe** — the SMC runs its own fan curve through `macsmc-hwmon`, and it
was measured doing so under full load (12 threads, 75 s):

```
t=05s cpu=99C  fan1=2732 fan2=2555
t=25s cpu=81C  fan1=3994 fan2=3654
t=50s cpu=100C fan1=4739 fan2=4428
t=75s cpu=76C  fan1=5828 fan2=5409     (max is 5927 / 5489)
```

and ramping back down as it cools (5442 → 4511 rpm over 60 s idle). With the daemon
unable to find a fan at all, it has never contributed any fan control here — the only
thing it produced was the loop.

**Masked, not disabled:** `disable` would be undone by the next `omarchy update` or
`pacman -S t2fanrd`, and the loop would come straight back. `mask` points the unit at
`/dev/null` and survives package updates.

## Verify

```bash
./scripts/fix-fan-daemon.sh --status
```

```
=== t2fanrd.service ===
  masked (no restart loop)
  restarts this boot: 8826
=== fans (macsmc-hwmon, SMC-controlled) ===
  fan1 (Fan 0): 5897 rpm   (min 2160, max 5927)
  fan2 (Fan 1): 5473 rpm   (min 2000, max 5489)
=== package ===
  t2fanrd r16.48baf96-1
```

The restart counter staying put is the proof — observed `8826` before and after a 12 s
wait, where it used to climb by ~6, and `journalctl -u t2fanrd --since '-45s'` reporting
`-- No entries --`.

A round-trip check runs without root and without touching a real unit:

```bash
./scripts/check-fan-daemon.sh
```

```
ok   apply detects an already-masked unit
ok   apply does not re-mask
ok   --revert unmask is called
ok   --revert enable --now is called
ok   --revert reports success
ok   naive pipeline misdetects a masked unit (why the fix looks odd)
ok   capturing the string detects it
```

The last two exist because the obvious way to detect a masked unit is wrong (see the
first Gotcha), and this script was written that way first.

## Gotchas

- **`systemctl is-enabled` exits 1 for a masked unit** while printing `masked`. Under
  `set -o pipefail`, `systemctl is-enabled X | grep -qx masked` is therefore **always
  false** — which made `--revert` silently refuse to unmask anything. The script
  captures the string and ignores the status instead (`unit_state`), and
  `check-fan-daemon.sh` guards both branches.
- **Do not "fix" this by writing `fanN_target` yourself.** It is `rw-r--r--` and takes a
  raw value, but the SMC re-asserts its own curve, so a hand-written target fights it
  instead of helping.
- If upstream adds macsmc/hwmon support, `--revert` unmasks and re-enables it. Watch
  issues #21/#22 rather than polling the package version — the freeze on this box is
  `r16.48baf96-1` and it is the current build.
- The fans spinning *up* here is not the daemon doing anything: 2732 → 5828 rpm happened
  with the daemon unable to find a fan, which is why removing it costs nothing.
- **`sensors` and `t2fanrd` disagree by design.** `sensors` (via `macsmc-hwmon`) shows
  the fans; `t2fanrd` cannot, because it only knows the old `APP0001:00/fan*` path. Two
  tools, two different interfaces — one of them obsolete.
