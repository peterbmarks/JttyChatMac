#ifndef JttyCodecBridge_h
#define JttyCodecBridge_h

#include <stdbool.h>
#include <stdint.h>

// C declarations for the JTTY mode codec's Fortran entry points (see
// ../../../ThirdParty/jtty_codec, copied unmodified from wsjtx-3.2.0-rc1's
// lib/jtty). Statically linked via OTHER_LDFLAGS (see
// ThirdParty/jtty_codec/lib/libjttycodec.a and build.sh); Xcode has no
// Fortran compiler, so these sources aren't part of this target.
//
// gfortran (built with -fno-second-underscore, matching build.sh) mangles
// plain subroutine/function names to a single trailing underscore, and
// appends one hidden `long` length argument per CHARACTER dummy argument,
// in order, after all other arguments. jtty_release_fft_resources is the
// one exception: it's declared `bind(C)` in Fortran, so it keeps its exact
// name and has no hidden arguments.

#ifdef __cplusplus
extern "C" {
#endif

// Encodes text to channel-symbol tones. msg is a fixed 80-byte buffer,
// space-padded, normalized in place by the codec; msgLength must be 80.
void genjtty_profile_(char *msg, const int32_t *exchangeProfile, int32_t itone[], int32_t *nsym,
                       long msgLength);

// Renders channel-symbol tones to a GFSK audio waveform. cwave and wave may
// point at the same buffer (the caller only wants the real output).
void gen_jttywave_(int32_t itone[], int32_t *nsym, int32_t *nsps, float *bt, float *fsample,
                    float *f0, float cwave[], float wave[], int32_t *icmplx, int32_t *nwave);

// Scans a growing receive buffer (iwave, length *kz) for JTTY frames,
// resuming from where it left off each call (see JttyDecoder.swift).
void rjtty_sub_(int16_t iwave[], int32_t *kz, int32_t *nsps, int32_t *nfa, int32_t *nfb,
                 float *f0, float *ftol);

// Drains up to 30 completed/updated messages per call; call repeatedly
// while *count comes back equal to the batch size (30). textBlocks must be
// 30*80 bytes; textBlocksLength must be that size. snrDb is the latest
// frame's raw tone-power SNR; symbolErrors/symbolsChecked are hard symbol
// error totals over the message so far (all three added locally to the
// otherwise-unmodified codec).
void jtty_get_updates_(char textBlocks[], int64_t messageIds[], float frequencies[],
                        float startTsync[], bool eom[], float snrDb[], int32_t symbolErrors[],
                        int32_t symbolsChecked[], int32_t *count, long textBlocksLength);

// Releases the decoder's cached FFT plans/buffers. Safe to call once at
// shutdown.
void jtty_release_fft_resources(void);

#ifdef __cplusplus
}
#endif

#endif /* JttyCodecBridge_h */
