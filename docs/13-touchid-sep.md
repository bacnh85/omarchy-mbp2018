# 13 — Touch ID: hardware works, but there is no fingerprint to verify

Wanted: Touch ID for `sudo`, polkit dialogs and the lock screen.

**Verdict, proven on this machine: blocked — not by a driver gap, but because the
SEP holds no fingerprint this install can bind to, and Linux has no way to create
one.** The sensor itself is reachable and the bridge talks to it successfully; the
identity inventory comes back empty. Enrolling a finger requires booting macOS once.

| Question | Answer, measured here |
|---|---|
| Is the sensor there and reachable? | **Yes** — T2 USB bridge `05ac:8233`, BiometricKit session opens over IPv6 |
| Does the daemon run unmodified on this kernel? | **Yes** — `arch-mact2/t2-touchid 0.1.0.r949.g8c7f725-1` starts and reaches the SEP |
| Is there a fingerprint to match against? | **No** — SEP inventory empty/locked ("log into macOS once") |
| Can Linux enroll a finger? | **No** — the SEP only verifies templates enrolled under macOS |
| Does Omarchy support it if the above were solved? | **Yes** — lock screen and polkit already read `pam_fprintd` |
| Does this box have macOS? | **No** — single boot, whole disk is LUKS (see Machine facts) |

The last row is the one that stops everything, so it is worth being blunt about it:
this is not a configuration that can be unblocked from Linux. `macintog/t2touch`
refuses to install at all when it finds APFS storage, and `jmurth1234/t2-touchid-linux`
requires an *exported macOS keybag*. When macOS has been erased, the templates in the
SEP belong to a volume that no longer exists, and a fresh Linux install cannot adopt
them from sensor state alone.

---

## 1. What was tried, and what the SEP said

The `t2-touchid` package ships into `arch-mact2`, so it is installed from a repo that is
already configured here. Its binary was extracted and run directly — nothing installed,
nothing enabled — against `/run/t2-touchid/fprint.sock`:

```
$ sudo install -d -m 0700 /run/t2-touchid
$ sudo /tmp/t2tid/usr/bin/t2-touchid --socket /run/t2-touchid/fprint.sock \
    --uid auto --flags 0 --bind-user none
t2-touchid: watching /run/t2-touchid/fprint.sock for uid auto with flags 0x0
t2-touchid: cannot reach the sensor: BiometricKit was not advertised:
            connect [fe80::aede:48ff:fe33:4455%enp2s0f1u1]:59602:
            Cannot assign requested address (os error 99)
t2-touchid: BiometricKit session open
t2-touchid: no macOS user on this Mac has a finger enrolled, or the SEP is still
            locked because no password has unlocked it since the T2 last powered on;
            log into macOS once to fix that
```

That output has two halves, and both matter:

- `BiometricKit session open` — the transport works. The first `cannot reach` line is a
  race on the port broadcast, not a failure; the session opens immediately after it.
- The inventory line is the SEP's own answer. Those are the only two states that produce
  it — *no finger enrolled for any macOS uid* or *keybag still locked since the T2 last
  powered on* — and both are fixed by the same action: log into macOS once.

Answered twice, on two different transports, so this is not an artefact of how the link
was brought up:

| Run | Link-local address | Result |
|---|---|---|
| hand-added | `fe80::1/64` | inventory empty |
| kernel-generated (`addr_gen_mode=0`) | `fe80::aede:48ff:fe00:1122/64 proto kernel_ll` | identical |

Peer discovery confirms the far end is the T2 itself, not an assumed address:

```
$ ip -6 neigh show dev enp2s0f1u1
fe80::aede:48ff:fe33:4455 lladdr ac:de:48:33:44:55 DELAY
```

## 2. The transport trap: the link has no kernel-generated IPv6 address

This is a separate, real bug that would block Touch ID *even with* a valid macOS keybag.
`t2-touchid` dials the T2 over IPv6 link-local on the CDC-NCM link, and on a stock
NetworkManager install that link has no kernel-generated link-local address:

```
$ cat /proc/sys/net/ipv6/conf/all/addr_gen_mode       # 0
$ cat /proc/sys/net/ipv6/conf/enp2s0f1u1/addr_gen_mode # 1  <-- IN6_ADDR_GEN_MODE_NONE
```

`1` means *do not generate a link-local address on this interface*. Nothing in
`/etc/sysctl.d/`, `/etc/sysctl.conf` or any udev rule sets it (grepped), and the global
default is `0` — it follows the interface's managed state. Proven by flipping it in
memory only:

| `addr_gen_mode` | kernel generates a link-local? |
|---|---|
| `1` | **no.** NetworkManager may still add one, flagged `noprefixroute` |
| `0` | yes, immediately: `inet6 fe80::aede:48ff:fe00:1122/64 scope link proto kernel_ll` |

