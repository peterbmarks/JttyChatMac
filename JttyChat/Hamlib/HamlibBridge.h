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

#ifdef __cplusplus
}
#endif

#endif /* HamlibBridge_h */
