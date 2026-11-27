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
            inlineHeaderHeight: 52
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
            present(existing)
            return
        }

        let window = makeDarkWindow(
            title: "Accounts",
            contentSize: NSSize(width: 780, height: 620),
            contentMinSize: NSSize(width: 540, height: 360),
            rootView: PlaceholderAccountsView(store: store, router: self),
            fullSizeContent: false,
            inlineHeaderHeight: nil
        )
        accountsWindow = window
        present(window)
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
        inlineHeaderHeight: CGFloat?
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
                headerHeight: inlineHeaderHeight
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

    private func present(_ window: NSWindow) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        if let inlineWindow = window as? InlineTitleBarWindow {
            inlineWindow.positionTrafficLights()
        }
        // Re-assert activation on the next turn so LSUIElement windows reliably come to front at launch.
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
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
/// transparent inline header row (e.g. 52 pt) left of the header title.
@MainActor
private final class InlineTitleBarWindow: NSWindow {
    private let headerHeight: CGFloat
    private let trafficLightLeading: CGFloat = 16
    private let trafficLightSpacing: CGFloat = 20

    init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool,
        headerHeight: CGFloat
    ) {
        self.headerHeight = headerHeight
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)

        // Attach an empty unified toolbar so AppKit sizes the native titlebar container to 52 pt
        // without drawing a separator, keeping traffic lights unclipped and natively draggable.
        let toolbar = NSToolbar(identifier: NSToolbar.Identifier("dev.jabree.OpenUsage.InlineHeader"))
        self.toolbar = toolbar
        self.toolbarStyle = .unified
        self.titlebarSeparatorStyle = .none
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

        // Compute the vertical center of the 52-pt header row in the titlebar view's coordinate space.
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

struct PlaceholderAccountsView: View {
    let store: AppStore
    let router: AppRouter

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Accounts")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Theme.textPrimary.swiftUIColor)
            if let focused = router.focusedAccountProvider {
                Text("Selected subscription: \(focused.displayName)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary.swiftUIColor)
            }
            Text("Subscription connections, local log sources, and depletion thresholds will be implemented in Milestone 4.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textMuted.swiftUIColor)
            Spacer()
        }
        .padding(24)
        .frame(
            minWidth: 540,
            idealWidth: 780,
            maxWidth: .infinity,
            minHeight: 360,
            idealHeight: 620,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .background(Theme.background.swiftUIColor)
        .preferredColorScheme(.dark)
    }
}
