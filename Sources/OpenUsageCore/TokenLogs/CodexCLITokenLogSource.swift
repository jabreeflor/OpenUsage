import CryptoKit
import Darwin
import Foundation

/// Parses Codex CLI local JSONL rollout logs under `~/.codex/sessions/**/rollout-*.jsonl`.
///
/// Verified against real Codex CLI rollout logs on macOS:
/// - `turn_context` events set the active model in `payload.model` (and `session_meta` may carry `payload.model`).
/// - `event_msg` lines with `payload.type == "token_count"` carry `payload.info.total_token_usage` (cumulative)
///   and `payload.info.last_token_usage` (per-turn). Consecutive `token_count` events can repeat identical
///   `total_token_usage` snapshots and are de-duplicated by tracking the previous cumulative totals.
/// - `input_tokens` includes `cached_input_tokens` (`input_tokens + output_tokens == total_tokens`) and
///   `output_tokens` includes `reasoning_output_tokens`, so non-cached input is `input_tokens - cached_input_tokens`
///   and records with `cached_input_tokens > input_tokens` or inconsistent totals are rejected before mutating state.
public struct CodexCLITokenLogSource: IncrementalTokenLogSource, Sendable {
    public let provider: ProviderID = .chatgpt
    public let toolSource: LocalToolSource = .codexCLI
    public let sourceLabel: String = "~/.codex/sessions"
    public let rootDirectory: URL
    public let fileAccess: any TokenLogFileAccess
    internal let maxScanAttempts: Int
    internal let onLineScannedForTesting: (@Sendable (_ relativePath: String, _ attempt: Int, _ lineNumber: Int) -> Void)?

    private static let tokenCountNeedle = Array("\"token_count\"".utf8)
    private static let turnContextNeedle = Array("\"turn_context\"".utf8)
    private static let sessionMetaNeedle = Array("\"session_meta\"".utf8)

    public init(
        rootDirectory: URL = CodexCLITokenLogSource.defaultRootDirectory(),
        fileAccess: any TokenLogFileAccess = SystemTokenLogFileAccess()
    ) {
        self.rootDirectory = rootDirectory
        self.fileAccess = fileAccess
        self.maxScanAttempts = 3
        self.onLineScannedForTesting = nil
    }

    internal init(
        rootDirectory: URL = CodexCLITokenLogSource.defaultRootDirectory(),
        fileAccess: any TokenLogFileAccess = SystemTokenLogFileAccess(),
        maxScanAttempts: Int = 3,
        onLineScannedForTesting: (@Sendable (_ relativePath: String, _ attempt: Int, _ lineNumber: Int) -> Void)? = nil
    ) {
        self.rootDirectory = rootDirectory
        self.fileAccess = fileAccess
        self.maxScanAttempts = max(1, maxScanAttempts)
        self.onLineScannedForTesting = onLineScannedForTesting
    }

    public static func defaultRootDirectory() -> URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    public var watchDirectories: [URL] {
        [rootDirectory]
    }

    public func refresh(state: inout SourceCacheState, calendar: Calendar) throws -> [TokenBucket] {
        try refreshLocalPass(state: &state, calendar: calendar, now: Date()).buckets
    }

    public func refreshLocalPass(
        state: inout SourceCacheState,
        calendar: Calendar,
        now: Date
    ) throws -> LocalRefreshResult {
        try refreshLocalPass(state: &state, calendar: calendar, now: now) { _, _, _ in false }
    }

