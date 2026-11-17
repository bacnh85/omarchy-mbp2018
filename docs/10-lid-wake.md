# 10 — Opening the lid does not wake the machine

**Symptom.** Closing the lid sleeps the machine correctly. Opening it does not bring
it back — the screen stays dark and the only way in is to press the power button. It
looks like "lid open doesn't wake", and on a PC that usually means the lid switch is
disabled. Here it means almost the opposite.

**Fix script:** [`../scripts/fix-lid-wake.sh`](../scripts/fix-lid-wake.sh) — instant,
no reboot; persisted for the next boots.

```bash
./scripts/fix-lid-wake.sh            # apply
./scripts/fix-lid-wake.sh --status   # what woke the last sleep?
./scripts/fix-lid-wake.sh --revert   # back to power-button-only
```

## Root cause

Sleeping (`deep` = S3) arms only the wake GPEs that a **wakeup-enabled** device claims
through `_PRW`. Two steps decide it:

```
drivers/acpi/wakeup.c  acpi_enable_wakeup_devices(ACPI_STATE_S3)
    for each _PRW device where device_may_wakeup() || prepare_count:
        acpi_set_gpe_wake_mask(gpe, ACPI_GPE_ENABLE)        -> sets enable_for_wake

drivers/acpi/acpica/hwsleep.c  acpi_hw_enable_all_wakeup_gpes()
    just before the SLP_TYP write: enables enable_for_wake and
    CLEARS EVERY OTHER GPE BIT in those registers
```

So a GPE can wake the machine only if a `_PRW` names it **and** that device has wakeup
enabled. Two things follow that are not obvious:

1. **The lid has no usable GPE of its own on this machine.**

   ```
   /sys/firmware/acpi/interrupts/gpe6F    0 events,  disabled    <- LID0's own _PRW
   /sys/firmware/acpi/interrupts/gpe6E    3000+ events, enabled   <- "ACPI: EC: GPE=0x6e"
   ```

   The lid is read by the embedded controller and delivered as an ACPI **query on the
   EC's GPE**. `gpe6F` never fires. Enabling LID0 — the recipe every forum post gives —
   arms a line the lid does not use, which is why `LID0 *enabled` was already the
   default here and changed nothing.

2. **The EC's own wakeup flag was off, and that is what was missing.** The EC's `_PRW`
   names that same GPE `0x6E`, so enabling `EC` is what arms the lid's real wake line:

   ```
   $ grep ^EC /proc/acpi/wakeup
   EC      S4   *disabled   platform:PNP0C09:00      <- before
   EC      S4   *enabled    platform:PNP0C09:00      <- after
   ```

   While it was `*disabled`, `device_may_wakeup(EC)` was false, so
   `acpi_set_gpe_wake_mask(0x6E, ENABLE)` never ran and `0x6E` was **cleared at S3
   entry**. An EC event then could not raise a wake SCI at all. The lid query sat
   queued until some *other* wakeup delivered it.

That last sentence is exactly what the recorded lid cycles show. Both sleeps ended with
logind logging `Lid opened.` about 25 s in, ~0.7 s *before* `PM: suspend exit` — the lid
event was handed over by the resume, it did not cause it. And `LNXPWRBN:00`, the power
button, counted exactly two events, one per cycle:

```
$ ./scripts/fix-lid-wake.sh --status
  PNP0C0D:00 (lid reported by logind): 2
  LNXPWRBN:00 (power button)         : 2     <- the actual wake source, both times
```

Same story as the `MacBookPro14,3` reports in
[omarchy-pkgs#2472](https://github.com/omacom/omarchy-pkgs/pull/2472) and
[omarchy#14692](https://github.com/omacom/omarchy/pull/14692), by a different route:
there the missing piece was the s2idle EC mask, here it is the S3 `_PRW` wakeup flag.

## Fix

```
echo EC > /proc/acpi/wakeup
```

Nothing else changes. **`LID0` stays `*enabled`** — it is the default and harmless.
**`deep` stays** — this is not a reason to switch to `s2idle` (see
[06](06-suspend-hang.md)). The EC keeps doing its normal work; this only sets the
wakeup flag on a device the kernel already drives.

`/proc/acpi/wakeup` is a **toggle, not a setter**: writing a name flips its state, so
writing it twice turns the fix back off. The script reads first and writes only when the
state is wrong, and its boot unit does the same.

The script installs `/etc/systemd/system/lid-wake-ec.service` (oneshot, `RemainAfterExit`)
to re-apply at boot. It does not touch the bootloader and needs no reboot.

## Trade-off

Arming the EC GPE arms **everything the EC reports**, not just the lid — plugging the
charger in will wake the machine too. That is the price of a working lid wake on this
design, and it is why the flag defaults to off. `--revert` puts it back.

## Verify

```bash
./scripts/fix-lid-wake.sh --status      # EC must say "enabled"
```

Then close the lid, wait a few seconds, open it. It should come back with no button
press. `--status` afterwards tells you what actually happened:

- `PNP0C0D:00` up **and** `LNXPWRBN:00` unchanged → the lid woke it. Fixed.
- `LNXPWRBN:00` also up → a button was still pressed, so the EC GPE was not enough on
  this firmware. Confirm with `cat /sys/power/suspend_stats/last_failed_*` and the
  noirq resume timing before trying anything else — the next suspect is the Thunderbolt
  noirq stall (18.8 s per resume on this exact model, measured in
  [omarchy#8668](https://github.com/omacom/omarchy/issues/8668)), which the T2 flags
  Omarchy now ships do not address.

> **Status.** The root cause above is read from the kernel source and confirmed by the
> counters on this machine (`gpe6F` 0 events, `gpe6E` thousands, `EC *disabled`,
> `LNXPWRBN:00` = 2 for 2 lid cycles). The *conclusion* — that enabling `EC` makes lid
> open sufficient — has not yet been recorded on a real lid cycle here. Run the test
> above before trusting it.

## Gotchas

- **Enabling `LID0` does nothing here.** It is already enabled and its GPE (`gpe6F`)
  has never counted a single event. If a recipe tells you to enable the lid, that recipe
  was written for a machine whose lid has its own working GPE.
- **Do not "fix" this with `s2idle`.** `deep` works on this box now that
  [06](06-suspend-hang.md) removed the unfreezable `applesmc` probe; `s2idle` is the
  variant that comes back with a dead Touch Bar. The lid-wake gap is a wake-source
  flag, not a sleep-mode problem.
- **`/proc/acpi/wakeup` toggles.** Never `echo EC >` unconditionally in a boot unit or
  a hook that can run twice.
- **`ff_pwr_btn` in `/sys/firmware/acpi/interrupts/`** counts the *fixed* power button,
  which is a different source from `LNXPWRBN:00`. Read the `LNXPWRBN:00` event count to
  answer "was a button pressed".
- **A GPE name can be registered twice.** `PNP0C0D:00` appears as both `wakeup41` and
  `wakeup42`; reading only the first match reports 0 events for a lid that did fire.
  The script sums all matches under a name.
