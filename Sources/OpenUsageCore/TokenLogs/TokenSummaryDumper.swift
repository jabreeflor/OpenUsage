import Foundation

/// Formats a privacy-safe, numbers-only token summary for the `--dump-token-summary` CLI flag.
/// Never prints file paths, project names, session IDs, prompts, or model strings.
public enum TokenSummaryDumper {
    /// Default bounded wall-clock wait (10 minutes) for the background iCloud materialization pass.
    public static let defaultBackgroundWaitTimeout: TimeInterval = 600.0

    public static func generateReport(
        isDemo: Bool,
        anchorDate: Date = Date(),
        calendar: Calendar = StatisticsAggregator.gregorianCalendar(),
        coordinator: LocalTokenLogCoordinator? = nil,
        enabledSources: Set<LocalToolSource>? = nil,
        defaults: UserDefaults = .standard,
        backgroundWaitTimeout: TimeInterval = TokenSummaryDumper.defaultBackgroundWaitTimeout
    ) async -> String {
        let buckets: [TokenBucket]
        let effectiveAnchor: Date
        let pendingICloudFiles: Int
        if isDemo {
            buckets = DemoFixtures.tokenBuckets()
            effectiveAnchor = DemoFixtures.referenceDate
            pendingICloudFiles = 0
        } else {
            let activeCoordinator = coordinator ?? LocalTokenLogCoordinator()
            let resolvedEnabled = enabledSources ?? LocalSourceSettings.persistedEnabledSources(defaults: defaults)
            let localSnapshot = await activeCoordinator.refreshLocalPass(
                enabledSources: resolvedEnabled,
                calendar: calendar,
                now: anchorDate,
                persistCache: true
            )
            let finalSnapshot: LocalLogRefreshSnapshot
            if localSnapshot.pendingICloudFiles > 0 {
                finalSnapshot = await activeCoordinator.runBackgroundMaterializationPass(
                    enabledSources: resolvedEnabled,
                    calendar: calendar,
                    totalTimeout: backgroundWaitTimeout,
                    persistCache: true
                )
            } else {
                finalSnapshot = localSnapshot
            }
            buckets = TokenBucketAggregator.merge(finalSnapshot.bucketsBySource.values.flatMap { $0 })
            effectiveAnchor = anchorDate
            pendingICloudFiles = finalSnapshot.pendingICloudFiles
        }

        return formatReport(
            buckets: buckets,
            anchorDate: effectiveAnchor,
            calendar: calendar,
            pendingICloudFiles: pendingICloudFiles
        )
    }

    public static func formatReport(
        buckets: [TokenBucket],
        anchorDate: Date,
        calendar: Calendar = StatisticsAggregator.gregorianCalendar(),
        pendingICloudFiles: Int = 0
    ) -> String {
        let ranges: [(title: String, range: StatisticsRange)] = [
            ("last 7 days", .sevenDays),
            ("last 30 days", .thirtyDays)
        ]

        var lines: [String] = []
        for (index, entry) in ranges.enumerated() {
            if index > 0 {
                lines.append("")
            }
            lines.append("OpenUsage token summary (\(entry.title))")

            for provider in ProviderID.allCases {
                let summary = StatisticsAggregator.summarize(
                    buckets: buckets,
                    range: entry.range,
                    filter: .provider(provider),
                    anchorDate: anchorDate,
                    calendar: calendar
                )
                let t = summary.tokenSummary
                lines.append(
                    "\(provider.rawValue): total=\(t.totalTokens) input=\(t.inputTokens) output=\(t.outputTokens) cache=\(t.cacheTokens) requests=\(t.requests)"
                )
            }

            let allSummary = StatisticsAggregator.summarize(
                buckets: buckets,
                range: entry.range,
                filter: .overview,
                anchorDate: anchorDate,
                calendar: calendar
            )
            let allTokens = allSummary.tokenSummary
            lines.append(
                "all: total=\(allTokens.totalTokens) input=\(allTokens.inputTokens) output=\(allTokens.outputTokens) cache=\(allTokens.cacheTokens) requests=\(allTokens.requests)"
            )
        }

        lines.append("pending_icloud_files=\(max(0, pendingICloudFiles))")

        return lines.joined(separator: "\n") + "\n"
    }
}
