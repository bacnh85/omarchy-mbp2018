#!/bin/bash
# Fix: external monitor on the AMD dGPU (e.g. USB-C/DisplayPort) is detected but
#      shows no picture, forever logging "Backend requires blit, but blit failed".
#
# ROOT CAUSE (upstream aquamarine bug, fixed in 0.16.0 — Ubuntu/Arch still ship 0.15.1)
#   src/backend/drm/Renderer.cpp, CDRMRenderer::verifyDestinationDMABUF():
#
#       if (fmt.modifier != DRM_FORMAT_INVALID && fmt.external) {   // WRONG constant
#           -> "FAIL, format is external-only"; return false;
#
#   DRM_FORMAT_INVALID is 0.  It should be DRM_FORMAT_MOD_INVALID (0x00ffffffffffffff).
#   initDRMFormats() always appends "(DRM_FORMAT_MOD_INVALID, external = true)" for every
#   format ("EGL can always do implicit modifiers"), so a destination buffer with an
#   IMPLICIT modifier matches that entry, passes "!= 0", and is rejected as external-only.
#   The check ends up doing the exact opposite of hyprwm/aquamarine#143.
#
#   Only GPUs that cannot advertise KMS modifiers are hit: amdgpu sets
#   supportsAddFb2Modifiers only on GFX9+, so a Polaris (RX 460/560/555X/560X — the
#   MacBookPro15,1 dGPU) scanout swapchain is allocated modifier-less, gets
#   modifier = INVALID, and EVERY cross-GPU blit to it is refused.
#
#   The iGPU renders (Hyprland's renderer is /dev/dri/card1 = Intel) and the dGPU scans
#   out, so every frame needs that Intel->AMD blit. It fails -> atomic commit fails ->
#   Hyprland retries forever ("Modesetting DP-4" thousands of times) -> monitor stays
#   black while hyprctl happily lists it with a workspace and a mode.
#
# THE FIX
#   One-character-class change in that comparison. This script builds aquamarine 0.15.1
#   (same SOVERSION 14 as the installed one, so Hyprland 0.56.2 needs no relink) with the
#   patch applied, and installs it over /usr/lib/libaquamarine.so.0.15.1.
#
#   Building 0.16.0 instead would bump SOVERSION to 15 and break Hyprland — do not.
#
# VERIFY (must show enabled/On and zero "external-only" in the new log)
#   cat /sys/class/drm/card0-DP-4/enabled /sys/class/drm/card0-DP-4/dpms
#   grep -c 'external-only' $(ls -t /run/user/$(id -u)/hypr/*/hyprland.log | head -1)
#
# NOTE: a package upgrade of aquamarine reinstalls the buggy .so. Re-run this script
# afterwards (idempotent), or run scripts/verify-aquamarine-patch.sh to detect it.

set -euo pipefail

PKGVER=0.15.1
SRCDIR=${SRCDIR:-$HOME/.local/src}
BUILDDIR=$SRCDIR/aquamarine-$PKGVER
LOCALPREFIX=$SRCDIR/local
HERE=$(cd "$(dirname "$0")" && pwd)

# omarchy update runs its hooks under the update's own sudo authorization, where
# pkexec would prompt all over again (and polkit with no TTY just hangs). Prefer
# a sudo that already works, then pkexec for an interactive shell.
as_root() {
  if ((EUID == 0)); then "$@"
  elif sudo -n true 2>/dev/null; then sudo -n "$@"
  else pkexec "$@" </dev/null
  fi
}

echo "==> Locating cmake (not installed system-wide on this box)"
if command -v cmake >/dev/null; then
  CMAKE=$(command -v cmake)
