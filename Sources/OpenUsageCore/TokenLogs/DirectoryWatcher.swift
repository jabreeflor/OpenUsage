import CoreServices
import Foundation

/// Handle to an active directory-watching session started by a `DirectoryWatchBackend`.
public protocol DirectoryWatchSession: AnyObject, Sendable {
    func invalidate()
}

/// Pluggable filesystem event source backend (production: `FSEventsDirectoryWatchBackend`).
public protocol DirectoryWatchBackend: Sendable {
    /// Starts watching `paths` and returns an active session, or `nil` if startup fails.
    func startWatching(
        paths: [String],
        queue: DispatchQueue,
        onEvent: @escaping @Sendable () -> Void
    ) -> (any DirectoryWatchSession)?
}

/// Handle to a scheduled debounce timer created by a `DirectoryWatchScheduler`.
public protocol DirectoryWatchTimerToken: AnyObject, Sendable {
    func cancel()
}

/// Pluggable timer scheduler for trailing-edge debounce (production: `DispatchDirectoryWatchScheduler`).
public protocol DirectoryWatchScheduler: Sendable {
    func schedule(
        after delay: TimeInterval,
        on queue: DispatchQueue,
        action: @escaping @Sendable () -> Void
    ) -> any DirectoryWatchTimerToken
}

/// Production timer scheduler backed by `DispatchQueue.asyncAfter`.
public struct DispatchDirectoryWatchScheduler: DirectoryWatchScheduler, Sendable {
    public init() {}

    public func schedule(
        after delay: TimeInterval,
        on queue: DispatchQueue,
        action: @escaping @Sendable () -> Void
    ) -> any DirectoryWatchTimerToken {
        let workItem = DispatchWorkItem(block: action)
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
        return Token(workItem: workItem)
    }

    private final class Token: DirectoryWatchTimerToken, @unchecked Sendable {
        private let workItem: DispatchWorkItem

        init(workItem: DispatchWorkItem) {
            self.workItem = workItem
        }

        func cancel() {
            workItem.cancel()
        }
    }
}

/// Thin CoreServices FSEvents adapter implementing `DirectoryWatchBackend`.
public struct FSEventsDirectoryWatchBackend: DirectoryWatchBackend, Sendable {
    public let latency: TimeInterval

    public init(latency: TimeInterval = 0.1) {
        self.latency = max(0.01, latency)
    }

    public func startWatching(
        paths: [String],
        queue: DispatchQueue,
        onEvent: @escaping @Sendable () -> Void
    ) -> (any DirectoryWatchSession)? {
        guard !paths.isEmpty else { return nil }

        let box = CallbackBox(onEvent)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                return UnsafeRawPointer(Unmanaged<CallbackBox>.fromOpaque(info).retain().toOpaque())
            },
            release: { info in
                guard let info else { return }
                Unmanaged<CallbackBox>.fromOpaque(info).release()
            },
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, clientCallBackInfo, _, _, _, _ in
            guard let clientCallBackInfo else { return }
            let callbackBox = Unmanaged<CallbackBox>.fromOpaque(clientCallBackInfo).takeUnretainedValue()
            callbackBox.handler()
        }

        let cfPaths = paths as CFArray
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer
        )

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            cfPaths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            return nil
        }

        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return nil
        }

        return Session(stream: created)
    }

    private final class CallbackBox: @unchecked Sendable {
        let handler: @Sendable () -> Void

        init(_ handler: @escaping @Sendable () -> Void) {
            self.handler = handler
        }
    }

    private final class Session: DirectoryWatchSession, @unchecked Sendable {
        private let lock = NSLock()
        private var stream: FSEventStreamRef?

        init(stream: FSEventStreamRef) {
            self.stream = stream
        }

        deinit {
            invalidate()
        }

        func invalidate() {
            lock.lock()
            let existing = stream
            stream = nil
            lock.unlock()

            guard let existing else { return }
            FSEventStreamStop(existing)
            FSEventStreamInvalidate(existing)
            FSEventStreamRelease(existing)
        }
    }
}

