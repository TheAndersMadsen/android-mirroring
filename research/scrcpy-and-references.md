# scrcpy 4.1 wire protocol — byte-exact reference

Ground truth read directly from the server sources at tag `v4.1` of
https://github.com/Genymobile/scrcpy (Apache-2.0):
`server/src/main/java/com/genymobile/scrcpy/{control/ControlMessageReader.java,
control/ControlMessage.java, device/Streamer.java, device/DesktopConnection.java,
Options.java}` — mirrored in `/tmp/scrcpy-src/` during the session.
Doc: `doc/develop.md` (warns the protocol is internal and version-specific).

## Server invocation

```bash
adb -s SERIAL push scrcpy-server /data/local/tmp/am-server-<scid>.jar
adb -s SERIAL forward tcp:0 localabstract:scrcpy_<scid8>      # prints the chosen port
adb -s SERIAL shell CLASSPATH=/data/local/tmp/am-server-<scid>.jar \
    app_process / com.genymobile.scrcpy.Server 4.1 <params…>
```
`<scid8>` = 8 lowercase hex digits of a random 31-bit int. Version string must match
the jar exactly or the server exits.

Accepted param keys (Options.java): `scid, log_level, video, audio, video_codec,
audio_codec, video_source, audio_source, audio_dup, max_size, min_size_alignment,
video_bit_rate, audio_bit_rate, max_fps, angle, tunnel_forward, crop, control,
display_id, show_touches, stay_awake, screen_off_timeout, video_codec_options,
audio_codec_options, video_encoder, audio_encoder, power_off_on_close,
clipboard_autosync, downsize_on_error, cleanup, power_on, list_encoders, list_displays,
list_cameras, list_camera_sizes, list_apps, camera_id, camera_size, camera_facing,
camera_ar, camera_zoom, camera_fps, camera_high_speed, camera_torch, new_display,
vd_destroy_content, vd_system_decorations, flex_display, capture_orientation,
display_ime_policy, keep_active, ignore_video_encoder_constraints, send_device_meta,
send_frame_meta, send_dummy_byte, send_stream_meta, raw_stream`.

## Socket topology (tunnel_forward=true)

Sockets are opened by the client **in order**: ① video, ② audio (if enabled),
③ control — all to the same forwarded TCP port (DesktopConnection.java).

On the **first** socket the server writes:
1. one **dummy byte** `0x00` (if `send_dummy_byte=true`) — lets the client detect
   connection errors;
2. **64-byte device name** (UTF-8, NUL padded) if `send_device_meta=true`.

⚠ adb forward accepts the TCP connect *before* the server exists; the socket then
EOFs. A client must retry until the dummy byte actually arrives (this bit us).

## Video socket stream (defaults: send_stream_meta / send_frame_meta = true)

```
u32  codec-id   "h264" 0x68323634 | "h265" 0x68323635 | "av1" 0x00617631 …
                 0x00000000 = stream disabled (keep running)
                 0x00000001 = configuration error (stop)
…then packets, each 12-byte header first:
  session packet: u32 flags = 0x8000_0000 (+1 if client-resized) | u32 width | u32 height
  media packet:   u64 ptsAndFlags | u32 size | <size bytes Annex-B payload>
```
Flag bits (Streamer.java): `bit63 = session`, `bit62 = config (SPS/PPS)`,
`bit61 = key frame`, low 61 bits = PTS in µs. Distinguish session vs media by bit63 of
the first u64. All big-endian. Rotation/fold produces a new session packet.

## Control socket (client → device), raw big-endian, no length prefix

Type IDs (ControlMessage.java):

| id | type | layout after the type byte |
|---|---|---|
| 0 | inject_keycode | action u8, keycode i32, repeat i32, metaState i32 |
| 1 | inject_text | len u32, UTF-8 |
| 2 | inject_touch | action u8, pointerId i64, x i32, y i32, screenW u16, screenH u16, pressure u16-fi, actionButton i32, buttons i32 |
| 3 | inject_scroll | x i32, y i32, screenW u16, screenH u16, hScroll i16-fp, vScroll i16-fp, buttons i32 |
| 4 | back_or_screen_on | action u8 |
| 5/6/7 | expand notification/settings panel, collapse panels | — |
| 8 | get_clipboard | copyKey u8 |
| 9 | set_clipboard | sequence i64, paste u8, len u32, UTF-8 |
| 10 | set_display_power | on u8 |
| 11 | rotate_device | — |
| 12/13/14 | uhid create/input/destroy | … |
| 15 | open_hard_keyboard_settings | — |
| 16 | start_app | len u8, name |
| 17 | reset_video | — |
| 18/19/20 | camera torch / zoom in / zoom out | … |
| 21 | resize_display | w u16, h u16 |
| 22 | scan_file | len u32, path |

- **positions are plain i32 device pixels** (no fixed point); pressure is
  u16 fixed-point (val/0xFFFF); scroll values are i16 fixed-point in [-1, 1]
  (server multiplies by 16).
- mouse uses pointer id `-1` (u64 all-ones), buttons = Android MotionEvent bits
  (primary = 1).
- Device→client messages (clipboard sync etc.) arrive on the same socket
  (DeviceMessageWriter.java) — v0 of the clone just drains them.

## Android keycodes used

HOME 3 · BACK 4 · VOLUME_UP 24 · VOLUME_DOWN 25 · POWER 26 · MENU 82 ·
DPAD 19/20/21/22 · ENTER 66 · DEL 67 · TAB 61 · APP_SWITCH 187.

## Gotchas hit during this build

1. adb forward TCP connect succeeds before the server exists → retry until the dummy
   byte arrives (see `MirrorSession.openVideoSocket`).
2. Swift `Data` keeps a non-zero `startIndex` after `removeFirst` — integer-literal
   subscripts trap. Slice relative to `startIndex`.
3. Feeding a stream parser via unordered `Task {}` hops scrambles TCP chunk order —
   parse on one serial queue (`VideoStreamParser`).
4. Multi-device adb: always pass `-s`; re-push the jar per session (scrcpy does too).
5. `app_process64` is not a valid entry point — use `app_process`.

## Licensing

scrcpy is **Apache-2.0**; bundling and redistributing `scrcpy-server` is permitted with
attribution + license copy. The bundled jar here comes from the local Homebrew install
(`/opt/homebrew/share/scrcpy/scrcpy-server`, v4.1).

## iPhone Mirroring UX references (for the clone's look & feel)

- Apple Support — “Use iPhone Mirroring on Mac”: connect requirements, window
  behavior, Controls menu, gestures (right-click = Back, keyboard routes to phone).
- MacRumors review coverage (Sequoia beta, 2024): bezel look, Dynamic Island
  rendering, notification/Dock integration.
- This repo's `iphone-mirroring-re.md` — primary-source strings recovered from the
  binary (the connect-screen copy, menu titles, state machine).
