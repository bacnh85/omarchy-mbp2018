#!/bin/bash
# Detect whether the installed libaquamarine has the multi-GPU modifier fix.
# A pacman upgrade of aquamarine silently restores the buggy build; run this after
# any system update. Exit 0 = patched, 1 = buggy or missing.
#
# Why disassembly: the patch is one comparison operand, so there is no string or
# symbol that distinguishes the two builds. The patched function compares the
# buffer modifier against 0xffffffffffffff (DRM_FORMAT_MOD_INVALID); the stock one
# compares it against 0 (DRM_FORMAT_INVALID) via `test %rsi,%rsi`.
#
#   ./verify-aquamarine-patch.sh            check
#   ./verify-aquamarine-patch.sh --session  also check that the RUNNING Hyprland
#                                           loaded the patched build (after an
#                                           install you must restart the session)

set -uo pipefail

LIB=${LIB:-/usr/lib/libaquamarine.so.0.15.1}
rc=0

if [[ ! -e $LIB ]]; then
  echo "MISSING: $LIB" >&2
  exit 1
fi

addr=$(nm -DC "$LIB" 2>/dev/null | awk '/verifyDestinationDMABUF/ && / T / {print $1; exit}')
if [[ -z $addr ]]; then
  echo "BUGGY?: cannot locate verifyDestinationDMABUF in $LIB" >&2
  exit 1
fi

disasm=$(objdump -d --no-show-raw-insn \
  --start-address=0x$addr --stop-address=$((0x$addr + 0x80)) "$LIB" 2>/dev/null)

if grep -q '0xffffffffffffff' <<<"$disasm"; then
  echo "PATCHED: $LIB compares against DRM_FORMAT_MOD_INVALID"
else
  echo "BUGGY:   $LIB compares against DRM_FORMAT_INVALID (0) — external display on the dGPU will be black"
  rc=1
fi

if [[ ${1:-} == --session ]]; then
  pid=$(pgrep -x Hyprland | head -1)
  if [[ -z $pid ]]; then
    echo "session: Hyprland not running"
  elif ls -l "/proc/$pid/map_files/" 2>/dev/null | grep -q 'libaquamarine.so.0.15.1 (deleted)'; then
    echo "session: Hyprland (pid $pid) still maps the OLD .so — restart the session"
    rc=1
  else
    echo "session: Hyprland (pid $pid) maps the installed .so"
  fi
fi

exit $rc
