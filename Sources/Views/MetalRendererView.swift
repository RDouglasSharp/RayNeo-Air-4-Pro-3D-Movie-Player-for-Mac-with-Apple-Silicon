import Cocoa
import MetalKit
import CoreVideo
import AVFoundation
import Darwin

/// MTKView that drives the full stereo pipeline:
/// FFmpeg decode → Core ML depth → Metal stereoWarp → SBS output
final class MetalRendererView: MTKView, MTKViewDelegate {
    var commandBuffer: MTLCommandBuffer?
    var currentFrame: CVPixelBuffer?

    // Pipeline components
    private var metalPipeline: MetalPipeline!
    private var depthEstimator: DepthEstimator?
    private var stereoComposer: StereoComposer!
    private var ffmpegDecoder: AVFoundationDecoder!

    // MARK: - Test Harness State
    /// When true, pipeline renders to file instead of MTKView screen.
    private var isTestMode = false
    private var testHarnessRecorder: TestHarnessRecorder?
    private var testFrameCount = 0
    private var testSourceURL = ""
    private var testModelURL = ""
    private var testStartTime: TimeInterval = 0
    /// FPS tracking for timing report
        private var frameTimestamps: [TimeInterval] = []
        private var syntheticDepthWarned = false
    var lastDepth: CVPixelBuffer?
    var fpsLabel: NSTextField?

    // MARK: - Test Mode Configuration

    /// Activate test harness mode: render SBS to file, collect timing report.
    public func startTestHarness(outputURL: URL, sourceURL: String, modelURL: String) {
        isTestMode = true
        testFrameCount = 0
        testSourceURL = sourceURL
        testModelURL = modelURL
        frameTimestamps.removeAll()

        do {
            let recorder = TestHarnessRecorder(outputURL: outputURL)
            try recorder.startRecording(
                width: 3840,
                height: 1080,
                fps: 30.0
            )
            testHarnessRecorder = recorder
            testStartTime = CACurrentMediaTime()
            print("Test harness started → \(outputURL.path)")
        } catch {
            isTestMode = false
            testHarnessRecorder = nil
            fatalError("Test harness init failed: \(error)")
        }
    }

