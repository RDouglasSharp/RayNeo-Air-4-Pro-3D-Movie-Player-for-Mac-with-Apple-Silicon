import Foundation
import AVFoundation
import QuartzCore

// MARK: - Video Player State Enum
public enum PlayerState {
    case idle
    case loading
    case playing
    case paused
    case stopped
    case error(String)
}

// MARK: - Video Decoder Protocol
public protocol VideoDecoderProtocol: AnyObject {
    var videoWidth: Int { get }
    var videoHeight: Int { get }
    var frameRate: Double { get }
    var duration: Double { get }
    
    func decodeNextFrame() throws -> CVBuffer?
    func seek(to timestamp: Double) throws
    func stop()
}

// MARK: - Metadata
public struct VideoMetadata: CustomStringConvertible {
    public let decoderName: String
    public let pixelFormat: String
    public let width: Int
    public let height: Int
    public let fps: Double
    public let bitrate: Int64
    public let duration: Double
    public let formatName: String
    
    public var description: String {
        """
        Decoder: \(decoderName)
        Pixel Format: \(pixelFormat)
        Resolution: \(width) × \(height)
        FPS: \(String(format: "%.2f", fps))
        Bitrate: \(formatBitsPerSecond(bitrate))
        Duration: \(formatDuration(duration))
        Format: \(formatName)
        """
    }
    
    private func formatBitsPerSecond(_ bitrate: Int64) -> String {
        let mbps = Double(bitrate) / 1_000_000
        return String(format: "%.1f Mbps", mbps)
    }
    
    private func formatDuration(_ duration: Double) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}

// MARK: - Framed Delegate
public protocol FrameReadyHandler: AnyObject {
    func frameReady(pixelBuffer: CVPixelBuffer, timestamp: CMTime)
    func decodeError(error: Error)
    func seekComplete()
}

// MARK: - Video Output (Frame Sink)
public class VideoOutputSink {
    weak var handler: FrameReadyHandler?
    
    private let pixelBufferAttributes: [String: Any]
    
    public init(handler: FrameReadyHandler?) {
        self.handler = handler
        self.pixelBufferAttributes = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
    }
    
    public func attach(pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        handler?.frameReady(pixelBuffer: pixelBuffer, timestamp: timestamp)
    }
    
    public func signalError(_ error: Error) {
        handler?.decodeError(error: error)
    }
}

// MARK: - Player Protocol
public protocol VideoPlayerProtocol: AnyObject {
    var state: PlayerState { get }
    var metadata: VideoMetadata? { get }
    var currentTimestamp: Double { get }
    var currentFrame: CVPixelBuffer? { get }
    
    func play(url: URL) async
    func pause()
    func resume()
    func seek(to timestamp: Double)
    func stop()
}

// MARK: - Frame Metadata
public struct FrameTemp {
    public let pixelBuffer: CVPixelBuffer
    public let timestamp: CMTime
    public let isKeyFrame: Bool
    
    public init(pixelBuffer: CVPixelBuffer, timestamp: CMTime, isKeyFrame: Bool = false) {
        self.pixelBuffer = pixelBuffer
        self.timestamp = timestamp
        self.isKeyFrame = isKeyFrame
    }
}
