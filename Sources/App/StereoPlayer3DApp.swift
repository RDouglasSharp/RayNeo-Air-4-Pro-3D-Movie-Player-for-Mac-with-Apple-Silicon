import SwiftUI
import MetalKit
import AVFoundation
import UniformTypeIdentifiers
import Darwin
import Combine

// MARK: - Main App Entry Point

@main
struct StereoPlayer3DApp: App {
    @StateObject private var appDelegate = AppDelegate()

    var body: some Scene {
        WindowGroup {
            MainWindowView(appState: appDelegate.appState)
                .environmentObject(appDelegate)
                .environmentObject(appDelegate.appState)
                .frame(minWidth: 320, minHeight: 180)
        }
        .defaultSize(width: 960, height: 560)
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
                Picker("3D Effect", selection: $appDelegate.appState.stereoPreset) {
                    Text("Normal").tag(StereoPreset.normal)
                    Text("Wide").tag(StereoPreset.wide)
                }
                .pickerStyle(.inline)
                .onChange(of: appDelegate.appState.stereoPreset) { preset in
                    appDelegate.applyStereoPreset(preset)
                }
            }

            CommandMenu("Debug") {
                Button("Record Test Harness (5s)") {
                    appDelegate.startTestHarness()
                }

                Divider()

                Slider(value: $appDelegate.appState.baseline, in: 0...200) {
                    Text("Baseline")
                }
                .onChange(of: appDelegate.appState.baseline) { v in
                    appDelegate.metalRenderer?.updateBaseline(v)
                }

                Slider(value: $appDelegate.appState.focalLength, in: 200...1000) {
                    Text("Focal Length")
                }
                .onChange(of: appDelegate.appState.focalLength) { v in
                    appDelegate.metalRenderer?.updateFocalLength(v)
                }

                Picker("Fill Mode", selection: $appDelegate.appState.fillMode) {
                    Text("Nearest").tag(StereoComposer.FillMode.nearest)
                    Text("Mirror").tag(StereoComposer.FillMode.mirror)
                    Text("Color").tag(StereoComposer.FillMode.color)
                }
                .onChange(of: appDelegate.appState.fillMode) { v in
                    appDelegate.metalRenderer?.updateFillMode(v)
                }

                Divider()

                Slider(value: $appDelegate.appState.dilationSigma, in: 0.5...12.0) {
                    Text("Blur σ \(String(format: "%.1f", appDelegate.appState.dilationSigma))")
                }
                .onChange(of: appDelegate.appState.dilationSigma) { _ in
                    appDelegate.applyDepthDilation()
                }

                Slider(value: $appDelegate.appState.dilationRadiusH, in: 1...20) {
                    Text("Dilation H \(Int(appDelegate.appState.dilationRadiusH))")
                }
                .onChange(of: appDelegate.appState.dilationRadiusH) { _ in
                    appDelegate.applyDepthDilation()
                }

                Slider(value: $appDelegate.appState.dilationRadiusV, in: 1...12) {
                    Text("Dilation V \(Int(appDelegate.appState.dilationRadiusV))")
                }
                .onChange(of: appDelegate.appState.dilationRadiusV) { _ in
                    appDelegate.applyDepthDilation()
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

// MARK: - Stereo Preset

enum StereoPreset: Equatable {
    case normal
    case wide

    var baselineValue: Float {
        switch self {
        case .normal: return 16.0
        case .wide:   return 48.0
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
    @Published var stereoPreset: StereoPreset = .normal
    @Published var baseline: Float = 16.0
    @Published var focalLength: Float = 512.0
    @Published var fillMode: StereoComposer.FillMode = .nearest
    // Depth dilation parameters (tunable in Debug menu)
    @Published var dilationSigma: Float = 2.0
    @Published var dilationRadiusH: Float = 5
    @Published var dilationRadiusV: Float = 3
    
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

@MainActor
final class AppDelegate: NSObject, ObservableObject {
    @Published var appState = AppState()
    var metalRenderer: MetalRendererView?
    var rayNeoMonitor: RayNeoDisplayMonitor?
    private var cancellables = Set<AnyCancellable>()

    #if STEREO_AUTOPLAY
    static let autoPlayURL = URL(fileURLWithPath: "test.mp4")
    #endif

    override init() {
        super.init()
        // Keep StereoComposer in sync whenever the preset changes via the menu.
        appState.$stereoPreset
            .receive(on: DispatchQueue.main)
            .sink { [weak self] preset in
                self?.metalRenderer?.updateBaseline(preset.baselineValue)
                self?.appState.baseline = preset.baselineValue
            }
            .store(in: &cancellables)
    }

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
        renderer.onTimeUpdate = { [weak self] t, d in
            self?.appState.playbackPosition = t
            if d > 0 { self?.appState.duration = d }
        }
        renderer.loadVideo(at: url, startPlayback: false)
        let info = renderer.videoInfo
        appState.updateVideoInfo(width: info.width, height: info.height,
                                 codec: info.codec, fps: info.fps, duration: info.duration)
        appState.pipelineStatus = "Video loaded — press Space to play"
        appState.isPlaying = false
    }
    
    /// DEBUG: Auto-load video and start playback immediately.
    func loadVideoAndAutoPlay(at url: URL) {
        logDebug("AUTOPLAY called, metalRenderer=\(metalRenderer != nil ? "OK" : "nil")\n")
        guard let renderer = metalRenderer else {
            appState.pipelineStatus = "Error: MetalRenderer not ready"
            return
        }
        renderer.onTimeUpdate = { [weak self] t, d in
            self?.appState.playbackPosition = t
            if d > 0 { self?.appState.duration = d }
        }
        renderer.loadVideo(at: url)
        let info = renderer.videoInfo
        appState.updateVideoInfo(width: info.width, height: info.height,
                                 codec: info.codec, fps: info.fps, duration: info.duration)
        appState.pipelineStatus = "Auto-playing \(url.lastPathComponent)"
        appState.isPlaying = true
        renderer.start()
    }
    
    func togglePlayback() {
        guard let renderer = metalRenderer else { return }
        if appState.isPlaying {
            renderer.pause()
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

    func applyStereoPreset(_ preset: StereoPreset) {
        appState.baseline = preset.baselineValue
        metalRenderer?.updateBaseline(preset.baselineValue)
    }

    func applyDepthDilation() {
        metalRenderer?.updateDepthDilation(
            sigma: appState.dilationSigma,
            radiusH: Int(appState.dilationRadiusH),
            radiusV: Int(appState.dilationRadiusV)
        )
    }

    /// Start monitoring for RayNeo Air 4 Pro display.
    func startRayNeoDisplayMonitoring() {
        let monitor = RayNeoDisplayMonitor()
        monitor.didFindDisplay = { [weak monitor] screen in
            DispatchQueue.main.async {
                logDebug("RAYNEO: display found — moving window\n")
                guard let window = NSApplication.shared.mainWindow else { return }
                monitor?.moveWindowToScreen(window, screen: screen)
            }
        }
        monitor.didLosingDisplay = { [weak monitor] in
            DispatchQueue.main.async {
                logDebug("RAYNEO: display lost — returning to main screen\n")
                guard let window = NSApplication.shared.mainWindow else { return }
                monitor?.moveWindowToMainScreen(window)
            }
        }
        monitor.startPolling()
        self.rayNeoMonitor = monitor
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
