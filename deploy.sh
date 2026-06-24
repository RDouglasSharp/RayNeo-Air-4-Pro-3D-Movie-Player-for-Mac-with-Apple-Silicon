#!/bin/bash
set -e

APP_NAME="StereoPlayer3D"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$DIR/$APP_NAME.app"
BUILD_CONFIG="release"

# Auto-play flag for debug builds
if [ "${AUTOPLAY}" = "1" ]; then
  BUILD_CONFIG="debug"
fi

# Build
echo "Building..."
cd "$DIR"
swift build -c "$BUILD_CONFIG" -Xswiftc -D -Xswiftc STEREO_AUTOPLAY

# Clean old build
rm -rf "$APP"

# Create app bundle structure
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

# Copy binary
BINARY="$DIR/.build/arm64-apple-macosx/$BUILD_CONFIG/$APP_NAME"
cp "$BINARY" "$APP/Contents/MacOS/"

# Create minimal but functional Info.plist
cat > "$APP/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>StereoPlayer3D</string>
    <key>CFBundleExecutable</key>
    <string>StereoPlayer3D</string>
    <key>CFBundleIdentifier</key>
    <string>com.stereo.StereoPlayer3D</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>StereoPlayer3D</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>MacOSX</string>
    </array>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>NSMainStoryboardFile</key>
    <string>Main</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSRequiresAquaSystemAppearance</key>
    <false/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
PLIST

# Copy Core ML model if it exists
if [ -d "$DIR/Sources/Resources/models/DepthAnythingV2SmallF16.mlmodelc" ]; then
    cp -r "$DIR/Sources/Resources/models/DepthAnythingV2SmallF16.mlmodelc" "$APP/Contents/Resources/"
    echo "Copied Core ML model"
fi

# Copy Metal shader source
if [ -f "$DIR/Sources/Metal/StereoWarp.metal" ]; then
    cp "$DIR/Sources/Metal/StereoWarp.metal" "$APP/Contents/Resources/"
    echo "Copied Metal shader: StereoWarp.metal"
fi

# Strip debug symbols for smaller binary
strip "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || true

# Codesign with adhoc signature
codesign --force --sign - "$APP"
echo "Signed app bundle"

# Clear quarantine
xattr -rd com.apple.quarantine "$APP" 2>/dev/null || true

echo "Deployed to: $APP"
echo "Launch with: open '$APP'"
