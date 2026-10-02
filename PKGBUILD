# Maintainer: Sverre Johansen <sverre.johansen@gmail.com>
# Upstream AUR maintainer: Dan Johansen <strit@strits.dk>
#
# Fork of the AUR intune-portal-bin package with the fixes needed to
# enroll and stay enrolled on Arch Linux:
#  - LD_PRELOAD shim for the X509_REQ_set_version(2) bug that breaks
#    enrollment on OpenSSL >= 3.4 (still present in 1.2609.5, verified
#    by disassembly; see README.md)
#  - wrapper scripts around all three binaries so the shim and keyring
#    environment apply to the portal, the agent and the daemon
#  - intune-doctor / intune-arch-setup helper scripts

pkgname=intune-portal-bin
_pkgname=intune-portal
pkgver=1.2609.5
pkgrel=1
pkgdesc="Microsoft Intune company portal and agent (with Arch Linux compatibility fixes)"
arch=('x86_64')
url="https://learn.microsoft.com/mem/intune/user-help/enroll-device-linux"
license=('LicenseRef-Microsoft-Intune')
provides=('intune-portal')
conflicts=('intune-portal')
depends=(
        'curl'
        'at-spi2-core'
        'dbus'
        'gcc-libs'
        'gtk3'
        'glib2'
        'webkit2gtk-4.1'
        'hicolor-icon-theme'
        'libsoup3'
        'libsecret'
        'libpwquality'
        'libp11-kit'
        'libx11'
        'openssl'
        'pam'
        'pango'
        'sqlite'
        'systemd-libs'
        'util-linux-libs'
        'microsoft-identity-broker'
        'zlib'
)
optdepends=(
        'gnome-keyring: Secret Service provider; the broker needs a "login" collection'
        'kwallet: alternative Secret Service provider for Plasma'
        'tpm2-tss: TPM-backed device keys (pulled in through libsecret)'
)
install=$pkgname.install
source=("https://packages.microsoft.com/ubuntu/24.04/prod/pool/main/i/${_pkgname}/${_pkgname}_${pkgver}-noble_amd64.deb"
        "os-release"
        "openssl_shim.c"
        "intune-wrapper-openssl.sh"
        "intune-doctor.sh"
        "intune-arch-setup.sh"
        "99-intune-os-release.hook")
sha256sums=('9e98636a336ad61c0ba475b68d52861b5816382fc1fde7a7fc7d387989867a14'
            'e76761955061bc82bc47ec0214c1053100b3256e1b93fabf279bb80e220c4046'
            'bc90015d4befaf813a98e49068c1c38981b3c29abc1f0826f21f575e618d98bc'
            'fdded595ab8e34d46ec2026f60dde24b3eeb234b257c03b5ed71e96e252aa0ed'
            '0fb3611d5883e1bfae8524c0f22146cd05480e7e640428d1207b0410453a610f'
            '95f172b5b93b24a9f12d24dcacc57824401110b383a1abb3fa0ebf202306b076'
            '240be642e144730232c4c082218c0c43387c5cfbbcbbf5fc644ca87f3c366dec')

prepare() {
    tar -xf data.tar.xz
}

build() {
    # OpenSSL compatibility shim, see openssl_shim.c for the why.
    gcc -O2 -Wall -fPIC -shared -o openssl_shim.so openssl_shim.c -ldl
}

package() {
  install -d "$pkgdir"/usr/lib/systemd/{system,user}
  install -d "$pkgdir"/opt/microsoft/intune/{bin,share,lib}
  install -d "$pkgdir"/usr/lib/{tmpfiles.d,security}

  # PAM, tmpfiles, desktop integration, polkit
  install -Dm644 "$srcdir"/usr/share/pam-configs/intune -t "$pkgdir"/etc/pam.d/
  install -Dm644 "$srcdir"/usr/lib/x86_64-linux-gnu/security/pam_intune.so -t "$pkgdir"/usr/lib/security/
  install -Dm644 "$srcdir"/usr/lib/tmpfiles.d/intune.conf -t "$pkgdir"/usr/lib/tmpfiles.d/
  install -Dm644 "$srcdir"/usr/share/applications/intune-portal.desktop -t "$pkgdir"/usr/share/applications/
  install -Dm644 "$srcdir"/usr/share/icons/hicolor/48x48/apps/intune.png -t "$pkgdir"/usr/share/icons/hicolor/48x48/apps/
  install -Dm644 "$srcdir"/usr/share/polkit-1/actions/com.microsoft.intune.policy -t "$pkgdir"/usr/share/polkit-1/actions/

  # Licenses
  install -Dm644 "$srcdir"/usr/share/doc/intune-portal/copyright -t "$pkgdir"/usr/share/licenses/$pkgname/
  install -Dm644 "$srcdir"/opt/microsoft/intune/NOTICE.txt -t "$pkgdir"/usr/share/licenses/$pkgname/

  # systemd units (Debian ships them under /lib)
  install -Dm644 "$srcdir"/lib/systemd/system/* "$pkgdir"/usr/lib/systemd/system/
  install -Dm644 "$srcdir"/lib/systemd/user/* "$pkgdir"/usr/lib/systemd/user/

  # Original binaries get a .original suffix ...
  for binary in "$srcdir"/opt/microsoft/intune/bin/*; do
    install -Dm755 "$binary" "$pkgdir"/opt/microsoft/intune/bin/"$(basename "$binary")".original
  done

  # ... and the wrapper takes their place. The wrapper execs
  # <own name>.original with LD_PRELOAD and keyring env set.
  for binary in intune-portal intune-agent intune-daemon; do
    install -Dm755 "$srcdir"/intune-wrapper-openssl.sh "$pkgdir"/opt/microsoft/intune/bin/"$binary"
  done
  install -Dm755 "$srcdir"/openssl_shim.so "$pkgdir"/opt/microsoft/intune/lib/openssl_shim.so

  # Upstream's postinst symlinks the portal into PATH; do the same.
  install -d "$pkgdir"/usr/bin
  ln -s /opt/microsoft/intune/bin/intune-portal "$pkgdir"/usr/bin/intune-portal

  # Arch helpers: health check and one-shot system preparation.
  install -Dm755 "$srcdir"/intune-doctor.sh "$pkgdir"/usr/bin/intune-doctor
  install -Dm755 "$srcdir"/intune-arch-setup.sh "$pkgdir"/usr/bin/intune-arch-setup

  # Ubuntu os-release for the spoof (applied by intune-arch-setup, never
  # by the package itself) and the pacman hook that keeps /etc/os-release
  # pointing at it across omarchy-settings / filesystem upgrades.
  install -Dm644 "$srcdir"/os-release -t "$pkgdir"/opt/microsoft/intune/share/
  install -Dm644 "$srcdir"/99-intune-os-release.hook -t "$pkgdir"/opt/microsoft/intune/share/
  cp -r "$srcdir"/opt/microsoft/intune/share/locale "$pkgdir"/opt/microsoft/intune/share/
}
