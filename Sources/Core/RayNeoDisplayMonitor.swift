import Cocoa

/// Polls for RayNeo Air 4 Pro display (3840×1080 SBS mode).
/// Only moves window when:
///   - Display is 3840×1080
///   - Display is NOT the main screen
///   - Screens are NOT mirrored (different resolutions)
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
        checkAndFire()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Wait 1s for screen to complete unmirror transition (resolutions update with delay)
            guard let self = self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.checkAndFire()
            }
        }

        pollingTimer = Timer.scheduledTimer(
            withTimeInterval: 2,
            repeats: true
        ) { [weak self] _ in
            self?.checkAndFire()
        }
    }

    private func checkAndFire() {
        guard let screens = obtainScreens() else { return }
        guard screens.count >= 2 else { return }
        guard isMirrorTest(screens) == false else { return }

        guard let glasses = findRayNeoScreenIn(screens) else {
            if isPinned, didLosingDisplay != nil {
                isPinned = false
                notifyLoss()
            }
            return
        }

        guard isMain(glasses) == false else { return }

        if !isPinned {
            isPinned = true
            didFindDisplay?(glasses)
            stopPolling()
        }
    }

    private func obtainScreens() -> [NSScreen]? {
        return NSScreen.screens
    }

    private func isMirrorTest(_ screens: [NSScreen]) -> Bool {
        guard screens.count >= 2 else { return false }
        let first = screens[0].frame.size
        for screen in screens {
            let dw = abs(screen.frame.width - first.width)
            let dh = abs(screen.frame.height - first.height)
            if dw >= 2.0 || dh >= 2.0 { return false }
        }
        return true
    }

    private func isMain(_ screen: NSScreen) -> Bool {
        return screen == NSScreen.main
    }

    private func findRayNeoScreenIn(_ screens: [NSScreen]) -> NSScreen? {
        for screen in screens {
            let w = screen.frame.width
            let h = screen.frame.height
            if abs(w - targetWidth) < 2.0 && abs(h - targetHeight) < 2.0 {
                return screen
            }
        }
        return nil
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

    private func notifyLoss() {
        if let handler = didLosingDisplay {
            handler(Void())
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
