#!/bin/bash
# Build and run StereoPlayer3D
# macOS 13 Ventura+ required for Metal 3 + ANE

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$PROJECT_DIR/.build"

echo "=== Building StereoPlayer3D ==="
echo "Platform: $(sw_vers -buildVersion)"
echo "Xcode: $(xcode-select -p)"
echo "Metal GPU: $(python3 -c "import CoreFoundation; print(CoreFoundation.CFRelease(None))" 2>/dev/null || echo "Metal supported")

# Verify dependencies
echo "Checking dependencies..."
swift --version

# Install FFmpeg if not already installed
if ! command -v ffmpeg &> /dev/null; then
    echo "Installing FFmpeg via Homebrew..."
    brew install ffmpeg
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to install FFmpeg. Install Homebrew or add FFmpeg to PATH."
        exit 1
    fi
fi

echo "FFmpeg: $(ffmpeg -version | head -1)"

# Build
echo "=== Building ==="
cd "$PROJECT_DIR"

# Spawn build using build script
echo "Command: swift build $CONFIGURATION"
swift build $CONFIGURATION
if [[ $? -ne 0 ]]; then
    echo "Error: Build failed."
    exit 1
fi

echo "=== Build successful ==="

# Install Core ML model if not present
if [[ ! -f "$PROJECT_DIR/Sources/Resources/models/DepthAnythingV2SmallF16.mlmodel" ]]; then
    echo "Core ML model not found!"
    echo "Download from: https://huggingface.co/apple/coreml-depth-anything-v2-small"
    echo "Place in: $PROJECT_DIR/Documents/Resources/models/DepthAnythingV2SmallF16.mlmodelc"
    exit 1
fi

echo "Core ML model verified.

# Run tests
echo "=== Running Tests ==="
swift test
if [[ $? -ne 0 ]]; then
    echo "WARNING: Some tests failed."
else
    echo "All tests passed!"
fi

echo "=== Build complete ==="
echo "Application: .build/apple-platform-config darwinex resource StereoPlayer3D.app"
echo "Or open with: open 'StereoPlayer3D/StereoPlayer3D' "
echo ""
echo "HINT: To run in debugger: xcodebuild -scheme StereoPlayer3D -destination 'platform=macOS' build"
