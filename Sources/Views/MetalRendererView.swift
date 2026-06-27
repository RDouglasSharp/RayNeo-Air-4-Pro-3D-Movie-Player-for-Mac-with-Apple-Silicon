import Cocoa
import MetalKit
import CoreVideo
import AVFoundation
import Darwin

/// MTKView that drives the full stereo pipeline:
/// AVPlayerItemVideoOutput → depth+warp (synchronous) → SBS output
final class MetalRendererView: MTKView, MTKViewDelegate {
    var commandBuffer: MTLCommandBuffer?
    var currentFrame: CVPixelBuffer?

    // Pipeline components
    private var metalPipeline: MetalPipeline!
    private var depthEstimator: DepthEstimator?
    private var stereoComposer: StereoComposer!
    private var syncPlayer: SyncedVideoPlayer?

    /// Latest processed stereo frame (depth+warp result). Mounted on CVDisplayLink thread.
    private struct ProcessedFrame {
        let videoTexture: MTLTexture
        let depthTexture: MTLTexture
        let leftEye: MTLTexture
        let rightEye: MTLTexture
        let timing: FrameTiming
    }

    private var processedFrame: ProcessedFrame?

    // MARK: - Test Harness State
    private var isTestMode = false
    private var testHarnessRecorder: TestHarnessRecorder?
    private var testFrameCount = 0
    private var testSourceURL = ""
    private var testModelURL = ""
    private var testStartTime: TimeInterval = 0
    private var frameTimestamps: [TimeInterval] = []
    private var syntheticDepthWarned = false
    var lastDepth: CVPixelBuffer?
    var fpsLabel: NSTextField?

    /// Called on the main thread with (currentTime, duration) in seconds each rendered frame.
    /// Duration is read live from the player so it's always valid once frames are flowing.
    var onTimeUpdate: ((_ time: Double, _ duration: Double) -> Void)?

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
            logDebug("Test harness started → \(outputURL.path)\n")
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
            logDebug("Test harness finalize error: \(error)\n")
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

    public     func setupMTKView() {
        logDebug("SETUPMTK device=\(MTLCreateSystemDefaultDevice() != nil), frame=\(frame)\n")
        guard let mtlDevice = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal not supported")
        }

        self.device = mtlDevice

        metalPipeline = MetalPipeline(device: mtlDevice)
        syncPlayer = SyncedVideoPlayer()
        syncPlayer?.stateChanged = { [weak self] state in
            guard let self else { return }
            switch state {
            case .playing: self.isPaused = false
            case .paused: self.isPaused = true
            case .idle, .loading, .readyToPlay, .failed: break
            }
        }
        do {
            depthEstimator = try DepthEstimator()
            logDebug("DepthEstimator initialized successfully\n")
        } catch {
            depthEstimator = nil
            logDebug("WARNING: DepthEstimator failed: \(error.localizedDescription)\n")
            logDebug("         App will run in SYNTHETIC DEPTH MODE (no real depth estimation)\n")
        }
        stereoComposer = StereoComposer(pipeline: metalPipeline)

        colorPixelFormat = .bgra8Unorm
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

    public func updateBaseline(_ baseline: Float) {
        stereoComposer?.baseline = baseline
    }

    public func updateFocalLength(_ focalLength: Float) {
        stereoComposer?.focalLength = focalLength
    }

    public func updateFillMode(_ fillMode: StereoComposer.FillMode) {
        stereoComposer?.fillMode = fillMode
    }

    public func updateDepthDilation(sigma: Float, radiusH: Int, radiusV: Int) {
        depthEstimator?.dilationSigma = sigma
        depthEstimator?.dilationRadiusH = radiusH
        depthEstimator?.dilationRadiusV = radiusV
    }

    // MARK: - Video Playback

    /// Counter for frame skipping.
    private var frameCounter = 0
    private var renderCounter = 0
    private var renderSecond: TimeInterval = 0
    private var lastFrameProcTime: TimeInterval = 0

