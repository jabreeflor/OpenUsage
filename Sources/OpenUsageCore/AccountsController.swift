import Foundation
import Observation

public protocol AccountsSleeper: Sendable {
    func sleep(for duration: Duration) async throws
}

public struct ContinuousAccountsSleeper: AccountsSleeper {
    public init() {}

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

/// Owns the per-provider account connection state machine (`notConnected` / `expired` → `connecting` → `connected`,
/// `connected` → `notConnected` on sign out) and bridges both demo timing and live `UsageProvider` sign-in hooks.
@MainActor
public final class AccountsController: Observable {
    public static let demoSignInDuration: Duration = .milliseconds(2500)
    public static let demoInitialConnectingDuration: Duration = .milliseconds(6000)

    private struct InFlightOperation {
        let generation: UInt64
        let task: Task<Void, Never>
    }

    private let _$observationRegistrar = ObservationRegistrar()

    public let isDemo: Bool
    private let providersByID: [ProviderID: any UsageProvider]
    private let sleeper: any AccountsSleeper
    private let signInDuration: Duration
    private let initialConnectingDuration: Duration

    private var _snapshots: [ProviderSnapshot]
    private var providerGenerations: [ProviderID: UInt64] = [:]
    private var inFlightOperations: [ProviderID: InFlightOperation] = [:]

    public var snapshots: [ProviderSnapshot] {
        _$observationRegistrar.access(self, keyPath: \.snapshots)
        return _snapshots
    }

