# StereoPlayer3D

VR-ready stereoscopic video player for **Mac**, using Core ML-based depth estimation and Metal-accelerated stereo warping. Renders 3840×1080 SBS output (two 1920×1080 views) with automatic letterbox/pillarbox for any input aspect ratio.

## Target Device

RayNeo Air 4 Pro (Apple Silicon host, connected in 3D mode)

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

### 2. Build & Deploy

```bash
swift build -c release
```

Then deploy the `.app`:

```bash
# Deploy steps (also in build.sh):
cp .build/release/StereoPlayer3D StereoPlayer3D.app/Contents/MacOS/
strip -x StereoPlayer3D.app/Contents/MacOS/StereoPlayer3D
codesign --force --sign - StereoPlayer3D.app
```

### 3. Run

Open `StereoPlayer3D.app` and drag-and-drop an MP4 video to play.

In auto-play mode (default when `STEREO_AUTOPLAY` is defined in `Package.swift`), the first available video loads automatically.

## Features

- **Async render pipeline**: Decode → Core ML depth → Metal warp runs on background queue; draw loop only renders from lock-protected frame result. Prevents WindowServer crashes during fullscreen.
- **Audio playback**: AVPlayer synced to same `AVAsset` as video decoder — clock-synchronized, no manual buffer extraction. Pause/resume/seek handled together.
- **Stereo depth from monoscopic video**: DepthAnythingV2 small model via Core ML (Vision + MLCompute).
- **Side-by-side composition**: Two 1920×1080 eye views with depth-adjusted parallax.
- **RayNeo AR glasses support**: Automatically detects RayNeo Air 4 Pro display (3840×1080 SBS), moves window to that screen, and goes fullscreen.

## Architecture

| Stage | Description | Tech |
|-------|-------------|------|
| **Decode** | Decodes MP4/H.264 via AVFoundation | AVAssetReader |
| **Depth** | Estimates per-pixel depth via DepthAnythingV2 | Core ML (Vision + MLCompute) |
| **Warp** | Stereo warping → per-eye rendered textures | Metal compute + blit shaders |
| **Compose** | Side-by-side composition (two 1920×1080 eyes) | Metal render pipeline |
| **Audio** | Playback synced to video clock | AVPlayer (same AVAsset) |

### Stereo Rendering Pipeline

Video frames are decoded on a background queue (`pipelineQueue`). Each frame goes through:

1. **Pixel buffer** from `decodeFrame()`
2. **Depth estimation** via `DepthEstimator.estimateDepth()`
3. **Texture packaging** via `MetalPipeline.packageAll()`
4. **Stereo warp** — `StereoComposer.compose()` generates left/right eye textures
5. **Result stored** in lock-protected `ProcessedFrame`
6. **Draw** — `renderLoop()` on main thread reads from `ProcessedFrame` and renders SBS output

The source video is scaled to fit each 1920×1080 eye using "contain" fit:
- **Wide source** → letterbox (black bars top/bottom)
- **Tall source** → pillarbox (black bars left/right)

Portrait videos are automatically padded to 1:1 aspect ratio before warping to reduce edge sampling artifacts.

## Debugging

Log file: `/tmp/stereo_debug.log`

Build with debug logging enabled in `Sources/Core/DebugLogger.swift`.

## Backup Directories

- `First-audio-works/` — Sources after audio integration is stable
- `Sources.pre-audio/` — Sources before audio work began

## Troubleshooting

### "Model not found"
Re-run `./setup.sh`. It downloads the DepthAnythingV2 model binary into `Sources/Resources/`.

### Depth estimation crash
If the app crashes on launch, the `.mlmodelc` bundle is missing from the app's `Contents/Resources/` directory. Rebuild with the deploy script.

### "Metal device not available"
This app requires macOS 13+ with Metal 3 support. Ensure your GPU driver is up to date.

### Window doesn't move to RayNeo glasses
The app polling for the 3840×1080 display. Ensure RayNeo Air 4 Pro is connected in 3D mode. The display must report visibleFrame dimensions of 3840×1080.

### Codesign errors
- Use a valid Apple developer identity: check `security find-identity -p codesigning -v`
- Or skip codesign: run `.build/release/StereoPlayer3D` directly
