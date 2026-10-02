# Microsoft Intune on Arch Linux

A fork of the AUR [`intune-portal-bin`](https://aur.archlinux.org/packages/intune-portal-bin)
package plus everything else it takes to enroll an Arch (or Omarchy)
machine in Microsoft Intune and keep it compliant. The plain AUR package
installs, but enrollment fails on current Arch and compliance silently
flips to "unsupported distro" after some upgrades. This repo fixes both and
documents why.

Tested on Arch/Omarchy with Hyprland, gnome-keyring, a TPM 2.0 and a
Microsoft work tenant. Current state: enrolled and compliant since
2025-10-31, surviving upgrades through Omarchy 4.0.4.

| Component | Version in this repo |
|---|---|
| intune-portal (Microsoft, Ubuntu 24.04 build) | 1.2609.5 |
| microsoft-identity-broker-bin (AUR) | 3.0.2 or newer (3.0.1 minimum) |
| tpm2-tss (pinned) | 3.2.0-1 |

## What the fork changes

- **OpenSSL shim.** `intune-portal` builds the MDM enrollment certificate
  request with `X509_REQ_set_version(req, 2)`. RFC 2986 only defines
  version 1 (value 0); OpenSSL 3.4 started rejecting anything else, so
  enrollment dies with a certificate error on every Arch since late 2024.
  `openssl_shim.c` is a 40-line `LD_PRELOAD` library that rewrites the
  argument to 0. The bug is still in 1.2609.5 (checked by disassembly:
  `push $0x2; pop %rsi; call X509_REQ_set_version`). The device broker
  passes 0 and is unaffected.
- **Wrappers for all three binaries.** `intune-portal`, `intune-agent` and
  `intune-daemon` are installed as `<name>.original` and replaced by
  `intune-wrapper-openssl.sh`, which sets `LD_PRELOAD` and
  `GNOME_KEYRING_CONTROL` and execs the original. The daemon wrapper was
  missing in early versions of this fork and cost a day.
- **`intune-doctor`** checks every requirement below and tells you which
  one broke. Run it first, always.
- **`intune-arch-setup`** applies the system-level requirements
  idempotently (Ubuntu spoof, pacman hook, groups, keyring, services).
- **Dependencies** the AUR package misses (`gcc-libs`, `util-linux-libs`),
  the `/usr/bin/intune-portal` symlink that upstream's postinst creates,
  and the license files.

The package deliberately does **not** rewrite `/etc/os-release` or touch
`pacman.conf` itself; `intune-arch-setup` does, and only when you run it.

## Install

```bash
# 1. The broker (AUR). It provides microsoft-identity-broker and dsreg.
yay -S microsoft-identity-broker-bin

# 2. This package
git clone https://github.com/sverrejoh/intune-portal-bin.git
cd intune-portal-bin
makepkg -si

# 3. System preparation (asks before downgrading tpm2-tss, uses sudo)
intune-arch-setup

# 4. Log out and back in: group membership and the keyring environment
#    only apply to a new session. Then verify and enroll.
intune-doctor
intune-portal
```

If you already have the plain AUR `intune-portal-bin` installed,
`makepkg -si` replaces it in place (same package name). Enrollment state is
kept.

Enrollment itself: sign in with the work account, approve the MFA prompt,
let the portal register the device and generate the MDM certificate (this
is where the shim matters), and wait for the first check-in. The portal
prints its log to the terminal when started from one, which is the easiest
way to see what fails.

## The subtleties

Each of these has broken Intune on Arch at least once. `intune-doctor`
checks all of them.

### 1. The machine must claim to be Ubuntu

Intune's Linux support is Ubuntu 22.04/24.04 and RHEL 8/9. Compliance
policies evaluate `linux_distribution_alloweddistros` from `ID` and
`VERSION_ID` in `/etc/os-release` (falling back to `/usr/lib/os-release`),
and enrollment refuses anything else. `intune-arch-setup`:

- replaces `/usr/lib/os-release` with the Ubuntu 24.04 content from
  `os-release` (original saved as `/usr/lib/os-release.arch.bak`);
- makes `/etc/os-release` a symlink to it;
- installs `/etc/pacman.d/hooks/99-intune-os-release.hook`, a
  PostTransaction hook that re-creates the symlink whenever
  `omarchy-settings` or `filesystem` is installed or upgraded. The
  `omarchy-settings` install scriptlet does `rm -f /etc/os-release` and
  copies its own file on every upgrade; its comment calls this
  "intentionally destructive". It broke compliance three times in August
  2026 before the hook;
- adds `NoUpgrade = usr/lib/os-release` to `pacman.conf` so the
  `filesystem` package leaves a `.pacnew` instead of restoring Arch.

Side effect: anything that reads os-release (fastfetch, some installers,
Omarchy's own update checks) thinks it is on Ubuntu. Nothing we have found
breaks because of it.

### 2. `lsb_release` must not say Arch

`lsb_release -is` returns "Arch" regardless of os-release and the
enrollment flow consults it. The setup script moves
`/usr/bin/lsb_release` to `.bak` and adds `NoExtract = usr/bin/lsb_release`
so a package upgrade does not bring it back.

### 3. The broker needs a `login` keyring collection

`microsoft-identity-broker` (native since 2.0.3; 3.x is Rust) stores the
Primary Refresh Token through libsecret into the collection at
`/org/freedesktop/secrets/collection/login`, hard-coded. A gnome-keyring
with only a `Default` collection gives libsecret error 19 ("No such
interface ... on object at path .../collection/login") and the portal shows
**"Something went wrong [4kv4v]"** right after a successful sign-in.
Omarchy's keyring "unlock on login" change renamed `login.keyring` away,
which is how this was found.

Requirements: `~/.local/share/keyrings/login.keyring` exists, the
`default` file there says `login`, and the collection is unlocked when
Intune runs. The setup script creates the collection (copying an existing
keyring file, or via `CreateCollection` if there is none) and sets the
default. Give the login keyring your login password so PAM
(`pam_gnome_keyring.so auto_start`) unlocks it at login; otherwise unlock
it with Seahorse or `secret-tool` before using Intune.

### 4. `GNOME_KEYRING_CONTROL` must reach dbus-activated processes

The user broker is started by D-Bus activation, not by your shell, so it
does not inherit `GNOME_KEYRING_CONTROL` and cannot find the keyring
socket. The wrappers export it, and the setup script also puts it in
`~/.config/environment.d/90-intune-keyring.conf` and the systemd user
manager environment.

### 5. TPM access

Device registration generates keys in the TPM. Your user must be in group
`tss` (`/dev/tpmrm0` is `crw-rw---- tss tss`) and re-login afterwards.

`tpm2-tss` is pinned to **3.2.0-1** (from the Arch archive) and listed in
`IgnorePkg`. 4.x was reported to break the broker's device-key operations
in 2025; it has not been re-tested since, and the pin has been harmless.
The 3.2.0 build links OpenSSL 1.1, so `openssl-1.1` from the AUR is needed
with it. `libsecret` is what pulls `tpm2-tss` into every Intune process.

### 6. Both brokers, the daemon socket and the agent timer

- `microsoft-identity-device-broker.service` (system, D-Bus activated,
  runs as root, owns `/var/lib/microsoft-identity-device-broker/`).
- `microsoft-identity-broker` (user, D-Bus activated on
  `com.microsoft.identity.broker1`, no systemd unit).
- `intune-daemon.socket` + `.service` (system). Enable the socket.
- `intune-agent.timer` (user, `graphical-session.target`). Runs the agent
  5 minutes after login and hourly; the agent does the compliance check-in.

### 7. Registration file location

The portal writes `~/.config/intune/registration.toml`, the agent reads
`~/.local/state/intune/registration.toml`. The setup script symlinks the
second to the first. Current builds seem to handle it, but the AUR
package still recommends the symlink and it does no harm.

### 8. Version pairing

`intune-portal` 1.2609.x requires `microsoft-identity-broker >= 3.0.1`
(from the deb's `Depends`). Mixing a new portal with an old broker, or the
2.0.1 Java broker with current Microsoft endpoints, produces JSON parse
errors (`4y8ve`) and blank sign-in windows. Keep both at the newest
versions in this repo and the AUR.

## Troubleshooting

Run `intune-doctor` first. Then start the portal from a terminal:

```bash
intune-portal                      # logs to the terminal
journalctl --user -u intune-agent -n 100 --no-pager
journalctl -u microsoft-identity-device-broker -n 100 --no-pager
journalctl --since '10 min ago' --no-pager | grep -iE 'intune|broker|msal|oneauth|keyring|openssl_shim'
dsreg --status                     # device registration and PRT state
```

Error tags shown in the portal's "Something went wrong [xxxxx]" box:

| Tag | Message in logs | Cause | Fix |
|---|---|---|---|
| `4kv4v` | `Missing PRT after a successful bootstrap`, libsecret error 19 on `WriteNoLock` | no `login` keyring collection, or wrapper without `GNOME_KEYRING_CONTROL` | subtlety 3 and 4 |
| `4u3gb` | `storage_keyring_write_failure` | default keyring is not `login` | `echo login > ~/.local/share/keyrings/default`, restart gnome-keyring |
| `581h6` | `key_not_returned` | device broker could not use the TPM | subtlety 5, then full reset |
| `4rfhk` | `The operation attempted is invalid`, `interactive request already in progress` | a hung user broker from a previous attempt | `pkill -9 -f identity-broker/bin/microsoft-identity-broker`, retry |
| `4y8ve` | JSON parse error `BEGIN_OBJECT expected` | broker too old for the current service | upgrade the broker |
| (none) | certificate / CSR error during enrollment | shim not loaded | `intune-doctor` shows wrappers as plain ELF: reinstall this package |

Other symptoms:

- **"Upgrade to a supported Linux distro" or compliance `expected ubuntu /
  actual omarchy`.** `/etc/os-release` was replaced. `ls -la
  /etc/os-release` should show a symlink; run `intune-arch-setup` again.
  Then force a check-in: `systemctl --user start intune-agent.service`.
- **Check-ins time out, everything else works.** Look for a dead VPN
  tunnel: `ip route get 20.37.152.128`. A route via `MSFT-AzVPN-*` with
  100% loss means the Azure VPN client left a tunnel behind; `sudo ip link
  delete <iface>`.
- **`Cannot register URI scheme oneauth more than once` then SIGSEGV.**
  A glib2 regression in 2025 (AUR comments); fixed by upgrading glib2.
- **`Unable to initialize GTK+`.** No display in the environment the
  portal was started from. Run it from the graphical session; with
  systemd-run or SSH, pass `DISPLAY`/`WAYLAND_DISPLAY`.
- **Browser SSO breaks but Intune is fine.** Edge talks to the broker
  natively. Chromium with linux-entra-sso injects a PRT cookie that goes
  stale after minutes and Conditional Access then demands a YubiKey. Use
  Edge or Firefox for Microsoft sign-ins.
- **HTTP 500 from the policy endpoint.** Transient server error; the next
  hourly check-in succeeds. Not local.

### Full reset

When state is corrupt (repeated `4rfhk`, `581h6`, or a half-finished
enrollment). This un-enrolls the device; you enroll again afterwards.

```bash
systemctl --user stop intune-agent.timer intune-agent.service
sudo systemctl stop intune-daemon.socket intune-daemon.service microsoft-identity-device-broker.service
pkill -9 -f intune; pkill -9 -f microsoft-identity; pkill -9 -f WebKitNetworkProcess
rm -rf ~/.config/intune ~/.local/state/intune ~/.local/share/intune-portal* ~/.cache/intune-portal*
rm -rf ~/.local/state/microsoft-identity-broker
sudo rm -rf /var/lib/intune /run/intune /var/lib/microsoft-identity-device-broker
sudo systemctl start microsoft-identity-device-broker.service intune-daemon.socket
intune-arch-setup           # re-creates state dirs and the symlink
intune-portal
```

The PRT in the keyring can be dropped with `dsreg --cleanup` (as root),
which is gentler than deleting keyring files.

## Updating to a new upstream release

Microsoft publishes new debs at
<https://packages.microsoft.com/ubuntu/24.04/prod/pool/main/i/intune-portal/>
without release notes. The AUR package often lags by months.

```bash
intune-doctor | grep upstream                 # shows the newest version
sed -i 's/^pkgver=.*/pkgver=1.2609.5/; s/^pkgrel=.*/pkgrel=1/' PKGBUILD
updpkgsums                                    # downloads the deb, fills sha256sums
makepkg --printsrcinfo > .SRCINFO
makepkg -si
intune-doctor
```

Before bumping, check that the shim is still needed (and still
sufficient): `intune-doctor` reports whether the new `intune-portal`
still passes CSR version 2. If a release ever stops, the wrapper can go.
Also compare `Depends:` in the deb's control file against `depends=()`;
the broker minimum moved from 2.x to 3.0.1 in 2026.

`microsoft-identity-broker-bin` is maintained in the AUR by the same
maintainer as the upstream `intune-portal-bin`; `yay -Syu` is enough.

## Repository layout

| Path | Purpose |
|---|---|
| `PKGBUILD`, `.SRCINFO`, `intune-portal-bin.install` | the package |
| `openssl_shim.c` | the `X509_REQ_set_version` fix |
| `intune-wrapper-openssl.sh` | installed as all three binaries |
| `os-release` | Ubuntu 24.04 content for the spoof |
| `99-intune-os-release.hook` | pacman hook that keeps `/etc/os-release` a symlink |
| `intune-doctor.sh` | health check, installed as `intune-doctor` |
| `intune-arch-setup.sh` | system preparation, installed as `intune-arch-setup` |
| `skills/intune-troubleshoot/` | a skill for coding agents with the same knowledge |
| `docs/history/` | the 2025 debugging write-ups this README condenses |

## Credits

Dan Johansen (Strit) maintains the upstream AUR packages. The OpenSSL
root cause is OpenSSL issue 20663 / commit 264ff64. Recolic's
`microsoft-intune-archlinux` and chrisnicola's broker packaging were the
sources for the TPM and broker version notes.
