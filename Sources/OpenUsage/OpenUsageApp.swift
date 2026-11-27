import AppKit
import Darwin
import OpenUsageCore
import SwiftUI

@main
enum OpenUsageMain {
    @MainActor
    static func main() {
        Theme.registerBundledFonts()
        let options = LaunchOptions.parse()

        if let snapshotDir = options.snapshotDir {
            do {
                try SnapshotExporter.exportAllSnapshots(to: snapshotDir)
                Darwin.exit(0)
            } catch {
                fputs("error: snapshot export failed: \(error.localizedDescription)\n", stderr)
                Darwin.exit(1)
            }
        }

        OpenUsageApp.main()
    }
}

@MainActor
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    static weak var sharedStore: AppStore?
    static weak var sharedRouter: AppRouter?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let store = Self.sharedStore, let router = Self.sharedRouter else {
            return
        }
        store.startRefreshScheduler()

        switch store.options.openScreen {
        case .dropdown:
            StatusItemOpener.openMenuBarDropdown()
        case .statistics:
            router.openStatistics()
        case .accounts:
            router.openAccounts()
        case nil:
            break
        }
    }
}

struct OpenUsageApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var appDelegate
    @State private var store: AppStore
    @State private var router: AppRouter

    init() {
        Theme.registerBundledFonts()
        let options = LaunchOptions.parse()
        let store = AppStore(options: options)
        let router = AppRouter()
        router.attach(store: store)
        AppLifecycleDelegate.sharedStore = store
        AppLifecycleDelegate.sharedRouter = router
        _store = State(initialValue: store)
        _router = State(initialValue: router)
    }

    var body: some Scene {
        MenuBarExtra {
            DropdownPopoverView(store: store, router: router)
        } label: {
            Image(nsImage: MenuBarLabelRenderer.renderMenuBarImage(
                snapshots: store.snapshots,
                yellowFrom: store.thresholds.yellowFrom,
                redFrom: store.thresholds.redFrom
            ))
        }
        .menuBarExtraStyle(.window)
    }
}
