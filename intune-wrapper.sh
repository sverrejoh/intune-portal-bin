#!/bin/bash
# Wrapper script for Microsoft Intune binaries with compatibility fixes

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check if webkit2gtk-noassert is installed
WEBKIT_NOASSERT_AVAILABLE=0
if [ -d "/opt/webkit2gtk-noassert/lib" ]; then
    export LD_LIBRARY_PATH="/opt/webkit2gtk-noassert/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export GI_TYPELIB_PATH="/opt/webkit2gtk-noassert/lib/girepository-1.0${GI_TYPELIB_PATH:+:$GI_TYPELIB_PATH}"
    WEBKIT_NOASSERT_AVAILABLE=1
fi

# Set up LD_PRELOAD with our compatibility shims
# Always use OpenSSL shim
SHIMS="/opt/microsoft/intune/lib/openssl_shim.so"

# Only use webkit_uri_shim if webkit2gtk-noassert is NOT available
# (webkit2gtk-noassert handles duplicate registrations properly)
if [ $WEBKIT_NOASSERT_AVAILABLE -eq 0 ]; then
    SHIMS="${SHIMS}:/opt/microsoft/intune/lib/webkit_uri_shim.so"
fi

export LD_PRELOAD="${SHIMS}:${LD_PRELOAD}"

# Get the original binary name (this wrapper replaces intune-portal and intune-agent)
BINARY_NAME="$(basename "$0")"

# Execute the original binary
exec "${SCRIPT_DIR}/${BINARY_NAME}.original" "$@"