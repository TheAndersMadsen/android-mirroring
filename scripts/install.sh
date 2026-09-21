#!/bin/zsh
# Full install: build, create icon, install to /Applications, launch.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="/Applications/Android Mirroring.app"

echo "==> Building release…"
cd "$ROOT/app"
swift build -c release

echo "==> Creating app icon…"
ICON_SRC="/tmp/AppIcon.icns"
if [ ! -f "$ICON_SRC" ] || [ "$ROOT/scripts/create_icon.swift" -nt "$ICON_SRC" ]; then
    swift "$ROOT/scripts/create_icon.swift" "$ICON_SRC" || {
        echo "    (icon creation failed, skipping)"
        ICON_SRC=""
    }
fi

echo "==> Installing to $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/AndroidMirroring "$APP/Contents/MacOS/Android Mirroring"
chmod +x "$APP/Contents/MacOS/Android Mirroring"

# Bundle the scrcpy server jar (Apache-2.0, © Genymobile)
if [ -f /opt/homebrew/share/scrcpy/scrcpy-server ]; then
    cp /opt/homebrew/share/scrcpy/scrcpy-server "$APP/Contents/Resources/"
else
    cp Sources/AndroidMirroring/Resources/scrcpy-server "$APP/Contents/Resources/"
fi

[ -n "$ICON_SRC" ] && [ -f "$ICON_SRC" ] && cp "$ICON_SRC" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Android Mirroring</string>
    <key>CFBundleDisplayName</key>       <string>Android Mirroring</string>
    <key>CFBundleExecutable</key>        <string>Android Mirroring</string>
    <key>CFBundleIdentifier</key>        <string>local.android-mirroring</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSAppTransportSecurity</key>    <dict><key>NSAllowsLocalNetworking</key><true/></dict>
    <key>LSApplicationCategoryType</key> <string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

echo "==> Killing old instances…"
pkill -f "Android Mirroring" 2>/dev/null || true
sleep 1

echo "==> Launching…"
open "$APP"
echo "✓ Installed and launched: $APP"
