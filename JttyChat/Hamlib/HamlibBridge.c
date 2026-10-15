#include "HamlibBridge.h"

#include <hamlib/rig.h>

#include <ctype.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdarg.h>
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

// MARK: - Logging

static JttyLogHandler logHandler = NULL;
static int debugLevel = RIG_DEBUG_TRACE;

void jttyrig_set_log_handler(JttyLogHandler handler)
{
    logHandler = handler;
}

// Logs one of JttyChat's own messages (as opposed to one from Hamlib).
static void appLog(int level, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static void appLog(int level, const char *fmt, ...)
{
    const JttyLogHandler handler = logHandler;
    if (!handler)
        return;

    char *message = NULL;
    va_list ap;
    va_start(ap, fmt);
    const int length = vasprintf(&message, fmt, ap);
    va_end(ap);
    if (length >= 0 && message) {
        handler(level, message, true);
        free(message);
    }
}

// Installed with rig_set_debug_callback(); Hamlib has already filtered by
// debug level before calling this.
static int hamlibDebugCallback(enum rig_debug_level_e level, rig_ptr_t arg, const char *fmt,
                               va_list ap)
{
    (void)arg;
    const JttyLogHandler handler = logHandler;
    if (!handler)
        return 0;

    char *message = NULL;
    if (vasprintf(&message, fmt, ap) >= 0 && message) {
        handler((int)level, message, false);
        free(message);
    }
    return 0;
}

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
    __typeof__(rig_set_debug_callback) *rig_set_debug_callback;
    __typeof__(rig_load_all_backends) *rig_load_all_backends;
    __typeof__(rig_list_foreach) *rig_list_foreach;
    __typeof__(rig_init) *rig_init;
    __typeof__(rig_open) *rig_open;
    __typeof__(rig_close) *rig_close;
    __typeof__(rig_cleanup) *rig_cleanup;
    __typeof__(rig_token_lookup) *rig_token_lookup;
    __typeof__(rig_set_conf) *rig_set_conf;
    // Fallback for libraries without rig_get_conf2(); spelled out rather
    // than __typeof__'d because the header marks it deprecated.
    int (*rig_get_conf)(RIG *rig, hamlib_token_t token, char *val);
    __typeof__(rig_get_conf2) *rig_get_conf2; // Optional; only in newer Hamlib 4.x.
    __typeof__(rig_get_freq) *rig_get_freq;
    __typeof__(rig_set_freq) *rig_set_freq;
    __typeof__(rig_get_mode) *rig_get_mode;
    __typeof__(rig_set_mode) *rig_set_mode;
    __typeof__(rig_parse_mode) *rig_parse_mode;
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
    RESOLVE(rig_set_debug_callback)
    RESOLVE(rig_load_all_backends)
    RESOLVE(rig_list_foreach)
    RESOLVE(rig_init)
    RESOLVE(rig_open)
    RESOLVE(rig_close)
    RESOLVE(rig_cleanup)
    RESOLVE(rig_token_lookup)
    RESOLVE(rig_set_conf)
    RESOLVE(rig_get_conf)
    RESOLVE(rig_get_freq)
    RESOLVE(rig_set_freq)
    RESOLVE(rig_get_mode)
    RESOLVE(rig_set_mode)
    RESOLVE(rig_parse_mode)
    RESOLVE(rig_set_ptt)
    RESOLVE(rig_strrmode)
    RESOLVE(rigerror)
#undef RESOLVE

    api->rigerror2 = (__typeof__(api->rigerror2))dlsym(handle, "rigerror2");
    api->rig_get_conf2 = (__typeof__(api->rig_get_conf2))dlsym(handle, "rig_get_conf2");
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
        if (!handle) {
            appLog(RIG_DEBUG_VERBOSE, "Hamlib not loaded from %s: %s", kHamlibCandidates[i],
                   dlerror());
            continue;
        }

        // Two paths can resolve to the same image (e.g. Homebrew's opt/
        // and lib/ symlinks); dlopen hands back the same handle for both.
        if (handle == bestHandle) {
            dlclose(handle);
            continue;
        }

        struct HamlibAPI api = {0};
        const char *version = versionOfLibrary(handle);
        if (!version || !resolveAPI(handle, &api)) {
            appLog(RIG_DEBUG_WARN, "Ignoring %s: not a usable Hamlib (missing symbols)",
                   kHamlibCandidates[i]);
            dlclose(handle);
            continue;
        }
        appLog(RIG_DEBUG_VERBOSE, "Found %s at %s", version, kHamlibCandidates[i]);

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

    if (!bestHandle) {
        appLog(RIG_DEBUG_ERR, "No usable Hamlib library found.");
        return;
    }

    hl = bestAPI;
    hlVersion = bestVersion;
    hlLoaded = true;

    // Report the real file that was loaded, not the (possibly symlinked or
    // @executable_path-relative) candidate path that found it.
    Dl_info info;
    if (dladdr((const void *)hl.rig_init, &info) && info.dli_fname)
        hlPath = strdup(info.dli_fname);
    appLog(RIG_DEBUG_VERBOSE, "Using %s from %s", hlVersion, hlPath ? hlPath : "unknown path");

    // Route Hamlib's debug output to the log handler instead of stderr.
    hl.rig_set_debug_callback(hamlibDebugCallback, NULL);
    hl.rig_set_debug((enum rig_debug_level_e)debugLevel);
}

