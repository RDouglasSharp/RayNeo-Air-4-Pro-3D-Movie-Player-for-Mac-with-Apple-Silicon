#!/bin/bash
# Downloads and sets up FFmpeg for StereoPlayer3D
# Requires: Xcode CLTOOLs installed

set -e

FFMPEG_VERSION=6.1
BUILD_DIR="$HOME/ffmpeg-stereoplayer"

echo "==> Checking for Homebrew FFmpeg framework..."
if brew list --formula ffmpeg >/dev/null 2>&1; then
    HOMEBREW_FFMPEG=$(brew --prefix ffmpeg)
    if [ -d "$HOMEBREW_FFMPEG/include/libavcodec" ]; then
        echo "    found at: $HOMEBREW_FFMPEG"
        PREFIX="$HOMEBREW_FFMPEG"
    else
        PREFIX=""
    fi
fi

if [ -z "$PREFIX" ]; then
    echo "[~] Homebrew FFmpeg not found. Building from source..."

    echo "(1) Downloading FFmpeg $ffmpeg_VERSION..."
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"
    curl -sLO "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.bz2"

    echo "(2) Extracting..."
    tar -xf "ffmpeg-$FFMPEG_VERSION.tar.bz2"
    cd "ffmpeg-$FFMPEG_VERSION"

    echo "(3) Configuring (arm64 + universal)..."
    ./configure \
        --extra-cflags="-arch arm64" \
        --extra-ldflags="-arch arm64" \
        --enable-shared \
        --enable-gpl \
        --disable-doc \
        --disable-programs # disable binaries we only need libraries

    echo "(4) Building... (this takes ~20 min on M-series)"
    make -j$(sysctl -n hw.ncpu)

    echo "(5) Installing to ~/.ffmpeg-stereo..."
    mkdir -p "$HOME/.ffmpeg-stereo"
    make install

    echo ""
    echo ">= Done! FFmpeg installed to ~/.ffmpeg-stereo/"
    echo "> To use: export LIBRARY_PATH=$HOME/.ffmpeg-stereo/lib"
    echo "           export CPATH=$HOME/.ffmpeg-stereo/include"
    echo "           export DYLD_LIBRARY_PATH=$HOME/.ffmpeg-stereo/lib"
else
    echo "Found Homebrew FFmpeg at $PREFIX"
    echo "Using it directly!"
fi

echo "SUCCESS"