    func loadVideo(at url: URL, startPlayback: Bool = true) {
        logDebug("LOADVIDEO loading \(url.lastPathComponent)\n")

        syncPlayer?.frameProcessor = { [weak self] buffer, time in
            guard let self = self else { return buffer }
            let processStart = CACurrentMediaTime()
            self.processFrameSync(buffer, time: time)
            let elapsed = (CACurrentMediaTime() - processStart) * 1000
            logDebug("FRAMEPROC t=\(String(format: "%.2f", time.seconds)) elapsed=\(String(format: "%.1f", elapsed))ms\n")
            return buffer
        }

        syncPlayer?.frameRenderer = { [weak self] _buffer, _time in
            guard let self = self else { return }
            self.onTimeUpdate?(_time.seconds, self.syncPlayer?.duration.seconds ?? 0)
            self.renderCounter += 1
            let now = CACurrentMediaTime()
            if Int(now) != Int(self.renderSecond) {
                logDebug("RENDER \(Int(self.renderSecond))-\(Int(now)): \(self.renderCounter) frames\n")
                self.renderCounter = 0
                self.renderSecond = TimeInterval(Int(now))
            }
            guard let frame = self.processedFrame, let drawable = self.currentDrawable else { return }
            let cmdBuffer = self.metalPipeline.commandQueue.makeCommandBuffer()!

            if self.isTestMode {
                self.renderTestFrame(frame, cmdBuffer: cmdBuffer)
            } else {
                let descriptor = self.currentRenderPassDescriptor
                descriptor?.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
                if let renderPipelineState = self.createRenderPipeline(), let desc = descriptor {
                    let renderEncoder = cmdBuffer.makeRenderCommandEncoder(descriptor: desc)!
                    renderEncoder.setRenderPipelineState(renderPipelineState)
                    renderEncoder.setFragmentTexture(frame.leftEye, index: 0)
                    renderEncoder.setFragmentTexture(frame.rightEye, index: 1)
                    renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                    renderEncoder.endEncoding()
                }
                cmdBuffer.present(drawable)
                cmdBuffer.commit()
                self.metalPipeline.releaseTextures([frame.videoTexture, frame.depthTexture])
            }
            self.stereoComposer.releaseTextures()
        }

        syncPlayer?.load(url: url, autoplay: startPlayback)
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
        syncPlayer?.play()
    }

    func pause() {
        syncPlayer?.pause()
    }

    func stop() {
        if isTestMode {
            stopTestHarness(
                videoWidth: Int(syncPlayer?.duration.seconds ?? 0),
                videoHeight: 1080,
                videoFPS: 30,
                videoDuration: syncPlayer?.duration.seconds ?? 0
            )
        }
        syncPlayer?.pause()
        syncPlayer = nil
        processedFrame = nil
        isPaused = true
    }