    public func refreshLocalPass(
        state: inout SourceCacheState,
        calendar: Calendar,
        now: Date,
        shouldSkipInFlightVersion: (_ cacheKey: String, _ metadata: FileMetadata, _ secondaryMetadata: FileMetadata?) -> Bool
    ) throws -> LocalRefreshResult {
        let discovered = fileAccess.discoverFiles(under: rootDirectory) { url in
            let name = url.lastPathComponent
            return name.hasPrefix("rollout-") && url.pathExtension.lowercased() == "jsonl"
        }

        let livePaths = Set(discovered.map(\.relativePath))
        for stalePath in state.files.keys where !livePaths.contains(stalePath) {
            let staleURL = rootDirectory.appendingPathComponent(stalePath, isDirectory: false)
            do {
                if let meta = try fileAccess.readMetadataOrThrow(at: staleURL), meta.isRegularFile {
                    continue
                }
                state.files.removeValue(forKey: stalePath)
            } catch {
                continue
            }
        }

        var pendingEvicted: [PendingEvictedLogFile] = []
        var inconclusiveCacheKeys: Set<String> = []
        var resolvedCacheKeys: Set<String> = []
        for file in discovered {
            let result = scanFile(
                at: file.url,
                relativePath: file.relativePath,
                allowMaterialization: false,
                expectedVersion: nil,
                materializationNow: nil,
                shouldSkipInFlightVersion: shouldSkipInFlightVersion,
                state: &state,
                calendar: calendar
            )
            switch result {
            case .skippedDataless(let meta):
                if EvictedLogPolicy.isRecentEnoughToMaterialize(mtimeNanos: meta.mtimeNanos, now: now) {
                    pendingEvicted.append(
                        PendingEvictedLogFile(
                            toolSource: toolSource,
                            url: file.url,
                            relativePath: file.relativePath,
                            cacheKey: file.relativePath,
                            metadata: meta
                        )
                    )
                } else {
                    resolvedCacheKeys.insert(file.relativePath)
                }
            case .counted, .removed, .skippedTooOld, .staleVersion:
                resolvedCacheKeys.insert(file.relativePath)
            case .stillDataless, .failed:
                inconclusiveCacheKeys.insert(file.relativePath)
            }
        }

        return LocalRefreshResult(
            buckets: state.mergedBuckets(),
            pendingEvictedFiles: pendingEvicted,
            inconclusiveCacheKeys: inconclusiveCacheKeys,
            resolvedCacheKeys: resolvedCacheKeys
        )
    }

    public func isPendingFileConfirmedRemoved(_ file: PendingEvictedLogFile) -> Bool {
        do {
            guard let meta = try fileAccess.readMetadataOrThrow(at: file.url) else {
                return true
            }
            return !meta.isRegularFile
        } catch {
            return false
        }
    }

    public func scanEvictedFile(
        _ file: PendingEvictedLogFile,
        state: inout SourceCacheState,
        calendar: Calendar,
        now: Date
    ) -> EvictedMaterializationOutcome {
        switch scanFile(
            at: file.url,
            relativePath: file.relativePath,
            allowMaterialization: true,
            expectedVersion: file.metadata,
            materializationNow: now,
            state: &state,
            calendar: calendar
        ) {
        case .counted:
            return .counted
        case .removed:
            return .removed
        case .skippedTooOld:
            return .skippedTooOld
        case .staleVersion:
            return .staleVersion
        case .skippedDataless, .stillDataless:
            return .stillDataless
        case .failed:
            return .failed
        }
    }

    private enum FileScanResult {
        case counted
        case removed
        case skippedTooOld
        case staleVersion
        case skippedDataless(FileMetadata)
        case stillDataless
        case failed
    }

    private enum ScanAttemptOutcome {
        case done
        case removed
        case skippedTooOld
        case staleVersion
        case retry
        case skippedDataless(FileMetadata)
        case stillDataless
        case preserveExisting
    }

    @discardableResult
    private func scanFile(
        at url: URL,
        relativePath: String,
        allowMaterialization: Bool,
        expectedVersion: FileMetadata?,
        materializationNow: Date?,
        shouldSkipInFlightVersion: (_ cacheKey: String, _ metadata: FileMetadata, _ secondaryMetadata: FileMetadata?) -> Bool = { _, _, _ in false },
        state: inout SourceCacheState,
        calendar: Calendar
    ) -> FileScanResult {
        for attempt in 1...maxScanAttempts {
            let outcome = runScanAttempt(
                at: url,
                relativePath: relativePath,
                attempt: attempt,
                allowMaterialization: allowMaterialization,
                expectedVersion: expectedVersion,
                materializationNow: materializationNow,
                shouldSkipInFlightVersion: shouldSkipInFlightVersion,
                state: &state,
                calendar: calendar
            )
            switch outcome {
            case .done:
                return .counted
            case .removed:
                return .removed
            case .skippedTooOld:
                return .skippedTooOld
            case .staleVersion:
                return .staleVersion
            case .skippedDataless(let meta):
                return .skippedDataless(meta)
            case .stillDataless:
                return .stillDataless
            case .preserveExisting:
                return .failed
            case .retry:
                continue
            }
        }
        // Exhausted retries due to concurrent rotation/mutation: in local pass drop cached state so the next refresh rescans from 0.
        if !allowMaterialization {
            state.files.removeValue(forKey: relativePath)
        }
        return .failed
    }

