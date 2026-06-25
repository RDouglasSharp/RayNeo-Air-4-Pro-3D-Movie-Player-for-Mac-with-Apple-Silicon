import Cocoa

/// Polls for RayNeo Air 4 Pro display (3840×1080 SBS mode).
/// Waits for unmirrored state (two screens with different resolutions)
/// before moving window to the glasses display.
/// Falls back to main screen at default size when glasses disconnect.
final class RayNeoDisplayMonitor {
    private let targetWidth: CGFloat = 3840
    private let targetHeight: CGFloat = 1080
    private var pollingTimer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var isPinned = false

    public var didFindDisplay: ((NSScreen) -> Void)?
    public var didLosingDisplay: ((Void) -> Void)?

    /// Start polling for the RayNeo display.
    func startPolling() {
        // Check immediately
        checkAndFire()

        // Listen for screen configuration changes
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkAndFire()
        }

        // Poll every 2 seconds as backup
        pollingTimer = Timer.scheduledTimer(
            withTimeInterval: 2,
            repeats: true
        ) { [weak self] _ in
            self?.checkAndFire()
        }
    }

    private func checkAndFire() {
        guard let glasses = findRayNeoScreen() else {
                isPinned = false
                didLosingDisplay?(Void())
            return
        }

        // Only fire when NOT mirrored (two screens with different resolutions)
        guard !isMirrored() else { return }

        if !isPinned {
            isPinned = true
            didFindDisplay?(glasses)
            stopPolling()
        }
    }

    /// Check if screens are all the same resolution (mirrored state).
    private func isMirrored() -> Bool {
        guard NSScreen.screens.count >= 2 else { return false }
        let first = NSScreen.screens[0].frame.size
        for screen in NSScreen.screens {
            let dw = abs(screen.frame.width - first.width)
            let dh = abs(screen.frame.height - first.height)
            if dw >= 2.0 || dh >= 2.0 { return false }
        }
        return true
    }

    /// Stop polling.
    func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
            self.screenObserver = nil
        }
    }

    private func findRayNeoScreen() -> NSScreen? {
        return NSScreen.screens.first {
            let w = $0.frame.width
            let h = $0.frame.height
            return abs(w - targetWidth) < 2.0 && abs(h - targetHeight) < 2.0
        }
    }

    /// Move a window to the target screen and go fullscreen.
    func moveWindowToScreen(_ window: NSWindow, screen: NSScreen) {
        let targetFrame = screen.frame
        window.collectionBehavior = [.fullScreenNone]
        window.setFrame(targetFrame, display: true, animate: true)
        window.makeKeyAndOrderFront(nil)

        window.collectionBehavior = [.fullScreenPrimary]
        window.level = .floating
        window.toggleFullScreen(nil)
    }

    /// Move window back to main screen at default size, exit fullscreen.
    func moveWindowToMainScreen(_ window: NSWindow) {
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }

        window.collectionBehavior = [.fullScreenNone]
        window.level = .normal

        let mainScreen = NSScreen.main ?? NSScreen.screens[0]
        var targetSize = CGSize(width: 900, height: 379)
        if mainScreen.frame.width < targetSize.width || mainScreen.frame.height < targetSize.height {
            targetSize = CGSize(
                width: min(targetSize.width, mainScreen.frame.width * 0.9),
                height: min(targetSize.height, mainScreen.frame.height * 0.9)
            )
        }

        let origin = CGPoint(
            x: mainScreen.frame.midX - targetSize.width / 2,
            y: mainScreen.frame.midY - targetSize.height / 2
        )

        window.setFrame(NSRect(origin: origin, size: targetSize), display: true, animate: true)
        window.makeKeyAndOrderFront(nil)
    }
}
