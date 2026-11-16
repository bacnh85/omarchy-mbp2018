# 04 — The AMD dGPU (RX 560X): does it work, and can it be on-demand?

Short answer: **the GPU hardware works, but on this model you cannot have both
"iGPU by default to save battery" and "dGPU available on demand without a reboot".**
Polaris on MacBookPro15,1 has no `amdgpu` runtime PM, so the card either runs (idle
~7 W) or is powered off until the next boot. Pick one; there is no middle state.

## What the hardware is

```
00:02.0  Intel UHD Graphics 630 (CFL GT2)          igpu, drives internal eDP-1 panel
01:00.0  AMD Baffin / Radeon Pro 555X-560X [1002:67ef]  dgpu, Polaris11
01:00.1  AMD Baffin HDMI/DP audio [1002:aae0]
```

Both drivers load normally: `i915` on the iGPU, `amdgpu` on the dGPU
(`amdgpu: initializing kernel modesetting (POLARIS11 0x1002:0x67EF 0x106B:0x018F 0xC2)`),
`SE 2, SH per SE 1, CU per SH 8, active_cu_number 16`, UVD 1.130 + VCE 53.26 firmware
found, `radeonsi_dri.so` and `vulkan-radeon` installed. `apple_gmux` reports
`gmux version 5.0.0 [T2]`, and at boot vgaswitcheroo already shows the iGPU as the
active adapter:

```
0:DIS-Audio: :DynOff:0000:01:00.1
1:IGD:+:Pwr:0000:00:02.0     <- the + is on IGD: iGPU is the display adapter
2:DIS: :Pwr:0000:01:00.0
```

So `apple_gmux.force_igd=1` (what the t2linux wiki recommends) is **already the
effective state on this box** — do not add it, it changes nothing. The internal panel
is on `card1-eDP-1` (iGPU) while it is running, and Hyprland renders on the iGPU
(`glxinfo -B` → `Mesa Intel(R) UHD Graphics 630 (CFL GT2)`, GL 4.6).

That answers the macOS-panic question as far as it can be answered without a stress
test: the panic the machine threw under macOS was in Apple's driver stack. Under Linux
the GPU enumerates, gets its VBIOS, powers up its SMUs, reads temp/power sensors
(57 °C / 7.43 W idle) and scans out a display — no signs of failing silicon. It is
**not** proof of stability under load; see "What is still unverified" below.

Note the dGPU is a **Radeon Pro 555X/560X**, not an RX 560 desktop card — 16 CUs,
~4 GB. Modest. It will not transform a game's framerate; its main value is GPGPU and
encoders.

## The actual constraint: no runtime PM

```
amdgpu 0000:01:00.0: Runtime PM not available
```

Polaris (and specifically this MacBook's ACPI: `\_SB_.PCI0.PEG0.GFX0` has no
`_PR3`/power resources, see `firmware_node/power_resources` → none) does not support
runtime power management. Consequences, all verified here:

| Attempt | Result |
|---|---|
| `echo auto > .../power/control` (default already `auto`) | stays `active`, `runtime_suspended_time=0`. No effect. |
| `power_dpm_force_performance_level=low` | **t2linux wiki: does not work on MacBookPro15,1** (no runtime PM on Polaris). Untested here — the card was already wedged. |
| `echo OFF > /sys/kernel/debug/vgaswitcheroo/switch` | **works.** `DIS: :Off`, drops to `D3hot`, hwmon stops responding (card asleep) |
| `echo ON > .../switch` afterwards | **wedged this machine.** See the trap below. |

Because runtime PM is absent, `amdgpu` alone keeps the card powered from boot to
shutdown. The idle cost measured here was **7.43 W** in `power1_input` — on a ~87 Wh
battery that is roughly an hour of runtime given away for a GPU that is not being used.

## Pick a mode

### Mode A — dGPU powered off (best battery; needs a reboot to get it back)

The t2linux recommendation. Drops idle draw substantially (wiki: ~20 W → ~9 W at 50 %
brightness). Installs `amdgpu-off.service`, which writes `OFF` to vgaswitcheroo before
the display manager starts.

```bash
./scripts/fix-dgpu-power.sh off     # then reboot
```

Cost when off: no `DRI_PRIME` offload, and **an external display attached to the dGPU
will not light up** (that port is wired to the dGPU — `ID_PATH=pci-0000:01:00.0`).
To get the dGPU back: `./scripts/fix-dgpu-power.sh on` then reboot.

This is a boot-mode toggle, not a switch. That is a hardware/driver limit, not a
config gap.

### Mode B — dGPU loaded, iGPU renders (on-demand offload, no reboot; pays the 7 W)

