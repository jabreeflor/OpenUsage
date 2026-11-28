import Darwin
import Foundation

/// Discovered regular file entry returned by `TokenLogFileAccess.discoverFiles`.
public struct DiscoveredLogFile: Sendable, Equatable {
    public let url: URL
    public let relativePath: String
    public let metadata: FileMetadata

    public init(url: URL, relativePath: String, metadata: FileMetadata) {
        self.url = url
        self.relativePath = relativePath
        self.metadata = metadata
    }
}

/// Injectable POSIX filesystem interface for local token log sources so tests can simulate
/// iCloud-evicted (`isDataless`) files, slow/hung materialization reads, and metadata transitions
/// without touching real iCloud Drive.
public protocol TokenLogFileAccess: Sendable {
    func discoverFiles(
        under root: URL,
        matching predicate: (URL) -> Bool
    ) -> [DiscoveredLogFile]

    func readMetadata(at url: URL) -> FileMetadata?
    /// Reads file metadata using `lstat`, returning `nil` only when the path is confirmed absent
    /// (`ENOENT` / `ENOTDIR`) and throwing an error for transient filesystem errors (`EACCES`, `EIO`, etc.).
    func readMetadataOrThrow(at url: URL) throws -> FileMetadata?
    func readMetadata(fd: Int32) -> FileMetadata?

    /// Opens `url` read-only without following a trailing symlink.
    /// Returns a POSIX file descriptor (`>= 0`) on success, or `-1` on failure (with `errno` set).
    /// When `allowMaterialization` is `true`, implementations may trigger and await iCloud download
    /// of a dataless file before returning the descriptor.
    func openReadOnly(at url: URL, allowMaterialization: Bool) -> Int32

    /// Closes a file descriptor returned by `openReadOnly`.
    func close(fd: Int32)
}

public extension TokenLogFileAccess {
    func readMetadata(at url: URL) -> FileMetadata? {
        try? readMetadataOrThrow(at: url)
    }
}

/// Default production `TokenLogFileAccess` backed by POSIX `lstat`/`fstat`/`open`/`pread`/`close`.
public struct SystemTokenLogFileAccess: TokenLogFileAccess, Sendable {
    public init() {}

    public func discoverFiles(
        under root: URL,
        matching predicate: (URL) -> Bool
    ) -> [DiscoveredLogFile] {
        SafeDirectoryScanner.discoverFiles(under: root, matching: predicate).map {
            DiscoveredLogFile(url: $0.url, relativePath: $0.relativePath, metadata: $0.metadata)
        }
    }

    public func readMetadata(at url: URL) -> FileMetadata? {
        FileMetadata.read(at: url)
    }

    public func readMetadataOrThrow(at url: URL) throws -> FileMetadata? {
        try FileMetadata.readOrThrow(at: url)
    }

    public func readMetadata(fd: Int32) -> FileMetadata? {
        FileMetadata.read(fd: fd)
    }

    public func openReadOnly(at url: URL, allowMaterialization: Bool) -> Int32 {
        if allowMaterialization {
            // Best-effort hint to FileProvider / iCloud Drive to initiate download if needed.
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }

        let fd = StreamingLineReader.openReadOnly(at: url)
        guard fd >= 0 else { return -1 }

        if allowMaterialization,
           let openMeta = FileMetadata.read(fd: fd),
           openMeta.isDataless {
            // Force synchronous materialization via a 1-byte pread (which preserves file offset 0)
            // so APFS/FileProvider downloads the file on this open descriptor before scanning.
            var probe: UInt8 = 0
            while true {
                let n = Darwin.pread(fd, &probe, 1, 0)
                if n < 0 {
                    if errno == EINTR { continue }
                    let savedErrno = errno
                    _ = Darwin.close(fd)
                    errno = savedErrno
                    return -1
                }
                break
            }
        }

        return fd
    }

    public func close(fd: Int32) {
        _ = Darwin.close(fd)
    }
}

/// Describes a single iCloud-evicted (dataless) log file discovered during the fast local pass
/// that is recent enough to matter and needs background materialization.
public struct PendingEvictedLogFile: Sendable, Equatable, Hashable {
    public let toolSource: LocalToolSource
    public let url: URL
    public let relativePath: String
    public let cacheKey: String
    public let metadata: FileMetadata
    /// Optional companion file metadata (e.g. `opencode.db-wal` for SQLite-backed sources).
    public let secondaryMetadata: FileMetadata?

    public init(
        toolSource: LocalToolSource,
        url: URL,
        relativePath: String,
        cacheKey: String,
        metadata: FileMetadata,
        secondaryMetadata: FileMetadata? = nil
    ) {
        self.toolSource = toolSource
        self.url = url
        self.relativePath = relativePath
        self.cacheKey = cacheKey
        self.metadata = metadata
        self.secondaryMetadata = secondaryMetadata
    }
}

