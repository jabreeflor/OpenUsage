import Darwin
import Foundation
import SQLite3

// MARK: - HTTP Transport

public struct HTTPResponseData: Sendable, Equatable {
    public let statusCode: Int
    public let body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

/// Safe transport errors that never carry URLs, headers, cookies, tokens, or raw response bodies.
public enum LiveProviderTransportError: Error, Sendable, Equatable {
    case timedOut
    case networkUnavailable
    case cancelled
    case invalidResponse
    case transportFailure(code: Int)

    public var shortReason: String {
        switch self {
        case .timedOut:
            return "Request timed out"
        case .networkUnavailable:
            return "Network unavailable"
        case .cancelled:
            return "Request cancelled"
        case .invalidResponse:
            return "Invalid HTTP response"
        case .transportFailure(let code):
            return "Network error (\(code))"
        }
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest, timeout: TimeInterval) async throws -> HTTPResponseData
}

/// Ephemeral `URLSession` transport with no disk cache, no cookie storage, and a hard per-request timeout.
public final class URLSessionHTTPTransport: HTTPTransport, Sendable {
    public static let defaultTimeout: TimeInterval = 10.0

    private let session: URLSession

    public init(timeout: TimeInterval = URLSessionHTTPTransport.defaultTimeout) {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = max(1.0, timeout)
        config.timeoutIntervalForResource = max(1.0, timeout)
        self.session = URLSession(configuration: config)
    }