else
  CMAKE=$LOCALPREFIX/../cmake/bin/cmake
  if [[ ! -x $CMAKE ]]; then
    echo "    downloading a relocatable cmake"
    mkdir -p "$SRCDIR"
    ( cd "$SRCDIR" && curl -sL -o cmake.tar.gz \
        https://github.com/Kitware/CMake/releases/download/v3.31.6/cmake-3.31.6-linux-x86_64.tar.gz \
        && tar xzf cmake.tar.gz )
    CMAKE=$SRCDIR/cmake-3.31.6-linux-x86_64/bin/cmake
  fi
fi
echo "    $CMAKE"

echo "==> Building hyprwayland-scanner into $LOCALPREFIX (aquamarine build-dep)"
if [[ ! -x $LOCALPREFIX/bin/hyprwayland-scanner ]]; then
  rm -rf "$SRCDIR/hyprwayland-scanner"
  git clone -q --depth 1 https://github.com/hyprwm/hyprwayland-scanner.git "$SRCDIR/hyprwayland-scanner"
  "$CMAKE" -S "$SRCDIR/hyprwayland-scanner" -B "$SRCDIR/hyprwayland-scanner/build" \
    -D CMAKE_INSTALL_PREFIX="$LOCALPREFIX" -D CMAKE_BUILD_TYPE=Release >/dev/null
  "$CMAKE" --build "$SRCDIR/hyprwayland-scanner/build" -j"$(nproc)" >/dev/null
  "$CMAKE" --install "$SRCDIR/hyprwayland-scanner/build" >/dev/null
fi

echo "==> Fetching aquamarine v$PKGVER"
rm -rf "$BUILDDIR"
mkdir -p "$BUILDDIR"
curl -sL "https://github.com/hyprwm/aquamarine/archive/v$PKGVER/aquamarine-$PKGVER.tar.gz" \
  | tar xz -C "$SRCDIR"
cd "$BUILDDIR"

echo "==> Applying the modifier-type patch"
patch -p1 -i "$HERE/../patches/aquamarine/0001-fix-modifier-type-check.patch"
grep -q 'fmt.modifier != DRM_FORMAT_MOD_INVALID && fmt.external' src/backend/drm/Renderer.cpp \
  || { echo "    FAIL: patch did not apply as expected" >&2; exit 1; }

echo "==> Building"
PATH=$LOCALPREFIX/bin:$PATH \
PKG_CONFIG_PATH=$LOCALPREFIX/lib/pkgconfig \
CMAKE_PREFIX_PATH=$LOCALPREFIX \
  "$CMAKE" -S . -B build -D CMAKE_INSTALL_PREFIX=/usr -D CMAKE_BUILD_TYPE=Release >/dev/null
PATH=$LOCALPREFIX/bin:$PATH "$CMAKE" --build build -j"$(nproc)" >/dev/null

echo "==> Checking SOVERSION matches the installed library (no Hyprland relink needed)"
NEW_SO=$(readelf -d build/libaquamarine.so.$PKGVER | sed -n 's/.*SONAME.*\[\(.*\)\]/\1/p')
OLD_SO=$(readelf -d /usr/lib/libaquamarine.so.$PKGVER 2>/dev/null | sed -n 's/.*SONAME.*\[\(.*\)\]/\1/p' || true)
echo "    built: ${NEW_SO:-?}   installed: ${OLD_SO:-?}"
[[ $NEW_SO == "$OLD_SO" ]] || { echo "    FAIL: SOVERSION mismatch, refusing to install" >&2; exit 1; }

echo "==> Installing over /usr/lib/libaquamarine.so.$PKGVER"
# Absolute: pkexec chdirs to /root, so a relative build/ path does not resolve
# there and the install fails with "cannot stat" -- exactly when a package
# upgrade of aquamarine has just restored the buggy .so and this must repair it.
as_root install -m755 "$BUILDDIR/build/libaquamarine.so.$PKGVER" "/usr/lib/libaquamarine.so.$PKGVER"

echo "==> Restarting the graphical session (needed: the old .so is already mapped)"
echo "    After it comes back: cat /sys/class/drm/card0-DP-4/enabled   (want: enabled)"
