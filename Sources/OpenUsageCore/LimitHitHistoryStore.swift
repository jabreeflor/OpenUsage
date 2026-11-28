import Foundation

/// A single observed limit-hit transition (`percentUsed >= 100` when the previous observation
/// in the same provider + limit + reset window was below 100% or unknown).
/// Contains no credentials, emails, or account identifiers.
public struct RecordedLimitHit: Codable, Sendable, Equatable, Hashable {
    public let provider: ProviderID
    public let limitID: String
    public let timestamp: Date

    public init(provider: ProviderID, limitID: String, timestamp: Date) {
        self.provider = provider
        self.limitID = limitID
        self.timestamp = timestamp
    }
}

/// Persisted last-seen utilization for one `(provider, limitID)` so restarts do not double-count
/// an ongoing 100% limit within the same reset window.
public struct LimitObservationState: Codable, Sendable, Equatable, Hashable {
    public let percentUsed: Int
    public let resetsAt: Date?

    public init(percentUsed: Int, resetsAt: Date?) {
        self.percentUsed = min(100, max(0, percentUsed))
        self.resetsAt = resetsAt
    }
}

/// Continuous time interval during which a provider was actively observed (observations arriving
/// within 15 minutes of the previous one extend the interval; larger gaps start a new interval).
public struct ObservationInterval: Codable, Sendable, Equatable, Hashable {
    public var start: Date
    public var end: Date

    public init(start: Date, end: Date) {
        self.start = min(start, end)
        self.end = max(start, end)
    }
}

/// Small privacy-safe JSON document persisted under `~/Library/Application Support/OpenUsage/`.
public struct LimitHitHistoryDocument: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var firstObservedAt: Date?
    public var events: [RecordedLimitHit]
    public var lastStates: [String: LimitObservationState]
    /// Per-provider observed time intervals keyed by `ProviderID.rawValue`, pruned to 60 days.
    public var observedIntervalsByProvider: [String: [ObservationInterval]]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case firstObservedAt
        case events
        case lastStates
        case observedIntervalsByProvider
    }

    public init(
        schemaVersion: Int = currentSchemaVersion,
        firstObservedAt: Date? = nil,
        events: [RecordedLimitHit] = [],
        lastStates: [String: LimitObservationState] = [:],
        observedIntervalsByProvider: [String: [ObservationInterval]] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.firstObservedAt = firstObservedAt
        self.events = events
        self.lastStates = lastStates
        self.observedIntervalsByProvider = observedIntervalsByProvider
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        self.firstObservedAt = try container.decodeIfPresent(Date.self, forKey: .firstObservedAt)
        self.events = try container.decodeIfPresent([RecordedLimitHit].self, forKey: .events) ?? []
        self.lastStates = try container.decodeIfPresent([String: LimitObservationState].self, forKey: .lastStates) ?? [:]
        self.observedIntervalsByProvider = try container.decodeIfPresent([String: [ObservationInterval]].self, forKey: .observedIntervalsByProvider) ?? [:]
    }
}

/// Records live limit-hit events locally and tracks per-provider observation intervals for the
/// Statistics "Limits hit" KPI. Never read or written in demo mode.
public final class LimitHitHistoryStore: @unchecked Sendable {
    public static let retentionDays: Int = 60
    public static let retentionSeconds: TimeInterval = TimeInterval(retentionDays * 86_400)
    /// Maximum gap between consecutive observations for the same provider that still extends
    /// the active observation interval (refresh cadence is 5 minutes; 15 minutes allows 2 missed refreshes).
    public static let maxObservationGapSeconds: TimeInterval = 15 * 60
    public static let minimumCoverageRatio: Double = StatisticsLimitHitPolicy.minimumCoverageRatio
    public static let defaultFileName = "limit-hit-history-v1.json"
    private static let resetWindowJitterTolerance: TimeInterval = 60.0

    public let fileURL: URL
    private let clock: @Sendable () -> Date
    private let lock = NSLock()
    private var document: LimitHitHistoryDocument?

