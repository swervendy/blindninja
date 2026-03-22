#!/bin/bash
set -e

APP_NAME="Blind Ninja"
BUNDLE_ID="com.blindninja.app"
EXECUTABLE="BlindNinja"
BUILD_DIR=".build/release"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
ICON_SRC="Sources/BlindNinja/Resources/AppIcon.icns"

echo "Cleaning build cache..."
rm -rf .build/arm64-apple-macosx .build/release

echo "Building release..."
swift build -c release

echo "Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp "$BUILD_DIR/$EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE"

# Copy icons
if [ -f "$ICON_SRC" ]; then
    cp "$ICON_SRC" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    echo "Icon copied."
else
    echo "Warning: icon not found at $ICON_SRC"
fi
PNG_SRC="Sources/BlindNinja/Resources/AppIcon.png"
if [ -f "$PNG_SRC" ]; then
    cp "$PNG_SRC" "$APP_BUNDLE/Contents/Resources/AppIcon.png"
fi

# Create Info.plist
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
    <string>com.blindninja.app</string>
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

# Create PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

echo ""
echo "Built: $APP_BUNDLE"
echo "Size: $(du -sh "$APP_BUNDLE" | cut -f1)"

# Install to /Applications and launch if --deploy flag
if [[ "$1" == "--deploy" ]]; then
    pkill -9 -f "Blind Ninja" 2>/dev/null || true
    sleep 1
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP_BUNDLE" "/Applications/$APP_NAME.app"
    echo "Deployed to /Applications/$APP_NAME.app"
    open "/Applications/$APP_NAME.app"
else
    echo ""
    echo "To run:    open \"$APP_BUNDLE\""
    echo "To deploy: ./build.sh --deploy"
fi