    private func runScanAttempt(
        at url: URL,
        relativePath: String,
        attempt: Int,
        allowMaterialization: Bool,
        expectedVersion: FileMetadata?,
        materializationNow: Date?,
        shouldSkipInFlightVersion: (_ cacheKey: String, _ metadata: FileMetadata, _ secondaryMetadata: FileMetadata?) -> Bool,
        state: inout SourceCacheState,
        calendar: Calendar
    ) -> ScanAttemptOutcome {
        let preMeta: FileMetadata
        do {
            guard let meta = try fileAccess.readMetadataOrThrow(at: url) else {
                state.files.removeValue(forKey: relativePath)
                return .removed
            }
            preMeta = meta
        } catch {
            return .preserveExisting
        }
        guard preMeta.isRegularFile else {
            state.files.removeValue(forKey: relativePath)
            return .removed
        }
        if !allowMaterialization, shouldSkipInFlightVersion(relativePath, preMeta, nil) {
            return .preserveExisting
        }
        if preMeta.isDataless {
            if let expectedVersion {
                if let materializationNow,
                   !EvictedLogPolicy.isRecentEnoughToMaterialize(mtimeNanos: preMeta.mtimeNanos, now: materializationNow) {
                    return .skippedTooOld
                }
                guard EvictedLogPolicy.sameFileVersion(preMeta, expectedVersion) else {
                    return .staleVersion
                }
            }
            if let existing = state.files[relativePath],
               EvictedLogPolicy.isCacheEntryUpToDate(existing, for: preMeta) {
                return .done
            }
            if !allowMaterialization {
                return .skippedDataless(preMeta)
            }
        } else if let expectedVersion {
            guard EvictedLogPolicy.sameFileVersion(preMeta, expectedVersion) else {
                return .staleVersion
            }
        }

        let fd = fileAccess.openReadOnly(at: url, allowMaterialization: allowMaterialization)
        guard fd >= 0 else {
            if errno == ENOENT || errno == ENOTDIR || errno == ELOOP {
                state.files.removeValue(forKey: relativePath)
                return .removed
            }
            return .preserveExisting
        }
        defer { fileAccess.close(fd: fd) }

        guard let openMeta = fileAccess.readMetadata(fd: fd) else {
            return .retry
        }
        guard openMeta.isRegularFile else {
            state.files.removeValue(forKey: relativePath)
            return .removed
        }
        if openMeta.isDataless {
            return allowMaterialization ? .stillDataless : .skippedDataless(openMeta)
        }
        if let expectedVersion, !EvictedLogPolicy.sameFileVersion(openMeta, expectedVersion) {
            return .staleVersion
        }

        let existing = state.files[relativePath]
        let startOffset: UInt64
        let initialHasher: SHA256
        var accumulator: TokenBucketAccumulator
        var currentModel: String?
        var previousTotals: CodexTokenTotals?

        if let existing,
           existing.device == openMeta.device,
           existing.inode == openMeta.inode,
           openMeta.mtimeNanos >= existing.mtimeNanos,
           openMeta.size >= existing.offset {
            if existing.fileSize == openMeta.size,
               existing.mtimeNanos == openMeta.mtimeNanos,
               let expectedEOFFingerprint = existing.eofFingerprint
                   ?? (existing.offset == openMeta.size ? existing.prefixFingerprint : nil),
               let fullHasher = StreamingLineReader.prefixHasher(fd: fd, upToOffset: openMeta.size),
               StreamingLineReader.hexDigest(of: fullHasher) == expectedEOFFingerprint {
                return StreamingLineReader.verifyUnchanged(at: url, fd: fd, since: openMeta, fileAccess: fileAccess)
                    ? .done
                    : .retry
            }

            if existing.offset == 0 {
                if openMeta.size == 0
                    && existing.fileSize == 0
                    && existing.mtimeNanos == openMeta.mtimeNanos {
                    return StreamingLineReader.verifyUnchanged(at: url, fd: fd, since: openMeta, fileAccess: fileAccess)
                        ? .done
                        : .retry
                }
                startOffset = 0
                initialHasher = SHA256()
                accumulator = TokenBucketAccumulator()
                currentModel = nil
                previousTotals = nil
            } else if let savedFingerprint = existing.prefixFingerprint,
                      let prefixHasher = StreamingLineReader.prefixHasher(fd: fd, upToOffset: existing.offset),
                      StreamingLineReader.hexDigest(of: prefixHasher) == savedFingerprint {
                startOffset = existing.offset
                initialHasher = prefixHasher
                accumulator = TokenBucketAccumulator(initialBuckets: existing.buckets)
                currentModel = existing.currentModel
                previousTotals = existing.previousCodexTotals
            } else {
                startOffset = 0
                initialHasher = SHA256()
                accumulator = TokenBucketAccumulator()
                currentModel = nil
                previousTotals = nil
            }
        } else {
            startOffset = 0
            initialHasher = SHA256()
            accumulator = TokenBucketAccumulator()
            currentModel = nil
            previousTotals = nil
        }

        var lineCounter = 0
        let readResult: LineReadResult
        do {
            readResult = try StreamingLineReader.readLines(
                fd: fd,
                fromOffset: startOffset,
                initialHasher: initialHasher
            ) { lineData, endedWithNewline in
                lineCounter += 1
                defer {
                    onLineScannedForTesting?(relativePath, attempt, lineCounter)
                }

                let interesting = StreamingLineReader.dataContainsASCII(lineData, needle: Self.tokenCountNeedle)
                    || StreamingLineReader.dataContainsASCII(lineData, needle: Self.turnContextNeedle)
                    || StreamingLineReader.dataContainsASCII(lineData, needle: Self.sessionMetaNeedle)

                guard interesting else {
                    if !endedWithNewline, (try? JSONSerialization.jsonObject(with: lineData)) == nil {
                        return .keepUnconsumed
                    }
                    return .advance
                }

                guard let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                    return endedWithNewline ? .advance : .keepUnconsumed
                }

                processParsedLine(
                    object,
                    calendar: calendar,
                    currentModel: &currentModel,
                    previousTotals: &previousTotals,
                    accumulator: &accumulator
                )
                return .advance
            }
        } catch {
            if !StreamingLineReader.verifyUnchanged(at: url, fd: fd, since: openMeta, fileAccess: fileAccess) {
                return .retry
            }
            return .preserveExisting
        }

