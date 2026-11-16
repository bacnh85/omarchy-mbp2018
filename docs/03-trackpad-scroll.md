# 03 — Trackpad scroll direction

**Symptom.** Two-finger scrolling on the built-in trackpad goes the "traditional"
(Windows) way. On this Mac it should behave like macOS: content follows the fingers.

**Fix script:** [`../scripts/fix-trackpad-scroll.sh`](../scripts/fix-trackpad-scroll.sh) — instant, no reboot.

## Root cause

Not a driver bug. Omarchy's own default is traditional scrolling:

`/usr/share/omarchy/default/hypr/input.lua`
```lua
hl.config({
  input = {
    ...
    touchpad = {
      natural_scroll = false,
      clickfinger_behavior = true,
      scroll_factor = 0.4,
    },
  },
})
```

Confirmed live before the fix:
```bash
hyprctl getoption input:touchpad:natural_scroll   # bool: false  set: true
```

Note the Touch Bar on this model is **not** a scroll surface — it is a key strip
(`hid-appletb-kbd`, mode 2 = special keys) exposing only key/EV_MSC events, no
`REL`/`ABS` axes. Whatever "scroll" felt wrong was the trackpad.

Also worth knowing: the touchpad is driven by `hid_magicmouse`, not `hid_multitouch`
— that is normal for T2 Macs, not a mis-binding.

## Fix

`~/.config/hypr/input.lua` is loaded *after* Omarchy's defaults (`hyprland.lua`
requires `hypr.input` last), so a `hl.config` block there overrides them:

```lua
-- macOS-style two-finger scrolling on the built-in trackpad, as this Mac had
-- before Omarchy installed its own input defaults.
hl.config({
  input = {
    touchpad = {
      natural_scroll = true,
    },
  },
})
```

Then:

```bash
hyprctl reload
```

A copy of the resulting file is in [`../config/hypr/input.lua`](../config/hypr/input.lua).

`hl.config` merges into the existing input tree, so the default
`scroll_factor`/`clickfinger_behavior` survive — only `natural_scroll` changes.

## Verify

```bash
hyprctl getoption input:touchpad:natural_scroll
# bool: true  set: true
```

Observed after the fix: `bool: true`, `set: true`.

## Gotchas

- **`hyprctl keyword input:touchpad:natural_scroll true` does not work** on this
  Hyprland (0.56.2): *"keyword can't work with non-legacy parsers. Use eval."* Use
  the config file + `hyprctl reload`, which is what the script does.
- Do **not** edit `/usr/share/omarchy/default/hypr/input.lua` — package updates
  overwrite it. The `~/.config/hypr/` copy is the supported override point.
- If you ever want traditional scrolling back: delete the block, `hyprctl reload`.
- Per-device override, if only one pointing device should invert:
  ```lua
  hl.device({ name = "apple-inc.-apple-internal-keyboard-/-trackpad-1",
              natural_scroll = true })
  ```
  Device names come from `hyprctl devices -j`.
