import Foundation

/// Combined output of a local or background token-log refresh pass.
public struct LocalLogRefreshSnapshot: Sendable, Equatable {
    public let bucketsBySource: [LocalToolSource: [TokenBucket]]
    public let pendingICloudFiles: Int
    public let pendingICloudFilesBySource: [LocalToolSource: Int]

    public init(
        bucketsBySource: [LocalToolSource: [TokenBucket]],
        pendingICloudFiles: Int,
        pendingICloudFilesBySource: [LocalToolSource: Int] = [:]
    ) {
        self.bucketsBySource = bucketsBySource
        self.pendingICloudFiles = max(0, pendingICloudFiles)
        self.pendingICloudFilesBySource = pendingICloudFilesBySource
    }

    public func pendingCount(for enabledSources: Set<LocalToolSource>) -> Int {
        if pendingICloudFilesBySource.isEmpty {
            return pendingICloudFiles
        }
        return pendingICloudFilesBySource.reduce(0) { total, entry in
            total + (enabledSources.contains(entry.key) ? max(0, entry.value) : 0)
        }
    }
}

/// Coordinates incremental parsing, Application Support caching, enabled-source filtering,
/// and low-priority background materialization of iCloud-evicted files across all local `TokenLogSource`s.
public actor LocalTokenLogCoordinator {
    private struct EvictedFileKey: Hashable, Sendable {
        let source: LocalToolSource
        let cacheKey: String
    }

    private struct AttemptedFileVersion: Hashable, Sendable {
        let key: EvictedFileKey
        let device: UInt64
        let inode: UInt64
        let size: UInt64
        let mtimeNanos: Int64
        let secondaryDevice: UInt64
        let secondaryInode: UInt64
        let secondarySize: UInt64
        let secondaryMtimeNanos: Int64

        init(key: EvictedFileKey, file: PendingEvictedLogFile) {
            self.key = key
            self.device = file.metadata.device
            self.inode = file.metadata.inode
            self.size = file.metadata.size
            self.mtimeNanos = file.metadata.mtimeNanos
            self.secondaryDevice = file.secondaryMetadata?.device ?? 0
            self.secondaryInode = file.secondaryMetadata?.inode ?? 0
            self.secondarySize = file.secondaryMetadata?.size ?? 0
            self.secondaryMtimeNanos = file.secondaryMetadata?.mtimeNanos ?? 0
        }

        init(key: EvictedFileKey, metadata: FileMetadata, secondaryMetadata: FileMetadata?) {
            self.key = key
            self.device = metadata.device
            self.inode = metadata.inode
            self.size = metadata.size
            self.mtimeNanos = metadata.mtimeNanos
            self.secondaryDevice = secondaryMetadata?.device ?? 0
            self.secondaryInode = secondaryMetadata?.inode ?? 0
            self.secondarySize = secondaryMetadata?.size ?? 0
            self.secondaryMtimeNanos = secondaryMetadata?.mtimeNanos ?? 0
        }
    }

    private struct EvictedRetryRecord: Sendable {
        let failureCount: Int
        let nextAttemptAt: Date
        let lastMetadata: FileMetadata
        let lastSecondaryMetadata: FileMetadata?
    }

    private enum WorkerResultKind: Sendable {
        case scanned(EvictedMaterializationOutcome, SourceCacheState)
        case skippedDisabled
        case alreadyResolvedByLateWorker
    }

    private struct LateWorkerCompletion: Sendable {
        let key: EvictedFileKey
        let file: PendingEvictedLogFile
        let initialEntry: FileCacheEntry?
        let timeZoneIdentifier: String
        let result: WorkerResultKind
        let persistCache: Bool
        let enabledSourcesProvider: (@Sendable () -> Set<LocalToolSource>)?
        let fallbackEnabledSources: Set<LocalToolSource>
        let calendar: Calendar
        let onProgress: (@Sendable (LocalLogRefreshSnapshot) -> Void)?
    }

    private final class LateCompletionsBox: @unchecked Sendable {
        private let lock = NSLock()
        private var queue: [LateWorkerCompletion] = []
        private var resolvedVersions: Set<AttemptedFileVersion> = []
        private var inFlightVersion: AttemptedFileVersion?

        func setInFlight(_ version: AttemptedFileVersion) {
            lock.lock()
            inFlightVersion = version
            lock.unlock()
        }

        func clearInFlight(_ version: AttemptedFileVersion) {
            lock.lock()
            if inFlightVersion == version {
                inFlightVersion = nil
            }
            lock.unlock()
        }

        func isInFlight(_ version: AttemptedFileVersion) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return inFlightVersion == version
        }

        func enqueue(
            _ completion: LateWorkerCompletion,
            markVersionResolved: Bool,
            clearInFlight version: AttemptedFileVersion
        ) {
            lock.lock()
            queue.append(completion)
            if markVersionResolved {
                resolvedVersions.insert(version)
            }
            if inFlightVersion == version {
                inFlightVersion = nil
            }
            lock.unlock()
        }

        func takeAll() -> [LateWorkerCompletion] {
            lock.lock()
            let items = queue
            queue.removeAll(keepingCapacity: false)
            lock.unlock()
            return items
        }

        func isVersionResolved(_ version: AttemptedFileVersion) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return resolvedVersions.contains(version)
        }

        func clearAllResolvedVersions() {
            lock.lock()
            resolvedVersions.removeAll(keepingCapacity: false)
            lock.unlock()
        }
    }

    public static let defaultPerFileTimeout: TimeInterval = 30.0
    public static let defaultMaxConsecutiveTimeouts: Int = 5

    private let sources: [any IncrementalTokenLogSource]
    private let cacheStore: TokenLogCacheStore
    private let perFileTimeout: TimeInterval
    private let backoffPolicy: EvictedRetryBackoffPolicy
    private let maxConsecutiveTimeouts: Int
    private let clock: @Sendable () -> Date
    private let lateCompletionsBox = LateCompletionsBox()

    private var cacheDocument: TokenLogCacheDocument?
    private var pendingByKey: [EvictedFileKey: PendingEvictedLogFile] = [:]
    private var retryRecords: [EvictedFileKey: EvictedRetryRecord] = [:]
    private var activeEnabledSources: Set<LocalToolSource>?
    private var isBackgroundPassActive = false

    public static func defaultSources() -> [any IncrementalTokenLogSource] {
        [
            ClaudeCodeTokenLogSource(),
            CodexCLITokenLogSource(),
            GeminiCLITokenLogSource(),
            OpenCodeTokenLogSource(),
            CursorTokenLogSource()
        ]
    }

    public init(
        sources: [any IncrementalTokenLogSource] = LocalTokenLogCoordinator.defaultSources(),
        cacheStore: TokenLogCacheStore = TokenLogCacheStore(),
        perFileTimeout: TimeInterval = LocalTokenLogCoordinator.defaultPerFileTimeout,
        backoffPolicy: EvictedRetryBackoffPolicy = .default,
        maxConsecutiveTimeouts: Int = LocalTokenLogCoordinator.defaultMaxConsecutiveTimeouts,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sources = sources
        self.cacheStore = cacheStore
        self.perFileTimeout = max(0.01, perFileTimeout.isFinite ? perFileTimeout : Self.defaultPerFileTimeout)
        self.backoffPolicy = backoffPolicy
        self.maxConsecutiveTimeouts = max(1, maxConsecutiveTimeouts)
        self.clock = clock
    }

    /// Loads previously persisted per-source buckets immediately so app launch does not block on full disk scans.
    public func loadCachedBuckets(
        calendar: Calendar = StatisticsAggregator.gregorianCalendar()
    ) -> [LocalToolSource: [TokenBucket]] {
        drainLateCompletions()
        let doc = ensureCacheLoaded(for: calendar.timeZone)
        var result: [LocalToolSource: [TokenBucket]] = [:]
        for source in sources {
            result[source.toolSource] = doc.state(for: source.toolSource).mergedBuckets()
        }
        return result
    }

    /// Incrementally refreshes every enabled source's already-local files, persists the updated cache,
    /// and returns the latest per-source buckets. Disabled sources are not scanned.
    public func refresh(
        enabledSources: Set<LocalToolSource>,
        calendar: Calendar = StatisticsAggregator.gregorianCalendar(),
        persistCache: Bool = true
    ) -> [LocalToolSource: [TokenBucket]] {
        refreshLocalPass(
            enabledSources: enabledSources,
            calendar: calendar,
            now: clock(),
            persistCache: persistCache
        ).bucketsBySource
    }

    /// Fast first pass: refreshes already-local files immediately without materializing iCloud-evicted files,
    /// tracks recent pending evicted files for the low-priority background pass, and returns both buckets and pending count.
    public func refreshLocalPass(
        enabledSources: Set<LocalToolSource>,
        calendar: Calendar = StatisticsAggregator.gregorianCalendar(),
        now: Date? = nil,
        persistCache: Bool = true
    ) -> LocalLogRefreshSnapshot {
        drainLateCompletions()
        let effectiveNow = now ?? clock()
        activeEnabledSources = enabledSources
        var doc = ensureCacheLoaded(for: calendar.timeZone)
        var bucketsBySource: [LocalToolSource: [TokenBucket]] = [:]

        // Drop pending tracking for disabled sources so they are never materialized or shown as pending.
        pendingByKey = pendingByKey.filter { enabledSources.contains($0.key.source) }

        for source in sources {
            let tool = source.toolSource
            guard enabledSources.contains(tool) else {
                continue
            }

            var state = doc.state(for: tool)
            do {
                let lateBox = self.lateCompletionsBox
                let result = try source.refreshLocalPass(
                    state: &state,
                    calendar: calendar,
                    now: effectiveNow
                ) { cacheKey, metadata, secondaryMetadata in
                    let candidate = AttemptedFileVersion(
                        key: EvictedFileKey(source: tool, cacheKey: cacheKey),
                        metadata: metadata,
                        secondaryMetadata: secondaryMetadata
                    )
                    return lateBox.isInFlight(candidate)
                }
                doc.setState(state, for: tool)
                bucketsBySource[tool] = result.buckets
                updatePendingFiles(for: source, result: result)
            } catch {
                bucketsBySource[tool] = state.mergedBuckets()
            }
        }

        // Prune retry records whose files are no longer pending.
        let activeKeys = Set(pendingByKey.keys)
        retryRecords = retryRecords.filter { activeKeys.contains($0.key) }

        cacheDocument = doc
        if persistCache {
            cacheStore.save(doc)
        }
        let countsBySource = pendingCountsBySource(for: enabledSources)
        return LocalLogRefreshSnapshot(
            bucketsBySource: bucketsBySource,
            pendingICloudFiles: countsBySource.values.reduce(0, +),
            pendingICloudFilesBySource: countsBySource
        )
    }

    /// Updates the coordinator's live enabled-source selection, immediately removing pending downloads for
    /// disabled sources so an in-flight background pass does not open subsequent files for them.
    @discardableResult
    public func updateEnabledSources(_ enabledSources: Set<LocalToolSource>) -> Int {
        drainLateCompletions()
        activeEnabledSources = enabledSources
        pendingByKey = pendingByKey.filter { enabledSources.contains($0.key.source) }
        let activeKeys = Set(pendingByKey.keys)
        retryRecords = retryRecords.filter { activeKeys.contains($0.key) }
        return pendingCount(for: enabledSources)
    }

    /// Number of currently pending iCloud-evicted files across `enabledSources`.
    public func pendingICloudFileCount(for enabledSources: Set<LocalToolSource>) -> Int {
        drainLateCompletions()
        return pendingCount(for: enabledSources)
    }

    /// Low-priority background pass: materializes and counts pending iCloud-evicted files one at a time
    /// off the coordinator actor with a process-wide single slot, per-file timeout, and exponential retry backoff.
    public func runBackgroundMaterializationPass(
        enabledSources: Set<LocalToolSource>,
        calendar: Calendar = StatisticsAggregator.gregorianCalendar(),
        totalTimeout: TimeInterval? = nil,
        persistCache: Bool = true,
        enabledSourcesProvider: (@Sendable () -> Set<LocalToolSource>)? = nil,
        onProgress: (@Sendable (LocalLogRefreshSnapshot) -> Void)? = nil
    ) async -> LocalLogRefreshSnapshot {
        drainLateCompletions()
        let resolveEnabled: () -> Set<LocalToolSource> = { [self] in
            if let provider = enabledSourcesProvider {
                return provider()
            }
            return self.activeEnabledSources ?? enabledSources
        }

        guard !isBackgroundPassActive else {
            return currentSnapshot(for: resolveEnabled(), calendar: calendar)
        }
        isBackgroundPassActive = true
        defer {
            isBackgroundPassActive = false
            drainLateCompletions()
        }

        if enabledSourcesProvider == nil {
            activeEnabledSources = enabledSources
        }

        let deadlineNanos: UInt64? = totalTimeout.map { timeout in
            let clamped = max(0.01, timeout.isFinite ? timeout : 600.0)
            let raw = (clamped * 1_000_000_000.0).rounded()
            let delta = raw >= Double(UInt64.max / 2) ? UInt64(Int.max) : UInt64(max(1.0, raw))
            return DispatchTime.now().uptimeNanoseconds &+ delta
        }

        var attemptedVersions: Set<AttemptedFileVersion> = []
        var processedSinceSave = 0
        var consecutiveTimeouts = 0

        passLoop: while !Task.isCancelled {
            drainLateCompletions()
            if let deadlineNanos, DispatchTime.now().uptimeNanoseconds >= deadlineNanos {
                break passLoop
            }

            let currentEnabled = resolveEnabled()
            pruneDisabledPending(enabledSources: currentEnabled)

            let now = clock()
            guard let next = nextEligiblePendingFile(
                enabledSources: currentEnabled,
                attemptedVersions: attemptedVersions,
                now: now
            ) else {
                break passLoop
            }

            let key = EvictedFileKey(source: next.toolSource, cacheKey: next.cacheKey)
            let version = AttemptedFileVersion(key: key, file: next)
            attemptedVersions.insert(version)

            guard let source = sources.first(where: { $0.toolSource == next.toolSource }) else {
                if let existingPending = pendingByKey[key], samePendingVersion(existingPending, next) {
                    pendingByKey.removeValue(forKey: key)
                    retryRecords.removeValue(forKey: key)
                }
                continue passLoop
            }

            let doc = ensureCacheLoaded(for: calendar.timeZone)
            let initialEntry = doc.state(for: next.toolSource).files[next.cacheKey]
            let workerState = isolatedStateForWorker(source: next.toolSource, cacheKey: next.cacheKey, from: doc)

            var effectiveTimeout = perFileTimeout
            if let deadlineNanos {
                let nowNanos = DispatchTime.now().uptimeNanoseconds
                if nowNanos >= deadlineNanos { break passLoop }
                let remainingSeconds = Double(deadlineNanos - nowNanos) / 1_000_000_000.0
                if remainingSeconds <= 0 { break passLoop }
                effectiveTimeout = min(effectiveTimeout, remainingSeconds)
            }

            let lateBox = self.lateCompletionsBox
            let tzIdentifier = calendar.timeZone.identifier
            let workResult: BoundedWorkResult<WorkerResultKind> = await BoundedBackgroundWork.run(
                timeout: effectiveTimeout,
                onLateCompletion: { [weak self] lateResult in
                    let markResolved: Bool
                    switch lateResult {
                    case .scanned(let outcome, _):
                        markResolved = (outcome == .counted
                            || outcome == .removed
                            || outcome == .skippedTooOld
                            || outcome == .staleVersion)
                    case .skippedDisabled, .alreadyResolvedByLateWorker:
                        markResolved = false
                    }
                    let completion = LateWorkerCompletion(
                        key: key,
                        file: next,
                        initialEntry: initialEntry,
                        timeZoneIdentifier: tzIdentifier,
                        result: lateResult,
                        persistCache: persistCache,
                        enabledSourcesProvider: enabledSourcesProvider,
                        fallbackEnabledSources: enabledSources,
                        calendar: calendar,
                        onProgress: onProgress
                    )
                    lateBox.enqueue(completion, markVersionResolved: markResolved, clearInFlight: version)
                    Task(priority: .utility) { [weak self] in
                        await self?.drainLateCompletions()
                    }
                }
            ) {
                if let provider = enabledSourcesProvider, !provider().contains(next.toolSource) {
                    return .skippedDisabled
                }
                if lateBox.isVersionResolved(version) {
                    return .alreadyResolvedByLateWorker
                }
                lateBox.setInFlight(version)
                var stateCopy = workerState
                let outcome = source.scanEvictedFile(next, state: &stateCopy, calendar: calendar, now: now)
                return .scanned(outcome, stateCopy)
            }

            drainLateCompletions()
            let finishTime = clock()
            let latestEnabled = resolveEnabled()
            pruneDisabledPending(enabledSources: latestEnabled)

            switch workResult {
            case .slotBusy:
                // Another materialization is still occupying the process-wide single slot.
                // Do not start a second open and do not penalize this unattempted file with backoff.
                break passLoop

            case .timedOut:
                if let currentPending = pendingByKey[key], samePendingVersion(currentPending, next) {
                    recordRetryFailure(for: key, file: next, at: finishTime)
                }
                consecutiveTimeouts += 1
                let snapshot = currentSnapshot(for: latestEnabled, calendar: calendar)
                onProgress?(snapshot)

                // A timed-out worker retains the single slot until it really finishes.
                // If there is no outer totalTimeout (or max consecutive timeouts reached), return promptly now.
                if (BoundedBackgroundWork.isSlotOccupied && deadlineNanos == nil)
                    || consecutiveTimeouts >= maxConsecutiveTimeouts {
                    break passLoop
                }

            case .completed(.skippedDisabled), .completed(.alreadyResolvedByLateWorker):
                lateBox.clearInFlight(version)
                let snapshot = currentSnapshot(for: latestEnabled, calendar: calendar)
                onProgress?(snapshot)

            case .completed(.scanned(let outcome, let updatedState)):
                defer { lateBox.clearInFlight(version) }
                var latestDoc = ensureCacheLoaded(for: calendar.timeZone)
                let pendingMatchesProcessedVersion = pendingByKey[key].map {
                    samePendingVersion($0, next)
                } ?? false

                switch outcome {
                case .counted:
                    consecutiveTimeouts = 0
                    if pendingMatchesProcessedVersion {
                        let committed = mergeWorkerState(
                            updatedState,
                            for: next,
                            initialEntry: initialEntry,
                            into: &latestDoc
                        )
                        if committed {
                            pendingByKey.removeValue(forKey: key)
                            retryRecords.removeValue(forKey: key)
                            cacheDocument = latestDoc
                            processedSinceSave += 1

                            if persistCache && (processedSinceSave >= 5 || pendingCount(for: latestEnabled) == 0) {
                                cacheStore.save(latestDoc)
                                processedSinceSave = 0
                            }
                        }
                    }

                case .removed:
                    consecutiveTimeouts = 0
                    if pendingMatchesProcessedVersion {
                        if next.toolSource == .openCode {
                            let committed = mergeWorkerState(
                                updatedState,
                                for: next,
                                initialEntry: initialEntry,
                                into: &latestDoc
                            )
                            if committed {
                                cacheDocument = latestDoc
                                processedSinceSave += 1
                            }
                        } else {
                            var sourceState = latestDoc.state(for: next.toolSource)
                            if sourceState.files[next.cacheKey] == initialEntry {
                                sourceState.files.removeValue(forKey: next.cacheKey)
                                latestDoc.setState(sourceState, for: next.toolSource)
                                cacheDocument = latestDoc
                                processedSinceSave += 1
                            }
                        }
                        pendingByKey.removeValue(forKey: key)
                        retryRecords.removeValue(forKey: key)
                    }

                case .skippedTooOld, .staleVersion:
                    consecutiveTimeouts = 0
                    if pendingMatchesProcessedVersion {
                        pendingByKey.removeValue(forKey: key)
                        retryRecords.removeValue(forKey: key)
                    }

                case .stillDataless, .failed, .timedOut:
                    if pendingMatchesProcessedVersion {
                        recordRetryFailure(for: key, file: next, at: finishTime)
                    }
                    if outcome == .timedOut {
                        consecutiveTimeouts += 1
                    } else {
                        consecutiveTimeouts = 0
                    }
                }

                let snapshot = currentSnapshot(for: latestEnabled, calendar: calendar)
                onProgress?(snapshot)

                if consecutiveTimeouts >= maxConsecutiveTimeouts {
                    break passLoop
                }
            }
        }

        if persistCache && processedSinceSave > 0, let doc = cacheDocument {
            cacheStore.save(doc)
        }

        let finalEnabled = resolveEnabled()
        pruneDisabledPending(enabledSources: finalEnabled)
        return currentSnapshot(for: finalEnabled, calendar: calendar)
    }

    /// Returns the filesystem roots that should be watched for the given set of enabled sources.
    public func watchDirectories(for enabledSources: Set<LocalToolSource>) -> [URL] {
        sources
            .filter { enabledSources.contains($0.toolSource) }
            .flatMap(\.watchDirectories)
    }

    /// Filters and merges per-source buckets according to the live enabled-source map.
    public static func activeBuckets(
        from bucketsBySource: [LocalToolSource: [TokenBucket]],
        enabledSources: [LocalToolSource: Bool]
    ) -> [TokenBucket] {
        var combined: [TokenBucket] = []
        for source in LocalToolSource.allCases {
            guard enabledSources[source] ?? source.defaultEnabled else { continue }
            if let sourceBuckets = bucketsBySource[source] {
                combined.append(contentsOf: sourceBuckets)
            }
        }
        return TokenBucketAggregator.merge(combined)
    }

    private func pruneDisabledPending(enabledSources: Set<LocalToolSource>) {
        pendingByKey = pendingByKey.filter { enabledSources.contains($0.key.source) }
        let activeKeys = Set(pendingByKey.keys)
        retryRecords = retryRecords.filter { activeKeys.contains($0.key) }
    }

    private func recordRetryFailure(
        for key: EvictedFileKey,
        file: PendingEvictedLogFile,
        at finishTime: Date
    ) {
        let prevFailures = retryRecords[key]?.failureCount ?? 0
        let nextFailures = prevFailures + 1
        let delay = backoffPolicy.delay(forFailureCount: nextFailures)
        retryRecords[key] = EvictedRetryRecord(
            failureCount: nextFailures,
            nextAttemptAt: finishTime.addingTimeInterval(delay),
            lastMetadata: file.metadata,
            lastSecondaryMetadata: file.secondaryMetadata
        )
    }

    private func updatePendingFiles(
        for source: any IncrementalTokenLogSource,
        result: LocalRefreshResult
    ) {
        let tool = source.toolSource
        let discoveredByKey = Dictionary(
            uniqueKeysWithValues: result.pendingEvictedFiles.map {
                (EvictedFileKey(source: tool, cacheKey: $0.cacheKey), $0)
            }
        )

        let existingKeys = Array(pendingByKey.keys.filter { $0.source == tool })
        for key in existingKeys {
            if discoveredByKey[key] != nil {
                continue
            }
            if result.inconclusiveCacheKeys.contains(key.cacheKey) {
                // Transient metadata/open/read failure: retain last known pending version and retry deadline.
                continue
            }
            if result.resolvedCacheKeys.contains(key.cacheKey) {
                // Definitively counted, removed, or aged past the 31-day cutoff.
                pendingByKey.removeValue(forKey: key)
                continue
            }
            if let existingPending = pendingByKey[key],
               !source.isPendingFileConfirmedRemoved(existingPending) {
                // Not enumerated during this refresh, but not confirmed deleted (e.g. transient EIO/EACCES):
                // retain last known pending version and retry deadline.
                continue
            }
            pendingByKey.removeValue(forKey: key)
        }

        for (key, file) in discoveredByKey {
            pendingByKey[key] = file
            if let existingRetry = retryRecords[key],
               (!EvictedLogPolicy.sameFileVersion(existingRetry.lastMetadata, file.metadata)
                || !EvictedLogPolicy.sameOptionalFileVersion(existingRetry.lastSecondaryMetadata, file.secondaryMetadata)) {
                // File identity, size, or mtime changed: clear backoff so the updated file is attempted right away.
                retryRecords.removeValue(forKey: key)
            }
        }
    }

    private func samePendingVersion(_ lhs: PendingEvictedLogFile, _ rhs: PendingEvictedLogFile) -> Bool {
        EvictedLogPolicy.sameFileVersion(lhs.metadata, rhs.metadata)
            && EvictedLogPolicy.sameOptionalFileVersion(lhs.secondaryMetadata, rhs.secondaryMetadata)
    }

    private func nextEligiblePendingFile(
        enabledSources: Set<LocalToolSource>,
        attemptedVersions: Set<AttemptedFileVersion>,
        now: Date
    ) -> PendingEvictedLogFile? {
        let candidates = pendingByKey.compactMap { key, file -> PendingEvictedLogFile? in
            guard enabledSources.contains(key.source) else {
                return nil
            }
            let versionKey = AttemptedFileVersion(key: key, file: file)
            guard !attemptedVersions.contains(versionKey) else {
                return nil
            }
            if let retry = retryRecords[key], now < retry.nextAttemptAt {
                return nil
            }
            return file
        }
        return candidates.sorted { lhs, rhs in
            if lhs.metadata.mtimeNanos != rhs.metadata.mtimeNanos {
                return lhs.metadata.mtimeNanos > rhs.metadata.mtimeNanos
            }
            if lhs.toolSource.rawValue != rhs.toolSource.rawValue {
                return lhs.toolSource.rawValue < rhs.toolSource.rawValue
            }
            return lhs.cacheKey < rhs.cacheKey
        }.first
    }

    private func isolatedStateForWorker(
        source: LocalToolSource,
        cacheKey: String,
        from doc: TokenLogCacheDocument
    ) -> SourceCacheState {
        let sourceState = doc.state(for: source)
        if source == .openCode {
            return sourceState
        }
        if let entry = sourceState.files[cacheKey] {
            return SourceCacheState(files: [cacheKey: entry])
        }
        return SourceCacheState()
    }

    /// Commits a worker's cache update ONLY if the target cache entry has not been modified by a concurrent
    /// refresh since the worker started AND the updated entry matches the exact file version the worker processed.
    @discardableResult
    private func mergeWorkerState(
        _ workerState: SourceCacheState,
        for file: PendingEvictedLogFile,
        initialEntry: FileCacheEntry?,
        into doc: inout TokenLogCacheDocument
    ) -> Bool {
        if file.toolSource == .openCode {
            var current = doc.state(for: .openCode)
            guard current.files[file.cacheKey] == initialEntry else {
                return false
            }
            if let updatedEntry = workerState.files[file.cacheKey] {
                guard EvictedLogPolicy.matchesFileVersion(updatedEntry, file.metadata) else {
                    return false
                }
                if file.cacheKey == OpenCodeTokenLogSource.sqliteCacheKey,
                   !EvictedLogPolicy.matchesSecondaryFileVersion(updatedEntry, file.secondaryMetadata) {
                    return false
                }
                current.files[file.cacheKey] = updatedEntry
            } else {
                current.files.removeValue(forKey: file.cacheKey)
            }
            // Recompute deterministic OpenCode message-ID precedence (SQLite first, then legacy JSON in
            // ascending cacheKey order) across all current cached entries regardless of download order.
            OpenCodeTokenLogSource.recomputeLegacyActiveBuckets(state: &current)
            doc.setState(current, for: .openCode)
            return true
        }

        var current = doc.state(for: file.toolSource)
        guard current.files[file.cacheKey] == initialEntry else {
            // A concurrent local refresh already updated or replaced this cache entry; never overwrite it.
            return false
        }
        if let updatedEntry = workerState.files[file.cacheKey] {
            guard EvictedLogPolicy.matchesFileVersion(updatedEntry, file.metadata) else {
                return false
            }
            current.files[file.cacheKey] = updatedEntry
        } else {
            current.files.removeValue(forKey: file.cacheKey)
        }
        doc.setState(current, for: file.toolSource)
        return true
    }

    private func pendingCountsBySource(for enabledSources: Set<LocalToolSource>) -> [LocalToolSource: Int] {
        var counts: [LocalToolSource: Int] = [:]
        for source in LocalToolSource.allCases where enabledSources.contains(source) {
            counts[source] = 0
        }
        for key in pendingByKey.keys where enabledSources.contains(key.source) {
            counts[key.source, default: 0] += 1
        }
        return counts
    }

    private func pendingCount(for enabledSources: Set<LocalToolSource>) -> Int {
        pendingByKey.keys.reduce(0) { count, key in
            count + (enabledSources.contains(key.source) ? 1 : 0)
        }
    }

    private func currentSnapshot(
        for enabledSources: Set<LocalToolSource>,
        calendar: Calendar
    ) -> LocalLogRefreshSnapshot {
        let doc = ensureCacheLoaded(for: calendar.timeZone)
        var bucketsBySource: [LocalToolSource: [TokenBucket]] = [:]
        for source in sources where enabledSources.contains(source.toolSource) {
            bucketsBySource[source.toolSource] = doc.state(for: source.toolSource).mergedBuckets()
        }
        let countsBySource = pendingCountsBySource(for: enabledSources)
        return LocalLogRefreshSnapshot(
            bucketsBySource: bucketsBySource,
            pendingICloudFiles: countsBySource.values.reduce(0, +),
            pendingICloudFilesBySource: countsBySource
        )
    }

    private func drainLateCompletions() {
        let completions = lateCompletionsBox.takeAll()
        if !completions.isEmpty {
            var dirtyPersistTimeZone: TimeZone?
            for completion in completions {
                applyLateCompletion(completion, dirtyPersistTimeZone: &dirtyPersistTimeZone)
            }
            if let tz = dirtyPersistTimeZone,
               let doc = cacheDocument,
               doc.timeZoneIdentifier == tz.identifier {
                cacheStore.save(doc)
            }
        }
        if !isBackgroundPassActive {
            lateCompletionsBox.clearAllResolvedVersions()
        }
    }

    private func applyLateCompletion(
        _ completion: LateWorkerCompletion,
        dirtyPersistTimeZone: inout TimeZone?
    ) {
        let currentEnabled: Set<LocalToolSource>
        if let provider = completion.enabledSourcesProvider {
            currentEnabled = provider()
        } else {
            currentEnabled = activeEnabledSources ?? completion.fallbackEnabledSources
        }
        pruneDisabledPending(enabledSources: currentEnabled)

        guard currentEnabled.contains(completion.file.toolSource) else {
            return
        }

        let key = completion.key
        let pendingMatchesProcessedVersion = pendingByKey[key].map {
            samePendingVersion($0, completion.file)
        } ?? false
        guard pendingMatchesProcessedVersion else {
            return
        }

        switch completion.result {
        case .skippedDisabled, .alreadyResolvedByLateWorker:
            return

        case .scanned(let outcome, let updatedState):
            var latestDoc = ensureCacheLoaded(for: completion.calendar.timeZone)
            guard latestDoc.timeZoneIdentifier == completion.timeZoneIdentifier else {
                return
            }

            var didChange = false
            switch outcome {
            case .counted:
                let committed = mergeWorkerState(
                    updatedState,
                    for: completion.file,
                    initialEntry: completion.initialEntry,
                    into: &latestDoc
                )
                if committed {
                    pendingByKey.removeValue(forKey: key)
                    retryRecords.removeValue(forKey: key)
                    cacheDocument = latestDoc
                    didChange = true
                    if completion.persistCache {
                        dirtyPersistTimeZone = completion.calendar.timeZone
                    }
                }

            case .removed:
                if completion.file.toolSource == .openCode {
                    let committed = mergeWorkerState(
                        updatedState,
                        for: completion.file,
                        initialEntry: completion.initialEntry,
                        into: &latestDoc
                    )
                    if committed {
                        cacheDocument = latestDoc
                        if completion.persistCache {
                            dirtyPersistTimeZone = completion.calendar.timeZone
                        }
                    }
                } else {
                    var sourceState = latestDoc.state(for: completion.file.toolSource)
                    if sourceState.files[completion.file.cacheKey] == completion.initialEntry {
                        sourceState.files.removeValue(forKey: completion.file.cacheKey)
                        latestDoc.setState(sourceState, for: completion.file.toolSource)
                        cacheDocument = latestDoc
                        if completion.persistCache {
                            dirtyPersistTimeZone = completion.calendar.timeZone
                        }
                    }
                }
                pendingByKey.removeValue(forKey: key)
                retryRecords.removeValue(forKey: key)
                didChange = true

            case .skippedTooOld, .staleVersion:
                pendingByKey.removeValue(forKey: key)
                retryRecords.removeValue(forKey: key)
                didChange = true

            case .stillDataless, .failed, .timedOut:
                // Timeout already recorded retry backoff for this attempt; do not double-penalize.
                break
            }

            if didChange {
                let snapshot = currentSnapshot(for: currentEnabled, calendar: completion.calendar)
                completion.onProgress?(snapshot)
            }
        }
    }

    private func ensureCacheLoaded(for timeZone: TimeZone) -> TokenLogCacheDocument {
        if let existing = cacheDocument, existing.timeZoneIdentifier == timeZone.identifier {
            return existing
        }
        lateCompletionsBox.clearAllResolvedVersions()
        let loaded = cacheStore.load(expectedTimeZone: timeZone)
        cacheDocument = loaded
        return loaded
    }
}