/// Outcome of attempting to materialize and scan one evicted log file in the background pass.
public enum EvictedMaterializationOutcome: Sendable, Equatable {
    /// Materialized, scanned, verified unchanged, and committed to `SourceCacheState` (or already cached).
    case counted
    /// File confirmed absent (`ENOENT`/`ENOTDIR`) or not a regular file; stale cache entry removed.
    case removed
    /// Current file on disk is older than the 31-day materialization cutoff; skipped without opening.
    case skippedTooOld
    /// Current file on disk no longer matches the queued version (replaced or modified); skipped without opening.
    case staleVersion
    /// File remained dataless even after the read/materialization attempt; keep pending and retry with backoff.
    case stillDataless
    /// Read/parse or metadata failed transiently or concurrent mutations exhausted retries; keep pending and retry with backoff.
    case failed
    /// Per-file timeout expired before the read completed; keep pending and retry with backoff.
    case timedOut
}

/// Policy controlling which evicted files are eligible for background materialization and cache reuse.
public enum EvictedLogPolicy {
    /// Largest statistics window (30 days) plus 1 day margin.
    public static let materializationWindowDays: Int = 31
    public static let materializationWindowSeconds: TimeInterval = TimeInterval(materializationWindowDays * 86_400)

    /// Returns `true` when the file's modification time is within the last 31 days of `now`.
    public static func isRecentEnoughToMaterialize(mtimeNanos: Int64, now: Date) -> Bool {
        let cutoffSeconds = now.timeIntervalSince1970 - materializationWindowSeconds
        let mtimeSeconds = Double(mtimeNanos) / 1_000_000_000.0
        return mtimeSeconds >= cutoffSeconds
    }

    /// Returns `true` when `lhs` and `rhs` identify the exact same regular file version `(device, inode, size, mtime)`.
    public static func sameFileVersion(_ lhs: FileMetadata, _ rhs: FileMetadata) -> Bool {
        lhs.device == rhs.device
            && lhs.inode == rhs.inode
            && lhs.size == rhs.size
            && lhs.mtimeNanos == rhs.mtimeNanos
    }

    public static func sameOptionalFileVersion(_ lhs: FileMetadata?, _ rhs: FileMetadata?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (l?, r?):
            return sameFileVersion(l, r)
        default:
            return false
        }
    }

    /// Returns `true` when `entry` was built from the exact file version `meta`.
    public static func matchesFileVersion(_ entry: FileCacheEntry, _ meta: FileMetadata) -> Bool {
        entry.device == meta.device
            && entry.inode == meta.inode
            && entry.fileSize == meta.size
            && entry.mtimeNanos == meta.mtimeNanos
    }

    /// Returns `true` when `entry`'s companion file version (e.g. SQLite WAL) matches `meta`.
    public static func matchesSecondaryFileVersion(_ entry: FileCacheEntry, _ meta: FileMetadata?) -> Bool {
        (entry.secondaryDevice ?? 0) == (meta?.device ?? 0)
            && (entry.secondaryInode ?? 0) == (meta?.inode ?? 0)
            && (entry.secondarySize ?? 0) == (meta?.size ?? 0)
            && (entry.secondaryMtimeNanos ?? 0) == (meta?.mtimeNanos ?? 0)
    }

    /// Returns `true` when `entry` already holds the inspected result for `(device, inode, size, mtime)`,
    /// including files whose consumed `offset` was intentionally left before an incomplete trailing record.
    public static func isCacheEntryUpToDate(_ entry: FileCacheEntry, for meta: FileMetadata) -> Bool {
        matchesFileVersion(entry, meta)
            && entry.offset <= meta.size
            && (entry.offset == meta.size || entry.eofFingerprint != nil)
    }
}

/// Exponential retry backoff policy for evicted files whose materialization fails, times out, or remains dataless.
public struct EvictedRetryBackoffPolicy: Sendable, Equatable {
    public let baseDelay: TimeInterval
    public let maxDelay: TimeInterval

    public static let `default` = EvictedRetryBackoffPolicy(baseDelay: 30.0, maxDelay: 1_800.0)

    public init(baseDelay: TimeInterval = 30.0, maxDelay: TimeInterval = 1_800.0) {
        self.baseDelay = max(0, baseDelay)
        self.maxDelay = max(self.baseDelay, maxDelay)
    }

    public func delay(forFailureCount failureCount: Int) -> TimeInterval {
        guard failureCount > 0, baseDelay > 0 else { return 0 }
        let exponent = min(failureCount - 1, 10)
        return min(maxDelay, baseDelay * pow(2.0, Double(exponent)))
    }
}

