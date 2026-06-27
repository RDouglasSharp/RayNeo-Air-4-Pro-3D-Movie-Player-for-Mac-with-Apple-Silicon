import SwiftUI
import MetalKit

// MARK: - Main Window View

struct MainWindowView: View {
    @EnvironmentObject var appDelegate: AppDelegate
    @ObservedObject var appState: AppState
    @State private var isPlaying: Bool = false
    @State private var scrubPosition: Double? = nil  // non-nil only while dragging

    init(appState: AppState) {
        self.appState = appState
        _isPlaying = State(initialValue: appState.isPlaying)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Metal rendering view
            MetalRenderer()
                .background(Color.black)

            // Scrubber bar — drag to seek, releases trigger a single seek call.
            GeometryReader { geo in
                let duration = appState.duration > 0 ? appState.duration : 1
                let displayPos = scrubPosition ?? appState.playbackPosition
                let progress = max(0, min(1, displayPos / duration))

                ZStack(alignment: .leading) {
                    // Track
                    Rectangle()
                        .fill(Color.white.opacity(0.15))
                        .frame(height: 3)
                    // Fill
                    Rectangle()
                        .fill(Color.green)
                        .frame(width: geo.size.width * progress, height: 3)
                    // Thumb — only visible while scrubbing
                    if scrubPosition != nil {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 10, height: 10)
                            .offset(x: geo.size.width * progress - 5)
                    }
                }
                .frame(maxHeight: .infinity)   // fill the 16pt hit area
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let fraction = max(0, min(1, value.location.x / geo.size.width))
                            scrubPosition = fraction * duration
                        }
                        .onEnded { value in
                            let fraction = max(0, min(1, value.location.x / geo.size.width))
                            appState.playbackPosition = fraction * duration
                            appDelegate.seekToPosition()
                            scrubPosition = nil
                        }
                )
            }
            .frame(height: 16)  // tall hit target; bar itself is 3pt inside

            // Playback controls bar
            HStack {
                Button(action: {
                    appDelegate.togglePlayback()
                }) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                }

                Button(action: {
                    appDelegate.stepFrame()
                }) {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                }

                Spacer()

                Text("STEREO 3D")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.green)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.8))
        }
        .onReceive(appState.$isPlaying) { isPlaying = $0 }
        .onAppear {
            logDebug("MAINWINDOW onAppear fire\n")
            // If the restored frame is larger than the main screen (e.g. saved while
            // on the 3840×1080 RayNeo display), snap back to a sensible default.
            if let window = NSApplication.shared.mainWindow,
               let screen = NSScreen.main {
                let safe = screen.visibleFrame
                if window.frame.width > safe.width || window.frame.height > safe.height {
                    let w: CGFloat = 960
                    let h: CGFloat = 560
                    let origin = CGPoint(x: safe.midX - w / 2, y: safe.midY - h / 2)
                    window.setFrame(NSRect(origin: origin, size: CGSize(width: w, height: h)),
                                    display: true)
                }
            }
            appDelegate.startRayNeoDisplayMonitoring()
            #if STEREO_AUTOPLAY
            logDebug("MAINWINDOW calling loadVideoAndAutoPlay: \(AppDelegate.autoPlayURL.path)\n")
            appDelegate.loadVideoAndAutoPlay(at: AppDelegate.autoPlayURL)
            #endif
        }
    }
}
