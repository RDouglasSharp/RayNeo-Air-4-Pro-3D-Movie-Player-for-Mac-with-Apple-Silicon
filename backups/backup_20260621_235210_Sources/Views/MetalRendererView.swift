import Cocoa
import MetalKit
import CoreVideo
import AVFoundation

/// MTKView that drives the full stereo pipeline:
/// FFmpeg decode → Core ML depth → Metal stereoWarp → SBS output
final class MetalRendererView: MTKView, MTKViewDelegate {
    var commandBuffer: MTLCommandBuffer?
    var currentFrame: CVPixelBuffer?

    // Pipeline components
    private var metalPipeline: MetalPipeline!
    private var depthEstimator: DepthEstimator!
    private var stereoComposer: StereoComposer!
    private var ffmpegDecoder: FFmpegDecoder!

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
        ffmpegDecoder = FFmpegDecoder()
        depthEstimator = try! DepthEstimator()
        stereoComposer = StereoComposer(pipeline: metalPipeline)

        colorPixelFormat = .bgra8Unorm
        sampleCount = 4
        framebufferOnly = false
        isPaused = true
        isOpaque = true
        clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0)

        enclaveFormat = .invalid
        autoResize = true
        preferredFramesPerSecond = 60

        delegate = self
    }

    // MARK: - Configuration Updates

    public func updateBaseline(_ baseline: Float) {}

    public func updateFocalLength(_ focalLength: Float) {}

    public func updateFillMode(_ fillMode: StereoComposer.FillMode) {}

    public override func prepare() {
        super.prepare()
        setupMTKView()
    }

    // MARK: - Video Playback

    func loadVideo(at url: URL) {
        do {
            try ffmpegDecoder.loadVideo(at: url)
            ffmpegDecoder.start()
            self.running = true
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
        running = true
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
        running = false
        isPaused = true
    }

    func pause() {
        ffmpegDecoder.pause()
        running = false
        isPaused = true
    }

    func seek(to time: TimeInterval) {
        ffmpegDecoder.seek(to: time)
    }

    // MARK: - Depth Preview

    func showDepthPreview(_ depth: CVPixelBuffer) {
        lastDepth = depth
    }

    // MARK: - MTKViewDelegate (Rendering)

    public override func draw(_ dirtyRect: NSRect) {
        // Decode new frame
        guard let videoFrame = ffmpegDecoder.decodeFrame() else {
            return
        }
        currentFrame = videoFrame
        let frameStart = CACurrentMediaTime()

        let decodeStart = CACurrentMediaTime()

        // 1. Core ML depth estimation
        var depthMap: CVPixelBuffer
        let depthStart = CACurrentMediaTime()
        do {
            depthMap = try depthEstimator.estimateDepth(from: videoFrame)
        } catch {
            depthMap = depthEstimator.generateDepthMap(
                width: Int(CVPixelBufferGetWidth(videoFrame)),
                height: Int(CVPixelBufferGetHeight(videoFrame)),
                focalLength: 512.0
            )
        }
        let depthMs = (CACurrentMediaTime() - depthStart) * 1000

        // 2. Package textures from CVPixelBuffers
        let textures = metalPipeline.packageAll(
            videoFrame: videoFrame,
            depthMap: depthMap
        )

        // 3. Stereo warp + compose
        let warpStart = CACurrentMediaTime()
        let videoWidth = textures.video.width
        let videoHeight = textures.video.height

        let leftEye = metalPipeline.createTexture(
            width: videoWidth,
            height: videoHeight,
            pixelFormat: .bgra8Unorm
        )
        let rightEye = metalPipeline.createTexture(
            width: videoWidth,
            height: videoHeight,
            pixelFormat: .bgra8Unorm
        )

        stereoComposer.compose(
            video: textures.video,
            depth: textures.depth,
            leftEye: leftEye,
            rightEye: rightEye
        )
        let warpMs = (CACurrentMediaTime() - warpStart) * 1000

        // Compose SBS output
        let sbsWidth = videoWidth * 2
        let sbsHeight = videoHeight
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
            sourceSize: MTLSizeMake(videoWidth, videoHeight, 1),
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
            sourceSize: MTLSizeMake(videoWidth, videoHeight, 1),
            to: sbsTexture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOriginMake(videoWidth, 0, 0)
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
            descriptor?.colorAttachments[0].clearColor = .clear

            if let renderPipelineState = createRenderPipeline() {
                let renderEncoder = cmdBuffer.makeRenderCommandEncoder(descriptor: descriptor)!
                renderEncoder.setRenderPipelineState(renderPipelineState)
                renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                renderEncoder.endEncoding()
            }

            cmdBuffer.present(drawable)
            cmdBuffer.commit()
        }

        metalPipeline.releaseTextures([textures.video, textures.depth, leftEye, rightEye, sbsTexture])
        stereoComposer.releaseTextures()
    }

    /// Copy MTLTexture → CVPixelBuffer (BGRA) for AVAssetWriter consumption.
    private func createPixelBuffer(from texture: MTLTexture, width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue,
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue,
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

        guard
            let device = self.device,
            let library = try? device.makeDefaultLibrary()
        else {
            return nil
        }

        guard
            let vertexFunction = library.makeFunction(name: "vertex_shader"),
            let fragmentFunction = library.makeFunction(name: "fragment_shader")
        else {
            return nil
        }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            let state = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
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
