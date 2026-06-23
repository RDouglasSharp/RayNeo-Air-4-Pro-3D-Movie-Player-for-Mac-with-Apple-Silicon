import SwiftUI
import MetalKit

// MARK: - Interop Wrapper
// Wraps MetalRendererView for SwiftUI

struct MetalRenderer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = MetalRendererView(frame: .zero)
        view.initialize()
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {}
}
