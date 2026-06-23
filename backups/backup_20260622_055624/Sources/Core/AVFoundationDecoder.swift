import AVFoundation
import CoreVideo

/// AVFoundation-based video decoder using AVAssetReader + AVAssetReaderTrackOutput.
///
/// Fallback decoder (no FFmpeg dependency). Supports Apple-native formats.
/// Good for testing without FFmpeg libavcodec linking.
///
/// Note: AVFoundation provides fewer codec options than FFmpeg
/// but has better hardware decoding on Apple Silicon.
public class AVFoundationDecoder: VideoDecoderProtocol {
    private var playerItem: AVPlayerItem?
    private var assetReader: AVAssetReader?
    private var videoTrackOutput: AVAssetReaderTrackOutput?

    private(set) var isPlaying = false
    private var isScanning = false
    private var frameBuffer: CMSampleBuffer?
    private var currentFrameIndex = 0

    public private(set) var videoWidth = 0
    public private(set) var videoHeight = 0
    public private(set) var frameRate: Double = 30.0
    public private(set) var duration: Double = 0

    private var _currentFrame: CVPixelBuffer?
    private var url: URL?
    private var doneScan: Bool = false

    public init() {}

    public func loadVideo(at url: URL) throws {
        self.url = url
        let asset = AVAsset(url: url)
        playerItem = AVPlayerItem(asset: asset)

        // Get video track
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw NSError(domain: "AVFoundationDecoder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No video track found"])
        }

        let naturalSize = videoTrack.naturalSize
        videoWidth = Int(naturalSize.width)
        videoHeight = Int(naturalSize.height)

        // Get frame rate from track time scale
        let duration = videoTrack.timeRange.duration
        frameRate = duration.value != 0
            ? Double(duration.timescale) / Double(duration.value)
            : 30.0

        // Get duration
        let durationSeconds = CMTimeGetSeconds(asset.duration)
        duration = durationSeconds.isNaN ? 0 : durationSeconds

        // Setup asset reader
        assetReader = try AVAssetReader(asset: asset)

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoTrackOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: outputSettings
        )

        if assetReader?.canAdd(videoTrackOutput!) ?? false {
            assetReader?.add(videoTrackOutput!)
        }

        assetReader?.startReading()
    }

    public func decodeNextFrame() throws -> CVBuffer? {
        guard let videoTrackOutput = videoTrackOutput,
              assetReader?.status == .reading
        else {
            return nil
        }

        // Get next sample buffer
        while let sampleBuffer = videoTrackOutput.copyNextSampleBuffer() {
            let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
            currentFrameIndex += 1
            return pixelBuffer as CVBuffer?
        }

        return nil
    }

    public func scanFrames() {
        isScanning = true
        defer { isScanning = false }

        guard let videoTrackOutput = videoTrackOutput,
              assetReader?.status == .reading
        else {
            doneScan = true
            return
        }

        while let sampleBuffer = videoTrackOutput.copyNextSampleBuffer() {
            let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
            currentFrameIndex += 1
        }

        doneScan = true
    }

    public func parseFrames() {
        // Parse/scanning is equivalent to scanning for AVFoundation
        scanFrames()
    }

    /// Convenience wrapper used by the render loop.
    public func decodeFrame() -> CVPixelBuffer? {
        do {
            guard let sample = try decodeNextFrame() else { return nil }
            return sample as? CVPixelBuffer
        } catch {
            return nil
        }
    }

    public func start() {
        guard !isPlaying else { return }
        isPlaying = true
    }

    public func stop() {
        isPlaying = false
        assetReader?.cancelReading()
        playerItem?.seek(to: .zero)
    }

    public func seek(to timestamp: Double) throws {
        guard let playerItem = playerItem else { return }
        let seekTime = CMTime(seconds: timestamp, preferredTimescale: 600)
        playerItem.seek(
            to: seekTime,
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] completed in
            if let self = self, completed {
                print("Seek completed to \(timestamp)")
            }
        }
        // Reset reader
        assetReader?.cancelReading()
        try rebuildAssetReader()
    }

    private func rebuildAssetReader() throws {
        guard let url = url else { return }
        let asset = AVAsset(url: url)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else { return }

        assetReader = try AVAssetReader(asset: asset)

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoTrackOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: outputSettings
        )

        if let vto = videoTrackOutput, assetReader?.canAdd(vto) ?? false {
            assetReader?.add(vto)
        }
        assetReader?.startReading()
    }

    public func pause() {
        isPlaying = false
    }

    public func reset() {
        isPlaying = false
        isScanning = false
        currentFrameIndex = 0
        _currentFrame = nil
        doneScan = false
    }
}
