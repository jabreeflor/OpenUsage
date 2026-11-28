import CoreFoundation
import Foundation

/// Overflow-safe arithmetic and strict integer parsing helpers for local token log parsers and aggregators.
public enum CheckedTokenMath {
    /// Result of parsing an optional non-negative integer JSON field where `nil`/`NSNull` must be
    /// distinguished from an explicit `0` (e.g. a declared `total` field).
    public enum OptionalParsedInt: Sendable, Equatable {
        case absent
        case value(Int)
        case invalid
    }

    /// Sane upper bound for a single parsed token counter field (1 trillion tokens per record/field).
    public static let maxTokenFieldValue: Int = 1_000_000_000_000

    /// Parses an optional JSON numeric value, distinguishing absent/`null` from an explicit non-negative `Int`
    /// and rejecting booleans, strings, negative values, fractional numbers, or values outside `0...maxValue`.
    public static func parseOptionalNonNegativeInt(
        _ raw: Any?,
        maxValue: Int = CheckedTokenMath.maxTokenFieldValue
    ) -> OptionalParsedInt {
        guard let raw, !(raw is NSNull) else {
            return .absent
        }
        guard let parsed = parseNonNegativeInt(raw, maxValue: maxValue) else {
            return .invalid
        }
        return .value(parsed)
    }

    /// Validates that `subset` is a valid non-negative subset of `superset` (`0 <= subset <= superset`),
    /// returning the remaining non-subset portion `superset - subset` or `nil` when impossible.
    public static func validateSubset(_ subset: Int, of superset: Int) -> Int? {
        guard subset >= 0, superset >= 0, subset <= superset else {
            return nil
        }
        return superset - subset
    }

    /// Validates that when a record provides an explicit `declaredTotal`, it is consistent with its parts
    /// (`declaredTotal >= partsSum`). Returns `true` when `declaredTotal` is `nil` (omitted/null).
    public static func validateDeclaredTotal(_ declaredTotal: Int?, partsSum: Int) -> Bool {
        guard partsSum >= 0 else { return false }
        guard let declaredTotal else { return true }
        return declaredTotal >= partsSum
    }

