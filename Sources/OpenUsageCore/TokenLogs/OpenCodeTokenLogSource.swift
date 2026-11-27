import Darwin
import Foundation
import SQLite3

/// Parses OpenCode local usage storage under `~/.local/share/opencode`.
///
/// Verified against real OpenCode storage on macOS:
/// - Primary storage is SQLite (`opencode.db`, table `message(id, session_id, time_created, time_updated, data)`).
/// - Assistant message JSON payloads (`data.role == "assistant"`) include `modelID`, `time.created` / `time.completed`
///   (Unix ms), and `tokens` (`input`, `output`, `reasoning`, `cache.read`, `cache.write`, `total`) where
///   `input + output + reasoning + cache.read + cache.write == total` (`cache.read` is disjoint from `input`).
/// - Also supports legacy JSON message files under `storage/message/**/*.json` (de-duplicated by message ID
///   against `opencode.db` so messages are never double-counted).
public struct OpenCodeTokenLogSource: IncrementalTokenLogSource, Sendable {
    public let provider: ProviderID = .opencode
    public let toolSource: LocalToolSource = .openCode
    public let sourceLabel: String = "~/.local/share/opencode"
    public let rootDirectory: URL
    public let sqliteBusyTimeoutMs: Int32
    internal let maxScanAttempts: Int
    internal let onLegacyFileReadForTesting: (@Sendable (_ relativePath: String, _ attempt: Int) -> Void)?

    private static let sqliteCacheKey = "__sqlite__/opencode.db"

    public init(
        rootDirectory: URL = OpenCodeTokenLogSource.defaultRootDirectory(),
        sqliteBusyTimeoutMs: Int32 = 1000
    ) {
        self.rootDirectory = rootDirectory
        self.sqliteBusyTimeoutMs = max(0, sqliteBusyTimeoutMs)
        self.maxScanAttempts = 3
        self.onLegacyFileReadForTesting = nil
    }

    internal init(
        rootDirectory: URL = OpenCodeTokenLogSource.defaultRootDirectory(),
        sqliteBusyTimeoutMs: Int32 = 1000,
        maxScanAttempts: Int = 3,
        onLegacyFileReadForTesting: (@Sendable (_ relativePath: String, _ attempt: Int) -> Void)? = nil
    ) {
        self.rootDirectory = rootDirectory
        self.sqliteBusyTimeoutMs = max(0, sqliteBusyTimeoutMs)
        self.maxScanAttempts = max(1, maxScanAttempts)
        self.onLegacyFileReadForTesting = onLegacyFileReadForTesting
    }

