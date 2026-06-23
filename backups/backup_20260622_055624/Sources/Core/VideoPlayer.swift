import Foundation
import AVFoundation

/// High-level video player that wraps a decoder and drives frame delivery.
public class VideoPlayer: NSObject, ObservableObject, VideoPlayerProtocol {
    private let logError: (String) -> Void = { print($0) }
    
    public var state: PlayerState = .idle
    public var metadata: VideoMetadata?
    public var currentTimestamp: Double = 0
    public var currentFrame: CVPixelBuffer?
    
    private var decoder: VideoDecoderProtocol?
    private var playerTask: Task<Void, Never>?
    private var sink: VideoOutputSink?
    
    private var videoURL: URL?
    
    /// Convenience: current video info for the UI.
    var videoInfo: VideoInfo {
        VideoInfo(
            width: decoder?.videoWidth ?? 0,
            height: decoder?.videoHeight ?? 0,
            codec: metadata?.decoderName ?? "",
            fps: decoder?.frameRate ?? 0,
            duration: decoder?.duration ?? 0
        )
    }
    
    // MARK: - PlayerProtocol conformance
    
    public func play(url: URL) async {
        await MainActor.run {
            self.state = .loading
        }
        
        do {
            self.videoURL = url
            self.decoder = try await Self.createDecoder(for: url)
            self.metadata = await createMetadata()
            
            await MainActor.run {
                self.state = .playing
            }
            
            await decodeLoop()
        } catch {
            logError("Playback failed: \(error.localizedDescription)")
            await MainActor.run {
                self.state = .error(error.localizedDescription)
            }
        }
    }
    
    public func pause() {
        self.playerTask?.cancel()
        self.decoder?.stop()
    }
    
    public func resume() {
        self.playerTask?.cancel()
        Task {
            await decodeLoop()
        }
    }
    
    public func seek(to timestamp: Double) {
        do {
            try self.decoder?.seek(to: timestamp)
            self.currentTimestamp = timestamp
        } catch {
            logError("Seek failed: \(error.localizedDescription)")
        }
    }
    
    public func stop() {
        self.playerTask?.cancel()
        self.decoder?.stop()
        self.decoder = nil
        self.metadata = nil
        self.currentTimestamp = 0
        self.currentFrame = nil
        self.videoURL = nil
    }
    
    // MARK: - UI-friendly methods used by AppDelegate
    
    /// Open a video file at the given URL.
    func openVideo(at url: URL) async throws {
        self.videoURL = url
        self.decoder = try await Self.createDecoder(for: url)
        self.metadata = await createMetadata()
    }
    
    /// Toggle between playing and paused.
    func togglePlayback() {
        switch state {
        case .playing:
            pause()
            state = .paused
        case .paused:
            resume()
            state = .playing
        default:
            if let url = videoURL {
                Task {
                    await play(url: url)
                }
            }
        }
    }
    
    /// Step forward by one frame.
    func stepFrame() {
        guard let decoder = decoder else { return }
        do {
            if let frame = try decoder.decodeNextFrame() {
                currentFrame = frame
            }
        } catch {
            logError("Step frame failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Internal
    
    private func decodeLoop() async {
        guard let decoder = decoder else { return }
        
        while !Task.isCancelled {
            let startTime = CFAbsoluteTimeGetCurrent()
            
            do {
                guard let buffer = try decoder.decodeNextFrame() else { break }
                
                let presentationTime = CMTimeGetSeconds(CMTime.zero)
                currentTimestamp = presentationTime
                currentFrame = buffer
                
                self.sink?.attach(pixelBuffer: buffer, timestamp: CMTime(seconds: presentationTime, preferredTimescale: 600))
                
                let frameDuration = 1.0 / decoder.frameRate
                let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                let sleepTime = frameDuration - elapsed
                if sleepTime > 0 {
                    try await Task.sleep(nanoseconds: UInt64(sleepTime * 1_000_000_000))
                }
            } catch {
                if !Task.isCancelled {
                    logError("Decode error: \(error.localizedDescription)")
                }
                break
            }
        }
        
        await MainActor.run {
            self.state = .stopped
        }
    }
    
    private func createMetadata() async -> VideoMetadata? {
        guard let decoder = decoder else { return nil }
        return VideoMetadata(
            decoderName: "ffplay",
            pixelFormat: "BGRA",
            width: decoder.videoWidth,
            height: decoder.videoHeight,
            fps: decoder.frameRate,
            bitrate: 0,
            duration: decoder.duration,
            formatName: "mp4"
        )
    }
    
    /// Create the appropriate decoder for a given URL.
    private static func createDecoder(for url: URL) async throws -> VideoDecoderProtocol {
        let decoder = FFmpegDecoder()
        try decoder.loadVideo(at: url)
        return decoder
    }
}