static bool ensureHamlib(void)
{
    pthread_once(&hlOnce, loadHamlib);
    return hlLoaded;
}

void jttyrig_set_debug_level(int level)
{
    debugLevel = level;
    if (ensureHamlib())
        hl.rig_set_debug((enum rig_debug_level_e)level);
}

static const char *errorText(int retcode)
{
    return hl.rigerror2 ? hl.rigerror2(retcode) : hl.rigerror(retcode);
}

// Logs a failed Hamlib call with rigerror()'s full text, which appends
// Hamlib's saved trail of recent debug messages leading up to the error -
// much more than the one-line errorText() shown in the UI.
static void logRigError(const char *what, int retcode)
{
    // rigerror2()'s text ends in a newline; leave it off the headline.
    const char *summary = errorText(retcode);
    int summaryLength = (int)strlen(summary);
    while (summaryLength > 0 && summary[summaryLength - 1] == '\n')
        summaryLength--;

    appLog(RIG_DEBUG_ERR, "%s failed: %.*s (error %d)\nHamlib error trace:\n%s", what,
           summaryLength, summary, retcode, hl.rigerror(retcode));
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

    // Registering every backend logs a line per rig model; keep that out
    // of the log.
    hl.rig_set_debug(RIG_DEBUG_NONE);
    hl.rig_load_all_backends();

    struct RigCollectContext ctx = {0};
    hl.rig_list_foreach(collectRig, &ctx);
    hl.rig_set_debug((enum rig_debug_level_e)debugLevel);

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

// Applies serialConfig's "name=value" lines (see HamlibBridge.h) to rig.
// Failures are logged and otherwise ignored: a network rig has no serial
// line to configure, and a bad value shouldn't stop the rig opening with
// its defaults.
static void applySerialConfig(RIG *rig, const char *serialConfig)
{
    if (!serialConfig)
        return;

    char *copy = strdup(serialConfig);
    char *cursor = copy;
    char *line;
    while ((line = strsep(&cursor, "\n")) != NULL) {
        char *equals = strchr(line, '=');
        if (!equals || equals == line)
            continue;
        *equals = '\0';
        const char *name = line;
        const char *value = equals + 1;

        const int retcode = setConf(rig, name, value);
        if (retcode == RIG_OK)
            appLog(RIG_DEBUG_VERBOSE, "Set %s = %s", name, value);
        else
            appLog(RIG_DEBUG_WARN, "Couldn't set %s = %s (%s); using the rig's default", name, value,
                   errorText(retcode));
    }
    free(copy);
}

// Initializes and opens a rig, applying the given port and serial settings.
// On failure, returns NULL and fills outError; the caller owns the returned
// RIG on success and must rig_close()+rig_cleanup() it.
static RIG *openRig(int model, const char *port, const char *serialConfig, char *outError,
                     int outErrorSize)
{
    if (!ensureHamlib()) {
        snprintf(outError, (size_t)outErrorSize, "%s", kNotFoundMessage);
        return NULL;
    }

    appLog(RIG_DEBUG_VERBOSE, "Opening rig model %d on port \"%s\"", model, port ? port : "");

    RIG *rig = hl.rig_init((rig_model_t)model);
    if (!rig) {
        snprintf(outError, (size_t)outErrorSize, "Could not initialize this rig model.");
        appLog(RIG_DEBUG_ERR, "rig_init(%d) failed: %s", model, outError);
        return NULL;
    }

    if (port && port[0] != '\0') {
        const int retcode = setConf(rig, "rig_pathname", port);
        if (retcode != RIG_OK) {
            snprintf(outError, (size_t)outErrorSize, "Could not set port: %s", errorText(retcode));
            logRigError("Setting port", retcode);
            hl.rig_cleanup(rig);
            return NULL;
        }
    }

    applySerialConfig(rig, serialConfig);

    const int retcode = hl.rig_open(rig);
    if (retcode != RIG_OK) {
        snprintf(outError, (size_t)outErrorSize, "Connection failed: %s", errorText(retcode));
        logRigError("rig_open", retcode);
        hl.rig_cleanup(rig);
        return NULL;
    }
    appLog(RIG_DEBUG_VERBOSE, "Rig opened.");
    return rig;
}

// Sets the current VFO's mode by Hamlib name (e.g. "PKTUSB"), leaving the
// passband alone. A NULL or empty mode does nothing. On failure, fills
// outError and returns false.
static bool setMode(RIG *rig, const char *mode, char *outError, int outErrorSize)
{
    if (!mode || mode[0] == '\0')
        return true;

    const rmode_t parsed = hl.rig_parse_mode(mode);
    if (parsed == RIG_MODE_NONE) {
        snprintf(outError, (size_t)outErrorSize, "Unknown mode \"%s\".", mode);
        appLog(RIG_DEBUG_ERR, "rig_parse_mode(\"%s\") failed", mode);
        return false;
    }

    appLog(RIG_DEBUG_VERBOSE, "Setting mode to %s", mode);
    const int retcode = hl.rig_set_mode(rig, RIG_VFO_CURR, parsed, RIG_PASSBAND_NOCHANGE);
    if (retcode != RIG_OK) {
        snprintf(outError, (size_t)outErrorSize, "Set mode %s failed: %s", mode, errorText(retcode));
        logRigError("rig_set_mode", retcode);
        return false;
    }
    return true;
}

bool jttyrig_connect_and_query(int model, const char *port, const char *serialConfig, const char *mode,
                                char *outMessage, int outMessageSize)
{
    RIG *rig = openRig(model, port, serialConfig, outMessage, outMessageSize);
    if (!rig)
        return false;

    if (!setMode(rig, mode, outMessage, outMessageSize)) {
        hl.rig_close(rig);
        hl.rig_cleanup(rig);
        return false;
    }

    freq_t freq = 0;
    int retcode = hl.rig_get_freq(rig, RIG_VFO_CURR, &freq);
    if (retcode != RIG_OK) {
        snprintf(outMessage, (size_t)outMessageSize, "Connected, but could not read frequency: %s",
                  errorText(retcode));
        logRigError("rig_get_freq", retcode);
        hl.rig_close(rig);
        hl.rig_cleanup(rig);
        return false;
    }

    rmode_t currentMode = RIG_MODE_NONE;
    pbwidth_t width = 0;
    const int modeRetcode = hl.rig_get_mode(rig, RIG_VFO_CURR, &currentMode, &width);
    if (modeRetcode != RIG_OK)
        logRigError("rig_get_mode", modeRetcode);

    hl.rig_close(rig);
    hl.rig_cleanup(rig);

    char modeText[64];
    if (modeRetcode == RIG_OK && currentMode != RIG_MODE_NONE) {
        if (width > 0)
            snprintf(modeText, sizeof(modeText), "%s (%ld Hz)", hl.rig_strrmode(currentMode), (long)width);
        else
            snprintf(modeText, sizeof(modeText), "%s", hl.rig_strrmode(currentMode));
    } else {
        snprintf(modeText, sizeof(modeText), "unknown mode");
    }

    snprintf(outMessage, (size_t)outMessageSize, "%.6f MHz  %s", freq / 1.0e6, modeText);
    appLog(RIG_DEBUG_VERBOSE, "Rig reports %s", outMessage);
    return true;
}

bool jttyrig_set_ptt(int model, const char *port, const char *serialConfig, bool on, char *outError,
                      int outErrorSize)
{
    RIG *rig = openRig(model, port, serialConfig, outError, outErrorSize);
    if (!rig)
        return false;

    appLog(RIG_DEBUG_VERBOSE, "Setting PTT %s", on ? "on" : "off");
    const int retcode = hl.rig_set_ptt(rig, RIG_VFO_CURR, on ? RIG_PTT_ON : RIG_PTT_OFF);
    hl.rig_close(rig);
    hl.rig_cleanup(rig);

    if (retcode != RIG_OK) {
        snprintf(outError, (size_t)outErrorSize, "PTT %s failed: %s", on ? "on" : "off",
                  errorText(retcode));
        logRigError(on ? "rig_set_ptt(on)" : "rig_set_ptt(off)", retcode);
        return false;
    }
    return true;
}

bool jttyrig_set_frequency(int model, const char *port, const char *serialConfig, double freqHz,
                            const char *mode, char *outError, int outErrorSize)
{
    RIG *rig = openRig(model, port, serialConfig, outError, outErrorSize);
    if (!rig)
        return false;

    appLog(RIG_DEBUG_VERBOSE, "Setting frequency to %.6f MHz", freqHz / 1.0e6);
    const int retcode = hl.rig_set_freq(rig, RIG_VFO_CURR, freqHz);
    if (retcode != RIG_OK) {
        snprintf(outError, (size_t)outErrorSize, "Set frequency failed: %s", errorText(retcode));
        logRigError("rig_set_freq", retcode);
        hl.rig_close(rig);
        hl.rig_cleanup(rig);
        return false;
    }

    // After the frequency, since some rigs pick a band's last-used mode
    // when they change band.
    const bool modeSet = setMode(rig, mode, outError, outErrorSize);
    hl.rig_close(rig);
    hl.rig_cleanup(rig);
    return modeSet;
}

// MARK: - Modes

bool jttyrig_list_modes(int model, char *outModes, int outModesSize)
{
    if (outModesSize <= 0)
        return false;
    outModes[0] = '\0';
    if (!ensureHamlib())
        return false;

    // As in jttyrig_get_default_conf: only a lookup, so keep rig_init()'s
    // trace output out of the Hamlib Log.
    hl.rig_set_debug(RIG_DEBUG_NONE);
    RIG *rig = hl.rig_init((rig_model_t)model);
    if (!rig) {
        hl.rig_set_debug((enum rig_debug_level_e)debugLevel);
        return false;
    }

    // Every mode any of the model's (first two regions') receive or
    // transmit frequency ranges allows. These lists sit early in
    // rig_caps, where Hamlib 4.x keeps its layout stable.
    const struct rig_caps *caps = rig->caps;
    const freq_range_t *lists[] = {caps->rx_range_list1, caps->tx_range_list1, caps->rx_range_list2,
                                   caps->tx_range_list2};
    rmode_t modes = RIG_MODE_NONE;
    for (size_t l = 0; l < sizeof(lists) / sizeof(lists[0]); l++) {
        for (int i = 0; i < HAMLIB_FRQRANGESIZ && !RIG_IS_FRNG_END(lists[l][i]); i++)
            modes |= lists[l][i].modes;
    }

    size_t used = 0;
    for (int bit = 0; bit < 64; bit++) {
        const rmode_t mode = CONSTANT_64BIT_FLAG(bit);
        if (!(modes & mode))
            continue;
        const char *name = hl.rig_strrmode(mode);
        if (!name || name[0] == '\0')
            continue;
        const int written = snprintf(outModes + used, (size_t)outModesSize - used, "%s\n", name);
        if (written < 0 || used + (size_t)written >= (size_t)outModesSize)
            break;
        used += (size_t)written;
    }

    hl.rig_cleanup(rig);
    hl.rig_set_debug((enum rig_debug_level_e)debugLevel);
    return true;
}

// MARK: - Defaults

bool jttyrig_get_default_conf(int model, const char *names, char *outValues, int outValuesSize)
{
    if (outValuesSize <= 0)
        return false;
    outValues[0] = '\0';
    if (!ensureHamlib() || !names)
        return false;

    // rig_init() logs a couple of dozen lines at Trace level; this is only
    // a lookup, so keep it out of the Hamlib Log.
    hl.rig_set_debug(RIG_DEBUG_NONE);
    RIG *rig = hl.rig_init((rig_model_t)model);
    if (!rig) {
        hl.rig_set_debug((enum rig_debug_level_e)debugLevel);
        return false;
    }

    char *copy = strdup(names);
    char *cursor = copy;
    char *name;
    size_t used = 0;
    while ((name = strsep(&cursor, "\n")) != NULL) {
        if (name[0] == '\0')
            continue;

        // Sized well beyond any serial setting's value; rig_get_conf()
        // (for libraries without rig_get_conf2()) has no length argument.
        char value[256] = "";
        const hamlib_token_t token = hl.rig_token_lookup(rig, name);
        if (token != RIG_CONF_END) {
            if (hl.rig_get_conf2)
                hl.rig_get_conf2(rig, token, value, (int)sizeof(value));
            else
                hl.rig_get_conf(rig, token, value);
        }

        const int written = snprintf(outValues + used, (size_t)outValuesSize - used, "%s\n", value);
        if (written < 0 || used + (size_t)written >= (size_t)outValuesSize)
            break;
        used += (size_t)written;
    }
    free(copy);

    hl.rig_cleanup(rig);
    hl.rig_set_debug((enum rig_debug_level_e)debugLevel);
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
