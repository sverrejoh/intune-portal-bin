#!/bin/bash
# Wrapper script for Microsoft Intune binaries with OpenSSL compatibility fix

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Set up LD_PRELOAD with OpenSSL compatibility shim
export LD_PRELOAD="/opt/microsoft/intune/lib/openssl_shim.so:${LD_PRELOAD}"

# Set GNOME_KEYRING_CONTROL for libsecret access
export GNOME_KEYRING_CONTROL=/run/user/$(id -u)/keyring

# This wrapper is installed as intune-portal, intune-agent and
# intune-daemon; each execs its own <name>.original.
BINARY_NAME="$(basename "$0")"

# Execute the original binary
exec "${SCRIPT_DIR}/${BINARY_NAME}.original" "$@"