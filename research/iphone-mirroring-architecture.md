# iPhone Mirroring — Complete Technical Architecture

## How It Actually Works (from deep binary RE + entitlements + system analysis)

---

## Executive Summary

iPhone Mirroring (`com.apple.ScreenContinuity`) is a thin SwiftUI shell over a
sophisticated private infrastructure spanning at least **6 system daemons** and
**9 private frameworks**. The video path is: iPhone's screen → H.265 encode on
device → AWDL peer-to-peer WiFi → macOS `replicatord` daemon → ScreenSharingKit
→ AVSampleBufferDisplayLayer. Input flows reverse: Mac HID events → UniversalHID
→ AWDL → device-side injection. Audio uses a separate synchronized stream.

---

## 1. Process Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    macOS User Session                             │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────┐    XPC     ┌─────────────────┐                │
│  │ iPhone       │◄──────────►│ replicatord      │                │
│  │ Mirroring    │            │ (LaunchAgent)    │                │
│  │ (app)        │            │                  │                │
│  │              │            │ Mach services:   │                │
│  │ Swift shell  │            │  .replicatorservices │            │
│  │ + ScreenCont-│            │  .replicator.control │            │
│  │   inuityUI   │            │  .replicator.state   │            │
│  └──────┬───────┘            └────────┬─────────┘                │
│         │                             │                          │
│         │ XPC to:                     │ manages                  │
│         │  .wifip2pd                  ▼                          │
│         │  .networkd_privileged   ┌──────────────┐               │
│         │  .timesync.*            │ Replicator   │               │
│         │  .identityservicesd     │ Engine       │               │
│         │  .rtcreportingd         │ (in dyld     │               │
│         │                         │  cache)      │               │
│         ▼                         └──────┬───────┘               │
│  ┌──────────────┐                     │                          │
│  │ mediacont-   │                     │ AWDL WiFi P2P            │
│  │ inuityd      │                     │ (peer-to-peer)           │
│  │ (LaunchAgent)│                     │                          │
│  └──────────────┘                     ▼                          │
│                                      ┌──────────────┐            │
│  Also running:                       │ iPhone       │            │
│  .screensharing.agent                │ (iOS 18+)    │            │
│  .ContinuityCaptureAgent             │              │            │
│  .screencaptureui                    │ Encodes      │            │
│                                      │ H.265 video │            │
│                                      │ Opus audio  │            │
│                                      └──────────────┘            │
└─────────────────────────────────────────────────────────────────┘
```

## 2. The App Layer (com.apple.ScreenContinuity)

### 2.1 Binary structure
- **Main binary** (365K): thin stub, just `NSApplicationMain` + loads framework
- **ScreenContinuityUI** (4.1MB): the entire UI — SwiftUI, no nibs/storyboards
- Pure Swift + SwiftUI, localization embedded in binary via `String(localized:)`

### 2.2 Key classes (from symbol analysis)
```
ScreenContinuityUI namespace:
  CaptureViewController     — video rendering host
  HIDCaptureViewModel       — mouse/keyboard input capture
  RemoteTextInputView       — text input bridging to device
  DragAndDropView           — drag & drop Mac↔device
  SnapshotView              — last-frame snapshot for blur
  SnapshotBlurringView      — blur overlay on disconnect
  BlurOverlayView           — general blur effect
  LocalAuthenticationView   — Touch ID prompt
  TitlebarContainer         — auto-hiding toolbar
  ClientDragForwarding*     — drag pipeline
  BackgroundChromeInteractionModifier
  DeviceChromeInteractionModifier
  ResizableWindowChromeModifier
  WindowShapeModifier
  CustomRotationAnimation
```

### 2.3 State machine (recovered from log strings)
```
INITIALIZED
  → "sending its startup configuration to the server"
  → "activating the audio/video streams"    (parallel)
  → "activating the control stream"          (parallel)
  → "activated the audio/video streams, awaiting final readiness"
  → "device is ready to be on screen"       → CONNECTED

INTERRUPTED:
  → "was interrupted by: <error>"
  → SnapshotBlurringView appears
  → auto-reconnect or show error

TEARDOWN:
  → "invalidated cleanly, tearing down"
  → session deallocated