    /// Parses a JSON numeric value as a non-negative `Int`, returning `0` for `nil`/`NSNull` (absent optional field)
    /// and `nil` for booleans, strings, negative values, fractional numbers, or values outside `0...maxValue`.
    public static func parseNonNegativeInt(_ raw: Any?, maxValue: Int = CheckedTokenMath.maxTokenFieldValue) -> Int? {
        guard let raw, !(raw is NSNull) else {
            return 0
        }
        let ceiling = max(0, maxValue)
        // Reject Swift Bool and CoreFoundation/JSON CFBoolean BEFORE any numeric bridging (`raw as? Int` bridges CFBoolean to 0/1).
        if type(of: raw) == Bool.self {
            return nil
        }
        if CFGetTypeID(raw as AnyObject) == CFBooleanGetTypeID() {
            return nil
        }
        if raw is String {
            return nil
        }
        if type(of: raw) == Int.self, let intVal = raw as? Int {
            return (intVal >= 0 && intVal <= ceiling) ? intVal : nil
        }
        if let num = raw as? NSNumber {
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                return nil
            }
            let typeChar = num.objCType.pointee
            switch typeChar {
            case 0x51, 0x4C, 0x49, 0x53, 0x43: // 'Q', 'L', 'I', 'S', 'C' (unsigned integer types)
                let u = num.uint64Value
                guard u <= UInt64(ceiling) else { return nil }
                return Int(u)
            case 0x71, 0x6C, 0x69, 0x73, 0x63: // 'q', 'l', 'i', 's', 'c' (signed integer types)
                let s = num.int64Value
                guard s >= 0, s <= Int64(ceiling) else { return nil }
                return Int(s)
            case 0x64, 0x66: // 'd', 'f' (floating point; also used by JSONSerialization for >Int64.max)
                let d = num.doubleValue
                // 9223372036854775808.0 == 2^63; any Double strictly below it fits in Int64 without trapping.
                guard d.isFinite, d >= 0, d < 9223372036854775808.0, d.rounded(.towardZero) == d else {
                    return nil
                }
                let converted = Int(d)
                guard converted <= ceiling else { return nil }
                return converted
            default:
                let d = num.doubleValue
                guard d.isFinite, d >= 0, d < 9223372036854775808.0, d.rounded(.towardZero) == d else {
                    return nil
                }
                let converted = Int(d)
                guard converted <= ceiling else { return nil }
                return converted
            }
        }
        return nil
    }

    /// Parses a non-negative base-10 integer from ASCII digit bytes, rejecting negative values,
    /// empty input, non-digits, or values exceeding `maxValue`.
    public static func parseNonNegativeInt(
        asciiDigits bytes: [UInt8],
        maxValue: Int = CheckedTokenMath.maxTokenFieldValue
    ) -> Int? {
        guard !bytes.isEmpty else { return nil }
        let ceiling = max(0, maxValue)
        var value = 0
        for byte in bytes {
            guard byte >= 48 && byte <= 57 else { return nil }
            let digit = Int(byte - 48)
            let (mul, mulOverflow) = value.multipliedReportingOverflow(by: 10)
            guard !mulOverflow else { return nil }
            let (next, addOverflow) = mul.addingReportingOverflow(digit)
            guard !addOverflow, next <= ceiling else { return nil }
            value = next
        }
        return value
    }

    public static func add(_ a: Int, _ b: Int) -> Int? {
        let (result, overflow) = a.addingReportingOverflow(b)
        return overflow ? nil : result
    }

    public static func subtract(_ a: Int, _ b: Int) -> Int? {
        let (result, overflow) = a.subtractingReportingOverflow(b)
        return overflow ? nil : result
    }

    public static func sum(_ values: Int...) -> Int? {
        var total = 0
        for value in values {
            let (next, overflow) = total.addingReportingOverflow(value)
            guard !overflow else { return nil }
            total = next
        }
        return total
    }

    public static func saturatingAdd(_ a: Int, _ b: Int) -> Int {
        let (result, overflow) = a.addingReportingOverflow(b)
        if !overflow { return result }
        return b >= 0 ? Int.max : Int.min
    }

    public static func saturatingSum(_ values: Int...) -> Int {
        var total = 0
        for value in values {
            total = saturatingAdd(total, value)
        }
        return total
    }
}

/// A single normalized token usage record emitted by a local log parser before day/hour bucketing.
public struct TokenUsageEvent: Sendable, Equatable {
    public let timestamp: Date
    public let provider: ProviderID
    public let model: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheTokens: Int
    public let requests: Int

    public var totalTokens: Int {
        CheckedTokenMath.saturatingSum(inputTokens, outputTokens, cacheTokens)
    }

    public init(
        timestamp: Date,
        provider: ProviderID,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheTokens: Int,
        requests: Int = 1
    ) {
        self.timestamp = timestamp
        self.provider = provider
        self.model = model
        self.inputTokens = max(0, inputTokens)
        self.outputTokens = max(0, outputTokens)
        self.cacheTokens = max(0, cacheTokens)
        self.requests = max(0, requests)
    }
}

/// Aggregates `TokenUsageEvent`s into `(dayKey, hour, provider, model)` `TokenBucket`s in the target calendar/time zone.
public enum TokenBucketAggregator {
    public static func aggregate(
        _ events: [TokenUsageEvent],
        calendar: Calendar = StatisticsAggregator.gregorianCalendar()
    ) -> [TokenBucket] {
        var accumulator = TokenBucketAccumulator()
        for event in events {
            let total = CheckedTokenMath.saturatingSum(event.inputTokens, event.outputTokens, event.cacheTokens)
            guard total > 0 || event.requests > 0 else {
                continue
            }
            let dayKey = StatisticsAggregator.dayKey(for: event.timestamp, calendar: calendar)
            let hour = calendar.component(.hour, from: event.timestamp)
            accumulator.saturatingAdd(
                dayKey: dayKey,
                hour: hour,
                provider: event.provider,
                model: event.model,
                inputTokens: event.inputTokens,
                outputTokens: event.outputTokens,
                cacheTokens: event.cacheTokens,
                requests: event.requests
            )
        }
        return accumulator.buckets()
    }

