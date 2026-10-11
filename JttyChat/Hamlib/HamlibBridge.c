#include "HamlibBridge.h"

#include <hamlib/rig.h>

#include <ctype.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

// Ported from JttyChatLinux/src/HamlibRigs.cpp, replacing Qt types (QList,
// QString) with plain C buffers/malloc so this can be called from Swift
// through HamlibBridge.h without exposing any Hamlib or Qt type to Swift.
//
// Hamlib isn't linked at build time. Instead, the first call into this file
// dlopen()s every libhamlib it can find - the copy embedded in the app's
// Frameworks folder plus the usual Homebrew/MacPorts/Fink locations - and
// keeps whichever reports the newest version. <hamlib/rig.h> is only used
// for types and to declare the function pointers below.

// MARK: - Dynamic loading

// Places to look for Hamlib, in order of preference when two copies report
// the same version (so the embedded copy wins a tie).
static const char *const kHamlibCandidates[] = {
    "@executable_path/../Frameworks/libhamlib.4.dylib",
    "/opt/homebrew/opt/hamlib/lib/libhamlib.dylib",
    "/opt/homebrew/lib/libhamlib.dylib",
    "/usr/local/opt/hamlib/lib/libhamlib.dylib",
    "/usr/local/lib/libhamlib.dylib",
    "/opt/local/lib/libhamlib.dylib", // MacPorts
    "/sw/lib/libhamlib.dylib",         // Fink
};

// Every Hamlib entry point used in this file, resolved with dlsym().
struct HamlibAPI {
    __typeof__(rig_set_debug) *rig_set_debug;
    __typeof__(rig_load_all_backends) *rig_load_all_backends;
    __typeof__(rig_list_foreach) *rig_list_foreach;
    __typeof__(rig_init) *rig_init;
    __typeof__(rig_open) *rig_open;
    __typeof__(rig_close) *rig_close;
    __typeof__(rig_cleanup) *rig_cleanup;
    __typeof__(rig_token_lookup) *rig_token_lookup;
    __typeof__(rig_set_conf) *rig_set_conf;
    __typeof__(rig_get_freq) *rig_get_freq;
    __typeof__(rig_set_freq) *rig_set_freq;
    __typeof__(rig_get_mode) *rig_get_mode;
    __typeof__(rig_set_ptt) *rig_set_ptt;
    __typeof__(rig_strrmode) *rig_strrmode;
    __typeof__(rigerror) *rigerror;
    __typeof__(rigerror2) *rigerror2; // Optional; only in newer Hamlib 4.x.
};

static struct HamlibAPI hl;
static bool hlLoaded = false;
static const char *hlVersion = NULL;
static char *hlPath = NULL;
static pthread_once_t hlOnce = PTHREAD_ONCE_INIT;

// Reads the version string out of an opened library: the long form
// ("Hamlib 4.7.2 2026-06-21T13:07:37Z SHA=...") if present, else the short
// one ("Hamlib 4.7.2").
static const char *versionOfLibrary(void *handle)
{
    const char *const *version2 = dlsym(handle, "hamlib_version2");
    if (version2 && *version2)
        return *version2;
    return dlsym(handle, "hamlib_version");
}

// Parses up to four numeric components ("4.7.2" -> {4, 7, 2, 0}) out of a
// version string, starting at its first digit.
static void parseVersion(const char *version, long out[4])
{
    memset(out, 0, sizeof(long) * 4);
    const char *p = version;
    while (*p && !isdigit((unsigned char)*p))
        p++;
    for (int i = 0; i < 4 && isdigit((unsigned char)*p); i++) {
        char *end = NULL;
        out[i] = strtol(p, &end, 10);
        p = end;
        if (*p != '.')
            break;
        p++;
    }
}

static int compareVersions(const char *a, const char *b)
{
    long va[4], vb[4];
    parseVersion(a, va);
    parseVersion(b, vb);
    for (int i = 0; i < 4; i++) {
        if (va[i] != vb[i])
            return va[i] < vb[i] ? -1 : 1;
    }
    return 0;
}