```

## 3. The Transport Layer (AWDL + Rapport)

### 3.1 Discovery — Rapport
iPhone Mirroring uses Apple's **Rapport** infrastructure (same as AirDrop,
Handoff, Sidecar) for device discovery:

- `com.apple.rapport.matching` in replicatord's LaunchEvents
- Service type: `com.apple.ApplicationService.chrono`
- Uses Bonjour (`_service._tcp`, `_service._udp`) for advertisement
- Bluetooth LE for proximity detection (is device nearby?)

### 3.2 Connection — AWDL (Apple Wireless Direct Link)
Entitlements reveal:
```
com.apple.wifip2pd                          — WiFi P2P daemon access
com.apple.private.corewifi                  — direct WiFi hardware control
com.apple.developer.networking.multicast    — multicast networking
com.apple.networkd_privileged               — privileged network access
com.apple.private.network.socket-delegate   — socket delegation
```

AWDL creates a **peer-to-peer WiFi link** between Mac and iPhone without
requiring a shared network. This is the same technology as AirDrop.

### 3.3 Time Synchronization
```
com.apple.timesync.expositor
com.apple.timesync.manager
com.apple.timesync.ptp.manager
```
Precision Time Protocol (PTP) for **audio/video lip sync** — critical for
a seamless mirroring experience.

## 4. The Replication Engine (replicatord + ReplicatorEngine)

### 4.1 replicatord daemon
- Runs as a LaunchAgent (`com.apple.replicatord.plist`)
- Starts on `keybag-first-unlock` (needs device to be unlocked once)
- Exposes Mach services:
  - `com.apple.replicatorservices` — main API
  - `com.apple.replicator.control` — control channel
  - `com.apple.replicator.state` — state queries
  - `com.apple.replicator.testing` — testing interface
- 262K binary, links ReplicatorCore + ReplicatorServices

### 4.2 Replicator framework family
```
ReplicatorCore      — core logic, daemon support
ReplicatorEngine    — the actual mirroring engine (in dyld cache)
ReplicatorServices  — XPC service definitions
ReplicatorDependencies — dependency injection
```

The engine handles:
- Session lifecycle (negotiate, connect, stream, teardown)
- Video stream management (codec negotiation, frame delivery)
- Audio stream management (synchronized with video)
- Control stream (input events, clipboard, gestures)
- Quality adaptation (bitrate, resolution scaling)

## 5. Video Pipeline

### 5.1 On the iPhone (sender)
- Screen captured via `RemoteDisplay` entitlement
- Encoded as **H.265/HEVC** (revealed by codec strings + entitlements)
- Audio encoded as **Opus** (low latency)
- Sent via AWDL to the Mac
- Config packet sent first (SPS/PPS equivalent)

### 5.2 On the Mac (receiver)
- `replicatord` receives stream
- `ScreenSharingKit.MirroringSession` manages the session state
- Video frames → `AVSampleBufferDisplayLayer` (or Metal, for HDR)
- Audio frames → `AVAudioEngine` with time synchronization
- Region-of-Interest (RoI) zoom support for Dynamic Island interactions

### 5.3 Screen quality features
From entitlements: `com.apple.private.screencapturekit.noprompt` and
`com.apple.private.SkyLight.screencapturedirect` — direct access to the
display pipeline for lowest latency.

## 6. Input Pipeline

### 6.1 Mouse/Keyboard → UniversalHID
```
Mac NSEvent → HIDCaptureViewModel → UniversalHID framework
  → HID events sent via AWDL → iPhone receives as real HID device
```
The Mac appears to the iPhone as a **physical HID device** — no special
software needed on the phone side.

### 6.2 Text Input → RemoteTextInput
```
Mac NSTextInputContext → RemoteTextInputView → RemoteTextInput framework
  → text forwarded to device IME → device processes → text state synced back
```
This is why typing feels native — it goes through the full text input system,
not just key event injection. Supports:
- Real-time text preview (marked text)
- Autocorrect suggestions from the device
- Emoji picker forwarding (RTI)

### 6.3 Gestures
From binary strings: `CaptureGestureRecognizer` handles:
- Trackpad swipe gestures (Home, App Switcher)
- Scroll events with momentum
- Right-click (mapped to Back on device)
- System gesture injection (`sendSystemGesture`)

## 7. Security & Authentication

### 7.1 Entitlements reveal security model
```
com.apple.private.sharing.unlock-manager    — remote unlock capability
com.apple.private.octagon                   — iCloud key sync
com.apple.private.CoreAuthentication.SPI    — Touch ID integration
com.apple.private.LocalAuthentication.CallerName — auth with app name
com.apple.private.LocalAuthentication.ExtractCredential
com.apple.identityservicesd.embedded.auth   — identity services
com.apple.PairingManager.Read               — device pairing data
```

### 7.2 Authentication flow
1. Mac and iPhone must be signed into **same iCloud account**
2. Device proximity verified via **Bluetooth LE**
3. Pairing keys stored in **Octagon** (iCloud key value store)
4. "Lock your iPhone to connect" — initial pairing requires locked phone
5. Optional per-session authentication:
   - "Ask Every Time" — Touch ID/password on every connect
   - "Authenticate Automatically" — when Mac is unlocked

### 7.3 Eligibility
- Reads `/private/var/db/os_eligibility/eligibility.plist`
- Region-restricted feature (EU initially excluded)
- Managed by configuration profiles (`com.apple.applicationaccess`)

## 8. Window & Rendering

### 8.1 Window architecture
From binary class names and strings:
- Borderless, shaped NSWindow (the window IS the phone)
- `ResizableWindowChromeModifier` — auto-hiding toolbar
- `WindowShapeModifier` — the window's shape follows the phone
- `ResizableChromeShape` — toolbar adapts to resize
- Traffic lights appear on hover over the bezel
- Window is movable by dragging anywhere

### 8.2 Layout constants (from constant pool)
```
Screen: 390×844pt (iPhone reference)    Corner radius: 54pt
Bezel: 14pt (internal) → ~5pt visible  Shadow: radius 15pt
Chrome reveal: 0.4s                    Chrome opacity: 77%
Blur in: 0.8s                          Blur out: 0.75s
Spring: damping 0.85, bounce 1.18     Settle timeout: 1.5s
```

### 8.3 Rendering optimizations
- `SnapshotView` + `SnapshotBlurringView` — freeze last frame + blur on disconnect
- `LayerBackedView` — CA-backed views for hardware acceleration
- Region-of-Interest zoom — can zoom into Dynamic Island interactions
- Live resize blur — blurs content during window resize (prevents jaggies)
- Crossfade animations between connect → mirror states

## 9. Drag & Drop

From `UniversalDrag` framework + binary classes:
```
DragAndDropView on Mac
  → ClientDragForwardingManager
    → ClientDragForwardingPipeline
      → UniversalDrag framework
        → AWDL → device receives drag items
          → file/photo transfer Mac↔device
