# Third-party notices

Android Mirroring's own source is MIT-licensed (see [LICENSE](LICENSE)). It
ships with, or was informed by, the following.

## scrcpy server

- **File:** `app/Sources/AndroidMirroring/Resources/scrcpy-server` (v4.1,
  unmodified; MD5 `7223f4d0753e9a9ebc43d10c51d01439`)
- **Source:** <https://github.com/Genymobile/scrcpy>
- **Copyright:** © 2018 Genymobile, © 2018–2026 Romain Vimont
- **Licence:** Apache-2.0, full text in [LICENSES/Apache-2.0.txt](LICENSES/Apache-2.0.txt)

The app pushes this jar to the device and speaks its socket protocol. The
Swift client in this repository is an independent implementation written
against the server sources; it contains no scrcpy client code.

## Test fixture

`app/Tests/AndroidMirroringTests/Fixtures/testsrc.h264` is eight frames of
FFmpeg's synthetic `testsrc` pattern, encoded with libx264. It contains no
third-party imagery.

## Apple

This repository contains **no Apple code, binaries, artwork, strings or other
assets**. The notes in `research/` describe the publicly shipped iPhone
Mirroring app as observed through static analysis on the author's own Mac, for
interoperability and UI study. The window, bezel and icon are drawn in code
written for this project. iPhone, iPhone Mirroring, Mac and macOS are
trademarks of Apple Inc.; Android is a trademark of Google LLC. This project is
not affiliated with or endorsed by either.

## AI-assisted development

Much of this project was written with AI coding assistants, under human
direction, selection and review.
