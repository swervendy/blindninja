#!/bin/bash
set -e

APP_NAME="Blind Ninja"
EXECUTABLE="BlindNinja"
BUILD_DIR=".build/debug"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
ICON_SRC="Sources/BlindNinja/Resources/AppIcon.icns"

echo "Building debug..."
swift build 2>&1 | tail -3

echo "Creating debug app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE"

if [ -f "$ICON_SRC" ]; then
    cp "$ICON_SRC" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

cat > "$APP_BUNDLE/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Blind Ninja</string>
    <key>CFBundleDisplayName</key>
    <string>Blind Ninja</string>
    <key>CFBundleIdentifier</key>
    <string>com.blindninja.app.debug</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>BlindNinja</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
</dict>
</plist>
PLIST

echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

echo "Launching..."
open "$APP_BUNDLE"