    public static func defaultRootDirectory() -> URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".local/share/opencode", isDirectory: true)
    }

    public var watchDirectories: [URL] {
        [rootDirectory]
    }

    public func refresh(state: inout SourceCacheState, calendar: Calendar) throws -> [TokenBucket] {
        var sqliteMessageIDs: Set<String> = []

        // 1. SQLite database (`opencode.db`)
        let dbURL = rootDirectory.appendingPathComponent("opencode.db", isDirectory: false)
        let walURL = rootDirectory.appendingPathComponent("opencode.db-wal", isDirectory: false)

        if let dbMeta = FileMetadata.read(at: dbURL), dbMeta.isRegularFile {
            if !dbMeta.isDataless {
                refreshSQLite(
                    dbURL: dbURL,
                    walURL: walURL,
                    state: &state,
                    calendar: calendar
                )
            }
            if let seen = state.files[Self.sqliteCacheKey]?.seenMessages {
                sqliteMessageIDs.formUnion(seen.keys)
            }
        } else {
            state.files.removeValue(forKey: Self.sqliteCacheKey)
        }

        // 2. Legacy JSON message files (`storage/message/**/*.json`)
        let legacyMessageDir = rootDirectory
            .appendingPathComponent("storage", isDirectory: true)
            .appendingPathComponent("message", isDirectory: true)
        let discoveredJSON = SafeDirectoryScanner.discoverFiles(under: legacyMessageDir) { url in
            url.pathExtension.lowercased() == "json"
        }

        var liveKeys: Set<String> = Set(discoveredJSON.map { "storage/message/\($0.relativePath)" })
        if state.files[Self.sqliteCacheKey] != nil {
            liveKeys.insert(Self.sqliteCacheKey)
        }
        for staleKey in state.files.keys where !liveKeys.contains(staleKey) {
            state.files.removeValue(forKey: staleKey)
        }

        var claimedMessageIDs = sqliteMessageIDs

        for file in discoveredJSON {
            scanLegacyJSONFile(
                at: file.url,
                relativePath: file.relativePath,
                state: &state,
                claimedMessageIDs: &claimedMessageIDs,
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

    private func scanLegacyJSONFile(
        at url: URL,
        relativePath: String,
        state: inout SourceCacheState,
        claimedMessageIDs: inout Set<String>,
        calendar: Calendar
    ) {
        let cacheKey = "storage/message/\(relativePath)"
        for attempt in 1...maxScanAttempts {
            let outcome = runLegacyJSONScanAttempt(
                at: url,
                relativePath: relativePath,
                cacheKey: cacheKey,
                attempt: attempt,
                state: &state,
                claimedMessageIDs: &claimedMessageIDs,
                calendar: calendar
            )
            switch outcome {
            case .done:
                return
            case .preserveExisting:
                if let seen = state.files[cacheKey]?.seenMessages {
                    claimedMessageIDs.formUnion(seen.keys)
                }
                return
            case .retry:
                continue
            }
        }
        // Exhausted retries due to concurrent rotation/mutation: drop cached state so the next refresh rescans from 0.
        state.files.removeValue(forKey: cacheKey)
    }

    private func runLegacyJSONScanAttempt(
        at url: URL,
        relativePath: String,
        cacheKey: String,
        attempt: Int,
        state: inout SourceCacheState,
        claimedMessageIDs: inout Set<String>,
        calendar: Calendar
    ) -> ScanAttemptOutcome {
        guard let preMeta = FileMetadata.read(at: url), preMeta.isRegularFile else {
            state.files.removeValue(forKey: cacheKey)
            return .done
        }
        guard !preMeta.isDataless else {
            return .preserveExisting
        }

        let fd = StreamingLineReader.openReadOnly(at: url)
        guard fd >= 0 else {
            if errno == ENOENT || errno == ELOOP {
                state.files.removeValue(forKey: cacheKey)
                return .done
            }
            return .preserveExisting
        }
        defer { _ = Darwin.close(fd) }

        guard let openMeta = FileMetadata.read(fd: fd) else {
            return .retry
        }
        guard openMeta.isRegularFile else {
            state.files.removeValue(forKey: cacheKey)
            return .done
        }
        guard !openMeta.isDataless else {
            return .preserveExisting
        }

        let data: Data
        let fingerprint: String
        do {
            let readResult = try StreamingLineReader.readAllBytes(fd: fd)
            data = readResult.data
            fingerprint = readResult.fingerprint
        } catch {
            if !StreamingLineReader.verifyUnchanged(at: url, fd: fd, since: openMeta) {
                return .retry
            }
            return .preserveExisting
        }

        onLegacyFileReadForTesting?(relativePath, attempt)

        // Verify the descriptor and path remained completely unchanged before committing or claiming message IDs.
        guard UInt64(data.count) == openMeta.size,
              StreamingLineReader.verifyUnchanged(at: url, fd: fd, since: openMeta) else {
            return .retry
        }

        // Fast path for an unchanged legacy JSON file: reuse its cached parsed snapshot and
        // recompute active buckets against the current SQLite / claimed message IDs without re-parsing JSON.
        if var existing = state.files[cacheKey],
           existing.device == openMeta.device,
           existing.inode == openMeta.inode,
           existing.fileSize == openMeta.size,
           existing.mtimeNanos == openMeta.mtimeNanos,
           let savedFingerprint = existing.prefixFingerprint,
           savedFingerprint == fingerprint,
           let cachedSeen = existing.seenMessages {
            existing.buckets = activeBuckets(
                from: cachedSeen,
                claimedMessageIDs: &claimedMessageIDs
            )
            state.files[cacheKey] = existing
            return .done
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Corrupt/non-object JSON: clear any stale cached buckets so incremental == fresh scan.
            state.files[cacheKey] = FileCacheEntry(
                fileSize: openMeta.size,
                mtimeNanos: openMeta.mtimeNanos,
                inode: openMeta.inode,
                device: openMeta.device,
                offset: openMeta.size,
                buckets: [],
                prefixFingerprint: fingerprint,
                seenMessages: [:]
            )
            return .done
        }

        let fallbackID = url.deletingPathExtension().lastPathComponent
        let messageID = cleanedString(object["id"]) ?? fallbackID

        var ownSeen: [String: CountedUsageSnapshot] = [:]
        if let snapshot = parseMessageObject(object, fallbackTimeCreated: nil, calendar: calendar) {
            // Always retain the legacy file's own parsed identity & snapshot even if currently
            // shadowed by SQLite, so removing the DB or deleting the SQLite row restores it.
            ownSeen[messageID] = snapshot
        }

        let buckets = activeBuckets(
            from: ownSeen,
            claimedMessageIDs: &claimedMessageIDs
        )

        state.files[cacheKey] = FileCacheEntry(
            fileSize: openMeta.size,
            mtimeNanos: openMeta.mtimeNanos,
            inode: openMeta.inode,
            device: openMeta.device,
            offset: openMeta.size,
            buckets: buckets,
            prefixFingerprint: fingerprint,
            seenMessages: ownSeen
        )
        return .done
    }

    private func activeBuckets(
        from ownSeen: [String: CountedUsageSnapshot],
        claimedMessageIDs: inout Set<String>
    ) -> [TokenBucket] {
        var accumulator = TokenBucketAccumulator()
        for messageID in ownSeen.keys.sorted() {
            guard !claimedMessageIDs.contains(messageID),
                  let snapshot = ownSeen[messageID] else {
                continue
            }
            if accumulator.add(
                dayKey: snapshot.dayKey,
                hour: snapshot.hour,
                provider: .opencode,
                model: snapshot.model,
                inputTokens: snapshot.inputTokens,
                outputTokens: snapshot.outputTokens,
                cacheTokens: snapshot.cacheTokens,
                requests: 1
            ) {
                claimedMessageIDs.insert(messageID)
            }
        }
        return accumulator.buckets()
    }

    private func refreshSQLite(
        dbURL: URL,
        walURL: URL,
        state: inout SourceCacheState,
        calendar: Calendar
    ) {
        for _ in 1...maxScanAttempts {
            guard let dbMeta = FileMetadata.read(at: dbURL), dbMeta.isRegularFile else {
                state.files.removeValue(forKey: Self.sqliteCacheKey)
                return
            }
            guard !dbMeta.isDataless else {
                return
            }
            let walMeta = FileMetadata.read(at: walURL)
            let walSize = walMeta?.size ?? 0
            let walMtime = walMeta?.mtimeNanos ?? 0
            let walInode = walMeta?.inode ?? 0
            let walDevice = walMeta?.device ?? 0

            let dbHash = StreamingLineReader.prefixFingerprint(at: dbURL, upToOffset: dbMeta.size)
            let walHash: String?
            if let walMeta, walMeta.isRegularFile, !walMeta.isDataless {
                walHash = StreamingLineReader.prefixFingerprint(at: walURL, upToOffset: walMeta.size)
            } else {
                walHash = "absent"
            }
            let combinedFingerprint: String? = if let dbHash, let walHash {
                "\(dbHash)|\(walHash)"
            } else {
                nil
            }

            let existing = state.files[Self.sqliteCacheKey]
            if let existing,
               existing.device == dbMeta.device,
               existing.inode == dbMeta.inode,
               existing.fileSize == dbMeta.size,
               existing.mtimeNanos == dbMeta.mtimeNanos,
               (existing.secondaryDevice ?? 0) == walDevice,
               (existing.secondarySize ?? 0) == walSize,
               (existing.secondaryMtimeNanos ?? 0) == walMtime,
               (existing.secondaryInode ?? 0) == walInode,
               let savedFingerprint = existing.prefixFingerprint,
               let combinedFingerprint,
               savedFingerprint == combinedFingerprint {
                if FileMetadata.read(at: dbURL) == dbMeta && FileMetadata.read(at: walURL) == walMeta {
                    return
                }
                continue
            }

            var db: OpaquePointer?
            let openFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
            guard sqlite3_open_v2(dbURL.path, &db, openFlags, nil) == SQLITE_OK, let db else {
                if let db { sqlite3_close(db) }
                return
            }
            defer { sqlite3_close(db) }
            sqlite3_busy_timeout(db, sqliteBusyTimeoutMs)

            // Full scan whenever the DB or WAL changes guarantees deletions, out-of-order updates,
            // and equal-size page rewrites match a fresh scan identically.
            let query = "SELECT id, time_created, time_updated, data FROM message ORDER BY time_updated ASC"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else {
                if let statement { sqlite3_finalize(statement) }
                return
            }
            defer { sqlite3_finalize(statement) }

            var accumulator = TokenBucketAccumulator()
            var seenMessages: [String: CountedUsageSnapshot] = [:]
            var maxWatermark: Int64 = 0

            var stepResult: Int32 = SQLITE_OK
            while true {
                stepResult = sqlite3_step(statement)
                if stepResult != SQLITE_ROW {
                    break
                }

                guard let idPtr = sqlite3_column_text(statement, 0),
                      let dataPtr = sqlite3_column_text(statement, 3) else {
                    continue
                }

                let msgID = String(cString: idPtr)
                let rowTimeCreated = sqlite3_column_int64(statement, 1)
                let rowTimeUpdated = sqlite3_column_int64(statement, 2)
                if rowTimeUpdated > maxWatermark {
                    maxWatermark = rowTimeUpdated
                }

                let dataLen = Int(sqlite3_column_bytes(statement, 3))
                guard dataLen > 0 else { continue }
                let rawData = Data(bytes: dataPtr, count: dataLen)

                guard let object = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any] else {
                    continue
                }
                guard let snapshot = parseMessageObject(
                    object,
                    fallbackTimeCreated: rowTimeCreated,
                    calendar: calendar
                ) else {
                    continue
                }

                if let previous = seenMessages[msgID] {
                    guard previous != snapshot else { continue }
                    guard accumulator.replace(previous: previous, with: snapshot, provider: .opencode) else {
                        continue
                    }
                    seenMessages[msgID] = snapshot
                } else {
                    guard accumulator.add(
                        dayKey: snapshot.dayKey,
                        hour: snapshot.hour,
                        provider: .opencode,
                        model: snapshot.model,
                        inputTokens: snapshot.inputTokens,
                        outputTokens: snapshot.outputTokens,
                        cacheTokens: snapshot.cacheTokens,
                        requests: 1
                    ) else {
                        continue
                    }
                    seenMessages[msgID] = snapshot
                }
            }

            // Commit refreshed SQLite state ONLY after SQLite reports SQLITE_DONE.
            // On any error or interruption (SQLITE_BUSY, SQLITE_INTERRUPT, SQLITE_ERROR, etc.),
            // preserve prior cached state untouched so the next refresh retries.
            guard stepResult == SQLITE_DONE else {
                return
            }

            // Verify neither DB nor WAL changed while reading; otherwise retry so metadata and rows match.
            guard FileMetadata.read(at: dbURL) == dbMeta,
                  FileMetadata.read(at: walURL) == walMeta else {
                continue
            }

            state.files[Self.sqliteCacheKey] = FileCacheEntry(
                fileSize: dbMeta.size,
                mtimeNanos: dbMeta.mtimeNanos,
                inode: dbMeta.inode,
                device: dbMeta.device,
                offset: dbMeta.size,
                buckets: accumulator.buckets(),
                prefixFingerprint: combinedFingerprint,
                secondarySize: walSize,
                secondaryMtimeNanos: walMtime,
                secondaryInode: walInode,
                secondaryDevice: walDevice,
                seenMessages: seenMessages,
                watermarkTimestamp: maxWatermark > 0 ? maxWatermark : nil
            )
            return
        }

        // Exhausted retries due to concurrent DB/WAL rotation/mutation: drop cached state so next refresh rescans.
        state.files.removeValue(forKey: Self.sqliteCacheKey)
    }

    private func parseMessageObject(
        _ object: [String: Any],
        fallbackTimeCreated: Int64?,
        calendar: Calendar
    ) -> CountedUsageSnapshot? {
        guard (object["role"] as? String) == "assistant" else { return nil }
        guard let tokens = object["tokens"] as? [String: Any] else { return nil }

        let declaredTotal: Int?
        switch CheckedTokenMath.parseOptionalNonNegativeInt(tokens["total"]) {
        case .absent:
            declaredTotal = nil
        case .value(let value):
            declaredTotal = value
        case .invalid:
            return nil
        }

        guard let inputTokens = CheckedTokenMath.parseNonNegativeInt(tokens["input"]),
              let rawOutput = CheckedTokenMath.parseNonNegativeInt(tokens["output"]),
              let reasoning = CheckedTokenMath.parseNonNegativeInt(tokens["reasoning"]),
              let outputTokens = CheckedTokenMath.add(rawOutput, reasoning) else {
            return nil
        }

        let cacheDict: [String: Any]?
        if let rawCache = tokens["cache"], !(rawCache is NSNull) {
            guard let dict = rawCache as? [String: Any] else { return nil }
            cacheDict = dict
        } else {
            cacheDict = nil
        }

        guard let cacheRead = CheckedTokenMath.parseNonNegativeInt(cacheDict?["read"]),
              let cacheWrite = CheckedTokenMath.parseNonNegativeInt(cacheDict?["write"]),
              let cacheTokens = CheckedTokenMath.add(cacheRead, cacheWrite),
              let total = CheckedTokenMath.sum(inputTokens, outputTokens, cacheTokens),
              total > 0,
              CheckedTokenMath.validateDeclaredTotal(declaredTotal, partsSum: total) else {
            return nil
        }

        let timeDict = object["time"] as? [String: Any]
        let date = LogTimestampParser.parseJSONTimestamp(timeDict?["completed"])
            ?? LogTimestampParser.parseJSONTimestamp(timeDict?["created"])
            ?? fallbackTimeCreated.flatMap(LogTimestampParser.parseEpoch)
        guard let date else { return nil }

        let model = cleanedString(object["modelID"])
            ?? cleanedString(object["model"])
            ?? "unknown"

        let dayKey = StatisticsAggregator.dayKey(for: date, calendar: calendar)
        let hour = calendar.component(.hour, from: date)

        return CountedUsageSnapshot(
            dayKey: dayKey,
            hour: hour,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheTokens: cacheTokens
        )
    }

    private func cleanedString(_ raw: Any?) -> String? {
        guard let str = raw as? String else { return nil }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
