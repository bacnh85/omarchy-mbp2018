#!/bin/bash
# Fix: no Wi-Fi on MacBookPro15,1 (BCM4364, 14e4:4464).
#
# ROOT CAUSE
#   brcmfmac needs brcm/brcmfmac4364b2-pcie.{bin,clm_blob,txt,txcap_blob}, which
#   are NOT shipped in any Arch linux-firmware split package (verified: 0 matches
#   in linux-firmware-broadcom). They exist only inside a macOS installation, so
#   the T2 wiki's firmware.sh must harvest and rename them from macOS.
#
#   Omarchy installs `apple-bcm-firmware-fetcher`, but that package only implements
#   "Method 4": read the firmware off an on-disk APFS macOS volume. This machine is
#   single-boot (nvme0n1p2 is LUKS, there is no APFS partition), so the fetcher
#   cannot work here and the post-install hook silently left Wi-Fi without firmware.
#   Method 5 (download Apple's recovery image) is the only option.
#
# FIX
#   Reuse a saved tarball when present, otherwise re-run Method 5:
#   fetch-macOS-v2.py -> dmg2img -> mount HFS+ -> rename -> tar -> install.
#
# NOTE Bluetooth is NOT broken on this model. It loads without a RAM patch
# (hci0 reports "BCM: firmware Patch file not found" but scans fine) — see
# docs/02-wifi-bluetooth.md. Don't chase that log line.

set -euo pipefail

CACHE="${MBP_T2_FW_CACHE:-$HOME/.local/share/mbp-t2-firmware}"
TARBALL="$CACHE/firmware-renamed.tar"
BRCM=/lib/firmware/brcm
WORK=$(mktemp -d "$HOME/t2-fw.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

as_root() {
  if ((EUID == 0)); then "$@"; else pkexec "$@" </dev/null; fi
}

install_tarball() {
  local tar_file=$1
  echo "==> Installing firmware into $BRCM"
  as_root tar -xC "$BRCM" -f "$tar_file"
  echo "==> Reloading brcmfmac"
  as_root modprobe -r brcmfmac_wcc 2>/dev/null || true
  as_root modprobe -r brcmfmac 2>/dev/null || true
  as_root modprobe brcmfmac
  sleep 4
}

verify() {
  echo "==> Verifying"
  if ip -br link | grep -qE '^wlp'; then
    local iface
    iface=$(ip -br link | awk '/^wlp/{print $1; exit}')
    echo "    OK: $iface exists"
    nmcli -t -f SSID,SIGNAL device wifi list 2>/dev/null | head -5 | sed 's/^/    /'
  else
    echo "    FAIL: no wlp* interface. Check: sudo dmesg | grep brcmfmac" >&2
    exit 1
  fi
}

if [[ -f $TARBALL ]]; then
  echo "==> Using saved firmware tarball: $TARBALL"
  if [[ -f $TARBALL.sha256 ]]; then
    ( cd "$(dirname "$TARBALL")" && sha256sum -c "$(basename "$TARBALL").sha256" ) \
      || { echo "    checksum mismatch — falling through to re-download" >&2; TARBALL=""; }
  fi
fi

if [[ ! -f $TARBALL ]]; then
  echo "==> No saved tarball; harvesting from Apple's recovery image (Method 5, ~850 MB)"
  command -v dmg2img >/dev/null || {
    echo "dmg2img is required. Build it from AUR:" >&2
    echo "  yay -S dmg2img    # or: git clone https://aur.archlinux.org/dmg2img.git && cd dmg2img && makepkg -si" >&2
    exit 1
  }
  cd "$WORK"
  curl -sfLO https://raw.githubusercontent.com/kholia/OSX-KVM/master/fetch-macOS-v2.py
  # Board ID for MacBookPro15,1. Any Monterey..Sonoma product works.
  python3 fetch-macOS-v2.py --action download -b Mac-937A206F2EE63C01 -o "$WORK/rec"
  # The chunklist verifier fails with "Inappropriate ioctl for device" on a plain
  # file; the size check is what matters and dmg2img validates the container.
  dmg2img -s "$WORK/rec/BaseSystem.dmg" "$WORK/fw.img"

  LOOP=$(as_root losetup -f --show -P "$WORK/fw.img")
  as_root mkdir -p "$WORK/mnt"
  as_root mount -o ro "${LOOP}p1" "$WORK/mnt"
  # rename_fw.py is the renamer lifted verbatim from wiki.t2linux.org's firmware.sh
  # (VENDORMAP/board-type logic identical); it maps macOS layout to kernel names.
  cp "$(dirname "$(readlink -f "$0")")/rename_fw.py" "$WORK/"
  python3 "$WORK/rename_fw.py" "$WORK/mnt/usr/share/firmware" "$WORK/firmware-renamed.tar"
  as_root umount "$WORK/mnt"
  as_root losetup -d "$LOOP"

  mkdir -p "$CACHE"
  cp "$WORK/firmware-renamed.tar" "$TARBALL"
  ( cd "$CACHE" && sha256sum "$(basename "$TARBALL")" > "$(basename "$TARBALL").sha256" )
  echo "==> Saved firmware to $TARBALL for future reinstalls"
fi

install_tarball "$TARBALL"
verify
echo
echo "Done. Wi-Fi should now be usable via nmcli / the Omarchy bar."