/// Outcome of executing a single-slot bounded background materialization operation.
enum BoundedWorkResult<T: Sendable>: Sendable {
    /// Operation finished before the deadline.
    case completed(T)
    /// Operation started in the single slot but outlived its deadline; the slot remains held until it truly finishes.
    case timedOut
    /// Another materialization already occupies the process-wide single slot and did not finish before the deadline.
    case slotBusy
}

/// Runs a potentially blocking synchronous file operation on a low-priority utility queue
/// behind a process-wide single-flight slot with a hard wall-clock timeout.
///
/// Guarantees:
/// - At most ONE materialization operation is in flight in the entire process at any time.
/// - If an operation outlives its timeout, the caller resumes promptly with `.timedOut`,
///   while the blocked worker retains the single slot until it actually finishes.
/// - No second materialization can start until the active operation releases the slot.
enum BoundedBackgroundWork {
    private static let workerQueue = DispatchQueue(
        label: "dev.jabree.OpenUsage.iCloudLogMaterializer",
        qos: .utility
    )

    private static let timerQueue = DispatchQueue(
        label: "dev.jabree.OpenUsage.iCloudLogMaterializer.timer",
        qos: .utility
    )

    private static let slot = ProcessWideSingleSlot()

    static var isSlotOccupied: Bool {
        slot.isBusy
    }

