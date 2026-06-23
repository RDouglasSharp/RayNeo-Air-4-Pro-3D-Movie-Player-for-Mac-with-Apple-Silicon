import SwiftUI
import MetalKit

// MARK: - Main Window View

struct MainWindowView: View {
    @EnvironmentObject var appState: AppState
    @State private var metalView = MetalRendererView()
    
    var body: some View {
        VStack(spacing: 0) {
            // Metal rendering view
            metalView
                .background(Color.black)
                .onAppear {
                    metalView.initialize()
                }
                .onChange(of: appState.baseline) { newBaseline in
                    metalView.updateBaseline(newBaseline)
                }
                .onChange(of: appState.focalLength) { newFocalLength in
                    metalView.updateFocalLength(newFocalLength)
                }
                .onChange(of: appState.fillMode) { newFillMode in
                    metalView.updateFillMode(newFillMode)
                }
            
            // Playback controls bar
            HStack {
                Button(action: {
                    // Play/Pause
                }) {
                    Image(systemName: appState.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                }
                
                Button(action: {
                    // Step frame
                }) {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                }
                
                Spacer()
                
                Text("\(String(format: "%.1f", appState.fps)) fps")
                    .font(.system(.caption, design: .monospaced))
                
                Text("Latency: \(String(format: "%.0f", appState.latency))ms")
                    .font(.system(.caption, design: .monospaced))
                
                Spacer()
                
                Text("STEREO 3D")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.green)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.8))
        }
    }
}
