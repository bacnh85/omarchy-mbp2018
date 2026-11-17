# 12 — Undervolting the CPU and dGPU: what is actually possible on this box

Asked for: lower voltage on both the i7-8850H and the Radeon Pro 560X, to cut heat and
fan noise while keeping reasonable performance.

**Verdict, measured on this machine:**

| Goal | Possible? | Why |
|---|---|---|
| CPU undervolt (V/F offset) | **No** | Voltage control (`MSR 0x150`) is ignored — locked by the post-Plundervolt microcode, not by a BIOS setting. Proven below. |
| dGPU undervolt | **No usable path** | OverDrive is masked out by `amdgpu.ppfeaturemask` (`PP_OVERDRIVE_MASK` = bit 14 = `0x4000` is clear in `0xfff7bfff`), so no `pp_od_clk_voltage` / `OD_VDDGFX_OFFSET` node exists, and a hand-edited `pp_table` is the only other route — real brick risk for a card whose idle draw is **not** voltage-bound anyway. |
| Less heat / less fan noise | **Yes, two levers** | (1) EPP / power profile — 12.5 W → 9.4 W idle, fan 4051 → ~2982 rpm. (2) dGPU powered off — **−7.1 W** and its 57 °C. |
| "Reasonable performance" | **Leave the limits alone** | Clamping `max_perf_pct` to 85 or 70 cost **no** power and no temperature (already thermal-saturated) but moved throughput ±6 %. Pure loss — see the sweep. |

The physics worth stating once: at a *fixed* performance target, heat falls only if
voltage falls, because P ∝ C·V²·f. Every other knob (RAPL/TDP limits, `max_perf_pct`,
EPP, `no_turbo`) buys **less performance for less heat** — it slides you *down* the
frequency/voltage curve to a *worse* point on it, which is why clamping here does not
even save watts. Undervolting is the only true win, and it is unavailable on this silicon.
What remains is: run fewer engines (dGPU off) and let the CPU idle in a lower P-state
(EPP), or accept less performance.

---

## 1. CPU: MSR 0x150 is writable but ignored

The three things an undervolt needs, in order:

```
$ cat /proc/cpuinfo | grep -m1 microcode
microcode	: 0xfa                  # 2019-11 or later -> contains the Plundervolt fix
$ pacman -Ss '^intel-undervolt$'     # extra/intel-undervolt 1.7-3 exists in the repos
extra/intel-undervolt 1.7-3
$ # MSR 0x150 readout, all 12 threads identical:
0x0150 = 0x185ac
   bits[15:0]  = 0x85ac       (voltage offset field)
   bits[20:16] = 0x1
   bit21       = 0            (some docs call this the "voltage locked" bit — it does NOT
                               mean unlocked here, see the write test)
   bit63       = 0            ()
```

Never trust a bit's docs. The test that settles it — write the register and read it back:

```python
v = rdmsr(0, 0x150)              # 0x185ac
wrmsr(0, 0x150, v)               # write the SAME value      -> succeeds
wrmsr(0, 0x150, v & ~0xFFFF)     # -50 mV into bits[15:0]    -> "succeeds", no error
rdmsr(0, 0x150)                  # 0x185ac  -- unchanged
```

A same-value write succeeds (so the MSR is not read-only and there is no `#GP`), but a
real offset write is **silently dropped**: every one of the 12 threads reads back
`0x185ac`. That is the microcode refusing the V/F offset while pretending to accept it —
exactly the behaviour Ian Beer / Plundervolt-era microcode (CVE-2019-11157) introduced on
Coffee Lake. `intel-undervolt` installed from `extra` would therefore report success and
change nothing; **do not bother installing it** (verified here, not assumed from a forum).

This is not the usual "BIOS locks it" story — there is no Apple firmware knob that
re-enables it either, because the lock lives in the CPU microcode loaded at boot.

## 2. dGPU: no voltage control, and it would not help

```
$ ls /sys/class/drm/card0/device/pp_od_clk_voltage      # (no such file)
$ cat /sys/module/amdgpu/parameters/ppfeaturemask
0xfff7bfff
$ python3 -c "m=0xfff7bfff; print([i for i in range(32) if not (m>>i)&1])"
[14, 19]                        # only PP_OVERDRIVE_MASK (0x4000) and PP_GFX_DCS_MASK (0x80000)
```

`amdgpu` only exposes `pp_od_clk_voltage` / `OD_VDDGFX_OFFSET` when
`enum PP_FEATURE_MASK` in `drivers/gpu/drm/amd/include/amd_shared.h` allows OverDrive, i.e.
bit 14 (`PP_OVERDRIVE_MASK = 0x4000`) — and that bit is the one cleared here.

**These are the shipped defaults, not a local override.** `amdgpu_drv.c` defines them
verbatim:

```c
/*
 * OverDrive(bit 14) disabled by default
 * GFX DCS(bit 19) disabled by default
 */
uint amdgpu_pp_feature_mask = 0xfff7bfff;
```

