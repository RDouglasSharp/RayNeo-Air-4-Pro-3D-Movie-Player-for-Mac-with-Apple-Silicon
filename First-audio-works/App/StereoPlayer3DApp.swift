import SwiftUI
import MetalKit
import AVFoundation
import UniformTypeIdentifiers
import Darwin

// MARK: - Main App Entry Point

@main
struct StereoPlayer3DApp: App {
    @StateObject private var appDelegate = AppDelegate()

    var body: some Scene {
        WindowGroup {
            MainWindowView()
                .environmentObject(appDelegate)
                .environmentObject(appDelegate.appState)
                .frame(minWidth: 320, minHeight: 180)
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
            
            CommandMenu("Debug") {
                Button("Record Test Harness (5s)") {
                    appDelegate.startTestHarness()
                }
            }
        }
        #if os(macOS)
        .handlesExternalEvents(matching: ["stereoplayer3d"])
        #endif
    }
}

// MARK: - Debug helpers extension

extension AppDelegate {
    func startTestHarness() {
        guard let renderer = metalRenderer else {
            appState.pipelineStatus = "Renderer not ready"
            return
        }

        // Pick a video file
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.video, .movie]
        
        guard panel.runModal() == .OK, let videoURL = panel.url else { return }

        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_output_\(Int(Date().timeIntervalSince1970)).mp4")

        let modelURL = Bundle.main.resourceURL?
            .appendingPathComponent("DepthAnythingV2SmallF16.mlmodelc")
            .absoluteString ?? ""

        renderer.loadVideoForTest(
            at: videoURL,
            outputURL: outputURL,
            modelURL: modelURL
        )

        appState.pipelineStatus = "Recording → \(outputURL.path)"
        appState.isPlaying = true

        // Auto-stop after 5 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.testStop()
        }
    }

    func testStop() {
        guard let renderer = metalRenderer else { return }
        renderer.stop()
        appState.isPlaying = false
        appState.pipelineStatus = "Recording complete — check /tmp/"
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

final class AppDelegate: NSObject, ObservableObject {
    @Published var appState = AppState()
    var metalRenderer: MetalRendererView?
    
    #if STEREO_AUTOPLAY
    static let autoPlayURL = URL(fileURLWithPath: "/Users/doug/Movies/GracieAbramsThatsSoTrueLiveAtRadioCityMusicHall.mp4")
    #endif
    
    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType.movie,
            UTType.video,
            UTType(filenameExtension: "mkv") ?? UTType.video,
        ]
        panel.allowsMultipleSelection = false
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                self.loadVideo(at: url)
            }
        }
    }
    
    func loadVideo(at url: URL) {
        guard let renderer = metalRenderer else {
            appState.pipelineStatus = "Error: MetalRenderer not ready"
            return
        }
        
        renderer.loadVideo(at: url)
        
        DispatchQueue.global(qos: .userInitiated).async {
            let info = renderer.videoInfo
            DispatchQueue.main.async {
                self.appState.updateVideoInfo(
                    width: info.width,
                    height: info.height,
                    codec: info.codec,
                    fps: info.fps,
                    duration: info.duration
                )
                self.appState.pipelineStatus = "Video loaded — press Space to play"
                self.appState.isPlaying = false
            }
        }
    }
    
    /// DEBUG: Auto-load video and start playback immediately.
    func loadVideoAndAutoPlay(at url: URL) {
        logDebug("AUTOPLAY called, metalRenderer=\(metalRenderer != nil ? "OK" : "nil")\n")
        guard let renderer = metalRenderer else {
            appState.pipelineStatus = "Error: MetalRenderer not ready"
            return
        }
        
        renderer.loadVideo(at: url)
        
        logDebug("AUTOPLAY async after video load\n")
        DispatchQueue.global(qos: .userInitiated).async {
            logDebug("AUTOPLAY bg thread get videoInfo\n")
            let info = renderer.videoInfo
            logDebug("AUTOPLAY bg thread got videoInfo\n")
            DispatchQueue.main.async {
                logDebug("AUTOPLAY main thread update and start\n")
                self.appState.updateVideoInfo(
                    width: info.width,
                    height: info.height,
                    codec: info.codec,
                    fps: info.fps,
                    duration: info.duration
                )
                self.appState.pipelineStatus = "Auto-playing \(url.lastPathComponent)"
                self.appState.isPlaying = true
                renderer.start()
            }
        }
    }
    
    func togglePlayback() {
        guard let renderer = metalRenderer else { return }
        if appState.isPlaying {
            renderer.stop()
            appState.isPlaying = false
        } else {
            renderer.start()
            appState.isPlaying = true
        }
    }
    
    func stepFrame() {
        guard let renderer = metalRenderer else { return }
        renderer.stepFrame()
    }
    
    func seekToPosition() {
        guard let renderer = metalRenderer else { return }
        renderer.seek(to: appState.playbackPosition)
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
