# 07 — Brightness not restored after a reboot

**Symptom.** After a restart the panel comes up at the firmware default — noticeably
dimmer than what was left set — and has to be raised again every boot.

**Fix script:** [`../scripts/fix-brightness-persist.sh`](../scripts/fix-brightness-persist.sh) —
instant, no reboot.

## What already worked

It matters to separate the pieces, because most of the usual advice does not apply here:

- The right device exists: `/sys/class/backlight/gmux_backlight` (max `65535`), and
  `omarchy-hw-display` already prefers it over the Touch Bar's `appletb_backlight`.
  `i915` logs `Skipping intel_backlight registration`, which is correct — the panel is
  behind the gmux.
- The udev wiring works. This systemd's `path_id` **does** produce a path for the
  PNP-parented backlight, so `99-systemd.rules` applies:

  ```
  $ udevadm info /sys/class/backlight/gmux_backlight | grep -E 'ID_PATH|SYSTEMD_WANTS'
  E: ID_PATH=acpi-APP000B:00
  E: SYSTEMD_WANTS=systemd-backlight@backlight:gmux_backlight.service
  ```

  (On some T2 models `path_id` fails here and the unit is never instantiated — the
  [systemd issue](https://github.com/systemd/systemd/issues/43793) case. Not this box.)

- Saving and restoring both work when invoked:

  ```
  $ brightnessctl -d gmux_backlight set 42%      # register: 27525
  $ systemd-backlight save backlight:gmux_backlight
  $ cat /var/lib/systemd/backlight/acpi-APP000B:00:backlight:gmux_backlight
  27525
  $ brightnessctl -d gmux_backlight set 100%
  $ systemd-backlight load backlight:gmux_backlight
  # register back to 27525
  ```

So the state file and the restore are fine. The problem is **when the save happens**.

## Root cause

`systemd-backlight@.service` writes the state file only in its `ExecStop`, i.e. at a
clean systemd shutdown:

```
ExecStart=/usr/lib/systemd/systemd-backlight load %i
ExecStop=/usr/lib/systemd/systemd-backlight save %i
```

Anything that is not a clean shutdown loses whatever was set since the last one. On
this machine that was not hypothetical: suspend was hanging and being recovered with a
long power-button press (see [06](06-suspend-hang.md)), so **every** sleep risked a
dirty power-off. Brightness "not persisting" was mostly a symptom of that.

It is still worth closing on its own, because the saved value is only ever as fresh as
the last clean shutdown — a crash, a `SysRq`-b reboot, or a run of suspended-then-forced
power-offs all fall back to a much older level.

## Fix

Save on every brightness *change* instead of only at shutdown. The backlight driver
emits a `change` uevent on each write to `brightness`, which is the earliest moment the
new value is known:

```
/etc/udev/rules.d/99-gmux-backlight-save.rules
```
```
ACTION=="change", SUBSYSTEM=="backlight", KERNEL=="gmux_backlight", \
  RUN+="/usr/lib/systemd/systemd-backlight save backlight:gmux_backlight"
```

Only `gmux_backlight` is covered — `appletb_backlight` is the Touch Bar, and the
keyboard backlight has its own Omarchy handling.

```bash
./scripts/fix-brightness-persist.sh
```

The script reloads udev rules and seeds the state file from the live register, so the
level that is set right now is the one that survives the next reboot.

## Verify

Change the brightness and watch the state file follow it, without any shutdown
involved:

```bash
brightnessctl -d gmux_backlight set 50%
./scripts/fix-brightness-persist.sh --status
```

Observed here:

```
$ brightnessctl -q -d gmux_backlight set 33%; ./scripts/fix-brightness-persist.sh --status | grep -E 'brightness:|value:'
  brightness: 21627 / 65535 (33%)
  value: 21627 (updated 2026-11-16 22:03:02)

$ brightnessctl -q -d gmux_backlight set 71%; ./scripts/fix-brightness-persist.sh --status | grep -E 'brightness:|value:'
  brightness: 46530 / 65535 (71%)
  value: 46530 (updated 2026-11-16 22:03:05)
```

The `value:` line tracking `brightness:` within a second or two is the proof; a stale
`updated` timestamp means the rule is not firing (`udevadm control --reload-rules`, then
check `udevadm test /sys/class/backlight/gmux_backlight`).

## Gotchas

- **Brightness is a percentage of 65535 here, not of 937 or 1000.** Any script that
  assumes `max_brightness` is small will look wrong on this panel. `omarchy
  brightness display` and `brightnessctl` both read the real maximum, so use them
  rather than writing the register directly.
- **The register is not reset by a DPMS cycle or a `hyprctl reload`** on this kernel —
  verified stable across both, and across 190 s with the panel blanked. The gmux
  firmware reset described for some Macs (`linux-on-t2-mac`: "the register is reset to
  80% while the screen is off") does not reproduce here, so no `system-wake` hook is
  needed.
- **Do not point a save rule at `appletb_backlight`** to "cover everything": it is the
  Touch Bar, and the panel is the only backlight whose level the user cares about.
- If a future systemd makes `path_id` fail for the PNP parent again (the issue above),
  the `SYSTEMD_WANTS` wiring disappears and *restore* stops too. The check is the first
  command in "What already worked"; the upstream workaround is a local rule that adds
  `TAG+="systemd"` and the `SYSTEMD_WANTS` itself.