    // MARK: - NSView lifecycle

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            stop()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
    }
    
    override func layout() {
        super.layout()
        logDebug("VIEWLAYOUT bounds=\(bounds)\n")
    }

    func seek(to time: TimeInterval) {
        syncPlayer?.seek(to: CMTime(seconds: time, preferredTimescale: 600))
    }

    func stepFrame() {}

    var videoInfo: VideoInfo {
        let duration = syncPlayer?.duration.seconds ?? 0
        return VideoInfo(width: 0, height: 0, codec: "AVFoundation", fps: 0, duration: duration)
    }

    // MARK: - Depth Preview

    func showDepthPreview(_ depth: CVPixelBuffer) {
        lastDepth = depth
    }

    /// no-op — rendering is driven by SyncedVideoPlayer's frameRenderer.
    public func draw(in view: MTKView) {}

    // MARK: - Synchronous Frame Processing

    /// Runs depth+warp synchronously on the CVDisplayLink thread.
    private func processFrameSync(_ videoFrame: CVPixelBuffer, time: CMTime) {
        let portraidFrame = CVPixelBufferGetWidth(videoFrame) >= CVPixelBufferGetHeight(videoFrame)
            ? videoFrame : padToSquare(videoFrame)

        let frameStart = CACurrentMediaTime()

        let depthStart = CACurrentMediaTime()
        let depthMap: CVPixelBuffer
        if let depthEst = depthEstimator {
            depthMap = depthEst.estimateDepth(from: portraidFrame)
        } else {
            depthMap = DepthEstimator.generateDepthMap(
                width: CVPixelBufferGetWidth(portraidFrame),
                height: CVPixelBufferGetHeight(portraidFrame),
                focalLength: 50.0
            )
        }
        let depthMs = (CACurrentMediaTime() - depthStart) * 1000

        let textures = metalPipeline.packageAll(
            videoFrame: portraidFrame,
            depthMap: depthMap
        )

        let warpStart = CACurrentMediaTime()
        let (leftEye, rightEye) = stereoComposer.compose(
            video: textures.video,
            depth: textures.depth
        )
        let warpMs = (CACurrentMediaTime() - warpStart) * 1000

        let totalMs = (CACurrentMediaTime() - frameStart) * 1000

        logDebug("FRAMEPROC depth=\(String(format: "%.1f", depthMs))ms warp=\(String(format: "%.1f", warpMs))ms total=\(String(format: "%.1f", totalMs))ms\n")

        let timing = FrameTiming(
            frame: 0,
            timestamp: CACurrentMediaTime(),
            decodeMs: 0,
            depthMs: depthMs,
            warpMs: warpMs,
            composeMs: 0,
            recordMs: 0,
            totalMs: totalMs,
            fps: totalMs > 0 ? 1000 / totalMs : 0
        )

        processedFrame = ProcessedFrame(
            videoTexture: textures.video,
            depthTexture: textures.depth,
            leftEye: leftEye,
            rightEye: rightEye,
            timing: timing
        )
    }

    /// Render test frame to file.
    private func renderTestFrame(_ frame: ProcessedFrame, cmdBuffer: MTLCommandBuffer) {
        let sbsWidth = 3840
        let sbsHeight = 1080
        let eyeWidth = frame.leftEye.width
        let eyeHeight = frame.leftEye.height

        let sbsTexture = metalPipeline.createTexture(
            width: sbsWidth, height: sbsHeight,
            pixelFormat: .bgra8Unorm
        )
        let blit = cmdBuffer.makeBlitCommandEncoder()!
        blit.copy(
            from: frame.leftEye,
            sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOriginMake(0, 0, 0),
            sourceSize: MTLSizeMake(eyeWidth, eyeHeight, 1),
            to: sbsTexture,
            destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOriginMake(0, 0, 0)
        )
        blit.copy(
            from: frame.rightEye,
            sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOriginMake(0, 0, 0),
            sourceSize: MTLSizeMake(eyeWidth, eyeHeight, 1),
            to: sbsTexture,
            destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOriginMake(eyeWidth, 0, 0)
        )
        blit.endEncoding()
        cmdBuffer.commit()
        cmdBuffer.waitUntilCompleted()

        guard let sbsPixelBuffer = createPixelBuffer(from: sbsTexture, width: sbsWidth, height: sbsHeight) else {
            metalPipeline.releaseTextures([frame.videoTexture, frame.depthTexture])
            stereoComposer.releaseTextures()
            return
        }

        let recordStart = CACurrentMediaTime()
        testFrameCount += 1

        let frameEnd = CACurrentMediaTime()
        let fps: Double
        frameTimestamps.append(frameEnd)
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
            decodeMs: frame.timing.decodeMs,
            depthMs: frame.timing.depthMs,
            warpMs: frame.timing.warpMs,
            composeMs: frame.timing.composeMs,
            recordMs: (CACurrentMediaTime() - recordStart) * 1000,
            totalMs: frame.timing.totalMs,
            fps: fps
        )
        testHarnessRecorder?.appendFrame(sbsPixelBuffer, timing: timing)
        metalPipeline.releaseTextures([frame.videoTexture, frame.depthTexture])
        metalPipeline.releaseTextures([sbsTexture])
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

    /// If source frame is portrait (height > width), pad horizontally to square
    /// so the stereo warp doesn't sample from black edges.
    /// Returns a new CVPixelBuffer (square, black-padded). No-op if already landscape.
    private func padToSquare(_ source: CVPixelBuffer) -> CVPixelBuffer {
        let sw = CVPixelBufferGetWidth(source)
        let sh = CVPixelBufferGetHeight(source)
        guard sh > sw else { return source }

        let size = Int(sh)
        var padded: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, size, size, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &padded)
        guard let buf = padded else { return source }

        // Create Metal textures
        let srcTex = metalPipeline.createTexture(fromPixelBuffer: source, pixelFormat: .bgra8Unorm)
        let dstTex = metalPipeline.createTexture(width: size, height: size, pixelFormat: .bgra8Unorm)

        let cmd = metalPipeline.commandQueue.makeCommandBuffer()!
        let blit = cmd.makeBlitCommandEncoder()!

        let padX = (size - sw) / 2
        blit.copy(
            from: srcTex,
            sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOriginMake(0, 0, 0),
            sourceSize: MTLSizeMake(sw, sh, 1),
            to: dstTex,
            destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOriginMake(padX, 0, 0)
        )
        blit.endEncoding()
        cmd.commit()

        // Copy dst texture → destination CVPixelBuffer
        guard let data = CVPixelBufferGetBaseAddress(buf) else { return source }
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        dstTex.getBytes(data, bytesPerRow: bpr, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)

        metalPipeline.releaseTextures([srcTex, dstTex])
        return buf
    }

    var _cachedRenderPipeline: MTLRenderPipelineState?

    func createRenderPipeline() -> MTLRenderPipelineState? {
        if let cached = _cachedRenderPipeline { return cached }

        guard let library = metalPipeline.library,
              let vertexFunction = library.makeFunction(name: "SBSVertex"),
              let fragmentFunction = library.makeFunction(name: "SBSFragment") else {
            logDebug("RPIPELINE FAIL: library=\(metalPipeline.library != nil), verts=\(metalPipeline.library?.makeFunction(name: "SBSVertex") != nil), frags=\(metalPipeline.library?.makeFunction(name: "SBSFragment") != nil)\n")
            return nil
        }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            let state = try metalPipeline.device.makeRenderPipelineState(descriptor: pipelineDescriptor)
            _cachedRenderPipeline = state
            logDebug("RPIPELINE OK\n")
            return state
        } catch {
            logDebug("RPIPELINE error: \(error.localizedDescription)\n")
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