Point worth not over-reading: with `addr_gen_mode=1` the kernel never makes one, so any
address present is NetworkManager's manual `noprefixroute` one. The bridge **does accept
that** — proven in the "Fixed on this machine" section below, where the SEP answered with
NM's address alone. So `addr_gen_mode=1` is not itself a blocker; what blocks is having
*no* address, which is what a failed activation leaves behind.

The cause is NetworkManager's auto-generated profile, which loses its IPv6 config after
failing DHCP4:

```
device (enp2s0f1u1): Activation: starting connection 'Wired connection 2'
dhcp4 (enp2s0f1u1): activation: beginning transaction (timeout in 45 seconds)
device (enp2s0f1u1): state change: ip-config -> failed (reason 'ip-config-unavailable')
device (enp2s0f1u1): Activation: failed for connection 'Wired connection 2'
```

The T2's bridgeOS never answers DHCP, so the profile (auto-generated, `ipv6.method auto`,
`autoconnect yes`) times out and leaves the device `disconnected` with no link-local
address — and it does that **forever**: `214` activation cycles in a single boot, one
every 45 s, each ending `ip-config-unavailable`. That profile needs
`ipv6.method=link-local`, which is exactly what the package's own
`t2-touchid.nmconnection` says — but **on Arch that file goes to a path NetworkManager
never reads**:

```bash
$ strings -a /usr/bin/NetworkManager | grep system-connections
/etc/NetworkManager/system-connections
```

Only `/etc/NetworkManager/system-connections` is loaded, so `nmcli connection show`
will not list a profile you merely dropped into `/usr/lib/` — that directory holds the
file but NM never parses it (and the `/etc` one is not readable as a normal user:
`ls` → `Permission denied`). The package's drop-in `t2-touchid-network-setup.service`
expects the profile to be present and fails on
`NetworkManager profile ... was not loaded` otherwise.

### Fixed on this machine (2026-11-17)

The two settings from that unread file were applied to the profile NM actually uses:

```bash
sudo nmcli connection modify 'Wired connection 2' ipv4.method disabled ipv6.method link-local
sudo nmcli connection up 'Wired connection 2' ifname enp2s0f1u1
```

NM persists that as a keyfile at
`/etc/NetworkManager/system-connections/Wired connection 2.nmconnection` (`root:root`,
`0600`, written 22:07), so it survives reboots and does not depend on the package.

| | before | after |
|---|---|---|
| device state | `connecting` → `failed` every 45 s (`214` cycles/boot) | `connected`, held |
| activation cycles over 100 s (>2 DHCP timeouts) | climbing | `216 → 216` |
| SEP reaches the sensor | only with a hand-added address | **yes**, on NM's address alone |

That last row settles a question §2 previously left open: NM sets `addr_gen_mode=1`
regardless of the profile, so the address NM provides here is a manual
`noprefixroute` one — and the bridge accepts it. `BiometricKit session open` was
obtained with no hand-added address on the interface.

## 3. What is already in place, for when a finger exists

Nothing here needs inventing — it is all shipped and wired, and worth stating so the
next attempt does not re-derive it:

| Piece | State on this box |
|---|---|
| T2 USB bridge | `05ac:8233` on usb7, both interfaces bound to `cdc_ncm` → `enp2s0f1u1` |
| `t2-touchid` | available from `arch-mact2`; binary verified working here |
| libfprint driver the bridge needs | `extra/libfprint 1.94.100-1` **has** `virtual_device_storage` |
| …and the one Omarchy's setup would install | `omarchy/libfprint-git` **also has it** — but see the gotcha below |
| Omarchy lock screen | already fingerprint-aware: probes `fprintd-list`, has retry/backoff/resume logic |
| Omarchy polkit agent | reads `pam_fprintd.so` from `/etc/pam.d/polkit-1` to decide whether to offer it |
| Omarchy setup script | `omarchy-setup-security-fingerprint` does the PAM edits, `omarchy-apply-lock` the lock screen |

Note which libfprint: `omarchy-setup-security-fingerprint` installs `libfprint-git`, and
it **conflicts with stock `libfprint`** — it answers that prompt with `--ask 4`. Both
builds carry the virtual device driver, so Touch ID is not a reason to prefer either;
follow whatever the setup script picks.

## 4. What to do when the machine next boots macOS

Only the first step needs macOS. Everything after it is Linux.

1. **In macOS:** log in once (unlocks the SEP keybag), enrol at least one finger, then
   boot back to Linux. Do not erase the macOS volume afterwards — the templates live in
   the SEP but are bound to that volume's keybag.
2. **Fix the transport** — put the profile where NM reads it:
   ```bash
   sudo install -Dm600 /usr/lib/NetworkManager/system-connections/t2-touchid.nmconnection \
     /etc/NetworkManager/system-connections/t2-touchid.nmconnection
   sudo systemctl restart NetworkManager
   ```
   (after the package is installed; `ipv6.method=link-local` on the auto profile is the
   equivalent one-liner.)
