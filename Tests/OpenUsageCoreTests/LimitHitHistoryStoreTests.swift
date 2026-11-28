import Foundation
import XCTest
@testable import OpenUsageCore

private final class StepClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ initial: Date) {
        self.current = initial
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func set(_ date: Date) {
        lock.lock()
        current = date
        lock.unlock()
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}

final class LimitHitHistoryStoreTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        super.tearDown()
    }

    private func makeTempDir(prefix: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    private var utcCalendar: Calendar {
        StatisticsAggregator.gregorianCalendar(timeZone: TimeZone(secondsFromGMT: 0)!)
    }

    private func makeSnapshot(
        provider: ProviderID,
        state: ConnectionState = .connected,
        limits: [UsageLimit]
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: provider,
            plan: "Test",
            connectionState: state,
            limits: limits,
            connectedVia: "Test"
        )
    }

    func testRecordsLimitHitTransitionsDeduplicatesPerWindowAndPersistsAcrossReloads() throws {
        let dir = try makeTempDir(prefix: "limit-hit-transitions")
        let t0 = LogTimestampParser.parseISO8601("2026-11-01T10:00:00Z")!
        let clock = StepClock(t0)

        let window1Reset = t0.addingTimeInterval(5 * 3600)
        let window2Reset = t0.addingTimeInterval(10 * 3600)

        let store = LimitHitHistoryStore(directory: dir, clock: { clock.now() })
        XCTAssertNil(store.firstObservedAt())
        XCTAssertEqual(store.coverageRatio(for: .claude, range: .sevenDays), 0.0, accuracy: 0.0001)

        // 1. Initial observation below 100%: records firstObservedAt, appends 0 events.
        let initialEvents = store.observe(snapshots: [
            makeSnapshot(provider: .claude, limits: [
                UsageLimit(id: "claude-5h", name: "5-hour session", percentUsed: 80, resetText: "Resets in 5h", resetsAt: window1Reset)
            ])
        ])
        XCTAssertTrue(initialEvents.isEmpty)
        XCTAssertEqual(store.firstObservedAt(), t0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))

        // 2. Transition 80% -> 100% in window 1: appends 1 event.
        clock.advance(by: 1800)
        let hit1 = store.observe(snapshots: [
            makeSnapshot(provider: .claude, limits: [
                UsageLimit(id: "claude-5h", name: "5-hour session", percentUsed: 100, resetText: "Resets in 4h 30m", resetsAt: window1Reset)
            ])
        ])
        XCTAssertEqual(hit1.count, 1)
        XCTAssertEqual(hit1[0].provider, .claude)
        XCTAssertEqual(hit1[0].limitID, "claude-5h")
        XCTAssertEqual(hit1[0].timestamp, clock.now())

        // 3. Repeated 100% observation in same window (even with small server resetsAt jitter): NO duplicate.
        clock.advance(by: 60)
        let duplicate = store.observe(snapshots: [
            makeSnapshot(provider: .claude, limits: [
                UsageLimit(id: "claude-5h", name: "5-hour session", percentUsed: 100, resetText: "Resets in 4h 29m", resetsAt: window1Reset.addingTimeInterval(15))
            ])
        ])
        XCTAssertTrue(duplicate.isEmpty)

        // 4. Reload a brand new store instance from disk: still remembers window 1 is already at 100%.
        let reloaded = LimitHitHistoryStore(directory: dir, clock: { clock.now() })
        clock.advance(by: 60)
        let afterRestartDup = reloaded.observe(snapshots: [
            makeSnapshot(provider: .claude, limits: [
                UsageLimit(id: "claude-5h", name: "5-hour session", percentUsed: 100, resetText: "Resets in 4h 28m", resetsAt: window1Reset)
            ])
        ])
        XCTAssertTrue(afterRestartDup.isEmpty, "Reloaded store must not double-count the same window")

        // 5. New reset window already at 100% when first observed: appends 2nd event.
        clock.advance(by: 6 * 3600)
        let hit2 = reloaded.observe(snapshots: [
            makeSnapshot(provider: .claude, limits: [
                UsageLimit(id: "claude-5h", name: "5-hour session", percentUsed: 100, resetText: "Resets in 4h", resetsAt: window2Reset)
            ]),
            // Unknown previous state for ChatGPT already at 100%: appends 1 event for ChatGPT.
            makeSnapshot(provider: .chatgpt, limits: [
                UsageLimit(id: "chatgpt-5h", name: "5-hour", percentUsed: 100, resetText: "Resets in 3h", resetsAt: window2Reset)
            ])
        ])
        XCTAssertEqual(hit2.count, 2)
        XCTAssertEqual(reloaded.recordedEvents().count, 3)

        // 6. Drop below 100% then cross back to 100% in the same window: appends 1 new event.
        clock.advance(by: 300)
        _ = reloaded.observe(snapshots: [
            makeSnapshot(provider: .claude, limits: [
                UsageLimit(id: "claude-5h", name: "5-hour session", percentUsed: 95, resetText: "Resets in 3h 55m", resetsAt: window2Reset)
            ])
        ])
        clock.advance(by: 300)
        let hitAfterDrop = reloaded.observe(snapshots: [
            makeSnapshot(provider: .claude, limits: [
                UsageLimit(id: "claude-5h", name: "5-hour session", percentUsed: 100, resetText: "Resets in 3h 50m", resetsAt: window2Reset)
            ])
        ])
        XCTAssertEqual(hitAfterDrop.count, 1)
        XCTAssertEqual(reloaded.recordedEvents().count, 4)

        // Verify persisted JSON contains only privacy-safe keys (no credentials/emails).
        let rawJSON = try String(contentsOf: store.fileURL, encoding: .utf8)
        XCTAssertTrue(rawJSON.contains("claude-5h"))
        XCTAssertFalse(rawJSON.contains("token"))
        XCTAssertFalse(rawJSON.contains("email"))
    }

    /// Feeds observations at fixed `stepMinutes` across `[start, end]` for the given providers.
    private func observeContinuously(
        store: LimitHitHistoryStore,
        clock: StepClock,
        providers: [ProviderID],
        from start: Date,
        to end: Date,
        stepMinutes: Int = 15,
        percentByProvider: [ProviderID: Int] = [:]
    ) {
        let stepSeconds = TimeInterval(stepMinutes * 60)
        var t = start
        while t <= end {
            clock.set(t)
            let snapshots = providers.map { provider in
                makeSnapshot(provider: provider, limits: [
                    UsageLimit(
                        id: "\(provider.rawValue)-5h",
                        name: "5-hour",
                        percentUsed: percentByProvider[provider] ?? 20,
                        resetText: "Resets",
                        resetsAt: t.addingTimeInterval(3600)
                    )
                ])
            }
            _ = store.observe(snapshots: snapshots)
            t = t.addingTimeInterval(stepSeconds)
        }
        if t - stepSeconds < end {
            clock.set(end)
            let snapshots = providers.map { provider in
                makeSnapshot(provider: provider, limits: [
                    UsageLimit(
                        id: "\(provider.rawValue)-5h",
                        name: "5-hour",
                        percentUsed: percentByProvider[provider] ?? 20,
                        resetText: "Resets",
                        resetsAt: end.addingTimeInterval(3600)
                    )
                ])
            }
            _ = store.observe(snapshots: snapshots)
        }
    }

    func testSingleObservationAndClockAdvanceDoesNotCountAsObservedCoverage() throws {
        let dir = try makeTempDir(prefix: "limit-hit-no-fake-coverage")
        let day0 = LogTimestampParser.parseISO8601("2026-10-01T12:00:00Z")!
        let clock = StepClock(day0)

        let store = LimitHitHistoryStore(directory: dir, clock: { clock.now() })

        // One Claude observation, zero ChatGPT observations.
        _ = store.observe(snapshots: [
            makeSnapshot(provider: .claude, limits: [
                UsageLimit(id: "claude-5h", name: "5-hour session", percentUsed: 50, resetText: "Resets", resetsAt: day0.addingTimeInterval(3600))
            ])
        ])

        // Advance clock 30 days with no further observations (reviewer Defect 4 probe).
        clock.set(day0.addingTimeInterval(30 * 86_400))

        XCTAssertEqual(store.coverageRatio(for: .claude, range: .sevenDays), 0.0, accuracy: 0.0001)
        XCTAssertEqual(store.coverageRatio(for: .claude, range: .thirtyDays), 0.0, accuracy: 0.0001)
        XCTAssertEqual(store.coverageRatio(for: .chatgpt, range: .thirtyDays), 0.0, accuracy: 0.0001)

        XCTAssertFalse(store.hasSufficientCoverage(for: .provider(.claude), connectedProviders: [.claude, .chatgpt], range: .thirtyDays))
        XCTAssertFalse(store.hasSufficientCoverage(for: .provider(.chatgpt), connectedProviders: [.claude, .chatgpt], range: .thirtyDays))
        XCTAssertFalse(store.hasSufficientCoverage(for: .overview, connectedProviders: [.claude, .chatgpt], range: .thirtyDays))

        let chatgptSummary = StatisticsAggregator.summarize(
            buckets: [],
            limitHits: store.limitHitEvents(calendar: utcCalendar),
            limitsHitAvailable: store.hasSufficientCoverage(for: .provider(.chatgpt), connectedProviders: [.claude, .chatgpt], range: .thirtyDays),
            range: .thirtyDays,
            filter: .provider(.chatgpt),
            anchorDate: clock.now(),
            calendar: utcCalendar
        )
        XCTAssertFalse(chatgptSummary.limitsHitAvailable)
        XCTAssertEqual(chatgptSummary.limitsHitDisplayText, "\u{2013}")
    }

    func testPerProviderIntervalCoverageThresholdGapsScopingPersistenceAndPruning() throws {
        let dir = try makeTempDir(prefix: "limit-hit-intervals")
        let day0 = LogTimestampParser.parseISO8601("2026-10-01T12:00:00Z")!
        let clock = StepClock(day0)

        let store = LimitHitHistoryStore(directory: dir, clock: { clock.now() })

        // 1. Verify 15-minute extension rule vs >15-minute new interval split.
        clock.set(day0)
        _ = store.observe(snapshots: [makeSnapshot(provider: .claude, limits: [])])
        clock.set(day0.addingTimeInterval(15 * 60)) // exactly 15 min -> extends interval
        _ = store.observe(snapshots: [makeSnapshot(provider: .claude, limits: [])])
        clock.set(day0.addingTimeInterval(31 * 60)) // 16 min gap -> starts new interval
        _ = store.observe(snapshots: [makeSnapshot(provider: .claude, limits: [])])
        clock.set(day0.addingTimeInterval(36 * 60)) // 5 min later -> extends 2nd interval
        _ = store.observe(snapshots: [makeSnapshot(provider: .claude, limits: [])])

        let splitIntervals = store.observedIntervals(for: .claude)
        XCTAssertEqual(splitIntervals.count, 2, "Gap > 15 minutes must start a new observed interval")
        XCTAssertEqual(splitIntervals[0], ObservationInterval(start: day0, end: day0.addingTimeInterval(15 * 60)))
        XCTAssertEqual(splitIntervals[1], ObservationInterval(start: day0.addingTimeInterval(31 * 60), end: day0.addingTimeInterval(36 * 60)))

        // 2. Build a fresh store to test exact 90% threshold, gaps, per-provider vs overview scoping, and 60d pruning.
        let dir2 = try makeTempDir(prefix: "limit-hit-90-percent")
        let store2 = LimitHitHistoryStore(directory: dir2, clock: { clock.now() })

        // Observe Claude continuously for 6 days (6/7 = 85.7% < 90%) -> unavailable for 7D.
        observeContinuously(
            store: store2,
            clock: clock,
            providers: [.claude],
            from: day0,
            to: day0.addingTimeInterval(6 * 86_400)
        )
        XCTAssertEqual(store2.coverageRatio(for: .claude, range: .sevenDays), 6.0 / 7.0, accuracy: 0.001)
        XCTAssertFalse(store2.hasSufficientCoverage(for: .provider(.claude), connectedProviders: [.claude], range: .sevenDays))

        // Record a Claude limit hit at Day 6 + 6h and keep observing Claude through Day 7 (100% of 7D).
        clock.set(day0.addingTimeInterval(6 * 86_400 + 5 * 60))
        _ = store2.observe(snapshots: [
            makeSnapshot(provider: .claude, limits: [
                UsageLimit(id: "claude-5h", name: "5-hour session", percentUsed: 100, resetText: "Resets", resetsAt: clock.now().addingTimeInterval(3600))
            ])
        ])
        observeContinuously(
            store: store2,
            clock: clock,
            providers: [.claude],
            from: day0.addingTimeInterval(6 * 86_400 + 10 * 60),
            to: day0.addingTimeInterval(7 * 86_400)
        )

        // At Day 7:
        // - Claude has 100% 7D coverage (>= 90%), 23.3% 30D coverage (< 90%).
        // - ChatGPT has 0% coverage.
        XCTAssertTrue(store2.hasSufficientCoverage(for: .provider(.claude), connectedProviders: [.claude, .chatgpt], range: .sevenDays))
        XCTAssertFalse(store2.hasSufficientCoverage(for: .provider(.claude), connectedProviders: [.claude, .chatgpt], range: .thirtyDays))
        XCTAssertFalse(store2.hasSufficientCoverage(for: .provider(.chatgpt), connectedProviders: [.claude, .chatgpt], range: .sevenDays))

        // Overview with connected = [claude, chatgpt] must stay unavailable because ChatGPT is unobserved.
        XCTAssertFalse(store2.hasSufficientCoverage(for: .overview, connectedProviders: [.claude, .chatgpt], range: .sevenDays))
        // Overview with connected = [claude] (only currently connected provider) IS available!
        XCTAssertTrue(store2.hasSufficientCoverage(for: .overview, connectedProviders: [.claude], range: .sevenDays))
        // Overview with zero connected providers must stay unavailable.
        XCTAssertFalse(store2.hasSufficientCoverage(for: .overview, connectedProviders: [], range: .sevenDays))

        let claude7Summary = StatisticsAggregator.summarize(
            buckets: [],
            limitHits: store2.limitHitEvents(calendar: utcCalendar),
            limitsHitAvailable: store2.hasSufficientCoverage(for: .provider(.claude), connectedProviders: [.claude, .chatgpt], range: .sevenDays),
            range: .sevenDays,
            filter: .provider(.claude),
            anchorDate: clock.now(),
            calendar: utcCalendar
        )
        XCTAssertTrue(claude7Summary.limitsHitAvailable)
        XCTAssertEqual(claude7Summary.limitsHit, 1)
        XCTAssertEqual(claude7Summary.limitsHitDisplayText, "1")

        // 3. Reload from disk: persisted intervals in the same JSON file restore exact coverage.
        let reloaded2 = LimitHitHistoryStore(directory: dir2, clock: { clock.now() })
        XCTAssertEqual(reloaded2.observedIntervals(for: .claude).count, 1)
        XCTAssertTrue(reloaded2.hasSufficientCoverage(for: .provider(.claude), connectedProviders: [.claude], range: .sevenDays))

        // 4. Test gap handling: 7-day window with a 20-hour gap (~88.1% < 90%) stays unavailable,
        //    whereas a 10-hour gap (~94.0% >= 90%) becomes numeric.
        let dir3 = try makeTempDir(prefix: "limit-hit-gaps")
        let store3 = LimitHitHistoryStore(directory: dir3, clock: { clock.now() })
        let gapBase = LogTimestampParser.parseISO8601("2026-10-10T00:00:00Z")!

        // Segment 1: [0h, 48h], Gap: 20h, Segment 2: [68h, 168h] => 148/168 = 88.1% < 90%
        observeContinuously(store: store3, clock: clock, providers: [.chatgpt], from: gapBase, to: gapBase.addingTimeInterval(48 * 3600))
        observeContinuously(store: store3, clock: clock, providers: [.chatgpt], from: gapBase.addingTimeInterval(68 * 3600), to: gapBase.addingTimeInterval(168 * 3600))
        XCTAssertEqual(store3.observedIntervals(for: .chatgpt).count, 2)
        XCTAssertEqual(store3.coverageRatio(for: .chatgpt, range: .sevenDays), 148.0 / 168.0, accuracy: 0.001)
        XCTAssertFalse(store3.hasSufficientCoverage(for: .provider(.chatgpt), connectedProviders: [.chatgpt], range: .sevenDays))

        // Segment 1: [0h, 48h], Gap: 10h, Segment 2: [58h, 168h] => 158/168 = 94.0% >= 90%
        observeContinuously(store: store3, clock: clock, providers: [.gemini], from: gapBase, to: gapBase.addingTimeInterval(48 * 3600))
        observeContinuously(store: store3, clock: clock, providers: [.gemini], from: gapBase.addingTimeInterval(58 * 3600), to: gapBase.addingTimeInterval(168 * 3600))
        XCTAssertEqual(store3.coverageRatio(for: .gemini, range: .sevenDays), 158.0 / 168.0, accuracy: 0.001)
        XCTAssertTrue(store3.hasSufficientCoverage(for: .provider(.gemini), connectedProviders: [.gemini], range: .sevenDays))

        // 5. 60-day pruning clamps straddling intervals and drops intervals older than 60 days.
        let day65 = day0.addingTimeInterval(65 * 86_400)
        clock.set(day65)
        // Observe on day 65 in store2: the Day 0..Day 7 interval is >58 days old, so [day0, day5] is pruned
        // leaving [day5, day7] plus the new [day65, day65] interval.
        _ = store2.observe(snapshots: [makeSnapshot(provider: .claude, limits: [])])
        let prunedIntervals = store2.observedIntervals(for: .claude)
        XCTAssertEqual(prunedIntervals.count, 2)
        let expectedCutoff = day65.addingTimeInterval(-60 * 86_400) // day5
        XCTAssertEqual(prunedIntervals[0].start, expectedCutoff)
        XCTAssertEqual(prunedIntervals[0].end, day0.addingTimeInterval(7 * 86_400))
        XCTAssertEqual(prunedIntervals[1], ObservationInterval(start: day65, end: day65))
        // Day 6 hit event (59 days old) is still retained; advance to Day 67 -> Day 6 event & Day 5..7 interval pruned!
        let day68 = day0.addingTimeInterval(68 * 86_400)
        clock.set(day68)
        _ = store2.observe(snapshots: [makeSnapshot(provider: .claude, limits: [])])
        XCTAssertTrue(store2.recordedEvents().isEmpty, "Events older than 60 days must be pruned")
        XCTAssertEqual(store2.observedIntervals(for: .claude).count, 2) // [day65, day65] and [day68, day68]; old Day 5..7 interval dropped

        // Verify persisted JSON survives reload with pruned intervals.
        let reloadedAfterPrune = LimitHitHistoryStore(directory: dir2, clock: { clock.now() })
        XCTAssertEqual(reloadedAfterPrune.observedIntervals(for: .claude).count, 2)
        XCTAssertTrue(reloadedAfterPrune.recordedEvents().isEmpty)
    }
}
