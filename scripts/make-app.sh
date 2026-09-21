#!/bin/zsh
# Build Android Mirroring and wrap it into a proper .app bundle.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/app"

swift build -c release

OUT="dist/Android Mirroring.app/Contents"
rm -rf "$ROOT/app/dist/Android Mirroring.app"
mkdir -p "$OUT/MacOS" "$OUT/Resources"

cp .build/release/AndroidMirroring "$OUT/MacOS/Android Mirroring"
cp Sources/AndroidMirroring/Resources/scrcpy-server "$OUT/Resources/"

cat > "$OUT/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Android Mirroring</string>
    <key>CFBundleDisplayName</key>       <string>Android Mirroring</string>
    <key>CFBundleExecutable</key>        <string>Android Mirroring</string>
    <key>CFBundleIdentifier</key>        <string>local.android-mirroring</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>LSApplicationCategoryType</key> <string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

echo "Built: $ROOT/app/dist/Android Mirroring.app"
open "$ROOT/app/dist/Android Mirroring.app"
