import Foundation

/// Schedules periodic usage refreshes according to `RefreshPolicy` without postponing deadlines
/// when the dropdown opens or closes.
@MainActor
public final class RefreshScheduler {
    public typealias Clock = @Sendable () -> Date
    public typealias Sleeper = @Sendable (TimeInterval) async throws -> Void
    public typealias RefreshAction = @MainActor () async -> Void

    private let clock: Clock
    private let sleeper: Sleeper
    private let refreshAction: RefreshAction

    public private(set) var isDropdownOpen: Bool
    public private(set) var lastRefreshDate: Date?
    public private(set) var isRunning: Bool = false
    public var isRefreshing: Bool { refreshTask != nil }

    private var sleepTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var scheduleGeneration: UInt64 = 0
    private var refreshGeneration: UInt64 = 0

    public init(
        lastRefreshDate: Date? = nil,
        isDropdownOpen: Bool = false,
        clock: @escaping Clock = { Date() },
        sleeper: @escaping Sleeper = RefreshScheduler.defaultSleep,
        onRefresh: @escaping RefreshAction
    ) {
        self.lastRefreshDate = lastRefreshDate
        self.isDropdownOpen = isDropdownOpen
        self.clock = clock
        self.sleeper = sleeper
        self.refreshAction = onRefresh
    }

    public static func defaultSleep(_ delay: TimeInterval) async throws {
        guard delay > 0 else { return }
        let clampedSeconds = min(delay, Double(UInt64.max / 1_000_000_000))
        let nanos = max(UInt64(1_000_000), UInt64(ceil(clampedSeconds * 1_000_000_000)))
        try await Task.sleep(nanoseconds: nanos)
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        reschedule()
    }

    public func stop() {
        isRunning = false
        scheduleGeneration &+= 1
        sleepTask?.cancel()
        sleepTask = nil
        refreshTask?.cancel()
    }

    public func setDropdownOpen(_ isOpen: Bool) {
        guard isDropdownOpen != isOpen else { return }
        isDropdownOpen = isOpen
        if isRunning {
            reschedule()
        }
    }

    public func recordRefresh(at date: Date? = nil) {
        lastRefreshDate = date ?? clock()
    }

    public func reschedule() {
        scheduleGeneration &+= 1
        sleepTask?.cancel()
        sleepTask = nil

        guard isRunning else {
            return
        }
        // Keep a single refresh in flight across visibility changes; when it finishes,
        // it schedules the next sleep from its completion using the current interval.
        guard refreshTask == nil else {
            return
        }

        let now = clock()
        let initialDelay = RefreshPolicy.delayUntilNextRefresh(
            from: lastRefreshDate,
            isDropdownOpen: isDropdownOpen,
            now: now
        )
        if initialDelay <= 0 {
            beginRefresh()
            return
        }

        let generation = scheduleGeneration
        sleepTask = Task { [weak self] in
            guard let self else { return }
            var delay = initialDelay

            while !Task.isCancelled, self.isRunning, self.scheduleGeneration == generation {
                do {
                    try await self.sleeper(delay)
                } catch {
                    break
                }

                guard !Task.isCancelled, self.isRunning, self.scheduleGeneration == generation else {
                    break
                }

                let afterWake = self.clock()
                let remaining = RefreshPolicy.delayUntilNextRefresh(
                    from: self.lastRefreshDate,
                    isDropdownOpen: self.isDropdownOpen,
                    now: afterWake
                )
                if remaining > 0 {
                    delay = remaining
                    continue
                }

                self.sleepTask = nil
                self.beginRefresh()
                return
            }

            if self.scheduleGeneration == generation {
                self.sleepTask = nil
            }
        }
    }

    private func beginRefresh() {
        guard isRunning, refreshTask == nil else { return }
        refreshGeneration &+= 1
        let token = refreshGeneration

        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshAction()

            if self.refreshGeneration == token {
                self.refreshTask = nil
            }

            if !Task.isCancelled {
                let completedAt = self.clock()
                if let current = self.lastRefreshDate {
                    self.lastRefreshDate = max(current, completedAt)
                } else {
                    self.lastRefreshDate = completedAt
                }
            }

            if self.isRunning {
                self.reschedule()
            }
        }
    }
}
