# 08 — Battery charge limit

**Goal.** Stop charging at a chosen level instead of 100%, to slow down the calendar
ageing of the pack.

**Fix script:** [`../scripts/fix-battery-charge-limit.sh`](../scripts/fix-battery-charge-limit.sh) —
instant; the limit is also re-applied on every boot.

```bash
./scripts/fix-battery-charge-limit.sh 80    # stop at 80%
./scripts/fix-battery-charge-limit.sh       # show the current window
./scripts/fix-battery-charge-limit.sh --off # back to a full charge
```

## Why bother

A lithium pack held at 100% and warm loses capacity fastest. Keeping it in the middle
band — the common desktop choice is roughly 55–80% — costs an hour of unplugged runtime
and buys back a large part of the wear. On this machine the pack is 93 cycles old and
still reports `health: Good`, so the point is to keep it that way.

## What the hardware exposes

```
/sys/class/power_supply/macsmc-battery/charge_control_end_threshold   # 100 = no limit
```

That is the only threshold attribute on this kernel. There is **no**
`charge_control_start_threshold` and no `charge_behaviour`:

```
$ cat /sys/class/power_supply/macsmc-battery/charge_control_start_threshold
cat: ...: No such file or directory
```

So only the **top** of the window is settable from Linux. The SMC keeps its own
restart level — UPower reports it as `charge-start-threshold: 75%` — and starts
charging again once the pack falls below it. That is why `fix-battery-charge-limit.sh`
takes one number: a second argument is only validated and then explicitly ignored
(with a note), so nothing pretends a start threshold was applied.

`1`-`100` are accepted. **`0` is not** — this driver rejects it with `Invalid argument`
(confirmed on this machine: 1, 49, 50, 99 and 100 all stick; 0 fails), even though the
attribute reads back `0` before anything has ever set it. So the "no limit" value to
write is `100`, which is what the firmware default turns out to be and what `--off`
uses. The script never writes `0`.

The script accepts `50`-`99` (`--off` for 100). It validates that range by pattern
rather than with bash arithmetic on purpose: `(( 080 ))` is an octal parse error and
`(( 99999999999999999999 ))` overflows, and either would slip past a numeric
comparison and store an unusable value for the boot unit.

## Fix

The threshold is a plain sysfs attribute, so the fix is a write plus something to
repeat it at boot:

```
/etc/omarchy-battery-limit.conf
  END_THRESHOLD=80

/etc/systemd/system/battery-charge-limit.service
  ExecStart=/bin/sh -c '. /etc/omarchy-battery-limit.conf; [ -w <attr> ] && echo "$END_THRESHOLD" > <attr> || true'
```

`Type=oneshot` + `RemainAfterExit=yes`, `WantedBy=multi-user.target`. No daemon, no
polling: the SMC latches the value and keeps enforcing it.

## Verify

Apply, and confirm the attribute took it:

```bash
./scripts/fix-battery-charge-limit.sh 80
#   limit:     stops at 80%
```

and that the boot unit re-applies it — set something else, run the unit, check it was
overwritten:

```bash
pkexec sh -c 'echo 91 > /sys/class/power_supply/macsmc-battery/charge_control_end_threshold'
pkexec systemctl restart battery-charge-limit.service
cat /sys/class/power_supply/macsmc-battery/charge_control_end_threshold
# 80
```

Charging follows the limit immediately — verified on this machine by setting the
threshold above the current capacity, which flipped the state and the current:

```
$ cat status                     Not charging   current_now=-18000
$ echo 100 > charge_control_end_threshold
$ cat status                     Charging       current_now=795000
```

The value also survives a driver reload (`modprobe -r macsmc-power && modprobe
macsmc-power` left it at the set value), so nothing needs to re-apply it on resume.

## Why not UPower

UPower does expose the value on D-Bus, but not usefully for setting it:

```
$ busctl introspect org.freedesktop.UPower .../battery_macsmc_battery | grep -i thresh
.EnableChargeThreshold        method    b
.ChargeEndThreshold           property  u   80      emits-change
$ busctl set-property ... ChargeEndThreshold u 70
Failed to set property ChargeEndThreshold: Property "ChargeEndThreshold" is not writable
```

Only `EnableChargeThreshold(bool)` is callable, and the property is a **cache**.
Observed here: with sysfs at `55`, UPower kept reporting `80` until it was restarted —
so a tool that reads the D-Bus property can disagree with the hardware. Writing the
sysfs attribute is the interface the kernel actually offers, and UPower re-reads it on
start (`55` in sysfs → `55` on D-Bus after a restart) without ever writing back over a
value it did not set.

`omarchy battery status` reads UPower first and falls back to this same sysfs attribute,
which is why a limit set here shows up in the bar and the power panel.

## Gotchas

- **A limit below the current charge does not force a discharge.** The pack simply stops
  charging; it drains through normal use. `fix-battery-charge-limit.sh` says so when the
  capacity is already above the new limit.
- **Never write `0`.** It reads as "no limit" in some docs, but this driver rejects the
  write with `Invalid argument`; `100` is the value that means "charge to full".
- `power-profiles-daemon` (`omarchy-power-profiles-daemon`) is installed and active and
  does not touch the threshold — the two do not conflict. There is no `tlp` on this box.
- If you later change the limit by hand, change `/etc/omarchy-battery-limit.conf` too,
  or the next boot will put it back.
