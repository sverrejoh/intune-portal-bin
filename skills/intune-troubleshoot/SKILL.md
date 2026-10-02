---
name: intune-troubleshoot
description: |
  Diagnose and fix Microsoft Intune enrollment, authentication and
  compliance problems on Arch Linux / Omarchy using the intune-portal-bin
  fork (OpenSSL shim, wrappers, intune-doctor, intune-arch-setup).
  Triggers: "intune not working", "intune auth", "intune enrollment",
  "something went wrong 4kv4v", "upgrade to a supported linux distro",
  "intune compliance", "identity broker", "oneauth error", "update intune
  package", "new intune version".
---

# Intune on Arch Linux

Repo: `~/Projects/Microsoft/intune-portal-bin` (fork of AUR
`intune-portal-bin`; README.md there is the full guide). Read the README
section "The subtleties" before guessing. The failure is almost always one
of eight known things, and the doctor finds it.

## Step 1: run the doctor, believe it

```bash
intune-doctor            # or: ~/Projects/Microsoft/intune-portal-bin/intune-doctor.sh
```

Every FAIL maps to a README subtlety. Fix FAILs top to bottom, re-run.
Do not start with Wayland, GTK, rendering or network theories; those have
never been the cause here (2026-02-28 lesson).

Common FAIL -> fix:

| Doctor says | Do |
|---|---|
| binaries are plain ELF / shim missing | plain AUR package got installed over the fork. `cd repo && makepkg -si` |
| /etc/os-release regular file or not ubuntu | `intune-arch-setup` (re-links, installs hook). Omarchy upgrade did it. |
| no `login` collection / default not login | `intune-arch-setup` keyring step; if `login.keyring.bak` exists restore it, `echo login > ~/.local/share/keyrings/default`, restart gnome-keyring-daemon |
| not in group tss | `sudo usermod -aG tss $USER`, re-login |
| tpm2-tss not 3.2.0-1 | setup script downgrades from archive + pins (needs AUR openssl-1.1) |
| timer / socket not enabled | setup script services step |
| more than one user broker | `pkill -9 -f identity-broker/bin/microsoft-identity-broker` then retry |
| Azure VPN interface | `ip route get 20.37.152.128`; if via MSFT-AzVPN with loss: `sudo ip link delete <iface>` |

## Step 2: read the logs with the error tag

The portal box says "Something went wrong [tag]". Start the portal from a
terminal (`intune-portal`) to get its log, and:

```bash
journalctl --since '10 min ago' --no-pager | grep -iE 'intune|broker|msal|oneauth|keyring|openssl_shim'
journalctl -u microsoft-identity-device-broker -n 100 --no-pager
journalctl --user -u intune-agent -n 100 --no-pager
dsreg --status
```

| Tag | Meaning | Fix |
|---|---|---|
| 4kv4v | Missing PRT after bootstrap; libsecret error 19 on collection/login | login keyring collection + GNOME_KEYRING_CONTROL in wrappers |
| 4u3gb | storage_keyring_write_failure | default keyring must be `login` |
| 581h6 | key_not_returned from device broker | TPM access (tss group, tpm2-tss pin), then full reset |
| 4rfhk | operation invalid / interactive request already in progress | kill -9 the stale user broker (dbus-activated, no unit) |
| 4y8ve | JSON parse BEGIN_OBJECT | broker too old; upgrade microsoft-identity-broker-bin |

Compliance "NonCompliant, expected ubuntu actual omarchy":
`/etc/os-release` was replaced by omarchy-settings. Re-link, then
`systemctl --user start intune-agent.service` and check
`journalctl --user -u intune-agent -o cat | grep -o 'alloweddistros_item_$type[^}]*' | tail -2`.

## Step 3: full reset only if state is corrupt

README "Full reset". It un-enrolls. Stop units, kill -9 intune and
microsoft-identity processes, remove `~/.config/intune`,
`~/.local/state/intune`, `~/.local/state/microsoft-identity-broker`,
`/var/lib/microsoft-identity-device-broker`, `/var/lib/intune`; start the
device broker and daemon socket; `intune-arch-setup`; `intune-portal`.

## Updating the package

```bash
cd ~/Projects/Microsoft/intune-portal-bin
intune-doctor | grep upstream          # newest deb version
sed -i "s/^pkgver=.*/pkgver=NEW/; s/^pkgrel=.*/pkgrel=1/" PKGBUILD
updpkgsums && makepkg --printsrcinfo > .SRCINFO
makepkg -si && intune-doctor
```

Check the shim is still needed on the new binary (doctor prints it; the
test is `objdump -d intune-portal.original | grep -B3 X509_REQ_set_version`
showing `push $0x2`). Compare the deb `control` Depends for a new broker
minimum. Upstream pool:
https://packages.microsoft.com/ubuntu/24.04/prod/pool/main/i/intune-portal/

## Facts that save time

- The shim only matters at enrollment and certificate renewal. A machine
  running the plain AUR package stays enrolled until then, so "it works
  without the shim" proves nothing.
- `tpm2-tss` reaches every Intune process through `libsecret`; the pinned
  3.2.0-1 needs AUR `openssl-1.1`.
- The user broker is D-Bus activated (`com.microsoft.identity.broker1`),
  so `systemctl restart` does nothing to it; kill the process.
- `pacman -Qkk filesystem` warning about `/usr/lib/os-release` is the
  spoof, not corruption.
- Browser SSO failures with YubiKey prompts are a browser-bridge problem
  (Chromium + linux-entra-sso), not Intune. Use Edge/Firefox.
- Never debug by downgrading the broker to 2.0.1 (Java); current
  endpoints reject it.
