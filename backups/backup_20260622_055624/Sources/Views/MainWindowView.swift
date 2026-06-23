import SwiftUI
import MetalKit

// MARK: - Main Window View

struct MainWindowView: View {
    @State private var isPlaying = false

    var body: some View {
        VStack(spacing: 0) {
            // Metal rendering view
            MetalRenderer()
                .background(Color.black)

            // Playback controls bar
            HStack {
                Button(action: {
                    isPlaying.toggle()
                }) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                }

                Button(action: {
                    // Step frame
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
    }
}