```
- "A file transfer is in progress and will be canceled if you quit"
- Supports photos, documents, files
- Uses surrogate drag sessions when device doesn't support full D&D

## 10. Audio

- **Opus codec** at 48kHz
- Separate synchronized audio stream alongside video
- `com.apple.mediacontinuitykit.coex` — coexistence management
- `com.apple.private.mediaexperience.smartRoutingScore.allow` — smart routing
- `com.apple.videoconference.camera` — camera/mic sharing from device
- Time sync via PTP (`com.apple.timesync.*`) for lip sync
- "Some features such as iPhone microphone, camera, and Notification Center
  will not be available" — limitations acknowledged in alert

## 11. Notifications & Live Activities

- Notifications from iPhone forwarded to Mac
- "With iPhone Mirroring, Live Activities and notifications are forwarded"
- `com.apple.private.notificationcenter.preferences` — notification access
- iPhone widgets appear on Mac desktop (via Replicator)
- "Access your iPhone apps from notifications, Live Activities, Spotlight,
  and the Dock - with just a click."

## 12. Comparison with Our Android Mirroring

| Aspect | iPhone Mirroring | Android Mirroring |
|--------|-----------------|-------------------|
| Transport | AWDL (WiFi P2P) | USB / WiFi via ADB |
| Video codec | H.265/HEVC | H.264 (H.265 optional) |
| Audio codec | Opus 48kHz | (not yet — Opus planned) |
| Discovery | Rapport + BLE | adb devices |
| Auth | iCloud + Octagon + Touch ID | USB debugging authorization |
| Input injection | UniversalHID (appears as HID device) | scrcpy inject_input_event |
| Text input | RemoteTextInput (full IME) | inject_text (basic) |
| Drag & drop | UniversalDrag | (not yet) |
| Notifications | Forwarded to Mac | (not yet) |
| Time sync | PTP | Not needed (USB latency) |
| Window | Borderless shaped | Borderless shaped |
| Latency | Very low (AWDL direct) | Low (USB ~5-15ms) |

## 13. XPC Services Communication Map

```
iPhone Mirroring app
  ├── com.apple.replicatorservices     → replicatord (mirroring engine)
  ├── com.apple.wifip2pd               → WiFi P2P (AWDL)
  ├── com.apple.networkd_privileged    → privileged networking
  ├── com.apple.timesync.expositor     → time sync
  ├── com.apple.timesync.manager       → time sync
  ├── com.apple.timesync.ptp.manager   → PTP protocol
  ├── com.apple.identityservicesd      → iCloud auth
  ├── com.apple.security.octagon       → key sync
  ├── com.apple.rtcreportingd          → quality metrics
  ├── com.apple.mediacontinuitykit.coex → media coexistence
  ├── com.apple.videoconference.camera → camera sharing
  ├── com.apple.corewifi-xpc           → WiFi control
  ├── com.apple.bluetooth.le.att.xpc   → Bluetooth LE
  ├── com.apple.usernotifications.settings-vendor → notifications
  └── com.apple.powerlog.plxpclogger.xpc → power logging
```

## 14. Why Some Features Are Hard to Replicate

1. **AWDL**: Apple's proprietary WiFi P2P — no equivalent on Android over WiFi
   (scrcpy uses TCP/IP instead, which requires a shared network)
2. **UniversalHID**: makes Mac appear as physical device — scrcpy's
   inject_input_event works differently but achieves similar results
3. **RemoteTextInput**: full IME bridging — we use basic text injection
4. **Notification forwarding**: requires deep OS integration
5. **iCloud auth**: we use ADB authorization instead

## 15. What We CAN Replicate (and have)

✅ Video mirroring (H.264 instead of H.265, similar latency)
✅ Mouse/touch input (scrcpy inject_touch)
✅ Keyboard input (scrcpy inject_text + keycode)
✅ Window chrome (borderless, bezel, auto-hiding toolbar)
✅ Connect flow (requirements checklist, auto-connect)
✅ Auto-reconnect on disconnect
✅ Scale presets (Larger/Smaller/Actual Size)
✅ Blur snapshot on disconnect
✅ Controls menu with proper shortcuts