so the measured `0xfff7bfff` is bit-for-bit `amdgpu`'s own default, and indeed no
`amdgpu.ppfeaturemask=` appears in `/proc/cmdline` and no `options amdgpu` line exists in
`/etc/modprobe.d/`. The `MODULE_PARM_DESC` string is misleading — it says *"all power
features enabled (default)"* while the code disables two of them; trust the initialiser,
not the description. The `0x8000` bit sitting next to `0x4000` has nothing to do with
OverDrive (`PP_GFXOFF_MASK`) — read the enum, not the hex.

To *enable* OD, set bit 14 on top of the default — `0xfff7bfff | 0x4000 = 0xfff7ffff`
(i.e. `amdgpu.ppfeaturemask=0xfff7ffff`), which enables OverDrive and changes nothing else.
Not done here, per the reasoning below. The remaining route
is `pp_table` — the binary VBIOS power table is readable (4096 bytes) and writable, and
SMU7 tables of this shape do carry per-state voltage (mV) values. Editing it is possible
and is what `amdgpu-clocks`-style tools do on desktop Polaris cards. It is also the fastest
way to wedge this laptop's dGPU, and there is **no gain to collect**:

```
dGPU idle, nothing attached, all day:  sclk 214 MHz  mclk 300 MHz  busy 0 %  57 °C  7125 mW
```

7.1 W at the *lowest* clock state is leakage + PHYs + display engine + PCIe link, not
dynamic switching power. Knocking 50 mV off a state that is already at minimum frequency
does nothing measurable. Measured, one variable at a time, each given 4 s to settle:

| Attempt | Result |
|---|---|
| `power_dpm_force_performance_level=low` | 7125 mW, 56–57 °C — **no change** |
| `pp_power_profile_mode` = POWER_SAVING (2) | 7125 mW — **no change** |
| `pp_dpm_sclk` forced to state 0 | 7125 mW — **no change** (already there) |
| dGPU `echo OFF > vgaswitcheroo/switch` | **−7.1 W**, card at D3hot, `hwmon` gone ([04](04-dgpu-power.md) Mode A) |

`power1_cap` is firmly 40 W (`min 0`, `max 40`) and is the only dGPU power knob that
works — but a cap cannot go below the idle floor, and this card has never been near it.

**Conclusion:** the dGPU lever is not voltage, it is presence. Mode A from
[04](04-dgpu-power.md). No displays are attached to it right now (`card0-DP-4..7`,
`card0-eDP-2` all `disconnected`), so that 7.1 W is being spent on nothing.

## 3. What actually moves the noise: EPP / power profile

The desktop shipped on the `performance` profile (`powerprofilesctl get` →
`performance`, persisted in `/var/lib/power-profiles-daemon/state.ini`), which pins HWP to
`energy_performance_preference=performance` on all 12 threads — the CPU then sits at
~3.0 GHz and ~12.5 W doing nothing. `power-profiles-daemon`'s mapping on this box
(`PlatformDriver: placeholder`, so EPP is the only thing it drives):

| `powerprofilesctl set` | `energy_performance_preference` | governor |
|---|---|---|
| `performance` | `performance` | `powersave` (intel_pstate — the governor name is meaningless here) |
| `balanced` | `balance_performance` | `powersave` |
| `power-saver` | `power` | `powersave` |

Clean 30 s RAPL windows, nothing else sampling, 45 s settle between changes:

| Setting | Package power | Package °C | Fan 0 (rpm) |
|---|---|---|---|
| EPP `performance` (current, `max_perf_pct=100`) | **12.5 W** | 53 | 4051 |
| EPP `balance_power` | **9.5 W** | 53 | 3427 |
| EPP `power` | **9.4 W** | 54 | 2982 |
| EPP `power`, `max_perf_pct=50` | 9.4 W | 54 | 2648 |
| EPP `power`, `max_perf_pct=30` | 9.5 W | 55 | 2441 |
| EPP `power`, `no_turbo=1` | 9.5 W | 54 | 2339 |

**−3.1 W at idle for free, ≈1000 rpm quieter fans**, and the fan keeps drifting down for
a few minutes after each step (the SMC curve has long hysteresis — see §5). Floor is
~9.4 W: the cores go to 800 MHz either way, so clock caps and `no_turbo` add nothing
beyond what `power-saver` already does. `battery_aware=true` in ppd's state means this
already happens automatically on battery.

Use the shell's power widget (`omarchy-powerprofiles-list` / the bar menu) or:

```bash
powerprofilesctl set balanced      # daily: 9.5 W idle, ~3430 rpm
powerprofilesctl set power-saver   # quiet work: 9.4 W idle, ~2980 rpm
```

## 4. The perf/watt sweep: clamping buys nothing

12-thread `openssl speed -evp aes-256-cbc`, 40 s per point, `first_block` throughput as
the work unit (predictable, thermal-honest, no game loop needed):

| `max_perf_pct` | pkg W | avg pkg °C | core max °C | fan max rpm | AES MB/s |
|---|---|---|---|---|---|
| 100 | 29.6 | 54 | **100** | 5832 | 6485 |
| 85 | 30.2 | 56 | **100** | 5996 | 6893 |
| 70 | 30.1 | 56 | **100** | 5996 | 6532 |

