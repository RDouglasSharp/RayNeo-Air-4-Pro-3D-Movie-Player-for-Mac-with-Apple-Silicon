import AVFoundation
import Foundation
import os.log

/// Audio player wrapping AVAudioEngine + AVAudioPlayerNode.
final class AudioPlayer {
    private let engine: AVAudioEngine
    private let playerNode: AVAudioPlayerNode
    private let logger = Logger(subsystem: "com.stereoplayer", category: "AudioPlayer")

    /// Audio format (set after loading).
    private(set) var format: AVAudioFormat?

    init() {
        self.engine = AVAudioEngine()
        self.playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)
    }

    /// Configure with sample rate and channels for optimal buffer creation.
    func configure(sampleRate: Double, channels: Int) {
        format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: false
        )
    }

    /// Start audio engine and player node.
    func start() {
        engine.prepare()
        do {
            try engine.start()
        } catch {
            logger.error("Engine start failed: \(error)")
        }
        playerNode.play()
    }

    /// Schedule a PCM buffer for playback.
    func scheduleBuffer(_ buffer: AVAudioPCMBuffer) {
        playerNode.scheduleBuffer(buffer) { [weak self] in
            // Buffer callback — AutoReleasedBlock, must not capture strongly
        }
    }

    /// Stop playback.
    func stop() {
        playerNode.stop()
        engine.stop()
        engine.reset()
    }

    /// Pause playback.
    func pause() {
        playerNode.pause()
    }

    /// Check if playing.
    var isPlaying: Bool {
        playerNode.isPlaying
    }
}
