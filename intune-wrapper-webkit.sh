#!/bin/bash
# Wrapper script for Microsoft Intune binaries with compatibility fixes

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Set up LD_PRELOAD with both OpenSSL and WebKit compatibility shims
export LD_PRELOAD="/opt/microsoft/intune/lib/openssl_shim.so:/opt/microsoft/intune/lib/webkit_uri_shim.so:${LD_PRELOAD}"

# Get the original binary name (this wrapper replaces intune-portal and intune-agent)
BINARY_NAME="$(basename "$0")"

# Execute the original binary
exec "${SCRIPT_DIR}/${BINARY_NAME}.original" "$@"