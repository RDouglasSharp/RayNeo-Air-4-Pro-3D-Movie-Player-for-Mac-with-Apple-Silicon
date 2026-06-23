import Foundation
import AVFoundation
import CoreVideo
import Metal
import QuartzCore

// MARK: - Timing Entry

/// Per-frame timing record: latency at each pipeline stage (ms).
public struct FrameTiming: Codable {
    public let frame: Int
    public let timestamp: TimeInterval // presentation timestamp (seconds)
    public let decodeMs: Double
    public let depthMs: Double
    public let warpMs: Double
    public let composeMs: Double
    public let recordMs: Double
    public let totalMs: Double
    public let fps: Double

    public init(
        frame: Int,
        timestamp: TimeInterval,
        decodeMs: Double,
        depthMs: Double,
        warpMs: Double,
        composeMs: Double,
        recordMs: Double,
        totalMs: Double,
        fps: Double
    ) {
        self.frame = frame
        self.timestamp = timestamp
        self.decodeMs = decodeMs
        self.depthMs = depthMs
        self.warpMs = warpMs
        self.composeMs = composeMs
        self.recordMs = recordMs
        self.totalMs = totalMs
        self.fps = fps
    }
}

// MARK: - Timing Report

/// Aggregate timing report: per-frame entries + statistics + hardware info.
/// Written as JSON alongside test output SBS video file for validation.
public struct TimingReport: Codable {
    // Input metadata
    public let sourceURL: String
    public let outputURL: String
    public let date: String
    public let hardwareInfo: String
    public let videoWidth: Int
    public let videoHeight: Int
    public let videoFPS: Double
    public let videoDuration: Double
    public let modelURL: String

    // Aggregate statistics
    public let totalFrames: Int
    public let processedFrames: Int
    public let wallClockSeconds: Double
    public let outputFPS: Double

    // Latency percentiles (ms)
    public let avgTotalMs: Double
    public let medianMs: Double  // p50
    public let p95Ms: Double
    public let p99Ms: Double
    public let maxMs: Double
    public let minMs: Double

    // Stage breakdown (ms)
    public let avgDecodeMs: Double
    public let avgDepthMs: Double
    public let avgWarpMs: Double
    public let avgComposeMs: Double
    public let avgRecordMs: Double

    // Real-time pass/fail
    public let realtimeGrade: String  // "PASS" if p95 < 33ms (30fps budget)

    // Per-frame data
    public let frames: [FrameTiming]

    public init(
        sourceURL: String,
        outputURL: String,
        date: String,
        hardwareInfo: String,
        videoWidth: Int,
        videoHeight: Int,
        videoFPS: Double,
        videoDuration: Double,
        modelURL: String,
        frames: [FrameTiming],
        wallClockSeconds: Double
    ) {
        self.sourceURL = sourceURL
        self.outputURL = outputURL
        self.date = date
        self.hardwareInfo = hardwareInfo
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
        self.videoFPS = videoFPS
        self.videoDuration = videoDuration
        self.modelURL = modelURL
        self.frames = frames
        self.wallClockSeconds = wallClockSeconds
        self.processedFrames = frames.count
        self.totalFrames = Int(videoDuration * videoFPS)
        self.outputFPS = Double(processedFrames) / max(wallClockSeconds, 0.001)

        let totalTimes = frames.map { $0.totalMs }
        let sorted = totalTimes.sorted()
        let n = sorted.count

        self.minMs = sorted.first ?? 0
        self.avgTotalMs = totalTimes.reduce(0, +) / Double(n)
        self.medianMs = n > 0 ? sorted[Int(Double(n) * 0.5)] : 0
        self.p95Ms = n > 0 ? sorted[min(Int(Double(n) * 0.95), n - 1)] : 0
        self.p99Ms = n > 0 ? sorted[min(Int(Double(n) * 0.99), n - 1)] : 0
        self.maxMs = sorted.last ?? 0

        self.avgDecodeMs = frames.map { $0.decodeMs }.reduce(0, +) / Double(n)
        self.avgDepthMs = frames.map { $0.depthMs }.reduce(0, +) / Double(n)
        self.avgWarpMs = frames.map { $0.warpMs }.reduce(0, +) / Double(n)
        self.avgComposeMs = frames.map { $0.composeMs }.reduce(0, +) / Double(n)
        self.avgRecordMs = frames.map { $0.recordMs }.reduce(0, +) / Double(n)

        self.realtimeGrade = self.p95Ms < 33 ? "PASS" : "FAIL"
    }

