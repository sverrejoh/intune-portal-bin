#!/bin/bash
# intune-doctor: read-only health check for Microsoft Intune on Arch Linux.
#
# Checks every requirement that has broken Intune on Arch at least once
# (see README.md "The subtleties"). Prints PASS/WARN/FAIL per item and
# exits with the number of FAILs. Never changes anything.
#
# Usage: intune-doctor [--no-network]

set -uo pipefail

NETWORK=1
[[ "${1:-}" == "--no-network" ]] && NETWORK=0

fails=0
warns=0
pass() { printf '  \e[32mPASS\e[0m  %s\n' "$*"; }
warn() { printf '  \e[33mWARN\e[0m  %s\n' "$*"; warns=$((warns + 1)); }
fail() { printf '  \e[31mFAIL\e[0m  %s\n' "$*"; fails=$((fails + 1)); }
info() { printf '  \e[36minfo\e[0m  %s\n' "$*"; }
section() { printf '\n\e[1m== %s\e[0m\n' "$*"; }

BIN=/opt/microsoft/intune/bin
SHIM=/opt/microsoft/intune/lib/openssl_shim.so

# ---------------------------------------------------------------- packages
section "Packages"
if v=$(pacman -Q intune-portal-bin 2>/dev/null); then
  pass "$v"
else
  fail "intune-portal-bin is not installed"
