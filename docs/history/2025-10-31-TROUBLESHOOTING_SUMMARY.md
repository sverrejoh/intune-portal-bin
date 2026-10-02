> Historical write-up from 2025-10-31, kept verbatim. Paths and versions
> are outdated; the current guide is ../../README.md.

# Microsoft Intune on Arch Linux - Complete Troubleshooting Journey

## 🚨 The Original Problem

**Error**: "Error Something went wrong. [4kv4v]" during Intune authentication

**What happened**: You mentioned "Just before it stopped working I noticed that Omarchy changed to some sort of key manager that unlocks on login."

This change to "unlock on login" keyring configuration corrupted your gnome-keyring and triggered a cascade of issues.

---

## 🔍 Root Cause Analysis

### The Fatal Flaw: Missing Login Keyring Collection

The Microsoft Identity Broker (native C++ version 2.0.3) has a **hardcoded requirement** for the `/org/freedesktop/secrets/collection/login` DBus path to store authentication tokens via libsecret.

Your system only had:
- `/org/freedesktop/secrets/collection/Default`
- `/org/freedesktop/secrets/collection/Default_keyring`
- `/org/freedesktop/secrets/collection/session`

**But NOT** `/org/freedesktop/secrets/collection/login`

When the broker tried to call libsecret's `secret_password_store_sync()` to the "login" collection, it returned **Error Code 19**: "No such interface 'org.freedesktop.Secret.Collection' on object at path /org/freedesktop/secrets/collection/login"

This caused the error: `write_token_last_error: Error '(pii)' was returned for API: 'WriteNoLock'`

### Secondary Issues Discovered

1. **Corrupted gnome-keyring files**
   - `Default_keyring.keyring` was in "invalid or unrecognized format"
   - Logs showed: `keyring was in an invalid or unrecognized format`
   
2. **lsb_release breaking Ubuntu spoof**
   - Reported "Arch Linux" which overrode `/etc/os-release`
   - Microsoft Intune only officially supports Ubuntu
   
3. **Missing TPM access**
   - User not in `tss` group
   - Couldn't access `/dev/tpm0` and `/dev/tpmrm0` for device key generation
   
4. **tpm2-tss version incompatibility**  
   - Version 4.1.3-1 causes issues with Intune
   - Known issue on Arch Linux (per AUR comments)
   
5. **OpenSSL 3.4+ CSR version bug**
   - Intune calls `X509_REQ_set_version(req, 2)` 
   - But RFC 2986 specifies CSRs only have version 1 (value = 0)
   - OpenSSL 3.4+ enforces this, causing enrollment to fail
   
6. **Missing dependencies**
   - OpenSSL 1.1 required for java-based device broker (if using older versions)
   
7. **Missing environment variables**
   - `GNOME_KEYRING_CONTROL` not set for DBus-activated services
   - Broker couldn't find keyring socket
   
8. **Missing intune-daemon wrapper**
   - AUR package only created wrappers for portal and agent
   - Daemon needed same LD_PRELOAD and environment setup

---

## 🛠️ Complete Fix (Step by Step)

### Phase 1: System Configuration

```bash
# 1. Add user to tss group for TPM access
sudo usermod -aG tss $USER

# 2. Disable lsb_release (it overrides Ubuntu spoof)
sudo mv /usr/bin/lsb_release /usr/bin/lsb_release.bak

# 3. Downgrade tpm2-tss to compatible version
cd /tmp
curl -LO "https://archive.archlinux.org/packages/t/tpm2-tss/tpm2-tss-3.2.0-1-x86_64.pkg.tar.zst"
sudo pacman -U tpm2-tss-3.2.0-1-x86_64.pkg.tar.zst --noconfirm

# 4. Pin tpm2-tss to prevent upgrades
sudo bash -c 'echo "IgnorePkg = tpm2-tss" >> /etc/pacman.conf'

# 5. Install OpenSSL 1.1 compatibility (if needed for older broker versions)
yay -S openssl-1.1 --noconfirm
```

### Phase 2: Keyring Configuration (THE CRITICAL FIX)

