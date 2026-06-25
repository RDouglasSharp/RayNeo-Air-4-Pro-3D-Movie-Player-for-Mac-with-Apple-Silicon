# StereoPlayer3D

VR-ready stereoscopic video player for **macOS**, using Core ML-based depth estimation and Metal-accelerated stereo warping. Renders 3840x1080 side-by-side output (two 1920x1080 views) with automatic letterbox/pillarbox for any input aspect ratio.  If a non-mirrored display shows up on the Mac with 3840x1080 resolution (as for example if you attach Rayneo Air 4 Pro HDR10 Smart AR Glasses, switch them to be running in 3D mode, then make them an extended display) the video frame moves to that screen and goes into full screen mode.

## Requirements

- macOS 14+ (Ventura or later, Apple Silicon recommended)
- Swift 5.9+ (included with Xcode 15+)
- CommandLineTools or Xcode installed

## Quick Start

### 1. Clone the repository

```bash
git clone <repo-url>
cd StereoPlayer3D
```

### 2. Download the depth model

The app uses the DepthAnythingV2 model for depth estimation from monoscopic video:

```bash
bash setup.sh
```

This downloads the pre-compiled `DepthAnythingV2SmallF16.mlmodelc` Core ML model bundle into `Sources/Resources/models/`.

> **Note:** If you have a raw `.mlpackage` source instead of a compiled `.mlmodelc`, you must compile it first:
>
> ```bash
> xcrun coremlcompiler compile Sources/Resources/models/DepthAnythingV2SmallF16.mlpackage Sources/Resources/models/DepthAnythingV2SmallF16.mlmodelc
> ```

### 3. Build and deploy

Use `deploy.sh` — it builds the Swift package, creates the `.app` application bundle, bundles the Core ML model and Metal shaders, ad-hoc signs, and strips the binary:

```bash
bash deploy.sh
```

The app is created at `StereoPlayer3D.app`.

### 4. Run

```bash
open StereoPlayer3D.app
```

Then drag-and-drop an MP4 video to play, or use **File > Open** (or `Cmd+O`).

## Build Options

### Ad-hoc signing (default)

The `codesign --force --deep --sign -` command signs with an ad-hoc certificate — no personal certificate required.

### Debug build with auto-play

Set `AUTOPLAY=1` to build in debug mode with debug logging and auto-play enabled:

```bash
AUTOPLAY=1 bash deploy.sh
```

Debug logging writes to `/tmp/stereo_debug.log`. The debug build expects a file named `test.mp4` in the project root (e.g., `StereoPlayer3D/test.mp4`) and will auto-play it when the app launches. Any landscape video (16:9 or similar) works; the app handles any resolution, but 4K sources look best.

## Architecture

| Stage | Description | Tech |
|-------|-------------|------|
| **Decode** | Pulls decoded frames at current audio time | AVPlayerItemVideoOutput |
| **Depth** | Estimates per-pixel depth via DepthAnythingV2 | Core ML (Vision + MLCompute) |
| **Warp** | Stereo warping produces per-eye textures | Metal compute + blit shaders |
| **Compose** | Side-by-side composition (two 1920x1080 eyes) | Metal render pipeline |
| **Audio** | Plays natively via AVPlayer | AVFoundation |

### Video Playback Pipeline

1. **SyncedVideoPlayer** uses `CVDisplayLink` to fire on every display refresh. For each tick it pulls the frame matching the **current audio clock** time via `AVPlayerItemVideoOutput`.
2. **FrameProcessor** runs synchronously on the display-link thread: depth estimation + Metal stereo warp. The result is stored in a shared `processedFrame`.
3. **FrameRenderer** fires on the main thread and renders the latest completed `processedFrame` to the MTKView drawable.

If processing takes longer than the display interval (~16.7ms at 60fps), the next tick's `processingInFlight` guard drops it. The following tick pulls whatever frame the audio clock is at, naturally resyncing — no drifting.

### Stereo Rendering

The source video is scaled to fit each 1920x1080 eye using "contain" fit:
- **Wide source** -> letterbox (black bars top/bottom)
- **Tall source** -> pillarbox (black bars left/right)

Portrait videos are automatically padded to 1:1 aspect ratio before warping to reduce edge sampling artifacts.

## Debugging

Log file: `/tmp/stereo_debug.log`

Debug logging is compiled out in release builds. Set `AUTOPLAY=1` when running `deploy.sh` to include debug output.

## Troubleshooting

### "Model not found"

Re-run `./setup.sh`. It downloads the DepthAnythingV2 model binary into `Sources/Resources/models/`.

### Depth estimation crash

If the app crashes on launch, the `.mlmodelc` bundle is missing from the app's `Contents/Resources/` directory. Rebuild with the deploy script.

### "Metal device not available"

This app requires macOS 13+ with Metal 3 support. Ensure your GPU driver is up to date.

### Window doesn't move to RayNeo glasses

The app polls for a 3840x1080 display. Ensure your AR glasses are connected in 3D mode and reporting the correct resolution.

### Slow video playback

The depth+warp pipeline runs synchronously and takes ~30-50ms per frame. If your GPU is slower, consider:
- Using a faster Core ML depth model
- Reducing the depth estimation resolution
- Disabling depth estimation (uses synthetic parallax instead)
