#!/bin/sh
set -e
swift build -c release
APP=Prancheta.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Prancheta "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Prancheta</string>
  <key>CFBundleIdentifier</key><string>org.delduca.Prancheta</string>
  <key>CFBundleName</key><string>Prancheta</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
