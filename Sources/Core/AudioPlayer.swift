import AVFoundation
import Foundation

/// Minimal audio player wrapping AVAudioEngine + AVAudioPlayerNode.
/// Step 1: Idle engine only — no scheduling, no integration.
final class AudioPlayer {
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?

    /// Audio sample rate from source (set after loading).
    private(set) var sampleRate: Double = 0

    init() {
        setupEngine()
    }

    private func setupEngine() {
        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
        // Do NOT connect or start — just idle for now
        self.engine = engine
        self.playerNode = playerNode
    }

    func stop() {
        playerNode?.stop()
        engine?.stop()
    }
}
