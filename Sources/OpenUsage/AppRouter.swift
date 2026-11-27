import AppKit
import Darwin
import Observation
import OpenUsageCore
import SwiftUI

@MainActor
final class AppRouter: Observable {
    private let _$observationRegistrar = ObservationRegistrar()

    private weak var store: AppStore?
    private var statisticsWindow: NSWindow?
    private var accountsWindow: NSWindow?
    private var _focusedAccountProvider: ProviderID?

    var focusedAccountProvider: ProviderID? {
        _$observationRegistrar.access(self, keyPath: \.focusedAccountProvider)
        return _focusedAccountProvider
    }

    func attach(store: AppStore) {
        self.store = store
    }

    func openStatistics() {
        guard let store else { return }
        if let existing = statisticsWindow {
            present(existing)
            return
        }

        let window = makeDarkWindow(
            title: "Statistics",
            contentSize: NSSize(width: 1000, height: 748),
            contentMinSize: NSSize(width: 1000, height: 748),
            rootView: StatisticsWindowView(store: store),
            fullSizeContent: true,
            inlineHeaderHeight: 52,
            useUnifiedToolbar: true
        )
        statisticsWindow = window
        present(window)
    }

    func openAccounts(focus provider: ProviderID? = nil) {
        guard let store else { return }
        _$observationRegistrar.withMutation(of: self, keyPath: \.focusedAccountProvider) {
            _focusedAccountProvider = provider
        }
        if let existing = accountsWindow {
            present(existing, clearInitialFocus: true)
            return
        }

        let window = makeDarkWindow(
            title: "Accounts",
            contentSize: NSSize(width: 780, height: 652),
            contentMinSize: NSSize(width: 780, height: 652),
            rootView: AccountsWindowView(store: store, router: self),
            fullSizeContent: true,
            inlineHeaderHeight: 36,
            useUnifiedToolbar: false
        )
        window.initialFirstResponder = nil
        accountsWindow = window
        present(window, clearInitialFocus: true)
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func makeDarkWindow<Content: View>(
        title: String,
        contentSize: NSSize,
        contentMinSize: NSSize,
        rootView: Content,
        fullSizeContent: Bool,
        inlineHeaderHeight: CGFloat?,
        useUnifiedToolbar: Bool
    ) -> NSWindow {
        var mask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        if fullSizeContent {
            mask.insert(.fullSizeContentView)
        }

        let contentRect = NSRect(origin: .zero, size: contentSize)
        let window: NSWindow
        if let inlineHeaderHeight, fullSizeContent {
            window = InlineTitleBarWindow(
                contentRect: contentRect,
                styleMask: mask,
                backing: .buffered,
                defer: false,
                headerHeight: inlineHeaderHeight,
                useUnifiedToolbar: useUnifiedToolbar
            )
        } else {
            window = NSWindow(
                contentRect: contentRect,
                styleMask: mask,
                backing: .buffered,
                defer: false
            )
        }

        window.title = title
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.background.nsColor
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        if fullSizeContent {
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
        }
        window.contentMinSize = contentMinSize

        // Host SwiftUI inside a plain NSView container rather than window.contentViewController
        // so NSHostingView never drives window frame resizing via windowDidLayout().
        let container = NSView(frame: contentRect)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.sizingOptions = []
        if fullSizeContent {
            hostingView.safeAreaRegions = []
        }
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        window.contentView = container

        // Apply exact content size after toolbar/titlebar/contentView setup, then center.
        window.setContentSize(contentSize)
        window.center()
        if let inlineWindow = window as? InlineTitleBarWindow {
            inlineWindow.positionTrafficLights()
        }
        return window
    }

    private func present(_ window: NSWindow, clearInitialFocus: Bool = false) {
        if clearInitialFocus, let inlineWindow = window as? InlineTitleBarWindow {
            inlineWindow.suppressInitialTextFieldFocus()
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        if clearInitialFocus {
            window.makeFirstResponder(nil)
        }
        if let inlineWindow = window as? InlineTitleBarWindow {
            inlineWindow.positionTrafficLights()
        }
        // Re-assert activation on the next turn so LSUIElement windows reliably come to front at launch.
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            if clearInitialFocus {
                window.makeFirstResponder(nil)
            }
            if let inlineWindow = window as? InlineTitleBarWindow {
                inlineWindow.positionTrafficLights()
            }
        }
        #if DEBUG
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak window] in
            guard let window else { return }
            let frame = window.frame
            let content = window.contentRect(forFrameRect: frame)
            let line = String(
                format: "[OpenUsage DEBUG] window=\"%@\" frame=%.0f,%.0f %.0fx%.0f content=%.0fx%.0f\n",
                window.title,
                frame.origin.x,
                frame.origin.y,
                frame.size.width,
                frame.size.height,
                content.size.width,
                content.size.height
            )
            fputs(line, stderr)
            fflush(stderr)
        }
        #endif
    }
}

/// Dark `NSWindow` whose native traffic light buttons sit vertically centered inside a custom-height
/// transparent inline header row left of the header title.
@MainActor
private final class InlineTitleBarWindow: NSWindow {
    private let headerHeight: CGFloat
    private let trafficLightLeading: CGFloat = 16
    private let trafficLightSpacing: CGFloat = 20
    private var suppressAutoTextFocus = false
    private var suppressionToken: UInt64 = 0

    init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool,
        headerHeight: CGFloat,
        useUnifiedToolbar: Bool
    ) {
        self.headerHeight = headerHeight
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)

        if useUnifiedToolbar {
            // Attach an empty unified toolbar so AppKit sizes the native titlebar container to 52 pt
            // without drawing a separator, keeping traffic lights unclipped and natively draggable.
            let toolbar = NSToolbar(identifier: NSToolbar.Identifier("dev.jabree.OpenUsage.InlineHeader"))
            self.toolbar = toolbar
            self.toolbarStyle = .unified
            self.titlebarSeparatorStyle = .none
        }
    }

    /// Prevents AppKit / SwiftUI from automatically focusing text fields while the window is first presented,
    /// while preserving normal focus via mouse click or keyboard navigation (`Tab`).
    func suppressInitialTextFieldFocus() {
        suppressAutoTextFocus = true
        suppressionToken &+= 1
        let expectedToken = suppressionToken
        makeFirstResponder(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.suppressionToken == expectedToken else { return }
            self.suppressAutoTextFocus = false
        }
    }

    override func sendEvent(_ event: NSEvent) {
        if suppressAutoTextFocus {
            switch event.type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown:
                suppressAutoTextFocus = false
            default:
                break
            }
        }
        super.sendEvent(event)
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if suppressAutoTextFocus,
           let responder,
           responder is NSText || responder is NSTextField {
            return false
        }
        return super.makeFirstResponder(responder)
    }

    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        positionTrafficLights()
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        positionTrafficLights()
    }

    func positionTrafficLights() {
        let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let buttons = buttonTypes.compactMap { standardWindowButton($0) }
        guard let titlebarView = buttons.first?.superview else { return }

        // Compute the vertical center of the inline title row in the titlebar view's coordinate space.
        let targetCenterY = titlebarView.convert(
            NSPoint(x: 0, y: frame.height - headerHeight / 2.0),
            from: nil
        ).y

        for (index, button) in buttons.enumerated() {
            let x = trafficLightLeading + CGFloat(index) * trafficLightSpacing
            let y = (targetCenterY - button.frame.height / 2.0).rounded()
            if abs(button.frame.origin.x - x) > 0.5 || abs(button.frame.origin.y - y) > 0.5 {
                button.setFrameOrigin(NSPoint(x: x, y: y))
            }
        }
    }
}
