#!/bin/bash
# intune-arch-setup: one-shot, idempotent system preparation for
# Microsoft Intune on Arch Linux. Run as your normal user; sudo is used
# where root is needed. Every step is a function below; each prints what
# it does and skips itself when already done.
#
#   intune-arch-setup            run all steps
#   intune-arch-setup --dry-run  show what would change
#   intune-arch-setup --undo     revert the distribution spoof + lsb_release
#   intune-arch-setup --yes      do not ask before downgrading tpm2-tss
#
# Why each step exists is documented in README.md, "The subtleties".

set -euo pipefail

DRY=0; UNDO=0; YES=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --undo) UNDO=1 ;;
    --yes|-y) YES=1 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

if [[ $EUID -eq 0 ]]; then
  echo "Run as your normal user, not root (it uses sudo where needed)." >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARE=/opt/microsoft/intune/share
# Sources: installed package first, then the git checkout this script
# lives in, so the script also works before the package is installed.
src_file() {
  local name=$1
  for p in "$SHARE/$name" "$SCRIPT_DIR/../$name" "$SCRIPT_DIR/$name"; do
    [[ -f $p ]] && { echo "$p"; return; }
  done
  return 1
}

say()  { printf '\e[1m-> %s\e[0m\n' "$*"; }
ok()   { printf '   \e[32m%s\e[0m\n' "$*"; }
skip() { printf '   \e[2m%s\e[0m\n' "$*"; }
run()  { if (( DRY )); then printf '   \e[33mwould:\e[0m %s\n' "$*"; else "$@"; fi; }
sudo_run() { run sudo "$@"; }

# ------------------------------------------------------------------ undo
undo() {
  say "Reverting the Ubuntu spoof"
  if [[ -f /usr/lib/os-release.arch.bak ]]; then
    sudo_run cp -f /usr/lib/os-release.arch.bak /usr/lib/os-release
    ok "/usr/lib/os-release restored from .arch.bak"
  fi
  sudo_run rm -f /etc/pacman.d/hooks/99-intune-os-release.hook
  if grep -qE '^\s*NoUpgrade\s*=\s*usr/lib/os-release' /etc/pacman.conf; then
    sudo_run sed -i '/^\s*NoUpgrade\s*=\s*usr\/lib\/os-release/d' /etc/pacman.conf
  fi
  if grep -qE '^\s*NoExtract\s*=\s*usr/bin/lsb_release' /etc/pacman.conf; then
    sudo_run sed -i '/^\s*NoExtract\s*=\s*usr\/bin\/lsb_release/d' /etc/pacman.conf
  fi
  [[ -f /usr/bin/lsb_release.bak ]] && sudo_run mv /usr/bin/lsb_release.bak /usr/bin/lsb_release
  ok "done. tpm2-tss pin, keyring and services were left alone."
}
if (( UNDO )); then undo; exit 0; fi

# ---------------------------------------------------------------- checks
say "Checking packages"
for p in intune-portal-bin microsoft-identity-broker-bin gnome-keyring; do
  if pacman -Q "$p" >/dev/null 2>&1; then ok "$p $(pacman -Q "$p" | awk '{print $2}')"
  else echo "   missing: $p (install it first, see README.md)" >&2; fi
done

# ---------------------------------------------------------------- groups
say "Group membership (TPM access, broker)"
for g in tss microsoft-identity-broker; do
  if ! getent group "$g" >/dev/null; then skip "group $g does not exist"; continue; fi
  if id -nG | tr ' ' '\n' | grep -qx "$g"; then skip "already in $g"
  else sudo_run usermod -aG "$g" "$USER"; ok "added to $g (takes effect at next login)"; fi
done

# ----------------------------------------------------------- os-release
say "Make the machine report Ubuntu 24.04"
osrel=$(src_file os-release) || { echo "os-release template not found" >&2; exit 1; }
if ! grep -q '^ID=ubuntu' /usr/lib/os-release; then
  [[ -f /usr/lib/os-release.arch.bak ]] || sudo_run cp /usr/lib/os-release /usr/lib/os-release.arch.bak
  sudo_run cp -f "$osrel" /usr/lib/os-release
  ok "/usr/lib/os-release replaced (original in /usr/lib/os-release.arch.bak)"