```bash
# 1. Stop gnome-keyring daemon
systemctl --user stop gnome-keyring-daemon.service

# 2. Remove corrupted keyring files
rm ~/.local/share/keyrings/Default_keyring.keyring

# 3. Create login keyring from existing Default keyring
cp ~/.local/share/keyrings/Default_keyring.keyring ~/.local/share/keyrings/login.keyring 2>/dev/null || \
  touch ~/.local/share/keyrings/login.keyring

# 4. Set login as the default keyring
echo "login" > ~/.local/share/keyrings/default

# 5. Restart gnome-keyring daemon
systemctl --user start gnome-keyring-daemon.service
sleep 3

# 6. Verify login collection exists
busctl --user tree org.freedesktop.secrets | grep login
# Should show: /org/freedesktop/secrets/collection/login

# 7. Verify it's set as default
busctl --user call org.freedesktop.secrets /org/freedesktop/secrets org.freedesktop.Secret.Service ReadAlias s "default"
# Should show: o "/org/freedesktop/secrets/collection/login"
```

### Phase 3: Intune Installation

```bash
# 1. Install latest versions
yay -S intune-portal-bin microsoft-identity-broker-bin --noconfirm

# Versions that work:
# - intune-portal-bin: 1.2511.7-1
# - microsoft-identity-broker-bin: 2.0.3-1 (native C++)

# 2. Compile OpenSSL compatibility shim
cd ~/Projects/Microsoft/intune-portal-bin
gcc -shared -fPIC -o openssl_shim.so openssl_shim.c -lssl -lcrypto

# 3. Install the shim
sudo mkdir -p /opt/microsoft/intune/lib
sudo cp openssl_shim.so /opt/microsoft/intune/lib/
sudo chmod +x /opt/microsoft/intune/lib/openssl_shim.so

# 4. Create wrapper scripts for ALL binaries (portal, agent, daemon)
for binary in intune-portal intune-agent intune-daemon; do
  # Backup original if not already done
  if [ ! -f "/opt/microsoft/intune/bin/${binary}.original" ]; then
    sudo mv "/opt/microsoft/intune/bin/${binary}" "/opt/microsoft/intune/bin/${binary}.original"
  fi
  
  # Create wrapper script
  sudo tee "/opt/microsoft/intune/bin/${binary}" > /dev/null << 'WRAPPER'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LD_PRELOAD="/opt/microsoft/intune/lib/openssl_shim.so:${LD_PRELOAD}"
export GNOME_KEYRING_CONTROL=/run/user/$(id -u)/keyring
BINARY_NAME="$(basename "$0")"
exec "${SCRIPT_DIR}/${BINARY_NAME}.original" "$@"
WRAPPER
  
  sudo chmod +x "/opt/microsoft/intune/bin/${binary}"
done

# 5. Create required directories
mkdir -p ~/.local/state/intune
mkdir -p ~/.local/state/microsoft-identity-broker

# 6. Create registration.toml symlink (required by intune-agent)
ln -sf ~/.config/intune/registration.toml ~/.local/state/intune/registration.toml

# 7. Enable and start services
sudo systemctl enable --now microsoft-identity-device-broker.service
sudo systemctl enable --now intune-daemon.service
systemctl --user enable --now intune-agent.timer
```

### Phase 4: Environment Setup

```bash
# Set keyring environment for systemd user services
export GNOME_KEYRING_CONTROL=/run/user/$(id -u)/keyring
systemctl --user set-environment GNOME_KEYRING_CONTROL=/run/user/$(id -u)/keyring

# Verify it's set
systemctl --user show-environment | grep GNOME_KEYRING
```

### Phase 5: Verification

```bash
# 1. Check login keyring exists
busctl --user tree org.freedesktop.secrets | grep login

# 2. Check services are running
sudo systemctl status microsoft-identity-device-broker.service
sudo systemctl status intune-daemon.service

# 3. Test keyring write
secret-tool store --label='test' application test key value <<< "testdata"
secret-tool lookup application test key value
secret-tool clear application test key value

# 4. Check you're in tss group (requires logout/login to take effect)
groups | grep tss

# 5. Verify versions
pacman -Qi intune-portal-bin microsoft-identity-broker-bin tpm2-tss | grep "^Name\|^Version"
```

---

## 🎯 Why It Works Now

### The Login Keyring Fix
The **login keyring collection** is specifically hardcoded in the Microsoft Identity Broker C++ code. When you see these log entries:

```
WriteNoLock:112 hashKey 'id'
WriteNoLock:114 hashVal '(pii)'
Error Code 19: Error '(pii)' was returned for API: 'WriteNoLock'
Missing PRT after a successful bootstrap
```

It means the broker successfully authenticated with Microsoft (`HTTP 200`, `server_error_code: 0`) but **couldn't save the Primary Refresh Token (PRT)** because the login collection didn't exist.