/// Thread-safe holder for the live set of enabled local sources so background materialization workers
/// observe user checkbox toggles immediately without waiting for an actor hop.
private final class EnabledSourcesBox: @unchecked Sendable {
    private let lock = NSLock()
    private var sources: Set<LocalToolSource>

    init(_ initial: Set<LocalToolSource> = []) {
        self.sources = initial
    }

    func set(_ value: Set<LocalToolSource>) {
        lock.lock()
        sources = value
        lock.unlock()
    }

    func get() -> Set<LocalToolSource> {
        lock.lock()
        defer { lock.unlock() }
        return sources
    }
}

/// Manages live local-log folder watching, debounced event refreshes, automatic watcher recovery,
/// and low-priority background materialization of iCloud-evicted log files. Used directly by `AppStore` outside demo mode.
@MainActor
public final class LocalLogPipelineController {
    public typealias EnabledSourcesProvider = @MainActor () -> Set<LocalToolSource>
    public typealias BucketsHandler = @MainActor (_ bucketsBySource: [LocalToolSource: [TokenBucket]], _ refreshedAt: Date?) -> Void
    public typealias PendingICloudHandler = @MainActor (_ pendingCount: Int) -> Void

    private let coordinator: LocalTokenLogCoordinator
    private let enabledSourcesProvider: EnabledSourcesProvider
    private let enabledSourcesBox: EnabledSourcesBox
    private let onBucketsUpdated: BucketsHandler
    private let onPendingICloudFilesChanged: PendingICloudHandler?
    private let calendar: Calendar
    private let clock: @Sendable () -> Date
    private var watcher: DirectoryWatcher?
    private var eventRefreshTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var backgroundMaterializationTask: Task<Void, Never>?
    private var isStopped = false