    static func run<T: Sendable>(
        timeout: TimeInterval,
        onLateCompletion: (@Sendable (T) -> Void)? = nil,
        operation: @escaping @Sendable () -> T
    ) async -> BoundedWorkResult<T> {
        let clampedTimeout = max(0.01, timeout.isFinite ? timeout : 30.0)
        let deadlineNanos = DispatchTime.now().uptimeNanoseconds &+ secondsToNanos(clampedTimeout)

        let acquired = await slot.acquire(untilUptimeNanos: deadlineNanos, timerQueue: timerQueue)
        guard acquired else {
            return .slotBusy
        }

        if Task.isCancelled {
            slot.release()
            return .slotBusy
        }

        let nowNanos = DispatchTime.now().uptimeNanoseconds
        guard nowNanos < deadlineNanos else {
            slot.release()
            return .slotBusy
        }
        let remainingNanos = deadlineNanos - nowNanos

        let box = ResumeBox<BoundedWorkResult<T>>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let timer = DispatchSource.makeTimerSource(queue: timerQueue)
                timer.schedule(deadline: .now() + .nanoseconds(Int(min(remainingNanos, UInt64(Int.max)))))
                timer.setEventHandler {
                    timer.cancel()
                    box.resume(with: .timedOut)
                }

                if !box.install(continuation: continuation, timer: timer) {
                    timer.cancel()
                    slot.release()
                    continuation.resume(returning: .slotBusy)
                    return
                }

                timer.resume()

                workerQueue.async {
                    let result = operation()
                    if let delivery = box.tryComplete(with: .completed(result)) {
                        slot.release()
                        delivery.resume()
                    } else {
                        // Caller already timed out or cancelled: deliver late result before releasing the slot
                        // so subsequent callers observe it immediately without re-scanning the same version.
                        onLateCompletion?(result)
                        slot.release()
                    }
                }
            }
        } onCancel: {
            box.cancel(with: .timedOut)
        }
    }

    private static func secondsToNanos(_ seconds: TimeInterval) -> UInt64 {
        let clamped = max(0.001, seconds.isFinite ? seconds : 30.0)
        let raw = (clamped * 1_000_000_000.0).rounded()
        if raw >= Double(UInt64.max / 2) {
            return UInt64(Int.max)
        }
        return UInt64(max(1.0, raw))
    }

    private final class ProcessWideSingleSlot: @unchecked Sendable {
        private final class Waiter: @unchecked Sendable {
            enum State {
                case pending
                case waiting
                case granted
                case cancelled
                case timedOut
            }

            var state: State = .pending
            var continuation: CheckedContinuation<Bool, Never>?
            var timer: DispatchSourceTimer?
        }

        private let lock = NSLock()
        private var occupied = false
        private var waiters: [Waiter] = []

        var isBusy: Bool {
            lock.lock()
            defer { lock.unlock() }
            return occupied
        }

        func acquire(untilUptimeNanos deadlineNanos: UInt64, timerQueue: DispatchQueue) async -> Bool {
            let waiter = Waiter()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let immediate: Bool? = enqueueOrAcquire(
                        waiter: waiter,
                        continuation: continuation,
                        deadlineNanos: deadlineNanos,
                        timerQueue: timerQueue
                    )
                    if let immediate {
                        continuation.resume(returning: immediate)
                    }
                }
            } onCancel: {
                cancel(waiter: waiter)
            }
        }

        private func enqueueOrAcquire(
            waiter: Waiter,
            continuation: CheckedContinuation<Bool, Never>,
            deadlineNanos: UInt64,
            timerQueue: DispatchQueue
        ) -> Bool? {
            lock.lock()
            if waiter.state == .cancelled || Task.isCancelled {
                waiter.state = .cancelled
                lock.unlock()
                return false
            }
            if !occupied {
                occupied = true
                waiter.state = .granted
                lock.unlock()
                return true
            }
            let nowNanos = DispatchTime.now().uptimeNanoseconds
            guard nowNanos < deadlineNanos else {
                waiter.state = .timedOut
                lock.unlock()
                return false
            }
            let remainingNanos = deadlineNanos - nowNanos

            let timer = DispatchSource.makeTimerSource(queue: timerQueue)
            timer.schedule(deadline: .now() + .nanoseconds(Int(min(remainingNanos, UInt64(Int.max)))))
            timer.setEventHandler { [weak self] in
                self?.timeout(waiter: waiter)
            }

            waiter.state = .waiting
            waiter.continuation = continuation
            waiter.timer = timer
            waiters.append(waiter)
            lock.unlock()

            timer.resume()
            return nil
        }

        private func timeout(waiter: Waiter) {
            lock.lock()
            guard waiter.state == .waiting else {
                lock.unlock()
                return
            }
            waiter.state = .timedOut
            let cont = waiter.continuation
            waiter.continuation = nil
            let timer = waiter.timer
            waiter.timer = nil
            waiters.removeAll { $0 === waiter }
            lock.unlock()

            timer?.cancel()
            cont?.resume(returning: false)
        }

        private func cancel(waiter: Waiter) {
            lock.lock()
            switch waiter.state {
            case .pending:
                waiter.state = .cancelled
                lock.unlock()
                return
            case .waiting:
                waiter.state = .cancelled
                let cont = waiter.continuation
                waiter.continuation = nil
                let timer = waiter.timer
                waiter.timer = nil
                waiters.removeAll { $0 === waiter }
                lock.unlock()

                timer?.cancel()
                cont?.resume(returning: false)
                return
            case .granted, .cancelled, .timedOut:
                lock.unlock()
                return
            }
        }

        func release() {
            lock.lock()
            while !waiters.isEmpty {
                let next = waiters.removeFirst()
                guard next.state == .waiting else { continue }
                next.state = .granted
                let cont = next.continuation
                next.continuation = nil
                let timer = next.timer
                next.timer = nil
                // Ownership transfers directly to `next`, so `occupied` stays `true`.
                lock.unlock()

                timer?.cancel()
                cont?.resume(returning: true)
                return
            }
            occupied = false
            lock.unlock()
        }
    }

    private final class ResumeBox<T: Sendable>: @unchecked Sendable {
        struct Delivery: Sendable {
            private let continuation: CheckedContinuation<T, Never>?
            private let value: T

            fileprivate init(continuation: CheckedContinuation<T, Never>?, value: T) {
                self.continuation = continuation
                self.value = value
            }

            func resume() {
                continuation?.resume(returning: value)
            }
        }

        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Never>?
        private var timer: DispatchSourceTimer?
        private var cancelledBeforeInstall = false
        private var finished = false

        func install(continuation: CheckedContinuation<T, Never>, timer: DispatchSourceTimer) -> Bool {
            lock.lock()
            if cancelledBeforeInstall || Task.isCancelled {
                finished = true
                lock.unlock()
                return false
            }
            self.continuation = continuation
            self.timer = timer
            lock.unlock()
            return true
        }

        /// Atomically claims completion if the box has not already finished (timed out or cancelled).
        /// Returns a `Delivery` handle when this caller won the race, or `nil` when the caller
        /// already resumed earlier (late completion).
        func tryComplete(with value: T) -> Delivery? {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return nil
            }
            finished = true
            let cont = continuation
            continuation = nil
            let activeTimer = timer
            timer = nil
            lock.unlock()

            activeTimer?.cancel()
            return Delivery(continuation: cont, value: value)
        }

        func resume(with value: T) {
            tryComplete(with: value)?.resume()
        }

        func cancel(with value: T) {
            lock.lock()
            if continuation == nil && !finished {
                cancelledBeforeInstall = true
                lock.unlock()
                return
            }
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            let cont = continuation
            continuation = nil
            let activeTimer = timer
            timer = nil
            lock.unlock()

            activeTimer?.cancel()
            cont?.resume(returning: value)
        }
    }
}