/// Recursive folder watcher with trailing-edge debounce and safe retry after failed stream startup.
/// Used only outside demo mode to trigger incremental local-log refreshes when AI tools write new logs.
public final class DirectoryWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.jabree.OpenUsage.DirectoryWatcher", qos: .utility)
    private let lock = NSLock()
    private let debounceInterval: TimeInterval
    private let backend: any DirectoryWatchBackend
    private let scheduler: any DirectoryWatchScheduler
    private let onChange: @Sendable () -> Void

    private var activeSession: (any DirectoryWatchSession)?
    private var pendingTimer: (any DirectoryWatchTimerToken)?
    private var watchGeneration: UInt64 = 0
    private var debounceGeneration: UInt64 = 0
    private var activePaths: [String] = []
    private var isStopped = false

    public init(
        debounceInterval: TimeInterval = 0.75,
        backend: (any DirectoryWatchBackend)? = nil,
        scheduler: any DirectoryWatchScheduler = DispatchDirectoryWatchScheduler(),
        onChange: @escaping @Sendable () -> Void
    ) {
        let clampedDebounce = max(0.02, debounceInterval)
        self.debounceInterval = clampedDebounce
        // Keep FSEvents coalescing latency well below debounceInterval so subsequent events in a
        // rapid burst arrive before the trailing-edge debounce timer fires (with kFSEventStreamCreateFlagNoDefer).
        let streamLatency = max(0.01, min(0.1, clampedDebounce / 4.0))
        self.backend = backend ?? FSEventsDirectoryWatchBackend(latency: streamLatency)
        self.scheduler = scheduler
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    /// Whether the watcher currently has an active running event session.
    public var isWatching: Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeSession != nil && !isStopped
    }

    /// Starts or updates the watched directory set. Non-existent leaf directories fall back to their
    /// immediate parent directory (if that parent is not the home directory itself and already exists).
    ///
    /// Paths are recorded as active only after the underlying event stream starts successfully, so
    /// calling `watch(directories:)` again with the same paths after a startup failure retries cleanly.
    /// Returns `true` when watching succeeded (or when no watchable directories exist and the watcher
    /// was cleanly cleared), and `false` if the watcher is stopped or backend startup failed.
    @discardableResult
    public func watch(directories: [URL]) -> Bool {
        let resolvedPaths = Self.resolveWatchablePaths(from: directories)

        lock.lock()
        if isStopped {
            lock.unlock()
            return false
        }

        if resolvedPaths.isEmpty {
            watchGeneration &+= 1
            let oldSession = activeSession
            activeSession = nil
            activePaths = []
            lock.unlock()
            oldSession?.invalidate()
            return true
        }

        // Only short-circuit when an active session is already watching the exact same paths.
        if activeSession != nil && resolvedPaths == activePaths {
            lock.unlock()
            return true
        }

        watchGeneration &+= 1
        let startGeneration = watchGeneration
        let oldSession = activeSession
        activeSession = nil
        activePaths = []
        lock.unlock()

        oldSession?.invalidate()

        guard let newSession = backend.startWatching(
            paths: resolvedPaths,
            queue: queue,
            onEvent: { [weak self] in
                self?.handleBackendEvent(generation: startGeneration)
            }
        ) else {
            lock.lock()
            if watchGeneration == startGeneration {
                watchGeneration &+= 1
            }
            lock.unlock()
            return false
        }

        lock.lock()
        if isStopped || watchGeneration != startGeneration {
            lock.unlock()
            newSession.invalidate()
            return false
        }
        activeSession = newSession
        activePaths = resolvedPaths
        lock.unlock()
        return true
    }

    public func stop() {
        lock.lock()
        isStopped = true
        watchGeneration &+= 1
        debounceGeneration &+= 1
        let timer = pendingTimer
        pendingTimer = nil
        let session = activeSession
        activeSession = nil
        activePaths = []
        lock.unlock()

        timer?.cancel()
        session?.invalidate()
    }

    private func handleBackendEvent(generation: UInt64) {
        lock.lock()
        guard !isStopped, generation == watchGeneration else {
            lock.unlock()
            return
        }
        let previousTimer = pendingTimer
        debounceGeneration &+= 1
        let expectedGeneration = debounceGeneration
        let newTimer = scheduler.schedule(after: debounceInterval, on: queue) { [weak self] in
            self?.fireDebouncedCallback(expectedGeneration: expectedGeneration)
        }
        pendingTimer = newTimer
        lock.unlock()

        previousTimer?.cancel()
    }

    private func fireDebouncedCallback(expectedGeneration: UInt64) {
        lock.lock()
        guard !isStopped, debounceGeneration == expectedGeneration else {
            lock.unlock()
            return
        }
        pendingTimer = nil
        let handler = onChange
        lock.unlock()

        handler()
    }

    public static func resolveWatchablePaths(from directories: [URL]) -> [String] {
        let fm = FileManager.default
        let homePath = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).standardizedFileURL.path
        var unique: Set<String> = []

        for url in directories {
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: resolved.path, isDirectory: &isDir), isDir.boolValue {
                unique.insert(resolved.path)
            } else {
                let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
                if parent.path != homePath,
                   parent.path != "/",
                   fm.fileExists(atPath: parent.path, isDirectory: &isDir),
                   isDir.boolValue {
                    unique.insert(parent.path)
                }
            }
        }

        return unique.sorted()
    }
}
