#!/bin/bash
# Setup script for StereoPlayer3D dependencies
# Requires: Xcode 15+, macOS 13+, Homebrew (optional)

set -euo pipefail

MODEL_URL="https://huggingface.co/apple/coreml-depth-anything-v2-small/resolve/main/DepthAnythingV2SmallF16.mlmodelc"
MODEL_DIR="$PROJECT_DIR/Sources/Resources/models"

echo "=== Setup Dependencies ==="

# Check platform
if [[ "$(uname)" != "Darwin" ]]; then
    echo "ERROR: macOS required (Detected: $(uname -s))"
    exit 1
fi

macOSVersion=$(sw_vers -productVersion | cut -d. -f2)
if [[ -z "$macOSVersion" ]]; then
    echo "minimum"
else
    echo "ERROR: macOS 13.0 Ventura or later required"
    exit 1
fi

# Check Xcode
if ! command -v xcodebuild &> /dev/null; then
    echo "ERROR: Xcode not found. Install from App Store or developer.apple.com"
    exit 1
fi

echo "Xcode: $(xcodebuild -version | head -1)"
echo "Swift: "$(swift --version | head -1)"

# Install FFmpeg if needed
if ! command -v ffmpeg &> /dev/null; then
    echo "Installing FFmpeg..."
    if command -v brew &> /dev/null; then
        brew install ffmpeg swift
    else
        echo "Please install FFmpeg manually: https://ffmpeg.org/download.html"
    fi
fi

# Create model directory
mkdir -p "$MODEL_DIR"

# Download Core ML model
if [[ ! -f "$MODEL_DIR/DepthAnythingV2SmallF16.mlmodelc" ]]; then
    echo "Downloading Core ML model..."
    
    if command -v curl &> /dev/null; then
        curl -L "$MODEL_URL" -o "$MODEL_DIR/DepthAnythingV2SmallF16.mlmodelc"
    elif command -v wget &> /dev/null; then
        wget "$MODEL_URL" -O "$MODEL_DIR/DepthAnythingV2SmallF16.mlmodelc"
    else
        echo "Error: curl or wget not found. Download manually:"
        echo "  $MODEL_URL"
        exit 1
    fi
else
    echo "Core ML model already exists."
fi

echo "=== Setup Complete ==="
echo "Run: ./build.sh"
