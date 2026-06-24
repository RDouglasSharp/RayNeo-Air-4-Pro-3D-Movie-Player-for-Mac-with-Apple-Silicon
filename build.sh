#!/bin/bash
# Build and run StereoPlayer3D
# macOS 13 Ventura+ required for Metal 3 + ANE

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$PROJECT_DIR/.build"
CONFIGURATION="${CONFIGURATION:--c release}"

echo "=== Building StereoPlayer3D ==="
echo "Platform: $(sw_vers -buildVersion)"
echo "Xcode: $(xcode-select -p)"

# Verify dependencies
echo "Checking dependencies..."
swift --version

# Build
echo "=== Building ==="
cd "$PROJECT_DIR"
swift build $CONFIGURATION
if [[ $? -ne 0 ]]; then
    echo "Error: Build failed."
    exit 1
fi

echo "=== Build successful ==="

# === Deploy to .app bundle ===
APP_DIR="$PROJECT_DIR/StereoPlayer3D.app/Contents"
APP_RESOURCES="$APP_DIR/Resources"
ARCH="$(uname -m)"
if [[ "$CONFIGURATION" == *"-c release"* ]]; then
    SPM_BUNDLE="$BUILD_DIR/$ARCH-apple-macosx/release/StereoPlayer3D_StereoPlayer3D.bundle"
    BINARY="$BUILD_DIR/release/StereoPlayer3D"
else
    SPM_BUNDLE="$BUILD_DIR/$ARCH-apple-macosx/debug/StereoPlayer3D_StereoPlayer3D.bundle"
    BINARY="$BUILD_DIR/debug/StereoPlayer3D"
fi

echo "=== Deploying to StereoPlayer3D.app ==="
mkdir -p "$APP_RESOURCES"

# Copy binary
cp "$BINARY" "$APP_DIR/MacOS/StereoPlayer3D"

# Copy all bundled resources (shader, model files)
if [[ -d "$SPM_BUNDLE" ]]; then
    cp "$SPM_BUNDLE"/*.metal "$APP_RESOURCES/" 2>/dev/null || true
    cp -r "$SPM_BUNDLE"/*.mlmodelc "$APP_RESOURCES/" 2>/dev/null || true
else
    echo "Warning: SPM bundle not found at $SPM_BUNDLE"
fi

# Strip and sign
strip -x "$APP_DIR/MacOS/StereoPlayer3D" 2>/dev/null || true
xattr -cr "$PROJECT_DIR/StereoPlayer3D.app" 2>/dev/null || true
codesign --force --sign - "$PROJECT_DIR/StereoPlayer3D.app" 2>/dev/null || true

echo "=== Deployed and signed ==="