else
  skip "/usr/lib/os-release already Ubuntu"
fi
if [[ -L /etc/os-release && $(readlink /etc/os-release) == ../usr/lib/os-release ]]; then
  skip "/etc/os-release already symlinks ../usr/lib/os-release"
else
  if [[ -e /etc/os-release && ! -L /etc/os-release ]]; then
    sudo_run cp /etc/os-release "/etc/os-release.bak-$(date +%Y%m%d)"
  fi
  sudo_run ln -sfn ../usr/lib/os-release /etc/os-release
  ok "/etc/os-release -> ../usr/lib/os-release"
fi
hook=$(src_file 99-intune-os-release.hook) || true
if [[ -n ${hook:-} ]]; then
  if [[ -f /etc/pacman.d/hooks/99-intune-os-release.hook ]]; then skip "pacman hook present"
  else sudo_run install -Dm644 "$hook" /etc/pacman.d/hooks/99-intune-os-release.hook; ok "pacman hook installed"; fi
fi
if grep -qE '^\s*NoUpgrade\s*=.*usr/lib/os-release' /etc/pacman.conf; then
  skip "NoUpgrade for usr/lib/os-release present"
else
  sudo_run sed -i '/^\[options\]/a NoUpgrade = usr/lib/os-release' /etc/pacman.conf
  ok "NoUpgrade = usr/lib/os-release added (filesystem upgrades leave a .pacnew)"
fi

# ----------------------------------------------------------- lsb_release
say "Neutralise lsb_release (it reports Arch and overrides os-release)"
if [[ -x /usr/bin/lsb_release ]] && [[ $(lsb_release -is 2>/dev/null) != Ubuntu ]]; then
  sudo_run mv /usr/bin/lsb_release /usr/bin/lsb_release.bak
  ok "/usr/bin/lsb_release moved to .bak"
else
  skip "lsb_release absent or already reporting Ubuntu"
fi
if pacman -Q lsb-release >/dev/null 2>&1 && ! grep -qE '^\s*NoExtract\s*=.*usr/bin/lsb_release' /etc/pacman.conf; then
  sudo_run sed -i '/^\[options\]/a NoExtract = usr/bin/lsb_release' /etc/pacman.conf
  ok "NoExtract = usr/bin/lsb_release added so upgrades do not bring it back"
fi

# -------------------------------------------------------------- tpm2-tss
say "tpm2-tss (known-good 3.2.0-1, pinned)"
tss=$(pacman -Q tpm2-tss 2>/dev/null | awk '{print $2}' || true)
if [[ "$tss" == "3.2.0-1" ]]; then
  skip "tpm2-tss 3.2.0-1 installed"
else
  echo "   tpm2-tss is ${tss:-not installed}. 3.2.0-1 is the version that has"
  echo "   worked with the device broker; 4.x was reported to break device-key"
  echo "   operations (AUR comments, 2025). It needs openssl-1.1 from the AUR."
  do_it=$YES
  if (( ! YES && ! DRY )); then
    read -rp "   Downgrade and pin tpm2-tss now? [y/N] " a; [[ $a =~ ^[Yy] ]] && do_it=1
  fi
  if (( do_it || DRY )); then
    if ! pacman -Q openssl-1.1 >/dev/null 2>&1; then
      helper=$(command -v yay || command -v paru || true)
      if [[ -n $helper ]]; then run "$helper" -S --needed --noconfirm openssl-1.1
      else echo "   install openssl-1.1 from the AUR first, then re-run" >&2; exit 1; fi
    fi
    tmp=$(mktemp -d)
    run curl -fsSL -o "$tmp/tpm2-tss.pkg.tar.zst" \
      https://archive.archlinux.org/packages/t/tpm2-tss/tpm2-tss-3.2.0-1-x86_64.pkg.tar.zst
    sudo_run pacman -U --noconfirm "$tmp/tpm2-tss.pkg.tar.zst"
    ok "tpm2-tss 3.2.0-1 installed"
  fi
