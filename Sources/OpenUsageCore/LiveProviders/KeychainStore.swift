import Foundation
import Security

/// Safe Keychain errors that expose only numeric `OSStatus` codes, never credential data.
public enum KeychainStoreError: Error, Sendable, Equatable {
    case unexpectedItemFormat
    case timedOut
    case osStatus(Int32)

    public var shortDescription: String {
        switch self {
        case .unexpectedItemFormat:
            return "Keychain item format invalid"
        case .timedOut:
            return "Keychain read timed out"
        case .osStatus(let status):
            return "Keychain error (\(status))"
        }
    }
}

public protocol KeychainReading: Sendable {
    /// Reads a generic password item from the macOS Keychain. Returns `nil` when not found.
    func readGenericPassword(service: String, account: String?) throws -> Data?
}

public protocol KeychainStoring: KeychainReading {
    /// Writes or updates a generic password item owned by OpenUsage in the macOS Keychain.
    func writeGenericPassword(_ data: Data, service: String, account: String) throws

    /// Deletes a generic password item owned by OpenUsage from the macOS Keychain.
    func deleteGenericPassword(service: String, account: String) throws
}

/// Low-level `SecItem*` adapter so `SystemKeychainStore`'s query & status-code logic can be unit-tested
/// deterministically even inside sandboxes where the macOS login keychain daemon is unreachable.
public protocol SecItemBackend: Sendable {
    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: Any?)
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], attributesToUpdate: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

public struct SecurityFrameworkBackend: SecItemBackend, Sendable {
    public init() {}

    public func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: Any?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
    }

    public func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    public func update(_ query: [String: Any], attributesToUpdate: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
    }

    public func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

/// Thin wrapper over Security.framework for reading existing tool logins and storing OpenUsage-owned secrets.
/// Never logs, caches to disk, or embeds credential bytes in thrown errors.
public struct SystemKeychainStore: KeychainStoring, Sendable {
    public static let openUsageService = "dev.jabree.OpenUsage"

    private let backend: any SecItemBackend

    public init(backend: any SecItemBackend = SecurityFrameworkBackend()) {
        self.backend = backend
    }

    public func readGenericPassword(service: String, account: String? = nil) throws -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }

        let (status, result) = backend.copyMatching(query)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainStoreError.osStatus(status)
        }
        guard let data = result as? Data else {
            throw KeychainStoreError.unexpectedItemFormat
        }
        return data
    }

    public func writeGenericPassword(_ data: Data, service: String, account: String) throws {
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let addStatus = backend.add(addQuery)
        if addStatus == errSecSuccess {
            return
        }

        if addStatus == errSecDuplicateItem {
            let matchQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            let updateAttributes: [String: Any] = [
                kSecValueData as String: data
            ]
            let updateStatus = backend.update(matchQuery, attributesToUpdate: updateAttributes)
            guard updateStatus == errSecSuccess else {
                throw KeychainStoreError.osStatus(updateStatus)
            }
            return
        }

        throw KeychainStoreError.osStatus(addStatus)
    }

    public func deleteGenericPassword(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = backend.delete(query)
        if status == errSecSuccess || status == errSecItemNotFound {
            return
        }
        throw KeychainStoreError.osStatus(status)
    }
}

