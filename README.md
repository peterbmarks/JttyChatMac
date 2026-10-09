# JttyChat

JttyChat is a macOS desktop chat app, styled after Messages, for the **JTTY**
amateur radio digital mode. Type a message and send it, and it's transmitted
over the air as a JTTY signal through your transceiver; messages received
from other stations appear automatically as incoming chat bubbles.

This is a native macOS/SwiftUI rewrite of an earlier Qt6/C++ Linux
implementation of the same app (previously `JttyChatLinux/` in this repo,
since removed now that everything of value has been ported here). The
JTTY encode/decode DSP engine itself is unmodified Fortran, copied from a
WSJT-X fork — see [Credits](#credits).

## Features

- A scrolling chat view with speech-bubble messages — blue/right-aligned for
  sent, grey/left-aligned for received — above a text field and Send button.
- A live waterfall spectrum strip above the chat, showing the JTTY tone band
  of the receive audio.
- **Transmit**: typed messages are encoded to a JTTY audio waveform and
  played out your chosen audio output device, keying your transceiver's PTT
  (via Hamlib) for exactly the duration of the transmission (plus a short
  lead/tail for real radios).
- **Receive**: audio from your chosen input device is continuously decoded
  in the background; completed JTTY messages appear automatically as
  received bubbles.
- A Settings window (File → Settings…) for your callsign, audio input/output
  device selection, and a Transceiver section for Hamlib rig control (rig
  model, serial port, baud rate, and a Connect button to test the link and
  show the rig's current frequency/mode).
- A Frequency menu with quick-tune buttons for common ham bands, which
  retune the rig over CAT control.

## Architecture

JttyChat is a single-target SwiftUI app (macOS only). Business logic is
split from the DSP/hardware-control code it depends on, most of which is
plain C or Fortran wrapped in a thin Swift layer:

```
JttyChat/                      SwiftUI app target
├── MyApp.swift                 App scenes: main window + Settings window + menu commands
├── ContentView.swift           Main chat window (waterfall + message list + input bar)
├── ChatViewModel.swift         Orchestrates send/receive, PTT timing, rig tuning
├── Chat/
│   ├── ChatMessage.swift        Message model
│   └── ChatBubbleView.swift     Speech-bubble SwiftUI view
├── Jtty/                       JTTY mode codec
│   ├── JttyCodecBridge.h        C declarations for the Fortran encode/decode entry points
│   ├── JttyCodec.swift          Encodes text -> 48kHz PCM waveform
│   └── JttyDecoder.swift        Feeds 12kHz PCM to the decoder, reports completed messages
├── Hamlib/                     Transceiver (CAT/PTT) control
│   ├── HamlibBridge.h/.c         C shim around libhamlib (model list, connect, PTT, set frequency)
│   └── RigController.swift      Swift-facing wrapper, runs the blocking Hamlib calls off-main
├── Audio/                      Audio I/O
│   ├── AudioDevice.swift        CoreAudio input/output device enumeration + persisted-UID lookup
│   └── AudioEngine.swift        AVAudioEngine capture (-> 12kHz mono) and playback (<- 48kHz mono),
│                                 with explicit CoreAudio device selection
├── Spectrum/                    Live waterfall display
│   ├── AudioSpectrum.swift      Rolling-window FFT magnitude spectrum (Accelerate/vDSP)
│   └── SpectrumView.swift       Renders the scrolling waterfall bitmap
├── Settings/
│   ├── AppSettings.swift        UserDefaults-backed settings store (callsign, device/rig config)
│   └── SettingsView.swift       Settings window UI
├── JttyChat-Bridging-Header.h  Swift ↔ C bridge (imports JttyCodecBridge.h + HamlibBridge.h)
└── AppIcon.icns / Assets.xcassets

ThirdParty/jtty_codec/          JTTY encode/decode DSP engine (Fortran, GPLv3, unmodified)
└── build.sh                     Builds lib/libjttycodec.a with gfortran (see Prerequisites)
```

### Why there's C and Fortran in a SwiftUI app

- **The JTTY codec is Fortran.** It's copied unmodified from a WSJT-X fork
  (see [Credits](#credits)) rather than reimplemented, since it's a dense,
  correctness-critical DSP engine (GFSK waveform synthesis, FFT-based sync
  search, a trellis decoder, etc.) that isn't something to casually port by
  hand. Xcode has no Fortran compiler, so these sources sit outside the
  Xcode target; `ThirdParty/jtty_codec/build.sh` compiles them with
  Homebrew's `gfortran` into a static library (`lib/libjttycodec.a`,
  committed to the repo) that the app links directly via its
  `OTHER_LDFLAGS` build setting. `JttyCodecBridge.h` declares the handful of
  Fortran entry points as plain C functions (matching gfortran's calling
  convention) so Swift can call them through the bridging header; all of
  the actual encode/decode *logic* — text sanitization, buffering, batching
  decoded messages — is ordinary Swift in `JttyCodec.swift`/`JttyDecoder.swift`.
- **Hamlib is a C library.** `HamlibBridge.c` is a small shim that does all
  the Hamlib struct/pointer plumbing (`rig_init`, `rig_open`, `rig_set_ptt`,
  etc.) in C against `<hamlib/rig.h>`, exposing only flat, Swift-friendly
  functions (plain ints/strings/bools) through `HamlibBridge.h`. This keeps
  every Hamlib type out of Swift and out of the bridging header entirely —
  `RigController.swift` just calls those flat functions off the main thread.

### Data flow

- **Send**: `ContentView` → `ChatViewModel.sendMessage()` → `Jtty.encodeMessage`
  (Swift → `genjtty_profile_`/`gen_jttywave_` in the Fortran codec) → a 48kHz
  PCM buffer. `ChatViewModel` keys PTT via `RigController` (if a rig is
  configured in Settings), plays the buffer through `PlaybackEngine`
  (`Audio/AudioEngine.swift`) on the configured output device, and unkeys
  PTT once playback plus a short tail has elapsed.
- **Receive**: `CaptureEngine` taps the configured input device, resampling
  to 12kHz mono. Each chunk is fed to both `AudioSpectrum` (for the
  waterfall) and `JttyDecoder` (Swift → `rjtty_sub_`/`jtty_get_updates_` in
  the Fortran codec); completed messages come back through a callback that
  appends a received `ChatMessage`.

### Other notable choices

- **App Sandbox is disabled** (`ENABLE_APP_SANDBOX = NO`). CAT control over
  arbitrary serial/USB device paths and linking directly against
  Homebrew-installed dylibs don't play well with the sandbox, so this app
  is an ordinary unsandboxed Mac app, like most ham radio software.
- **The app icon** uses the classic `CFBundleIconFile` + `.icns` mechanism
  rather than an asset-catalog `AppIcon` set or an Icon Composer `.icon`
  file — this Xcode version's `ASSETCATALOG_COMPILER_APPICON_NAME` build
  setting wasn't available to configure here, so the icon doesn't get the
  newer Liquid Glass treatment (light/dark/tinted variants, specular
  highlights). It's a plain static icon.
- Audio device selection (Settings → Audio Input/Output) targets specific
  CoreAudio devices by persisting their stable UID and resolving it back to
  a live `AudioDeviceID` at capture/playback time, falling back to the
  system default if the saved device isn't present.

## Prerequisites to build

- **macOS and Xcode**, matching this project's deployment target.
- **Homebrew**, with these installed:

  ```sh
  brew install hamlib fftw gcc
  ```

  - `hamlib` — transceiver (CAT/PTT) control. The app links `libhamlib`
    dynamically and expects it at Homebrew's standard prefix
    (`/opt/homebrew/opt/hamlib`); its headers are needed to compile
    `Hamlib/HamlibBridge.c`.
  - `fftw` — the JTTY codec links `libfftw3f` (single-precision FFTW)
    statically.
  - `gcc` — provides `gfortran` (to build the JTTY codec, see below) and the
    Fortran runtime support libraries (`libgfortran`, `libquadmath`,
    `libgcc`) the app links statically.

  The app's build settings (`HEADER_SEARCH_PATHS`, `LIBRARY_SEARCH_PATHS`,
  `OTHER_LDFLAGS`) reference these by their absolute Homebrew paths, so an
  Apple Silicon Mac with Homebrew at the default `/opt/homebrew` prefix is
  assumed. The Fortran runtime libraries are referenced via the specific
  installed `gcc` version's Cellar path (e.g.
  `/opt/homebrew/Cellar/gcc/16.2.0/...`), not the `opt/gcc` symlink, so an
  unrelated `brew upgrade gcc` can break the link step — if that happens,
  update `OTHER_LDFLAGS` in the JttyChat target's build settings to match
  `brew --cellar gcc`'s new version.

- **The JTTY codec static library** (`ThirdParty/jtty_codec/lib/libjttycodec.a`)
  is committed to the repo, so a fresh clone should build without needing
  `gfortran` at all. If you change anything under `ThirdParty/jtty_codec/`,
  or the committed library doesn't link/run correctly on your machine,
  rebuild it with:

  ```sh
  cd ThirdParty/jtty_codec
  ./build.sh
  ```

  (This needs `gfortran` from the `gcc` formula above.)

### Building and running

1. Install the Homebrew dependencies above.
2. Open `JttyChat.xcodeproj` in Xcode.
3. Build and run the `JttyChat` scheme (⌘R).
4. On first launch, open File → Settings… to set your callsign, audio
   input/output devices, and (if you have one) your transceiver's rig
   model, serial port, and baud rate. Use the Connect button to verify the
   rig link before transmitting.

macOS will prompt for microphone access the first time the app tries to
capture audio for decoding — this is required for Receive to work.

## Testing
There is a wav file with a test message and a jtty\_capture.iq8 that can be transmitted with
a hackRF like this:

```sh
hackrf_transfer -t jtty\_capture.iq8 -f 7090000 -x 47 -R
```

## Credits

The JTTY encode/decode engine in `ThirdParty/jtty_codec/` is copied,
unmodified, from the JTTY mode implementation in a fork of
[WSJT-X](https://wsjtx.github.io/wsjtx/) (`wsjtx-3.2.0-rc1`). JTTY is a
GFSK-based weak-signal mode designed for fast, RTTY-style contest exchanges
and keyboard-to-keyboard contacts; see `ThirdParty/jtty_codec/NOTICE.txt`
for the specific entry points this project calls.

WSJT-X is developed by the WSJT Development Team:

Joe Taylor, K1JT; Bill Somerville, G4WJS; Steve Franke, K9AN; Nico Palermo,
IV3NWV; Uwe Risse, DG2YCB; Brian Moran, N9ADG; Roger Rehr, W3SZ; John Nelson,
G4KLA; Charlie Suckling, DL3WDG; Terrell Deppe, KJ5HST; and David Christle,
KD0BTO —

with acknowledged contributions from AC6SL, AE4JY, DF2ET, DJ0OT, DL3WDG,
EA4AC, G4KLA, IW3RAB, JA7UDE, K3WYC, KA1GT, KA6MAL, KA9Q, KB1ZMX, KD6EKQ,
KG4IYS, KI7MT, KK1D, ND0B, PY1ZRJ, PY2SDR, VE1SKY, VK3ACF, VK4BDJ, VK7MO,
VR2UPU, W3DJS, W4TI, W4TV, and W9MDB.

The copied codec is licensed under the GNU General Public License v3 (see
`ThirdParty/jtty_codec/COPYING`); JttyChat, which links it directly into the
application, is distributed under the same license.

JttyChat also depends on:

- [Hamlib](https://hamlib.github.io/) — transceiver (CAT/PTT) control.
- [FFTW](https://www.fftw.org/) — used internally by the JTTY codec.

# License
This application is licensed under GPL 3. The source code is available here: https://github.com/peterbmarks/JttyChatMac