// Resolves every required symbol from handle into api. Returns false if any
// is missing, in which case this library can't be used.
static bool resolveAPI(void *handle, struct HamlibAPI *api)
{
#define RESOLVE(name)                                    \
    api->name = (__typeof__(api->name))dlsym(handle, #name); \
    if (!api->name)                                      \
        return false;

    RESOLVE(rig_set_debug)
    RESOLVE(rig_load_all_backends)
    RESOLVE(rig_list_foreach)
    RESOLVE(rig_init)
    RESOLVE(rig_open)
    RESOLVE(rig_close)
    RESOLVE(rig_cleanup)
    RESOLVE(rig_token_lookup)
    RESOLVE(rig_set_conf)
    RESOLVE(rig_get_freq)
    RESOLVE(rig_set_freq)
    RESOLVE(rig_get_mode)
    RESOLVE(rig_set_ptt)
    RESOLVE(rig_strrmode)
    RESOLVE(rigerror)
#undef RESOLVE

    api->rigerror2 = (__typeof__(api->rigerror2))dlsym(handle, "rigerror2");
    return true;
}

static void loadHamlib(void)
{
    void *bestHandle = NULL;
    const char *bestVersion = NULL;
    struct HamlibAPI bestAPI = {0};

    const size_t candidateCount = sizeof(kHamlibCandidates) / sizeof(kHamlibCandidates[0]);
    for (size_t i = 0; i < candidateCount; i++) {
        // RTLD_LOCAL keeps each copy's symbols out of the global namespace,
        // so several versions can be open side by side while we compare.
        void *handle = dlopen(kHamlibCandidates[i], RTLD_LAZY | RTLD_LOCAL);
        if (!handle)
            continue;

        // Two paths can resolve to the same image (e.g. Homebrew's opt/
        // and lib/ symlinks); dlopen hands back the same handle for both.
        if (handle == bestHandle) {
            dlclose(handle);
            continue;
        }

        struct HamlibAPI api = {0};
        const char *version = versionOfLibrary(handle);
        if (!version || !resolveAPI(handle, &api)) {
            dlclose(handle);
            continue;
        }

        if (!bestHandle || compareVersions(version, bestVersion) > 0) {
            if (bestHandle)
                dlclose(bestHandle);
            bestHandle = handle;
            bestVersion = version;
            bestAPI = api;
        } else {
            dlclose(handle);
        }
    }

    if (!bestHandle)
        return;

    hl = bestAPI;
    hlVersion = bestVersion;
    hlLoaded = true;

    // Report the real file that was loaded, not the (possibly symlinked or
    // @executable_path-relative) candidate path that found it.
    Dl_info info;
    if (dladdr((const void *)hl.rig_init, &info) && info.dli_fname)
        hlPath = strdup(info.dli_fname);

    // Hamlib logs a line per backend as it loads them; we don't want that
    // on stdout/stderr every time the app starts.
    hl.rig_set_debug(RIG_DEBUG_NONE);
}

static bool ensureHamlib(void)
{
    pthread_once(&hlOnce, loadHamlib);
    return hlLoaded;
}

static const char *errorText(int retcode)
{
    return hl.rigerror2 ? hl.rigerror2(retcode) : hl.rigerror(retcode);
}

static const char *const kNotFoundMessage = "Hamlib library not found.";

// MARK: - Rig list

struct RigCollectContext {
    JttyRigInfo *items;
    int count;
    int capacity;
};

static int collectRig(const struct rig_caps *caps, rig_ptr_t data)
{
    struct RigCollectContext *ctx = (struct RigCollectContext *)data;
    if (ctx->count == ctx->capacity) {
        ctx->capacity = ctx->capacity == 0 ? 64 : ctx->capacity * 2;
        ctx->items = realloc(ctx->items, sizeof(JttyRigInfo) * (size_t)ctx->capacity);
    }

    char label[256];
    snprintf(label, sizeof(label), "%s %s", caps->mfg_name, caps->model_name);
    ctx->items[ctx->count].model = (int)caps->rig_model;
    ctx->items[ctx->count].label = strdup(label);
    ctx->count++;
    return 1; // non-zero: keep iterating
}

static int compareRigs(const void *a, const void *b)
{
    const JttyRigInfo *ra = (const JttyRigInfo *)a;
    const JttyRigInfo *rb = (const JttyRigInfo *)b;
    return strcasecmp(ra->label, rb->label);
}

JttyRigInfo *jttyrig_list_models(int *outCount)
{
    *outCount = 0;
    if (!ensureHamlib())
        return NULL;

    hl.rig_load_all_backends();

    struct RigCollectContext ctx = {0};
    hl.rig_list_foreach(collectRig, &ctx);

    qsort(ctx.items, (size_t)ctx.count, sizeof(JttyRigInfo), compareRigs);
    *outCount = ctx.count;
    return ctx.items;
}

void jttyrig_free_list(JttyRigInfo *list, int count)
{
    if (!list)
        return;
    for (int i = 0; i < count; ++i)
        free(list[i].label);
    free(list);
}

// MARK: - Rig control

// Sets a Hamlib configuration parameter by name. Going through
// rig_set_conf() rather than poking rig->state directly keeps this working
// across Hamlib versions whose RIG struct layouts differ.
static int setConf(RIG *rig, const char *name, const char *value)
{
    const hamlib_token_t token = hl.rig_token_lookup(rig, name);
    if (token == RIG_CONF_END)
        return -RIG_EINVAL;
    return hl.rig_set_conf(rig, token, value);
}

// Initializes and opens a rig, applying the given port/baud. On failure,
// returns NULL and fills outError; the caller owns the returned RIG on
// success and must rig_close()+rig_cleanup() it.
static RIG *openRig(int model, const char *port, const char *baudRate, char *outError,
                     int outErrorSize)
{
    if (!ensureHamlib()) {
        snprintf(outError, (size_t)outErrorSize, "%s", kNotFoundMessage);
        return NULL;
    }

    RIG *rig = hl.rig_init((rig_model_t)model);
    if (!rig) {
        snprintf(outError, (size_t)outErrorSize, "Could not initialize this rig model.");
        return NULL;
    }

    if (port && port[0] != '\0') {
        const int retcode = setConf(rig, "rig_pathname", port);
        if (retcode != RIG_OK) {
            snprintf(outError, (size_t)outErrorSize, "Could not set port: %s", errorText(retcode));
            hl.rig_cleanup(rig);
            return NULL;
        }
    }

    // "Default" (or anything non-numeric) leaves the backend's default.
    // Errors are ignored: network rigs have no serial speed to set.
    if (baudRate && baudRate[0] != '\0') {
        char *end = NULL;
        strtol(baudRate, &end, 10);
        if (end != baudRate && *end == '\0')
            setConf(rig, "serial_speed", baudRate);
    }

    const int retcode = hl.rig_open(rig);
    if (retcode != RIG_OK) {
        snprintf(outError, (size_t)outErrorSize, "Connection failed: %s", errorText(retcode));
        hl.rig_cleanup(rig);
        return NULL;
    }
    return rig;
}

bool jttyrig_connect_and_query(int model, const char *port, const char *baudRate,
                                char *outMessage, int outMessageSize)
{
    RIG *rig = openRig(model, port, baudRate, outMessage, outMessageSize);
    if (!rig)
        return false;

    freq_t freq = 0;
    int retcode = hl.rig_get_freq(rig, RIG_VFO_CURR, &freq);
    if (retcode != RIG_OK) {
        snprintf(outMessage, (size_t)outMessageSize, "Connected, but could not read frequency: %s",
                  errorText(retcode));
        hl.rig_close(rig);
        hl.rig_cleanup(rig);
        return false;
    }

    rmode_t mode = RIG_MODE_NONE;
    pbwidth_t width = 0;
    const int modeRetcode = hl.rig_get_mode(rig, RIG_VFO_CURR, &mode, &width);

    hl.rig_close(rig);
    hl.rig_cleanup(rig);

    char modeText[64];
    if (modeRetcode == RIG_OK && mode != RIG_MODE_NONE) {
        if (width > 0)
            snprintf(modeText, sizeof(modeText), "%s (%ld Hz)", hl.rig_strrmode(mode), (long)width);
        else
            snprintf(modeText, sizeof(modeText), "%s", hl.rig_strrmode(mode));
    } else {
        snprintf(modeText, sizeof(modeText), "unknown mode");
    }

    snprintf(outMessage, (size_t)outMessageSize, "%.6f MHz  %s", freq / 1.0e6, modeText);
    return true;
}

bool jttyrig_set_ptt(int model, const char *port, const char *baudRate, bool on, char *outError,
                      int outErrorSize)
{
    RIG *rig = openRig(model, port, baudRate, outError, outErrorSize);
    if (!rig)
        return false;

    const int retcode = hl.rig_set_ptt(rig, RIG_VFO_CURR, on ? RIG_PTT_ON : RIG_PTT_OFF);
    hl.rig_close(rig);
    hl.rig_cleanup(rig);

    if (retcode != RIG_OK) {
        snprintf(outError, (size_t)outErrorSize, "PTT %s failed: %s", on ? "on" : "off",
                  errorText(retcode));
        return false;
    }
    return true;
}

bool jttyrig_set_frequency(int model, const char *port, const char *baudRate, double freqHz,
                            char *outError, int outErrorSize)
{
    RIG *rig = openRig(model, port, baudRate, outError, outErrorSize);
    if (!rig)
        return false;

    const int retcode = hl.rig_set_freq(rig, RIG_VFO_CURR, freqHz);
    hl.rig_close(rig);
    hl.rig_cleanup(rig);

    if (retcode != RIG_OK) {
        snprintf(outError, (size_t)outErrorSize, "Set frequency failed: %s", errorText(retcode));
        return false;
    }
    return true;
}

// MARK: - Library info

const char *jttyrig_hamlib_version(void)
{
    return ensureHamlib() ? hlVersion : NULL;
}

const char *jttyrig_hamlib_path(void)
{
    return ensureHamlib() ? hlPath : NULL;
}
