import SwiftUI
import MetalKit

// MARK: - Main Window View

struct MainWindowView: View {
    @EnvironmentObject var appDelegate: AppDelegate
    @ObservedObject var appState: AppState
    @State private var isPlaying: Bool = false

    init(appState: AppState) {
        self.appState = appState
        _isPlaying = State(initialValue: appState.isPlaying)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Metal rendering view
            MetalRenderer()
                .background(Color.black)

            // Progress bar — read-only position indicator (phase 1)
            ProgressView(value: appState.playbackPosition,
                         total: appState.duration > 0 ? appState.duration : 1)
                .progressViewStyle(.linear)
                .tint(.green)
                .frame(height: 3)
                .padding(.horizontal, 0)
                .animation(.none, value: appState.playbackPosition)

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