    /// Merges multiple `TokenBucket` arrays by summing tokens and requests for matching `(dayKey, hour, provider, model)` keys
    /// using saturating arithmetic so combined totals exceeding `Int.max` never crash or drop buckets.
    public static func merge(_ buckets: [TokenBucket]) -> [TokenBucket] {
        var accumulator = TokenBucketAccumulator()
        accumulator.saturatingAdd(buckets: buckets)
        return accumulator.buckets()
    }
}

/// Mutable accumulator supporting both additions and atomic replacement updates (for deduplicated streaming updates).
public struct TokenBucketAccumulator: Sendable {
    private struct Key: Hashable {
        let dayKey: String
        let hour: Int
        let provider: ProviderID
        let model: String
    }

    private struct Totals {
        var input: Int = 0
        var output: Int = 0
        var cache: Int = 0
        var requests: Int = 0
    }

    private var entries: [Key: Totals] = [:]

    public init(initialBuckets: [TokenBucket] = []) {
        add(buckets: initialBuckets)
    }

    public mutating func add(buckets: [TokenBucket]) {
        for bucket in buckets {
            _ = add(
                dayKey: bucket.dayKey,
                hour: bucket.hour,
                provider: bucket.provider,
                model: bucket.model,
                inputTokens: bucket.inputTokens,
                outputTokens: bucket.outputTokens,
                cacheTokens: bucket.cacheTokens,
                requests: bucket.requests
            )
        }
    }

    /// Merges existing `TokenBucket`s using saturating addition so cross-file or cross-source merges
    /// never overflow or silently drop accepted buckets.
    public mutating func saturatingAdd(buckets: [TokenBucket]) {
        for bucket in buckets {
            saturatingAdd(
                dayKey: bucket.dayKey,
                hour: bucket.hour,
                provider: bucket.provider,
                model: bucket.model,
                inputTokens: bucket.inputTokens,
                outputTokens: bucket.outputTokens,
                cacheTokens: bucket.cacheTokens,
                requests: bucket.requests
            )
        }
    }

    public mutating func saturatingAdd(
        dayKey: String,
        hour: Int,
        provider: ProviderID,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheTokens: Int,
        requests: Int
    ) {
        let key = Key(
            dayKey: dayKey,
            hour: min(23, max(0, hour)),
            provider: provider,
            model: model
        )
        let current = entries[key] ?? Totals()
        let updated = Totals(
            input: CheckedTokenMath.saturatingAdd(current.input, max(0, inputTokens)),
            output: CheckedTokenMath.saturatingAdd(current.output, max(0, outputTokens)),
            cache: CheckedTokenMath.saturatingAdd(current.cache, max(0, cacheTokens)),
            requests: CheckedTokenMath.saturatingAdd(current.requests, max(0, requests))
        )
        commit(updated, for: key)
    }

    /// Adds token and request deltas to the target bucket using overflow-checked arithmetic.
    /// Returns `false` without modifying any bucket if the update would overflow `Int`
    /// (including the bucket's combined `input + output + cache` total).
    @discardableResult
    public mutating func add(
        dayKey: String,
        hour: Int,
        provider: ProviderID,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheTokens: Int,
        requests: Int
    ) -> Bool {
        let key = Key(
            dayKey: dayKey,
            hour: min(23, max(0, hour)),
            provider: provider,
            model: model
        )
        let current = entries[key] ?? Totals()
        guard let updated = Self.applyDelta(
            to: current,
            inputDelta: inputTokens,
            outputDelta: outputTokens,
            cacheDelta: cacheTokens,
            requestsDelta: requests
        ) else {
            return false
        }
        commit(updated, for: key)
        return true
    }

