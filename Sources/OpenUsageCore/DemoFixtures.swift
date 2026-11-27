import Foundation

public enum DemoScenario: String, CaseIterable, Codable, Sendable, Equatable {
    case all
    case disconnected
    case connecting
}

public enum DemoFixtures {
    /// Fixed reference timestamp matching the design stills (`Thu Nov 26, 2026 1:41 PM`, "updated 1 min ago").
    public static let referenceDate: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 11
        components.day = 26
        components.hour = 13
        components.minute = 41
        return Calendar(identifier: .gregorian).date(from: components) ?? Date(timeIntervalSince1970: 1_795_718_460)
    }()

    /// Reference "current" clock in demo mode (`Thu Nov 26, 2026 1:42 PM`, 1 min after `referenceDate`).
    public static let referenceNow: Date = referenceDate.addingTimeInterval(60)

    /// 12-bar hourly sparkline values matching `FinalDropdown.dc.html` and reference stills 01/02/05.
    public static let todayHourlySparkline: [Int] = [2, 1, 0, 0, 1, 3, 6, 8, 7, 9, 10, 6]

    /// Today's token usage and per-provider model shares matching stills 01, 02, 05 and `demo.html`.
    public static func todayUsage() -> TodayUsageSummary {
        let providers: [ProviderTodayUsage] = [
            ProviderTodayUsage(
                provider: .claude,
                totalTokens: 800_000,
                requests: 148,
                models: [
                    ModelShare(model: "claude-opus-4.5", sharePercent: 71, tokens: 568_000),
                    ModelShare(model: "claude-sonnet-4.5", sharePercent: 24, tokens: 192_000),
                    ModelShare(model: "claude-haiku-4.5", sharePercent: 5, tokens: 40_000)
                ]
            ),
            ProviderTodayUsage(
                provider: .chatgpt,
                totalTokens: 395_000,
                requests: 97,
                models: [
                    ModelShare(model: "gpt-5-codex", sharePercent: 82, tokens: 323_900),
                    ModelShare(model: "gpt-5", sharePercent: 18, tokens: 71_100)
                ]
            ),
            ProviderTodayUsage(
                provider: .cursor,
                totalTokens: 271_000,
                requests: 64,
                models: [
                    ModelShare(model: "composer-1", sharePercent: 58, tokens: 157_180),
                    ModelShare(model: "claude-sonnet-4.5", sharePercent: 29, tokens: 78_590),
                    ModelShare(model: "gpt-5", sharePercent: 13, tokens: 35_230)
                ]
            ),
            ProviderTodayUsage(
                provider: .gemini,
                totalTokens: 229_000,
                requests: 71,
                models: [
                    ModelShare(model: "gemini-3-pro", sharePercent: 66, tokens: 151_140),
                    ModelShare(model: "gemini-2.5-flash", sharePercent: 34, tokens: 77_860)
                ]
            ),
            ProviderTodayUsage(
                provider: .opencode,
                totalTokens: 127_000,
                requests: 32,
                models: [
                    ModelShare(model: "kimi-k2", sharePercent: 52, tokens: 66_040),
                    ModelShare(model: "glm-4.6", sharePercent: 31, tokens: 39_370),
                    ModelShare(model: "qwen3-coder", sharePercent: 17, tokens: 21_590)
                ]
            )
        ]

        return TodayUsageSummary(
            totalTokens: 1_840_000,
            totalRequests: 412,
            hourlySparkline: todayHourlySparkline,
            byProvider: Dictionary(uniqueKeysWithValues: providers.map { ($0.provider, $0) })
        )
    }

    public static func snapshot(for provider: ProviderID, scenario: DemoScenario = .all) -> ProviderSnapshot {
        switch (provider, scenario) {
        case (.claude, _):
            return ProviderSnapshot(
                provider: .claude,
                plan: "Max 5x",
                connectionState: .connected,
                limits: [
                    UsageLimit(
                        id: "claude-5h",
                        name: "5-hour session",
                        shortName: "5-hour session",
                        percentUsed: 62,
                        resetText: "Resets in 2h 14m"
                    ),
                    UsageLimit(
                        id: "claude-weekly-all",
                        name: "Weekly · all models",
                        shortName: "Wk · all models",
                        percentUsed: 38,
                        resetText: "Resets Tue 9:00 AM"
                    ),
                    UsageLimit(
                        id: "claude-weekly-opus",
                        name: "Weekly · Opus",
                        shortName: "Wk · Opus",
                        percentUsed: 81,
                        resetText: "Resets Tue 9:00 AM"
                    )
                ],
                connectedVia: "Signed in with claude.ai",
                updatedAt: referenceDate
            )

        case (.chatgpt, _):
            return ProviderSnapshot(
                provider: .chatgpt,
                plan: "Plus · Codex",
                connectionState: .connected,
                limits: [
                    UsageLimit(
                        id: "chatgpt-5h",
                        name: "5-hour",
                        shortName: "5-hour",
                        percentUsed: 21,
                        resetText: "Resets in 4h 02m"
                    ),
                    UsageLimit(
                        id: "chatgpt-weekly",
                        name: "Weekly",
                        shortName: "Weekly",
                        percentUsed: 54,
                        resetText: "Resets Mon 6:00 AM"
                    )
                ],
                connectedVia: "Signed in with ChatGPT",
                updatedAt: referenceDate
            )

        case (.cursor, _):
            return ProviderSnapshot(
                provider: .cursor,
                plan: "Pro",
                connectionState: .connected,
                limits: [
                    UsageLimit(
                        id: "cursor-included",
                        name: "Included usage",
                        shortName: "Included usage",
                        percentUsed: 67,
                        resetText: "$13.40 of $20 · resets Dec 9"
                    )
                ],
                connectedVia: "Using the Cursor app session on this Mac",
                updatedAt: referenceDate
            )

        case (.gemini, .all):
            return ProviderSnapshot(
                provider: .gemini,
                plan: "Google AI Pro",
                connectionState: .connected,
                limits: [
                    UsageLimit(
                        id: "gemini-daily",
                        name: "Daily requests",
                        shortName: "Daily requests",
                        percentUsed: 21,
                        resetText: "312 of 1,500 · resets at midnight"
                    )
                ],
                connectedVia: "Signed in with Google",
                updatedAt: referenceDate
            )

        case (.gemini, .disconnected):
            return ProviderSnapshot(
                provider: .gemini,
                plan: "Google AI Pro",
                connectionState: .expired,
                limits: [],
                connectedVia: "Sign-in expired yesterday",
                updatedAt: referenceDate
            )

        case (.gemini, .connecting):
            return ProviderSnapshot(
                provider: .gemini,
                plan: "Google AI Pro",
                connectionState: .connecting,
                limits: [],
                connectedVia: "Finish signing in in your browser",
                updatedAt: referenceDate
            )

        case (.opencode, .all):
            return ProviderSnapshot(
                provider: .opencode,
                plan: "Zen",
                connectionState: .connected,
                limits: [
                    UsageLimit(
                        id: "opencode-credit",
                        name: "Credit used",
                        shortName: "Credit used",
                        percentUsed: 42,
                        resetText: "$8.40 of $20 this month"
                    )
                ],
                connectedVia: "Signed in with OpenCode",
                updatedAt: referenceDate
            )

        case (.opencode, .disconnected), (.opencode, .connecting):
            return ProviderSnapshot(
                provider: .opencode,
                plan: "",
                connectionState: .notConnected,
                limits: [],
                connectedVia: "Not connected",
                updatedAt: referenceDate
            )
        }
    }

    public static func snapshots(for scenario: DemoScenario = .all) -> [ProviderSnapshot] {
        ProviderID.allCases.map { snapshot(for: $0, scenario: scenario) }
    }

    public static func providers(for scenario: DemoScenario = .all) -> [any UsageProvider] {
        ProviderID.allCases.map { DemoUsageProvider(provider: $0, scenario: scenario) }
    }
}

public struct DemoUsageProvider: UsageProvider, Sendable {
    public let provider: ProviderID
    public let scenario: DemoScenario

    public init(provider: ProviderID, scenario: DemoScenario = .all) {
        self.provider = provider
        self.scenario = scenario
    }

    public func fetchSnapshot() async throws -> ProviderSnapshot {
        DemoFixtures.snapshot(for: provider, scenario: scenario)
    }
}