3. **Install and enable:**
   ```bash
   sudo pacman -S --needed --noconfirm --ask 4 -- t2-touchid fprintd
   sudo sed -i 's/^T2_TOUCHID_BIND_USER=.*/T2_TOUCHID_BIND_USER=bacnh/' \
     /etc/kait2en/t2-touchid.conf
   sudo systemctl enable --now kait2en-t2-touchid.service
   ```
4. **Prove the binding before touching PAM:**
   ```bash
   fprintd-list "$USER"      # expect " - #1: <finger>"
   fprintd-verify "$USER"    # expect "verify-match"
   ```
5. **Only then** run `omarchy-setup-security-fingerprint` (or make the same PAM edits)
   for `sudo`, `polkit-1` and `/etc/pam.d/omarchy-lock-fingerprint`.

**Keep password authentication at every one of these steps.** A fingerprint that stops
verifying after a forced shutdown must never be the only way in.

## 5. Standing limitations even when it works

From the `t2-touchid` package README, worth recording once so nobody debugs them later:

- **Only macOS-enrolled fingers verify.** Delete a finger in macOS and it stops working
  in Linux. The daemon never enrols — it *binds* a SEP identity to a Linux account.
- **A real T2 power loss re-locks the keybag.** Reboots and shutdowns of the x86 side
  only sleep bridgeOS, so a normal reboot is fine — but a forced shutdown or power loss
  means one macOS login before Touch ID works again.
- **It falls back to the password, by design.** `fprintd` is wired to the bridge, so a
  stopped bridge means no reader and PAM falls straight through to the password.
  That is the correct failure mode and the reason it is safe to enable.

## Verify

Everything below works without macOS. The first block prints the blocked verdict; the
second proves the transport fix; the third proves nothing was installed or left behind.

```bash
# 1. Is there an identity to verify against? Needs the package (nothing is installed on
#    this box, so this block only applies once step 3 of §4 has been run).
sudo install -d -m 0700 /run/t2-touchid
sudo timeout 20 /usr/bin/t2-touchid --socket /run/t2-touchid/fprint.sock \
  --uid auto --flags 0 --bind-user none 2>&1 | grep -E 'session open|no macOS user'
sudo rm -rf /run/t2-touchid
# expect: "BiometricKit session open" then "no macOS user on this Mac has a finger enrolled"

# ...or without installing anything, straight from the repo package:
cd /tmp && curl -sLO https://github.com/NoaHimesaka1873/arch-mact2-mirror/releases/download/release/t2-touchid-0.1.0.r949.g8c7f725-1-x86_64.pkg.tar.zst
mkdir -p t2tid && tar --zstd -xf t2-touchid-*.pkg.tar.zst -C t2tid
sudo install -d -m 0700 /run/t2-touchid
sudo timeout 20 /tmp/t2tid/usr/bin/t2-touchid --socket /run/t2-touchid/fprint.sock \
  --uid auto --flags 0 --bind-user none 2>&1 | grep -E 'session open|no macOS user'
sudo rm -rf /run/t2-touchid

# 2. The transport, after the fix above
nmcli device status | grep enp2s0f1u1                 # connected (held, no flap)
nmcli -f ipv4.method,ipv6.method connection show 'Wired connection 2'
                                                      # disabled / link-local
ip -6 addr show dev enp2s0f1u1 | grep fe80            # noprefixroute is enough
strings -a /usr/bin/NetworkManager | grep system-connections   # /etc/..., never /usr/lib

# 3. Nothing was installed, and no socket dir was left behind
ls -d /run/t2-touchid 2>&1 | tail -1                  # No such file or directory
pacman -Q t2-touchid fprintd 2>&1 | tail -2           # both: not found
```

## Gotchas

- **`BiometricKit was not advertised: ... Cannot assign requested address`** is a
  transient race on the port broadcast, printed on the first attempt. If
  `BiometricKit session open` follows it, ignore it; if it repeats instead, the
  link-local address is missing (§2).
- **`addr_gen_mode` is not a sysctl you will find in a file.** It is applied per
  interface by NetworkManager and resets with the device's managed state, so grepping
  `/etc` for it proves nothing. Read the live value.
- **`nmcli connection show` will not list a profile dropped into
  `/usr/lib/NetworkManager/system-connections`** — NM does not read that directory (the
  daemon's only such path string is the `/etc` one), and `/etc/NetworkManager/system-connections`
  is not readable as a normal user (`ls` → `Permission denied`). Use `strings` on the
  daemon rather than assuming a search path.
- **Do not enable the PAM lines first.** `pam_fprintd` with no enrolled finger makes
  every `sudo` wait out the reader's timeout before falling back. Bind, `fprintd-verify`,
  then edit PAM.
- **`omarchy update` will reset `omarchy-lock-password`** but not
  `omarchy-lock-fingerprint`; re-run `omarchy-apply-lock` after an update if the lock
  screen loses its fingerprint indicator. The existing post-update hook
  ([`../scripts/omarchy-hook-hooks/verify-mbp-fixes.sh`](../scripts/omarchy-hook-hooks/verify-mbp-fixes.sh))
  does not check this yet — add it there if Touch ID is ever enabled.
