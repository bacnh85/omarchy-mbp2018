# 01 — Built-in keyboard dead before login

**Symptom.** At the LUKS passphrase prompt the built-in keyboard and trackpad do
nothing; an external USB keyboard is required. After login the built-in keyboard
works normally.

**Fix script:** [`../scripts/fix-initramfs-keyboard.sh`](../scripts/fix-initramfs-keyboard.sh)
**Requires:** reboot to verify.

## Root cause

The machine boots `linux-t2`. Its initramfs (a unified kernel image at
`/boot/EFI/Linux/omarchy_linux-t2.efi`) contained **no T2 keyboard driver at all**.

On T2 Macs the internal keyboard is *not* a platform device — it is a USB device
(`05ac:0278`) that hangs off a virtual USB host controller created by the
`t2bce_vhci` module. No `t2bce_vhci` in the initramfs ⇒ no `usb7` bus ⇒ no
keyboard at the prompt.

`t2bce_vhci` was being stripped by two drop-ins fighting each other:

`/etc/mkinitcpio.conf.d/apple-t2.conf` (Omarchy installer, for T2 Macs):
```sh
MODULES+=(t2bce_vhci usbhid hid_apple hid_generic xhci_pci xhci_hcd)
```

`/etc/mkinitcpio.conf.d/zz-omarchy-kernel-modules.conf` (also the installer) —
`zz-` sorts last so it wins:
```sh
_omarchy_absent=(t2bce_vhci)
... strips t2bce_vhci from MODULES unconditionally ...
```

The strip exists for a real reason: `linux-omarchy` has **no** `t2bce_vhci`, and
mkinitcpio hard-fails on a module it cannot resolve, which would break that
kernel's build. But the machine runs `linux-t2`, where the module *does* exist
(`/lib/modules/<ver>/kernel/drivers/staging/t2bce/t2bce_vhci/`), so the strip was
wrong for the kernel actually booting.

Why the keyboard still worked after login: `/etc/modules-load.d/t2.conf` loads
`t2bce_vhci` in userspace. That is also the tell — boot-time userspace has it,
initramfs does not.

### How it was confirmed

```bash
lsinitcpio /boot/EFI/Linux/omarchy_linux-t2.efi | grep t2bce   # -> nothing
modinfo -F filename t2bce_vhci                                 # -> exists for 7.3.4
git-blame not needed: the strip is visible in the conf itself
```

`pkexec lsinitcpio -a .../omarchy_linux-t2.efi` listed 377 modules including
`hid-apple`, `usbhid`, `xhci_hcd` — everything *except* the t2bce stack. `usbhid`
was even built-in, so the only missing piece was the VHCI host controller.

## Fix

Strip `t2bce_vhci` only when the kernel being built genuinely lacks it:

```sh
_omarchy_kept=()
for _omarchy_module in "${MODULES[@]}"; do
  if [[ $_omarchy_module == "t2bce_vhci" ]] &&
    [[ $(modinfo -k "${KERNELVERSION:-$(uname -r)}" -F filename t2bce_vhci 2>/dev/null) != /* ]]; then
    continue
  fi
  _omarchy_kept+=("$_omarchy_module")
done
MODULES=("${_omarchy_kept[@]}")
```

`modinfo -k "$KERNELVERSION"` is the key: mkinitcpio sets `KERNELVERSION` per
kernel, so the same file does the right thing for both kernels in one
`limine-mkinitcpio` run. The `?` optional-module prefix is *not* a substitute —
a systemd initramfs copies `MODULES` verbatim into `modules-load.d`, where
`t2bce_vhci?` names a nonexistent module.

Then rebuild:

```bash
pkexec limine-mkinitcpio
```

## Verify (without rebooting)

```bash
pkexec lsinitcpio /boot/EFI/Linux/omarchy_linux-t2.efi | grep 't2bce.*ko.zst'
# expect 3 lines: t2bce_core, t2bce_dma, t2bce_vhci

pkexec lsinitcpio /boot/EFI/Linux/omarchy_linux-omarchy.efi | grep -c t2bce
# expect 0  (linux-omarchy must not carry it)
```

Observed after the fix:
```
t2bce_core/t2bce_core.ko.zst
t2bce_dma/t2bce_dma.ko.zst
t2bce_vhci/t2bce_vhci.ko.zst
```

Final proof is a reboot: the internal keyboard must type the LUKS passphrase.

## Gotchas

- **`MODULES` order matters here.** `t2bce_core`/`t2bce_dma` come in via module
  dependencies; the explicit entry only names `t2bce_vhci`. That is enough.
- **A failed hook leaves a stale UKI** that will still boot. If `limine-mkinitcpio`
  errors, the ESP is *not* updated — do not assume the old image is safe.
- If a future Omarchy update rewrites `zz-omarchy-kernel-modules.conf`, re-run
  `scripts/fix-initramfs-keyboard.sh`. It is idempotent.
- Upstream bug to report: the installer's strip should have been conditional from
  the start, exactly as above.
