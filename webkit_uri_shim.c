#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

// Global flag to track if oneauth has been registered
static int oneauth_registered = 0;

// WebKit2 function type
typedef void (*webkit_web_context_register_uri_scheme_func)(void*, const char*, void*, void*, void*);

// Override webkit_web_context_register_uri_scheme
void webkit_web_context_register_uri_scheme(void* context, const char* scheme,
                                           void* callback, void* user_data, void* destroy) {
    static webkit_web_context_register_uri_scheme_func original_func = NULL;

    if (!original_func) {
        original_func = (webkit_web_context_register_uri_scheme_func)dlsym(RTLD_NEXT, "webkit_web_context_register_uri_scheme");
    }

    // Check if this is oneauth
    if (scheme && strcmp(scheme, "oneauth") == 0) {
        if (oneauth_registered) {
            fprintf(stderr, "webkit_uri_shim: Blocking duplicate oneauth registration\n");
            return; // Just return without doing anything
        }
        oneauth_registered = 1;
        fprintf(stderr, "webkit_uri_shim: Allowing first oneauth registration\n");
    }

    if (original_func) {
        original_func(context, scheme, callback, user_data, destroy);
    }
}