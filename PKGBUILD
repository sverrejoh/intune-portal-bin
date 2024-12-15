# Maintainer: Dan Johansen <strit@strits.dk>

pkgname=intune-portal-bin
_pkgname=intune-portal
pkgver=1.2411.14
pkgrel=2
pkgdesc="Enroll devices in Microsoft Azure Endpoint"
arch=('x86_64')
url="http://intune.microsoft.com"
license=('Unknown')
provides=('intune-portal')
depends=('curl' 'at-spi2-core' 'gtk3' 'webkit2gtk' 'libsoup' 'libsecret' 'libpwquality' 'libx11' 'sqlite' 'microsoft-identity-broker')
install=$pkgname.install
source=("https://packages.microsoft.com/ubuntu/24.04/prod/pool/main/i/${_pkgname}/${_pkgname}_${pkgver}-noble_amd64.deb"
        "os-release")
sha256sums=('37a69f4f3cca163ca1897230b20998a684a108571f6203499c2fcd1c420eec66'
            '3d545e5f2af1dc74afb0a295a67b07e81ac226534690891ef7ddd86ef0886baf')

prepare() {
    tar -xvf data.tar.xz
}

package() {
  install -d "$pkgdir"/usr/lib/systemd/{system,user}
  install -d "$pkgdir"/opt/microsoft/intune/{bin,share}
  install -d "$pkgdir"/usr/lib/{tmpfiles.d,/security}
  install -Dm644 "$srcdir"/usr/share/pam-configs/intune -t "$pkgdir"/etc/pam.d/
  install -Dm644 "$srcdir"/usr/lib/x86_64-linux-gnu/security/pam_intune.so -t "$pkgdir"/usr/lib/security/
  install -Dm644 "$srcdir"/usr/lib/tmpfiles.d/intune.conf -t "$pkgdir"/usr/lib/tmpfiles.d/
  install -Dm644 "$srcdir"/usr/share/applications/intune-portal.desktop -t "$pkgdir"/usr/share/applications/
  install -Dm644 "$srcdir"/usr/share/icons/hicolor/48x48/apps/intune.png -t "$pkgdir"/usr/share/icons/hicolor/48x48/apps/
  install -Dm644 "$srcdir"/usr/share/polkit-1/actions/com.microsoft.intune.policy -t "$pkgdir"/usr/share/polkit-1/actions/
  install -Dm644 "$srcdir"/usr/share/doc/intune-portal/copyright -t "$pkgdir"/usr/share/doc/intune-portal/
  install -Dm644 "$srcdir"/lib/systemd/system/* "$pkgdir"/usr/lib/systemd/system/
  install -Dm644 "$srcdir"/lib/systemd/user/* "$pkgdir"/usr/lib/systemd/user/
  install -Dm755 "$srcdir"/opt/microsoft/intune/bin/* "$pkgdir"/opt/microsoft/intune/bin/
  install -Dm644 "$srcdir"/os-release -t "$pkgdir"/opt/microsoft/intune/share/
  cp -r "$srcdir"/opt/microsoft/intune/share/* "$pkgdir"/opt/microsoft/intune/share/
}