/// Coordinates at most one in-flight Keychain lookup per credential service so repeated refreshes
/// never stack concurrent macOS Keychain prompts. Callers wait independently up to their own deadline;
/// if consent arrives after all callers stopped waiting, the completed result is held in memory only
/// and consumed by the next fetch without starting another Keychain read.
public actor KeychainLookupCoordinator {
    public enum LookupOutcome: Sendable {
        case completed(Result<Data?, Error>)
        case pending
    }

    private final class WaiterBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<LookupOutcome, Error>?
        private var timer: DispatchWorkItem?
        private var earlyResult: Result<LookupOutcome, Error>?
        private var resolved = false

        /// Installs the continuation and deadline timer, returning `true` when still waiting
        /// or `false` if an early completion/cancellation already resumed the continuation.
        func install(
            continuation: CheckedContinuation<LookupOutcome, Error>,
            timer: DispatchWorkItem
        ) -> Bool {
            lock.lock()
            if let earlyResult {
                self.earlyResult = nil
                lock.unlock()
                timer.cancel()
                continuation.resume(with: earlyResult)
                return false
            }
            self.continuation = continuation
            self.timer = timer
            lock.unlock()
            return true
        }

        /// Returns `true` if this call won the race to resolve the waiter.
        @discardableResult
        func resolve(_ result: Result<LookupOutcome, Error>) -> Bool {
            lock.lock()
            guard !resolved else {
                lock.unlock()
                return false
            }
            resolved = true
            let cont = continuation
            continuation = nil
            let t = timer
            timer = nil
            if cont == nil {
                earlyResult = result
            }
            lock.unlock()

            t?.cancel()
            cont?.resume(with: result)
            return true
        }
    }

    private struct LookupKey: Hashable, Sendable {
        let service: String
        let account: String?
    }

    private struct InFlightLookup {
        let epoch: UInt64
        var waiters: [UUID: WaiterBox] = [:]
    }

    private var inFlight: [LookupKey: InFlightLookup] = [:]
    private var unconsumedResults: [LookupKey: Result<Data?, Error>] = [:]
    private var epochs: [LookupKey: UInt64] = [:]

    public init() {}

    /// Discards any in-memory late result for `service` (and optional `account`) and invalidates
    /// any currently in-flight lookup so stale pre-mutation reads cannot repopulate the cache.
    public func clearCachedResult(forService service: String, account: String? = nil) {
        let key = LookupKey(service: service, account: account)
        epochs[key] = (epochs[key] ?? 0) &+ 1
        unconsumedResults.removeValue(forKey: key)
    }

    /// Reads a generic password for `service` (and optional `account`) off the MainActor and off Swift's cooperative
    /// thread pool, joining any existing in-flight lookup for the same key rather than stacking duplicate reads.
    public func readGenericPassword(
        using keychain: any KeychainReading,
        service: String,
        account: String? = nil,
        timeout: TimeInterval
    ) async throws -> LookupOutcome {
        try Task.checkCancellation()

        let key = LookupKey(service: service, account: account)
        if let cached = unconsumedResults.removeValue(forKey: key) {
            return .completed(cached)
        }

        let effectiveTimeout = timeout.isFinite ? min(3600.0, max(0.01, timeout)) : URLSessionHTTPTransport.defaultTimeout
        let waiterID = UUID()
        let box = WaiterBox()
        let currentEpoch = epochs[key] ?? 0
        let shouldStartBackgroundRead = (inFlight[key] == nil || inFlight[key]?.epoch != currentEpoch)

        if shouldStartBackgroundRead {
            inFlight[key] = InFlightLookup(epoch: currentEpoch, waiters: [waiterID: box])
        } else {
            inFlight[key]?.waiters[waiterID] = box
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timer = DispatchWorkItem { [weak self] in
                    if box.resolve(.success(.pending)) {
                        Task { await self?.removeWaiter(waiterID, forKey: key, epoch: currentEpoch) }
                    }
                }

                if Task.isCancelled {
                    if box.resolve(.failure(CancellationError())) {
                        self.removeWaiter(waiterID, forKey: key, epoch: currentEpoch)
                    }
                }

                let installed = box.install(continuation: continuation, timer: timer)
                let queue = DispatchQueue.global(qos: .userInitiated)
                if installed {
                    queue.asyncAfter(deadline: .now() + effectiveTimeout, execute: timer)
                }

                if shouldStartBackgroundRead {
                    queue.async { [weak self] in
                        let result: Result<Data?, Error>
                        do {
                            let data = try keychain.readGenericPassword(service: service, account: account)
                            result = .success(data)
                        } catch {
                            result = .failure(error)
                        }
                        Task {
                            await self?.completeLookup(forKey: key, epoch: currentEpoch, result: result)
                        }
                    }
                }
            }
        } onCancel: {
            if box.resolve(.failure(CancellationError())) {
                Task { await self.removeWaiter(waiterID, forKey: key, epoch: currentEpoch) }
            }
        }
    }

    private func removeWaiter(_ id: UUID, forKey key: LookupKey, epoch: UInt64) {
        guard inFlight[key]?.epoch == epoch else { return }
        inFlight[key]?.waiters.removeValue(forKey: id)
    }

    private func completeLookup(forKey key: LookupKey, epoch: UInt64, result: Result<Data?, Error>) {
        guard inFlight[key]?.epoch == epoch,
              let lookup = inFlight.removeValue(forKey: key) else {
            return
        }
        let isStillCurrent = ((epochs[key] ?? 0) == epoch)
        var deliveredToAnyWaiter = false
        for waiter in lookup.waiters.values {
            if isStillCurrent {
                if waiter.resolve(.success(.completed(result))) {
                    deliveredToAnyWaiter = true
                }
            } else {
                _ = waiter.resolve(.failure(CancellationError()))
            }
        }
        if !deliveredToAnyWaiter && isStillCurrent {
            unconsumedResults[key] = result
        }
    }
}

/// Weak-keyed registry associating reference-type `KeychainReading` instances with a shared `KeychainLookupCoordinator`
/// so multiple providers sharing the same Keychain reader never stack concurrent reads while independent test doubles remain isolated.
internal final class KeychainCoordinatorRegistry: @unchecked Sendable {
    static let shared = KeychainCoordinatorRegistry()

    private let lock = NSLock()
    private let table = NSMapTable<AnyObject, KeychainLookupCoordinator>.weakToStrongObjects()

    private init() {}

    func coordinator(for keychain: any KeychainReading) -> KeychainLookupCoordinator {
        guard type(of: keychain) is AnyClass else {
            return KeychainLookupCoordinator()
        }
        let object = keychain as AnyObject
        lock.lock()
        defer { lock.unlock() }
        if let existing = table.object(forKey: object) {
            return existing
        }
        let created = KeychainLookupCoordinator()
        table.setObject(created, forKey: object)
        return created
    }
}
