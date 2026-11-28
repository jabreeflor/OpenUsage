import AppKit
import Foundation
import Observation
import OpenUsageCore

struct WorkspaceURLOpener: URLOpening, Sendable {
    @discardableResult
    func open(_ url: URL) -> Bool {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                NSWorkspace.shared.open(url)
            }
        }
        return DispatchQueue.main.sync {
            NSWorkspace.shared.open(url)
        }
    }
}

enum DropdownSelection: Equatable, Hashable, Sendable {
    case provider(ProviderID)
    case today
}

@MainActor
final class AppStore: Observable {
    private let _$observationRegistrar = ObservationRegistrar()

    let options: LaunchOptions
    let thresholds: ThresholdSettings
    let localSources: LocalSourceSettings
    let accounts: AccountsController

    private var _tokenBuckets: [TokenBucket]
    private var _bucketsBySource: [LocalToolSource: [TokenBucket]]
    private var _limitHitEvents: [LimitHitEvent]
    private var _todayUsage: TodayUsageSummary
    private var _selectedTile: DropdownSelection
    private var _statisticsRange: StatisticsRange
    private var _statisticsFilter: StatisticsFilter
    private var _isRefreshing: Bool = false
    private var _isDropdownOpen: Bool = false
    private var _lastRefreshedAt: Date?
    private var _pendingICloudFiles: Int = 0

    private var refreshScheduler: RefreshScheduler?
    private let tokenLogCoordinator: LocalTokenLogCoordinator?
    private let limitHitHistoryStore: LimitHitHistoryStore?
    private var localLogPipeline: LocalLogPipelineController?
    private let watchBackend: (any DirectoryWatchBackend)?
    private let watchScheduler: any DirectoryWatchScheduler
    private let clock: @Sendable () -> Date

    var snapshots: [ProviderSnapshot] {
        accounts.snapshots
    }

    var tokenBuckets: [TokenBucket] {
        if options.isDemo {
            _$observationRegistrar.access(self, keyPath: \.tokenBuckets)
            return _tokenBuckets
        }
        _$observationRegistrar.access(self, keyPath: \.tokenBuckets)
        let enabled = localSources.enabledSources
        return LocalTokenLogCoordinator.activeBuckets(from: _bucketsBySource, enabledSources: enabled)
    }

    var limitHitEvents: [LimitHitEvent] {
        _$observationRegistrar.access(self, keyPath: \.limitHitEvents)
        return _limitHitEvents
    }

    var todayUsage: TodayUsageSummary {
        if options.isDemo {
            _$observationRegistrar.access(self, keyPath: \.todayUsage)
            return _todayUsage
        }
        return StatisticsAggregator.todayUsage(from: tokenBuckets, on: Date())
    }

    var selectedTile: DropdownSelection {
        get {
            _$observationRegistrar.access(self, keyPath: \.selectedTile)
            return _selectedTile
        }
        set {
            _$observationRegistrar.withMutation(of: self, keyPath: \.selectedTile) {
                _selectedTile = newValue
            }
        }
    }

    var statisticsRange: StatisticsRange {
        get {
            _$observationRegistrar.access(self, keyPath: \.statisticsRange)
            return _statisticsRange
        }
        set {
            _$observationRegistrar.withMutation(of: self, keyPath: \.statisticsRange) {
                _statisticsRange = newValue
            }
        }
    }

    var statisticsFilter: StatisticsFilter {
        get {
            _$observationRegistrar.access(self, keyPath: \.statisticsFilter)
            return _statisticsFilter
        }
        set {
            _$observationRegistrar.withMutation(of: self, keyPath: \.statisticsFilter) {
                _statisticsFilter = newValue
            }
        }
    }

    var isRefreshing: Bool {
        _$observationRegistrar.access(self, keyPath: \.isRefreshing)
        return _isRefreshing
    }

    var isDropdownOpen: Bool {
        _$observationRegistrar.access(self, keyPath: \.isDropdownOpen)
        return _isDropdownOpen
    }

    var lastRefreshedAt: Date? {
        _$observationRegistrar.access(self, keyPath: \.lastRefreshedAt)
        return _lastRefreshedAt
    }

    var pendingICloudFiles: Int {
        if options.isDemo {
            return 0
        }
        _$observationRegistrar.access(self, keyPath: \.pendingICloudFiles)
        return _pendingICloudFiles
    }