    public static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport.appendingPathComponent("OpenUsage", isDirectory: true)
    }

    public static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        defaultDirectory(fileManager: fileManager)
            .appendingPathComponent(defaultFileName, isDirectory: false)
    }

    public init(
        fileURL: URL = LimitHitHistoryStore.defaultFileURL(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileURL = fileURL
        self.clock = clock
    }

    public convenience init(
        directory: URL,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            fileURL: directory.appendingPathComponent(Self.defaultFileName, isDirectory: false),
            clock: clock
        )
    }

    /// Loads persisted history from disk (if not already loaded) and prunes events and intervals older than 60 days.
    @discardableResult
    public func loadIfNeeded(at now: Date? = nil) -> LimitHitHistoryDocument {
        let effectiveNow = now ?? clock()
        lock.lock()
        defer { lock.unlock() }
        return ensureLoadedLocked(now: effectiveNow)
    }

    /// Records a live refresh observation across all provider snapshots.
    /// - Sets `firstObservedAt` on the first live observation with a connected provider.
    /// - Extends or starts each connected provider's observed interval (extending when arriving within 15 min
    ///   of the previous observation for that provider, otherwise starting a new interval).
    /// - Appends one `{provider, limitID, timestamp}` event whenever a connected limit is `>= 100%`
    ///   and the previous observation of the same `(provider, limitID, reset window)` was `< 100%` or unknown.
    /// - Prunes events and intervals older than 60 days and persists atomically to disk.
    @discardableResult
    public func observe(
        snapshots: [ProviderSnapshot],
        at now: Date? = nil
    ) -> [RecordedLimitHit] {
        let effectiveNow = now ?? clock()
        lock.lock()
        var doc = ensureLoadedLocked(now: effectiveNow)
        var newEvents: [RecordedLimitHit] = []
        var mutated = pruneHistoryLocked(&doc, now: effectiveNow)

        let connectedSnapshots = snapshots.filter { $0.connectionState == .connected }
        if !connectedSnapshots.isEmpty {
            if doc.firstObservedAt == nil {
                doc.firstObservedAt = effectiveNow
                mutated = true
            }

            var recordedProviders: Set<ProviderID> = []
            for snapshot in connectedSnapshots {
                if recordedProviders.insert(snapshot.provider).inserted {
                    if recordObservationLocked(for: snapshot.provider, at: effectiveNow, in: &doc) {
                        mutated = true
                    }
                }

                for limit in snapshot.limits {
                    let stateKey = "\(snapshot.provider.rawValue)#\(limit.id)"
                    let previous = doc.lastStates[stateKey]
                    let sameWindow = Self.isSameResetWindow(previous: previous?.resetsAt, current: limit.resetsAt)
                    let previousPercentInWindow: Int? = sameWindow ? previous?.percentUsed : nil

                    if limit.percentUsed >= 100,
                       (previousPercentInWindow == nil || previousPercentInWindow! < 100) {
                        let event = RecordedLimitHit(
                            provider: snapshot.provider,
                            limitID: limit.id,
                            timestamp: effectiveNow
                        )
                        doc.events.append(event)
                        newEvents.append(event)
                        mutated = true
                    }

                    let nextState = LimitObservationState(
                        percentUsed: limit.percentUsed,
                        resetsAt: limit.resetsAt
                    )
                    if doc.lastStates[stateKey] != nextState {
                        doc.lastStates[stateKey] = nextState
                        mutated = true
                    }
                }
            }
        }

        if pruneHistoryLocked(&doc, now: effectiveNow) {
            mutated = true
        }

        document = doc
        let snapshotToSave: LimitHitHistoryDocument? = mutated ? doc : nil
        lock.unlock()

        if let snapshotToSave {
            persist(snapshotToSave)
        }
        return newEvents
    }

    /// Returns the persisted observed intervals for `provider` (pruned to 60 days relative to `now`).
    public func observedIntervals(for provider: ProviderID, at now: Date? = nil) -> [ObservationInterval] {
        let effectiveNow = now ?? clock()
        lock.lock()
        var doc = ensureLoadedLocked(now: effectiveNow)
        _ = pruneHistoryLocked(&doc, now: effectiveNow)
        document = doc
        let intervals = doc.observedIntervalsByProvider[provider.rawValue] ?? []
        lock.unlock()
        return intervals
    }

    /// Total observed duration (in seconds) for `provider` within `[now - range.dayCount * 86_400, now]`.
    public func observedSeconds(
        for provider: ProviderID,
        range: StatisticsRange,
        at now: Date? = nil
    ) -> TimeInterval {
        let effectiveNow = now ?? clock()
        let intervals = observedIntervals(for: provider, at: effectiveNow)
        let windowDuration = TimeInterval(range.dayCount) * 86_400.0
        let windowStart = effectiveNow.addingTimeInterval(-windowDuration)
        return Self.coveredSeconds(intervals: intervals, windowStart: windowStart, windowEnd: effectiveNow)
    }

    /// Fraction (`0.0 ... 1.0`) of the selected `range` ending at `now` covered by `provider`'s observed intervals.
    public func coverageRatio(
        for provider: ProviderID,
        range: StatisticsRange,
        at now: Date? = nil
    ) -> Double {
        let effectiveNow = now ?? clock()
        let windowDuration = TimeInterval(range.dayCount) * 86_400.0
        guard windowDuration > 0 else { return 0 }
        let covered = observedSeconds(for: provider, range: range, at: effectiveNow)
        return min(1.0, max(0.0, covered / windowDuration))
    }

    /// Returns `true` only when every provider in the scope (`[provider]` for `.provider(provider)`,
    /// or `connectedProviders` for `.overview`, requiring at least one provider) has observed intervals
    /// covering at least 90% of `range` ending at `now`.
    public func hasSufficientCoverage(
        for filter: StatisticsFilter,
        connectedProviders: [ProviderID],
        range: StatisticsRange,
        at now: Date? = nil
    ) -> Bool {
        let effectiveNow = now ?? clock()
        return StatisticsLimitHitPolicy.isAvailable(
            isDemo: false,
            filter: filter,
            connectedProviders: connectedProviders,
            range: range,
            coverageRatioForProvider: { provider in
                self.coverageRatio(for: provider, range: range, at: effectiveNow)
            }
        )
    }

    public func firstObservedAt(at now: Date? = nil) -> Date? {
        let effectiveNow = now ?? clock()
        lock.lock()
        let doc = ensureLoadedLocked(now: effectiveNow)
        lock.unlock()
        return doc.firstObservedAt
    }

    public func recordedEvents(at now: Date? = nil) -> [RecordedLimitHit] {
        let effectiveNow = now ?? clock()
        lock.lock()
        var doc = ensureLoadedLocked(now: effectiveNow)
        _ = pruneHistoryLocked(&doc, now: effectiveNow)
        document = doc
        lock.unlock()
        return doc.events
    }

    /// Converts persisted `RecordedLimitHit` events into `LimitHitEvent` records bucketed in `calendar`.
    public func limitHitEvents(
        at now: Date? = nil,
        calendar: Calendar = StatisticsAggregator.gregorianCalendar()
    ) -> [LimitHitEvent] {
        recordedEvents(at: now).enumerated().map { index, event in
            let dayKey = StatisticsAggregator.dayKey(for: event.timestamp, calendar: calendar)
            let millis = Int64((event.timestamp.timeIntervalSince1970 * 1_000.0).rounded())
            return LimitHitEvent(
                id: "\(event.provider.rawValue)#\(event.limitID)#\(millis)#\(index)",
                dayKey: dayKey,
                provider: event.provider,
                limitName: event.limitID
            )
        }
    }

    // MARK: - Private

    private static func isSameResetWindow(previous: Date?, current: Date?) -> Bool {
        switch (previous, current) {
        case let (p?, c?):
            return abs(c.timeIntervalSince(p)) <= resetWindowJitterTolerance
        case (nil, nil):
            return true
        default:
            return false
        }
    }

    private func recordObservationLocked(
        for provider: ProviderID,
        at timestamp: Date,
        in doc: inout LimitHitHistoryDocument
    ) -> Bool {
        let key = provider.rawValue
        var intervals = doc.observedIntervalsByProvider[key] ?? []
        let before = intervals

        if var last = intervals.last, timestamp >= last.end {
            if timestamp.timeIntervalSince(last.end) <= Self.maxObservationGapSeconds {
                if timestamp > last.end {
                    last.end = timestamp
                    intervals[intervals.count - 1] = last
                }
            } else {
                intervals.append(ObservationInterval(start: timestamp, end: timestamp))
            }
        } else {
            intervals.append(ObservationInterval(start: timestamp, end: timestamp))
            intervals = Self.coalesceIntervals(intervals)
        }

        doc.observedIntervalsByProvider[key] = intervals
        return intervals != before
    }

    private static func coalesceIntervals(_ intervals: [ObservationInterval]) -> [ObservationInterval] {
        guard !intervals.isEmpty else { return [] }
        let sorted = intervals
            .map { ObservationInterval(start: $0.start, end: $0.end) }
            .sorted { lhs, rhs in
                if lhs.start != rhs.start { return lhs.start < rhs.start }
                return lhs.end < rhs.end
            }
        var merged: [ObservationInterval] = [sorted[0]]
        for next in sorted.dropFirst() {
            var current = merged[merged.count - 1]
            if next.start.timeIntervalSince(current.end) <= maxObservationGapSeconds {
                if next.end > current.end {
                    current.end = next.end
                    merged[merged.count - 1] = current
                }
            } else {
                merged.append(next)
            }
        }
        return merged
    }

    private static func coveredSeconds(
        intervals: [ObservationInterval],
        windowStart: Date,
        windowEnd: Date
    ) -> TimeInterval {
        guard windowEnd > windowStart, !intervals.isEmpty else { return 0 }
        let clipped = intervals.compactMap { interval -> (start: Date, end: Date)? in
            let s = max(min(interval.start, interval.end), windowStart)
            let e = min(max(interval.start, interval.end), windowEnd)
            return e > s ? (s, e) : nil
        }.sorted { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            return lhs.end < rhs.end
        }

        var total: TimeInterval = 0
        var activeStart: Date?
        var activeEnd: Date?
        for span in clipped {
            if let s = activeStart, let e = activeEnd {
                if span.start <= e {
                    if span.end > e {
                        activeEnd = span.end
                    }
                } else {
                    total += e.timeIntervalSince(s)
                    activeStart = span.start
                    activeEnd = span.end
                }
            } else {
                activeStart = span.start
                activeEnd = span.end
            }
        }
        if let s = activeStart, let e = activeEnd {
            total += e.timeIntervalSince(s)
        }
        return total
    }

    private func ensureLoadedLocked(now: Date) -> LimitHitHistoryDocument {
        if let existing = document {
            return existing
        }
        var doc = loadFromDisk()
        _ = pruneHistoryLocked(&doc, now: now)
        document = doc
        return doc
    }

    private func pruneHistoryLocked(_ doc: inout LimitHitHistoryDocument, now: Date) -> Bool {
        let cutoff = now.addingTimeInterval(-Self.retentionSeconds)
        var changed = false

        let eventsBefore = doc.events.count
        doc.events.removeAll { $0.timestamp < cutoff }
        if doc.events.count != eventsBefore {
            changed = true
        }

        var updatedIntervals: [String: [ObservationInterval]] = [:]
        for (providerKey, intervals) in doc.observedIntervalsByProvider {
            let pruned = intervals.compactMap { interval -> ObservationInterval? in
                let start = min(interval.start, interval.end)
                let end = max(interval.start, interval.end)
                guard end >= cutoff else { return nil }
                return ObservationInterval(start: max(start, cutoff), end: end)
            }
            if !pruned.isEmpty {
                updatedIntervals[providerKey] = pruned
            }
        }
        if updatedIntervals != doc.observedIntervalsByProvider {
            doc.observedIntervalsByProvider = updatedIntervals
            changed = true
        }

        return changed
    }

    private func loadFromDisk() -> LimitHitHistoryDocument {
        guard let data = try? Data(contentsOf: fileURL) else {
            return LimitHitHistoryDocument()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(LimitHitHistoryDocument.self, from: data),
              decoded.schemaVersion == LimitHitHistoryDocument.currentSchemaVersion else {
            return LimitHitHistoryDocument()
        }
        return decoded
    }

    private func persist(_ doc: LimitHitHistoryDocument) {
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(doc)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Persistence is best-effort; never crash on disk write errors.
        }
    }
}
