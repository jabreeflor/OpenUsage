import Foundation

public enum StatisticsRange: String, CaseIterable, Identifiable, Codable, Sendable, Equatable, Hashable {
    case sevenDays = "7d"
    case thirtyDays = "30d"

    public var id: String { rawValue }

    public var dayCount: Int {
        switch self {
        case .sevenDays: 7
        case .thirtyDays: 30
        }
    }

    public var label: String {
        switch self {
        case .sevenDays: "7D"
        case .thirtyDays: "30D"
        }
    }
}

public enum StatisticsFilter: Equatable, Hashable, Sendable {
    case overview
    case provider(ProviderID)

    public init?(cliValue: String) {
        let normalized = cliValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "overview" || normalized == "all" {
            self = .overview
        } else if let provider = ProviderID(rawValue: normalized) {
            self = .provider(provider)
        } else {
            return nil
        }
    }

    public var providerID: ProviderID? {
        switch self {
        case .overview: nil
        case .provider(let id): id
        }
    }

    public var heading: String {
        switch self {
        case .overview: "All subscriptions"
        case .provider(let id): id.displayName
        }
    }
}

public struct LimitHitEvent: Identifiable, Codable, Sendable, Equatable, Hashable {
    public let id: String
    /// ISO calendar day string (`YYYY-MM-DD`).
    public let dayKey: String
    public let provider: ProviderID
    public let limitName: String

    public init(
        id: String? = nil,
        dayKey: String,
        provider: ProviderID,
        limitName: String
    ) {
        self.id = id ?? "\(dayKey)#\(provider.rawValue)#\(limitName)"
        self.dayKey = dayKey
        self.provider = provider
        self.limitName = limitName
    }
}

public struct DayBarSegment: Identifiable, Codable, Sendable, Equatable, Hashable {
    public var id: ProviderID { provider }

    public let provider: ProviderID
    public let tokens: Int

    public init(provider: ProviderID, tokens: Int) {
        self.provider = provider
        self.tokens = max(0, tokens)
    }
}

public struct DailyTokenBar: Identifiable, Codable, Sendable, Equatable {
    public var id: String { dayKey }

    public let dayKey: String
    public let date: Date
    public let axisLabel: String
    public let tooltipText: String
    public let segments: [DayBarSegment]
    public let totalTokens: Int

    public init(
        dayKey: String,
        date: Date,
        axisLabel: String,
        tooltipText: String,
        segments: [DayBarSegment],
        totalTokens: Int
    ) {
        self.dayKey = dayKey
        self.date = date
        self.axisLabel = axisLabel
        self.tooltipText = tooltipText
        self.segments = segments
        self.totalTokens = max(0, totalTokens)
    }
}

public struct ModelUsageRow: Identifiable, Codable, Sendable, Equatable, Hashable {
    public let id: String
    public let provider: ProviderID
    public let model: String
    public let viaText: String?
    public let tokens: Int
    public let sharePercent: Int
    public let relativeToTop: Double

    public init(
        provider: ProviderID,
        model: String,
        viaText: String?,
        tokens: Int,
        sharePercent: Int,
        relativeToTop: Double
    ) {
        self.id = "\(provider.rawValue)#\(model)"
        self.provider = provider
        self.model = model
        self.viaText = viaText
        self.tokens = max(0, tokens)
        self.sharePercent = min(100, max(0, sharePercent))
        self.relativeToTop = min(1.0, max(0.0, relativeToTop))
    }
}

public struct HeatmapCell: Identifiable, Codable, Sendable, Equatable, Hashable {
    public var id: Int { hour }

    public let hour: Int
    public let tokens: Int
    public let requests: Int
    public let intensity: Double

    public init(hour: Int, tokens: Int, requests: Int = 0, intensity: Double) {
        self.hour = min(23, max(0, hour))
        self.tokens = max(0, tokens)
        self.requests = max(0, requests)
        self.intensity = min(1.0, max(0.0, intensity))
    }
}

public struct HeatmapRow: Identifiable, Codable, Sendable, Equatable {
    public var id: Int { weekdayIndex }

    /// 0 = Monday ... 6 = Sunday.
    public let weekdayIndex: Int
    public let dayLabel: String
    public let cells: [HeatmapCell]

    public init(weekdayIndex: Int, dayLabel: String, cells: [HeatmapCell]) {
        self.weekdayIndex = weekdayIndex
        self.dayLabel = dayLabel
        self.cells = cells
    }
}