This is the machine's current state, and the only way to get "enable it when needed"
without a reboot. The dGPU sits loaded and idle; individual apps are pinned to it:

```bash
DRI_PRIME=1 glxinfo -B | grep 'OpenGL renderer'   # expect: AMD Radeon ... (radeonsi, POLARIS11)
DRI_PRIME=1 ./game-or-blender
MESA_VK_DEVICE_SELECT=1002:67ef! vulkaninfo      # Vulkan: select the AMD ICD explicitly
```

Un-pinned apps (Hyprland itself, browsers, terminals) keep using the iGPU, so the
desktop stays on the power-efficient path; only the pinned process pays for the dGPU.
`prime-run` does not exist on this box (`nvidia-prime` is not installed) — use the env
vars directly.

### Which to choose

Battery matters more than the occasional game → **Mode A**, and accept a reboot when
you need the GPU. You regularly use GPGPU/encoders/external display → **Mode B**; the
7 W is the price of instant availability.

## Trap: never `ON` the dGPU while it has a display

Do not "test" the power state by writing to vgaswitcheroo on a live session. This
exact sequence killed the dGPU mid-session here:

1. External monitor enumerated on the dGPU (`card0-DP-11`, MST, 2560x1440).
2. `echo OFF > /sys/kernel/debug/vgaswitcheroo/switch` → card to `D3hot`, then `D3cold`.
3. `echo ON > ...` → **`amdgpu: Unable to change power state from D3cold to D0, device inaccessible`**

From there it cascades and never recovers:

```
amdgpu 0000:01:00.0: [drm] Timeout wait for RLC serdes 0,0
amdgpu 0000:01:00.0: ring sdma0 timeout, signaled seq=490, emitted seq=492
amdgpu 0000:01:00.0: GPU reset begin!. Source:  1
amdgpu 0000:01:00.0: ASIC reset failed with error, -22 for drm dev, 0000:01:00.0
amdgpu 0000:01:00.0: GPU reset end with ret = -22
amdgpu 0000:01:00.0: SMU message 0x261 failed: response is 65535   (x many)
```

Symptoms afterwards: `power_state=D3cold` forever, `/sys/kernel/debug/vgaswitcheroo`
still claims `2:DIS: :Pwr`, every process that touched the GPU sits in uninterruptible
sleep (`wchan=amdgpu_info_ioctl`, ~40 tasks, loadavg ~45), `hwmon` returns
`Device or resource busy`, Hyprland and VS Code hang on exit, `pkexec` gets slow
because the polkit helper joins the D-state pile.

Recovery attempts that **do not work** — save yourself the time:

- `echo ON > vgaswitcheroo/switch` — no effect, stays `D3cold`.
- `lspci` still lists the device, so PCI removal looks like it worked, but
  `echo 1 > /sys/bus/pci/devices/0000:01:00.0/remove` + `echo 1 > /sys/bus/pci/rescan`
  cannot re-probe a card that will not answer config cycles, and
  `echo 0000:01:00.0 > /sys/bus/pci/drivers/amdgpu/bind` leaves it unbound.

**Only a reboot recovers it.** Do not run `vulkaninfo`, `vkcube`, `glxinfo` against the
AMD ICD while poking power states either — they block in `amdgpu_info_ioctl` and add
to the pile. If you want a GPU stress test, reboot first, stay in Mode B, and test the
card *without* touching vgaswitcheroo.

## What is still unverified

The dGPU was working (initialized, sensors live at 7.43 W / 57 °C, driving an external
display) right up until the power-state poke above. These were **not** tested and need
a reboot:

- `DRI_PRIME=1` actually rendering on `radeonsi` (expect
  `OpenGL renderer string: AMD Radeon ... (radeonsi, POLARIS11, LLVM ...)`).
- `power_dpm_force_performance_level=low` — the wiki says it fails on 15,1; worth one
  test since it would be a cheap thermal win if it worked.
- Any sustained load. Given the machine's macOS GPU-panic history, treat a 10-minute
  `glmark2` or a Blender render as the acceptance test before trusting it with real
  work. If it hangs the same way the panic did, the silicon is marginal and Mode A +
  iGPU-only is the correct permanent answer.

## Verify

```bash
./scripts/fix-dgpu-power.sh status
```

```
=== vgaswitcheroo ===
0:DIS-Audio: :DynOff:0000:01:00.1
1:IGD:+:Pwr:0000:00:02.0
2:DIS: :Pwr:0000:01:00.0
=== dGPU ===
state=D3hot  runtime=active  control=auto
=== amdgpu-off.service ===
disabled
=== renderers ===
OpenGL renderer string: Mesa Intel(R) UHD Graphics 630 (CFL GT2)
```