    /// Atomically replaces a previously counted message snapshot with an updated snapshot, moving both
    /// tokens and its request count when `(dayKey, hour, model)` changes.
    /// Returns `false` without modifying any bucket if either bucket update would overflow `Int`.
    @discardableResult
    public mutating func replace(
        previous: CountedUsageSnapshot,
        with next: CountedUsageSnapshot,
        provider: ProviderID
    ) -> Bool {
        let oldKey = Key(
            dayKey: previous.dayKey,
            hour: min(23, max(0, previous.hour)),
            provider: provider,
            model: previous.model
        )
        let newKey = Key(
            dayKey: next.dayKey,
            hour: min(23, max(0, next.hour)),
            provider: provider,
            model: next.model
        )

        if oldKey == newKey {
            let current = entries[oldKey] ?? Totals()
            guard let afterRemove = Self.applyDelta(
                to: current,
                inputDelta: -previous.inputTokens,
                outputDelta: -previous.outputTokens,
                cacheDelta: -previous.cacheTokens,
                requestsDelta: -1,
                validateTotal: false
            ),
            let finalTotals = Self.applyDelta(
                to: afterRemove,
                inputDelta: next.inputTokens,
                outputDelta: next.outputTokens,
                cacheDelta: next.cacheTokens,
                requestsDelta: 1,
                validateTotal: true
            ) else {
                return false
            }
            commit(finalTotals, for: oldKey)
            return true
        } else {
            let oldCurrent = entries[oldKey] ?? Totals()
            let newCurrent = entries[newKey] ?? Totals()
            guard let updatedOld = Self.applyDelta(
                to: oldCurrent,
                inputDelta: -previous.inputTokens,
                outputDelta: -previous.outputTokens,
                cacheDelta: -previous.cacheTokens,
                requestsDelta: -1,
                validateTotal: true
            ),
            let updatedNew = Self.applyDelta(
                to: newCurrent,
                inputDelta: next.inputTokens,
                outputDelta: next.outputTokens,
                cacheDelta: next.cacheTokens,
                requestsDelta: 1,
                validateTotal: true
            ) else {
                return false
            }
            commit(updatedOld, for: oldKey)
            commit(updatedNew, for: newKey)
            return true
        }
    }

    private static func applyDelta(
        to current: Totals,
        inputDelta: Int,
        outputDelta: Int,
        cacheDelta: Int,
        requestsDelta: Int,
        validateTotal: Bool = true
    ) -> Totals? {
        guard let nextInput = CheckedTokenMath.add(current.input, inputDelta),
              let nextOutput = CheckedTokenMath.add(current.output, outputDelta),
              let nextCache = CheckedTokenMath.add(current.cache, cacheDelta),
              let nextRequests = CheckedTokenMath.add(current.requests, requestsDelta) else {
            return nil
        }
        if validateTotal {
            let clampedInput = max(0, nextInput)
            let clampedOutput = max(0, nextOutput)
            let clampedCache = max(0, nextCache)
            guard CheckedTokenMath.sum(clampedInput, clampedOutput, clampedCache) != nil else {
                return nil
            }
        }
        return Totals(
            input: nextInput,
            output: nextOutput,
            cache: nextCache,
            requests: nextRequests
        )
    }

    private mutating func commit(_ totals: Totals, for key: Key) {
        if totals.input <= 0 && totals.output <= 0 && totals.cache <= 0 && totals.requests <= 0 {
            entries.removeValue(forKey: key)
        } else {
            entries[key] = totals
        }
    }

