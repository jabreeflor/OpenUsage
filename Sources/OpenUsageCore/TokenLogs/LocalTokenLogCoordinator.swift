import Foundation

/// Coordinates incremental parsing, Application Support caching, and enabled-source filtering
/// across all local `TokenLogSource` implementations.
public actor LocalTokenLogCoordinator {
    private let sources: [any IncrementalTokenLogSource]
    private let cacheStore: TokenLogCacheStore
    private var cacheDocument: TokenLogCacheDocument?

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
        cacheStore: TokenLogCacheStore = TokenLogCacheStore()
    ) {
        self.sources = sources
        self.cacheStore = cacheStore
    }

    /// Loads previously persisted per-source buckets immediately so app launch does not block on full disk scans.
    public func loadCachedBuckets(
        calendar: Calendar = StatisticsAggregator.gregorianCalendar()
    ) -> [LocalToolSource: [TokenBucket]] {
        let doc = ensureCacheLoaded(for: calendar.timeZone)
        var result: [LocalToolSource: [TokenBucket]] = [:]
        for source in sources {
            result[source.toolSource] = doc.state(for: source.toolSource).mergedBuckets()
        }
        return result
    }

    /// Incrementally refreshes every enabled source, persists the updated cache, and returns
    /// the latest per-source buckets. Disabled sources are not scanned.
    public func refresh(
        enabledSources: Set<LocalToolSource>,
        calendar: Calendar = StatisticsAggregator.gregorianCalendar(),
        persistCache: Bool = true
    ) -> [LocalToolSource: [TokenBucket]] {
        var doc = ensureCacheLoaded(for: calendar.timeZone)
        var bucketsBySource: [LocalToolSource: [TokenBucket]] = [:]

        for source in sources {
            let tool = source.toolSource
            guard enabledSources.contains(tool) else {
                // Keep any previously cached buckets in memory/disk untouched, but return empty for disabled tools.
                continue
            }

            var state = doc.state(for: tool)
            do {
                let refreshed = try source.refresh(state: &state, calendar: calendar)
                doc.setState(state, for: tool)
                bucketsBySource[tool] = refreshed
            } catch {
                bucketsBySource[tool] = state.mergedBuckets()
            }
        }

        cacheDocument = doc
        if persistCache {
            cacheStore.save(doc)
        }
        return bucketsBySource
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

    private func ensureCacheLoaded(for timeZone: TimeZone) -> TokenLogCacheDocument {
        if let existing = cacheDocument, existing.timeZoneIdentifier == timeZone.identifier {
            return existing
        }
        let loaded = cacheStore.load(expectedTimeZone: timeZone)
        cacheDocument = loaded
        return loaded
    }
}

/// Manages live local-log folder watching, debounced event refreshes, and automatic watcher recovery
/// whenever a normal or periodic refresh runs. Used directly by `AppStore` outside demo mode.
@MainActor
public final class LocalLogPipelineController {
    public typealias EnabledSourcesProvider = @MainActor () -> Set<LocalToolSource>
    public typealias BucketsHandler = @MainActor (_ bucketsBySource: [LocalToolSource: [TokenBucket]], _ refreshedAt: Date?) -> Void

    private let coordinator: LocalTokenLogCoordinator
    private let enabledSourcesProvider: EnabledSourcesProvider
    private let onBucketsUpdated: BucketsHandler
    private let calendar: Calendar
    private let clock: @Sendable () -> Date
    private var watcher: DirectoryWatcher?
    private var eventRefreshTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
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
        onBucketsUpdated: @escaping BucketsHandler
    ) {
        self.coordinator = coordinator
        self.calendar = calendar
        self.clock = clock
        self.enabledSourcesProvider = enabledSources
        self.onBucketsUpdated = onBucketsUpdated
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

    /// Starts the pipeline asynchronously: loads cached buckets, attempts to start the watcher, and refreshes logs.
    public func start() {
        guard !isStopped, startupTask == nil else { return }
        startupTask = Task { [weak self] in
            await self?.runInitialLoad()
        }
    }

    /// Runs initial cache load, watcher startup, and log refresh.
    public func runInitialLoad() async {
        guard !isStopped else { return }
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
        let enabled = enabledSourcesProvider()
        let dirs = await coordinator.watchDirectories(for: enabled)
        guard !isStopped else { return false }
        return watcher.watch(directories: dirs)
    }

    /// Retries an inactive watcher (if needed) and incrementally refreshes all enabled local log sources.
    public func refreshLogs() async {
        guard !isStopped else { return }
        _ = await ensureWatcherActive()
        guard !isStopped else { return }
        let enabled = enabledSourcesProvider()
        let updated = await coordinator.refresh(enabledSources: enabled, calendar: calendar)
        guard !isStopped else { return }
        onBucketsUpdated(updated, clock())
    }

    /// Updates watched directories after a user toggles a local source, refreshing immediately when enabled.
    public func handleSourceToggled(isNowEnabled: Bool) async {
        guard !isStopped else { return }
        _ = await ensureWatcherActive()
        if isNowEnabled {
            await refreshLogs()
        }
    }

    public func stop() {
        isStopped = true
        startupTask?.cancel()
        startupTask = nil
        eventRefreshTask?.cancel()
        eventRefreshTask = nil
        watcher?.stop()
    }

    private func scheduleEventDrivenRefresh() {
        guard !isStopped else { return }
        eventRefreshTask?.cancel()
        eventRefreshTask = Task { [weak self] in
            await self?.refreshLogs()
        }
    }
}
