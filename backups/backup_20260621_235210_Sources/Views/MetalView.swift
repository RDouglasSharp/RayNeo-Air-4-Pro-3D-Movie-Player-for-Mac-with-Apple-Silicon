import SwiftUI
import MetalKit

// MARK: - Interop Wrapper
// Wraps MetalRendererView for SwiftUI

struct MetalRenderer: NSViewRepresentable {
    @Binding var appState: AppState
    
    func makeNSView(context: Context) -> NSView {
        let view = MetalRendererView(frame: .zero)
        view.initialize()
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        if let rendererView = nsView as? MetalRendererView {
            rendererView.updateBaseline(appState.baseline)
            rendererView.updateFocalLength(appState.focalLength)
            rendererView.updateFillMode(appState.fillMode)
        }
    }
}
