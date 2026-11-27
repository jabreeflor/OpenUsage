import Foundation
import Observation
import OpenUsageCore

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
    private var _limitHitEvents: [LimitHitEvent]
    private var _todayUsage: TodayUsageSummary
    private var _selectedTile: DropdownSelection
    private var _statisticsRange: StatisticsRange
    private var _statisticsFilter: StatisticsFilter
    private var _isRefreshing: Bool = false
    private var _isDropdownOpen: Bool = false
    private var _lastRefreshedAt: Date?

    private var refreshScheduler: RefreshScheduler?

    var snapshots: [ProviderSnapshot] {
        accounts.snapshots
    }

    var tokenBuckets: [TokenBucket] {
        _$observationRegistrar.access(self, keyPath: \.tokenBuckets)
        return _tokenBuckets
    }

    var limitHitEvents: [LimitHitEvent] {
        _$observationRegistrar.access(self, keyPath: \.limitHitEvents)
        return _limitHitEvents
    }

    var todayUsage: TodayUsageSummary {
        _$observationRegistrar.access(self, keyPath: \.todayUsage)
        return _todayUsage
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

    init(
        options: LaunchOptions,
        thresholds: ThresholdSettings? = nil,
        localSources: LocalSourceSettings? = nil,
        providers: [any UsageProvider]? = nil
    ) {
        self.options = options
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
        } else if options.isDemo {
            resolvedProviders = DemoFixtures.providers(for: options.demoScenario)
        } else {
            resolvedProviders = ProviderID.allCases.map { UnconfiguredUsageProvider(provider: $0) }
        }

        let initialSnapshots: [ProviderSnapshot]
        if options.isDemo {
            let buckets = DemoFixtures.tokenBuckets()
            initialSnapshots = DemoFixtures.snapshots(for: options.demoScenario)
            self._tokenBuckets = buckets
            self._limitHitEvents = DemoFixtures.limitHitEvents()
            self._todayUsage = DemoFixtures.todayUsage()
            self._lastRefreshedAt = DemoFixtures.referenceDate
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
            self._tokenBuckets = []
            self._limitHitEvents = []
            self._todayUsage = .empty
            self._lastRefreshedAt = nil
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

    func statisticsSummary(now: Date = Date()) -> StatisticsSummary {
        let anchorDate = options.isDemo ? DemoFixtures.referenceDate : now
        return StatisticsAggregator.summarize(
            buckets: tokenBuckets,
            limitHits: limitHitEvents,
            range: statisticsRange,
            filter: statisticsFilter,
            anchorDate: anchorDate
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
        refreshScheduler?.start()
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

        let now = Date()
        _$observationRegistrar.withMutation(of: self, keyPath: \.lastRefreshedAt) {
            _lastRefreshedAt = options.isDemo ? DemoFixtures.referenceDate : now
        }
        refreshScheduler?.recordRefresh(at: now)
    }
}
