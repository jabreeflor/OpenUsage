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
    private let providers: [any UsageProvider]

    private var _snapshots: [ProviderSnapshot]
    private var _todayUsage: TodayUsageSummary
    private var _selectedTile: DropdownSelection
    private var _isRefreshing: Bool = false
    private var _isDropdownOpen: Bool = false
    private var _lastRefreshedAt: Date?

    private var refreshScheduler: RefreshScheduler?

    var snapshots: [ProviderSnapshot] {
        _$observationRegistrar.access(self, keyPath: \.snapshots)
        return _snapshots
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
        providers: [any UsageProvider]? = nil
    ) {
        self.options = options
        self.thresholds = thresholds ?? ThresholdSettings.forLaunch(isDemo: options.isDemo)
        self._selectedTile = .provider(options.selectedProvider ?? .claude)

        if let providers {
            self.providers = providers
        } else if options.isDemo {
            self.providers = DemoFixtures.providers(for: options.demoScenario)
        } else {
            self.providers = ProviderID.allCases.map { UnconfiguredUsageProvider(provider: $0) }
        }

        if options.isDemo {
            self._snapshots = DemoFixtures.snapshots(for: options.demoScenario)
            self._todayUsage = DemoFixtures.todayUsage()
            self._lastRefreshedAt = DemoFixtures.referenceDate
        } else {
            self._snapshots = ProviderID.allCases.map {
                ProviderSnapshot(
                    provider: $0,
                    plan: "",
                    connectionState: .notConnected,
                    limits: [],
                    connectedVia: "Not connected"
                )
            }
            self._todayUsage = .empty
            self._lastRefreshedAt = nil
        }
        self.refreshScheduler = RefreshScheduler(
            lastRefreshDate: options.isDemo ? Date() : nil,
            isDropdownOpen: false,
            onRefresh: { [weak self] in
                await self?.refresh()
            }
        )
    }

    func updatedAgoText(now: Date = Date()) -> String {
        if options.isDemo {
            return TokenFormatter.updatedAgoText(from: lastRefreshedAt ?? DemoFixtures.referenceDate, now: DemoFixtures.referenceNow)
        }
        return TokenFormatter.updatedAgoText(from: lastRefreshedAt, now: now)
    }

    func snapshot(for provider: ProviderID) -> ProviderSnapshot {
        snapshots.first(where: { $0.provider == provider }) ?? ProviderSnapshot(
            provider: provider,
            plan: "",
            connectionState: .notConnected,
            limits: [],
            connectedVia: "Not connected"
        )
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

        var updated: [ProviderID: ProviderSnapshot] = [:]
        await withTaskGroup(of: ProviderSnapshot?.self) { group in
            for provider in providers {
                group.addTask {
                    try? await provider.fetchSnapshot()
                }
            }
            for await snapshot in group {
                if let snapshot {
                    updated[snapshot.provider] = snapshot
                }
            }
        }

        let nextSnapshots = ProviderID.allCases.compactMap { id in
            updated[id] ?? _snapshots.first(where: { $0.provider == id })
        }
        _$observationRegistrar.withMutation(of: self, keyPath: \.snapshots) {
            _snapshots = nextSnapshots
        }
        let now = Date()
        _$observationRegistrar.withMutation(of: self, keyPath: \.lastRefreshedAt) {
            _lastRefreshedAt = options.isDemo ? DemoFixtures.referenceDate : now
        }
        refreshScheduler?.recordRefresh(at: now)
    }
}
