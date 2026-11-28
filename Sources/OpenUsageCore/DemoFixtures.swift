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
        return StatisticsAggregator.gregorianCalendar().date(from: components) ?? Date(timeIntervalSince1970: 1_795_718_460)
    }()

    /// Reference "current" clock in demo mode (`Thu Nov 26, 2026 1:42 PM`, 1 min after `referenceDate`).
    public static let referenceNow: Date = referenceDate.addingTimeInterval(60)

    /// 12-bar hourly sparkline relative weights matching `FinalDropdown.dc.html` and reference stills 01/02/05.
    public static let todayHourlySparkline: [Int] = [2, 1, 0, 0, 1, 3, 6, 8, 7, 9, 10, 6]

    /// Deterministic 30-day token bucket fixture whose daily series, totals, models, and heatmap match
    /// `FinalStats.dc.html` and reference stills 03–04 (`Oct 28 – Nov 26, 2026`).
    public static let cachedTokenBuckets: [TokenBucket] = buildTokenBuckets()

    public static func tokenBuckets() -> [TokenBucket] {
        cachedTokenBuckets
    }

    public static func tokenLogSources() -> [any TokenLogSource] {
        let grouped = Dictionary(grouping: cachedTokenBuckets, by: \.provider)
        return ProviderID.allCases.map { provider in
            DemoTokenLogSource(provider: provider, buckets: grouped[provider] ?? [])
        }
    }

    /// Deterministic limit-hit events matching stills 03 (4 in 30D: 3 Claude, 1 ChatGPT) and 04 (1 Claude in 7D).
    public static func limitHitEvents() -> [LimitHitEvent] {
        [
            LimitHitEvent(id: "hit-claude-1", dayKey: "2026-11-24", provider: .claude, limitName: "Weekly · Opus"),
            LimitHitEvent(id: "hit-claude-2", dayKey: "2026-11-12", provider: .claude, limitName: "5-hour session"),
            LimitHitEvent(id: "hit-claude-3", dayKey: "2026-11-03", provider: .claude, limitName: "Weekly · Opus"),
            LimitHitEvent(id: "hit-chatgpt-1", dayKey: "2026-11-15", provider: .chatgpt, limitName: "5-hour")
        ]
    }

    /// Today's token usage and per-provider model shares matching `FinalDropdown.dc.html` and stills 01, 02, 05.
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
                updatedAt: referenceDate,
                showMenuBarPlaceholderWhileConnecting: true
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

    // MARK: - Deterministic 30-day Token Bucket Fixture

    private struct ProviderFixtureSpec {
        let provider: ProviderID
        let providerIndex: Int
        let baseDaily: Double
        let statsModels: [(name: String, share: Double)]
    }

    private static let fixtureSpecs: [ProviderFixtureSpec] = [
        ProviderFixtureSpec(
            provider: .claude,
            providerIndex: 0,
            baseDaily: 1_150_000,
            statsModels: [("claude-opus-4.5", 0.62), ("claude-sonnet-4.5", 0.31), ("claude-haiku-4.5", 0.07)]
        ),
        ProviderFixtureSpec(
            provider: .chatgpt,
            providerIndex: 1,
            baseDaily: 620_000,
            statsModels: [("gpt-5-codex", 0.78), ("gpt-5", 0.22)]
        ),
        ProviderFixtureSpec(
            provider: .cursor,
            providerIndex: 2,
            baseDaily: 360_000,
            statsModels: [("composer-1", 0.55), ("claude-sonnet-4.5", 0.30), ("gpt-5", 0.15)]
        ),
        ProviderFixtureSpec(
            provider: .gemini,
            providerIndex: 3,
            baseDaily: 300_000,
            statsModels: [("gemini-3-pro", 0.64), ("gemini-2.5-flash", 0.36)]
        ),
        ProviderFixtureSpec(
            provider: .opencode,
            providerIndex: 4,
            baseDaily: 150_000,
            statsModels: [("kimi-k2", 0.50), ("glm-4.6", 0.30), ("qwen3-coder", 0.20)]
        )
    ]

    private static func buildTokenBuckets() -> [TokenBucket] {
        let calendar = StatisticsAggregator.gregorianCalendar()
        let anchorStart = calendar.startOfDay(for: referenceDate)

        struct DayInfo {
            let index: Int
            let back: Int
            let dayKey: String
            let weekday: Int // 1 = Sun ... 7 = Sat
        }

        let days: [DayInfo] = (0..<30).map { index in
            let back = 29 - index
            let date = calendar.date(byAdding: .day, value: -back, to: anchorStart) ?? anchorStart
            return DayInfo(
                index: index,
                back: back,
                dayKey: StatisticsAggregator.dayKey(for: date, calendar: calendar),
                weekday: calendar.component(.weekday, from: date)
            )
        }

        // Compute per-day token totals directly from FinalStats.dc.html for all 30 days.
        var dailyTokensByProvider: [[Int]] = []
        var target30Tokens: [Int] = []
        var target7Tokens: [Int] = []

        for spec in fixtureSpecs {
            let daily: [Int] = days.map { day in
                let absDay = Double(60 - day.back)
                let weekendFactor = (day.weekday == 1 || day.weekday == 7) ? 0.4 : 1.0
                let raw = spec.baseDaily * (0.4 + 0.6 * abs(sin(absDay * 1.7 + Double(spec.providerIndex) * 2.3))) * weekendFactor
                return Int(raw.rounded())
            }
            dailyTokensByProvider.append(daily)
            target30Tokens.append(daily.reduce(0, +))
            target7Tokens.append(daily.suffix(7).reduce(0, +))
        }

        // Compute exact 30D and 7D request targets so Overview 30D sums to 5,870 and Claude 7D sums to 613.
        let total30TokensAll = target30Tokens.reduce(0, +)
        let target30RequestsAll = Int((Double(total30TokensAll) / 8_700.0).rounded()) // 5,870
        var target30Requests = distributeInt(total: target30RequestsAll, weights: target30Tokens.map(Double.init))
        let target7Requests = target7Tokens.map { Int((Double($0) / 8_700.0).rounded()) }
        for i in 0..<fixtureSpecs.count where target30Requests[i] < target7Requests[i] {
            target30Requests[i] = target7Requests[i]
        }

        // Precompute weekday-row geometry for 30D and 7D request allocation so the request-based
        // heatmap reproduces FinalStats.dc.html's weekday×hour pattern independently of daily token totals.
        let heatmapPattern: [[Double]] = (0..<7).map { row in
            // row 0 = Mon (weekday 2) ... row 5 = Sat (weekday 7), row 6 = Sun (weekday 1)
            let weekday = row == 6 ? 1 : row + 2
            return heatmapHourWeights(weekday: weekday)
        }
        var occurrences30 = Array(repeating: 0, count: 7)
        var prev23DaysByRow: [[Int]] = Array(repeating: [], count: 7)
        var last7DayByRow = Array(repeating: 0, count: 7)
        for day in days {
            let row = (day.weekday + 5) % 7
            occurrences30[row] += 1
            if day.index < 23 {
                prev23DaysByRow[row].append(day.index)
            } else {
                last7DayByRow[row] = day.index
            }
        }
        let flatWeights7: [Double] = (0..<7).flatMap { row in heatmapPattern[row] }
        let flatWeights30: [Double] = (0..<7).flatMap { row in
            let occ = Double(occurrences30[row])
            return heatmapPattern[row].map { $0 * occ }
        }

        var buckets: [TokenBucket] = []

        for (pIndex, spec) in fixtureSpecs.enumerated() {
            let dayTokens = dailyTokensByProvider[pIndex]
            let modelShares = spec.statsModels.map(\.share)
            let modelCount = spec.statsModels.count

            // Allocate requests directly to (day, hour) cells following the weekday×hour pattern:
            // - Last 7 days sum to target7Requests[pIndex] (e.g., Claude 7D = 613)
            // - All 30 days sum to target30Requests[pIndex] (e.g., Overview 30D = 5,870)
            let cells7 = distributeInt(total: target7Requests[pIndex], weights: flatWeights7)
            let cells30 = distributeInt(total: target30Requests[pIndex], weights: flatWeights30)
            var dayHourReqs: [[Int]] = Array(repeating: Array(repeating: 0, count: 24), count: days.count)
            for row in 0..<7 {
                let last7Index = last7DayByRow[row]
                let prevIndices = prev23DaysByRow[row]
                let equalWeights = Array(repeating: 1.0, count: prevIndices.count)
                for hour in 0..<24 {
                    let flatIndex = row * 24 + hour
                    let req7 = cells7[flatIndex]
                    dayHourReqs[last7Index][hour] = req7

                    let remPrev23 = max(0, cells30[flatIndex] - req7)
                    let splitPrev = distributeInt(total: remPrev23, weights: equalWeights)
                    for (dayIdx, reqCount) in zip(prevIndices, splitPrev) {
                        dayHourReqs[dayIdx][hour] = reqCount
                    }
                }
            }

            // Build hourly TokenBuckets for each day and model.
            for day in days {
                let row = (day.weekday + 5) % 7
                let hourWeights = heatmapPattern[row]
                let modelsForDay = distributeInt(total: dayTokens[day.index], weights: modelShares)

                // Split each hour's request count across models so the sum across models equals dayHourReqs[day][hour].
                var hourlyModelReqs: [[Int]] = Array(repeating: Array(repeating: 0, count: 24), count: modelCount)
                for hour in 0..<24 {
                    let reqAtHour = dayHourReqs[day.index][hour]
                    if reqAtHour > 0 {
                        let perModel = distributeInt(total: reqAtHour, weights: modelShares)
                        for m in 0..<modelCount {
                            hourlyModelReqs[m][hour] = perModel[m]
                        }
                    }
                }

                for m in 0..<modelCount {
                    let modelTokens = modelsForDay[m]
                    let hourlyReqs = hourlyModelReqs[m]
                    let modelReqTotal = hourlyReqs.reduce(0, +)
                    guard modelTokens > 0 || modelReqTotal > 0 else { continue }

                    let modelName = spec.statsModels[m].name
                    let modelInput = Int((Double(modelTokens) * 0.24).rounded())
                    let modelOutput = Int((Double(modelTokens) * 0.07).rounded())
                    let modelCache = max(0, modelTokens - modelInput - modelOutput)

                    let hourlyInput = distributeInt(total: modelInput, weights: hourWeights)
                    let hourlyOutput = distributeInt(total: modelOutput, weights: hourWeights)
                    let hourlyCache = distributeInt(total: modelCache, weights: hourWeights)

                    for hour in 0..<24 {
                        let inp = hourlyInput[hour]
                        let out = hourlyOutput[hour]
                        let cache = hourlyCache[hour]
                        let req = hourlyReqs[hour]
                        if inp == 0 && out == 0 && cache == 0 && req == 0 {
                            continue
                        }
                        buckets.append(
                            TokenBucket(
                                dayKey: day.dayKey,
                                hour: hour,
                                provider: spec.provider,
                                model: modelName,
                                inputTokens: inp,
                                outputTokens: out,
                                cacheTokens: cache,
                                requests: req
                            )
                        )
                    }
                }
            }
        }

        return buckets
    }

    private static func heatmapHourWeights(weekday: Int) -> [Double] {
        // weekday: 1 = Sun, 2 = Mon ... 7 = Sat; row r: 0 = Mon ... 6 = Sun
        let row = (weekday + 5) % 7
        let weekendFactor = (weekday == 1 || weekday == 7) ? 0.35 : 1.0
        return (0..<24).map { hour in
            let work: Double
            if (9...18).contains(hour) {
                work = 1.0
            } else if (20...23).contains(hour) {
                work = 0.55
            } else if hour <= 1 {
                work = 0.30
            } else {
                work = 0.04
            }
            return min(1.0, work * weekendFactor * (0.55 + 0.45 * abs(sin(Double(hour) * 0.9 + Double(row) * 1.3))))
        }
    }

    private static func distributeInt(total: Int, weights: [Double]) -> [Int] {
        guard !weights.isEmpty else { return [] }
        guard total > 0 else { return Array(repeating: 0, count: weights.count) }
        let weightSum = weights.reduce(0, +)
        guard weightSum > 0 else {
            var result = Array(repeating: 0, count: weights.count)
            result[0] = total
            return result
        }

        var floors: [Int] = []
        floors.reserveCapacity(weights.count)
        var remainders: [(index: Int, remainder: Double)] = []
        remainders.reserveCapacity(weights.count)
        var floorSum = 0

        for (index, weight) in weights.enumerated() {
            let exact = Double(total) * (weight / weightSum)
            let floored = Int(floor(exact))
            floors.append(floored)
            floorSum += floored
            remainders.append((index: index, remainder: exact - Double(floored)))
        }

        let deficit = total - floorSum
        if deficit > 0 {
            let sorted = remainders.sorted { lhs, rhs in
                if lhs.remainder != rhs.remainder {
                    return lhs.remainder > rhs.remainder
                }
                return lhs.index < rhs.index
            }
            for i in 0..<min(deficit, sorted.count) {
                floors[sorted[i].index] += 1
            }
        }
        return floors
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

    public func signIn() async throws -> ProviderSnapshot {
        DemoFixtures.snapshot(for: provider, scenario: .all)
    }

    public func signOut() async throws -> ProviderSnapshot {
        ProviderSnapshot(
            provider: provider,
            plan: "",
            connectionState: .notConnected,
            limits: [],
            connectedVia: "Not connected",
            updatedAt: DemoFixtures.referenceDate
        )
    }
}

public struct DemoTokenLogSource: TokenLogSource, Sendable {
    public let provider: ProviderID
    private let buckets: [TokenBucket]

    public init(provider: ProviderID, buckets: [TokenBucket]) {
        self.provider = provider
        self.buckets = buckets
    }

    public func loadBuckets() async throws -> [TokenBucket] {
        buckets
    }
}