    public func buckets() -> [TokenBucket] {
        entries.compactMap { key, totals -> TokenBucket? in
            let inp = max(0, totals.input)
            let out = max(0, totals.output)
            let cache = max(0, totals.cache)
            let req = max(0, totals.requests)
            let total = CheckedTokenMath.saturatingSum(inp, out, cache)
            guard total > 0 || req > 0 else {
                return nil
            }
            return TokenBucket(
                dayKey: key.dayKey,
                hour: key.hour,
                provider: key.provider,
                model: key.model,
                inputTokens: inp,
                outputTokens: out,
                cacheTokens: cache,
                requests: req
            )
        }
        .sorted { lhs, rhs in
            if lhs.dayKey != rhs.dayKey { return lhs.dayKey < rhs.dayKey }
            if lhs.hour != rhs.hour { return lhs.hour < rhs.hour }
            if lhs.provider.rawValue != rhs.provider.rawValue { return lhs.provider.rawValue < rhs.provider.rawValue }
            return lhs.model < rhs.model
        }
    }
}

// MARK: - Incremental Source Protocol & Persisted Cache State

/// Snapshot of a single deduplicated message/request's counted usage for incremental update replacement.
public struct CountedUsageSnapshot: Codable, Sendable, Equatable {
    public let dayKey: String
    public let hour: Int
    public let model: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheTokens: Int

    public init(
        dayKey: String,
        hour: Int,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheTokens: Int
    ) {
        self.dayKey = dayKey
        self.hour = hour
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheTokens = cacheTokens
    }
}

/// Raw cumulative usage counters stored per Codex rollout file so appended events compute exact deltas.
public struct CodexTokenTotals: Codable, Sendable, Equatable {
    public let inputTokens: Int
    public let cachedInputTokens: Int
    public let cacheWriteInputTokens: Int
    public let outputTokens: Int
    public let reasoningOutputTokens: Int
    public let totalTokens: Int
    public let declaredTotalTokens: Int?

    public init(
        inputTokens: Int,
        cachedInputTokens: Int,
        cacheWriteInputTokens: Int = 0,
        outputTokens: Int,
        reasoningOutputTokens: Int = 0,
        totalTokens: Int,
        declaredTotalTokens: Int? = nil
    ) {
        self.inputTokens = max(0, inputTokens)
        self.cachedInputTokens = max(0, cachedInputTokens)
        self.cacheWriteInputTokens = max(0, cacheWriteInputTokens)
        self.outputTokens = max(0, outputTokens)
        self.reasoningOutputTokens = max(0, reasoningOutputTokens)
        self.totalTokens = max(0, totalTokens)
        self.declaredTotalTokens = declaredTotalTokens.map { max(0, $0) }
    }
}

/// Incremental per-file cache state persisted in Application Support (never stores credentials or prompt content).
public struct FileCacheEntry: Codable, Sendable, Equatable {
    public var fileSize: UInt64
    public var mtimeNanos: Int64
    public var inode: UInt64
    public var device: UInt64
    public var offset: UInt64
    public var buckets: [TokenBucket]

    // Optional source-specific incremental cursors
    public var prefixFingerprint: String?
    /// Full-file SHA-256 over `0..<fileSize` recorded once the file has been inspected to EOF,
    /// allowing unchanged files with an incomplete trailing JSONL line (`offset < fileSize`)
    /// to avoid repeat downloads/parses while keeping `offset` before the incomplete record.
    public var eofFingerprint: String?
    public var secondarySize: UInt64?
    public var secondaryMtimeNanos: Int64?
    public var secondaryInode: UInt64?
    public var secondaryDevice: UInt64?
    public var seenMessages: [String: CountedUsageSnapshot]?
    public var currentModel: String?
    public var previousCodexTotals: CodexTokenTotals?
    public var watermarkTimestamp: Int64?