### The OpenSSL Shim Fix
When Intune generates a Certificate Signing Request (CSR) for device enrollment, it incorrectly calls:
```c
X509_REQ_set_version(req, 2)  // WRONG! CSRs only have version 0
```

OpenSSL 3.0-3.3 silently ignored this. OpenSSL 3.4+ throws an error. The shim intercepts and fixes it:
```c
if (version != 0) {
    fprintf(stderr, "openssl_shim: Fixing invalid X509_REQ version %ld to 0\n", version);
    version = 0;
}
```

### The lsb_release Fix
Even though `/etc/os-release` was set to Ubuntu, running `lsb_release -a` returned "Arch Linux". Microsoft's enrollment API checks this and rejects non-Ubuntu systems.

### The TPM Access Fix
Device enrollment requires generating cryptographic keys in the TPM (Trusted Platform Module). Without `tss` group membership and the correct tpm2-tss version, these operations fail silently.

---

## 📊 Error Code Journey

We encountered **5 different error codes** during troubleshooting:

| Error Tag | Error Code | Meaning | Fix |
|-----------|------------|---------|-----|
| `4kv4v` | 1001 | Missing PRT after successful bootstrap | Create login keyring collection |
| `4y8ve` | 1001 | JSON parse error (BEGIN_OBJECT expected) | Version incompatibility - tried multiple broker versions |
| `4u3gb` | 1001 | storage_keyring_write_failure | Default keyring not set properly |
| `581h6` | 1001 | key_not_returned | Device broker not returning encryption key |
| `4kv4v` (again) | 1001 | Missing login keyring with latest version | Recreate login keyring |
| **SUCCESS** | - | All working! | Complete configuration achieved |

---

## 🏆 Final Working Configuration

```
OS: Arch Linux 6.17.5-arch1-1
    Spoofed as: Ubuntu 24.04.2 LTS (Noble Numbat)

Intune Components:
├─ intune-portal-bin: 1.2511.7-1
├─ microsoft-identity-broker-bin: 2.0.3-1 (native C++)
└─ microsoft-identity-device-broker: 2.0.3-1 (runs as root)

Critical Dependencies:
├─ tpm2-tss: 3.2.0-1 (PINNED - do not upgrade!)
├─ openssl: 3.x (with openssl_shim.so compatibility)
├─ openssl-1.1: 1.1.1.w-1 (for compatibility)
└─ libsecret: 0.21.7-1

Keyring Setup:
├─ gnome-keyring-daemon: 1:48.0-1
├─ Default collection: /org/freedesktop/secrets/collection/login
├─ login.keyring file: ~/.local/share/keyrings/login.keyring
└─ default pointer: ~/.local/share/keyrings/default → "login"

Wrappers Applied:
├─ /opt/microsoft/intune/bin/intune-portal (wrapper)
├─   └─ intune-portal.original (actual binary)
├─ /opt/microsoft/intune/bin/intune-agent (wrapper)
├─   └─ intune-agent.original (actual binary)
└─ /opt/microsoft/intune/bin/intune-daemon (wrapper)
    └─ intune-daemon.original (actual binary)

Each wrapper sets:
- LD_PRELOAD=/opt/microsoft/intune/lib/openssl_shim.so
- GNOME_KEYRING_CONTROL=/run/user/1000/keyring

State Directories:
├─ ~/.local/state/intune/
│   └─ registration.toml → ~/.config/intune/registration.toml (symlink)
├─ ~/.local/state/microsoft-identity-broker/
│   ├─ account-data.db
│   ├─ broker-data.db
│   └─ cookies.db
└─ /var/lib/microsoft-identity-device-broker/
    └─ 1000.db (device enrollment data)
```

---

## 🧪 Testing Results

✅ **Authentication**: Working  
✅ **Token Storage**: Working (PRT saved to login keyring)  
✅ **Device Enrollment**: Working (X509 CSR generated correctly)  
✅ **Device Registration**: Working (keys stored in TPM)  

---

## 🔧 Maintenance & Future Upgrades

### DO NOT UPGRADE
- **tpm2-tss**: Must stay at 3.2.0-1 (pinned in /etc/pacman.conf)

### Safe to Upgrade
- intune-portal-bin (ensure openssl_shim wrappers remain)
- microsoft-identity-broker-bin (verify login keyring still works)

### If It Breaks Again

1. **Check login keyring exists**:
   ```bash
   busctl --user tree org.freedesktop.secrets | grep login
   ```

2. **Check openssl_shim is loading**:
   ```bash
   journalctl --since "5 minutes ago" | grep "openssl_shim"
   ```

