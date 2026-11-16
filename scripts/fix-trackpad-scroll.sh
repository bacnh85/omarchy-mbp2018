#!/bin/bash
# Fix: trackpad two-finger scroll should be macOS-style (natural) on this MacBook.
#
# ROOT CAUSE
#   Omarchy's default is $OMARCHY_PATH/default/hypr/input.lua:
#       touchpad = { natural_scroll = false, ... }
#   "Reverted" here means back to macOS behaviour = natural scrolling ON, i.e.
#   content follows the fingers. The Touch Bar is a key strip with no scroll
#   surface, so this is purely the trackpad.
#
# FIX
#   ~/.config/hypr/input.lua overrides the default (loaded after it). Live state
#   is also set immediately so no logout is needed.

set -euo pipefail

INPUT_LUA="$HOME/.config/hypr/input.lua"
BLOCK='-- macOS-style two-finger scrolling on the built-in trackpad, as this Mac had
-- before Omarchy installed its own input defaults.
hl.config({
  input = {
    touchpad = {
      natural_scroll = true,
    },
  },
})
'

mkdir -p "$(dirname "$INPUT_LUA")"
touch "$INPUT_LUA"

if grep -q 'natural_scroll = true' "$INPUT_LUA"; then
  echo "==> natural_scroll already enabled in $INPUT_LUA"
else
  echo "==> Adding natural_scroll block to $INPUT_LUA"
  # Insert after the leading comment header so the file keeps its shape.
  { printf '%s\n' "$BLOCK"; cat "$INPUT_LUA"; } > "$INPUT_LUA.tmp"
  mv "$INPUT_LUA.tmp" "$INPUT_LUA"
fi

echo "==> Reloading Hyprland"
if [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] || ls /run/user/"$(id -u)"/hypr >/dev/null 2>&1; then
  SIG=$(ls /run/user/"$(id -u)"/hypr 2>/dev/null | head -1)
  HYPRLAND_INSTANCE_SIGNATURE=${HYPRLAND_INSTANCE_SIGNATURE:-$SIG} hyprctl reload >/dev/null
  sleep 1
  STATE=$(HYPRLAND_INSTANCE_SIGNATURE=${HYPRLAND_INSTANCE_SIGNATURE:-$SIG} \
    hyprctl getoption input:touchpad:natural_scroll)
  echo "    $STATE"
  grep -q 'bool: true' <<<"$STATE" || { echo "    FAIL: natural_scroll did not apply" >&2; exit 1; }
else
  echo "    (Hyprland not running; takes effect on next login)"
fi
