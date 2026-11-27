import Foundation
import Observation
import OpenUsageCore

@MainActor
final class AppStore: Observable {
    private let _$observationRegistrar = ObservationRegistrar()

    let options: LaunchOptions
    let thresholds: ThresholdSettings
    private let providers: [any UsageProvider]

    private var _snapshots: [ProviderSnapshot]
    private var _isRefreshing: Bool = false

    var snapshots: [ProviderSnapshot] {
        _$observationRegistrar.access(self, keyPath: \.snapshots)
        return _snapshots
    }

    var isRefreshing: Bool {
        _$observationRegistrar.access(self, keyPath: \.isRefreshing)
        return _isRefreshing
    }

    init(
        options: LaunchOptions,
        thresholds: ThresholdSettings? = nil,
        providers: [any UsageProvider]? = nil
    ) {
        self.options = options
        self.thresholds = thresholds ?? ThresholdSettings.forLaunch(isDemo: options.isDemo)

        if let providers {
            self.providers = providers
        } else if options.isDemo {
            self.providers = DemoFixtures.providers(for: options.demoScenario)
        } else {
            self.providers = ProviderID.allCases.map { UnconfiguredUsageProvider(provider: $0) }
        }

        if options.isDemo {
            self._snapshots = DemoFixtures.snapshots(for: options.demoScenario)
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
        }
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
    }
}