3. **Verify wrappers are in place**:
   ```bash
   file /opt/microsoft/intune/bin/intune-portal
   # Should be: Bourne-Again shell script, not ELF executable
   ```

4. **Check tpm2-tss version**:
   ```bash
   pacman -Qi tpm2-tss | grep Version
   # Should be: 3.2.0-1
   ```

---

## 💡 Key Insights

### Why the Native C++ Broker?

We initially tried downgrading to microsoft-identity-broker 2.0.1-5 (Java-based), which AUR users said worked. However, it had JSON parsing errors when trying to communicate with Microsoft's updated API.

The native C++ broker (2.0.3) handles Microsoft's current API responses correctly, BUT it has stricter requirements:
- **Must** have login keyring collection
- **Must** have GNOME_KEYRING_CONTROL environment variable
- **Must** have working libsecret integration

### Why Both Versions Failed Initially?

**Broker 2.0.1 (Java)**: Worked for others but got JSON parsing errors for us because Microsoft may have updated their Device Registration Service API.

**Broker 2.0.3 (C++)**: Latest version but ERROR CODE 19 (missing login keyring) prevented ANY operation.

Once we created the login keyring, the C++ broker 2.0.3 worked perfectly!

### The OpenSSL Shim Magic

The shim is a tiny shared library (15KB) that uses `LD_PRELOAD` to intercept function calls:

```c
int X509_REQ_set_version(void* req, long version) {
    if (version != 0) {
        fprintf(stderr, "openssl_shim: Fixing invalid X509_REQ version %ld to 0\n", version);
        version = 0;
    }
    return original_X509_REQ_set_version(req, version);
}
```

This fixes Microsoft's bug without modifying their binaries!

---

## 📚 Debugging Techniques Used

1. **Traced binary file access** to find which config files were being read
2. **Monitored journalctl in real-time** to see authentication flow
3. **Used busctl/dbus-send** to inspect DBus secret service collections
4. **Checked process environments** (`/proc/PID/environ`) to verify variables
5. **Analyzed MSAL telemetry logs** to track error codes
6. **Searched AUR comments** to find known working configurations
7. **Used strace** to see system calls and library loading

---

## 🎓 Lessons Learned

1. **Error Code 19 from libsecret** = missing DBus collection path (not just permissions!)

2. **Microsoft Identity Broker versions matter**:
   - 2.0.1 = Java-based, more forgiving but older API
   - 2.0.3 = Native C++, stricter requirements but current API

3. **Keyring "unlock on login" isn't just about unlocking** - it changes the keyring structure and can break applications expecting specific collection names

4. **lsb_release overrides os-release** in many applications

5. **LD_PRELOAD is powerful** for fixing vendor bugs without binary modification

6. **TPM access requires both**:
   - User in `tss` group
   - Compatible tpm2-tss version (3.2.0-1 for Intune)

---

## 🚀 Quick Recovery Checklist

If Intune breaks after system updates:

- [ ] Verify login keyring collection exists
- [ ] Check tpm2-tss is still 3.2.0-1
- [ ] Verify openssl_shim wrappers are in place
- [ ] Check lsb_release is disabled
- [ ] Ensure user is in tss group
- [ ] Verify GNOME_KEYRING_CONTROL environment is set
- [ ] Check intune-daemon.service is running
- [ ] Verify microsoft-identity-device-broker.service is running

---

## 🙏 Credits

- OpenSSL shim concept from your local PKGBUILD
- tpm2-tss downgrade requirement from AUR comments
- Login keyring requirement discovered through libsecret error analysis
- Microsoft Identity Broker version insights from AUR user comments

---

## 📝 Notes

This was a complex multi-layered issue. The primary cause was the **missing login keyring collection**, but it was masked by several other issues:
- Corrupted keyring files
- lsb_release breaking the Ubuntu spoof  
- Missing TPM access
- OpenSSL compatibility

Each fix built upon the previous one. The authentication could only work once the keyring was fixed. The enrollment could only work once authentication was working AND the OpenSSL shim was in place AND TPM access was granted.

**Total debugging time**: ~3 hours
**Number of error codes encountered**: 5 unique tags
**Critical fix**: Creating /org/freedesktop/secrets/collection/login
**Most helpful tool**: journalctl with correlation ID tracking

---

**Status**: ✅ FULLY WORKING
**Last Updated**: 2025-10-31
**Configuration Committed**: Yes (commit bf76f88)