fi
if pacman -Q tpm2-tss >/dev/null 2>&1 && ! grep -qE '^\s*IgnorePkg\s*=.*tpm2-tss' /etc/pacman.conf; then
  if grep -qE '^\s*IgnorePkg\s*=' /etc/pacman.conf; then
    sudo_run sed -i -E '0,/^\s*IgnorePkg\s*=/s/(^\s*IgnorePkg\s*=)/\1 tpm2-tss/' /etc/pacman.conf
  else
    sudo_run sed -i '/^\[options\]/a IgnorePkg = tpm2-tss' /etc/pacman.conf
  fi
  ok "tpm2-tss added to IgnorePkg"
fi

# ---------------------------------------------------------------- keyring
say "gnome-keyring with a 'login' collection as default"
run systemctl --user enable --now gnome-keyring-daemon.socket >/dev/null 2>&1 || true
KR=~/.local/share/keyrings
run mkdir -p "$KR"
if [[ ! -f $KR/login.keyring ]]; then
  if [[ -f $KR/login.keyring.bak ]]; then
    run cp "$KR/login.keyring.bak" "$KR/login.keyring"; ok "login.keyring restored from .bak"
  elif [[ -f $KR/Default_keyring.keyring || -f $KR/Default.keyring ]]; then
    srcf=$KR/Default_keyring.keyring; [[ -f $srcf ]] || srcf=$KR/Default.keyring
    run cp "$srcf" "$KR/login.keyring"
    ok "login.keyring created from $(basename "$srcf") (same password)"
  else
    echo "   creating the login collection; a password prompt will appear."
    echo "   Use your LOGIN password so PAM can unlock it automatically."
    run busctl --user call org.freedesktop.secrets /org/freedesktop/secrets \
      org.freedesktop.Secret.Service CreateCollection 'a{sv}s' 1 \
      org.freedesktop.Secret.Collection.Label s login "" >/dev/null || true
  fi
else
  skip "login.keyring exists"
fi
if [[ $(cat "$KR/default" 2>/dev/null) != login ]]; then
  (( DRY )) || echo login > "$KR/default"
  ok "default keyring set to login"
  run systemctl --user restart gnome-keyring-daemon.service 2>/dev/null || true
  sleep 2
else
  skip "default keyring already login"
fi
alias=$(busctl --user call org.freedesktop.secrets /org/freedesktop/secrets \
  org.freedesktop.Secret.Service ReadAlias s default 2>/dev/null | awk '{print $2}' | tr -d '"')
[[ "$alias" == "/org/freedesktop/secrets/collection/login" ]] && ok "secret service default -> login" ||
  echo "   WARNING: secret service default is '${alias:-none}', expected .../collection/login"

say "GNOME_KEYRING_CONTROL for dbus-activated services"
envd=~/.config/environment.d/90-intune-keyring.conf
if [[ -f $envd ]]; then skip "$envd present"
else
  run mkdir -p ~/.config/environment.d
  (( DRY )) || printf 'GNOME_KEYRING_CONTROL=${XDG_RUNTIME_DIR}/keyring\n' > "$envd"
  ok "$envd written (applies at next login)"
fi
run systemctl --user set-environment "GNOME_KEYRING_CONTROL=/run/user/$(id -u)/keyring"
run dbus-update-activation-environment --systemd GNOME_KEYRING_CONTROL="/run/user/$(id -u)/keyring" 2>/dev/null || true

# --------------------------------------------------------------- services
say "Services"
sudo_run systemctl daemon-reload
sudo_run systemctl enable --now intune-daemon.socket
sudo_run systemctl start microsoft-identity-device-broker.service || true
run systemctl --user daemon-reload
run systemctl --user enable --now intune-agent.timer
ok "intune-daemon.socket, device broker, intune-agent.timer"

# ------------------------------------------------------------ state dirs
say "State directories"
run mkdir -p ~/.config/intune ~/.local/state/intune
if [[ ! -e ~/.local/state/intune/registration.toml ]]; then
  run ln -sfn ~/.config/intune/registration.toml ~/.local/state/intune/registration.toml
  ok "~/.local/state/intune/registration.toml -> ~/.config/intune/registration.toml"
else
  skip "registration.toml already in ~/.local/state/intune"
fi

cat <<'MSG'

Done. Next:
  1. Log out and back in (group membership, keyring environment).
  2. intune-doctor            # everything should be PASS
  3. intune-portal            # sign in and enroll
MSG