public struct StatisticsSummary: Sendable, Equatable {
    public let range: StatisticsRange
    public let filter: StatisticsFilter
    public let heading: String
    public let dateRangeText: String
    public let sidebarTotalAll: Int
    public let sidebarTotalsByProvider: [ProviderID: Int]
    public let visibleProviders: [ProviderID]
    public let tokenSummary: TokenSummary
    public let limitsHit: Int
    public let limitsHitAvailable: Bool
    public let dailyBars: [DailyTokenBar]
    public let yAxisTop: Int
    public let yAxisMid: Int
    public let topModels: [ModelUsageRow]
    public let heatmapRows: [HeatmapRow]

    public var limitsHitDisplayText: String {
        limitsHitAvailable ? TokenFormatter.formatCount(limitsHit) : "\u{2013}"
    }

    public func sidebarTotal(for filter: StatisticsFilter) -> Int {
        switch filter {
        case .overview:
            return sidebarTotalAll
        case .provider(let id):
            return sidebarTotalsByProvider[id] ?? 0
        }
    }
}

/// Determines whether the "Limits hit" KPI has real historical coverage for the selected range.
/// A current live snapshot only shows present utilization and cannot establish zero hits over 7D/30D.
public enum StatisticsLimitHitPolicy {
    public static func isAvailable(
        isDemo: Bool,
        historicalCoverageDays: Int,
        range: StatisticsRange
    ) -> Bool {
        if isDemo {
            return true
        }
        return historicalCoverageDays >= range.dayCount
    }
}

