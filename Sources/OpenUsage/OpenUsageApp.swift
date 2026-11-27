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
                try SnapshotExporter.exportMenuBarSnapshots(to: snapshotDir)
                Darwin.exit(0)
            } catch {
                fputs("error: snapshot export failed: \(error.localizedDescription)\n", stderr)
                Darwin.exit(1)
            }
        }

        OpenUsageApp.main()
    }
}

struct OpenUsageApp: App {
    @State private var store: AppStore

    init() {
        Theme.registerBundledFonts()
        let options = LaunchOptions.parse()
        _store = State(initialValue: AppStore(options: options))
    }

    var body: some Scene {
        MenuBarExtra {
            PlaceholderPopoverView(store: store)
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
