import CryptoKit
import Darwin
import Foundation

/// Parses Claude Code local JSONL logs under `~/.claude/projects/**/*.jsonl`.
///
/// Verified against real Claude Code logs on macOS:
/// - Assistant lines have `type == "assistant"`, top-level `timestamp` (ISO 8601) and optional `requestId`/`uuid`,
///   and `message` containing `id`, `model`, and `usage` (`input_tokens`, `output_tokens`,
///   `cache_creation_input_tokens`, `cache_read_input_tokens`).
/// - Multiple JSONL lines can share the same `(message.id, requestId)` (one per content block or streaming update);
///   repeated lines are de-duplicated so each API request is counted once with its latest/highest token counts.
public struct ClaudeCodeTokenLogSource: IncrementalTokenLogSource, Sendable {
    public let provider: ProviderID = .claude
    public let toolSource: LocalToolSource = .claudeCode
    public let sourceLabel: String = "~/.claude/projects"
    public let rootDirectory: URL
    internal let maxScanAttempts: Int
    internal let onLineScannedForTesting: (@Sendable (_ relativePath: String, _ attempt: Int, _ lineNumber: Int) -> Void)?

    private static let usageNeedle = Array("\"usage\"".utf8)
    private static let assistantNeedle = Array("\"assistant\"".utf8)

    public init(rootDirectory: URL = ClaudeCodeTokenLogSource.defaultRootDirectory()) {
        self.rootDirectory = rootDirectory
        self.maxScanAttempts = 3
        self.onLineScannedForTesting = nil
    }

    internal init(
        rootDirectory: URL = ClaudeCodeTokenLogSource.defaultRootDirectory(),
        maxScanAttempts: Int = 3,
        onLineScannedForTesting: (@Sendable (_ relativePath: String, _ attempt: Int, _ lineNumber: Int) -> Void)? = nil
    ) {
        self.rootDirectory = rootDirectory
        self.maxScanAttempts = max(1, maxScanAttempts)
        self.onLineScannedForTesting = onLineScannedForTesting
    }

    public static func defaultRootDirectory() -> URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    public var watchDirectories: [URL] {
        [rootDirectory]
    }

    public func refresh(state: inout SourceCacheState, calendar: Calendar) throws -> [TokenBucket] {
        let discovered = SafeDirectoryScanner.discoverFiles(under: rootDirectory) { url in
            url.pathExtension.lowercased() == "jsonl"
        }

        let livePaths = Set(discovered.map(\.relativePath))
        for stalePath in state.files.keys where !livePaths.contains(stalePath) {
            state.files.removeValue(forKey: stalePath)
        }

        for file in discovered {
            scanFile(
                at: file.url,
                relativePath: file.relativePath,
                state: &state,
                calendar: calendar
            )
        }

        return state.mergedBuckets()
    }

    private enum ScanAttemptOutcome {
        case done
        case retry
        case preserveExisting
    }

    private func scanFile(
        at url: URL,
        relativePath: String,
        state: inout SourceCacheState,
        calendar: Calendar
    ) {
        for attempt in 1...maxScanAttempts {
            let outcome = runScanAttempt(
                at: url,
                relativePath: relativePath,
                attempt: attempt,
                state: &state,
                calendar: calendar
            )
            switch outcome {
            case .done, .preserveExisting:
                return
            case .retry:
                continue
            }
        }
        // Exhausted retries due to concurrent rotation/mutation: drop cached state so the next refresh rescans from 0.
        state.files.removeValue(forKey: relativePath)
    }

    private func runScanAttempt(
        at url: URL,
        relativePath: String,
        attempt: Int,
        state: inout SourceCacheState,
        calendar: Calendar
    ) -> ScanAttemptOutcome {
        guard let preMeta = FileMetadata.read(at: url) else {
            state.files.removeValue(forKey: relativePath)
            return .done
        }
        guard preMeta.isRegularFile else {
            state.files.removeValue(forKey: relativePath)
            return .done
        }
        // Never materialize iCloud-evicted files; retain any previously cached counts for them.
        guard !preMeta.isDataless else {
            return .preserveExisting
        }

        let fd = StreamingLineReader.openReadOnly(at: url)
        guard fd >= 0 else {
            if errno == ENOENT || errno == ELOOP {
                state.files.removeValue(forKey: relativePath)
                return .done
            }
            return .preserveExisting
        }
        defer { _ = Darwin.close(fd) }

        guard let openMeta = FileMetadata.read(fd: fd) else {
            return .retry
        }
        guard openMeta.isRegularFile else {
            state.files.removeValue(forKey: relativePath)
            return .done
        }
        guard !openMeta.isDataless else {
            return .preserveExisting
        }

        let existing = state.files[relativePath]
        let startOffset: UInt64
        let initialHasher: SHA256
        var accumulator: TokenBucketAccumulator
        var seenMessages: [String: CountedUsageSnapshot]

        if let existing,
           existing.device == openMeta.device,
           existing.inode == openMeta.inode,
           openMeta.mtimeNanos >= existing.mtimeNanos,
           openMeta.size >= existing.offset {
            if existing.offset == 0 {
                if openMeta.size == 0
                    && existing.fileSize == 0
                    && existing.mtimeNanos == openMeta.mtimeNanos {
                    return StreamingLineReader.verifyUnchanged(at: url, fd: fd, since: openMeta)
                        ? .done
                        : .retry
                }
                startOffset = 0
                initialHasher = SHA256()
                accumulator = TokenBucketAccumulator()
                seenMessages = [:]
            } else if let savedFingerprint = existing.prefixFingerprint,
                      let prefixHasher = StreamingLineReader.prefixHasher(fd: fd, upToOffset: existing.offset),
                      StreamingLineReader.hexDigest(of: prefixHasher) == savedFingerprint {
                if existing.fileSize == openMeta.size
                    && existing.mtimeNanos == openMeta.mtimeNanos
                    && existing.offset == openMeta.size {
                    return StreamingLineReader.verifyUnchanged(at: url, fd: fd, since: openMeta)
                        ? .done
                        : .retry
                }
                startOffset = existing.offset
                initialHasher = prefixHasher
                accumulator = TokenBucketAccumulator(initialBuckets: existing.buckets)
                seenMessages = existing.seenMessages ?? [:]
            } else {
                startOffset = 0
                initialHasher = SHA256()
                accumulator = TokenBucketAccumulator()
                seenMessages = [:]
            }
        } else {
            startOffset = 0
            initialHasher = SHA256()
            accumulator = TokenBucketAccumulator()
            seenMessages = [:]
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

                guard StreamingLineReader.dataContainsASCII(lineData, needle: Self.usageNeedle),
                      StreamingLineReader.dataContainsASCII(lineData, needle: Self.assistantNeedle) else {
                    // If a trailing line lacks a newline, verify it is complete JSON before advancing past it;
                    // a mid-write line may not yet contain `"usage"` or may end with a nested `}`.
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
                    fallbackLineID: "\(startOffset)#\(lineCounter)",
                    calendar: calendar,
                    seenMessages: &seenMessages,
                    accumulator: &accumulator
                )
                return .advance
            }
        } catch {
            // If the file mutated or rotated mid-read, retry; otherwise skip transient I/O error.
            if !StreamingLineReader.verifyUnchanged(at: url, fd: fd, since: openMeta) {
                return .retry
            }
            return .preserveExisting
        }

