#include "HamlibBridge.h"

#include <hamlib/rig.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

// Ported from JttyChatLinux/src/HamlibRigs.cpp, replacing Qt types (QList,
// QString) with plain C buffers/malloc so this can be called from Swift
// through HamlibBridge.h without exposing any Hamlib or Qt type to Swift.

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
    // Hamlib logs a line per backend as it loads them; we don't want that
    // on stdout/stderr every time the app starts.
    rig_set_debug(RIG_DEBUG_NONE);
    rig_load_all_backends();

    struct RigCollectContext ctx = {0};
    rig_list_foreach(collectRig, &ctx);

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

// Initializes and opens a rig, applying the given port/baud. On failure,
// returns NULL and fills outError; the caller owns the returned RIG on
// success and must rig_close()+rig_cleanup() it.
static RIG *openRig(int model, const char *port, const char *baudRate, char *outError,
                     int outErrorSize)
{
    RIG *rig = rig_init(model);
    if (!rig) {
        snprintf(outError, (size_t)outErrorSize, "Could not initialize this rig model.");
        return NULL;
    }

    if (port && port[0] != '\0') {
        strncpy(rig->state.rigport.pathname, port, sizeof(rig->state.rigport.pathname) - 1);
        rig->state.rigport.pathname[sizeof(rig->state.rigport.pathname) - 1] = '\0';
    }

    if (baudRate && baudRate[0] != '\0') {
        char *end = NULL;
        long baud = strtol(baudRate, &end, 10);
        if (end != baudRate && *end == '\0')
            rig->state.rigport.parm.serial.rate = (int)baud;
    }

    const int retcode = rig_open(rig);
    if (retcode != RIG_OK) {
        snprintf(outError, (size_t)outErrorSize, "Connection failed: %s", rigerror2(retcode));
        rig_cleanup(rig);
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
    int retcode = rig_get_freq(rig, RIG_VFO_CURR, &freq);
    if (retcode != RIG_OK) {
        snprintf(outMessage, (size_t)outMessageSize, "Connected, but could not read frequency: %s",
                  rigerror2(retcode));
        rig_close(rig);
        rig_cleanup(rig);
        return false;
    }

    rmode_t mode = RIG_MODE_NONE;
    pbwidth_t width = 0;
    const int modeRetcode = rig_get_mode(rig, RIG_VFO_CURR, &mode, &width);

    rig_close(rig);
    rig_cleanup(rig);

    char modeText[64];
    if (modeRetcode == RIG_OK && mode != RIG_MODE_NONE) {
        if (width > 0)
            snprintf(modeText, sizeof(modeText), "%s (%ld Hz)", rig_strrmode(mode), (long)width);
        else
            snprintf(modeText, sizeof(modeText), "%s", rig_strrmode(mode));
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

    const int retcode = rig_set_ptt(rig, RIG_VFO_CURR, on ? RIG_PTT_ON : RIG_PTT_OFF);
    rig_close(rig);
    rig_cleanup(rig);

    if (retcode != RIG_OK) {
        snprintf(outError, (size_t)outErrorSize, "PTT %s failed: %s", on ? "on" : "off",
                  rigerror2(retcode));
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

    const int retcode = rig_set_freq(rig, RIG_VFO_CURR, freqHz);
    rig_close(rig);
    rig_cleanup(rig);

    if (retcode != RIG_OK) {
        snprintf(outError, (size_t)outErrorSize, "Set frequency failed: %s", rigerror2(retcode));
        return false;
    }
    return true;
}
