import SwiftUI
import MetalKit

struct MetalRenderer: NSViewRepresentable {
    @EnvironmentObject var appDelegate: AppDelegate

    func makeNSView(context: Context) -> NSView {
        let view = MetalRendererView(frame: .zero)
        view.initialize()
        appDelegate.metalRenderer = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
