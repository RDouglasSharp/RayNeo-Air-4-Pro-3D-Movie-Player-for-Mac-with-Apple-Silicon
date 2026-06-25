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
            appDelegate.startRayNeoDisplayMonitoring()
            #if STEREO_AUTOPLAY
            logDebug("MAINWINDOW calling loadVideoAndAutoPlay: \(AppDelegate.autoPlayURL.path)\n")
            appDelegate.loadVideoAndAutoPlay(at: AppDelegate.autoPlayURL)
            #endif
        }
    }
}