    /// Finalize test harness and write timing report.
    public func stopTestHarness(
        videoWidth: Int,
        videoHeight: Int,
        videoFPS: Double,
        videoDuration: Double
    ) {
        guard let recorder = testHarnessRecorder else { return }
        do {
            let report = try recorder.finish(
                sourceURL: testSourceURL,
                videoWidth: videoWidth,
                videoHeight: videoHeight,
                videoFPS: videoFPS,
                videoDuration: videoDuration,
                modelURL: testModelURL
            )
            let mdURL = recorder.reportURL.deletingPathExtension().appendingPathExtension("_summary.md")
            let summary = report.summary()
            try summary.write(to: mdURL, atomically: true, encoding: .utf8)
            testHarnessRecorder = nil
            isTestMode = false
        } catch {
            print("Test harness finalize error: \(error)")
        }
    }

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)
        setupMTKView()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        setupMTKView()
    }

    // MARK: - Initialization

    public func setupMTKView() {
        guard let mtlDevice = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal not supported")
        }

        self.device = mtlDevice

        metalPipeline = MetalPipeline(device: mtlDevice)
        ffmpegDecoder = AVFoundationDecoder()
        do {
            depthEstimator = try DepthEstimator()
            print("DepthEstimator initialized successfully")
        } catch {
            depthEstimator = nil
            print("WARNING: DepthEstimator failed: \(error.localizedDescription)")
            print("         App will run in SYNTHETIC DEPTH MODE (no real depth estimation)")
            fflush(__stderrp)
        }
        stereoComposer = StereoComposer(pipeline: metalPipeline)

        colorPixelFormat = .bgra8Unorm
        sampleCount = 4
        framebufferOnly = false
        isPaused = true
        wantsLayer = true
        layer?.isOpaque = true
        clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0)
        preferredFramesPerSecond = 60
        drawableSize = CGSize(width: 3840, height: 1080)

        delegate = self
    }

    /// Initialize underlying pipeline components manually.
    public func initialize() {
        setupMTKView()
    }

    // MARK: - Configuration Updates

    public func updateBaseline(_ baseline: Float) {}

    public func updateFocalLength(_ focalLength: Float) {}

    public func updateFillMode(_ fillMode: StereoComposer.FillMode) {}

    // MARK: - Video Playback

    func loadVideo(at url: URL) {
        do {
            try ffmpegDecoder.loadVideo(at: url)
            ffmpegDecoder.start()
            self.isPaused = false
        } catch {
            fatalError("Failed to load video: \(error)")
        }
    }

    func loadVideoForTest(
        at url: URL,
        outputURL: URL,
        modelURL: String
    ) {
        startTestHarness(outputURL: outputURL, sourceURL: url.path, modelURL: modelURL)
        loadVideo(at: url)
    }

    func start() {
        guard ffmpegDecoder != nil else { return }
        ffmpegDecoder.start()
        isPaused = false
    }

    func stop() {
        if isTestMode {
            stopTestHarness(
                videoWidth: ffmpegDecoder.videoWidth,
                videoHeight: ffmpegDecoder.videoHeight,
                videoFPS: Double(ffmpegDecoder.frameRate),
                videoDuration: Double(ffmpegDecoder.duration)
            )
        }
        ffmpegDecoder.stop()
        isPaused = true
    }

    func pause() {
        ffmpegDecoder.pause()
        isPaused = true
    }

    func seek(to time: TimeInterval) {
        _ = try? ffmpegDecoder.seek(to: time)
    }

    func stepFrame() {
        guard let frame = try? ffmpegDecoder.decodeNextFrame() else { return }
        currentFrame = frame
    }

    var videoInfo: VideoInfo {
        VideoInfo(
            width: ffmpegDecoder.videoWidth,
            height: ffmpegDecoder.videoHeight,
            codec: "AVFoundation",
            fps: ffmpegDecoder.frameRate,
            duration: ffmpegDecoder.duration
        )
    }

    // MARK: - Depth Preview

    func showDepthPreview(_ depth: CVPixelBuffer) {
        lastDepth = depth
    }

    // MARK: - MTKViewDelegate (Rendering)

    public func draw(in view: MTKView) {
        // Decode new frame
        guard let videoFrame = ffmpegDecoder.decodeFrame() else {
            return
        }
        currentFrame = videoFrame

        let vf = CVPixelBufferGetPixelFormatType(videoFrame)
        let vw = CVPixelBufferGetWidth(videoFrame)
        let vh = CVPixelBufferGetHeight(videoFrame)
        let vb = CVPixelBufferGetBaseAddress(videoFrame) != nil ? "OK" : "NIL"
        let vbr = CVPixelBufferGetBytesPerRow(videoFrame)
        logDebug("VIDEO: format=\(vf) w=\(vw) h=\(vh) base=\(vb) bppr=\(vbr)\n")
        let frameStart = CACurrentMediaTime()

        let decodeStart = CACurrentMediaTime()

        // 1. Core ML depth estimation (or synthetic fallback)
        var depthMap: CVPixelBuffer
        let depthStart = CACurrentMediaTime()
        if let depthEst = depthEstimator {
            depthMap = depthEst.estimateDepth(from: videoFrame)
        } else {
            depthMap = DepthEstimator.generateDepthMap(
                width: CVPixelBufferGetWidth(videoFrame),
                height: CVPixelBufferGetHeight(videoFrame),
                focalLength: 50.0
            )
            if !syntheticDepthWarned {
                syntheticDepthWarned = true
                print("WARNING: Running in SYNTHETIC DEPTH MODE — no real depth estimation available")
                print("         Stereoscopy will use a synthetic radial gradient (not real scene-aware)")
                fflush(__stderrp)
            }
        }
        let df = CVPixelBufferGetPixelFormatType(depthMap)
        let dw = CVPixelBufferGetWidth(depthMap)
        let dh = CVPixelBufferGetHeight(depthMap)
        let db = CVPixelBufferGetBaseAddress(depthMap) != nil ? "OK" : "NIL"
        let dbr = CVPixelBufferGetBytesPerRow(depthMap)
        logDebug("DEPTH: format=\(df) w=\(dw) h=\(dh) base=\(db) bppr=\(dbr)\n")
        let depthMs = (CACurrentMediaTime() - depthStart) * 1000

        // 2. Package textures from CVPixelBuffers
        let textures = metalPipeline.packageAll(
            videoFrame: videoFrame,
            depthMap: depthMap
        )

        // 3. Stereo warp + compose (1920×1080 per-eye, with letterbox/pillarbox)
        let warpStart = CACurrentMediaTime()
        let (leftEye, rightEye) = stereoComposer.compose(
            video: textures.video,
            depth: textures.depth
        )
        let warpMs = (CACurrentMediaTime() - warpStart) * 1000

        // SBS output: 3840×1080 (two 1920×1080 views side-by-side)
        let sbsWidth = 3840
        let sbsHeight = 1080
        let eyeWidth = leftEye.width
        let eyeHeight = leftEye.height
        let composeStart = CACurrentMediaTime()

        let sbsTexture = metalPipeline.createTexture(
            width: sbsWidth,
            height: sbsHeight,
            pixelFormat: .bgra8Unorm
        )

        let cmdBuffer = metalPipeline.commandQueue.makeCommandBuffer()!
        let blitEncoder = cmdBuffer.makeBlitCommandEncoder()!

        blitEncoder.copy(
            from: leftEye,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOriginMake(0, 0, 0),
            sourceSize: MTLSizeMake(eyeWidth, eyeHeight, 1),
            to: sbsTexture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOriginMake(0, 0, 0)
        )

        blitEncoder.copy(
            from: rightEye,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOriginMake(0, 0, 0),
            sourceSize: MTLSizeMake(eyeWidth, eyeHeight, 1),
            to: sbsTexture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOriginMake(eyeWidth, 0, 0)
        )
        blitEncoder.endEncoding()

        if isTestMode {
            cmdBuffer.commit()
            cmdBuffer.waitUntilCompleted()

            guard let sbsPixelBuffer = createPixelBuffer(from: sbsTexture, width: sbsWidth, height: sbsHeight) else {
                print("Warning: failed to capture SBS frame for test harness")
                return
            }

            let recordStart = CACurrentMediaTime()
            testFrameCount += 1

            let decodeMs = (depthStart - decodeStart) * 1000
            let composeMs = (CACurrentMediaTime() - composeStart) * 1000
            let recordMs = (CACurrentMediaTime() - recordStart) * 1000
            let frameEnd = CACurrentMediaTime()
            let totalMs = (frameEnd - frameStart) * 1000

            let fps: Double
            frameTimestamps.append(frameStart)
            if frameTimestamps.count > 30 {
                frameTimestamps.removeFirst()
                let span = frameTimestamps.last! - frameTimestamps.first!
                fps = span > 0 ? Double(frameTimestamps.count) / span : 0
            } else {
                let elapsed = frameEnd - testStartTime
                fps = elapsed > 0 ? Double(testFrameCount) / elapsed : 0
            }

            let timing = FrameTiming(
                frame: testFrameCount,
                timestamp: frameEnd - testStartTime,
                decodeMs: decodeMs,
                depthMs: depthMs,
                warpMs: warpMs,
                composeMs: composeMs,
                recordMs: recordMs,
                totalMs: totalMs,
                fps: fps
            )

            testHarnessRecorder?.appendFrame(sbsPixelBuffer, timing: timing)
        } else {
            guard let drawable = currentDrawable else {
                cmdBuffer.commit()
                return
            }

            let descriptor = currentRenderPassDescriptor
            descriptor?.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)

            if let renderPipelineState = createRenderPipeline(), let desc = descriptor {
                let renderEncoder = cmdBuffer.makeRenderCommandEncoder(descriptor: desc)!
                renderEncoder.setRenderPipelineState(renderPipelineState)
                renderEncoder.setFragmentTexture(leftEye, index: 0)
                renderEncoder.setFragmentTexture(rightEye, index: 1)
                renderEncoder.drawPrimitives(type: MTLPrimitiveType.triangleStrip, vertexStart: 0, vertexCount: 4)
                renderEncoder.endEncoding()
            }

            cmdBuffer.present(drawable)
            cmdBuffer.commit()
        }

        // Clean up textures — sbsTexture readback may span frames for test mode
        if !isTestMode {
            metalPipeline.releaseTextures([textures.video, textures.depth, sbsTexture])
        } else {
            metalPipeline.releaseTextures([textures.video, textures.depth])
        }
        stereoComposer.releaseTextures()
    }

    /// Copy MTLTexture → CVPixelBuffer (BGRA) for AVAssetWriter consumption.
    private func createPixelBuffer(from texture: MTLTexture, width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buf = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(buf)
        guard let baseAddress = CVPixelBufferGetBaseAddress(buf) else { return nil }

        texture.getBytes(
            baseAddress,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )

        return buf
    }

    var _cachedRenderPipeline: MTLRenderPipelineState?

    func createRenderPipeline() -> MTLRenderPipelineState? {
        if let cached = _cachedRenderPipeline { return cached }

        guard let library = metalPipeline.library,
              let vertexFunction = library.makeFunction(name: "SBSVertex"),
              let fragmentFunction = library.makeFunction(name: "SBSFragment") else {
            return nil
        }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            let state = try metalPipeline.device.makeRenderPipelineState(descriptor: pipelineDescriptor)
            _cachedRenderPipeline = state
            return state
        } catch {
            return nil
        }
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        _cachedRenderPipeline = nil
    }

    // MARK: - FPS Tracking

    func updateFPSDisplay(fps: Float) {
        DispatchQueue.main.async { [weak self] in
            self?.fpsLabel?.stringValue = String(format: "%.1f FPS", fps)
        }
    }
}
