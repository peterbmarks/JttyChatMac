#ifndef HamlibBridge_h
#define HamlibBridge_h

#include <stdbool.h>

// Thin, Swift-friendly C wrapper around Hamlib (see HamlibBridge.c), ported
// from JttyChatLinux/src/HamlibRigs.{h,cpp}. Keeps every Hamlib struct and
// type out of the bridging header - Swift only ever sees plain C types.

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int model;        // Hamlib rig model id, as used by rig_init().
    char *label;       // "Manufacturer Model", malloc'd; owned by the list.
} JttyRigInfo;

// All transceiver models Hamlib knows how to talk to, sorted by label.
// *outCount receives the number of entries. Free the result with
// jttyrig_free_list. Slow on first call (loads every Hamlib backend); cheap
// to call repeatedly after that, since Hamlib caches its backend registry.
JttyRigInfo *jttyrig_list_models(int *outCount);
void jttyrig_free_list(JttyRigInfo *list, int count);

// Opens the given rig model on the given port (a serial device path, or a
// "host:port" address for the "Hamlib NET rigctl" model), reads its current
// frequency and mode, then closes it again. baudRate is one of the strings
// offered by the Settings window's baud rate menu ("Default" to leave it at
// the rig backend's default). Blocks for as long as Hamlib takes to open
// the port and respond (or time out) - call this off the main thread.
//
// On success, fills outMessage with "<freq> MHz  <mode>" and returns true.
// On failure, fills outMessage with an error description and returns
// false. outMessage must be a caller-supplied buffer of outMessageSize
// bytes.
bool jttyrig_connect_and_query(int model, const char *port, const char *baudRate,
                                char *outMessage, int outMessageSize);

// Opens the rig just long enough to key or unkey PTT, then closes it again.
// Meant to run off the main thread. Returns true on success; on failure,
// fills outError (a caller-supplied buffer) and returns false.
bool jttyrig_set_ptt(int model, const char *port, const char *baudRate, bool on, char *outError,
                      int outErrorSize);

// Opens the rig just long enough to set its current VFO frequency (in Hz),
// then closes it again. Meant to run off the main thread. Returns true on
// success; on failure, fills outError and returns false.
bool jttyrig_set_frequency(int model, const char *port, const char *baudRate, double freqHz,
                            char *outError, int outErrorSize);

// Hamlib is loaded at runtime on first use: the copy embedded in the app
// bundle and any externally installed copies are compared, and the newest
// is used. If none can be loaded, the calls above fail with an error and the
// two functions below return NULL.

// The full version string of the loaded Hamlib library (e.g. "Hamlib 4.7.2
// 2026-06-21T13:07:37Z SHA=..."). The returned string is owned by Hamlib.
const char *jttyrig_hamlib_version(void);

// Filesystem path of the Hamlib dynamic library that was actually loaded,
// or NULL if it can't be determined. The returned string is owned by dyld.
const char *jttyrig_hamlib_path(void);

// Receives every Hamlib debug message at or below the current debug level,
// plus JttyChat's own notes about what it's asking the rig to do
// (fromApp = true). level is a Hamlib rig_debug_level_e value (1 = bug,
// 2 = error, 3 = warning, 4 = verbose, 5 = trace, 6 = cache). message may
// span several lines. Called on whatever thread is talking to Hamlib, so
// the handler must be thread-safe; message is only valid during the call.
typedef void (*JttyLogHandler)(int level, const char *message, bool fromApp);

// Installs the log handler. Call once at startup, before any other
// jttyrig_ function, so the library search is logged too.
void jttyrig_set_log_handler(JttyLogHandler handler);

// Sets how much Hamlib logs (a rig_debug_level_e value; 0 = nothing).
void jttyrig_set_debug_level(int level);

#ifdef __cplusplus
}
#endif

#endif /* HamlibBridge_h */
