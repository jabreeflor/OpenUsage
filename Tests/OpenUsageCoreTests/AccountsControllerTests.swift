import Foundation
import XCTest
@testable import OpenUsageCore

private actor ControllableSleeper: AccountsSleeper {
    private struct PendingSleep {
        let id: Int
        let duration: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private var nextID = 1
    private(set) var recordedDurations: [Duration] = []
    private var pendingSleeps: [PendingSleep] = []
    private var countWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func sleep(for duration: Duration) async throws {
        let id = nextID
        nextID += 1
        recordedDurations.append(duration)
        notifyCountWaiters()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    pendingSleeps.append(PendingSleep(id: id, duration: duration, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelSleep(id: id) }
        }
    }

    func waitUntilSleepCount(_ count: Int) async {
        if recordedDurations.count >= count {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if recordedDurations.count >= count {
                continuation.resume()
            } else {
                countWaiters.append((count, continuation))
            }
        }
    }

    func resumeFirst(matching duration: Duration? = nil) {
        let index: Int?
        if let duration {
            index = pendingSleeps.firstIndex(where: { $0.duration == duration })
        } else {
            index = pendingSleeps.isEmpty ? nil : 0
        }
        guard let index else { return }
        let entry = pendingSleeps.remove(at: index)
        entry.continuation.resume()
    }

    func resumeAll() {
        let pending = pendingSleeps
        pendingSleeps.removeAll()
        for entry in pending {
            entry.continuation.resume()
        }
    }

    private func notifyCountWaiters() {
        var remaining: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in countWaiters {
            if recordedDurations.count >= waiter.target {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        countWaiters = remaining
    }

    private func cancelSleep(id: Int) {
        guard let index = pendingSleeps.firstIndex(where: { $0.id == id }) else { return }
        let entry = pendingSleeps.remove(at: index)
        entry.continuation.resume(throwing: CancellationError())
    }
}

private actor DelayedUsageProvider: UsageProvider {
    let provider: ProviderID

    private var fetchContinuations: [CheckedContinuation<ProviderSnapshot, Error>] = []
    private var signInContinuations: [CheckedContinuation<ProviderSnapshot, Error>] = []
    private var signOutContinuations: [CheckedContinuation<ProviderSnapshot, Error>] = []

    private var fetchWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var signInWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var signOutWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    private(set) var fetchCallCount = 0
    private(set) var signInCallCount = 0
    private(set) var signOutCallCount = 0

    init(provider: ProviderID) {
        self.provider = provider
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        fetchCallCount += 1
        resumeWaiters(&fetchWaiters, count: fetchCallCount)
        return try await withCheckedThrowingContinuation { continuation in
            fetchContinuations.append(continuation)
        }
    }

    func signIn() async throws -> ProviderSnapshot {
        signInCallCount += 1
        resumeWaiters(&signInWaiters, count: signInCallCount)
        return try await withCheckedThrowingContinuation { continuation in
            signInContinuations.append(continuation)
        }
    }

    func signOut() async throws -> ProviderSnapshot {
        signOutCallCount += 1
        resumeWaiters(&signOutWaiters, count: signOutCallCount)
        return try await withCheckedThrowingContinuation { continuation in
            signOutContinuations.append(continuation)
        }
    }

    func waitForFetchCalls(_ count: Int) async {
        if fetchCallCount >= count { return }
        await withCheckedContinuation { continuation in
            if fetchCallCount >= count {
                continuation.resume()
            } else {
                fetchWaiters.append((count, continuation))
            }
        }
    }

    func waitForSignInCalls(_ count: Int) async {
        if signInCallCount >= count { return }
        await withCheckedContinuation { continuation in
            if signInCallCount >= count {
                continuation.resume()
            } else {
                signInWaiters.append((count, continuation))
            }
        }
    }

    func waitForSignOutCalls(_ count: Int) async {
        if signOutCallCount >= count { return }
        await withCheckedContinuation { continuation in
            if signOutCallCount >= count {
                continuation.resume()
            } else {
                signOutWaiters.append((count, continuation))
            }
        }
    }

    func resolveNextFetch(_ snapshot: ProviderSnapshot) {
        guard !fetchContinuations.isEmpty else { return }
        fetchContinuations.removeFirst().resume(returning: snapshot)
    }

    func resolveNextSignIn(_ snapshot: ProviderSnapshot) {
        guard !signInContinuations.isEmpty else { return }
        signInContinuations.removeFirst().resume(returning: snapshot)
    }

    func resolveNextSignOut(_ snapshot: ProviderSnapshot) {
        guard !signOutContinuations.isEmpty else { return }
        signOutContinuations.removeFirst().resume(returning: snapshot)
    }

    private func resumeWaiters(
        _ waiters: inout [(Int, CheckedContinuation<Void, Never>)],
        count: Int
    ) {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for (target, continuation) in waiters {
            if count >= target {
                continuation.resume()
            } else {
                remaining.append((target, continuation))
            }
        }
        waiters = remaining
    }
}

private actor StubUsageProvider: UsageProvider {
    let provider: ProviderID
    private(set) var signInCalls = 0
    private(set) var signOutCalls = 0
    private let connectedSnapshot: ProviderSnapshot

    init(provider: ProviderID, connectedSnapshot: ProviderSnapshot) {
        self.provider = provider
        self.connectedSnapshot = connectedSnapshot
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        ProviderSnapshot(
            provider: provider,
            plan: "",
            connectionState: .notConnected,
            limits: [],
            connectedVia: "Not connected"
        )
    }

    func signIn() async throws -> ProviderSnapshot {
        signInCalls += 1
        return connectedSnapshot
    }

    func signOut() async throws -> ProviderSnapshot {
        signOutCalls += 1
        return ProviderSnapshot(
            provider: provider,
            plan: "",
            connectionState: .notConnected,
            limits: [],
            connectedVia: "Not connected"
        )
    }
}

@MainActor
final class AccountsControllerTests: XCTestCase {
    func testDemoSignInFromNotConnectedTransitionsThroughConnectingToConnected() async {
        let sleeper = ControllableSleeper()
        let controller = AccountsController(
            isDemo: true,
            initialSnapshots: DemoFixtures.snapshots(for: .disconnected),
            providers: DemoFixtures.providers(for: .disconnected),
            sleeper: sleeper
        )
        defer { controller.cancelAll() }

        XCTAssertEqual(controller.snapshot(for: .opencode).connectionState, .notConnected)
        XCTAssertEqual(controller.snapshot(for: .opencode).menuBarEntryState, .omitted)

        let task = controller.signIn(.opencode)
        XCTAssertNotNil(task)

        // Immediately transitions to connecting while remaining omitted from the menu bar until connected
        let connecting = controller.snapshot(for: .opencode)
        XCTAssertEqual(connecting.connectionState, .connecting)
        XCTAssertEqual(connecting.connectedVia, "Finish signing in in your browser")
        XCTAssertEqual(connecting.menuBarEntryState, .omitted)

        // Duplicate sign-in while already connecting is ignored
        XCTAssertNil(controller.signIn(.opencode))

        await sleeper.waitUntilSleepCount(1)
        let durations = await sleeper.recordedDurations
        XCTAssertEqual(durations, [AccountsController.demoSignInDuration])

        await sleeper.resumeFirst(matching: AccountsController.demoSignInDuration)
        await task?.value

        let connected = controller.snapshot(for: .opencode)
        XCTAssertEqual(connected.connectionState, .connected)
        XCTAssertEqual(connected.plan, "Go")
        XCTAssertEqual(connected.limits.map(\.name), ["5-hour", "Weekly", "Monthly"])
        XCTAssertEqual(connected.fullestLimit?.percentUsed, 42)
        XCTAssertEqual(connected.connectedVia, "Signed in with OpenCode")
        XCTAssertEqual(connected.menuBarEntryState, .connected(percent: 42))
    }

    func testDemoReconnectFromExpiredTransitionsThroughConnectingToConnected() async {
        let sleeper = ControllableSleeper()
        let controller = AccountsController(
            isDemo: true,
            initialSnapshots: DemoFixtures.snapshots(for: .disconnected),
            providers: DemoFixtures.providers(for: .disconnected),
            sleeper: sleeper
        )
        defer { controller.cancelAll() }

        XCTAssertEqual(controller.snapshot(for: .gemini).connectionState, .expired)
        XCTAssertEqual(controller.snapshot(for: .gemini).plan, "Google AI Pro")
        XCTAssertEqual(controller.snapshot(for: .gemini).menuBarEntryState, .dimmedPlaceholder)

        let task = controller.signIn(.gemini)
        XCTAssertNotNil(task)

        // Reconnect retains the existing dimmed "--" slot in the menu bar while connecting
        let connecting = controller.snapshot(for: .gemini)
        XCTAssertEqual(connecting.connectionState, .connecting)
        XCTAssertEqual(connecting.plan, "Google AI Pro")
        XCTAssertEqual(connecting.connectedVia, "Finish signing in in your browser")
        XCTAssertEqual(connecting.menuBarEntryState, .dimmedPlaceholder)

        await sleeper.waitUntilSleepCount(1)
        await sleeper.resumeFirst(matching: AccountsController.demoSignInDuration)
        await task?.value

        let connected = controller.snapshot(for: .gemini)
        XCTAssertEqual(connected.connectionState, .connected)
        XCTAssertEqual(connected.plan, "Google AI Pro")
        XCTAssertEqual(connected.fullestLimit?.percentUsed, 21)
        XCTAssertEqual(connected.connectedVia, "Signed in with Google")
        XCTAssertEqual(connected.menuBarEntryState, .connected(percent: 21))
    }

    func testDemoConnectingScenarioAutoCompletesInitialGeminiAfterDelay() async {
        let sleeper = ControllableSleeper()
        let controller = AccountsController(
            isDemo: true,
            initialSnapshots: DemoFixtures.snapshots(for: .connecting),
            providers: DemoFixtures.providers(for: .connecting),
            sleeper: sleeper
        )
        defer { controller.cancelAll() }

        // Starts at still 06: Gemini connecting with dimmed placeholder, OpenCode off and omitted
        XCTAssertEqual(controller.snapshot(for: .gemini).connectionState, .connecting)
        XCTAssertEqual(controller.snapshot(for: .gemini).plan, "Google AI Pro")
        XCTAssertEqual(controller.snapshot(for: .gemini).menuBarEntryState, .dimmedPlaceholder)
        XCTAssertEqual(controller.snapshot(for: .opencode).connectionState, .notConnected)
        XCTAssertEqual(controller.snapshot(for: .opencode).menuBarEntryState, .omitted)

        await sleeper.waitUntilSleepCount(1)
        let durations = await sleeper.recordedDurations
        XCTAssertEqual(durations, [AccountsController.demoInitialConnectingDuration])
        XCTAssertGreaterThan(
            AccountsController.demoInitialConnectingDuration,
            AccountsController.demoSignInDuration
        )

        // Refresh while waiting preserves the still-06 connecting state
        await controller.refreshAll()
        XCTAssertEqual(controller.snapshot(for: .gemini).connectionState, .connecting)

        // Advancing the demo delay completes Gemini to Google AI Pro · 21% · Connected
        await sleeper.resumeFirst(matching: AccountsController.demoInitialConnectingDuration)
        for _ in 0..<20 where controller.snapshot(for: .gemini).connectionState != .connected {
            await Task.yield()
        }

        let gemini = controller.snapshot(for: .gemini)
        XCTAssertEqual(gemini.connectionState, .connected)
        XCTAssertEqual(gemini.plan, "Google AI Pro")
        XCTAssertEqual(gemini.fullestLimit?.percentUsed, 21)
        XCTAssertEqual(gemini.connectedVia, "Signed in with Google")
        XCTAssertEqual(gemini.menuBarEntryState, .connected(percent: 21))
    }

    func testDemoSignOutTransitionsToNotConnectedAndCancelsInFlightSignIn() async {
        let sleeper = ControllableSleeper()
        let controller = AccountsController(
            isDemo: true,
            initialSnapshots: DemoFixtures.snapshots(for: .connecting),
            providers: DemoFixtures.providers(for: .connecting),
            sleeper: sleeper
        )
        defer { controller.cancelAll() }

        // Wait for initial Gemini auto-complete sleep to register
        await sleeper.waitUntilSleepCount(1)

        // Sign out an already connected provider
        XCTAssertEqual(controller.snapshot(for: .claude).connectionState, .connected)
        _ = controller.signOut(.claude)
        let signedOutClaude = controller.snapshot(for: .claude)
        XCTAssertEqual(signedOutClaude.connectionState, .notConnected)
        XCTAssertEqual(signedOutClaude.plan, "")
        XCTAssertTrue(signedOutClaude.limits.isEmpty)
        XCTAssertEqual(signedOutClaude.connectedVia, "Not connected")
        XCTAssertEqual(signedOutClaude.menuBarEntryState, .omitted)

        // Sign out while sign-in is in flight cancels the pending completion
        let task = controller.signIn(.opencode)
        await sleeper.waitUntilSleepCount(2)
        XCTAssertEqual(controller.snapshot(for: .opencode).connectionState, .connecting)
        XCTAssertEqual(controller.snapshot(for: .opencode).menuBarEntryState, .omitted)

        _ = controller.signOut(.opencode)
        await task?.value

        XCTAssertEqual(controller.snapshot(for: .opencode).connectionState, .notConnected)
        XCTAssertEqual(controller.snapshot(for: .opencode).menuBarEntryState, .omitted)
    }

    func testDemoRefreshPreservesUserDrivenConnectionState() async {
        let sleeper = ControllableSleeper()
        let controller = AccountsController(
            isDemo: true,
            initialSnapshots: DemoFixtures.snapshots(for: .connecting),
            providers: DemoFixtures.providers(for: .connecting),
            sleeper: sleeper
        )
        defer { controller.cancelAll() }

        // Wait for initial Gemini connecting sleep
        await sleeper.waitUntilSleepCount(1)

        // Sign in OpenCode (leaves Gemini's 6s initial sleep still pending) and sign out Claude
        let task = controller.signIn(.opencode)
        await sleeper.waitUntilSleepCount(2)
        await sleeper.resumeFirst(matching: AccountsController.demoSignInDuration)
        await task?.value
        _ = controller.signOut(.claude)

        // Periodic refresh must not revert demo account changes or Gemini's pending connecting state
        await controller.refreshAll()

        XCTAssertEqual(controller.snapshot(for: .opencode).connectionState, .connected)
        XCTAssertEqual(controller.snapshot(for: .opencode).fullestLimit?.percentUsed, 42)
        XCTAssertEqual(controller.snapshot(for: .claude).connectionState, .notConnected)
        XCTAssertEqual(controller.snapshot(for: .gemini).connectionState, .connecting)
    }

    func testLiveRefreshStartedBeforeSignOutCannotRestoreSignedOutProvider() async {
        let delayed = DelayedUsageProvider(provider: .opencode)
        let staleConnected = DemoFixtures.snapshot(for: .opencode, scenario: .all)
        let signedOut = ProviderSnapshot(
            provider: .opencode,
            plan: "",
            connectionState: .notConnected,
            limits: [],
            connectedVia: "Not connected"
        )

        let providers: [any UsageProvider] = ProviderID.allCases.map { id -> any UsageProvider in
            if id == .opencode {
                return delayed
            }
            return UnconfiguredUsageProvider(provider: id)
        }
        let initial = ProviderID.allCases.map { id in
            id == .opencode ? staleConnected : ProviderSnapshot(
                provider: id,
                plan: "",
                connectionState: .notConnected,
                limits: [],
                connectedVia: "Not connected"
            )
        }
        let controller = AccountsController(
            isDemo: false,
            initialSnapshots: initial,
            providers: providers
        )

        // Start a refresh while OpenCode is connected
        let refreshTask = Task { await controller.refreshAll() }
        await delayed.waitForFetchCalls(1)

        // User signs out before the in-flight refresh completes
        let signOutTask = controller.signOut(.opencode)
        XCTAssertEqual(controller.snapshot(for: .opencode).connectionState, .notConnected)
        await delayed.waitForSignOutCalls(1)
        await delayed.resolveNextSignOut(signedOut)
        await signOutTask?.value

        // Older refresh now completes with the stale Connected snapshot
        await delayed.resolveNextFetch(staleConnected)
        await refreshTask.value

        // Must remain signed out
        XCTAssertEqual(controller.snapshot(for: .opencode).connectionState, .notConnected)
        XCTAssertEqual(controller.snapshot(for: .opencode).menuBarEntryState, .omitted)
    }

    func testOutOfOrderDelayedSignOutCannotOverwriteSubsequentSignInOrClearItsTask() async {
        let delayed = DelayedUsageProvider(provider: .opencode)
        let connected = DemoFixtures.snapshot(for: .opencode, scenario: .all)
        let signedOut = ProviderSnapshot(
            provider: .opencode,
            plan: "",
            connectionState: .notConnected,
            limits: [],
            connectedVia: "Not connected"
        )

        let providers: [any UsageProvider] = ProviderID.allCases.map { id -> any UsageProvider in
            if id == .opencode {
                return delayed
            }
            return UnconfiguredUsageProvider(provider: id)
        }
        let initial = ProviderID.allCases.map { id in
            id == .opencode ? connected : ProviderSnapshot(
                provider: id,
                plan: "",
                connectionState: .notConnected,
                limits: [],
                connectedVia: "Not connected"
            )
        }
        let controller = AccountsController(
            isDemo: false,
            initialSnapshots: initial,
            providers: providers
        )

        // 1) Start sign-out (remains pending in provider even after cancellation)
        let signOutTask = controller.signOut(.opencode)
        await delayed.waitForSignOutCalls(1)
        XCTAssertEqual(controller.snapshot(for: .opencode).connectionState, .notConnected)

        // 2) Immediately start a new sign-in before sign-out returns
        let signInTask = controller.signIn(.opencode)
        await delayed.waitForSignInCalls(1)
        XCTAssertEqual(controller.snapshot(for: .opencode).connectionState, .connecting)
        XCTAssertEqual(controller.snapshot(for: .opencode).menuBarEntryState, .omitted)

        // 3) Older sign-out resolves while sign-in is still pending — must NOT overwrite .connecting or clear sign-in task
        await delayed.resolveNextSignOut(signedOut)
        await signOutTask?.value
        XCTAssertEqual(controller.snapshot(for: .opencode).connectionState, .connecting)

        // 4) Newer sign-in now completes — transitions cleanly to Connected 42%
        await delayed.resolveNextSignIn(connected)
        await signInTask?.value
        XCTAssertEqual(controller.snapshot(for: .opencode).connectionState, .connected)
        XCTAssertEqual(controller.snapshot(for: .opencode).fullestLimit?.percentUsed, 42)

        // 5) Also verify the reverse out-of-order case: sign-in finishes BEFORE an older delayed sign-out
        let secondSignOutTask = controller.signOut(.opencode)
        await delayed.waitForSignOutCalls(2)
        let secondSignInTask = controller.signIn(.opencode)
        await delayed.waitForSignInCalls(2)

        await delayed.resolveNextSignIn(connected)
        await secondSignInTask?.value
        XCTAssertEqual(controller.snapshot(for: .opencode).connectionState, .connected)

        await delayed.resolveNextSignOut(signedOut)
        await secondSignOutTask?.value
        XCTAssertEqual(controller.snapshot(for: .opencode).connectionState, .connected)
        XCTAssertEqual(controller.snapshot(for: .opencode).fullestLimit?.percentUsed, 42)
    }

    func testLiveUnconfiguredSignInReportsNotYetSupportedHonestly() async {
        let providers = ProviderID.allCases.map { UnconfiguredUsageProvider(provider: $0) }
        let initial = ProviderID.allCases.map {
            ProviderSnapshot(
                provider: $0,
                plan: "",
                connectionState: .notConnected,
                limits: [],
                connectedVia: "Not connected"
            )
        }
        let controller = AccountsController(
            isDemo: false,
            initialSnapshots: initial,
            providers: providers
        )

        let task = controller.signIn(.claude)
        await task?.value

        let result = controller.snapshot(for: .claude)
        XCTAssertEqual(result.connectionState, .unsupported)
        XCTAssertTrue(result.connectedVia.localizedCaseInsensitiveContains("not yet supported"))
        XCTAssertEqual(result.menuBarEntryState, .omitted)

        // Background refresh should keep the honest unsupported message
        await controller.refreshAll()
        XCTAssertEqual(controller.snapshot(for: .claude).connectionState, .unsupported)
    }

    func testLiveSignInAndSignOutCallProviderProtocolHooks() async {
        let connected = DemoFixtures.snapshot(for: .opencode, scenario: .all)
        let stub = StubUsageProvider(provider: .opencode, connectedSnapshot: connected)
        let providers: [any UsageProvider] = ProviderID.allCases.map { id in
            if id == .opencode {
                return stub
            }
            return UnconfiguredUsageProvider(provider: id)
        }
        let initial = ProviderID.allCases.map {
            ProviderSnapshot(
                provider: $0,
                plan: "",
                connectionState: .notConnected,
                limits: [],
                connectedVia: "Not connected"
            )
        }
        let controller = AccountsController(
            isDemo: false,
            initialSnapshots: initial,
            providers: providers
        )

        let signInTask = controller.signIn(.opencode)
        await signInTask?.value

        let signInCount = await stub.signInCalls
        XCTAssertEqual(signInCount, 1)
        XCTAssertEqual(controller.snapshot(for: .opencode).connectionState, .connected)
        XCTAssertEqual(controller.snapshot(for: .opencode).fullestLimit?.percentUsed, 42)

        let signOutTask = controller.signOut(.opencode)
        await signOutTask?.value

        let signOutCount = await stub.signOutCalls
        XCTAssertEqual(signOutCount, 1)
        XCTAssertEqual(controller.snapshot(for: .opencode).connectionState, .notConnected)
    }
}

@MainActor
final class LocalSourceSettingsTests: XCTestCase {
    private func makeIsolatedDefaults() -> (suiteName: String, defaults: UserDefaults) {
        let suiteName = "dev.jabree.OpenUsageLocalSourceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (suiteName, defaults)
    }

    func testDefaultValuesMatchReferenceStill06() {
        let (suiteName, defaults) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = LocalSourceSettings(defaults: defaults)
        XCTAssertTrue(settings.isEnabled(.claudeCode))
        XCTAssertTrue(settings.isEnabled(.codexCLI))
        XCTAssertTrue(settings.isEnabled(.geminiCLI))
        XCTAssertFalse(settings.isEnabled(.openCode))
        XCTAssertTrue(settings.isEnabled(.cursor))
    }

    func testPersistenceAcrossReloads() {
        let (suiteName, defaults) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = LocalSourceSettings(defaults: defaults)
        settings.setEnabled(true, for: .openCode)
        settings.toggle(.geminiCLI)

        let reloaded = LocalSourceSettings(defaults: defaults)
        XCTAssertTrue(reloaded.isEnabled(.openCode))
        XCTAssertFalse(reloaded.isEnabled(.geminiCLI))
        XCTAssertTrue(reloaded.isEnabled(.claudeCode))
        XCTAssertTrue(reloaded.isEnabled(.codexCLI))
        XCTAssertTrue(reloaded.isEnabled(.cursor))
    }

    func testDemoSettingsAreVolatileAndIsolatedFromLiveDefaults() {
        let (suiteName, defaults) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let live = LocalSourceSettings.forLaunch(isDemo: false, liveDefaults: defaults)
        live.setEnabled(false, for: .claudeCode)
        live.setEnabled(true, for: .openCode)

        // Demo connecting scenario matches still 06 regardless of live prefs
        let demoConnecting = LocalSourceSettings.forLaunch(
            isDemo: true,
            demoScenario: .connecting,
            liveDefaults: defaults
        )
        XCTAssertTrue(demoConnecting.isEnabled(.claudeCode))
        XCTAssertFalse(demoConnecting.isEnabled(.openCode))

        // Demo all scenario matches still 07 (all enabled)
        let demoAll = LocalSourceSettings.forLaunch(
            isDemo: true,
            demoScenario: .all,
            liveDefaults: defaults
        )
        for source in LocalToolSource.allCases {
            XCTAssertTrue(demoAll.isEnabled(source))
        }

        // Edits in demo mode stay volatile and do not mutate live defaults
        demoConnecting.toggle(.openCode)
        demoConnecting.toggle(.cursor)
        XCTAssertTrue(demoConnecting.isEnabled(.openCode))
        XCTAssertFalse(demoConnecting.isEnabled(.cursor))

        let liveReloaded = LocalSourceSettings.forLaunch(isDemo: false, liveDefaults: defaults)
        XCTAssertFalse(liveReloaded.isEnabled(.claudeCode))
        XCTAssertTrue(liveReloaded.isEnabled(.openCode))
        XCTAssertTrue(liveReloaded.isEnabled(.cursor))
    }
}