    public init(
        isDemo: Bool,
        initialSnapshots: [ProviderSnapshot],
        providers: [any UsageProvider],
        sleeper: any AccountsSleeper = ContinuousAccountsSleeper(),
        signInDuration: Duration = AccountsController.demoSignInDuration,
        initialConnectingDuration: Duration = AccountsController.demoInitialConnectingDuration
    ) {
        self.isDemo = isDemo
        self.providersByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.provider, $0) })
        self.sleeper = sleeper
        self.signInDuration = signInDuration
        self.initialConnectingDuration = initialConnectingDuration

        let byID = Dictionary(uniqueKeysWithValues: initialSnapshots.map { ($0.provider, $0) })
        self._snapshots = ProviderID.allCases.map { id in
            byID[id] ?? ProviderSnapshot(
                provider: id,
                plan: "",
                connectionState: .notConnected,
                limits: [],
                connectedVia: "Not connected"
            )
        }

        if isDemo {
            for snapshot in _snapshots where snapshot.connectionState == .connecting {
                scheduleDemoCompletion(for: snapshot.provider, duration: initialConnectingDuration)
            }
        }
    }

    public func snapshot(for provider: ProviderID) -> ProviderSnapshot {
        snapshots.first(where: { $0.provider == provider }) ?? ProviderSnapshot(
            provider: provider,
            plan: "",
            connectionState: .notConnected,
            limits: [],
            connectedVia: "Not connected"
        )
    }

    /// Starts sign-in (or reconnect) for `provider`.
    /// - Valid entry states: `.notConnected`, `.expired`, `.unsupported`.
    /// - Transitions immediately to `.connecting` ("Finish signing in in your browser").
    ///   First-time sign-in from Off omits the menu bar entry until connected; Reconnect from `.expired` retains `--`.
    /// - In demo mode: waits `signInDuration` (~2.5 s) via `sleeper`, then finishes in `.connected` with fixture data.
    /// - Outside demo mode: invokes `UsageProvider.signIn()` and applies its returned snapshot.
    @discardableResult
    public func signIn(_ provider: ProviderID) -> Task<Void, Never>? {
        let current = _snapshots.first(where: { $0.provider == provider })
        let currentState = current?.connectionState ?? .notConnected

        guard currentState == .notConnected || currentState == .expired || currentState == .unsupported else {
            return nil
        }

        let generation = beginOperation(for: provider)

        let preservedPlan = current?.plan ?? ""
        let retainMenuBarSlot = (currentState == .expired)
        let connectingSnapshot = ProviderSnapshot(
            provider: provider,
            plan: preservedPlan,
            connectionState: .connecting,
            limits: [],
            connectedVia: "Finish signing in in your browser",
            updatedAt: isDemo ? DemoFixtures.referenceDate : Date(),
            showMenuBarPlaceholderWhileConnecting: retainMenuBarSlot
        )
        replaceSnapshot(connectingSnapshot)

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performSignIn(for: provider, generation: generation)
        }
        inFlightOperations[provider] = InFlightOperation(generation: generation, task: task)
        return task
    }

    /// Signs out `provider`, cancelling any in-flight sign-in and transitioning immediately to `.notConnected`.
    @discardableResult
    public func signOut(_ provider: ProviderID) -> Task<Void, Never>? {
        let currentState = _snapshots.first(where: { $0.provider == provider })?.connectionState ?? .notConnected
        guard currentState != .notConnected else {
            return nil
        }

        let generation = beginOperation(for: provider)

        let signedOutSnapshot = ProviderSnapshot(
            provider: provider,
            plan: "",
            connectionState: .notConnected,
            limits: [],
            connectedVia: "Not connected",
            updatedAt: isDemo ? DemoFixtures.referenceDate : Date()
        )
        replaceSnapshot(signedOutSnapshot)

        guard !isDemo, let usageProvider = providersByID[provider] else {
            return nil
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performSignOut(for: provider, usageProvider: usageProvider, generation: generation)
        }
        inFlightOperations[provider] = InFlightOperation(generation: generation, task: task)
        return task
    }

    /// Refreshes provider snapshots without clobbering in-flight account actions or user-driven demo state.
    public func refreshAll() async {
        if isDemo {
            let nextSnapshots = _snapshots.map { existing -> ProviderSnapshot in
                switch existing.connectionState {
                case .connected:
                    return DemoFixtures.snapshot(for: existing.provider, scenario: .all)
                case .expired, .notConnected, .connecting, .unsupported:
                    return existing
                }
            }
            _$observationRegistrar.withMutation(of: self, keyPath: \.snapshots) {
                _snapshots = nextSnapshots
            }
            return
        }

        let currentByID = Dictionary(uniqueKeysWithValues: _snapshots.map { ($0.provider, $0) })
        var refreshGenerations: [ProviderID: UInt64] = [:]
        var providersToFetch: [any UsageProvider] = []

        for id in ProviderID.allCases {
            guard inFlightOperations[id] == nil else {
                continue
            }
            if let state = currentByID[id]?.connectionState,
               state == .connecting || state == .unsupported {
                continue
            }
            guard let provider = providersByID[id] else {
                continue
            }
            refreshGenerations[id] = advanceGeneration(for: id)
            providersToFetch.append(provider)
        }

        guard !providersToFetch.isEmpty else { return }

        var fetched: [ProviderID: ProviderSnapshot] = [:]
        await withTaskGroup(of: ProviderSnapshot?.self) { group in
            for provider in providersToFetch {
                group.addTask {
                    try? await provider.fetchSnapshot()
                }
            }
            for await snapshot in group {
                if let snapshot {
                    fetched[snapshot.provider] = snapshot
                }
            }
        }

        let nextSnapshots = ProviderID.allCases.compactMap { id -> ProviderSnapshot? in
            let existing = _snapshots.first(where: { $0.provider == id })
            guard let expectedGeneration = refreshGenerations[id],
                  isCurrentOperation(expectedGeneration, for: id),
                  let fresh = fetched[id] else {
                return existing
            }
            return fresh
        }

        _$observationRegistrar.withMutation(of: self, keyPath: \.snapshots) {
            _snapshots = nextSnapshots
        }
    }

    public func cancelAll() {
        for operation in inFlightOperations.values {
            operation.task.cancel()
        }
        inFlightOperations.removeAll()
        for id in ProviderID.allCases {
            _ = advanceGeneration(for: id)
        }
    }

    // MARK: - Private

    @discardableResult
    private func advanceGeneration(for provider: ProviderID) -> UInt64 {
        let next = (providerGenerations[provider] ?? 0) &+ 1
        providerGenerations[provider] = next
        return next
    }

    @discardableResult
    private func beginOperation(for provider: ProviderID) -> UInt64 {
        inFlightOperations[provider]?.task.cancel()
        inFlightOperations[provider] = nil
        return advanceGeneration(for: provider)
    }

    private func isCurrentOperation(_ generation: UInt64, for provider: ProviderID) -> Bool {
        providerGenerations[provider] == generation
    }

    private func clearTaskIfCurrent(_ generation: UInt64, for provider: ProviderID) {
        if inFlightOperations[provider]?.generation == generation {
            inFlightOperations[provider] = nil
        }
    }

    private func scheduleDemoCompletion(for provider: ProviderID, duration: Duration) {
        let generation = beginOperation(for: provider)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performDemoCompletion(for: provider, duration: duration, generation: generation)
        }
        inFlightOperations[provider] = InFlightOperation(generation: generation, task: task)
    }

    private func performDemoCompletion(for provider: ProviderID, duration: Duration, generation: UInt64) async {
        defer {
            clearTaskIfCurrent(generation, for: provider)
        }

        do {
            try await sleeper.sleep(for: duration)
        } catch {
            return
        }
        guard !Task.isCancelled, isCurrentOperation(generation, for: provider) else { return }
        let connected = DemoFixtures.snapshot(for: provider, scenario: .all)
        replaceSnapshot(connected)
    }

    private func performSignIn(for provider: ProviderID, generation: UInt64) async {
        defer {
            clearTaskIfCurrent(generation, for: provider)
        }

        if isDemo {
            do {
                try await sleeper.sleep(for: signInDuration)
            } catch {
                return
            }
            guard !Task.isCancelled, isCurrentOperation(generation, for: provider) else { return }
            let connected = DemoFixtures.snapshot(for: provider, scenario: .all)
            replaceSnapshot(connected)
            return
        }

        guard let usageProvider = providersByID[provider] else {
            guard !Task.isCancelled, isCurrentOperation(generation, for: provider) else { return }
            replaceSnapshot(
                ProviderSnapshot(
                    provider: provider,
                    plan: "",
                    connectionState: .unsupported,
                    limits: [],
                    connectedVia: "Sign-in is not yet supported"
                )
            )
            return
        }

        do {
            let result = try await usageProvider.signIn()
            guard !Task.isCancelled, isCurrentOperation(generation, for: provider) else { return }
            replaceSnapshot(result)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, isCurrentOperation(generation, for: provider) else { return }
            replaceSnapshot(
                ProviderSnapshot(
                    provider: provider,
                    plan: "",
                    connectionState: .notConnected,
                    limits: [],
                    connectedVia: "Sign-in failed"
                )
            )
        }
    }

    private func performSignOut(
        for provider: ProviderID,
        usageProvider: any UsageProvider,
        generation: UInt64
    ) async {
        defer {
            clearTaskIfCurrent(generation, for: provider)
        }

        do {
            let result = try await usageProvider.signOut()
            guard !Task.isCancelled, isCurrentOperation(generation, for: provider) else { return }
            replaceSnapshot(result)
        } catch {
            // Keep the disconnected snapshot already applied synchronously.
        }
    }

    private func replaceSnapshot(_ snapshot: ProviderSnapshot) {
        var next = _snapshots
        if let index = next.firstIndex(where: { $0.provider == snapshot.provider }) {
            next[index] = snapshot
        } else {
            next.append(snapshot)
        }
        _$observationRegistrar.withMutation(of: self, keyPath: \.snapshots) {
            _snapshots = next
        }
    }
}
