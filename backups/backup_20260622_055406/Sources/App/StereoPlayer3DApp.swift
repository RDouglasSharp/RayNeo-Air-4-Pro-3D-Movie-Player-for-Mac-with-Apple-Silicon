import SwiftUI
import MetalKit
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Main App Entry Point

@main
struct StereoPlayer3DApp: App {
    @StateObject private var appDelegate = AppDelegate()

    var body: some Scene {
        WindowGroup {
            MainWindowView()
                .environmentObject(appDelegate.appState)
                .frame(minWidth: 1920, minHeight: 1080)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Playback") {
                Button("Open Video...") {
                    appDelegate.showOpenPanel()
                }
                .keyboardShortcut("O", modifiers: .command)
                
                Divider()
                
                Button("Play / Pause") {
                    appDelegate.togglePlayback()
                }
                .keyboardShortcut(" ", modifiers: [])
                
                Button("Step Frame") {
                    appDelegate.stepFrame()
                }
                .keyboardShortcut("S", modifiers: [])
                
                Divider()
                
                Slider(value: $appDelegate.appState.playbackPosition, in: 0...appDelegate.appState.duration, onEditingChanged: { _ in
                    appDelegate.seekToPosition()
                })
                .disabled(appDelegate.appState.duration == 0)
            }
            
            CommandMenu("Stereo") {
                Slider(value: $appDelegate.appState.baseline, in: 0...200) {
                    Text("Baseline")
                }
                
                Slider(value: $appDelegate.appState.focalLength, in: 200...1000) {
                    Text("Focal Length")
                }
                
                Picker("Fill Mode", selection: $appDelegate.appState.fillMode) {
                    Text("Nearest").tag(StereoComposer.FillMode.nearest)
                    Text("Mirror").tag(StereoComposer.FillMode.mirror)
                    Text("Color").tag(StereoComposer.FillMode.color)
                }
            }
            
            CommandMenu("Info") {
                Text("StereoPlayer3D v1.0")
                Divider()
                Text("Video: \(appDelegate.appState.videoInfo)")
                Text("Depth Model: Depth Anything V2-Small")
                Text("Pipeline: Metal/Core ML + FFmpeg")
            }
        }
    }
}

// MARK: - App State (Observable Object)

final class AppState: ObservableObject {
    @Published var isPlaying: Bool = false
    @Published var playbackPosition: Double = 0
    @Published var duration: Double = 0
    @Published var fps: Double = 0
    @Published var latency: Double = 0
    @Published var videoInfo: String = "No video loaded"
    @Published var baseline: Float = 64.0
    @Published var focalLength: Float = 512.0
    @Published var fillMode: StereoComposer.FillMode = .nearest
    
    // Pipeline status
    @Published var pipelineStatus: String = "Ready"
    @Published var depthModelLoaded: Bool = false
    
    func updateVideoInfo(width: Int, height: Int, codec: String, fps: Double, duration: Double) {
        self.videoInfo = "\(width)x\(height) @ \(codec) - \(String(format: "%.1f", fps)) fps, \(String(format: "%.0f", duration))s"
        self.duration = duration
        self.fps = fps
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, ObservableObject, NSApplicationDelegate {
    @Published let appState = AppState()
    var player: VideoPlayer?
    
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
    
    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType.movie!,
            UTType.mp4!,
            UTType(filenameExtension: "mkv") ?? UTType.movie!,
        ]
        panel.allowsMultipleSelection = false
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                self.loadVideo(at: url)
            }
        }
    }
    
    func loadVideo(at url: URL) {
        Task {
            guard let videoPlayer = VideoPlayer() else {
                await MainActor.run {
                    self.appState.pipelineStatus = "Failed to initialize player"
                }
                return
            }
            
            self.player = videoPlayer
            
            do {
                try await videoPlayer.openVideo(at: url)
                
                let info = await videoPlayer.videoInfo
                await MainActor.run {
                    self.appState.updateVideoInfo(
                        width: info.width,
                        height: info.height,
                        codec: info.codec,
                        fps: info.fps,
                        duration: info.duration
                    )
                    self.appState.pipelineStatus = "Video loaded"
                }
            } catch {
                await MainActor.run {
                    self.appState.pipelineStatus = "Failed to open video: \(error.localizedDescription)"
                }
            }
        }
    }
    
    func togglePlayback() {
        player?.togglePlayback()
        appState.isPlaying.toggle()
    }
    
    func stepFrame() {
        player?.stepFrame()
    }
    
    func seekToPosition() {
        player?.seek(to: appState.playbackPosition)
    }
}

// MARK: - Video Info Struct

struct VideoInfo {
    var width: Int = 0
    var height: Int = 0
    var codec: String = ""
    var fps: Double = 0
    var duration: Double = 0
}
