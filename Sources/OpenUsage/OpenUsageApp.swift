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

        if options.dumpTokenSummary {
            let semaphore = DispatchSemaphore(value: 0)
            let isDemo = options.isDemo
            Task.detached(priority: .userInitiated) {
                let report = await TokenSummaryDumper.generateReport(isDemo: isDemo)
                fputs(report, stdout)
                fflush(stdout)
                semaphore.signal()
            }
            semaphore.wait()
            Darwin.exit(0)
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

        if store.options.printWindowFrames {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                Self.printWindowFramesToStdout()
            }
        }
    }

    private static func printWindowFramesToStdout() {
        for window in NSApplication.shared.windows {
            let frame = window.frame
            let content = window.contentRect(forFrameRect: frame)
            let className = String(describing: type(of: window))
            let title = window.title.isEmpty ? "(untitled)" : window.title
            let line = String(
                format: "WINDOW title=\"%@\" class=%@ visible=%@ frame=%.0f,%.0f %.0fx%.0f content=%.0fx%.0f\n",
                title,
                className,
                window.isVisible ? "true" : "false",
                frame.origin.x,
                frame.origin.y,
                frame.size.width,
                frame.size.height,
                content.size.width,
                content.size.height
            )
            fputs(line, stdout)
        }
        fflush(stdout)
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
