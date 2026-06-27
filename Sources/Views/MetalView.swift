import SwiftUI
import MetalKit
import Darwin

struct MetalRenderer: NSViewRepresentable {
    @EnvironmentObject var appDelegate: AppDelegate

    func makeNSView(context: Context) -> NSView {
        logDebug("METALRENDER makeNSView\n")
        let view = MetalRendererView(frame: .zero)
        appDelegate.metalRenderer = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        logDebug("METALRENDER updateNSView frame=\(nsView.frame)\n")
    }
    
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        logDebug("METALRENDER sizeThatFits proposal=\(proposal.width ?? 0)x\(proposal.height ?? 0)\n")
        return nil
    }
}