        guard readResult.eofOffset == openMeta.size,
              StreamingLineReader.verifyUnchanged(at: url, fd: fd, since: openMeta) else {
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
            seenMessages: seenMessages
        )
        return .done
    }

    private func processParsedLine(
        _ object: [String: Any],
        fallbackLineID: String,
        calendar: Calendar,
        seenMessages: inout [String: CountedUsageSnapshot],
        accumulator: inout TokenBucketAccumulator
    ) {
        guard (object["type"] as? String) == "assistant" else { return }
        guard let message = object["message"] as? [String: Any] else { return }
        guard let usage = message["usage"] as? [String: Any] else { return }
        guard let timestampString = object["timestamp"] as? String,
              let date = LogTimestampParser.parseISO8601(timestampString) else {
            return
        }

        let declaredTotal: Int?
        switch CheckedTokenMath.parseOptionalNonNegativeInt(usage["total_tokens"]) {
        case .absent:
            declaredTotal = nil
        case .value(let value):
            declaredTotal = value
        case .invalid:
            return
        }

        guard let inputTokens = CheckedTokenMath.parseNonNegativeInt(usage["input_tokens"]),
              let outputTokens = CheckedTokenMath.parseNonNegativeInt(usage["output_tokens"]),
              let cacheCreation = CheckedTokenMath.parseNonNegativeInt(usage["cache_creation_input_tokens"]),
              let cacheRead = CheckedTokenMath.parseNonNegativeInt(usage["cache_read_input_tokens"]),
              let cacheTokens = CheckedTokenMath.add(cacheCreation, cacheRead),
              let newTotal = CheckedTokenMath.sum(inputTokens, outputTokens, cacheTokens) else {
            return
        }

        // Missing or zero usage contributes no bucket; reject inconsistent declared total if present.
        guard newTotal > 0,
              CheckedTokenMath.validateDeclaredTotal(declaredTotal, partsSum: newTotal) else {
            return
        }

        let rawModel = (message["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = rawModel.isEmpty ? "unknown" : rawModel

        let dayKey = StatisticsAggregator.dayKey(for: date, calendar: calendar)
        let hour = calendar.component(.hour, from: date)

        let dedupKey = deduplicationKey(object: object, message: message, fallback: fallbackLineID)
        let newSnapshot = CountedUsageSnapshot(
            dayKey: dayKey,
            hour: hour,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheTokens: cacheTokens
        )

        if let previous = seenMessages[dedupKey] {
            // Identical repeated line: skip.
            guard previous != newSnapshot else { return }

            // Progressive streaming update: replace previous counts only if the new total is at least as large.
            guard let prevTotal = CheckedTokenMath.sum(
                previous.inputTokens,
                previous.outputTokens,
                previous.cacheTokens
            ),
            newTotal >= prevTotal else {
                return
            }

            guard accumulator.replace(previous: previous, with: newSnapshot, provider: .claude) else {
                return
            }
            seenMessages[dedupKey] = newSnapshot
        } else {
            guard accumulator.add(
                dayKey: dayKey,
                hour: hour,
                provider: .claude,
                model: model,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheTokens: cacheTokens,
                requests: 1
            ) else {
                return
            }
            seenMessages[dedupKey] = newSnapshot
        }
    }

    private func deduplicationKey(object: [String: Any], message: [String: Any], fallback: String) -> String {
        let messageID = (message["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let requestID = (object["requestId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !messageID.isEmpty && !requestID.isEmpty {
            return "\(messageID)|\(requestID)"
        }
        if !messageID.isEmpty {
            return "m:\(messageID)"
        }
        if !requestID.isEmpty {
            return "r:\(requestID)"
        }
        if let uuid = (object["uuid"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !uuid.isEmpty {
            return "u:\(uuid)"
        }
        return "line:\(fallback)"
    }
}
