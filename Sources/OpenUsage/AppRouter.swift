import AppKit
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

        let hosting = NSHostingController(rootView: PlaceholderStatisticsView(store: store))
        let window = makeDarkWindow(
            title: "Statistics",
            size: NSSize(width: 1000, height: 748),
            minSize: NSSize(width: 640, height: 420),
            contentViewController: hosting
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

        let hosting = NSHostingController(rootView: PlaceholderAccountsView(store: store, router: self))
        let window = makeDarkWindow(
            title: "Accounts",
            size: NSSize(width: 780, height: 620),
            minSize: NSSize(width: 540, height: 360),
            contentViewController: hosting
        )
        accountsWindow = window
        present(window)
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func makeDarkWindow(
        title: String,
        size: NSSize,
        minSize: NSSize,
        contentViewController: NSViewController
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.minSize = minSize
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.background.nsColor
        window.titlebarAppearsTransparent = true
        window.contentViewController = contentViewController
        window.center()
        return window
    }

    private func present(_ window: NSWindow) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

struct PlaceholderStatisticsView: View {
    let store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Statistics")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Theme.textPrimary.swiftUIColor)
            Text("Detailed token and model analytics will be implemented in Milestone 3.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textMuted.swiftUIColor)
            Text("Today: \(TokenFormatter.formatTokens(store.todayUsage.totalTokens)) tokens · \(TokenFormatter.formatCount(store.todayUsage.totalRequests)) requests")
                .font(Theme.mono(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary.swiftUIColor)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background.swiftUIColor)
        .preferredColorScheme(.dark)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background.swiftUIColor)
        .preferredColorScheme(.dark)
    }
}
