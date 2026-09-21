# Technical guide

How Android Mirroring works, how to build it, and where things live.

## How it works

Android Mirroring is a from-scratch native client of the **scrcpy 4.1 server
protocol**. There is no SDL and no scrcpy binary: it is Swift, AppKit and SwiftUI.

1. `adb forward tcp:0 localabstract:scrcpy_<scid>` reserves a local port.
2. The bundled server jar is pushed to `/data/local/tmp` under a per-session name.
3. `app_process` starts the server on the device. It deletes its own jar on exit.
4. Three sockets are opened, in order: **video**, **audio**, **control**.
   - Video: dummy byte → 64-byte device name → codec id → framed H.264.
     Annex-B is converted to AVCC and enqueued on an
     `AVSampleBufferDisplayLayer` with display-immediately set, so the newest
     frame is on screen as soon as it is decoded.
   - Audio: raw 48 kHz stereo s16le → a jitter buffer → `AVAudioSourceNode`.
     The output device pulls samples on its own clock. Playback holds until
     60 ms is queued, re-buffers once after an underrun, and skips back to
     60 ms if more than 180 ms piles up. Run with
     `ANDROID_MIRRORING_AUDIO_STATS=1` to log peak level, underruns, skips and
     buffer depth every two seconds.
   - Control: `inject_touch`, `inject_keycode`, `inject_scroll`, `inject_text`,
     `set_clipboard` out; clipboard updates back.
5. On disconnect or quit, the sockets close, the server stops and the adb
   forward is removed.

Every session carries a generation number. Callbacks from sockets, the parser
and the connection flow check it, so nothing left over from a previous session
can touch the current one.

The byte-exact protocol reference is in
[research/scrcpy-and-references.md](../research/scrcpy-and-references.md).

## Layout

```
app/
  Package.swift
  Sources/AndroidMirroring/
    AndroidMirroringApp.swift   window, Controls menu, lifecycle
    AppModel.swift              composition root + auto-connect
    DependencyManager.swift     finds or installs adb and the server jar
    DeviceMonitor.swift         polls `adb devices -l`
    MirrorSession.swift         connection choreography, sockets, state machine
    VideoStreamParser.swift     serial, order-preserving v4.1 stream parser
    VideoDecoder.swift          Annex-B → AVCC → AVSampleBufferDisplayLayer
    AudioPlayer.swift           audio socket parser, jitter buffer, AVAudioEngine output
    ScrcpyWire.swift            byte-exact control message encoder
    PlayerView.swift            mouse → touch, wheel → scroll, keys, clipboard
    ConnectScreen.swift         connect pane with live requirements checklist
    MirrorContentView.swift     bezel + rounded-corner device window
    ToolLocator.swift / Shell.swift
    Resources/scrcpy-server     bundled server jar (v4.1, Apache-2.0)
  Tests/AndroidMirroringTests/  parser, wire format, real H.264 decode
research/                       interoperability and UI study notes
scripts/
  install.sh                    build, make the icon, install to /Applications
  make-app.sh                   build into app/dist without installing
  create_icon.swift             draws the app icon
```

## Build from source

Requires macOS 14 or later and Xcode (or the command line tools for building
only; `swift test` needs Xcode).

```bash
cd app
swift run
```

```bash
cd app
swift test
```

The decode test runs a real H.264 stream through the same Annex-B → AVCC path
the app uses, decodes it with VideoToolbox and checks the pixels.

## Overrides

| Variable | Effect |
|---|---|
| `ANDROID_MIRRORING_ADB` | Path to the `adb` to use |
| `ANDROID_MIRRORING_SERVER` | Path to a scrcpy server jar |
| `ANDROID_MIRRORING_SERVER_VERSION` | Version string passed to that server |
| `ANDROID_MIRRORING_AUDIO_STATS` | Log audio buffer health every two seconds |

If Homebrew's scrcpy is installed, its server jar and version are used, so the
two always match. Otherwise the bundled v4.1 jar is used.

## Roadmap

In rough priority: Opus audio (less USB bandwidth than raw), a device picker
for more than one device, UHID keyboard mode (⌘/⌥ shortcuts, non-Latin
layouts), an H.265 option, and a System Settings-style pane for the connect
requirements.
