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
