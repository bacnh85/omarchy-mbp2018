# Patches

## `zz-omarchy-kernel-modules.conf.patch`

The only **real bug** of the three. Omarchy's installer writes two drop-ins that
contradict each other on a T2 Mac that boots `linux-t2`:

| file | effect |
|---|---|
| `apple-t2.conf` | `MODULES+=(t2bce_vhci usbhid hid_apple hid_generic xhci_pci xhci_hcd)` |
| `zz-omarchy-kernel-modules.conf` (`zz-` sorts **last**, so it wins) | strips `t2bce_vhci` unconditionally |

Result: the `linux-t2` initramfs has no T2 virtual-USB host controller, so the
internal keyboard does not exist at the LUKS prompt. On `linux-omarchy` the strip
is *correct* — that kernel genuinely has no `t2bce_vhci`, and mkinitcpio hard-fails
on an unresolvable module.

The patch makes the strip conditional on the kernel actually lacking the module,
using `modinfo -k "${KERNELVERSION}"` (mkinitcpio sets `KERNELVERSION` per kernel,
so one file works for every kernel in a single `limine-mkinitcpio` run).

Apply with:

```bash
cd / && sudo patch -p0 --dry-run < /path/to/zz-omarchy-kernel-modules.conf.patch
cd / && sudo patch -p0           < /path/to/zz-omarchy-kernel-modules.conf.patch
sudo limine-mkinitcpio
```

Files here:

- `zz-omarchy-kernel-modules.conf.patch` — the unified diff (verified to apply cleanly
  to the original and reproduce `.fixed` byte-for-byte)
- `zz-omarchy-kernel-modules.conf.orig` — the installer's buggy original, recovered from
  `/.snapshots/1/snapshot/etc/mkinitcpio.conf.d/` (snapper), useful as the patch base
- `zz-omarchy-kernel-modules.conf.fixed` — the post-fix file (identical to what is
  installed now, and what `scripts/fix-initramfs-keyboard.sh` writes)

Prefer the script — it also rebuilds the UKI and verifies the module landed inside
the image.

## Upstream status

Reported and **still open** upstream as
[omacom/omarchy#18341](https://github.com/omacom/omarchy/issues/18341) — a MacBookAir8,1
hitting the identical two problems (no Wi-Fi because macOS was wiped, and no keyboard
at the LUKS prompt from this same unconditional strip). That report has no diff; the
patch here is the concrete fix.

The other two issues are not installer bugs and need no patch:

- **Wi-Fi** — `apple-bcm-firmware-fetcher` only implements Method 4 (read from an APFS
  volume). Single-boot machines need Method 5. Arguably the package/installer should say
  so or attempt Method 5; that is a feature request, not a patch to these two files.
- **Trackpad scroll** — pure user preference, set in `~/.config/hypr/input.lua`.

The installer's `zz-omarchy-kernel-modules.conf` is written from a heredoc inside
`omarchy-settings`, which is not present on this machine (the ISO ships only a
prebuilt root image), so an upstream diff against the generator could not be
produced here. The change to port is exactly the `@@ -1,9 +1,15 @@` hunk above.
