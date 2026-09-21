# iPhone Mirroring — Complete Reverse-Engineering Report

**Target:** `/System/Applications/iPhone Mirroring.app` (macOS 27.2, build 26B5086k)
**Bundle ID:** `com.apple.ScreenContinuity` · version 2.0 (126.6)
**Method:** static analysis — otool / nm / strings / Python binary constant-pool
extraction / radare2 / Ghidra 12.1.3 headless
**Purpose:** interoperability research to build "Android Mirroring" with matching look & feel.

---

## 1. Layout Constants (from binary constant pool @ 0x12e600-0x12e898)

These are the exact double-precision values found in the `__DATA` constant pool,
immediately preceding the strings "OnenessUIConstants", "MainWindow", "ScreenView",
"LoadingView" — they are the UI layout constants for those views:

| Value | Likely meaning |
|---|---|
| **390.0, 844.0** | iPhone reference screen dimensions (390×844pt = iPhone 14/15) |
| **54.0** | Screen corner radius (matches iPhone's ~55pt physical corner) |
| **14.0** | Bezel width around the screen |
| **0.4** | Chrome reveal duration (toolbar animation) |
| **0.5** | Standard animation duration |
| **0.75, 0.8** | Blur animation / blur removal duration |
| **0.95** | Spring damping (subtle) |
| **0.85** | Spring damping (bouncy) |
| **1.18** | Spring bounce overshoot ratio |
| **0.2** | Error animation delay / short animation |
| **0.05** | Very short delay |
| **0.77** | Chrome opacity (77%) |
| **4.0** | Small corner radius |
| **5.0** | Shadow radius |
| **1.5** | Sizing baseline settle timeout |
| **640.0** | Default window height |
| **360.0, 342.0** | Onboarding window dimensions |
| **649.88, 300.3** | Scaled mirror dimensions |
| **18.0, 20.0** | Standard paddings |
| **28.0, 32.0** | Icon/large element sizes |
| **±π/2** | Rotation transforms (90°) |

## 2. Complete UI Copy (verbatim from Swift String literals)

### Onboarding / Welcome
- **"Welcome to iPhone Mirroring"** (Welcome View Title)
- Bullet 1 title: **"No need to reach for your iPhone"**
- Bullet 2: **"Access your iPhone apps from notifications, Live Activities, Spotlight, and the Dock - with just a click."**
- Bullet 3: **"You can move photos, documents, and more from iPhone to Mac, or vice versa."**
- **"With iPhone Mirroring, Live Activities and notifications are forwarded to your Mac."**

### Pairing / Connect
- **"Your iPhone will be fully accessible from this Mac when connected."** (Pairing subtitle)
- **"To set up iPhone Mirroring, make sure your iPhone is near this Mac, powered on, running iOS 18 or later, with Bluetooth and Wi-Fi enabled, and signed in with the same iCloud account as this Mac."**
- **"Lock your iPhone before connecting." / "Lock your iPhone to connect."**

### Loading / Connecting
- **"Connecting to %@"** — with device name
- **"Message shown on the Mac while the initial handshake between the mac and iPhone is underway"**

### Confirmation
- **"iPhone Mirroring Is Ready to Use"** (Confirmation View Title)
- **"You're all set. When your iPhone is nearby, you can seamlessly use iPhone right from the desktop."**

### Authentication
- **"Require Mac Login to Access iPhone?"** (picker title)
- **"Authenticate Automatically"** / **"Ask Every Time"**
- **"Select Authenticate Automatically to access your iPhone when this Mac is unlocked."**
- **"Select Ask Every Time to be prompted to Touch ID or enter the Mac login for %@"**

### Errors (exact titles)
- **"Unable to Connect to iPhone"**
- **"Connection Interrupted"**
- **"Connection Paused"**
- **"Unlock Your iPhone"**
- **"Turn on Mac Bluetooth to connect."**
- **"Turn on Mac Wi-Fi to connect."**
- **"Sign in to iCloud to continue."**

### Buttons
- **Continue · Not Now · Try Again · Allow · Don't Allow · Set Up Later · Learn More**
- **Go to Settings · Change iPhone… · Revoke iPhone Access… · Enable iPhone**

### Settings
- **"Change iPhone…"** (with ellipsis character)
- **"Revoke iPhone Access…"** (with ellipsis character)

## 3. Menu Structure (exact)

### Controls Menu
| Item | Shortcut | SF Symbol |
|---|---|---|
| Home Screen | ⌘1 | `iphone` (inferred) |
| App Switcher | ⌘2 | `app.grid.3x3` or `iphone.app.switcher` |
| Spotlight | ⌘3 | `magnifyingglass` |
| Control Center | ⌘4 | `switch.2` |
| Rotate Device | ⌘R | `rectangle.portrait.rotate` |

### View Menu (scale presets)
| Item | Shortcut |
|---|---|
| Larger | ⌘+ |
| Smaller | ⌘− |
| Actual Size | ⌘0 |

Note: iPhone Mirroring **cannot be freely resized by dragging borders** — only
these three presets work (confirmed by Apple support + forum reports).

## 4. Window Chrome Behavior

- **Auto-hiding toolbar**: appears when pointer nears the top of the window
  (chrome reveal duration: 0.4s, opacity 0.77)
- Toolbar contains: Home Screen, App Switcher, Spotlight, Control Center buttons
- **"Force Show Chrome"** debug toggle exists — chrome visibility is controllable
- `ResizableBorderView` + `ResizableChromeShape` — the border adapts visually
- Traffic lights (close/minimize) appear on hover
- Window shadow: radius 5×3=15pt, y-offset 8pt, black 50% opacity

## 5. Connection Animations

1. **Connect**: crossfade + blur from connect pane to mirror (0.5s standard)
2. **Chrome reveal**: toolbar slides in from top (0.4s, easeInOut)
3. **Disconnect**: blur snapshot overlay appears (0.8s blurIn, 0.75s removal)
   - Uses `SnapshotBlurringView` — takes a snapshot, blurs it, overlays
   - Shows "Connection Interrupted" + "Reconnecting…"
4. **Window resize**: spring animation (damping 0.85, bounce 1.18)
5. **Rotation**: pre-shrinks window, rotates, re-expands (per log strings)

## 6. SF Symbols Used (from binary)

```
app.grid.3x3                          (App Switcher)
apps.iphone.and.cursorarrow           (hero/marketing)
iphone.app.switcher                   (App Switcher variant)
rectangle.portrait.rotate             (Rotate)
rectangle.portrait.arrowtriangle.2.inward  (Resize)
square.resize                         (Resize)
```

## 7. View Hierarchy (from Swift source filenames + class names)

```
MainWindow
├── OnboardingView (first launch)
│   ├── WelcomeView + BulletPointView ×3
│   ├── PairingView
│   ├── NotificationOnboardingView
│   ├── ConfirmationView
│   └── SettingsView (authentication frequency)
├── LoadingView (connecting)
└── ScreenView / DeviceScreenLayout
    ├── CaptureViewController (video rendering)
    │   ├── SnapshotView (last frame on disconnect)
    │   ├── SnapshotBlurringView (blur overlay)
    │   └── BlurOverlayView
    ├── ScreenContinuityTitlebar / TitlebarContainer (auto-hiding chrome)
    ├── ResizableBorderView / ResizableChromeShape
    ├── HIDCaptureView (input capture)
    ├── RemoteTextInputView (text input bridging)
    ├── DragAndDropView
    └── LocalAuthenticationViewController (Touch ID)
```

## 8. Architecture (private frameworks)

| Framework | Role |
|---|---|
| `ScreenSharingKit` | session transport (video/audio/control streams) |
| `ScreenContinuityServices` | continuity pairing, eligibility |
| `WiFiPeerToPeer` (AWDL) | peer-to-peer Mac↔iPhone link |
| `UniversalHID` | keyboard/mouse injection as HID |
| `RemoteTextInput` | IME/text bridging |
| `UniversalDrag` | drag & drop Mac↔iPhone |
| `LocalAuthenticationUI` | Touch ID prompt |

## 9. State Machine (from log strings)

```
MirroringSession initialized
  → "is sending its startup configuration to the server"
  → "is activating the audio/video streams"
  → "is activating the control stream"
  → "activated the audio/video streams, awaiting final readiness"
  → "was told the device is ready to be on screen, oblige it"
  [CONNECTED]

On disconnect:
  → "was interrupted by: %{public}s"
  → SnapshotBlurringView appears
  → "invalidated cleanly, tearing down"
  → auto-reconnect or show error

On error:
  → "is blocked from moving forward"
  → "vended an unknown state, tearing down"
```

## 10. Preferences / Defaults

- Domain: `com.apple.ScreenContinuity` and `com.apple.ScreenContinuityUI`
- Keys: `_shortcutsEnabled`, `defaultSize`, `backgroundOpacity`
- Debug keys: `chromeAnimationDelay`, `chromeAnimationSpeed`
- Feature flag: `com.apple.private.screencontinuity.app-launch`

## 11. What We Implemented (Android Mirroring v1.0)

| Feature | Status |
|---|---|
| Bezel: 14pt width, 54pt corner radius | ✅ exact match |
| Chrome reveal: 0.4s, opacity 0.77 | ✅ |
| Toolbar: Home/App Switcher/Spotlight/Control Center | ✅ |
| View menu: Larger/Smaller/Actual Size (⌘+/⌘−/⌘0) | ✅ |
| Disconnect blur overlay | ✅ |
| Spring animations (0.85 damping) | ✅ |
| Connect screen with requirements + self-fix | ✅ |
| Auto-reconnect on disconnect | ✅ |
| Keyboard/mouse/touch input | ✅ |
| Correct menu shortcuts (⌘1-4, ⌘R) | ✅ |

## 12. Reproducing

The analysed binaries are Apple's and are not in this repository. To follow
along, thin the arm64e slices out of your own copy of
`/System/Applications/iPhone Mirroring.app` with `lipo` and import them into
Ghidra.