    /// Serialize to JSON Dump format for human-readable report
    public func toJSONString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        do {
            let data = try encoder.encode(self)
            return String(data: data, encoding: .utf8) ?? "Serialization failed"
        } catch {
            return "JSON encode error: \(error)"
        }
    }

    /// Markdown summary
    public func summary() -> String {
        """
        ## StereoPlayer3D Test Harness Report

        **Source:** \(sourceURL)
        **Output:** \(outputURL)
        **Date:** \(date)
        **Hardware:** \(hardwareInfo)

        ### Video
        \(videoWidth)x\(videoHeight) @ \(videoFPS) fps | \(videoDuration)s duration

        ### Throughput
        \(processedFrames)/\(totalFrames) frames | \(outputFPS) fps | \(wallClockSeconds)

        ### Latency (ms)
        | Stat | Latency | Real-time (30fps) |
        |------|---------|-------------------|
        | Avg  | \(avgTotalMs)ms | OK |
        | P50  | \(medianMs)ms | OK |
        | P95  | \(p95Ms)ms | OK |
        | P99  | \(p99Ms)ms | OK |
        | Max  | \(maxMs)ms | OK |

        ### Stage Breakdown (avg ms)
        | Stage | Avg |
        |-------|-----|
        | Decode | \(avgDecodeMs)ms |
        | Depth | \(avgDepthMs)ms |
        | Warp | \(avgWarpMs)ms |
        | Compose | \(avgComposeMs)ms |
        | Record | \(avgRecordMs)ms |

        ### Grade: \(realtimeGrade)
        """
    }
}

// MARK: - Test Harness Recorder

/// Records stereo SBS output to MP4 file with per-frame timing metadata.
/// Used for offline pipeline validation:
/// 1. Writes SBS video (3840x1080) via AVAssetWriter
/// 2. Collects FrameTiming for every processed frame
/// 3. On completion, writes TimingReport JSON to disk
public class TestHarnessRecorder {
    private var assetWriter: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var adapter: AVAssetWriterInputPixelBufferAdaptor?
    private var isReady = false
    private var frameCount = 0
    private var startTimestamp: TimeInterval = 0
    private var totalLatency: Double = 0

    /// Collected framings
    private var timings: [FrameTiming]

    /// Output file URL for SBS video
    public let outputURL: URL

    /// Timing report JSON output URL (same dir, .json extension)
    public var reportURL: URL {
        var components = outputURL.pathComponents
        components.removeLast()
        components.append(outputURL.deletingPathExtension().lastPathComponent + "_timing.json")
        return URL(fileURLWithPath: components.joined(separator: "/"))
    }

    public init(outputURL: URL) {
        self.outputURL = outputURL
        self.timings = []
    }

    // MARK: - Setup