    public init(
        fileSize: UInt64 = 0,
        mtimeNanos: Int64 = 0,
        inode: UInt64 = 0,
        device: UInt64 = 0,
        offset: UInt64 = 0,
        buckets: [TokenBucket] = [],
        prefixFingerprint: String? = nil,
        eofFingerprint: String? = nil,
        secondarySize: UInt64? = nil,
        secondaryMtimeNanos: Int64? = nil,
        secondaryInode: UInt64? = nil,
        secondaryDevice: UInt64? = nil,
        seenMessages: [String: CountedUsageSnapshot]? = nil,
        currentModel: String? = nil,
        previousCodexTotals: CodexTokenTotals? = nil,
        watermarkTimestamp: Int64? = nil
    ) {
        self.fileSize = fileSize
        self.mtimeNanos = mtimeNanos
        self.inode = inode
        self.device = device
        self.offset = offset
        self.buckets = buckets
        self.prefixFingerprint = prefixFingerprint
        self.eofFingerprint = eofFingerprint
        self.secondarySize = secondarySize
        self.secondaryMtimeNanos = secondaryMtimeNanos
        self.secondaryInode = secondaryInode
        self.secondaryDevice = secondaryDevice
        self.seenMessages = seenMessages
        self.currentModel = currentModel
        self.previousCodexTotals = previousCodexTotals
        self.watermarkTimestamp = watermarkTimestamp
    }
}

/// Cached state for one `LocalToolSource`.
public struct SourceCacheState: Codable, Sendable, Equatable {
    public var files: [String: FileCacheEntry]

    public init(files: [String: FileCacheEntry] = [:]) {
        self.files = files
    }

    public func mergedBuckets() -> [TokenBucket] {
        var accumulator = TokenBucketAccumulator()
        for entry in files.values {
            accumulator.saturatingAdd(buckets: entry.buckets)
        }
        return accumulator.buckets()
    }
}

/// Top-level persisted cache document stored in `~/Library/Application Support/OpenUsage`.
public struct TokenLogCacheDocument: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 3

    public var schemaVersion: Int
    public var timeZoneIdentifier: String
    public var sources: [String: SourceCacheState]

    public init(
        schemaVersion: Int = currentSchemaVersion,
        timeZoneIdentifier: String = TimeZone.current.identifier,
        sources: [String: SourceCacheState] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.timeZoneIdentifier = timeZoneIdentifier
        self.sources = sources
    }

    public func state(for source: LocalToolSource) -> SourceCacheState {
        sources[source.rawValue] ?? SourceCacheState()
    }

    public mutating func setState(_ state: SourceCacheState, for source: LocalToolSource) {
        sources[source.rawValue] = state
    }
}

/// Result of the fast local-only refresh pass for one `IncrementalTokenLogSource`.
public struct LocalRefreshResult: Sendable, Equatable {
    public let buckets: [TokenBucket]
    public let pendingEvictedFiles: [PendingEvictedLogFile]
    /// Cache keys whose status could not be determined during this pass (e.g. transient `EIO`/`EACCES`),
    /// so any existing pending entry and retry backoff should be preserved.
    public let inconclusiveCacheKeys: Set<String>
    /// Cache keys definitively resolved during this pass (counted, confirmed removed, or aged past 31-day cutoff).
    public let resolvedCacheKeys: Set<String>

    public init(
        buckets: [TokenBucket],
        pendingEvictedFiles: [PendingEvictedLogFile] = [],
        inconclusiveCacheKeys: Set<String> = [],
        resolvedCacheKeys: Set<String> = []
    ) {
        self.buckets = buckets
        self.pendingEvictedFiles = pendingEvictedFiles
        self.inconclusiveCacheKeys = inconclusiveCacheKeys
        self.resolvedCacheKeys = resolvedCacheKeys
    }
}

/// Extension of `TokenLogSource` supporting incremental file-offset caching, folder watching,
/// and two-pass handling of iCloud-evicted (dataless) files.
public protocol IncrementalTokenLogSource: TokenLogSource {
    var toolSource: LocalToolSource { get }
    var sourceLabel: String { get }
    var watchDirectories: [URL] { get }

    func refresh(state: inout SourceCacheState, calendar: Calendar) throws -> [TokenBucket]

    /// Fast local-only pass: counts already-local files immediately without materializing evicted files,
    /// returning local buckets plus any recent evicted files queued for the low-priority background pass.
    func refreshLocalPass(
        state: inout SourceCacheState,
        calendar: Calendar,
        now: Date
    ) throws -> LocalRefreshResult