    init(
        options: LaunchOptions,
        thresholds: ThresholdSettings? = nil,
        localSources: LocalSourceSettings? = nil,
        providers: [any UsageProvider]? = nil,
        tokenLogCoordinator: LocalTokenLogCoordinator? = nil,
        limitHitHistoryStore: LimitHitHistoryStore? = nil,
        watchBackend: (any DirectoryWatchBackend)? = nil,
        watchScheduler: any DirectoryWatchScheduler = DispatchDirectoryWatchScheduler(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.options = options
        self.watchBackend = watchBackend
        self.watchScheduler = watchScheduler
        self.clock = clock
        self.thresholds = thresholds ?? ThresholdSettings.forLaunch(isDemo: options.isDemo)
        self.localSources = localSources ?? LocalSourceSettings.forLaunch(
            isDemo: options.isDemo,
            demoScenario: options.demoScenario
        )
        self._selectedTile = .provider(options.selectedProvider ?? .claude)
        self._statisticsRange = options.statisticsRange
        self._statisticsFilter = options.statisticsFilter

        let resolvedProviders: [any UsageProvider]
        if let providers {
            resolvedProviders = providers
        } else {
            resolvedProviders = UsageProviderRegistry.makeProviders(
                isDemo: options.isDemo,
                demoScenario: options.demoScenario,
                urlOpener: WorkspaceURLOpener()
            )
        }

        let initialSnapshots: [ProviderSnapshot]
        if options.isDemo {
            let buckets = DemoFixtures.tokenBuckets()
            initialSnapshots = DemoFixtures.snapshots(for: options.demoScenario)
            self._tokenBuckets = buckets
            self._bucketsBySource = [:]
            self._limitHitEvents = DemoFixtures.limitHitEvents()
            self._todayUsage = DemoFixtures.todayUsage()
            self._lastRefreshedAt = DemoFixtures.referenceDate
            self.tokenLogCoordinator = nil
            self.limitHitHistoryStore = nil
        } else {
            initialSnapshots = ProviderID.allCases.map {
                ProviderSnapshot(
                    provider: $0,
                    plan: "",
                    connectionState: .notConnected,
                    limits: [],
                    connectedVia: "Not connected"
                )
            }
            let historyStore = limitHitHistoryStore ?? LimitHitHistoryStore(clock: clock)
            self.limitHitHistoryStore = historyStore
            self._tokenBuckets = []
            self._bucketsBySource = [:]
            self._limitHitEvents = historyStore.limitHitEvents(at: clock())
            self._todayUsage = .empty
            self._lastRefreshedAt = nil
            self.tokenLogCoordinator = tokenLogCoordinator ?? LocalTokenLogCoordinator()
        }

        self.accounts = AccountsController(
            isDemo: options.isDemo,
            initialSnapshots: initialSnapshots,
            providers: resolvedProviders
        )

        self.refreshScheduler = RefreshScheduler(
            lastRefreshDate: options.isDemo ? Date() : nil,
            isDropdownOpen: false,
            onRefresh: { [weak self] in
                await self?.refresh()
            }
        )
    }

    func statisticsSummary(now: Date? = nil) -> StatisticsSummary {
        let effectiveNow = now ?? clock()
        let anchorDate = options.isDemo ? DemoFixtures.referenceDate : effectiveNow
        let hasLimitData = hasRealLimitData(for: statisticsFilter, now: anchorDate)
        let events: [LimitHitEvent]
        if options.isDemo {
            events = limitHitEvents
        } else {
            _ = limitHitEvents
            events = limitHitHistoryStore?.limitHitEvents(at: anchorDate) ?? []
        }
        return StatisticsAggregator.summarize(
            buckets: tokenBuckets,
            limitHits: events,
            limitsHitAvailable: hasLimitData,
            range: statisticsRange,
            filter: statisticsFilter,
            anchorDate: anchorDate
        )
    }

    private func hasRealLimitData(for filter: StatisticsFilter, now: Date) -> Bool {
        if options.isDemo {
            return true
        }
        guard let historyStore = limitHitHistoryStore else {
            return false
        }
        let connectedProviders = snapshots
            .filter { $0.connectionState == .connected }
            .map(\.provider)
        return historyStore.hasSufficientCoverage(
            for: filter,
            connectedProviders: connectedProviders,
            range: statisticsRange,
            at: now
        )
    }

    func updatedAgoText(now: Date = Date()) -> String {
        if options.isDemo {
            return TokenFormatter.updatedAgoText(from: lastRefreshedAt ?? DemoFixtures.referenceDate, now: DemoFixtures.referenceNow)
        }
        return TokenFormatter.updatedAgoText(from: lastRefreshedAt, now: now)
    }

    func snapshot(for provider: ProviderID) -> ProviderSnapshot {
        accounts.snapshot(for: provider)
    }

    func startRefreshScheduler() {
        if !options.isDemo {
            startLocalLogPipeline()
        }
        refreshScheduler?.start()
    }

    func toggleLocalSource(_ source: LocalToolSource) {
        localSources.toggle(source)
        guard !options.isDemo else { return }
        let isNowEnabled = localSources.isEnabled(source)
        let pipeline = ensureLocalLogPipeline()
        pipeline?.syncEnabledSources()
        Task { [weak self] in
            guard let self else { return }
            let activePipeline = self.ensureLocalLogPipeline()
            await activePipeline?.handleSourceToggled(isNowEnabled: isNowEnabled)
        }
    }

    func setDropdownOpen(_ isOpen: Bool) {
        guard _isDropdownOpen != isOpen else { return }
        _$observationRegistrar.withMutation(of: self, keyPath: \.isDropdownOpen) {
            _isDropdownOpen = isOpen
        }
        refreshScheduler?.setDropdownOpen(isOpen)
    }

    func refresh() async {
        _$observationRegistrar.withMutation(of: self, keyPath: \.isRefreshing) {
            _isRefreshing = true
        }
        defer {
            _$observationRegistrar.withMutation(of: self, keyPath: \.isRefreshing) {
                _isRefreshing = false
            }
        }

        await accounts.refreshAll()
        let now = clock()
        if !options.isDemo {
            if let historyStore = limitHitHistoryStore {
                _ = historyStore.observe(snapshots: accounts.snapshots, at: now)
                let updatedEvents = historyStore.limitHitEvents(at: now)
                _$observationRegistrar.withMutation(of: self, keyPath: \.limitHitEvents) {
                    _limitHitEvents = updatedEvents
                }
            }
            let pipeline = ensureLocalLogPipeline()
            await pipeline?.refreshLogs()
        }

        _$observationRegistrar.withMutation(of: self, keyPath: \.lastRefreshedAt) {
            _lastRefreshedAt = options.isDemo ? DemoFixtures.referenceDate : now
        }
        refreshScheduler?.recordRefresh(at: now)
    }

    private func startLocalLogPipeline() {
        ensureLocalLogPipeline()?.start()
    }

    private func ensureLocalLogPipeline() -> LocalLogPipelineController? {
        guard !options.isDemo, let coordinator = tokenLogCoordinator else { return nil }
        if let existing = localLogPipeline {
            return existing
        }
        let controller = LocalLogPipelineController(
            coordinator: coordinator,
            debounceInterval: 0.75,
            watchBackend: watchBackend,
            watchScheduler: watchScheduler,
            enabledSources: { [weak self] in
                self?.enabledToolSourceSet() ?? []
            },
            onBucketsUpdated: { [weak self] updated, refreshedAt in
                guard let self else { return }
                self.applyLocalLogBuckets(updated)
                if let refreshedAt {
                    self._$observationRegistrar.withMutation(of: self, keyPath: \.lastRefreshedAt) {
                        self._lastRefreshedAt = refreshedAt
                    }
                }
            },
            onPendingICloudFilesChanged: { [weak self] pendingCount in
                guard let self, !self.options.isDemo else { return }
                let clamped = max(0, pendingCount)
                guard self._pendingICloudFiles != clamped else { return }
                self._$observationRegistrar.withMutation(of: self, keyPath: \.pendingICloudFiles) {
                    self._pendingICloudFiles = clamped
                }
            }
        )
        localLogPipeline = controller
        return controller
    }

    private func applyLocalLogBuckets(_ updatedBySource: [LocalToolSource: [TokenBucket]]) {
        var merged = _bucketsBySource
        for (source, buckets) in updatedBySource {
            merged[source] = buckets
        }
        _$observationRegistrar.withMutation(of: self, keyPath: \.tokenBuckets) {
            _bucketsBySource = merged
        }
        _$observationRegistrar.withMutation(of: self, keyPath: \.todayUsage) {
            _todayUsage = StatisticsAggregator.todayUsage(
                from: LocalTokenLogCoordinator.activeBuckets(from: merged, enabledSources: localSources.enabledSources),
                on: Date()
            )
        }
    }

    private func enabledToolSourceSet() -> Set<LocalToolSource> {
        Set(LocalToolSource.allCases.filter { localSources.isEnabled($0) })
    }
}
