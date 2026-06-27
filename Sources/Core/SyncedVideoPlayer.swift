import AVFoundation
import CoreVideo
import QuartzCore

/// A video player that pulls decoded frames synchronously, lets you transform each one,
/// and keeps video locked to the audio clock — including automatic resync if your
/// per-frame processing falls behind.
///
/// Audio plays natively through `AVPlayer`'s own audio pipeline; video frames are pulled
/// on demand for whatever time the audio clock is *actually* at right now, so a slow
/// frame never accumulates lag — the next callback just asks for a later frame.
public final class SyncedVideoPlayer: @unchecked Sendable {

    // MARK: - Public types

    /// Called once per displayed frame, off the main thread, with the raw decoded frame.
    /// Return the buffer you want displayed (same buffer, a new one, or a Metal-rendered
    /// result wrapped back into a CVPixelBuffer — whatever your pipeline produces).
    ///
    /// This is invoked SYNCHRONOUSLY on the display-link callback thread: the player
    /// will not advance to request the next frame until this returns. Keep it as fast
    /// as your real-time budget allows (~1 frame interval), but it does not need to be
    /// "non-blocking" in the async sense — synchronous, frame-by-frame transforms are
    /// exactly what this hook is for.
    public typealias FrameProcessor = (CVPixelBuffer, _ presentationTime: CMTime) -> CVPixelBuffer

    /// Called on the main thread whenever a new processed frame is ready to draw.
    public typealias FrameRenderer = (CVPixelBuffer, _ presentationTime: CMTime) -> Void

    public enum PlayerError: Error {
        case invalidURL
        case assetNotPlayable
        case noVideoTrack
    }

    public enum State {
        case idle
        case loading
        case readyToPlay
        case playing
        case paused
        case failed
    }

    // MARK: - Public state

    public private(set) var state: State = .idle {
        didSet { stateChanged?(state) }
    }
    public var stateChanged: ((State) -> Void)?

    /// Your per-frame transform. Set before or during playback; read fresh each frame.
    public var frameProcessor: FrameProcessor?

    /// Where processed frames get handed off for display (e.g. feed into your Metal pipeline).
    public var frameRenderer: FrameRenderer?

    public var currentTime: CMTime { player.currentTime() }
    public var duration: CMTime { player.currentItem?.duration ?? .zero }
    public var isPlaying: Bool { player.rate != 0 }

    // MARK: - Private AVFoundation plumbing

    private let player = AVPlayer()
    private var videoOutput: AVPlayerItemVideoOutput?
    private var displayLink: CVDisplayLink?
    private var statusObservation: NSKeyValueObservation?

    /// Serial queue so frame pulls/processing never overlap with themselves, even if
    /// the display link fires faster than we can process (it won't double-process).
    private let processingQueue = DispatchQueue(label: "SyncedVideoPlayer.processing", qos: .userInteractive)

    /// Guards against the display link firing again while a frame is still mid-process.
    private let isProcessingFrame = NSLock()
    private var processingInFlight = false

    public init() {}

    deinit {
        stopDisplayLink()
    }

    // MARK: - Loading a new file

    /// Loads a new file, replacing whatever's currently playing. Stops the old display
    /// link and tears down the old AVPlayerItemVideoOutput before swapping in the new one,
    /// so there's no chance of frames from the old asset leaking into the new pipeline.
    public func load(url: URL, autoplay: Bool = true) {
        stopDisplayLink()
        state = .loading

        let asset = AVURLAsset(url: url)

        Task {
            do {
                let isPlayable = try await asset.load(.isPlayable)
                let tracks = try await asset.load(.tracks)
                guard isPlayable else { throw PlayerError.assetNotPlayable }
                guard tracks.contains(where: { $0.mediaType == .video }) else {
                    throw PlayerError.noVideoTrack
                }

                await MainActor.run {
                    self.configureItem(for: asset, autoplay: autoplay)
                }
            } catch {
                await MainActor.run { self.state = .failed }
            }
        }
    }

