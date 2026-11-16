# 05 — External monitor over USB-C/DisplayPort detected but black

Symptom: plug a monitor into a USB-C/DP port and macOS-style behaviour is expected.
Linux instead shows a sign of life — the panel wakes, `hyprctl monitors` lists it with a
description, a mode and a workspace — but **no video output**. The screen stays black.

This is not a cable, EDID or configuration problem. It is a one-character bug in
`aquamarine` (Hyprland's DRM backend), and it only bites **this exact hardware
combination**: an iGPU rendering while an AMD **Polaris** GPU scans out.

## What the diagnosis looked like

Three observations pointed at the link, and two of them were red herrings:

```
/sys/class/drm/card0-DP-4/status   = connected
/sys/class/drm/card0-DP-4/enabled  = disabled      <-- kernel never turned it on
/sys/class/drm/card0-DP-4/dpms     = Off

hyprctl monitors -> Monitor DP-4 (ID 1) 2560x1440@59.95  <-- but Hyprland thinks it's up
```

`edid-decode` read a perfectly good EDID (LG IPS QHD, 2560x1440@59.95, 241.5 MHz), and
`/sys/kernel/debug/dri/0/state` showed **every amdgpu CRTC with `enable=0`** and
`connector[111]: DP-4  crtc=(null)` — no atomic commit had ever landed. The interesting
detail was:

```
/sys/kernel/debug/dri/0/DP-4/link_settings
Current:  0  0x0  0   Verified:  4  0x1e  16   ...
```

`Current: 0 lanes` is a *symptom* of "never modeset", not a link-training failure — AUX
and EDID worked fine on the same connector. Chasing DPCD/AUX/link-training here wastes
time. The answer was in Hyprland's own log:

```
DEBUG from aquamarine ]: drm: Modesetting DP-4 with 2560x1440@59.95Hz
ERR from aquamarine ]: EGL (verifyDestinationDMABUF): FAIL, format is external-only
ERR from aquamarine ]: EGL (blit): failed to blit: destination dmabuf unsupported
ERR from aquamarine ]: drm: Backend requires blit, but blit failed
   ... repeated ~12 000 times
```

Read it as: *the modeset is attempted forever and never commits.*

## Root cause

`src/backend/drm/Renderer.cpp`, `CDRMRenderer::verifyDestinationDMABUF()`, in
aquamarine ≤ 0.15.1:

```c
if (fmt.modifier != DRM_FORMAT_INVALID && fmt.external) {   // WRONG constant
    backend->log(AQ_LOG_ERROR, "EGL (verifyDestinationDMABUF): FAIL, format is external-only");
    return false;
}
```

`DRM_FORMAT_INVALID` is `0`. The author meant `DRM_FORMAT_MOD_INVALID`
(`0x00ffffffffffffff`). This matters because `initDRMFormats()` always appends an entry
`(DRM_FORMAT_MOD_INVALID, external = true)` for every format — "EGL can always do
implicit modifiers". So a destination buffer whose modifier is **implicit**
(`MOD_INVALID`) matches that entry, passes `!= 0`, and gets rejected. The check does the
precise opposite of what hyprwm/aquamarine#143 intended.

Why only some machines: amdgpu advertises KMS format modifiers only on GFX9+. On
**Polaris** `supportsAddFb2Modifiers` is false, so the scanout swapchain for the dGPU is
allocated modifier-less:

```
GBM: Buffer is marked as multigpu, forcing linear
GBM: Using modifier-less allocation
GBM: Allocated a new buffer with size 2560x1440 and format XR24 with modifier 0xffffffffffffff : INVALID
```

Every blit destination therefore carries the implicit modifier and always trips the bad
check. And on this laptop a blit is mandatory for **every** frame: Hyprland's renderer is
`/dev/dri/card1` (the Intel iGPU, correct for power), while the external port hangs off
`/dev/dri/card0` (the AMD dGPU, `ID_PATH=pci-0000:01:00.0`). iGPU renders → skips the
dGPU scanout buffer → atomic commit fails → black screen.

Upstream fixed it on `main` (and in v0.16.0) by using `DRM_FORMAT_MOD_INVALID`.

## The fix

Build aquamarine **0.15.1** with the constant corrected and drop it in, because 0.15.1 is
what Hyprland 0.56.2 links against (**SOVERSION 14**). Building 0.16.0 would bump the
SOVERSION to 15 and leave Hyprland unable to start.

```bash
./scripts/fix-external-monitor.sh    # builds + installs, needs root via pkexec
# then restart the graphical session — the old .so is already mapped
systemctl --user restart wayland-wm@hyprland.desktop.service
```

The patch is `patches/aquamarine/0001-fix-modifier-type-check.patch` (one line); the
build recipe is `patches/aquamarine/PKGBUILD` if you prefer `makepkg`.
`cmake` and `hyprwayland-scanner` are not installed system-wide on this box, so the
script bootstraps both into `~/.local/src` with no package installs — inside a hyprland
session the polkit dialog can be slow/flaky to authorise with, and this avoids needing
it except for the single final `install`.

The result, before and after, on the same connector:

| | before | after |
|---|---|---|
| `card0-DP-4/enabled` | `disabled` | **`enabled`** |
| `card0-DP-4/dpms` | `Off` | **`On`** |
| `external-only` errors | ~12 000 | **0** |
| `Modesetting DP-4` | ~12 000 retries | **1** |

## Verify

```bash
./scripts/verify-aquamarine-patch.sh --session
```

```
PATCHED: /usr/lib/libaquamarine.so.0.15.1 compares against DRM_FORMAT_MOD_INVALID
session: Hyprland (pid 130118) maps the installed .so
```

There is no string or symbol that distinguishes the two builds, so the verifier looks at
the disassembly: the patched function contains `movabs $0xffffffffffffff` before the
comparison, the stock one contains `test %rsi,%rsi`. Exit code is 1 when the bug is back.

## It will come back unless you look

`aquamarine` is still `0.15.1-1` in Arch's `extra` repo, so **any system upgrade that
touches aquamarine reinstalls the buggy `.so`** — pacman flags it:

```
warning: aquamarine: /usr/lib/libaquamarine.so.0.15.1 (SHA256 checksum mismatch)
```

The permanent fix is aquamarine ≥ 0.16.0, which is already patched upstream. That update
alone will not work with the current binary: 0.16.0 moves SOVERSION 14 → 15, so
Hyprland must be rebuilt/reinstalled in the same transaction (a normal
`pacman -Syu` that upgrades both together is fine). **Until that pairing lands, after
every system update run `./scripts/verify-aquamarine-patch.sh` and re-run
`./scripts/fix-external-monitor.sh` if it reports BUGGY.**

## Related

This is the same stack as `docs/04-dgpu-power.md`: the external port is wired to the dGPU,
so anything that powers the dGPU off (`amdgpu-off.service`) also kills this monitor. If
you have dGPU-off enabled, the external display is simply unavailable — that is expected,
not this bug.
