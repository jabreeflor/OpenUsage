import Foundation
import OpenUsageCore

enum SnapshotExporter {
    static func exportMenuBarSnapshots(to directory: URL) throws {
        Theme.registerBundledFonts()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let scenarios: [(scenario: DemoScenario, filename: String)] = [
            (.all, "menubar-all.png"),
            (.disconnected, "menubar-disconnected.png"),
            (.connecting, "menubar-connecting.png")
        ]

        for entry in scenarios {
            let snapshots = DemoFixtures.snapshots(for: entry.scenario)
            let outputURL = directory.appendingPathComponent(entry.filename)
            try MenuBarLabelRenderer.writeSnapshotPNG(
                to: outputURL,
                snapshots: snapshots,
                yellowFrom: DepletionColor.defaultYellowThreshold,
                redFrom: DepletionColor.defaultRedThreshold,
                scale: 2.0
            )
        }
    }
}
