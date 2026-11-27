import XCTest
@testable import OpenUsageCore

final class StatisticsAggregatorTests: XCTestCase {
    private func makeDate(year: Int, month: Int, day: Int, calendar: Calendar) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        return calendar.date(from: components)!
    }

    func testAggregatorTotalsByRangeAndProviderAndInOutCacheSplit() {
        let calendar = StatisticsAggregator.gregorianCalendar(timeZone: TimeZone(secondsFromGMT: 0)!)
        let anchor = makeDate(year: 2026, month: 11, day: 26, calendar: calendar)

        let buckets = [
            // Outside 30D window (Oct 27) -> must be ignored
            TokenBucket(dayKey: "2026-10-27", hour: 10, provider: .claude, model: "claude-opus-4.5", inputTokens: 99_000, outputTokens: 1_000, cacheTokens: 0, requests: 99),
            // Inside 30D but outside 7D (Nov 10)
            TokenBucket(dayKey: "2026-11-10", hour: 14, provider: .claude, model: "claude-opus-4.5", inputTokens: 200_000, outputTokens: 50_000, cacheTokens: 750_000, requests: 20),
            TokenBucket(dayKey: "2026-11-10", hour: 15, provider: .chatgpt, model: "gpt-5-codex", inputTokens: 100_000, outputTokens: 20_000, cacheTokens: 380_000, requests: 10),
            // Inside 7D (Nov 25, Nov 26)
            TokenBucket(dayKey: "2026-11-25", hour: 9, provider: .claude, model: "claude-sonnet-4.5", inputTokens: 60_000, outputTokens: 15_000, cacheTokens: 225_000, requests: 8),
            TokenBucket(dayKey: "2026-11-26", hour: 11, provider: .cursor, model: "composer-1", inputTokens: 40_000, outputTokens: 10_000, cacheTokens: 150_000, requests: 5)
        ]

        let hits = [
            LimitHitEvent(dayKey: "2026-10-27", provider: .claude, limitName: "Old"),
            LimitHitEvent(dayKey: "2026-11-10", provider: .claude, limitName: "5-hour"),
            LimitHitEvent(dayKey: "2026-11-25", provider: .claude, limitName: "Weekly · Opus"),
            LimitHitEvent(dayKey: "2026-11-26", provider: .chatgpt, limitName: "5-hour")
        ]

        // 30D overview
        let overview30 = StatisticsAggregator.summarize(
            buckets: buckets,
            limitHits: hits,
            range: .thirtyDays,
            filter: .overview,
            anchorDate: anchor,
            calendar: calendar
        )
        XCTAssertEqual(overview30.tokenSummary.inputTokens, 400_000)
        XCTAssertEqual(overview30.tokenSummary.outputTokens, 95_000)
        XCTAssertEqual(overview30.tokenSummary.cacheTokens, 1_505_000)
        XCTAssertEqual(overview30.tokenSummary.totalTokens, 2_000_000)
        XCTAssertEqual(overview30.tokenSummary.requests, 43)
        XCTAssertEqual(overview30.limitsHit, 3)
        XCTAssertEqual(overview30.sidebarTotal(for: .overview), 2_000_000)
        XCTAssertEqual(overview30.sidebarTotal(for: .provider(.claude)), 1_300_000)
        XCTAssertEqual(overview30.sidebarTotal(for: .provider(.chatgpt)), 500_000)
        XCTAssertEqual(overview30.sidebarTotal(for: .provider(.cursor)), 200_000)

        // 7D overview
        let overview7 = StatisticsAggregator.summarize(
            buckets: buckets,
            limitHits: hits,
            range: .sevenDays,
            filter: .overview,
            anchorDate: anchor,
            calendar: calendar
        )
        XCTAssertEqual(overview7.tokenSummary.totalTokens, 500_000)
        XCTAssertEqual(overview7.tokenSummary.requests, 13)
        XCTAssertEqual(overview7.limitsHit, 2)

        // 7D Claude only (sidebar totals still reflect all providers in 7D)
        let claude7 = StatisticsAggregator.summarize(
            buckets: buckets,
            limitHits: hits,
            range: .sevenDays,
            filter: .provider(.claude),
            anchorDate: anchor,
            calendar: calendar
        )
        XCTAssertEqual(claude7.heading, "Claude")
        XCTAssertEqual(claude7.visibleProviders, [.claude])
        XCTAssertEqual(claude7.tokenSummary.inputTokens, 60_000)
        XCTAssertEqual(claude7.tokenSummary.outputTokens, 15_000)
        XCTAssertEqual(claude7.tokenSummary.cacheTokens, 225_000)
        XCTAssertEqual(claude7.tokenSummary.totalTokens, 300_000)
        XCTAssertEqual(claude7.tokenSummary.requests, 8)
        XCTAssertEqual(claude7.limitsHit, 1)
        XCTAssertEqual(claude7.sidebarTotal(for: .overview), 500_000)
        XCTAssertEqual(claude7.sidebarTotal(for: .provider(.cursor)), 200_000)
    }

    func testTopModelsCappedAtFiveWithSharesAndViaLabels() {
        let calendar = StatisticsAggregator.gregorianCalendar(timeZone: TimeZone(secondsFromGMT: 0)!)
        let anchor = makeDate(year: 2026, month: 11, day: 26, calendar: calendar)

        let buckets = [
            TokenBucket(dayKey: "2026-11-26", hour: 10, provider: .claude, model: "claude-opus-4.5", inputTokens: 500, outputTokens: 0, cacheTokens: 0, requests: 1),
            TokenBucket(dayKey: "2026-11-26", hour: 10, provider: .chatgpt, model: "gpt-5-codex", inputTokens: 300, outputTokens: 0, cacheTokens: 0, requests: 1),
            TokenBucket(dayKey: "2026-11-26", hour: 10, provider: .cursor, model: "composer-1", inputTokens: 100, outputTokens: 0, cacheTokens: 0, requests: 1),
            TokenBucket(dayKey: "2026-11-26", hour: 10, provider: .opencode, model: "kimi-k2", inputTokens: 50, outputTokens: 0, cacheTokens: 0, requests: 1),
            TokenBucket(dayKey: "2026-11-26", hour: 10, provider: .gemini, model: "gemini-3-pro", inputTokens: 30, outputTokens: 0, cacheTokens: 0, requests: 1),
            TokenBucket(dayKey: "2026-11-26", hour: 10, provider: .cursor, model: "claude-sonnet-4.5", inputTokens: 20, outputTokens: 0, cacheTokens: 0, requests: 1)
        ]

        let summary = StatisticsAggregator.summarize(
            buckets: buckets,
            range: .sevenDays,
            filter: .overview,
            anchorDate: anchor,
            calendar: calendar
        )

        XCTAssertEqual(summary.topModels.count, 5)
        XCTAssertEqual(summary.topModels.map(\.model), ["claude-opus-4.5", "gpt-5-codex", "composer-1", "kimi-k2", "gemini-3-pro"])
        XCTAssertEqual(summary.topModels.map(\.sharePercent), [50, 30, 10, 5, 3])
        XCTAssertNil(summary.topModels[0].viaText)
        XCTAssertNil(summary.topModels[1].viaText)
        XCTAssertEqual(summary.topModels[2].viaText, "via Cursor")
        XCTAssertEqual(summary.topModels[3].viaText, "via OpenCode")
        XCTAssertNil(summary.topModels[4].viaText)
        XCTAssertEqual(summary.topModels[0].relativeToTop, 1.0, accuracy: 0.0001)
        XCTAssertEqual(summary.topModels[1].relativeToTop, 0.6, accuracy: 0.0001)
    }

    func testHeatmapBucketingByWeekdayAndHour() {
        let calendar = StatisticsAggregator.gregorianCalendar(timeZone: TimeZone(secondsFromGMT: 0)!)
        // Thu Nov 26, 2026; Mon Nov 23, 2026; Sun Nov 22, 2026
        let anchor = makeDate(year: 2026, month: 11, day: 26, calendar: calendar)

        let buckets = [
            // Higher requests with fewer tokens on Mon 9am vs lower requests with more tokens on Thu 9pm
            TokenBucket(dayKey: "2026-11-23", hour: 9, provider: .claude, model: "opus", inputTokens: 200, outputTokens: 0, cacheTokens: 0, requests: 8),   // Mon 9am
            TokenBucket(dayKey: "2026-11-26", hour: 21, provider: .claude, model: "opus", inputTokens: 2_000, outputTokens: 0, cacheTokens: 0, requests: 4), // Thu 9pm
            TokenBucket(dayKey: "2026-11-22", hour: 0, provider: .claude, model: "opus", inputTokens: 500, outputTokens: 0, cacheTokens: 0, requests: 2)    // Sun 12am
        ]

        let summary = StatisticsAggregator.summarize(
            buckets: buckets,
            range: .sevenDays,
            filter: .overview,
            anchorDate: anchor,
            calendar: calendar
        )

        XCTAssertEqual(summary.heatmapRows.map(\.dayLabel), ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"])
        for row in summary.heatmapRows {
            XCTAssertEqual(row.cells.count, 24)
        }

        // Mon (row 0), hour 9 = 8 requests -> intensity 1.0 (independent of token count)
        XCTAssertEqual(summary.heatmapRows[0].cells[9].tokens, 200)
        XCTAssertEqual(summary.heatmapRows[0].cells[9].requests, 8)
        XCTAssertEqual(summary.heatmapRows[0].cells[9].intensity, 1.0, accuracy: 0.0001)

        // Thu (row 3), hour 21 = 4 requests -> intensity 0.5
        XCTAssertEqual(summary.heatmapRows[3].cells[21].tokens, 2_000)
        XCTAssertEqual(summary.heatmapRows[3].cells[21].requests, 4)
        XCTAssertEqual(summary.heatmapRows[3].cells[21].intensity, 0.5, accuracy: 0.0001)

        // Sun (row 6), hour 0 = 2 requests -> intensity 0.25
        XCTAssertEqual(summary.heatmapRows[6].cells[0].tokens, 500)
        XCTAssertEqual(summary.heatmapRows[6].cells[0].requests, 2)
        XCTAssertEqual(summary.heatmapRows[6].cells[0].intensity, 0.25, accuracy: 0.0001)

        // Untouched cell = 0 -> intensity 0
        XCTAssertEqual(summary.heatmapRows[1].cells[12].tokens, 0)
        XCTAssertEqual(summary.heatmapRows[1].cells[12].requests, 0)
        XCTAssertEqual(summary.heatmapRows[1].cells[12].intensity, 0.0, accuracy: 0.0001)
    }

    func testPerDaySeriesAndDateRangeLabels() {
        let calendar = StatisticsAggregator.gregorianCalendar(timeZone: TimeZone(secondsFromGMT: 0)!)
        let anchor = makeDate(year: 2026, month: 11, day: 26, calendar: calendar)

        let summary30 = StatisticsAggregator.summarize(
            buckets: [],
            range: .thirtyDays,
            filter: .overview,
            anchorDate: anchor,
            calendar: calendar
        )
        XCTAssertEqual(summary30.dateRangeText, "Oct 28 \u{2013} Nov 26, 2026")
        XCTAssertEqual(summary30.dailyBars.count, 30)
        XCTAssertEqual(summary30.dailyBars.first?.dayKey, "2026-10-28")
        XCTAssertEqual(summary30.dailyBars.last?.dayKey, "2026-11-26")
        let nonEmptyLabels30 = summary30.dailyBars.map(\.axisLabel).filter { !$0.isEmpty }
        XCTAssertEqual(nonEmptyLabels30, ["Nov 1", "Nov 6", "Nov 11", "Nov 16", "Nov 21", "Nov 26"])

        let summary7 = StatisticsAggregator.summarize(
            buckets: [],
            range: .sevenDays,
            filter: .provider(.claude),
            anchorDate: anchor,
            calendar: calendar
        )
        XCTAssertEqual(summary7.dateRangeText, "Nov 20 \u{2013} Nov 26, 2026")
        XCTAssertEqual(summary7.dailyBars.count, 7)
        XCTAssertEqual(summary7.dailyBars.map(\.axisLabel), ["Fri", "Sat", "Sun", "Mon", "Tue", "Wed", "Thu"])
        XCTAssertTrue(summary7.dailyBars.allSatisfy { $0.segments.map(\.provider) == [.claude] })

        // Cross-year range formatting
        let janAnchor = makeDate(year: 2027, month: 1, day: 10, calendar: calendar)
        let crossYear = StatisticsAggregator.summarize(
            buckets: [],
            range: .thirtyDays,
            filter: .overview,
            anchorDate: janAnchor,
            calendar: calendar
        )
        XCTAssertEqual(crossYear.dateRangeText, "Dec 12, 2026 \u{2013} Jan 10, 2027")
    }

    func testDemoFixtureMatchesReferenceStills03And04Exactly() {
        let buckets = DemoFixtures.tokenBuckets()
        let hits = DemoFixtures.limitHitEvents()
        let anchor = DemoFixtures.referenceDate

        // Still 03: Overview, 30D
        let overview30 = StatisticsAggregator.summarize(
            buckets: buckets,
            limitHits: hits,
            range: .thirtyDays,
            filter: .overview,
            anchorDate: anchor
        )
        XCTAssertEqual(overview30.heading, "All subscriptions")
        XCTAssertEqual(overview30.dateRangeText, "Oct 28 \u{2013} Nov 26, 2026")
        XCTAssertEqual(TokenFormatter.formatTokens(overview30.tokenSummary.totalTokens), "51.1M")
        XCTAssertEqual(TokenFormatter.formatTokens(overview30.sidebarTotal(for: .overview)), "51.1M")
        XCTAssertEqual(TokenFormatter.formatTokens(overview30.sidebarTotal(for: .provider(.claude))), "22.9M")
        XCTAssertEqual(TokenFormatter.formatTokens(overview30.sidebarTotal(for: .provider(.chatgpt))), "12.3M")
        XCTAssertEqual(TokenFormatter.formatTokens(overview30.sidebarTotal(for: .provider(.cursor))), "7.07M")
        XCTAssertEqual(TokenFormatter.formatTokens(overview30.sidebarTotal(for: .provider(.gemini))), "5.86M")
        XCTAssertEqual(TokenFormatter.formatTokens(overview30.sidebarTotal(for: .provider(.opencode))), "2.99M")
        XCTAssertEqual(TokenFormatter.formatTokens(overview30.tokenSummary.inputTokens), "12.3M")
        XCTAssertEqual(TokenFormatter.formatTokens(overview30.tokenSummary.outputTokens), "3.57M")
        XCTAssertEqual(TokenFormatter.formatTokens(overview30.tokenSummary.cacheTokens), "35.2M")
        XCTAssertEqual(TokenFormatter.formatCount(overview30.tokenSummary.requests), "5,870")
        XCTAssertEqual(overview30.limitsHit, 4)
        XCTAssertEqual(TokenFormatter.formatTokens(overview30.yAxisTop), "2.50M")
        XCTAssertEqual(TokenFormatter.formatTokens(overview30.yAxisMid), "1.25M")

        XCTAssertEqual(overview30.topModels.count, 5)
        XCTAssertEqual(overview30.topModels[0].model, "claude-opus-4.5")
        XCTAssertEqual(TokenFormatter.formatTokens(overview30.topModels[0].tokens), "14.2M")
        XCTAssertEqual(overview30.topModels[0].sharePercent, 28)

        XCTAssertEqual(overview30.topModels[1].model, "gpt-5-codex")
        XCTAssertEqual(TokenFormatter.formatTokens(overview30.topModels[1].tokens), "9.56M")
        XCTAssertEqual(overview30.topModels[1].sharePercent, 19)

        XCTAssertEqual(overview30.topModels[2].model, "claude-sonnet-4.5")
        XCTAssertEqual(TokenFormatter.formatTokens(overview30.topModels[2].tokens), "7.10M")
        XCTAssertEqual(overview30.topModels[2].sharePercent, 14)

        XCTAssertEqual(overview30.topModels[3].model, "composer-1")
        XCTAssertEqual(overview30.topModels[3].viaText, "via Cursor")
        XCTAssertEqual(TokenFormatter.formatTokens(overview30.topModels[3].tokens), "3.89M")
        XCTAssertEqual(overview30.topModels[3].sharePercent, 8)

        XCTAssertEqual(overview30.topModels[4].model, "gemini-3-pro")
        XCTAssertEqual(TokenFormatter.formatTokens(overview30.topModels[4].tokens), "3.75M")
        XCTAssertEqual(overview30.topModels[4].sharePercent, 7)

        // Still 04: Claude, 7D (and 7D overview sidebar totals)
        let claude7 = StatisticsAggregator.summarize(
            buckets: buckets,
            limitHits: hits,
            range: .sevenDays,
            filter: .provider(.claude),
            anchorDate: anchor
        )
        XCTAssertEqual(claude7.heading, "Claude")
        XCTAssertEqual(claude7.dateRangeText, "Nov 20 \u{2013} Nov 26, 2026")
        XCTAssertEqual(TokenFormatter.formatTokens(claude7.sidebarTotal(for: .overview)), "11.8M")
        XCTAssertEqual(TokenFormatter.formatTokens(claude7.sidebarTotal(for: .provider(.claude))), "5.34M")
        XCTAssertEqual(TokenFormatter.formatTokens(claude7.sidebarTotal(for: .provider(.chatgpt))), "2.70M")
        XCTAssertEqual(TokenFormatter.formatTokens(claude7.sidebarTotal(for: .provider(.cursor))), "1.66M")
        XCTAssertEqual(TokenFormatter.formatTokens(claude7.sidebarTotal(for: .provider(.gemini))), "1.37M")
        XCTAssertEqual(TokenFormatter.formatTokens(claude7.sidebarTotal(for: .provider(.opencode))), "701K")

        XCTAssertEqual(TokenFormatter.formatTokens(claude7.tokenSummary.totalTokens), "5.34M")
        XCTAssertEqual(TokenFormatter.formatTokens(claude7.tokenSummary.inputTokens), "1.28M")
        XCTAssertEqual(TokenFormatter.formatTokens(claude7.tokenSummary.outputTokens), "374K")
        XCTAssertEqual(TokenFormatter.formatTokens(claude7.tokenSummary.cacheTokens), "3.68M")
        XCTAssertEqual(TokenFormatter.formatCount(claude7.tokenSummary.requests), "613")
        XCTAssertEqual(claude7.limitsHit, 1)
        XCTAssertEqual(TokenFormatter.formatTokens(claude7.yAxisTop), "1.50M")
        XCTAssertEqual(TokenFormatter.formatTokens(claude7.yAxisMid), "750K")

        XCTAssertEqual(claude7.topModels.count, 3)
        XCTAssertEqual(claude7.topModels[0].model, "claude-opus-4.5")
        XCTAssertEqual(TokenFormatter.formatTokens(claude7.topModels[0].tokens), "3.31M")
        XCTAssertEqual(claude7.topModels[0].sharePercent, 62)

        XCTAssertEqual(claude7.topModels[1].model, "claude-sonnet-4.5")
        XCTAssertEqual(TokenFormatter.formatTokens(claude7.topModels[1].tokens), "1.65M")
        XCTAssertEqual(claude7.topModels[1].sharePercent, 31)

        XCTAssertEqual(claude7.topModels[2].model, "claude-haiku-4.5")
        XCTAssertEqual(TokenFormatter.formatTokens(claude7.topModels[2].tokens), "374K")
        XCTAssertEqual(claude7.topModels[2].sharePercent, 7)

        // Individual daily amounts match FinalStats.dc.html (stills 03 & 04)
        let expectedClaude7Daily: [(label: String, tokens: Int, formatted: String)] = [
            ("Fri", 901_237, "901K"),
            ("Sat", 371_683, "372K"),
            ("Sun", 408_859, "409K"),
            ("Mon", 784_350, "784K"),
            ("Tue", 1_105_728, "1.11M"),
            ("Wed", 617_953, "618K"),
            ("Thu", 1_146_430, "1.15M")
        ]
        XCTAssertEqual(claude7.dailyBars.count, expectedClaude7Daily.count)
        for (bar, expected) in zip(claude7.dailyBars, expectedClaude7Daily) {
            XCTAssertEqual(bar.axisLabel, expected.label)
            XCTAssertEqual(bar.totalTokens, expected.tokens)
            XCTAssertEqual(TokenFormatter.formatTokens(bar.totalTokens), expected.formatted)
        }
        // Still 04: Thursday is Claude's tallest bar (~1.15M, above Tuesday's 1.11M)
        XCTAssertGreaterThan(claude7.dailyBars[6].totalTokens, claude7.dailyBars[4].totalTokens)

        // Still 03: Overview's final stack (Nov 26) is 2.22M and all 30 daily totals match FinalStats.dc.html
        XCTAssertEqual(overview30.dailyBars.last?.totalTokens, 2_224_618)
        XCTAssertEqual(TokenFormatter.formatTokens(overview30.dailyBars.last?.totalTokens ?? 0), "2.22M")
        let calendar = StatisticsAggregator.gregorianCalendar()
        let bases: [Double] = [1_150_000, 620_000, 360_000, 300_000, 150_000]
        for (index, bar) in overview30.dailyBars.enumerated() {
            let back = 29 - index
            let absDay = Double(60 - back)
            let weekday = calendar.component(.weekday, from: bar.date)
            let weekendFactor = (weekday == 1 || weekday == 7) ? 0.4 : 1.0
            let expectedDayTotal = bases.enumerated().reduce(0) { partial, entry in
                let raw = entry.element * (0.4 + 0.6 * abs(sin(absDay * 1.7 + Double(entry.offset) * 2.3))) * weekendFactor
                return partial + Int(raw.rounded())
            }
            XCTAssertEqual(bar.totalTokens, expectedDayTotal, "Overview daily bar mismatch on \(bar.dayKey)")
        }

        // Still 04 & 03: Heatmap reproduces FinalStats.dc.html's weekday×hour pattern across ALL weekdays
        func meanIntensity(_ row: HeatmapRow, hours: ClosedRange<Int>) -> Double {
            let values = hours.map { row.cells[$0].intensity }
            return values.reduce(0, +) / Double(values.count)
        }

        func expectedReferenceIntensity(row: Int, hour: Int) -> Double {
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
            let weekendFactor = (row == 5 || row == 6) ? 0.35 : 1.0
            return min(1.0, work * weekendFactor * (0.55 + 0.45 * abs(sin(Double(hour) * 0.9 + Double(row) * 1.3))))
        }

        // Every weekday (Mon–Fri) in both Claude 7D and Overview 30D has bright workday > evening > quiet night
        for rowIndex in 0..<5 {
            for (label, rows) in [("Claude 7D", claude7.heatmapRows), ("Overview 30D", overview30.heatmapRows)] {
                let row = rows[rowIndex]
                let work = meanIntensity(row, hours: 9...18)
                let evening = meanIntensity(row, hours: 20...23)
                let night = meanIntensity(row, hours: 2...8)
                XCTAssertGreaterThan(work, 0.75, "\(label) \(row.dayLabel) should have bright workday band")
                XCTAssertGreaterThan(work, evening * 1.5, "\(label) \(row.dayLabel) workday > evening")
                XCTAssertGreaterThan(evening, night * 5.0, "\(label) \(row.dayLabel) evening > night")
            }
        }
        // Weekend rows are noticeably dimmer than weekday workday bands
        for (label, rows) in [("Claude 7D", claude7.heatmapRows), ("Overview 30D", overview30.heatmapRows)] {
            XCTAssertLessThan(meanIntensity(rows[5], hours: 9...18), 0.40, "\(label) Sat workday dimmed")
            XCTAssertLessThan(meanIntensity(rows[6], hours: 9...18), 0.40, "\(label) Sun workday dimmed")
        }

        // Cell-level regression checks for Mon (0), Wed (2), Thu (3), Sat (5) at 9 AM, 11 AM, 2 PM, 8 PM
        let checkedRows = [0, 2, 3, 5] // Mon, Wed, Thu, Sat
        let checkedHours = [9, 11, 14, 20]
        for rowIndex in checkedRows {
            for hour in checkedHours {
                let expected = expectedReferenceIntensity(row: rowIndex, hour: hour)
                let claudeCell = claude7.heatmapRows[rowIndex].cells[hour]
                let overviewCell = overview30.heatmapRows[rowIndex].cells[hour]
                XCTAssertEqual(
                    claudeCell.intensity,
                    expected,
                    accuracy: 0.06,
                    "Claude 7D heatmap mismatch at \(claude7.heatmapRows[rowIndex].dayLabel) h\(hour)"
                )
                XCTAssertEqual(
                    overviewCell.intensity,
                    expected,
                    accuracy: 0.025,
                    "Overview 30D heatmap mismatch at \(overview30.heatmapRows[rowIndex].dayLabel) h\(hour)"
                )
            }
        }

        // Regression check for the reported defect: Claude 7D Wed 9 AM and Mon 9 AM match Tue 11 AM brightness
        let claudeMon9 = claude7.heatmapRows[0].cells[9].intensity
        let claudeTue11 = claude7.heatmapRows[1].cells[11].intensity
        let claudeWed9 = claude7.heatmapRows[2].cells[9].intensity
        XCTAssertGreaterThan(claudeMon9, 0.90)
        XCTAssertGreaterThan(claudeWed9, 0.90)
        XCTAssertEqual(claudeWed9, claudeTue11, accuracy: 0.05)

        // Dropdown's own today fixture remains independent and preserves stills 01/02/05
        let today = DemoFixtures.todayUsage()
        XCTAssertEqual(TokenFormatter.formatTokens(today.totalTokens), "1.84M")
        XCTAssertEqual(today.totalRequests, 412)
        XCTAssertEqual(TokenFormatter.formatTokens(today.usage(for: .claude).totalTokens), "800K")
        XCTAssertEqual(TokenFormatter.formatTokens(today.usage(for: .chatgpt).totalTokens), "395K")
        XCTAssertEqual(TokenFormatter.formatTokens(today.usage(for: .cursor).totalTokens), "271K")
    }

    func testStatisticsTodayMergeAndDumperHandleMaxIntAndCombinedOverflow() {
        let calendar = StatisticsAggregator.gregorianCalendar(timeZone: TimeZone(secondsFromGMT: 0)!)
        let anchor = makeDate(year: 2026, month: 11, day: 26, calendar: calendar)

        // 1) Single Int.max input bucket (regression for chart y-axis rounding crash).
        let singleMaxBucket = [
            TokenBucket(
                dayKey: "2026-11-26",
                hour: 12,
                provider: .claude,
                model: "claude-opus-4.5",
                inputTokens: Int.max,
                outputTokens: 0,
                cacheTokens: 0,
                requests: 1
            )
        ]
        let singleSummary = StatisticsAggregator.summarize(
            buckets: singleMaxBucket,
            range: .sevenDays,
            filter: .overview,
            anchorDate: anchor,
            calendar: calendar
        )
        XCTAssertEqual(singleSummary.tokenSummary.totalTokens, Int.max)
        XCTAssertEqual(singleSummary.yAxisTop, Int.max)
        XCTAssertEqual(singleSummary.yAxisMid, Int.max / 2)
        XCTAssertEqual(singleSummary.dailyBars.last?.totalTokens, Int.max)
        XCTAssertEqual(singleSummary.topModels.first?.sharePercent, 100)

        // 2) Multiple buckets whose combined daily total, provider total, model total, and Today model-share
        // denominator all exceed Int.max.
        let multiOverflowBuckets = [
            TokenBucket(dayKey: "2026-11-26", hour: 10, provider: .claude, model: "model-a", inputTokens: Int.max, outputTokens: 0, cacheTokens: 0, requests: 1),
            TokenBucket(dayKey: "2026-11-26", hour: 11, provider: .claude, model: "model-b", inputTokens: Int.max, outputTokens: 0, cacheTokens: 0, requests: 1),
            TokenBucket(dayKey: "2026-11-26", hour: 12, provider: .chatgpt, model: "gpt-5-codex", inputTokens: Int.max, outputTokens: 0, cacheTokens: 0, requests: 1),
            TokenBucket(dayKey: "2026-11-26", hour: 10, provider: .claude, model: "model-a", inputTokens: Int.max, outputTokens: 100, cacheTokens: 50, requests: Int.max)
        ]

        // Merge must saturate without dropping buckets or trapping.
        let merged = TokenBucketAggregator.merge(multiOverflowBuckets)
        XCTAssertEqual(merged.count, 3)
        let mergedModelA = merged.first { $0.model == "model-a" }
        XCTAssertEqual(mergedModelA?.inputTokens, Int.max)
        XCTAssertEqual(mergedModelA?.outputTokens, 100)
        XCTAssertEqual(mergedModelA?.cacheTokens, 50)
        XCTAssertEqual(mergedModelA?.requests, Int.max)
        XCTAssertEqual(mergedModelA?.totalTokens, Int.max)

        // Statistics summary must complete for both overview and single-provider filters.
        let overflowOverview = StatisticsAggregator.summarize(
            buckets: multiOverflowBuckets,
            range: .thirtyDays,
            filter: .overview,
            anchorDate: anchor,
            calendar: calendar
        )
        XCTAssertEqual(overflowOverview.tokenSummary.totalTokens, Int.max)
        XCTAssertEqual(overflowOverview.sidebarTotalAll, Int.max)
        XCTAssertEqual(overflowOverview.dailyBars.last?.totalTokens, Int.max)
        XCTAssertEqual(overflowOverview.yAxisTop, Int.max)
        XCTAssertTrue(overflowOverview.topModels.allSatisfy { (0...100).contains($0.sharePercent) })

        // Today usage must complete and compute valid model shares totaling 100% without overflowing.
        let today = StatisticsAggregator.todayUsage(from: multiOverflowBuckets, on: anchor, calendar: calendar)
        XCTAssertEqual(today.totalTokens, Int.max)
        XCTAssertEqual(today.totalRequests, Int.max)
        let claudeToday = today.usage(for: .claude)
        XCTAssertEqual(claudeToday.totalTokens, Int.max)
        XCTAssertEqual(claudeToday.models.count, 2)
        XCTAssertEqual(claudeToday.models.map(\.sharePercent), [50, 50])

        // TokenSummaryDumper must format without crashing.
        let report = TokenSummaryDumper.formatReport(
            buckets: multiOverflowBuckets,
            anchorDate: anchor,
            calendar: calendar
        )
        XCTAssertTrue(report.contains("claude: total=\(Int.max)"))
        XCTAssertTrue(report.contains("all: total=\(Int.max)"))
    }

    func testLiveLimitsHitRemainsUnavailableWithoutHistoricalCoverage() {
        let calendar = StatisticsAggregator.gregorianCalendar(timeZone: TimeZone(secondsFromGMT: 0)!)
        let anchor = makeDate(year: 2026, month: 11, day: 26, calendar: calendar)

        // Demo mode has fixture historical coverage for both 7D and 30D.
        XCTAssertTrue(StatisticsLimitHitPolicy.isAvailable(isDemo: true, historicalCoverageDays: 0, range: .sevenDays))
        XCTAssertTrue(StatisticsLimitHitPolicy.isAvailable(isDemo: true, historicalCoverageDays: 0, range: .thirtyDays))

        // Live mode without full historical coverage for the selected range must stay unavailable (never invent 0).
        XCTAssertFalse(StatisticsLimitHitPolicy.isAvailable(isDemo: false, historicalCoverageDays: 0, range: .sevenDays))
        XCTAssertFalse(StatisticsLimitHitPolicy.isAvailable(isDemo: false, historicalCoverageDays: 0, range: .thirtyDays))
        XCTAssertFalse(StatisticsLimitHitPolicy.isAvailable(isDemo: false, historicalCoverageDays: 6, range: .sevenDays))
        XCTAssertTrue(StatisticsLimitHitPolicy.isAvailable(isDemo: false, historicalCoverageDays: 7, range: .sevenDays))
        XCTAssertFalse(StatisticsLimitHitPolicy.isAvailable(isDemo: false, historicalCoverageDays: 7, range: .thirtyDays))
        XCTAssertTrue(StatisticsLimitHitPolicy.isAvailable(isDemo: false, historicalCoverageDays: 30, range: .thirtyDays))

        let liveSummary = StatisticsAggregator.summarize(
            buckets: [
                TokenBucket(dayKey: "2026-11-26", hour: 12, provider: .claude, model: "claude-opus-4.5", inputTokens: 1_000, outputTokens: 200, cacheTokens: 0, requests: 2)
            ],
            limitHits: [],
            limitsHitAvailable: StatisticsLimitHitPolicy.isAvailable(isDemo: false, historicalCoverageDays: 0, range: .sevenDays),
            range: .sevenDays,
            filter: .overview,
            anchorDate: anchor,
            calendar: calendar
        )
        XCTAssertFalse(liveSummary.limitsHitAvailable)
        XCTAssertEqual(liveSummary.limitsHitDisplayText, "\u{2013}")
        XCTAssertNotEqual(liveSummary.limitsHitDisplayText, "0")
    }
}
