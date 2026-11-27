import AppKit
import SwiftUI

/// Neutralizes the default `MenuBarExtra(.window)` chrome/material so only our custom dark surface shows.
struct MenuBarWindowChromeCleaner: NSViewRepresentable {
    func makeNSView(context: Context) -> ChromeCleanerNSView {
        ChromeCleanerNSView()
    }

    func updateNSView(_ nsView: ChromeCleanerNSView, context: Context) {
        nsView.scheduleClean()
    }
}

final class ChromeCleanerNSView: NSView {
    private var didInstallObserver = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleClean()
        installObserverIfNeeded()
    }

    override func layout() {
        super.layout()
        cleanWindowChrome()
    }

    private func installObserverIfNeeded() {
        guard !didInstallObserver, let window else { return }
        didInstallObserver = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowUpdate),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowUpdate),
            name: NSWindow.didUpdateNotification,
            object: window
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleWindowUpdate() {
        cleanWindowChrome()
    }

    func scheduleClean() {
        cleanWindowChrome()
        DispatchQueue.main.async { [weak self] in
            self?.cleanWindowChrome()
        }
    }

    private func cleanWindowChrome() {
        guard let window else { return }

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true

        if let contentView = window.contentView {
            contentView.wantsLayer = true
            contentView.layer?.backgroundColor = NSColor.clear.cgColor
        }

        if let frameView = window.contentView?.superview {
            frameView.wantsLayer = true
            frameView.layer?.backgroundColor = NSColor.clear.cgColor
            stripBackgroundChrome(in: frameView, preservingBranchOf: self)
        }
    }

    private func stripBackgroundChrome(in root: NSView, preservingBranchOf target: NSView) {
        for subview in root.subviews {
            let isOnTargetBranch = (subview === target) || target.isDescendant(of: subview)
            let className = String(describing: type(of: subview))

            if isOnTargetBranch {
                // Keep our hosting branch visible, only clear any background fill on wrappers.
                if let visualEffect = subview as? NSVisualEffectView {
                    visualEffect.state = .inactive
                    visualEffect.blendingMode = .withinWindow
                    visualEffect.wantsLayer = true
                    visualEffect.layer?.backgroundColor = NSColor.clear.cgColor
                } else if subview !== target && (className.contains("Background") || className.contains("Glass") || className.contains("Material")) {
                    subview.wantsLayer = true
                    subview.layer?.backgroundColor = NSColor.clear.cgColor
                }
                stripBackgroundChrome(in: subview, preservingBranchOf: target)
            } else {
                // Hide sibling backdrop/glass/material/popover-frame decoration views.
                if subview is NSVisualEffectView
                    || className.contains("VisualEffect")
                    || className.contains("Glass")
                    || className.contains("Backdrop")
                    || className.contains("Material")
                    || className.contains("Popover")
                    || className.contains("Background")
                {
                    subview.isHidden = true
                }
            }
        }
    }
}

@MainActor
enum StatusItemOpener {
    /// Programmatically clicks the app's `NSStatusBarButton` once `MenuBarExtra` has installed it
    /// and WindowServer has assigned its real on-screen menu bar frame.
    static func openMenuBarDropdown(maxAttempts: Int = 60) {
        Task { @MainActor in
            var lastPositionedFrame: CGRect?

            for _ in 0..<maxAttempts {
                if let button = findStatusBarButton(),
                   let frame = positionedFrame(for: button) {
                    if lastPositionedFrame == frame {
                        NSApplication.shared.activate(ignoringOtherApps: true)
                        button.performClick(nil)
                        return
                    }
                    lastPositionedFrame = frame
                } else {
                    lastPositionedFrame = nil
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }

            // Fallback if the frame kept shifting slightly but is still validly positioned on-screen.
            if let button = findStatusBarButton(),
               positionedFrame(for: button) != nil {
                NSApplication.shared.activate(ignoringOtherApps: true)
                button.performClick(nil)
            }
        }
    }

    private static func positionedFrame(for button: NSStatusBarButton) -> CGRect? {
        guard let window = button.window,
              window.isVisible,
              button.bounds.width > 1,
              button.bounds.height > 1 else {
            return nil
        }

        let frame = window.frame
        guard frame.width > 1,
              frame.height > 1,
              frame.origin != .zero else {
            return nil
        }

        if let screen = window.screen ?? NSScreen.main {
            let screenFrame = screen.frame
            let horizontallyOnScreen = frame.midX > screenFrame.minX && frame.midX < screenFrame.maxX
            let inMenuBarBand = frame.minY >= screenFrame.maxY - 80 && frame.minY <= screenFrame.maxY
            guard horizontallyOnScreen && inMenuBarBand else {
                return nil
            }
        } else if frame.minX == 0 || frame.minY == 0 {
            return nil
        }

        return frame
    }

    private static func findStatusBarButton() -> NSStatusBarButton? {
        for window in NSApplication.shared.windows {
            if let root = window.contentView?.superview ?? window.contentView,
               let found = findStatusBarButton(in: root) {
                return found
            }
        }
        return nil
    }

    private static func findStatusBarButton(in view: NSView) -> NSStatusBarButton? {
        if let button = view as? NSStatusBarButton {
            return button
        }
        for subview in view.subviews {
            if let found = findStatusBarButton(in: subview) {
                return found
            }
        }
        return nil
    }
}