    public var isWatching: Bool {
        watcher?.isWatching ?? false
    }

    public init(
        coordinator: LocalTokenLogCoordinator,
        debounceInterval: TimeInterval = 0.75,
        watchBackend: (any DirectoryWatchBackend)? = nil,
        watchScheduler: any DirectoryWatchScheduler = DispatchDirectoryWatchScheduler(),
        calendar: Calendar = StatisticsAggregator.gregorianCalendar(),
        clock: @escaping @Sendable () -> Date = { Date() },
        enabledSources: @escaping EnabledSourcesProvider,
        onBucketsUpdated: @escaping BucketsHandler,
        onPendingICloudFilesChanged: PendingICloudHandler? = nil
    ) {
        self.coordinator = coordinator
        self.calendar = calendar
        self.clock = clock
        self.enabledSourcesProvider = enabledSources
        self.enabledSourcesBox = EnabledSourcesBox(enabledSources())
        self.onBucketsUpdated = onBucketsUpdated
        self.onPendingICloudFilesChanged = onPendingICloudFilesChanged
        self.watcher = DirectoryWatcher(
            debounceInterval: debounceInterval,
            backend: watchBackend,
            scheduler: watchScheduler
        ) { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleEventDrivenRefresh()
            }
        }
    }

    /// Synchronously updates the shared enabled-source selection so an active background materialization pass
    /// immediately skips newly disabled sources before opening any subsequent files.
    @discardableResult
    public func syncEnabledSources() -> Set<LocalToolSource> {
        let enabled = enabledSourcesProvider()
        enabledSourcesBox.set(enabled)
        return enabled
    }

    /// Starts the pipeline asynchronously: loads cached buckets, attempts to start the watcher, and refreshes logs.
    public func start() {
        guard !isStopped, startupTask == nil else { return }
        _ = syncEnabledSources()
        startupTask = Task { [weak self] in
            await self?.runInitialLoad()
        }
    }

    /// Runs initial cache load, watcher startup, and log refresh.
    public func runInitialLoad() async {
        guard !isStopped else { return }
        _ = syncEnabledSources()
        let cached = await coordinator.loadCachedBuckets(calendar: calendar)
        guard !isStopped else { return }
        onBucketsUpdated(cached, nil)
        await refreshLogs()
    }

    /// Ensures the directory watcher is active for the currently enabled sources.
    /// Automatically retries startup when the watcher is inactive (e.g. after an earlier startup failure)
    /// and short-circuits without restarting when already watching the same resolved directories.
    @discardableResult
    public func ensureWatcherActive() async -> Bool {
        guard !isStopped, let watcher else { return false }
        let enabled = syncEnabledSources()
        let dirs = await coordinator.watchDirectories(for: enabled)
        guard !isStopped else { return false }
        return watcher.watch(directories: dirs)
    }

    /// Retries an inactive watcher (if needed), incrementally refreshes already-local logs immediately,
    /// and schedules the low-priority background materialization pass whenever iCloud-evicted files are pending.
    public func refreshLogs() async {
        guard !isStopped else { return }
        _ = await ensureWatcherActive()
        guard !isStopped else { return }
        let enabled = syncEnabledSources()
        let snapshot = await coordinator.refreshLocalPass(
            enabledSources: enabled,
            calendar: calendar,
            now: clock()
        )
        guard !isStopped else { return }
        let currentEnabled = syncEnabledSources()
        let filteredBuckets = snapshot.bucketsBySource.filter { currentEnabled.contains($0.key) }
        let filteredPending = snapshot.pendingCount(for: currentEnabled)
        onBucketsUpdated(filteredBuckets, clock())
        onPendingICloudFilesChanged?(filteredPending)

        if filteredPending > 0 {
            scheduleBackgroundMaterializationIfNeeded()
        }
    }

    /// Waits for any currently running background iCloud materialization pass to finish (intended for tests).
    public func waitForBackgroundMaterialization() async {
        await backgroundMaterializationTask?.value
    }

    /// Updates watched directories after a user toggles a local source, refreshing immediately when enabled
    /// and immediately preventing subsequent background opens for disabled sources.
    public func handleSourceToggled(isNowEnabled: Bool) async {
        guard !isStopped else { return }
        // Update shared box synchronously BEFORE any await so an active background pass stops opening disabled sources immediately.
        _ = syncEnabledSources()
        _ = await ensureWatcherActive()
        guard !isStopped else { return }
        if isNowEnabled {
            await refreshLogs()
        } else {
            let enabled = syncEnabledSources()
            let remaining = await coordinator.updateEnabledSources(enabled)
            guard !isStopped else { return }
            let currentEnabled = syncEnabledSources()
            if currentEnabled == enabled {
                onPendingICloudFilesChanged?(remaining)
            } else {
                let latestRemaining = await coordinator.pendingICloudFileCount(for: currentEnabled)
                guard !isStopped else { return }
                onPendingICloudFilesChanged?(latestRemaining)
            }
        }
    }

    public func stop() {
        isStopped = true
        startupTask?.cancel()
        startupTask = nil
        eventRefreshTask?.cancel()
        eventRefreshTask = nil
        backgroundMaterializationTask?.cancel()
        backgroundMaterializationTask = nil
        watcher?.stop()
    }

    private func scheduleEventDrivenRefresh() {
        guard !isStopped else { return }
        eventRefreshTask?.cancel()
        eventRefreshTask = Task { [weak self] in
            await self?.refreshLogs()
        }
    }

    private func scheduleBackgroundMaterializationIfNeeded() {
        guard !isStopped, backgroundMaterializationTask == nil else { return }
        let enabled = syncEnabledSources()
        let coordinator = self.coordinator
        let calendar = self.calendar
        let clock = self.clock
        let enabledBox = self.enabledSourcesBox

        backgroundMaterializationTask = Task.detached(priority: .utility) { [weak self] in
            let finalSnapshot = await coordinator.runBackgroundMaterializationPass(
                enabledSources: enabled,
                calendar: calendar,
                persistCache: true,
                enabledSourcesProvider: { enabledBox.get() },
                onProgress: { [weak self] snapshot in
                    Task { @MainActor [weak self] in
                        guard let self, !self.isStopped else { return }
                        let liveEnabled = self.syncEnabledSources()
                        let filteredBuckets = snapshot.bucketsBySource.filter { liveEnabled.contains($0.key) }
                        self.onBucketsUpdated(filteredBuckets, clock())
                        self.onPendingICloudFilesChanged?(snapshot.pendingCount(for: liveEnabled))
                    }
                }
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.backgroundMaterializationTask = nil
                guard !self.isStopped else { return }
                let liveEnabled = self.syncEnabledSources()
                let filteredBuckets = finalSnapshot.bucketsBySource.filter { liveEnabled.contains($0.key) }
                self.onBucketsUpdated(filteredBuckets, clock())
                self.onPendingICloudFilesChanged?(finalSnapshot.pendingCount(for: liveEnabled))
            }
        }
    }
}
