/*
 * OpenSSL 3.5+ Compatibility Shim for Microsoft Intune
 *
 * This shim fixes a bug where Microsoft Intune calls X509_REQ_set_version()
 * with an invalid version number for Certificate Signing Requests (CSRs).
 *
 * Background:
 * - RFC 2986 defines only ONE version for CSRs: v1 (represented as value 0)
 * - X.509 certificates have versions v1(0), v2(1), v3(2), but CSRs do not
 * - OpenSSL 3.0-3.3 accepted invalid version numbers without validation
 * - OpenSSL 3.4+ (commit 264ff64) enforces RFC 2986 compliance
 * - See OpenSSL issue #20663 for details
 *
 * The bug: Intune likely calls X509_REQ_set_version(req, 1) or (req, 2)
 * thinking it needs to match the certificate version, but CSRs only have v1(0).
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>

// Define the function pointer type
typedef int (*X509_REQ_set_version_func)(void*, long);

// Override X509_REQ_set_version to intercept and fix the invalid argument
int X509_REQ_set_version(void* req, long version) {
    static X509_REQ_set_version_func original_func = NULL;

    // Load the original function if not already loaded
    if (!original_func) {
        original_func = (X509_REQ_set_version_func)dlsym(RTLD_NEXT, "X509_REQ_set_version");
    }

    // Fix invalid version values
    // RFC 2986: CSRs only support version 1 (value 0)
    // Common mistake: using X.509 certificate version numbers
    if (version != 0) {
        fprintf(stderr, "openssl_shim: Fixing invalid X509_REQ version %ld to 0 (only v1 CSRs exist per RFC 2986)\n", version);
        version = 0;
    }

    // Call the original function with the fixed version
    return original_func(req, version);
}