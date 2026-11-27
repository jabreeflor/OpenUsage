import os
import XCTest
@testable import OpenUsageCore

final class TokenFormatterTests: XCTestCase {
    func testFormatTokensMatchesStillsAndEdgeCases() {
        XCTAssertEqual(TokenFormatter.formatTokens(-5), "0")
        XCTAssertEqual(TokenFormatter.formatTokens(0), "0")
        XCTAssertEqual(TokenFormatter.formatTokens(412), "412")
        XCTAssertEqual(TokenFormatter.formatTokens(999), "999")
        XCTAssertEqual(TokenFormatter.formatTokens(1_000), "1K")
        XCTAssertEqual(TokenFormatter.formatTokens(127_000), "127K")
        XCTAssertEqual(TokenFormatter.formatTokens(229_000), "229K")
        XCTAssertEqual(TokenFormatter.formatTokens(271_000), "271K")
        XCTAssertEqual(TokenFormatter.formatTokens(395_000), "395K")
        XCTAssertEqual(TokenFormatter.formatTokens(800_000), "800K")
        XCTAssertEqual(TokenFormatter.formatTokens(999_600), "1.00M")
        XCTAssertEqual(TokenFormatter.formatTokens(1_000_000), "1.00M")
        XCTAssertEqual(TokenFormatter.formatTokens(1_840_000), "1.84M")
        XCTAssertEqual(TokenFormatter.formatTokens(9_995_000), "10.0M")
        XCTAssertEqual(TokenFormatter.formatTokens(42_340_000), "42.3M")
        XCTAssertEqual(TokenFormatter.formatTokens(1_250_000_000), "1.25B")
    }

    func testFormatCount() {
        XCTAssertEqual(TokenFormatter.formatCount(-10), "0")
        XCTAssertEqual(TokenFormatter.formatCount(0), "0")
        XCTAssertEqual(TokenFormatter.formatCount(412), "412")
        XCTAssertEqual(TokenFormatter.formatCount(1_500), "1,500")
        XCTAssertEqual(TokenFormatter.formatCount(1_234_567), "1,234,567")
    }

    func testUpdatedAgoText() {
        let now = DemoFixtures.referenceNow
        XCTAssertEqual(TokenFormatter.updatedAgoText(from: nil, now: now), "not updated yet")
        XCTAssertEqual(TokenFormatter.updatedAgoText(from: now, now: now), "updated just now")
        XCTAssertEqual(TokenFormatter.updatedAgoText(from: now.addingTimeInterval(-30), now: now), "updated just now")
        XCTAssertEqual(TokenFormatter.updatedAgoText(from: DemoFixtures.referenceDate, now: now), "updated 1 min ago")
        XCTAssertEqual(TokenFormatter.updatedAgoText(from: now.addingTimeInterval(-300), now: now), "updated 5 min ago")
        XCTAssertEqual(TokenFormatter.updatedAgoText(from: now.addingTimeInterval(-3600), now: now), "updated 1 hr ago")
        XCTAssertEqual(TokenFormatter.updatedAgoText(from: now.addingTimeInterval(-7200), now: now), "updated 2 hrs ago")
    }
}

final class RefreshPolicyTests: XCTestCase {
    func testIntervalsMatchSpec() {
        XCTAssertEqual(RefreshPolicy.openDropdownInterval, 60)
        XCTAssertEqual(RefreshPolicy.backgroundInterval, 300)
        XCTAssertEqual(RefreshPolicy.interval(isDropdownOpen: true), 60)
        XCTAssertEqual(RefreshPolicy.interval(isDropdownOpen: false), 300)
    }

    func testShouldRefreshAndNextRefreshDate() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        // Never refreshed yet -> refresh immediately
        XCTAssertTrue(RefreshPolicy.shouldRefresh(lastRefresh: nil, isDropdownOpen: true, now: t0))
        XCTAssertTrue(RefreshPolicy.shouldRefresh(lastRefresh: nil, isDropdownOpen: false, now: t0))
        XCTAssertEqual(RefreshPolicy.delayUntilNextRefresh(from: nil, isDropdownOpen: true, now: t0), 0)

