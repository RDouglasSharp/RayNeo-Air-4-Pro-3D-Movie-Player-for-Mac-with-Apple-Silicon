# StereoPlayer3D

VR-ready stereoscopic video player for **Mac**, using core ML-based depth estimation and Metal-accelerated stereo warping. Renders fixed 3840×1080 SBS output (two 1920×1080 views) with automatic letterbox/pillarbox for any input aspect ratio.

## Target Device

Rayneo Air 4 Pro (Core ML + ML, Metal 3)

## Prerequisites

- macOS 13+ (Metal 3)
- Xcode 16.2+ / Swift 6
- Apple developer account (for codesigning with auto-entitlements)

## Quick Start

### 1. Install Dependencies

```bash
./setup.sh   # Downloads DepthAnythingV2 model into Sources/Resources/
```

The model binary (`DepthAnythingV2SmallF16.mlmodelc`) must be present before building.

### 2. Build

```bash
./build.sh   # swift build -c release
```

### 3. Run

```bash
.build/release/StereoPlayer3D     # CLI mode (open video from menu)
```

Or build the `.app` bundle:

```bash
./build_app.sh   # Creates StereoPlayer3D.app with codesign
```

Then open StereoPlayer3D.app and drag-and-drop an MP4 video to play.

## Building for Release

Use the SPM `.release` binary and place `.app` bundle:

```bash
./build_app.sh
```

By default, uses ad-hoc signing. To sign with your Apple Developer identity:

```bash
CODESIGN_IDENTITY="Robert Douglas Sharp 1" ./build_app.sh
```

### Building for Store Submission

```bash
CODESIGN_IDENTITY="Your Name (TEAMID)" ./build_app.sh
```

## Architecture

| Stage | Description | Tech |
|-------|-------------|------|
| **Decode** | Decodes MP4/H.264 via AVFoundation | AVAssetReader |
| **Depth** | Estimates per-pixel depth via DepthAnythingV2 model | Core ML (Vision + MLCompute) |
| **Warp** | Stereo warping → per-eye rendered textures | Metal compute + blit shaders |
| **Compose** | Side-by-side composition (two 1920×1080 eyes, letterbox/pillarbox) | Metal render pipeline |
| **Record** | Captures test output + JSON timing report | AVAssetWriter + Metal |

### Stereo Rendering Pipeline

The source video is scaled to fit each 1920×1080 eye using "contain" fit.

- **Wide source** → letterbox (black bars top/bottom)
- **Tall source** → pillarbox (black bars left/right)

Each eye's viewport gets its own depth-adjusted content for 3D parallax.

## Test Harness

Run the test suite to verify pipeline performance:

```bash
swift test
```

Generates:
- `test_output.mp4` — rendered SBS video (3840×1080)
- `test_timing.json` — per-frame latency report with pass/fail grade
  - Target: P95 latency < 33ms (30fps @ RT)

## Troubleshooting

### "Model not found"
Re-run `./setup.sh`. It downloads the DepthAnythingV2 model binary into `Sources/Resources/`.

### Depth estimation crash
If the app crashes on launch, the `.mlmodelc` bundle is missing from the app's `Contents/Resources/` directory. Rebuild with `./build_app.sh`.

### "Metal device not available"
This app requires macOS 13+ with Metal 3 support. Ensure your GPU driver is up to date.

### Codesign errors
- Use a valid Apple developer identity: check `security find-identity -p codesigning -v`
- Or skip codesign: run `.build/release/StereoPlayer3D` directly