public enum StatisticsAggregator {
    private static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    private static let weekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private static let mondayFirstLabels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    public static func gregorianCalendar(timeZone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    public static func dayKey(for date: Date, calendar: Calendar = gregorianCalendar()) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        let day = components.day ?? 1
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    public static func dateRangeText(
        from startDate: Date,
        to endDate: Date,
        calendar: Calendar = gregorianCalendar()
    ) -> String {
        let start = calendar.dateComponents([.year, .month, .day], from: startDate)
        let end = calendar.dateComponents([.year, .month, .day], from: endDate)

        let startMonth = monthNames[max(0, min(11, (start.month ?? 1) - 1))]
        let endMonth = monthNames[max(0, min(11, (end.month ?? 1) - 1))]
        let startDay = start.day ?? 1
        let endDay = end.day ?? 1
        let startYear = start.year ?? 2026
        let endYear = end.year ?? 2026

        if startYear == endYear {
            return "\(startMonth) \(startDay) \u{2013} \(endMonth) \(endDay), \(endYear)"
        }
        return "\(startMonth) \(startDay), \(startYear) \u{2013} \(endMonth) \(endDay), \(endYear)"
    }

    public static func summarize(
        buckets: [TokenBucket],
        limitHits: [LimitHitEvent] = [],
        limitsHitAvailable: Bool = true,
        range: StatisticsRange,
        filter: StatisticsFilter,
        anchorDate: Date,
        calendar: Calendar = gregorianCalendar()
    ) -> StatisticsSummary {
        let dayCount = range.dayCount
        let anchorStart = calendar.startOfDay(for: anchorDate)

        var days: [(dayKey: String, date: Date, weekday: Int)] = []
        days.reserveCapacity(dayCount)
        var dayIndexByKey: [String: Int] = [:]
        var weekdayOccurrences = Array(repeating: 0, count: 7)

        for index in 0..<dayCount {
            let back = dayCount - 1 - index
            let date = calendar.date(byAdding: .day, value: -back, to: anchorStart) ?? anchorStart
            let key = dayKey(for: date, calendar: calendar)
            let weekday = calendar.component(.weekday, from: date) // 1 = Sun ... 7 = Sat
            let mondayIndex = (weekday + 5) % 7 // 0 = Mon ... 6 = Sun
            weekdayOccurrences[mondayIndex] += 1
            days.append((dayKey: key, date: date, weekday: weekday))
            dayIndexByKey[key] = index
        }

        let visibleProviders: [ProviderID] = switch filter {
        case .overview: ProviderID.allCases
        case .provider(let id): [id]
        }
        let visibleSet = Set(visibleProviders)

        // Sidebar totals (always computed across all providers for the active range)
        var sidebarTotalsByProvider: [ProviderID: Int] = Dictionary(
            uniqueKeysWithValues: ProviderID.allCases.map { ($0, 0) }
        )

        // Filtered accumulators
        var filteredInput = 0
        var filteredOutput = 0
        var filteredCache = 0
        var filteredRequests = 0
        var filteredTotalDouble = 0.0
        var dailyProviderTokens: [[ProviderID: Int]] = Array(repeating: [:], count: dayCount)
        var modelTotals: [ModelKey: Int] = [:]
        var heatmapTokens: [[Int]] = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        var heatmapRequests: [[Int]] = Array(repeating: Array(repeating: 0, count: 24), count: 7)

        for bucket in buckets {
            guard let dayIndex = dayIndexByKey[bucket.dayKey] else { continue }
            let bucketTotal = bucket.totalTokens
            sidebarTotalsByProvider[bucket.provider] = CheckedTokenMath.saturatingAdd(
                sidebarTotalsByProvider[bucket.provider] ?? 0,
                bucketTotal
            )

            guard visibleSet.contains(bucket.provider) else { continue }

            filteredInput = CheckedTokenMath.saturatingAdd(filteredInput, bucket.inputTokens)
            filteredOutput = CheckedTokenMath.saturatingAdd(filteredOutput, bucket.outputTokens)
            filteredCache = CheckedTokenMath.saturatingAdd(filteredCache, bucket.cacheTokens)
            filteredRequests = CheckedTokenMath.saturatingAdd(filteredRequests, bucket.requests)
            filteredTotalDouble += Double(bucketTotal)

            dailyProviderTokens[dayIndex][bucket.provider] = CheckedTokenMath.saturatingAdd(
                dailyProviderTokens[dayIndex][bucket.provider] ?? 0,
                bucketTotal
            )

            let modelKey = ModelKey(provider: bucket.provider, model: bucket.model)
            modelTotals[modelKey] = CheckedTokenMath.saturatingAdd(
                modelTotals[modelKey] ?? 0,
                bucketTotal
            )

            let weekday = days[dayIndex].weekday
            let mondayIndex = (weekday + 5) % 7
            heatmapTokens[mondayIndex][bucket.hour] = CheckedTokenMath.saturatingAdd(
                heatmapTokens[mondayIndex][bucket.hour],
                bucketTotal
            )
            heatmapRequests[mondayIndex][bucket.hour] = CheckedTokenMath.saturatingAdd(
                heatmapRequests[mondayIndex][bucket.hour],
                bucket.requests
            )
        }

        let sidebarTotalAll = ProviderID.allCases.reduce(0) {
            CheckedTokenMath.saturatingAdd($0, sidebarTotalsByProvider[$1] ?? 0)
        }
        let tokenSummary = TokenSummary(
            inputTokens: filteredInput,
            outputTokens: filteredOutput,
            cacheTokens: filteredCache,
            requests: filteredRequests
        )

        // Limits hit within window & filter
        let limitsHit = limitHits.reduce(0) { count, event in
            guard dayIndexByKey[event.dayKey] != nil, visibleSet.contains(event.provider) else {
                return count
            }
            return CheckedTokenMath.saturatingAdd(count, 1)
        }

        // Daily stacked bars
        var maxDailyTokens = 0
        var dailyBars: [DailyTokenBar] = []
        dailyBars.reserveCapacity(dayCount)

        for (index, day) in days.enumerated() {
            let segments = visibleProviders.map { provider in
                DayBarSegment(provider: provider, tokens: dailyProviderTokens[index][provider] ?? 0)
            }
            let dayTotal = segments.reduce(0) { CheckedTokenMath.saturatingAdd($0, $1.tokens) }
            maxDailyTokens = max(maxDailyTokens, dayTotal)

            let month = calendar.component(.month, from: day.date)
            let dayNum = calendar.component(.day, from: day.date)
            let monthText = monthNames[max(0, min(11, month - 1))]
            let weekdayText = weekdayNames[max(0, min(6, day.weekday - 1))]

            let axisLabel: String
            if range == .sevenDays {
                axisLabel = weekdayText
            } else {
                axisLabel = index % 5 == 4 ? "\(monthText) \(dayNum)" : ""
            }

            let tooltip = "\(monthText) \(dayNum) \u{00B7} \(TokenFormatter.formatTokens(dayTotal))"
            dailyBars.append(
                DailyTokenBar(
                    dayKey: day.dayKey,
                    date: day.date,
                    axisLabel: axisLabel,
                    tooltipText: tooltip,
                    segments: segments,
                    totalTokens: dayTotal
                )
            )
        }

        let yAxisTop = niceYAxisTop(for: maxDailyTokens)
        let yAxisMid = yAxisTop / 2

        // Top 5 models sorted by tokens descending (stable tie-break by provider order then model name)
        let providerOrder = Dictionary(uniqueKeysWithValues: ProviderID.allCases.enumerated().map { ($1, $0) })
        let sortedModels = modelTotals
            .filter { $0.value > 0 }
            .sorted { lhs, rhs in
                if lhs.value != rhs.value {
                    return lhs.value > rhs.value
                }
                let lp = providerOrder[lhs.key.provider] ?? 0
                let rp = providerOrder[rhs.key.provider] ?? 0
                if lp != rp {
                    return lp < rp
                }
                return lhs.key.model < rhs.key.model
            }
            .prefix(5)

        let topModelTokens = sortedModels.first?.value ?? 0
        let totalFilteredTokensDouble = max(Double(tokenSummary.totalTokens), filteredTotalDouble)
        let topModels: [ModelUsageRow] = sortedModels.map { entry in
            let share: Int
            if totalFilteredTokensDouble > 0 {
                let raw = (Double(entry.value) / totalFilteredTokensDouble * 100.0).rounded()
                share = raw.isFinite ? Int(min(100.0, max(0.0, raw))) : 0
            } else {
                share = 0
            }
            let relative = topModelTokens > 0
                ? Double(entry.value) / Double(topModelTokens)
                : 0.0
            let via: String? = (entry.key.provider == .cursor || entry.key.provider == .opencode)
                ? "via \(entry.key.provider.displayName)"
                : nil
            return ModelUsageRow(
                provider: entry.key.provider,
                model: entry.key.model,
                viaText: via,
                tokens: entry.value,
                sharePercent: share,
                relativeToTop: relative
            )
        }

        // 7x24 Heatmap represents activity (requests per weekday × hour), averaged by per-weekday
        // occurrence count so 5-occurrence weekdays in 30D stay balanced, normalized to the max cell.
        // Falls back to token averages only when no request counts are present in the range.
        var averagedRequests: [[Double]] = Array(repeating: Array(repeating: 0.0, count: 24), count: 7)
        var maxAverageRequests = 0.0
        var averagedTokens: [[Double]] = Array(repeating: Array(repeating: 0.0, count: 24), count: 7)
        var maxAverageTokens = 0.0
        for row in 0..<7 {
            let occurrences = max(1, weekdayOccurrences[row])
            for hour in 0..<24 {
                let reqAvg = Double(heatmapRequests[row][hour]) / Double(occurrences)
                averagedRequests[row][hour] = reqAvg
                if reqAvg > maxAverageRequests {
                    maxAverageRequests = reqAvg
                }
                let tokAvg = Double(heatmapTokens[row][hour]) / Double(occurrences)
                averagedTokens[row][hour] = tokAvg
                if tokAvg > maxAverageTokens {
                    maxAverageTokens = tokAvg
                }
            }
        }

        let useRequests = maxAverageRequests > 0
        let heatmapRows: [HeatmapRow] = (0..<7).map { row in
            let cells = (0..<24).map { hour in
                let intensity: Double
                if useRequests {
                    intensity = averagedRequests[row][hour] / maxAverageRequests
                } else if maxAverageTokens > 0 {
                    intensity = averagedTokens[row][hour] / maxAverageTokens
                } else {
                    intensity = 0.0
                }
                return HeatmapCell(
                    hour: hour,
                    tokens: heatmapTokens[row][hour],
                    requests: heatmapRequests[row][hour],
                    intensity: intensity
                )
            }
            return HeatmapRow(
                weekdayIndex: row,
                dayLabel: mondayFirstLabels[row],
                cells: cells
            )
        }

        let rangeLabel = dateRangeText(
            from: days.first?.date ?? anchorStart,
            to: days.last?.date ?? anchorStart,
            calendar: calendar
        )

        return StatisticsSummary(
            range: range,
            filter: filter,
            heading: filter.heading,
            dateRangeText: rangeLabel,
            sidebarTotalAll: sidebarTotalAll,
            sidebarTotalsByProvider: sidebarTotalsByProvider,
            visibleProviders: visibleProviders,
            tokenSummary: tokenSummary,
            limitsHit: limitsHit,
            limitsHitAvailable: limitsHitAvailable,
            dailyBars: dailyBars,
            yAxisTop: yAxisTop,
            yAxisMid: yAxisMid,
            topModels: topModels,
            heatmapRows: heatmapRows
        )
    }

    /// Aggregates a single day's buckets into the dropdown's `TodayUsageSummary`.
    public static func todayUsage(
        from buckets: [TokenBucket],
        on date: Date,
        calendar: Calendar = gregorianCalendar()
    ) -> TodayUsageSummary {
        let targetKey = dayKey(for: date, calendar: calendar)
        var totalTokens = 0
        var totalRequests = 0
        var twoHourBins = Array(repeating: 0, count: 12)
        var providerTokens: [ProviderID: Int] = [:]
        var providerRequests: [ProviderID: Int] = [:]
        var providerModels: [ProviderID: [String: Int]] = [:]

        for bucket in buckets where bucket.dayKey == targetKey {
            let tokens = bucket.totalTokens
            totalTokens = CheckedTokenMath.saturatingAdd(totalTokens, tokens)
            totalRequests = CheckedTokenMath.saturatingAdd(totalRequests, bucket.requests)
            let binIdx = min(11, max(0, bucket.hour / 2))
            twoHourBins[binIdx] = CheckedTokenMath.saturatingAdd(twoHourBins[binIdx], tokens)
            providerTokens[bucket.provider] = CheckedTokenMath.saturatingAdd(providerTokens[bucket.provider] ?? 0, tokens)
            providerRequests[bucket.provider] = CheckedTokenMath.saturatingAdd(providerRequests[bucket.provider] ?? 0, bucket.requests)
            var models = providerModels[bucket.provider] ?? [:]
            models[bucket.model] = CheckedTokenMath.saturatingAdd(models[bucket.model] ?? 0, tokens)
            providerModels[bucket.provider] = models
        }

        var byProvider: [ProviderID: ProviderTodayUsage] = [:]
        for provider in ProviderID.allCases {
            let pTotal = providerTokens[provider] ?? 0
            let pReq = providerRequests[provider] ?? 0
            let rawModels = (providerModels[provider] ?? [:])
                .filter { $0.value > 0 }
                .sorted { lhs, rhs in
                    if lhs.value != rhs.value {
                        return lhs.value > rhs.value
                    }
                    return lhs.key < rhs.key
                }

            let shares = largestRemainderPercents(for: rawModels.map(\.value))
            let models = zip(rawModels, shares).map { entry, share in
                ModelShare(model: entry.key, sharePercent: share, tokens: entry.value)
            }
            byProvider[provider] = ProviderTodayUsage(
                provider: provider,
                totalTokens: pTotal,
                requests: pReq,
                models: models
            )
        }

        return TodayUsageSummary(
            totalTokens: totalTokens,
            totalRequests: totalRequests,
            hourlySparkline: twoHourBins,
            byProvider: byProvider
        )
    }

    private struct ModelKey: Hashable {
        let provider: ProviderID
        let model: String
    }

    private static func niceYAxisTop(for maxValue: Int) -> Int {
        guard maxValue > 0 else { return 0 }
        let step: Int
        if maxValue >= 500_000 {
            step = 500_000
        } else if maxValue >= 100_000 {
            step = 100_000
        } else if maxValue >= 20_000 {
            step = 20_000
        } else if maxValue >= 5_000 {
            step = 5_000
        } else {
            step = 1_000
        }
        let remainder = maxValue % step
        if remainder == 0 {
            return maxValue
        }
        let increment = step - remainder
        let (rounded, overflow) = maxValue.addingReportingOverflow(increment)
        return overflow ? Int.max : rounded
    }

    private static func largestRemainderPercents(for values: [Int]) -> [Int] {
        let sum = values.reduce(0.0) { $0 + Double(max(0, $1)) }
        guard sum > 0 else { return Array(repeating: 0, count: values.count) }
        var floors: [Int] = []
        floors.reserveCapacity(values.count)
        var remainders: [(index: Int, remainder: Double)] = []
        remainders.reserveCapacity(values.count)
        var floorSum = 0

        for (index, value) in values.enumerated() {
            let exact = (Double(max(0, value)) / sum) * 100.0
            let flooredDouble = floor(exact)
            let floored = flooredDouble.isFinite ? min(100, max(0, Int(flooredDouble))) : 0
            floors.append(floored)
            floorSum = CheckedTokenMath.saturatingAdd(floorSum, floored)
            remainders.append((index: index, remainder: max(0.0, exact - Double(floored))))
        }

        let deficit = max(0, 100 - floorSum)
        let sortedIndices = remainders.sorted { lhs, rhs in
            if lhs.remainder != rhs.remainder {
                return lhs.remainder > rhs.remainder
            }
            return lhs.index < rhs.index
        }
        for i in 0..<min(deficit, sortedIndices.count) {
            floors[sortedIndices[i].index] += 1
        }
        return floors
    }
}