    /// Initialize AVAssetWriter for SBS video recording.
    ///
    /// Creates a lossy H.264 video with BT.2020 color range SBS output.
    ///
    /// Failure to record will fallback to H.264 with higher bitrate option.
    public func startRecording(width: Int, height: Int, fps: Double) throws {
        guard assetWriter == nil else { throw TestHarnessError.alreadyStarted }

        let outputSize = CGSize(width: width, height: height)

        // H.264 video with high quality for validation
        let videoSettings: [String: Any]
        videoSettings = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                "AVVideoAverageBitrateKey": max(20, Int(width * height * Double(fps) * 0.4)),
                AVVideoMaxKeyFrameIntervalKey: Int(fps),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ]
        ]

        assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        videoWriterInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: videoSettings
        )
        videoWriterInput?.expectsMediaDataInRealTime = true

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        adapter = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoWriterInput!,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )

        guard let writer = assetWriter, let input = videoWriterInput,
              writer.canAdd(input) else {
            throw TestHarnessError.setupFailed
        }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        isReady = true
        frameCount = 0
        totalLatency = 0
        startTimestamp = Date().timeIntervalSince1970
    }

    // MARK: - Frame Submission

    /// Submit a rendered SBS CVPixelBuffer with timing data.
    ///
    /// This is the main entry point for the render loop. Call after
    /// stereo composition to record the frame + timing.
    ///
    /// - Parameters:
    ///   - pixelBuffer: SBS stereo frame (3840x1080, BGRA)
    ///   - timing: Per-frame pipeline timings
    /// - Returns: true if frame was accepted, false if recording is paused or full
    @discardableResult
    public func appendFrame(_ pixelBuffer: CVPixelBuffer, timing: FrameTiming) -> Bool {
        guard isReady,
              let writer = assetWriter,
              let input = videoWriterInput,
              let adaptor = adapter,
              writer.status == .writing else {
            return false
        }

        guard input.isReadyForMoreMediaData else {
            usleep(1_000)
            guard input.isReadyForMoreMediaData else { return false }
        }

        let presentationTime = CMTime(
            seconds: Double(frameCount) / 30,
            preferredTimescale: 600
        )

        if adaptor.append(pixelBuffer, withPresentationTime: presentationTime) {
            frameCount += 1
            timings.append(timing)
            totalLatency += timing.totalMs
            return true
        }
        return false
    }

    // MARK: - Completion

    /// Finalize recording and write JSON timing report to disk.
    ///
    /// Must be called after all frames are submitted. Finishes the
    /// AVAssetWriter session, waits for it to complete, then writes
    /// the TimingReport JSON alongside the SBS video.
    ///
    /// - Parameter videoSource: Source video metadata for report
    /// - Returns: Path to JSON report file, plus console summary output
    public func finish(
        sourceURL: String,
        videoWidth: Int,
        videoHeight: Int,
        videoFPS: Double,
        videoDuration: Double,
        modelURL: String
    ) throws -> TimingReport {
        guard let writer = assetWriter, writer.status == .writing else {
            throw TestHarnessError.notRecording
        }

        videoWriterInput?.markAsFinished()

        // Synchronous wait for completion
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting {
            semaphore.signal()
        }
        semaphore.wait();

        let wallClock = Date().timeIntervalSince1970 - startTimestamp

        let report = TimingReport(
            sourceURL: sourceURL,
            outputURL: outputURL.path,
            date: ISO8601DateFormatter().string(from: Date()),
            hardwareInfo: Self.hardwareInfo(),
            videoWidth: videoWidth,
            videoHeight: videoHeight,
            videoFPS: videoFPS,
            videoDuration: videoDuration,
            modelURL: modelURL,
            frames: timings,
            wallClockSeconds: wallClock
        )

        // Write JSON report
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonData = try encoder.encode(report)
        try jsonData.write(to: reportURL)

        // Print summary to console
        print("\n========== Test Harness Report ==========")
        print("Output: \(outputURL.path)")
        print("Report: \(reportURL.path)")
        print("Frames: \(timings.count)")
        print("Wall clock: \(wallClock)")
        print("Avg latency: \(report.avgTotalMs, specifier: "%.2f")ms")
        print("p95 latency: \(report.p95Ms, specifier: "%.2f")ms")
        print("Max latency: \(report.maxMs, specifier: "%.2f")ms")
        print("Real-time grade: \(report.realtimeGrade)")
        print("==========================================\n")

        return report
    }

    public func cancel() {
        guard let writer = assetWriter else { return }
        switch writer.status {
        case .writing, .completed:
            if let input = videoWriterInput {
                input.markAsFinished()
                writer.cancelWriting()
            }
        default:
            break
        }
        isReady = false
    }

    // MARK: - Hardware Info

    private static func hardwareInfo() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let chip = String(cString: model)

        var mem: UInt64 = 0
        var sizeMem = MemoryLayout<UInt64>.stride
        sysctlbyname("hw.memsize", &mem, &sizeMem, nil, 0)
        let gb = mem / 1_073_741_824

        return "\(chip) (\(gb)GB RAM)"
    }
}

// MARK: - Error Types

public enum TestHarnessError: LocalizedError {
    case alreadyStarted
    case setupFailed
    case notRecording

    public var errorDescription: String? {
        switch self {
        case .alreadyStarted: "Recording already started"
        case .setupFailed: "Failed to set up AVAssetWriter"
        case .notRecording: "Recorder is not running"
        }
    }
}
