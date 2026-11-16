# 06 — Suspend hangs (freeze never completes)

**Symptom.** Suspend (menu, lid, or idle) leaves the machine looking asleep — panel
dark, fans quiet — but it never actually sleeps. It gets warm, drains the battery, and
the only way back is a long power-button press (a full power cycle). Nothing is in the
journal after the point of no return.

**Fix script:** [`../scripts/fix-suspend-hang.sh`](../scripts/fix-suspend-hang.sh) —
takes effect immediately, no reboot.

## Root cause

`applesmc` — the **pre-T2** Apple SMC driver — keeps getting loaded on a T2 Mac, and
its probe never completes.

The evidence, from the boot that hung (17:30):

```
PM: suspend entry (deep)
Filesystems sync: 0.032 seconds
smpboot: CPU 1..11 is now offline
Freezing user space processes
applesmc applesmc.768: probe with driver applesmc failed with error -5
Freezing user space processes failed after 20.001 seconds
  (1 tasks refusing to freeze, wq_busy=0):
task:(udev-worker)  state:D
  __schedule
  usleep_range_state
  smc_sane+0x3d/0x110 [applesmc]
  read_smc+0x23/0x340 [applesmc]
  applesmc_init_smcreg_try+0x6c/0x400 [applesmc]
  applesmc_init+0xa8/0xff0 [applesmc]
  do_one_initcall
  __x64_sys_finit_module
```

Three things had to line up:

1. **Why it loads.** `applesmc`'s ACPI id is `APP0001` (alias `acpi*:APP0001:*`). On
   this machine that device is
   `/sys/devices/pci0000:00/0000:00:1f.0/APP0001:00`, modalias
   `acpi:APP0001:SMC-HURONRIVER:`. Whenever udev emits an `add` for it, its `kmod`
   builtin calls `modprobe` with that modalias — and `applesmc` claims it, even though
   `macsmc-acpi` is the driver actually bound.
2. **Why it wedges.** `applesmc_init()` probes for its register layout in `smc_sane()`,
   which is a `usleep_range` loop, and on a T2 the SMC never answers the way it expects.
   It burns ~60 s inside a kernel initcall, in **uninterruptible (D) state**. Every
   boot since has the same `probe with driver applesmc failed with error -5`.
3. **Why that kills suspend.** A task in D state cannot be frozen. `pm-suspend` waits
   out `pm_freeze_timeout` (20 s), gives up, and aborts the sleep — but the panel and
   most devices are already down, so it *looks* asleep while the CPU keeps running.

The udev worker that owns the probe is the `udev-worker` in the trace, which is also
why an unrelated symptom appears at the same moment:

```
systemd-udevd[615]: id: Worker [674] processing SEQNUM=4505 is taking a long time.
```

`applesmc` is the **wrong driver for this hardware regardless**. `macsmc-core`,
`macsmc-acpi`, `macsmc-power` and `macsmc-hwmon` drive the same SMC through ACPI and
are already what the battery, RTC, watchdog and fan sensors run on. `applesmc` has
never once probed successfully here — there is no sensor, fan or backlight that
depends on it.

## Fix

```
/etc/modprobe.d/blacklist-applesmc.conf
```
```
blacklist applesmc
install applesmc /bin/true
```

Both lines are needed, and the second is the one that matters:

- `blacklist` only suppresses **alias-based** auto-loading. udev asks `modprobe` by
  modalias, so this alone still lets it through — verified: with only `blacklist`,
  `modprobe -v applesmc` still ran `insmod`.
- `install applesmc /bin/true` replaces the load with a no-op, so *every* request path
  (udev modalias, explicit `modprobe`, a dependency pull) is refused.

```bash
./scripts/fix-suspend-hang.sh
```

The script also `modprobe -r`s the module from the running session if it happens to be
loaded, so the next sleep is fixed without rebooting. That unload is safe *because*
the probe never succeeds — nothing is bound to it.

## Verify

The script can prove the fix without actually suspending. `pm_test=freezer` runs the
kernel's own freeze step and thaws after 5 s; it never enters S3, so it cannot leave
the machine asleep.

It deliberately does **not** touch `/sys/power/pm_freeze_timeout`: that attribute is in
milliseconds (20000 by default, which is where the `20.001 seconds` above comes from),
and lowering it would weaken the very timeout the test depends on — and would then
affect the next real suspend. The 5 s wait is the kernel's own.

```bash
./scripts/fix-suspend-hang.sh --test
```

Before the fix that step is exactly where suspend died:

```
Freezing user space processes failed after 20.001 seconds
  (1 tasks refusing to freeze, wq_busy=0):
task:(udev-worker) state:D  ... smc_sane [applesmc]
```

After the fix, on this machine:

```
==> Freezing userspace for 5s (pm_test=freezer, no real sleep)
==> Kernel said:
    Freezing user space processes completed (elapsed 0.001 seconds)
    OK — userspace froze cleanly. Real sleep should now work.
```

The device-suspend stage was checked the same way (`pm_test=devices`, which stops just
before entering S3 — `rc=0`, and the AMD dGPU came back as `D0`), so the other known
suspend hazard on this box ([04](04-dgpu-power.md)) is not biting.

Then a real sleep, with a self-wake so a failure cannot strand the machine:

```bash
pkexec rtcwake -m mem -s 20
```

```bash
./scripts/fix-suspend-hang.sh --status
```

```
=== blacklist ===
  applied: /etc/modprobe.d/blacklist-applesmc.conf
=== applesmc loaded? ===
  not loaded
=== sleep mode ===
  mem_sleep: s2idle [deep]
=== last freeze attempt ===
  Freezing user space processes completed (elapsed 0.002 seconds)
```

## Gotchas

- **Do not "fix" this by switching to `s2idle`.** Omarchy already sets
  `mem_sleep_default=deep`, and `deep` is what this firmware supports
  (`/sys/power/mem_sleep` = `s2idle [deep]`, ACPI `S0 S3 S4 S5`). Moving to `s2idle`
  hides the broken freeze instead of removing the D-state task, and s2idle on these
  machines is the variant known to come back with a dead Touch Bar. The blacklist fixes
  the actual cause, so `deep` stays.
- **`applesmc` is not what the fans use.** Fan readings come from `macsmc-hwmon`
  (`fan1_input`/`fan2_input`) and the SMC's own curve drives them. Blacklisting
  `applesmc` affects neither — see [09](09-fan-daemon.md) for the fan daemon, which is
  broken for an unrelated reason.
- **`pm_async=off` is already set** in `/etc/limine-entry-tool.d/t2-mac.conf` (t2linux
  requirement). Do not remove it while chasing suspend problems.
- If suspend still fails after this fix, `pm_test=devices` narrows it to a device rather
  than userspace, and `/sys/power/suspend_stats/last_failed_dev` names the culprit.
- The blacklist is a **config gap**, not an Omarchy bug: Omarchy's T2 installer never
  blacklists `applesmc`, and upstream `applesmc` claims an ACPI id that T2 firmware
  hands to `macsmc-acpi` too.
