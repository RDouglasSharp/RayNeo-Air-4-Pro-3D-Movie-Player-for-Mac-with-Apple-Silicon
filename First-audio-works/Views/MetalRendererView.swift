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
    private var audioPlayer: AVPlayer?
    private var renderTimer: Timer?

    // Background processing queue + lock
    private let pipelineQueue = DispatchQueue(label: "com.stereoplayer.pipeline", qos: .userInitiated)
    private let resultLock = NSLock()

    /// Latest processed frame result.
    private struct ProcessedFrame {
        let videoTexture: MTLTexture
        let depthTexture: MTLTexture
        let leftEye: MTLTexture
        let rightEye: MTLTexture
        let timing: FrameTiming
    }

    private var processedFrame: ProcessedFrame? {
        get { resultLock.lock(); defer { resultLock.unlock() }; return _processedFrame }
        set { resultLock.lock(); _processedFrame = newValue; resultLock.unlock() }
    }
    private var _processedFrame: ProcessedFrame?

    /// Whether background pipeline is currently running.
    private var isPipelineRunning: Bool {
        get { resultLock.lock(); defer { resultLock.unlock() }; return _isPipelineRunning }
        set { resultLock.lock(); _isPipelineRunning = newValue; resultLock.unlock() }
    }
    private var _isPipelineRunning = false

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
        ffmpegDecoder = AVFoundationDecoder()
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

    public func updateBaseline(_ baseline: Float) {}

    public func updateFocalLength(_ focalLength: Float) {}

    public func updateFillMode(_ fillMode: StereoComposer.FillMode) {}

    // MARK: - Video Playback

    func loadVideo(at url: URL) {
        logDebug("LOADVIDEO before loadVideo\n")
        do {
            try ffmpegDecoder.loadVideo(at: url)
            logDebug("LOADVIDEO after loadVideo\n")
            ffmpegDecoder.start()
            logDebug("LOADVIDEO after start, hasAudio=\(ffmpegDecoder.hasAudioTrack)\n")

            // Initialize AVPlayer for audio (synced to same asset as video decoder)
            if ffmpegDecoder.hasAudioTrack {
                let playerItem = AVPlayerItem(url: url)
                let player = AVPlayer(playerItem: playerItem)
                self.audioPlayer = player
                logDebug("LOADVIDEO AVPlayer created for audio\n")
            }
            // DON'T set isPaused=false yet — view may not be in window yet
            logDebug("LOADVIDEO window=\(self.window != nil), bounds=\(bounds)\n")
            // Defer until view is installed in window and resized
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self = self, self.window != nil, self.bounds.size.width > 0 else {
                    logDebug("LOADVIDEO deferred SKIP: window=\(self?.window != nil), bounds=\(self?.bounds ?? .zero)\n")
                    return
                }
                self.isPaused = false
                self.needsDisplay = true
                logDebug("LOADVIDEO deferred isPaused=false, needsDisplay=true, window=true, bounds=\(self.bounds)\n")
            }
        } catch {
            logDebug("LOADVIDEO ERROR: \(error.localizedDescription)\n")
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
        logDebug("START called, decoder=\(ffmpegDecoder != nil), paused=\(isPaused)\n")
        guard ffmpegDecoder != nil else { return }
        ffmpegDecoder.start()
        audioPlayer?.play()
        isPaused = false
        logDebug("START done, paused=\(isPaused)\n")
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
        audioPlayer?.pause()
        ffmpegDecoder.stop()
        isPaused = true
    }
    
    // MARK: - NSView lifecycle

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            removeDisplayLink()
        }
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        logDebug("VIEWWINDOW window=\(window != nil), bounds=\(bounds)\n")
        if window != nil {
            setupDisplayLink()
        }
    }
    
    /// Manually drive the render loop with a Timer.
    /// Higher frequency ensures responsive transitions; heavy work runs on background queue.
    private func setupDisplayLink() {
        guard window != nil else { return }
        removeDisplayLink()
        renderTimer = Timer.scheduledTimer(withTimeInterval: 1/60.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.draw(in: self)
        }
        logDebug("DISPLAYLINK added\n")
    }
    
    private func removeDisplayLink() {
        renderTimer?.invalidate()
        renderTimer = nil
    }
    
    @objc private func renderLoop() {
        if isPaused == false {
            draw(in: self)
        }
    }
    
    override func layout() {
        super.layout()
        logDebug("VIEWLAYOUT bounds=\(bounds)\n")
    }

    func pause() {
        ffmpegDecoder.pause()
        audioPlayer?.pause()
        isPaused = true
    }

    func seek(to time: TimeInterval) {
        _ = try? ffmpegDecoder.seek(to: time)
        audioPlayer?.seek(to: CMTime(seconds: time, preferredTimescale: 600))
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

    /// Atomically take and clear processedFrame to prevent double-render.
    @inline(__always)
    private func takeProcessedFrame() -> ProcessedFrame? {
        resultLock.lock()
        defer { resultLock.unlock() }
        let f = _processedFrame
        _processedFrame = nil
       return f
    }

    public func draw(in view: MTKView) {
        if !drawableSize.width.isFinite || !drawableSize.height.isFinite {
            drawableSize = (bounds.size.width > 0 && bounds.size.height > 0) ? bounds.size : CGSize(width: 3840, height: 1080)
        }

        if !isPaused, !isPipelineRunning, ffmpegDecoder != nil {
            kickOffProcessing()
        }

        guard let frame = takeProcessedFrame(), let drawable = currentDrawable else { return }

        let cmdBuffer = metalPipeline.commandQueue.makeCommandBuffer()!

        if isTestMode {
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
        } else {
            let descriptor = currentRenderPassDescriptor
            descriptor?.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)

            if let renderPipelineState = createRenderPipeline(), let desc = descriptor {
                let renderEncoder = cmdBuffer.makeRenderCommandEncoder(descriptor: desc)!
                renderEncoder.setRenderPipelineState(renderPipelineState)
                renderEncoder.setFragmentTexture(frame.leftEye, index: 0)
                renderEncoder.setFragmentTexture(frame.rightEye, index: 1)
                renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                renderEncoder.endEncoding()
            }

            cmdBuffer.present(drawable)
            cmdBuffer.commit()
            metalPipeline.releaseTextures([frame.videoTexture, frame.depthTexture])
        }
        stereoComposer.releaseTextures()
    }

    private func kickOffProcessing() {
        guard !isPipelineRunning else { return }
        isPipelineRunning = true

        pipelineQueue.async { [weak self] in
            self?.processFrame()
        }
    }

    private func processFrame() {
        defer { isPipelineRunning = false }

        guard let videoFrame = ffmpegDecoder.decodeFrame() else { return }
        currentFrame = videoFrame

        // If source video is portrait (aspect ratio < 1), pad to square
        // so stereo warp has content on all sides and won't sample from
        // edge black bars.
        let vw = CVPixelBufferGetWidth(videoFrame)
        let vh = CVPixelBufferGetHeight(videoFrame)
        let frame = vw >= vh ? videoFrame : padToSquare(videoFrame)

        let frameStart = CACurrentMediaTime()

        let depthStart = CACurrentMediaTime()
        let depthMap: CVPixelBuffer
        if let depthEst = depthEstimator {
            depthMap = depthEst.estimateDepth(from: frame)
        } else {
            depthMap = DepthEstimator.generateDepthMap(
                width: CVPixelBufferGetWidth(frame),
                height: CVPixelBufferGetHeight(frame),
                focalLength: 50.0
            )
        }
        let depthMs = (CACurrentMediaTime() - depthStart) * 1000

        let textures = metalPipeline.packageAll(
            videoFrame: frame,
            depthMap: depthMap
        )

        let warpStart = CACurrentMediaTime()
        let (leftEye, rightEye) = stereoComposer.compose(
            video: textures.video,
            depth: textures.depth
        )
        let warpMs = (CACurrentMediaTime() - warpStart) * 1000

        let totalMs = (CACurrentMediaTime() - frameStart) * 1000

        let timing = FrameTiming(
            frame: Int(totalMs / 1000 * 60),
            timestamp: CACurrentMediaTime(),
            decodeMs: 0,
            depthMs: depthMs,
            warpMs: warpMs,
            composeMs: 0,
            recordMs: 0,
            totalMs: totalMs,
            fps: totalMs > 0 ? 1000 / totalMs : 0
        )

        resultLock.lock()
        _processedFrame = ProcessedFrame(
            videoTexture: textures.video,
            depthTexture: textures.depth,
            leftEye: leftEye,
            rightEye: rightEye,
            timing: timing
        )
        resultLock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.needsDisplay = true
        }
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