    public func send(_ request: URLRequest, timeout: TimeInterval = URLSessionHTTPTransport.defaultTimeout) async throws -> HTTPResponseData {
        var prepared = request
        let effectiveTimeout = timeout.isFinite ? min(3600.0, max(0.5, timeout)) : URLSessionHTTPTransport.defaultTimeout
        prepared.timeoutInterval = effectiveTimeout
        prepared.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        prepared.httpShouldHandleCookies = false
        let finalRequest = prepared

        let session = self.session
        return try await withThrowingTaskGroup(of: HTTPResponseData.self) { group in
            group.addTask {
                do {
                    let (data, response) = try await session.data(for: finalRequest)
                    guard let http = response as? HTTPURLResponse else {
                        throw LiveProviderTransportError.invalidResponse
                    }
                    return HTTPResponseData(statusCode: http.statusCode, body: data)
                } catch let error as LiveProviderTransportError {
                    throw error
                } catch is CancellationError {
                    throw LiveProviderTransportError.cancelled
                } catch let urlError as URLError {
                    switch urlError.code {
                    case .timedOut:
                        throw LiveProviderTransportError.timedOut
                    case .cancelled:
                        throw LiveProviderTransportError.cancelled
                    case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                        throw LiveProviderTransportError.networkUnavailable
                    default:
                        throw LiveProviderTransportError.transportFailure(code: urlError.code.rawValue)
                    }
                } catch {
                    throw LiveProviderTransportError.transportFailure(code: (error as NSError).code)
                }
            }

            group.addTask {
                let nanos = UInt64(ceil(effectiveTimeout * 1_000_000_000))
                try await Task.sleep(nanoseconds: max(1_000_000, nanos))
                throw LiveProviderTransportError.timedOut
            }

            do {
                guard let first = try await group.next() else {
                    group.cancelAll()
                    throw LiveProviderTransportError.invalidResponse
                }
                group.cancelAll()
                return first
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }
}

// MARK: - Local File & Read-Only SQLite Reader

public struct DiscoveredLocalFile: Sendable, Equatable {
    public let url: URL
    public let relativePath: String
    public let metadata: FileMetadata

    public init(url: URL, relativePath: String, metadata: FileMetadata) {
        self.url = url
        self.relativePath = relativePath
        self.metadata = metadata
    }
}

public protocol LocalFileReader: Sendable {
    /// Reads a local regular file into memory. Returns `nil` when the file does not exist.
    func readFile(at url: URL) throws -> Data?

    /// Discovers regular files under `root` matching `predicate`.
    func discoverFiles(under root: URL, matching predicate: @Sendable (URL) -> Bool) -> [DiscoveredLocalFile]

    /// Reads string values for `keys` from a SQLite `ItemTable(key, value)` read-only.
    /// Returns `nil` when `dbURL` does not exist.
    func readSQLiteItems(at dbURL: URL, keys: [String]) throws -> [String: String]?
}

public enum LocalFileReaderError: Error, Sendable, Equatable {
    case unreadableFile
    case permissionDenied
    case fileTooLarge
    case sqliteOpenFailed(Int32)
    case sqliteQueryFailed(Int32)

    public var shortReason: String {
        switch self {
        case .unreadableFile:
            return "Local file unreadable"
        case .permissionDenied:
            return "Local file permission denied"
        case .fileTooLarge:
            return "Local file exceeds size limit"
        case .sqliteOpenFailed(let code):
            return "Local state DB unavailable (\(code))"
        case .sqliteQueryFailed(let code):
            return "Local state DB query failed (\(code))"
        }
    }
}

public struct SystemLocalFileReader: LocalFileReader, Sendable {
    public let maxFileBytes: Int
    public let sqliteBusyTimeoutMs: Int32

    public init(maxFileBytes: Int = 16 * 1024 * 1024, sqliteBusyTimeoutMs: Int32 = 1000) {
        self.maxFileBytes = max(1024, maxFileBytes)
        self.sqliteBusyTimeoutMs = max(0, sqliteBusyTimeoutMs)
    }

    private static func mapPOSIXError(_ error: POSIXError) -> LocalFileReaderError {
        switch error.code {
        case .EACCES, .EPERM:
            return .permissionDenied
        case .EFBIG:
            return .fileTooLarge
        default:
            return .unreadableFile
        }
    }

    public func readFile(at url: URL) throws -> Data? {
        let meta: FileMetadata?
        do {
            meta = try FileMetadata.readOrThrow(at: url)
        } catch let posixError as POSIXError {
            throw Self.mapPOSIXError(posixError)
        } catch {
            throw LocalFileReaderError.unreadableFile
        }
        guard let meta else {
            return nil
        }
        guard meta.isRegularFile, !meta.isDataless else {
            return nil
        }
        guard meta.size <= UInt64(maxFileBytes) else {
            throw LocalFileReaderError.fileTooLarge
        }

        let fd = StreamingLineReader.openReadOnly(at: url)
        guard fd >= 0 else {
            let openErrno = errno
            if openErrno == ENOENT || openErrno == ENOTDIR || openErrno == ELOOP {
                return nil
            }
            if openErrno == EACCES || openErrno == EPERM {
                throw LocalFileReaderError.permissionDenied
            }
            throw LocalFileReaderError.unreadableFile
        }
        defer { _ = Darwin.close(fd) }

        do {
            return try StreamingLineReader.readAllBytes(fd: fd, maxBytes: maxFileBytes).data
        } catch let posixError as POSIXError {
            throw Self.mapPOSIXError(posixError)
        } catch {
            throw LocalFileReaderError.unreadableFile
        }
    }

    public func discoverFiles(
        under root: URL,
        matching predicate: @Sendable (URL) -> Bool
    ) -> [DiscoveredLocalFile] {
        SafeDirectoryScanner.discoverFiles(under: root, matching: predicate).map {
            DiscoveredLocalFile(url: $0.url, relativePath: $0.relativePath, metadata: $0.metadata)
        }
    }

    public func readSQLiteItems(at dbURL: URL, keys: [String]) throws -> [String: String]? {
        guard !keys.isEmpty else { return [:] }
        let meta: FileMetadata?
        do {
            meta = try FileMetadata.readOrThrow(at: dbURL)
        } catch let posixError as POSIXError {
            throw Self.mapPOSIXError(posixError)
        } catch {
            throw LocalFileReaderError.unreadableFile
        }
        guard let meta, meta.isRegularFile, !meta.isDataless else {
            return nil
        }

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let openStatus = sqlite3_open_v2(dbURL.path, &db, flags, nil)
        guard openStatus == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw LocalFileReaderError.sqliteOpenFailed(openStatus)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, sqliteBusyTimeoutMs)

        let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ", ")
        let query = "SELECT key, value FROM ItemTable WHERE key IN (\(placeholders))"
        var statement: OpaquePointer?
        let prepareStatus = sqlite3_prepare_v2(db, query, -1, &statement, nil)
        guard prepareStatus == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw LocalFileReaderError.sqliteQueryFailed(prepareStatus)
        }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, key) in keys.enumerated() {
            let bindStatus = key.withCString { cStr in
                sqlite3_bind_text(statement, Int32(index + 1), cStr, -1, transient)
            }
            guard bindStatus == SQLITE_OK else {
                throw LocalFileReaderError.sqliteQueryFailed(bindStatus)
            }
        }

