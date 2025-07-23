# Microsoft Intune Portal for Arch Linux

This is an Arch Linux AUR package for Microsoft Intune Portal with compatibility fixes.

## What This Package Does

Microsoft Intune officially supports only Ubuntu, but this package includes several compatibility fixes to make it work on Arch Linux:

1. **OpenSSL 3.5 Compatibility**: Fixes crashes due to stricter CSR version validation
2. **WebKit URI Registration**: Prevents duplicate oneauth:// URI scheme registration errors
3. **OS Spoofing**: Includes Ubuntu os-release file for Intune compatibility

## Installation

```bash
# Clone and build the package
git clone https://github.com/sverrejoh/intune-portal-bin.git
cd intune-portal-bin
makepkg -si
```

## Post-Installation Setup

### 1. Configure Password Policy (Required)

Ensure your system enforces password complexity by editing `/etc/pam.d/passwd`:

```bash
sudo nano /etc/pam.d/passwd
```

Add this line BEFORE the existing 'password include' line:
```
password requisite pam_pwquality.so retry=3 minlen=12 dcredit=-1 ucredit=-1 lcredit=-1 ocredit=-1
```

Example of how it should look:
```
#%PAM-1.0
password requisite pam_pwquality.so retry=3 minlen=12 dcredit=-1 ucredit=-1 lcredit=-1 ocredit=-1
password include system-auth
```

This enforces: 12+ characters, with at least 1 digit, uppercase, lowercase, and special character.

Then create a symlink for Intune compatibility:
```bash
sudo ln -sf /etc/pam.d/passwd /etc/pam.d/common-password
```

### 2. Replace OS Release File
```bash
sudo cp /opt/microsoft/intune/share/os-release /etc/os-release
```

### 3. Enable Services and Set up Keyring

#### Enable required services:
```bash
# System services
sudo systemctl enable intune-daemon.service

# User services
systemctl --user enable intune-agent.timer
```

#### Set up keyring service (choose based on your desktop environment):

**For GNOME/GTK environments:**
```bash
systemctl --user enable gnome-keyring-daemon.socket gnome-keyring-daemon.service
```

**For KDE Plasma:**
Configure KDE Wallet as per https://wiki.archlinux.org/title/KDE_Wallet#Automatic_D-Bus_activation

#### For other environments (using Seahorse):
If you're not using GNOME or KDE, you can use Seahorse as a standalone keyring manager:

```bash
# Install Seahorse
sudo pacman -S seahorse

# Enable the services
sudo systemctl enable intune-daemon.service
systemctl --user enable intune-agent.timer gnome-keyring-daemon.socket gnome-keyring-daemon.service

# Create and unlock a keyring
seahorse
# In Seahorse: File -> New -> Password Keyring
# Name it "Default" and set a password
# Unlock it before enrolling in Intune
```

### 4. Reboot
```bash
sudo reboot
```

Don't forget to reboot after running the above commands!

*Note: If you prefer not to reboot, you can manually start all services with:*
```bash
# Reload systemd and start system services
sudo systemctl daemon-reload
sudo systemctl start intune-daemon.service

# Reload user systemd and start user services
systemctl --user daemon-reload
systemctl --user start intune-agent.timer
```

## Troubleshooting

### Authentication Issues
If you experience authentication loops or failures:
- Ensure your keyring is unlocked before starting Intune
- Check that microsoft-identity-broker is installed and running
- For Seahorse users: make sure you've created and unlocked the "Default" keyring

### OpenSSL Errors
The package includes an OpenSSL compatibility shim that fixes CSR version validation issues. If you still see OpenSSL errors, please report them.

### WebKit Assertion Crashes

**Issue:** Intune may crash with "Cannot register URI scheme oneauth more than once" or similar WebKit assertion errors.

**Root Cause:**
- Arch Linux builds WebKit with assertions enabled (for debugging)
- Ubuntu builds WebKit with `-DNDEBUG` (assertions disabled)
- Intune was developed/tested on Ubuntu and triggers harmless assertions

**Solutions:**

**Option 1 - Install webkit2gtk-4.1-noassert (Recommended for full compatibility):**
```bash
yay -S webkit2gtk-4.1-noassert
# or build from source (Warning: 4-12 hour build time)
git clone https://github.com/sverrejoh/webkit2gtk-4.1-noassert-aur.git
cd webkit2gtk-4.1-noassert-aur
makepkg -si
```

This package builds WebKit without assertions, matching Ubuntu's configuration. The intune-portal-bin wrapper will automatically use it if installed.

**Option 2 - Clean Authentication State (Quick fix for re-enrollment):**
If you experience crashes during re-enrollment, clean the authentication state:
```bash
rm -rf ~/.cache/intune* ~/.local/share/intune* ~/.config/intune ~/.local/state/microsoft-identity-broker
```

The included webkit_uri_shim helps prevent some crashes, but webkit2gtk-4.1-noassert provides the most complete solution.

## Technical Details

This package uses LD_PRELOAD to load compatibility shims without modifying the original Microsoft binaries:
- `/opt/microsoft/intune/lib/openssl_shim.so` - Fixes OpenSSL CSR version validation
- `/opt/microsoft/intune/lib/webkit_uri_shim.so` - Fixes WebKit URI registration

The original binaries are renamed with a `.original` suffix and wrapped with scripts that apply the fixes.