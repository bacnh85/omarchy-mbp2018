# 02 — Wi-Fi and Bluetooth

**Symptom.** No Wi-Fi at all (`wlp3s0` absent, only ethernet). Bluetooth looks dead
in logs.

**Fix script:** [`../scripts/fix-wifi-firmware.sh`](../scripts/fix-wifi-firmware.sh) — no reboot needed.

## The two are unrelated

Wi-Fi was genuinely broken. **Bluetooth was mostly fine** — do not "fix" it.

### Bluetooth: works, with one cosmetic log line

```
Bluetooth: hci0: BCM: firmware Patch file not found, tried:
Bluetooth: hci0: BCM: 'brcm/BCM.hcd'
```

That is a missing **RAM patch file**. The controller comes up regardless and
performs fine:

```bash
bluetoothctl show                       # Powered: yes
bluetoothctl --timeout 5 scan le        # ~20 devices found
```

On MacBookPro15,1 Bluetooth firmware on the UART path (ACPI `BCM2E7C`, driver
`hci_uart_bcm` on `serial0`) is not needed — the wiki only requires Bluetooth
firmware for MacBookPro15,4, 16,3 and MacBookAir9,1. The `BCM.hcd` lookup failing
is expected. Ignore it unless devices actually fail to pair/stream.

Also present and unused: `hci_bcm4377` is loaded from `/etc/modules-load.d/t2.conf`
but this model's Bluetooth is the UART one; only `hci0` exists. Harmless.

### Wi-Fi: firmware genuinely absent

```
brcmfmac: brcmf_fw_alloc_request: using brcm/brcmfmac4364b2-pcie for chip BCM4364/3
brcmfmac: Direct firmware load for brcm/brcmfmac4364b2-pcie.bin failed with error -2
brcmfmac: brcmf_pcie_setup: Dongle setup failed
ieee80211 phy0: brcmf_fw_crashed: Firmware has halted or crashed
```

`brcmfmac` is the correct driver (never install `broadcom-wl` for T2 Macs). It just
had no firmware. Those files are **not in any Arch package** — verified 0 matches
for `4364` in `linux-firmware-broadcom`. They only exist inside a macOS install.

## Root cause

Omarchy *does* install `apple-bcm-firmware-fetcher`, but that package implements
only **Method 4**: read firmware from an on-disk **APFS macOS volume**. This machine
is single-boot:

```
nvme0n1p1  2G    vfat    (ESP /boot)
nvme0n1p2  463G  LUKS -> btrfs   (no APFS partition anywhere)
```

`lsblk` shows no `apfs` fstype, so the fetcher had nothing to read and the
post-install hook left Wi-Fi without firmware, silently.

That leaves **Method 5**: download Apple's macOS recovery image and harvest the
firmware from it. 835 MiB `BaseSystem.dmg`, verified to be Sequoia recovery.

## Fix

```bash
./scripts/fix-wifi-firmware.sh
```

What it does (and what was done by hand originally):

1. **Rename/repack.** Taken from [wiki.t2linux.org/tools/firmware.sh](https://wiki.t2linux.org/tools/firmware.sh) —
   `rename_fw.py` in this repo is the renamer lifted verbatim. It maps macOS's
   `wifi/C-4364__s-B2/…` layout into the kernel's expected names
   `brcmfmac4364b2-pcie.apple,<board>[-<vendor>].<ext>`.
2. **Install** the 123 files into `/lib/firmware/brcm/`.
3. **Reload** `brcmfmac` (`modprobe -r brcmfmac_wcc; modprobe -r brcmfmac; modprobe brcmfmac`).
4. **Cache** the tarball at `~/.local/share/mbp-t2-firmware/firmware-renamed.tar`
   (+ `.sha256`) so a reinstall takes seconds, not 850 MB of download.

The tarball on this machine:

```
69dcced954b3058eef905b15a696c8590ebacadb4822782c24d3882dbc1d8088  firmware-renamed.tar
```

### Getting `dmg2img` (AUR, needed only for the download path)

`dmg2img` is AUR-only; `yay -S dmg2img` works, or build it directly (what was done
here, since `makepkg -si` cannot prompt for sudo inside an agent session):

```bash
git clone https://aur.archlinux.org/dmg2img.git && cd dmg2img
makepkg -s --noconfirm                        # build only
pkexec pacman -U --noconfirm dmg2img-*.pkg.tar.zst </dev/null
```

## Verify

```bash
dmesg | grep brcmfmac | tail -5
# brcmfmac: brcmf_c_process_txcap_blob: TxCap blob found, loading
# brcmfmac: brcmf_c_preinit_dcmds: Firmware: BCM4364/3 wl0: ... version 9.30.514.0.32.5.94
# brcmfmac 0000:03:00.0 wlp3s0: renamed from wlan0

ip -br link | grep wlp         # wlp3s0 exists
nmcli -t -f SSID,SIGNAL dev wifi list | head
```

Observed: `wlp3s0` up, `TxCap blob found`, firmware `9.30.514.0.32.5.94`, and a
scan returning the local APs.

## Gotchas

- **`feature_disable=0x82000` is already set** in `/etc/modprobe.d/brcmfmac.conf`
  to work around the wpa_supplicant ≥2.11 four-way-handshake regression (symptom:
  correct password rejected). Keep it. Alternative backend if it ever misbehaves:
  install `iwd` and set NetworkManager's `wifi.backend=iwd`.
- **The download's chunklist verification fails** with
  `[Errno 25] Inappropriate ioctl for device`. That is a `fetch-macOS-v2.py` quirk
  when the target is a plain file; the image is fine if the size matches
  (843.4 MiB). `dmg2img` validates the container anyway.
- **loop-mount, don't extract blindly.** The recovery image is GPT with one HFS+
  partition; `losetup -P` + mount `p1` is required (`hfsplus` is already in the
  kernel).
- Firmware installed this way is **unowned by pacman**. A `linux-firmware` upgrade
  will not remove it, but a full reinstall will — hence the cached tarball.
- Do not add these files to `/etc/`, and do not symlink from the ESP: they belong
  in `/lib/firmware/brcm` on the root filesystem.