        var items: [String: String] = [:]
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE {
                break
            }
            guard step == SQLITE_ROW else {
                throw LocalFileReaderError.sqliteQueryFailed(step)
            }
            guard let keyPtr = sqlite3_column_text(statement, 0),
                  let valPtr = sqlite3_column_text(statement, 1) else {
                continue
            }
            let key = String(cString: keyPtr)
            let valLen = Int(sqlite3_column_bytes(statement, 1))
            let valData = Data(bytes: valPtr, count: max(0, valLen))
            if let value = String(data: valData, encoding: .utf8) {
                items[key] = value
            }
        }
        return items
    }
}

// MARK: - URL Opener

public protocol URLOpening: Sendable {
    @discardableResult
    func open(_ url: URL) -> Bool
}

public struct NoOpURLOpener: URLOpening, Sendable {
    public init() {}

    @discardableResult
    public func open(_ url: URL) -> Bool {
        false
    }
}

// MARK: - Persisted Per-Provider Disabled Flag (Sign-Out)

public protocol ProviderDisableStoring: Sendable {
    func isDisabled(_ provider: ProviderID) -> Bool
    func setDisabled(_ disabled: Bool, for provider: ProviderID)
}

/// Persists only boolean per-provider sign-out flags in `UserDefaults`. Never stores credentials or account IDs.
public final class UserDefaultsProviderDisableStore: ProviderDisableStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public static func defaultsKey(for provider: ProviderID) -> String {
        "openusage.providerDisabled.\(provider.rawValue)"
    }

    public func isDisabled(_ provider: ProviderID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return defaults.bool(forKey: Self.defaultsKey(for: provider))
    }

    public func setDisabled(_ disabled: Bool, for provider: ProviderID) {
        lock.lock()
        defer { lock.unlock() }
        defaults.set(disabled, forKey: Self.defaultsKey(for: provider))
    }
}

public final class InMemoryProviderDisableStore: ProviderDisableStoring, @unchecked Sendable {
    private var disabledSet: Set<ProviderID>
    private let lock = NSLock()

    public init(disabled: Set<ProviderID> = []) {
        self.disabledSet = disabled
    }

    public func isDisabled(_ provider: ProviderID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return disabledSet.contains(provider)
    }

    public func setDisabled(_ disabled: Bool, for provider: ProviderID) {
        lock.lock()
        defer { lock.unlock() }
        if disabled {
            disabledSet.insert(provider)
        } else {
            disabledSet.remove(provider)
        }
    }
}

// MARK: - Diagnostics & Diagnosable Provider Protocol

public struct ProviderFetchDiagnostic: Sendable, Equatable {
    public let httpStatus: Int?
    public let shortReason: String?
    public let isTransientError: Bool
    public let warnings: [String]

    public init(
        httpStatus: Int? = nil,
        shortReason: String? = nil,
        isTransientError: Bool = false,
        warnings: [String] = []
    ) {
        self.httpStatus = httpStatus
        self.shortReason = shortReason.map { SecretRedactor.sanitize($0) }
        self.isTransientError = isTransientError
        self.warnings = warnings.map { SecretRedactor.sanitize($0, maxLength: 140) }
    }
}

public struct ProviderFetchResult: Sendable, Equatable {
    public let snapshot: ProviderSnapshot
    public let diagnostic: ProviderFetchDiagnostic?
    public let payloadShapes: [ProviderPayloadShape]

    public init(
        snapshot: ProviderSnapshot,
        diagnostic: ProviderFetchDiagnostic? = nil,
        payloadShapes: [ProviderPayloadShape] = []
    ) {
        self.snapshot = snapshot
        self.diagnostic = diagnostic
        self.payloadShapes = payloadShapes
    }
}

public protocol DiagnosableUsageProvider: UsageProvider {
    func fetchResult() async -> ProviderFetchResult
    func fetchResult(captureShape: Bool) async -> ProviderFetchResult
}