Throughput swing is ±6 % (run-to-run noise on 12 shared SMT threads); package power does
not fall at all; all three points end at the same 100 °C with the fans at max. This 6-core
is **thermally** limited, not power-limit limited: at stock it stabilises around 29–30 W no
matter what the limit says, because the cooler cannot remove more.

That is also why the firmware power limits are not worth fighting. Under load, `thermald`
ramps RAPL down all by itself and lands at the same regime:

```
t= 1..4s  PL1 100 W   window 27.98 s      <- shipped values (intel-rapl:0 constraint_0/1)
t= 5..7s  PL1  95 W   window  1.00 s
t= 8..10s PL1  85 W
t=11..12s PL1  75 W
```

Writing PL1=45 W / PL2=60 W by hand changed nothing observable: 45 s of full load still
ended at 100 °C and 5900+ rpm, because the limit was never the binding constraint. Leave
`constraint_*`, `max_perf_pct`, `no_turbo` and the governor alone.

## 5. Why the fans never shut up (and the one risky lever left)

Idle is 24 °C ambient air and ~54 °C package, yet fans sit at 2400–4000 rpm. The SMC's
curve is not parametric in a way this machine exposes: `fan1_target` is writable and
immediately over-written by the SMC (`macsmc_hwmon` loads with **`fan_control = N`**, so it
does not even claim the fans), `t2fanrd` cannot find them at all ([09](09-fan-daemon.md)),
and the only nodes are `fan{1,2}_input/target/min/max`. Observed floor at 53 °C with every
CPU knob turned down: **2339 rpm** (fan min is 2160). Spin-down from full load is also slow:

```
+0 s    5943 rpm        +100 s  5762 rpm
+20 s   5943 rpm        +120 s  5383 rpm
+40 s   5970 rpm        +140 s  5086 rpm
+60 s   5945 rpm        +160 s  4869 rpm        (5.5–6 min to actually start falling)
```

The ban is real from Apple's side too: this fan profile is the one they shipped to keep a
100 °C 6-core alive in a 15 mm chassis.

The one thing that *would* lower the floor is taking the SMC curve away from the firmware:
`options macsmc_hwmon fan_control=Y` in `/etc/modprobe.d/` (then it exposes manual control
and `fanN_target` sticks) plus a daemon that understands the new interface —
[Anthony2cc/t2newfd](https://github.com/Anthony2cc/t2newfd) (fork of T2FanRD adapted to
`macsmc-hwmon`) or [akhilv1/neofand](https://github.com/akhilv1/neofand). **Not recommended
here:** you are replacing a curve that is empirically keeping the package at 100 °C-not-more
with one you tuned by ear, on a machine whose dGPU already has a history of misbehaving, and
the safe-mode revert (`fan_control=N` + reboot) only works if you can still boot. A lower
idle floor is achievable with `power-saver` at zero risk; that is where this should stop.

## 6. Recommended end state

```bash
# 1. Git the 7.1 W back (no dGPU displays attached; needs a reboot to undo -- see doc 04)
./scripts/fix-dgpu-power.sh off          # then reboot

# 2. Daily driver = balanced, quiet = power-saver (idle 12.5 W -> 9.5 / 9.4 W)
powerprofilesctl set balanced

# 3. Nothing else. No intel-undervolt, no PL1/PL2 edits, no max_perf_pct clamp,
#    no fan_control=Y, no pp_table editing.
```

Expected result: idle package 9.4–9.5 W instead of 19.6 W (12.5 CPU + 7.1 dGPU), fans
roughly 1000–1500 rpm lower at idle and much quieter spin-down after a burst, and the same
29–30 W / 100 °C ceiling under load — that ceiling is the cooler, not the config.

## Verify

```bash
# CPU voltage: writable, but the readback never changes -> locked by microcode
pkexec python3 - <<'EOF'
import struct
def rd(c,r):
    with open(f"/dev/cpu/{c}/msr","rb") as f: f.seek(r); return struct.unpack("<Q",f.read(8))[0]
def wr(c,r,v):
    with open(f"/dev/cpu/{c}/msr","wb") as f: f.seek(r); f.write(struct.pack("<Q",v))
v=rd(0,0x150); wr(0,0x150,(v & ~0xFFFF)); print(hex(v),"->",hex(rd(0,0x150)))  # identical
EOF

# dGPU: no voltage node, no OD, idle draw does not move with any DPM setting
ls /sys/class/drm/card0/device/pp_od_clk_voltage; cat /sys/module/amdgpu/parameters/ppfeaturemask
cat /sys/class/drm/card0/device/hwmon/hwmon*/power1_input   # 7125000 while powered

# The lever that works
powerprofilesctl set power-saver
cat /sys/devices/system/cpu/cpufreq/policy0/energy_performance_preference   # power
# idle RAPL over 30 s: (energy_uj delta)/1e6/30 -> ~9.4 W
```