    /// Fast local-only pass that can skip files whose exact on-disk version is currently being scanned
    /// by an in-flight background materialization worker so a finishing late worker is not parsed twice.
    func refreshLocalPass(
        state: inout SourceCacheState,
        calendar: Calendar,
        now: Date,
        shouldSkipInFlightVersion: (_ cacheKey: String, _ metadata: FileMetadata, _ secondaryMetadata: FileMetadata?) -> Bool
    ) throws -> LocalRefreshResult

    /// Materializes and scans a single pending evicted file through the same single-descriptor
    /// transactional scan and per-file cache used by the local pass, validating current file version
    /// and age against `now` before requesting any download.
    func scanEvictedFile(
        _ file: PendingEvictedLogFile,
        state: inout SourceCacheState,
        calendar: Calendar,
        now: Date
    ) -> EvictedMaterializationOutcome

    /// Returns `true` only when a previously pending file that was not enumerated during a local refresh
    /// is confirmed absent (`ENOENT`/`ENOTDIR`) or no longer a regular file. Returns `false` on transient
    /// metadata errors (e.g. `EIO`, `EACCES`) or if the file still exists so pending state and retry backoff
    /// are retained across inconclusive refreshes.
    func isPendingFileConfirmedRemoved(_ file: PendingEvictedLogFile) -> Bool
}

public extension IncrementalTokenLogSource {
    func loadBuckets() async throws -> [TokenBucket] {
        var state = SourceCacheState()
        return try refresh(state: &state, calendar: StatisticsAggregator.gregorianCalendar())
    }

    func refreshLocalPass(
        state: inout SourceCacheState,
        calendar: Calendar,
        now: Date
    ) throws -> LocalRefreshResult {
        let buckets = try refresh(state: &state, calendar: calendar)
        return LocalRefreshResult(buckets: buckets, pendingEvictedFiles: [])
    }

    func refreshLocalPass(
        state: inout SourceCacheState,
        calendar: Calendar,
        now: Date,
        shouldSkipInFlightVersion: (_ cacheKey: String, _ metadata: FileMetadata, _ secondaryMetadata: FileMetadata?) -> Bool
    ) throws -> LocalRefreshResult {
        try refreshLocalPass(state: &state, calendar: calendar, now: now)
    }

    func scanEvictedFile(
        _ file: PendingEvictedLogFile,
        state: inout SourceCacheState,
        calendar: Calendar,
        now: Date
    ) -> EvictedMaterializationOutcome {
        .counted
    }

    func scanEvictedFile(
        _ file: PendingEvictedLogFile,
        state: inout SourceCacheState,
        calendar: Calendar
    ) -> EvictedMaterializationOutcome {
        scanEvictedFile(file, state: &state, calendar: calendar, now: Date())
    }

    func isPendingFileConfirmedRemoved(_ file: PendingEvictedLogFile) -> Bool {
        true
    }
}

/// Persists `TokenLogCacheDocument` in Application Support (strictly token counts + file offsets, no credentials).
public struct TokenLogCacheStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL = TokenLogCacheStore.defaultCacheURL()) {
        self.fileURL = fileURL
    }

    public static func defaultCacheURL(fileManager: FileManager = .default) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("OpenUsage", isDirectory: true)
            .appendingPathComponent("token-log-cache-v1.json", isDirectory: false)
    }

    public func load(expectedTimeZone: TimeZone = .current) -> TokenLogCacheDocument {
        guard let data = try? Data(contentsOf: fileURL),
              let doc = try? JSONDecoder().decode(TokenLogCacheDocument.self, from: data),
              doc.schemaVersion == TokenLogCacheDocument.currentSchemaVersion,
              doc.timeZoneIdentifier == expectedTimeZone.identifier else {
            return TokenLogCacheDocument(timeZoneIdentifier: expectedTimeZone.identifier)
        }
        return doc
    }

    public func save(_ document: TokenLogCacheDocument) {
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            let data = try encoder.encode(document)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Cache persistence is best-effort; never crash the app on disk write errors.
        }
    }
}