        // Open dropdown: 59s -> wait 1s; 60s -> refresh now
        let t59 = t0.addingTimeInterval(59)
        let t60 = t0.addingTimeInterval(60)
        XCTAssertFalse(RefreshPolicy.shouldRefresh(lastRefresh: t0, isDropdownOpen: true, now: t59))
        XCTAssertEqual(RefreshPolicy.delayUntilNextRefresh(from: t0, isDropdownOpen: true, now: t59), 1, accuracy: 0.001)
        XCTAssertTrue(RefreshPolicy.shouldRefresh(lastRefresh: t0, isDropdownOpen: true, now: t60))
        XCTAssertEqual(RefreshPolicy.delayUntilNextRefresh(from: t0, isDropdownOpen: true, now: t60), 0, accuracy: 0.001)

        // Closed dropdown: 60s -> still 240s left; 300s -> refresh now
        let t300 = t0.addingTimeInterval(300)
        XCTAssertFalse(RefreshPolicy.shouldRefresh(lastRefresh: t0, isDropdownOpen: false, now: t60))
        XCTAssertEqual(RefreshPolicy.delayUntilNextRefresh(from: t0, isDropdownOpen: false, now: t60), 240, accuracy: 0.001)
        XCTAssertTrue(RefreshPolicy.shouldRefresh(lastRefresh: t0, isDropdownOpen: false, now: t300))
        XCTAssertEqual(RefreshPolicy.nextRefreshDate(from: t0, isDropdownOpen: false, now: t300), t300)
    }
}

@MainActor
final class RefreshSchedulerTests: XCTestCase {
    private final class ControlledClockAndSleeper: Sendable {
        private struct PendingSleep: Sendable {
            let id: Int
            let delay: TimeInterval
            let continuation: CheckedContinuation<Void, Error>
        }

        private struct SleepCountWaiter: Sendable {
            let id: UUID
            let targetCount: Int
            let continuation: CheckedContinuation<Void, Never>
        }

        private struct State: Sendable {
            var now: Date
            var requestedDelays: [TimeInterval] = []
            var nextID: Int = 0
            var registeredIDs: Set<Int> = []
            var cancelledIDs: Set<Int> = []
            var pendingSleeps: [PendingSleep] = []
            var sleepCountWaiters: [SleepCountWaiter] = []
            var cancelledWaiterIDs: Set<UUID> = []
        }

        private let state: OSAllocatedUnfairLock<State>

        init(start: Date) {
            self.state = OSAllocatedUnfairLock(initialState: State(now: start))
        }

        var now: Date {
            get { state.withLock { $0.now } }
            set { state.withLock { $0.now = newValue } }
        }

        var requestedDelays: [TimeInterval] {
            state.withLock { $0.requestedDelays }
        }

        var pendingSleepCount: Int {
            state.withLock { $0.pendingSleeps.count }
        }