        guard readResult.eofOffset == openMeta.size,
              StreamingLineReader.verifyUnchanged(at: url, fd: fd, since: openMeta, fileAccess: fileAccess) else {
            return .retry
        }

        state.files[relativePath] = FileCacheEntry(
            fileSize: openMeta.size,
            mtimeNanos: openMeta.mtimeNanos,
            inode: openMeta.inode,
            device: openMeta.device,
            offset: readResult.consumedOffset,
            buckets: accumulator.buckets(),
            prefixFingerprint: readResult.consumedFingerprint,
            eofFingerprint: readResult.eofFingerprint,
            currentModel: currentModel,
            previousCodexTotals: previousTotals
        )
        return .done
    }

    private func processParsedLine(
        _ object: [String: Any],
        calendar: Calendar,
        currentModel: inout String?,
        previousTotals: inout CodexTokenTotals?,
        accumulator: inout TokenBucketAccumulator
    ) {
        guard let lineType = object["type"] as? String else { return }
        let payload = object["payload"] as? [String: Any] ?? [:]

        switch lineType {
        case "turn_context":
            if let model = cleanedString(payload["model"]) {
                currentModel = model
            }

        case "session_meta":
            if currentModel == nil, let model = cleanedString(payload["model"]) {
                currentModel = model
            }

        case "event_msg":
            guard (payload["type"] as? String) == "token_count" else { return }
            guard let info = payload["info"] as? [String: Any] else { return }
            // Validate timestamp BEFORE inspecting or advancing any counters/model state.
            guard let date = parseTimestamp(object["timestamp"]) else { return }

            let parsedTotal = parseTotals(info["total_token_usage"])
            let parsedLast = parseTotals(info["last_token_usage"])

            let totalUsage: CodexTokenTotals?
            switch parsedTotal {
            case .invalid:
                return
            case .absent, .zero:
                totalUsage = nil
            case .valid(let totals):
                totalUsage = totals
            }

            let lastUsage: CodexTokenTotals?
            switch parsedLast {
            case .invalid:
                return
            case .absent, .zero:
                lastUsage = nil
            case .valid(let totals):
                lastUsage = totals
            }

            let delta: CodexTokenTotals?
            if let total = totalUsage {
                if let prev = previousTotals {
                    // Repeated identical cumulative snapshot: skip to avoid double-counting.
                    if total == prev {
                        return
                    }
                    if total.inputTokens >= prev.inputTokens,
                       total.outputTokens >= prev.outputTokens,
                       total.cachedInputTokens >= prev.cachedInputTokens,
                       total.cacheWriteInputTokens >= prev.cacheWriteInputTokens {
                        let deltaDeclaredTotal: Int?
                        if let totalDecl = total.declaredTotalTokens, let prevDecl = prev.declaredTotalTokens {
                            guard totalDecl >= prevDecl else {
                                return
                            }
                            deltaDeclaredTotal = totalDecl - prevDecl
                        } else {
                            deltaDeclaredTotal = nil
                        }
                        delta = CodexTokenTotals(
                            inputTokens: total.inputTokens - prev.inputTokens,
                            cachedInputTokens: total.cachedInputTokens - prev.cachedInputTokens,
                            cacheWriteInputTokens: total.cacheWriteInputTokens - prev.cacheWriteInputTokens,
                            outputTokens: total.outputTokens - prev.outputTokens,
                            reasoningOutputTokens: max(0, total.reasoningOutputTokens - prev.reasoningOutputTokens),
                            totalTokens: deltaDeclaredTotal ?? max(0, total.totalTokens - prev.totalTokens),
                            declaredTotalTokens: deltaDeclaredTotal
                        )
                    } else {
                        // Cumulative counters reset (e.g. session compaction/restart): fall back to per-turn usage.
                        delta = lastUsage ?? total
                    }
                } else {
                    // First event in the file: prefer per-turn usage if available, else cumulative total.
                    delta = lastUsage ?? total
                }
            } else {
                delta = lastUsage
            }

            guard let delta else { return }

            let cachedInput = delta.cachedInputTokens
            let cacheWrite = delta.cacheWriteInputTokens
            let rawInput = delta.inputTokens
            let outputTokens = delta.outputTokens

            // In Codex rollouts, input_tokens includes cached_input_tokens (input_tokens + output_tokens == total_tokens).
            // Strictly validate subset and total consistency before touching accumulator or cumulative state.
            guard let cacheTokens = CheckedTokenMath.add(cachedInput, cacheWrite),
                  let rawPlusOutput = CheckedTokenMath.add(rawInput, outputTokens) else {
                return
            }
            let cacheWriteIncludedInInput = cacheWrite > 0
                && delta.declaredTotalTokens == rawPlusOutput
            let subtractedCache = cacheWriteIncludedInInput ? cacheTokens : cachedInput
            guard let inputTokens = CheckedTokenMath.validateSubset(subtractedCache, of: rawInput) else {
                return
            }

            guard let deltaTotal = CheckedTokenMath.sum(inputTokens, outputTokens, cacheTokens),
                  deltaTotal > 0,
                  CheckedTokenMath.validateDeclaredTotal(delta.declaredTotalTokens, partsSum: deltaTotal) else {
                return
            }

            let infoModel = cleanedString(info["model"])
            let model = infoModel ?? currentModel ?? "unknown"
            let dayKey = StatisticsAggregator.dayKey(for: date, calendar: calendar)
            let hour = calendar.component(.hour, from: date)
            guard accumulator.add(
                dayKey: dayKey,
                hour: hour,
                provider: .chatgpt,
                model: model,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheTokens: cacheTokens,
                requests: 1
            ) else {
                return
            }

            // Advance sticky model and cumulative counters only after validation and accumulation succeed.
            if let infoModel {
                currentModel = infoModel
            }
            if let totalUsage {
                previousTotals = totalUsage
            }

        default:
            break
        }
    }

    private enum ParsedTotals {
        case absent
        case zero
        case valid(CodexTokenTotals)
        case invalid
    }

    private func parseTotals(_ raw: Any?) -> ParsedTotals {
        guard let raw, !(raw is NSNull) else { return .absent }
        guard let dict = raw as? [String: Any] else { return .invalid }
        guard let input = CheckedTokenMath.parseNonNegativeInt(dict["input_tokens"]),
              let cachedInput = CheckedTokenMath.parseNonNegativeInt(dict["cached_input_tokens"]),
              let cacheWrite = CheckedTokenMath.parseNonNegativeInt(dict["cache_write_input_tokens"]),
              let output = CheckedTokenMath.parseNonNegativeInt(dict["output_tokens"]),
              let reasoning = CheckedTokenMath.parseNonNegativeInt(dict["reasoning_output_tokens"]) else {
            return .invalid
        }

        let declaredTotal: Int?
        switch CheckedTokenMath.parseOptionalNonNegativeInt(dict["total_tokens"]) {
        case .absent:
            declaredTotal = nil
        case .value(let value):
            declaredTotal = value
        case .invalid:
            return .invalid
        }

        // Schema subset invariants: cached_input_tokens <= input_tokens and reasoning_output_tokens <= output_tokens.
        guard CheckedTokenMath.validateSubset(cachedInput, of: input) != nil,
              CheckedTokenMath.validateSubset(reasoning, of: output) != nil,
              let cacheTokens = CheckedTokenMath.add(cachedInput, cacheWrite),
              let rawPlusOutput = CheckedTokenMath.add(input, output) else {
            return .invalid
        }

        // Declared total consistency: declared total must be >= sum of its disjoint parts.
        if let declaredTotal {
            guard CheckedTokenMath.validateDeclaredTotal(declaredTotal, partsSum: rawPlusOutput) else {
                return .invalid
            }
            if cacheWrite > 0 {
                if declaredTotal == rawPlusOutput {
                    // cache_write_input_tokens is counted inside input_tokens, so cached + cache_write <= input.
                    guard CheckedTokenMath.validateSubset(cacheTokens, of: input) != nil else {
                        return .invalid
                    }
                } else if cacheTokens > input {
                    // cache_write_input_tokens cannot fit inside input_tokens, so it must be disjoint in total.
                    guard let disjointParts = CheckedTokenMath.add(rawPlusOutput, cacheWrite),
                          CheckedTokenMath.validateDeclaredTotal(declaredTotal, partsSum: disjointParts) else {
                        return .invalid
                    }
                }
            }
        }

        guard input > 0 || output > 0 || cachedInput > 0 || cacheWrite > 0 else {
            return .zero
        }
        return .valid(
            CodexTokenTotals(
                inputTokens: input,
                cachedInputTokens: cachedInput,
                cacheWriteInputTokens: cacheWrite,
                outputTokens: output,
                reasoningOutputTokens: reasoning,
                totalTokens: declaredTotal ?? 0,
                declaredTotalTokens: declaredTotal
            )
        )
    }

    private func parseTimestamp(_ raw: Any?) -> Date? {
        LogTimestampParser.parseJSONTimestamp(raw)
    }

    private func cleanedString(_ raw: Any?) -> String? {
        guard let str = raw as? String else { return nil }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
