import CoreGraphics
import Foundation
import ImageIO
import OpenUsageCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum SnapshotExporter {
    static func exportAllSnapshots(to directory: URL) throws {
        Theme.registerBundledFonts()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try exportMenuBarSnapshots(to: directory)
        try exportDropdownSnapshots(to: directory)
        try exportStatisticsSnapshots(to: directory)
    }

    static func exportMenuBarSnapshots(to directory: URL) throws {
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

    static func exportDropdownSnapshots(to directory: URL) throws {
        let targets: [(scenario: DemoScenario, selection: DropdownSelection, filename: String)] = [
            (.all, .provider(.claude), "dropdown-all-claude.png"),
            (.all, .provider(.cursor), "dropdown-all-cursor.png"),
            (.disconnected, .provider(.claude), "dropdown-disconnected.png")
        ]

        let today = DemoFixtures.todayUsage()
        let updatedText = TokenFormatter.updatedAgoText(
            from: DemoFixtures.referenceDate,
            now: DemoFixtures.referenceNow
        )

        for target in targets {
            let view = DropdownContentView(
                snapshots: DemoFixtures.snapshots(for: target.scenario),
                todayUsage: today,
                selection: target.selection,
                yellowFrom: DepletionColor.defaultYellowThreshold,
                redFrom: DepletionColor.defaultRedThreshold,
                updatedAgoText: updatedText,
                onSelect: { _ in },
                onOpenStatistics: {},
                onOpenAccounts: { _ in },
                onQuit: {}
            )
            let outputURL = directory.appendingPathComponent(target.filename)
            try writeSwiftUIViewPNG(view, to: outputURL, scale: 2.0)
        }
    }

    static func exportStatisticsSnapshots(to directory: URL) throws {
        let targets: [(range: StatisticsRange, filter: StatisticsFilter, filename: String)] = [
            (.thirtyDays, .overview, "statistics-overview-30d.png"),
            (.sevenDays, .provider(.claude), "statistics-claude-7d.png")
        ]

        let snapshots = DemoFixtures.snapshots(for: .all)
        let buckets = DemoFixtures.tokenBuckets()
        let limitHits = DemoFixtures.limitHitEvents()

        for target in targets {
            let summary = StatisticsAggregator.summarize(
                buckets: buckets,
                limitHits: limitHits,
                range: target.range,
                filter: target.filter,
                anchorDate: DemoFixtures.referenceDate
            )
            let view = StatisticsContentView(
                snapshots: snapshots,
                summary: summary,
                yellowFrom: DepletionColor.defaultYellowThreshold,
                redFrom: DepletionColor.defaultRedThreshold,
                showsSimulatedTrafficLights: true,
                onSelectRange: { _ in },
                onSelectFilter: { _ in }
            )
            let outputURL = directory.appendingPathComponent(target.filename)
            try writeSwiftUIViewPNG(view, to: outputURL, scale: 2.0)
        }
    }

    private static func writeSwiftUIViewPNG<V: View>(
        _ view: V,
        to url: URL,
        scale: CGFloat
    ) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale

        guard let cgImage = renderer.cgImage else {
            throw NSError(
                domain: "dev.jabree.OpenUsage.Snapshot",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "ImageRenderer returned nil for \(url.lastPathComponent)"]
            )
        }

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(
                domain: "dev.jabree.OpenUsage.Snapshot",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create PNG destination at \(url.path)"]
            )
        }

        let properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72.0 * scale,
            kCGImagePropertyDPIHeight: 72.0 * scale
        ]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(
                domain: "dev.jabree.OpenUsage.Snapshot",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "Failed to finalize PNG at \(url.path)"]
            )
        }
    }
}