        func sleep(_ delay: TimeInterval) async throws {
            let sleepID = state.withLock { s -> Int in
                let id = s.nextID
                s.nextID += 1
                return id
            }

            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let (shouldCancelImmediately, waitersToResume) = self.state.withLock { s -> (Bool, [CheckedContinuation<Void, Never>]) in
                        s.registeredIDs.insert(sleepID)
                        if Task.isCancelled || s.cancelledIDs.remove(sleepID) != nil {
                            return (true, [])
                        }
                        // Atomically record both the requested delay and its continuation so any observer
                        // seeing the sleep count is guaranteed the continuation is ready to resume.
                        s.requestedDelays.append(delay)
                        s.pendingSleeps.append(PendingSleep(id: sleepID, delay: delay, continuation: continuation))
                        let count = s.requestedDelays.count
                        var ready: [CheckedContinuation<Void, Never>] = []
                        s.sleepCountWaiters.removeAll { waiter in
                            if count >= waiter.targetCount {
                                ready.append(waiter.continuation)
                                return true
                            }
                            return false
                        }
                        return (false, ready)
                    }

                    if shouldCancelImmediately {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        for waiter in waitersToResume {
                            waiter.resume()
                        }
                    }
                }
            } onCancel: {
                self.cancelSleep(id: sleepID)
            }
        }

        func waitUntilSleepCount(_ count: Int, timeoutNanoseconds: UInt64 = 2_000_000_000) async {
            if state.withLock({ $0.requestedDelays.count >= count }) {
                return
            }

            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    let waiterID = UUID()
                    await withTaskCancellationHandler {
                        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                            let resumeNow = self.state.withLock { s -> Bool in
                                if s.requestedDelays.count >= count
                                    || Task.isCancelled
                                    || s.cancelledWaiterIDs.remove(waiterID) != nil
                                {
                                    return true
                                }
                                s.sleepCountWaiters.append(
                                    SleepCountWaiter(id: waiterID, targetCount: count, continuation: continuation)
                                )
                                return false
                            }
                            if resumeNow {
                                continuation.resume()
                            }
                        }
                    } onCancel: {
                        let continuation = self.state.withLock { s -> CheckedContinuation<Void, Never>? in
                            if let index = s.sleepCountWaiters.firstIndex(where: { $0.id == waiterID }) {
                                return s.sleepCountWaiters.remove(at: index).continuation
                            }
                            s.cancelledWaiterIDs.insert(waiterID)
                            return nil
                        }
                        continuation?.resume()
                    }
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                }
                _ = await group.next()
                group.cancelAll()
            }
        }

        @discardableResult
        func completeLatestSleepAdvancingClock() -> Bool {
            let next = state.withLock { s -> PendingSleep? in
                guard !s.pendingSleeps.isEmpty else { return nil }
                let entry = s.pendingSleeps.removeLast()
                s.now = s.now.addingTimeInterval(entry.delay)
                return entry
            }
            guard let next else { return false }
            next.continuation.resume()
            return true
        }

        func cancelSleep(id: Int) {
            let entry = state.withLock { s -> PendingSleep? in
                if let index = s.pendingSleeps.firstIndex(where: { $0.id == id }) {
                    return s.pendingSleeps.remove(at: index)
                }
                if !s.registeredIDs.contains(id) {
                    s.cancelledIDs.insert(id)
                }
                return nil
            }
            entry?.continuation.resume(throwing: CancellationError())
        }

        func cancelAllPending() {
            let (toCancel, waiters) = state.withLock { s -> ([PendingSleep], [CheckedContinuation<Void, Never>]) in
                let entries = s.pendingSleeps
                s.pendingSleeps.removeAll()
                let pendingWaiters = s.sleepCountWaiters.map(\.continuation)
                s.sleepCountWaiters.removeAll()
                return (entries, pendingWaiters)
            }
            for entry in toCancel {
                entry.continuation.resume(throwing: CancellationError())
            }
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    private final class AsyncGate: Sendable {
        private struct State: Sendable {
            var isOpen: Bool = false
            var enteredCount: Int = 0
            var holdContinuations: [CheckedContinuation<Void, Never>] = []
            var enterWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let (resumeImmediately, enterWaiters) = state.withLock { s -> (Bool, [CheckedContinuation<Void, Never>]) in
                    s.enteredCount += 1
                    let count = s.enteredCount
                    var ready: [CheckedContinuation<Void, Never>] = []
                    s.enterWaiters.removeAll { waiter in
                        if count >= waiter.target {
                            ready.append(waiter.continuation)
                            return true
                        }
                        return false
                    }
                    if s.isOpen {
                        return (true, ready)
                    }
                    s.holdContinuations.append(continuation)
                    return (false, ready)
                }

                for waiter in enterWaiters {
                    waiter.resume()
                }
                if resumeImmediately {
                    continuation.resume()
                }
            }
        }

        func waitUntilEntered(count: Int = 1) async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let alreadyEntered = state.withLock { s -> Bool in
                    if s.enteredCount >= count {
                        return true
                    }
                    s.enterWaiters.append((target: count, continuation: continuation))
                    return false
                }
                if alreadyEntered {
                    continuation.resume()
                }
            }
        }

        func open() {
            let continuations = state.withLock { s -> [CheckedContinuation<Void, Never>] in
                s.isOpen = true
                let pending = s.holdContinuations
                s.holdContinuations.removeAll()
                return pending
            }
            for continuation in continuations {
                continuation.resume()
            }
        }
    }

    func testOpeningAt59SecondsWaitsOneSecondThenFetchesAt60Seconds() async {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let harness = ControlledClockAndSleeper(start: t0)
        var refreshTimestamps: [Date] = []

        let scheduler = RefreshScheduler(
            lastRefreshDate: t0,
            isDropdownOpen: false,
            clock: { harness.now },
            sleeper: { delay in try await harness.sleep(delay) },
            onRefresh: {
                refreshTimestamps.append(harness.now)
            }
        )
        defer {
            scheduler.stop()
            harness.cancelAllPending()
        }

        scheduler.start()
        await harness.waitUntilSleepCount(1)
        XCTAssertEqual(harness.requestedDelays.last ?? -1, 300, accuracy: 0.001)
        XCTAssertTrue(refreshTimestamps.isEmpty)

        // Advance to 59 seconds after last refresh and open dropdown:
        // must skip immediate fetch and schedule exactly 1 second remaining.
        harness.now = t0.addingTimeInterval(59)
        scheduler.setDropdownOpen(true)
        await harness.waitUntilSleepCount(2)
        XCTAssertTrue(refreshTimestamps.isEmpty, "Opening at 59s must not fetch immediately")
        XCTAssertEqual(harness.requestedDelays.last ?? -1, 1, accuracy: 0.001)

        // Completing that 1s sleep fetches at t0 + 60s and then sleeps 60s.
        XCTAssertTrue(harness.completeLatestSleepAdvancingClock())
        await harness.waitUntilSleepCount(3)
        XCTAssertEqual(refreshTimestamps.count, 1)
        XCTAssertEqual(refreshTimestamps[0].timeIntervalSince(t0), 60, accuracy: 0.001)
        XCTAssertEqual(harness.requestedDelays.last ?? -1, 60, accuracy: 0.001)
    }

    func testRepeatedTogglesNeverPostponeRefreshPastDeadline() async {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let harness = ControlledClockAndSleeper(start: t0)
        var refreshTimestamps: [Date] = []

        let scheduler = RefreshScheduler(
            lastRefreshDate: t0,
            isDropdownOpen: false,
            clock: { harness.now },
            sleeper: { delay in try await harness.sleep(delay) },
            onRefresh: {
                refreshTimestamps.append(harness.now)
            }
        )
        defer {
            scheduler.stop()
            harness.cancelAllPending()
        }

        scheduler.start()
        await harness.waitUntilSleepCount(1)
        XCTAssertEqual(harness.requestedDelays[0], 300, accuracy: 0.001)

        // Open at 20s -> 40s left until 60s
        harness.now = t0.addingTimeInterval(20)
        scheduler.setDropdownOpen(true)
        await harness.waitUntilSleepCount(2)
        XCTAssertEqual(harness.requestedDelays[1], 40, accuracy: 0.001)

        // Close at 35s -> 265s left until 300s (not reset to 300s)
        harness.now = t0.addingTimeInterval(35)
        scheduler.setDropdownOpen(false)
        await harness.waitUntilSleepCount(3)
        XCTAssertEqual(harness.requestedDelays[2], 265, accuracy: 0.001)

        // Open again at 59s -> 1s left until 60s
        harness.now = t0.addingTimeInterval(59)
        scheduler.setDropdownOpen(true)
        await harness.waitUntilSleepCount(4)
        XCTAssertEqual(harness.requestedDelays[3], 1, accuracy: 0.001)
        XCTAssertTrue(refreshTimestamps.isEmpty)

        // Advance 1s -> fetches right at 60s
        XCTAssertTrue(harness.completeLatestSleepAdvancingClock())
        await harness.waitUntilSleepCount(5)
        XCTAssertEqual(refreshTimestamps.count, 1)
        XCTAssertEqual(refreshTimestamps[0].timeIntervalSince(t0), 60, accuracy: 0.001)
    }

    func testOpeningPastOpenDeadlineRefreshesImmediatelyThenSchedules60Seconds() async {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let harness = ControlledClockAndSleeper(start: t0)
        var refreshTimestamps: [Date] = []

        let scheduler = RefreshScheduler(
            lastRefreshDate: t0,
            isDropdownOpen: false,
            clock: { harness.now },
            sleeper: { delay in try await harness.sleep(delay) },
            onRefresh: {
                refreshTimestamps.append(harness.now)
            }
        )
        defer {
            scheduler.stop()
            harness.cancelAllPending()
        }

        scheduler.start()
        await harness.waitUntilSleepCount(1)

        // 75s after last refresh -> past 60s open interval -> fetch immediately, then wait 60s
        harness.now = t0.addingTimeInterval(75)
        scheduler.setDropdownOpen(true)
        await harness.waitUntilSleepCount(2)
        XCTAssertEqual(refreshTimestamps.count, 1)
        XCTAssertEqual(refreshTimestamps[0].timeIntervalSince(t0), 75, accuracy: 0.001)
        XCTAssertEqual(harness.requestedDelays.last ?? -1, 60, accuracy: 0.001)
    }

    func testTogglingVisibilityWhileRefreshInFlightKeepsSingleFetchAndSchedulesFromCompletion() async {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let harness = ControlledClockAndSleeper(start: t0)
        let gate = AsyncGate()

        var startedCount = 0
        var inFlightCount = 0
        var maxConcurrent = 0

        let scheduler = RefreshScheduler(
            lastRefreshDate: t0,
            isDropdownOpen: false,
            clock: { harness.now },
            sleeper: { delay in try await harness.sleep(delay) },
            onRefresh: {
                startedCount += 1
                inFlightCount += 1
                maxConcurrent = max(maxConcurrent, inFlightCount)
                await gate.wait()
                inFlightCount -= 1
            }
        )
        defer {
            gate.open()
            scheduler.stop()
            harness.cancelAllPending()
        }

        scheduler.start()
        await harness.waitUntilSleepCount(1)
        XCTAssertEqual(harness.requestedDelays, [300])

        // Trigger the background refresh at t0 + 300s and hold it open.
        XCTAssertTrue(harness.completeLatestSleepAdvancingClock())
        await gate.waitUntilEntered(count: 1)
        XCTAssertEqual(startedCount, 1)
        XCTAssertEqual(inFlightCount, 1)
        XCTAssertTrue(scheduler.isRefreshing)

        // Toggle visibility repeatedly while the first refresh is suspended.
        harness.now = t0.addingTimeInterval(301)
        scheduler.setDropdownOpen(true)
        await Task.yield()

        harness.now = t0.addingTimeInterval(302)
        scheduler.setDropdownOpen(false)
        await Task.yield()

        harness.now = t0.addingTimeInterval(303)
        scheduler.setDropdownOpen(true)
        for _ in 0..<10 {
            await Task.yield()
        }

        XCTAssertEqual(startedCount, 1, "Visibility toggles must not start a second concurrent refresh")
        XCTAssertEqual(inFlightCount, 1)
        XCTAssertEqual(maxConcurrent, 1)
        XCTAssertEqual(harness.requestedDelays.count, 1, "No new sleep should be scheduled until the in-flight refresh finishes")

        // Complete the held refresh at t0 + 305s; next sleep must use the current open interval (60s) from completion.
        harness.now = t0.addingTimeInterval(305)
        gate.open()
        await harness.waitUntilSleepCount(2)

        XCTAssertEqual(startedCount, 1)
        XCTAssertEqual(inFlightCount, 0)
        XCTAssertEqual(maxConcurrent, 1)
        XCTAssertFalse(scheduler.isRefreshing)
        XCTAssertEqual(scheduler.lastRefreshDate?.timeIntervalSince(t0) ?? -1, 305, accuracy: 0.001)
        XCTAssertEqual(harness.requestedDelays.last ?? -1, 60, accuracy: 0.001)
    }

    func testClosingDropdownWhileImmediateRefreshInFlightSchedulesBackgroundIntervalFromCompletion() async {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let harness = ControlledClockAndSleeper(start: t0)
        let gate = AsyncGate()

        var startedCount = 0
        var maxConcurrent = 0
        var inFlightCount = 0

        let scheduler = RefreshScheduler(
            lastRefreshDate: nil,
            isDropdownOpen: true,
            clock: { harness.now },
            sleeper: { delay in try await harness.sleep(delay) },
            onRefresh: {
                startedCount += 1
                inFlightCount += 1
                maxConcurrent = max(maxConcurrent, inFlightCount)
                await gate.wait()
                inFlightCount -= 1
            }
        )
        defer {
            gate.open()
            scheduler.stop()
            harness.cancelAllPending()
        }

        scheduler.start()
        await gate.waitUntilEntered(count: 1)
        XCTAssertEqual(startedCount, 1)

        // Close dropdown while the initial refresh is still in flight.
        harness.now = t0.addingTimeInterval(2)
        scheduler.setDropdownOpen(false)
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(startedCount, 1)
        XCTAssertEqual(maxConcurrent, 1)
        XCTAssertTrue(harness.requestedDelays.isEmpty)

        // Release at t0 + 4s -> must schedule 300s (background interval) from t0 + 4s.
        harness.now = t0.addingTimeInterval(4)
        gate.open()
        await harness.waitUntilSleepCount(1)

        XCTAssertEqual(startedCount, 1)
        XCTAssertEqual(maxConcurrent, 1)
        XCTAssertEqual(scheduler.lastRefreshDate?.timeIntervalSince(t0) ?? -1, 4, accuracy: 0.001)
        XCTAssertEqual(harness.requestedDelays.last ?? -1, 300, accuracy: 0.001)
    }
}