public extension DiagnosableUsageProvider {
    func fetchResult(captureShape: Bool) async -> ProviderFetchResult {
        await fetchResult()
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        await fetchResult().snapshot
    }
}

// MARK: - Exponential Backoff Policy

public enum ProviderBackoffPolicy {
    public static let baseDelay: TimeInterval = 60
    public static let maxDelay: TimeInterval = 900

    /// Returns exponential backoff seconds for consecutive transient failures (1 → 60s, 2 → 120s, 3 → 240s, 4 → 480s, 5+ → 900s).
    public static func delay(forConsecutiveFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        let exponent = min(failures - 1, 10)
        let multiplier = pow(2.0, Double(exponent))
        return min(maxDelay, baseDelay * multiplier)
    }
}

// MARK: - Reset Time & Formatting Helpers

public enum ResetTimeFormatter {
    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    /// Formats a reset date cleanly for dropdown detail cards (`Resets in 2h 14m`, `Resets Tue 9:00 AM`, `Resets Dec 9`).
    public static func formatResetText(
        resetsAt: Date?,
        now: Date,
        timeZone: TimeZone = .current
    ) -> String {
        guard let resetsAt else {
            return "Reset time unavailable"
        }
        let delta = resetsAt.timeIntervalSince(now)
        if delta <= 0 {
            return "Resetting"
        }
        if delta < 24 * 3600 {
            let totalMinutes = max(1, Int(ceil(delta / 60.0)))
            let hours = totalMinutes / 60
            let minutes = totalMinutes % 60
            if hours == 0 {
                return "Resets in \(minutes)m"
            }
            if minutes == 0 {
                return "Resets in \(hours)h"
            }
            return String(format: "Resets in %dh %02dm", locale: posixLocale, hours, minutes)
        }

        let formatter = DateFormatter()
        formatter.locale = posixLocale
        formatter.timeZone = timeZone
        if delta < 7 * 24 * 3600 {
            formatter.dateFormat = "EEE h:mm a"
            return "Resets \(formatter.string(from: resetsAt))"
        }

        formatter.dateFormat = "MMM d"
        return "Resets \(formatter.string(from: resetsAt))"
    }

    /// Formats a billing reset suffix (`resets Dec 9`), or `"Resetting"` when `resetsAt` is already in the past.
    public static func formatBillingReset(
        resetsAt: Date?,
        now: Date? = nil,
        timeZone: TimeZone = .current
    ) -> String? {
        guard let resetsAt else { return nil }
        if let now, resetsAt <= now {
            return "Resetting"
        }
        let formatter = DateFormatter()
        formatter.locale = posixLocale
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMM d"
        return "resets \(formatter.string(from: resetsAt))"
    }

    /// Returns `true` when `dollars` is a finite non-negative USD amount whose cent value fits in `Int`.
    public static func isRepresentableUSD(_ dollars: Double) -> Bool {
        guard dollars.isFinite, dollars >= 0 else { return false }
        let scaled = (dollars * 100.0).rounded()
        return Int(exactly: scaled) != nil
    }

    /// Formats USD amounts compactly (`$13.40`, `$20`) without ever trapping on out-of-range finite inputs.
    public static func formatUSD(_ dollars: Double) -> String {
        guard dollars.isFinite else { return "$0" }
        let clamped = max(0, dollars)
        let scaled = (clamped * 100.0).rounded()
        guard let cents = Int(exactly: scaled) else {
            return String(format: "$%.2f", locale: posixLocale, clamped)
        }
        if cents % 100 == 0 {
            return "$\(cents / 100)"
        }
        return String(format: "$%.2f", locale: posixLocale, Double(cents) / 100.0)
    }

    /// Formats compact age for stale local session data (`25m ago`, `2h ago`, `3d ago`).
    public static func formatAge(from date: Date, now: Date) -> String {
        let elapsed = max(0, now.timeIntervalSince(date))
        guard elapsed.isFinite else { return "just now" }
        guard let minutes = Int(exactly: floor(elapsed / 60.0)) else {
            return "long ago"
        }
        if minutes < 1 {
            return "just now"
        }
        if minutes < 60 {
            return "\(minutes)m ago"
        }
        let hours = minutes / 60
        if hours < 48 {
            return "\(hours)h ago"
        }
        let days = hours / 24
        return "\(days)d ago"
    }
}