fi
if v=$(pacman -Q microsoft-identity-broker-bin 2>/dev/null); then
  ver=${v#* }
  if [[ "$(vercmp "${ver%-*}" 3.0.1)" -ge 0 ]]; then
    pass "$v"
  else
    fail "$v (intune-portal >= 1.2609 needs microsoft-identity-broker >= 3.0.1)"
  fi
else
  fail "microsoft-identity-broker-bin is not installed"
fi
if (( NETWORK )); then
  latest=$(curl -fsS -m 10 \
    https://packages.microsoft.com/ubuntu/24.04/prod/pool/main/i/intune-portal/ 2>/dev/null |
    grep -oE 'intune-portal_[0-9.]+-noble_amd64\.deb' | sed -E 's/intune-portal_([0-9.]+)-.*/\1/' |
    sort -uV | tail -1)
  installed=$(pacman -Q intune-portal-bin 2>/dev/null | awk '{print $2}' | cut -d- -f1)
  if [[ -n "$latest" && -n "$installed" ]]; then
    if [[ "$latest" == "$installed" ]]; then
      pass "upstream latest is $latest (installed)"
    else
      info "upstream latest is $latest, installed $installed (bump pkgver in PKGBUILD)"
    fi
  fi
fi

# ---------------------------------------------------------- wrappers/shim
section "OpenSSL shim and wrappers"
for b in intune-portal intune-agent intune-daemon; do
  if [[ ! -e $BIN/$b ]]; then
    fail "$BIN/$b missing"
  elif head -c 2 "$BIN/$b" 2>/dev/null | grep -q '#!'; then
    if grep -q GNOME_KEYRING_CONTROL "$BIN/$b" && [[ -x $BIN/$b.original ]]; then
      pass "$b is the wrapper (shim + GNOME_KEYRING_CONTROL), $b.original present"
    else
      fail "$b is a script but incomplete (needs GNOME_KEYRING_CONTROL export and $b.original)"
    fi
  else
    fail "$b is a plain ELF binary: the shim is NOT applied (plain AUR package installed?)"
  fi
done
if [[ -f $SHIM ]]; then
  if LD_PRELOAD=$SHIM /bin/true 2>/dev/null; then
    pass "openssl_shim.so present and loadable"
  else
    fail "openssl_shim.so present but fails to load"
  fi
else
  fail "$SHIM missing (enrollment will fail on OpenSSL >= 3.4)"
fi
if [[ -x $BIN/intune-portal.original ]] && command -v objdump >/dev/null; then
  if objdump -d --no-show-raw-insn "$BIN/intune-portal.original" 2>/dev/null |
       grep -B3 'call.*X509_REQ_set_version' | grep -q 'push *\$0x2'; then
    info "this intune-portal build still passes CSR version 2; the shim is required"
  else
    info "could not find the version-2 CSR call; the shim may no longer be needed"
  fi
fi

# ------------------------------------------------------------- os-release
section "Distribution spoof (Intune supports Ubuntu/RHEL only)"
if [[ -L /etc/os-release ]]; then
  pass "/etc/os-release is a symlink -> $(readlink /etc/os-release)"
else
  fail "/etc/os-release is a regular file (an omarchy-settings upgrade replaces the symlink)"
fi
id_line=$(. /etc/os-release 2>/dev/null; echo "${ID:-?} ${VERSION_ID:-?}")
if [[ "$id_line" == "ubuntu 24.04" || "$id_line" == "ubuntu 22.04" ]]; then
  pass "/etc/os-release reports $id_line"
else
  fail "/etc/os-release reports '$id_line'; Intune compliance expects ubuntu 24.04"
fi
if [[ -f /etc/pacman.d/hooks/99-intune-os-release.hook || -f /etc/pacman.d/hooks/99-restore-os-release.hook ]]; then
  pass "pacman hook restores the /etc/os-release symlink"
else
  warn "no pacman hook protects /etc/os-release (Omarchy upgrades will break compliance)"
fi
if grep -qE '^\s*NoUpgrade\s*=.*usr/lib/os-release' /etc/pacman.conf; then
  pass "pacman.conf NoUpgrade protects /usr/lib/os-release"
else
  warn "pacman.conf lacks 'NoUpgrade = usr/lib/os-release' (a filesystem upgrade restores Arch)"
fi
if command -v lsb_release >/dev/null; then
  d=$(lsb_release -is 2>/dev/null)
  if [[ "$d" == "Ubuntu" ]]; then
    pass "lsb_release reports Ubuntu"
  else
    fail "lsb_release reports '$d' and overrides os-release for enrollment"
  fi
else
  pass "lsb_release not present (good: it would report Arch)"
fi

# -------------------------------------------------------------------- TPM
section "TPM"
if id -nG | tr ' ' '\n' | grep -qx tss; then
  pass "user is in group tss"
else
  fail "user is not in group tss (sudo usermod -aG tss \$USER, then re-login)"
fi
if [[ -c /dev/tpmrm0 ]]; then
  pass "/dev/tpmrm0 present"
else
  warn "no /dev/tpmrm0: no TPM or tpm_tis/tpm_crb module not loaded"
fi
tss=$(pacman -Q tpm2-tss 2>/dev/null | awk '{print $2}')
if [[ "$tss" == "3.2.0-1" ]]; then
  if grep -qE '^\s*IgnorePkg\s*=.*tpm2-tss' /etc/pacman.conf; then
    pass "tpm2-tss $tss and pinned in pacman.conf"
  else
    warn "tpm2-tss $tss but not in IgnorePkg; the next -Syu upgrades it"
  fi
  if ldd /usr/lib/libtss2-esys.so.0 2>/dev/null | grep -q 'not found'; then
    fail "tpm2-tss 3.2.0 needs openssl-1.1 (AUR) and a library is missing"
  fi
elif [[ -n "$tss" ]]; then
  warn "tpm2-tss $tss; 3.2.0-1 is the known-good version (4.x reported to break device keys)"
else
  warn "tpm2-tss not installed"
fi

# ---------------------------------------------------------------- keyring
section "Secret Service (keyring)"
if busctl --user status org.freedesktop.secrets >/dev/null 2>&1; then
  pass "org.freedesktop.secrets is on the session bus"
  alias=$(busctl --user call org.freedesktop.secrets /org/freedesktop/secrets \
    org.freedesktop.Secret.Service ReadAlias s default 2>/dev/null | awk '{print $2}' | tr -d '"')
  if [[ "$alias" == "/org/freedesktop/secrets/collection/login" ]]; then
    pass "default collection is 'login'"
  else
    fail "default collection is '${alias:-none}'; the broker needs /org/freedesktop/secrets/collection/login"
  fi
  locked=$(busctl --user get-property org.freedesktop.secrets \
    /org/freedesktop/secrets/collection/login org.freedesktop.Secret.Collection Locked 2>/dev/null | awk '{print $2}')
  if [[ -n "$locked" ]]; then
    if [[ "$locked" == "false" ]]; then
      pass "login collection exists and is unlocked"
    else
      fail "login collection exists but is locked (tokens cannot be read/written)"
    fi
  else
    fail "no 'login' collection on the secret service"
  fi
else
  fail "no Secret Service on the session bus (gnome-keyring-daemon.socket not running?)"
fi
if systemctl --user show-environment 2>/dev/null | grep -q '^GNOME_KEYRING_CONTROL='; then
  pass "GNOME_KEYRING_CONTROL set in the user manager environment"
else
  warn "GNOME_KEYRING_CONTROL not in systemctl --user environment (dbus-activated broker may not find the keyring)"
fi
if [[ -f ~/.local/share/keyrings/default ]]; then
  d=$(<~/.local/share/keyrings/default)
  [[ "$d" == "login" ]] && pass "~/.local/share/keyrings/default = login" ||
    warn "~/.local/share/keyrings/default = '$d' (expected login)"
fi

# --------------------------------------------------------------- services
section "Services"
if systemctl is-active -q microsoft-identity-device-broker.service; then
  pass "microsoft-identity-device-broker.service active"
else
  warn "microsoft-identity-device-broker.service not running (dbus-activated; starts on demand)"
fi
if systemctl is-enabled -q intune-daemon.socket 2>/dev/null; then
  pass "intune-daemon.socket enabled ($(systemctl is-active intune-daemon.socket))"
else
  fail "intune-daemon.socket not enabled (sudo systemctl enable --now intune-daemon.socket)"
fi
if systemctl --user is-enabled -q intune-agent.timer 2>/dev/null; then
  pass "intune-agent.timer enabled ($(systemctl --user is-active intune-agent.timer))"
else
  fail "intune-agent.timer not enabled (systemctl --user enable --now intune-agent.timer)"
fi
n=$(pgrep -u "$(id -u)" -fc /opt/microsoft/identity-broker/bin/microsoft-identity-broker)
if (( n > 1 )); then
  warn "$n user brokers running; a stale one causes 'interactive request already in progress'"
fi
if ip -o link 2>/dev/null | grep -q 'MSFT-AzVPN'; then
  warn "Azure VPN tunnel interface present; a dead tunnel blackholes Intune check-ins"
fi

# ------------------------------------------------------------- enrollment
section "Enrollment state"
if [[ -f ~/.local/state/intune/registration.toml ]]; then
  pass "registration.toml present (device enrolled)"
  [[ -L ~/.local/state/intune/registration.toml ]] ||
    info "registration.toml is a regular file (older builds needed a symlink from ~/.config/intune)"
elif [[ -f ~/.config/intune/registration.toml ]]; then
  fail "registration.toml only in ~/.config/intune; symlink it into ~/.local/state/intune"
else
  info "not enrolled yet (no registration.toml). Run: intune-portal"
fi
last=$(journalctl --user -u intune-agent -o cat -n 400 --no-pager 2>/dev/null |
  grep -E 'Successfully checked in with Intune|Failed to checkin with Intune' | tail -1)
case "$last" in
  Successfully*) pass "last agent run: $last" ;;
  Failed*)       warn "last agent run: ${last:0:160}" ;;
  *)             info "no agent check-in found in the user journal" ;;
esac
distro=$(journalctl --user -u intune-agent -o cat -n 400 --no-pager 2>/dev/null |
  grep -oE 'alloweddistros_item_\$type", expected_value: "ubuntu", actual_value: "[a-z]*"' | tail -1)
[[ -n "$distro" ]] && info "compliance sees: ${distro##*actual_value: }"

if (( NETWORK )); then
  section "Connectivity"
  for host in login.microsoftonline.com enrollment.manage.microsoft.com packages.microsoft.com; do
    code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "https://$host/" 2>/dev/null)
    if [[ "$code" =~ ^[2345] ]]; then pass "$host answers (HTTP $code)"; else fail "$host unreachable"; fi
  done
fi

printf '\n%d failed, %d warnings\n' "$fails" "$warns"
exit "$fails"