final class DemoTodayUsageTests: XCTestCase {
    func testTodayTotalsAndSparklineMatchStills() {
        let today = DemoFixtures.todayUsage()
        XCTAssertEqual(today.totalTokens, 1_840_000)
        XCTAssertEqual(TokenFormatter.formatTokens(today.totalTokens), "1.84M")
        XCTAssertEqual(today.totalRequests, 412)
        XCTAssertEqual(today.hourlySparkline, [2, 1, 0, 0, 1, 3, 6, 8, 7, 9, 10, 6])
        XCTAssertEqual(today.hourlySparkline.count, 12)

        let summedRequests = ProviderID.allCases.reduce(0) { $0 + today.usage(for: $1).requests }
        XCTAssertEqual(summedRequests, 412)
    }

    func testPerProviderModelsTodayMatchStills() {
        let today = DemoFixtures.todayUsage()

        // Still 01: Claude
        let claude = today.usage(for: .claude)
        XCTAssertEqual(TokenFormatter.formatTokens(claude.totalTokens), "800K")
        XCTAssertEqual(claude.models.map(\.model), ["claude-opus-4.5", "claude-sonnet-4.5", "claude-haiku-4.5"])
        XCTAssertEqual(claude.models.map(\.sharePercent), [71, 24, 5])

        // ChatGPT
        let chatgpt = today.usage(for: .chatgpt)
        XCTAssertEqual(TokenFormatter.formatTokens(chatgpt.totalTokens), "395K")
        XCTAssertEqual(chatgpt.models.map(\.model), ["gpt-5-codex", "gpt-5"])
        XCTAssertEqual(chatgpt.models.map(\.sharePercent), [82, 18])

        // Still 02: Cursor
        let cursor = today.usage(for: .cursor)
        XCTAssertEqual(TokenFormatter.formatTokens(cursor.totalTokens), "271K")
        XCTAssertEqual(cursor.models.map(\.model), ["composer-1", "claude-sonnet-4.5", "gpt-5"])
        XCTAssertEqual(cursor.models.map(\.sharePercent), [58, 29, 13])

        // Gemini
        let gemini = today.usage(for: .gemini)
        XCTAssertEqual(TokenFormatter.formatTokens(gemini.totalTokens), "229K")
        XCTAssertEqual(gemini.models.map(\.model), ["gemini-3-pro", "gemini-2.5-flash"])
        XCTAssertEqual(gemini.models.map(\.sharePercent), [66, 34])

        // OpenCode
        let opencode = today.usage(for: .opencode)
        XCTAssertEqual(TokenFormatter.formatTokens(opencode.totalTokens), "127K")
        XCTAssertEqual(opencode.models.map(\.model), ["kimi-k2", "glm-4.6", "qwen3-coder"])
        XCTAssertEqual(opencode.models.map(\.sharePercent), [52, 31, 17])

        // Every provider's model shares sum to 100%
        for id in ProviderID.allCases {
            let sum = today.usage(for: id).models.reduce(0) { $0 + $1.sharePercent }
            XCTAssertEqual(sum, 100, "Model shares for \(id.rawValue) should sum to 100")
        }
    }
}