    @MainActor
    private func configureItem(for asset: AVURLAsset, autoplay: Bool) {
        let item = AVPlayerItem(asset: asset)

        // Pull buffers in a format Metal/CoreML can consume directly without conversion.
        let attrs: [String: any Sendable] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs as [String: Any])
        output.suppressesPlayerRendering = true // we own presentation; AVPlayer shouldn't also draw
        item.add(output)
        self.videoOutput = output

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                switch item.status {
                case .readyToPlay:
                    self.state = .readyToPlay
                    self.startDisplayLink()
                    if autoplay { self.play() }
                case .failed:
                    self.state = .failed
                default:
                    break
                }
            }
        }

        player.replaceCurrentItem(with: item)
    }

    // MARK: - Transport controls

    public func play() {
        guard state == .readyToPlay || state == .paused else { return }
        player.play()
        state = .playing
    }

    public func pause() {
        guard state == .playing else { return }
        player.pause()
        state = .paused
    }

    public func seek(to time: CMTime) {
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - Display link: the actual sync mechanism

    private func startDisplayLink() {
        stopDisplayLink()

        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else { return }

        let callback: CVDisplayLinkOutputCallback = { (_, _, outputTime, _, _, context) -> CVReturn in
            let player = Unmanaged<SyncedVideoPlayer>.fromOpaque(context!).takeUnretainedValue()
            player.handleDisplayLinkTick(outputTime: outputTime)
            return kCVReturnSuccess
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(link, callback, context)
        CVDisplayLinkStart(link)
        displayLink = link
    }

    private func stopDisplayLink() {
        if let link = displayLink {
            CVDisplayLinkStop(link)
        }
        displayLink = nil
    }

    /// This is the heart of the sync guarantee. We do NOT track "the next frame" — we
    /// ask AVFoundation for whatever frame corresponds to right now, every single tick.
    /// If processing fell behind on the previous frame, we simply skip straight to the
    /// frame that matches current audio time instead of catching up frame-by-frame —
    /// that IS the resync.
    private func handleDisplayLinkTick(outputTime: UnsafePointer<CVTimeStamp>) {
        // Never let two ticks process concurrently. If we're still busy on a previous
        // frame when this fires, just drop this tick — the next tick will ask for
        // whatever time it is BY THEN, which re-syncs us rather than queuing up staleness.
        isProcessingFrame.lock()
        if processingInFlight {
            isProcessingFrame.unlock()
            return
        }
        processingInFlight = true
        isProcessingFrame.unlock()

        processingQueue.async { [weak self] in
            defer {
                self?.isProcessingFrame.lock()
                self?.processingInFlight = false
                self?.isProcessingFrame.unlock()
            }
            guard let self, let output = self.videoOutput else { return }

            // Use CURRENT player time, not the stale hostTime from the displaylink tick.
            // When processing is slow, the tick's hostTime is long past and
            // hasNewPixelBuffer() fails because no buffer exists for that timestamp.
            let now = player.currentItem?.currentTime() ?? CMTime.zero

            guard now.isValid, output.hasNewPixelBuffer(forItemTime: now) else { return }

            var displayTime = CMTime.zero
            guard let pixelBuffer = output.copyPixelBuffer(
                forItemTime: now,
                itemTimeForDisplay: &displayTime
            ) else { return }

            let processed = self.frameProcessor?(pixelBuffer, displayTime) ?? pixelBuffer

            let capturedTime = displayTime
            DispatchQueue.main.async {
                self.frameRenderer?(processed, capturedTime)
            }
        }
    }
}

/// Converts a CVTimeStamp's raw mach host time into seconds, which is the unit
/// AVPlayerItemVideoOutput.itemTime(forHostTime:) expects.
private func machTimeToSeconds(_ hostTime: UInt64) -> CFTimeInterval {
    var timebase = mach_timebase_info()
    mach_timebase_info(&timebase)
    let nanos = Double(hostTime) * Double(timebase.numer) / Double(timebase.denom)
    return nanos / 1_000_000_000
}
