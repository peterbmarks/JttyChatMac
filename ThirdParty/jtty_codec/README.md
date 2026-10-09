# jtty_codec (ported from JttyChatLinux)

The Fortran sources here are copied from `JttyChatLinux/thirdparty/jtty_codec`
(see `NOTICE.txt` / `COPYING`), which itself copied them unmodified from the JTTY mode
codec in a WSJT-X fork. They implement the JTTY encode/decode DSP engine that
`JttyChat/Jtty/JttyCodec.swift` and `JttyChat/Jtty/JttyDecoder.swift` call into.

Local changes (marked `JttyChat:` in the source): `jtty_mdecode.f90` and `rjtty_sub.f90`
carry each message's SNR and hard symbol-error counts through to `jtty_get_updates`,
which has three extra output arrays for them.

Xcode has no built-in Fortran compiler, so these files aren't part of the JttyChat
Xcode target and aren't compiled by Xcode. Instead, `build.sh` compiles them with
Homebrew's `gfortran` into `lib/libjttycodec.a`, a prebuilt static library that the
JttyChat target links directly (see its `OTHER_LDFLAGS` build setting). Run
`./build.sh` again after changing a source file, or after cloning this repo fresh
(the built `lib/libjttycodec.a` is committed so a working build doesn't strictly
require gfortran, but regenerate it if in doubt).

Build dependencies: `brew install gcc` (for `gfortran`).
