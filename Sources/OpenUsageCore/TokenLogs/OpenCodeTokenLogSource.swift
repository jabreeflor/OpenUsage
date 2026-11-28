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
    public let fileAccess: any TokenLogFileAccess
    internal let maxScanAttempts: Int
    internal let onLegacyFileReadForTesting: (@Sendable (_ relativePath: String, _ attempt: Int) -> Void)?

    internal static let sqliteCacheKey = "__sqlite__/opencode.db"

    public init(
        rootDirectory: URL = OpenCodeTokenLogSource.defaultRootDirectory(),
        sqliteBusyTimeoutMs: Int32 = 1000,
        fileAccess: any TokenLogFileAccess = SystemTokenLogFileAccess()
    ) {
        self.rootDirectory = rootDirectory
        self.sqliteBusyTimeoutMs = max(0, sqliteBusyTimeoutMs)
        self.fileAccess = fileAccess
        self.maxScanAttempts = 3
        self.onLegacyFileReadForTesting = nil
    }

    internal init(
        rootDirectory: URL = OpenCodeTokenLogSource.defaultRootDirectory(),
        sqliteBusyTimeoutMs: Int32 = 1000,
        fileAccess: any TokenLogFileAccess = SystemTokenLogFileAccess(),
        maxScanAttempts: Int = 3,
        onLegacyFileReadForTesting: (@Sendable (_ relativePath: String, _ attempt: Int) -> Void)? = nil
    ) {
        self.rootDirectory = rootDirectory
        self.sqliteBusyTimeoutMs = max(0, sqliteBusyTimeoutMs)
        self.fileAccess = fileAccess
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
        var sqliteMessageIDs: Set<String> = []
        var pendingEvicted: [PendingEvictedLogFile] = []
        var inconclusiveCacheKeys: Set<String> = []
        var resolvedCacheKeys: Set<String> = []

        // 1. SQLite database (`opencode.db`)
        let dbURL = rootDirectory.appendingPathComponent("opencode.db", isDirectory: false)
        let walURL = rootDirectory.appendingPathComponent("opencode.db-wal", isDirectory: false)

        do {
            if let dbMeta = try fileAccess.readMetadataOrThrow(at: dbURL), dbMeta.isRegularFile {
                let walMeta = try fileAccess.readMetadataOrThrow(at: walURL)
                let walIsDataless = (walMeta?.isRegularFile == true && walMeta?.isDataless == true)
                if shouldSkipInFlightVersion(Self.sqliteCacheKey, dbMeta, walMeta) {
                    inconclusiveCacheKeys.insert(Self.sqliteCacheKey)
                } else if dbMeta.isDataless || walIsDataless {
                    if isSQLiteCacheUpToDate(state.files[Self.sqliteCacheKey], dbMeta: dbMeta, walMeta: walMeta) {
                        resolvedCacheKeys.insert(Self.sqliteCacheKey)
                    } else if Self.canMaterializeEvictedSQLiteComponents(dbMeta: dbMeta, walMeta: walMeta, now: now) {
                        pendingEvicted.append(
                            PendingEvictedLogFile(
                                toolSource: toolSource,
                                url: dbURL,
                                relativePath: "opencode.db",
                                cacheKey: Self.sqliteCacheKey,
                                metadata: dbMeta,
                                secondaryMetadata: walMeta
                            )
                        )
                    } else {
                        resolvedCacheKeys.insert(Self.sqliteCacheKey)
                    }
                } else {
                    let sqliteOutcome = refreshSQLite(
                        dbURL: dbURL,
                        walURL: walURL,
                        state: &state,
                        calendar: calendar
                    )
                    switch sqliteOutcome {
                    case .counted, .removed, .skippedTooOld, .staleVersion:
                        resolvedCacheKeys.insert(Self.sqliteCacheKey)
                    case .stillDataless, .failed, .timedOut:
                        inconclusiveCacheKeys.insert(Self.sqliteCacheKey)
                    }
                }
            } else {
                state.files.removeValue(forKey: Self.sqliteCacheKey)
                resolvedCacheKeys.insert(Self.sqliteCacheKey)
            }
        } catch {
            // Transient metadata error (e.g. EACCES, EIO): preserve existing SQLite cached state and pending status.
            inconclusiveCacheKeys.insert(Self.sqliteCacheKey)
        }
        if let seen = state.files[Self.sqliteCacheKey]?.seenMessages {
            sqliteMessageIDs.formUnion(seen.keys)
        }

        // 2. Legacy JSON message files (`storage/message/**/*.json`)
        let legacyMessageDir = rootDirectory
            .appendingPathComponent("storage", isDirectory: true)
            .appendingPathComponent("message", isDirectory: true)
        let discoveredJSON = fileAccess.discoverFiles(under: legacyMessageDir) { url in
            url.pathExtension.lowercased() == "json"
        }

        var liveKeys: Set<String> = Set(discoveredJSON.map { "storage/message/\($0.relativePath)" })
        if state.files[Self.sqliteCacheKey] != nil {
            liveKeys.insert(Self.sqliteCacheKey)
        }
        for staleKey in state.files.keys where !liveKeys.contains(staleKey) {
            let staleURL = rootDirectory.appendingPathComponent(staleKey, isDirectory: false)
            do {
                if let meta = try fileAccess.readMetadataOrThrow(at: staleURL), meta.isRegularFile {
                    continue
                }
                state.files.removeValue(forKey: staleKey)
            } catch {
                continue
            }
        }

        var claimedMessageIDs = sqliteMessageIDs

        for file in discoveredJSON {
            let cacheKey = "storage/message/\(file.relativePath)"
            let result = scanLegacyJSONFile(
                at: file.url,
                relativePath: file.relativePath,
                allowMaterialization: false,
                expectedVersion: nil,
                materializationNow: nil,
                shouldSkipInFlightVersion: shouldSkipInFlightVersion,
                state: &state,
                claimedMessageIDs: &claimedMessageIDs,
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
                            cacheKey: cacheKey,
                            metadata: meta
                        )
                    )
                } else {
                    resolvedCacheKeys.insert(cacheKey)
                }
            case .counted, .removed, .skippedTooOld, .staleVersion:
                resolvedCacheKeys.insert(cacheKey)
            case .stillDataless, .failed:
                inconclusiveCacheKeys.insert(cacheKey)
            }
        }

        Self.recomputeLegacyActiveBuckets(state: &state)

        return LocalRefreshResult(
            buckets: state.mergedBuckets(),
            pendingEvictedFiles: pendingEvicted,
            inconclusiveCacheKeys: inconclusiveCacheKeys,
            resolvedCacheKeys: resolvedCacheKeys
        )
    }

    public func isPendingFileConfirmedRemoved(_ file: PendingEvictedLogFile) -> Bool {
        let targetURL = (file.cacheKey == Self.sqliteCacheKey)
            ? rootDirectory.appendingPathComponent("opencode.db", isDirectory: false)
            : file.url
        do {
            guard let meta = try fileAccess.readMetadataOrThrow(at: targetURL) else {
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
        if file.cacheKey == Self.sqliteCacheKey {
            return scanEvictedSQLite(file: file, state: &state, calendar: calendar, now: now)
        }

        // Apply the exact same deterministic precedence as a fresh scan:
        // SQLite first, then legacy JSON files in ascending cacheKey (relativePath) order.
        var claimedMessageIDs: Set<String> = []
        if let sqliteSeen = state.files[Self.sqliteCacheKey]?.seenMessages {
            claimedMessageIDs.formUnion(sqliteSeen.keys)
        }
        for key in state.files.keys.sorted() where key != Self.sqliteCacheKey && key < file.cacheKey {
            if let seen = state.files[key]?.seenMessages {
                claimedMessageIDs.formUnion(seen.keys)
            }
        }

        switch scanLegacyJSONFile(
            at: file.url,
            relativePath: file.relativePath,
            allowMaterialization: true,
            expectedVersion: file.metadata,
            materializationNow: now,
            state: &state,
            claimedMessageIDs: &claimedMessageIDs,
            calendar: calendar
        ) {
        case .counted:
            Self.recomputeLegacyActiveBuckets(state: &state)
            return .counted
        case .removed:
            Self.recomputeLegacyActiveBuckets(state: &state)
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

    private static func canMaterializeEvictedSQLiteComponents(
        dbMeta: FileMetadata,
        walMeta: FileMetadata?,
        now: Date
    ) -> Bool {
        if dbMeta.isDataless,
           !EvictedLogPolicy.isRecentEnoughToMaterialize(mtimeNanos: dbMeta.mtimeNanos, now: now) {
            return false
        }
        if let walMeta,
           walMeta.isRegularFile,
           walMeta.isDataless,
           !EvictedLogPolicy.isRecentEnoughToMaterialize(mtimeNanos: walMeta.mtimeNanos, now: now) {
            return false
        }
        return true
    }

    private func isSQLiteCacheUpToDate(
        _ existing: FileCacheEntry?,
        dbMeta: FileMetadata,
        walMeta: FileMetadata?
    ) -> Bool {
        guard let existing else { return false }
        let walSize = walMeta?.size ?? 0
        let walMtime = walMeta?.mtimeNanos ?? 0
        let walInode = walMeta?.inode ?? 0
        let walDevice = walMeta?.device ?? 0
        return existing.device == dbMeta.device
            && existing.inode == dbMeta.inode
            && existing.fileSize == dbMeta.size
            && existing.mtimeNanos == dbMeta.mtimeNanos
            && (existing.secondaryDevice ?? 0) == walDevice
            && (existing.secondarySize ?? 0) == walSize
            && (existing.secondaryMtimeNanos ?? 0) == walMtime
            && (existing.secondaryInode ?? 0) == walInode
    }

    private func materializeRegularFileIfDataless(at url: URL, now: Date) -> EvictedMaterializationOutcome? {
        let meta: FileMetadata
        do {
            guard let read = try fileAccess.readMetadataOrThrow(at: url), read.isRegularFile else {
                return .removed
            }
            meta = read
        } catch {
            return .failed
        }
        guard meta.isDataless else { return nil }
        guard EvictedLogPolicy.isRecentEnoughToMaterialize(mtimeNanos: meta.mtimeNanos, now: now) else {
            return .skippedTooOld
        }
        let fd = fileAccess.openReadOnly(at: url, allowMaterialization: true)
        guard fd >= 0 else {
            return (errno == ENOENT || errno == ENOTDIR || errno == ELOOP) ? .removed : .failed
        }
        defer { fileAccess.close(fd: fd) }
        guard let openMeta = fileAccess.readMetadata(fd: fd) else {
            return .failed
        }
        guard openMeta.isRegularFile else {
            return .removed
        }
        if openMeta.isDataless {
            return .stillDataless
        }
        return nil
    }

    private func scanEvictedSQLite(
        file: PendingEvictedLogFile,
        state: inout SourceCacheState,
        calendar: Calendar,
        now: Date
    ) -> EvictedMaterializationOutcome {
        let dbURL = rootDirectory.appendingPathComponent("opencode.db", isDirectory: false)
        let walURL = rootDirectory.appendingPathComponent("opencode.db-wal", isDirectory: false)

        let dbMeta: FileMetadata
        let walMeta: FileMetadata?
        do {
            guard let readDB = try fileAccess.readMetadataOrThrow(at: dbURL), readDB.isRegularFile else {
                state.files.removeValue(forKey: Self.sqliteCacheKey)
                Self.recomputeLegacyActiveBuckets(state: &state)
                return .removed
            }
            dbMeta = readDB
            walMeta = try fileAccess.readMetadataOrThrow(at: walURL)
        } catch {
            return .failed
        }

        let walIsDataless = (walMeta?.isRegularFile == true && walMeta?.isDataless == true)
        if dbMeta.isDataless || walIsDataless {
            guard Self.canMaterializeEvictedSQLiteComponents(dbMeta: dbMeta, walMeta: walMeta, now: now) else {
                return .skippedTooOld
            }
        }
        guard EvictedLogPolicy.sameFileVersion(dbMeta, file.metadata),
              EvictedLogPolicy.sameOptionalFileVersion(walMeta, file.secondaryMetadata) else {
            return .staleVersion
        }
        if isSQLiteCacheUpToDate(state.files[Self.sqliteCacheKey], dbMeta: dbMeta, walMeta: walMeta) {
            return .counted
        }

        if let failure = materializeRegularFileIfDataless(at: dbURL, now: now) {
            if failure == .removed {
                state.files.removeValue(forKey: Self.sqliteCacheKey)
                Self.recomputeLegacyActiveBuckets(state: &state)
            }
            return failure
        }

        if let walMeta, walMeta.isRegularFile, walMeta.isDataless {
            if let failure = materializeRegularFileIfDataless(at: walURL, now: now), failure != .removed {
                return failure
            }
        }

        let outcome = refreshSQLite(
            dbURL: dbURL,
            walURL: walURL,
            state: &state,
            calendar: calendar
        )
        if outcome == .counted || outcome == .removed {
            Self.recomputeLegacyActiveBuckets(state: &state)
        }
        return outcome
    }

    internal static func recomputeLegacyActiveBuckets(state: inout SourceCacheState) {
        var claimedMessageIDs: Set<String> = []
        if let sqliteSeen = state.files[Self.sqliteCacheKey]?.seenMessages {
            claimedMessageIDs.formUnion(sqliteSeen.keys)
        }
        let legacyKeys = state.files.keys.filter { $0 != Self.sqliteCacheKey }.sorted()
        for key in legacyKeys {
            guard var entry = state.files[key], let ownSeen = entry.seenMessages else { continue }
            entry.buckets = activeBuckets(from: ownSeen, claimedMessageIDs: &claimedMessageIDs)
            state.files[key] = entry
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
    private func scanLegacyJSONFile(
        at url: URL,
        relativePath: String,
        allowMaterialization: Bool,
        expectedVersion: FileMetadata?,
        materializationNow: Date?,
        shouldSkipInFlightVersion: (_ cacheKey: String, _ metadata: FileMetadata, _ secondaryMetadata: FileMetadata?) -> Bool = { _, _, _ in false },
        state: inout SourceCacheState,
        claimedMessageIDs: inout Set<String>,
        calendar: Calendar
    ) -> FileScanResult {
        let cacheKey = "storage/message/\(relativePath)"
        for attempt in 1...maxScanAttempts {
            let outcome = runLegacyJSONScanAttempt(
                at: url,
                relativePath: relativePath,
                cacheKey: cacheKey,
                attempt: attempt,
                allowMaterialization: allowMaterialization,
                expectedVersion: expectedVersion,
                materializationNow: materializationNow,
                shouldSkipInFlightVersion: shouldSkipInFlightVersion,
                state: &state,
                claimedMessageIDs: &claimedMessageIDs,
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
                if let seen = state.files[cacheKey]?.seenMessages {
                    claimedMessageIDs.formUnion(seen.keys)
                }
                return .skippedDataless(meta)
            case .stillDataless:
                if let seen = state.files[cacheKey]?.seenMessages {
                    claimedMessageIDs.formUnion(seen.keys)
                }
                return .stillDataless
            case .preserveExisting:
                if let seen = state.files[cacheKey]?.seenMessages {
                    claimedMessageIDs.formUnion(seen.keys)
                }
                return .failed
            case .retry:
                continue
            }
        }
        // Exhausted retries due to concurrent rotation/mutation: in local pass drop cached state so the next refresh rescans from 0.
        if !allowMaterialization {
            state.files.removeValue(forKey: cacheKey)
        }
        return .failed
    }

    private func runLegacyJSONScanAttempt(
        at url: URL,
        relativePath: String,
        cacheKey: String,
        attempt: Int,
        allowMaterialization: Bool,
        expectedVersion: FileMetadata?,
        materializationNow: Date?,
        shouldSkipInFlightVersion: (_ cacheKey: String, _ metadata: FileMetadata, _ secondaryMetadata: FileMetadata?) -> Bool,
        state: inout SourceCacheState,
        claimedMessageIDs: inout Set<String>,
        calendar: Calendar
    ) -> ScanAttemptOutcome {
        let preMeta: FileMetadata
        do {
            guard let meta = try fileAccess.readMetadataOrThrow(at: url) else {
                state.files.removeValue(forKey: cacheKey)
                return .removed
            }
            preMeta = meta
        } catch {
            return .preserveExisting
        }
        guard preMeta.isRegularFile else {
            state.files.removeValue(forKey: cacheKey)
            return .removed
        }
        if !allowMaterialization, shouldSkipInFlightVersion(cacheKey, preMeta, nil) {
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
            if var existing = state.files[cacheKey],
               EvictedLogPolicy.isCacheEntryUpToDate(existing, for: preMeta),
               let cachedSeen = existing.seenMessages {
                existing.buckets = Self.activeBuckets(
                    from: cachedSeen,
                    claimedMessageIDs: &claimedMessageIDs
                )
                state.files[cacheKey] = existing
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
                state.files.removeValue(forKey: cacheKey)
                return .removed
            }
            return .preserveExisting
        }
        defer { fileAccess.close(fd: fd) }

        guard let openMeta = fileAccess.readMetadata(fd: fd) else {
            return .retry
        }
        guard openMeta.isRegularFile else {
            state.files.removeValue(forKey: cacheKey)
            return .removed
        }
        if openMeta.isDataless {
            return allowMaterialization ? .stillDataless : .skippedDataless(openMeta)
        }
        if let expectedVersion, !EvictedLogPolicy.sameFileVersion(openMeta, expectedVersion) {
            return .staleVersion
        }

        // Fast path for an unchanged legacy JSON file: verify full-file SHA-256 without re-parsing JSON
        // or re-firing full-read hooks, then recompute active buckets against the current claimed IDs.
        if var existing = state.files[cacheKey],
           existing.device == openMeta.device,
           existing.inode == openMeta.inode,
           existing.fileSize == openMeta.size,
           existing.mtimeNanos == openMeta.mtimeNanos,
           let savedFingerprint = existing.eofFingerprint ?? existing.prefixFingerprint,
           let cachedSeen = existing.seenMessages,
           let hasher = StreamingLineReader.prefixHasher(fd: fd, upToOffset: openMeta.size),
           StreamingLineReader.hexDigest(of: hasher) == savedFingerprint {
            guard StreamingLineReader.verifyUnchanged(at: url, fd: fd, since: openMeta, fileAccess: fileAccess) else {
                return .retry
            }
            existing.buckets = Self.activeBuckets(
                from: cachedSeen,
                claimedMessageIDs: &claimedMessageIDs
            )
            state.files[cacheKey] = existing
            return .done
        }

        let data: Data
        let fingerprint: String
        do {
            let readResult = try StreamingLineReader.readAllBytes(fd: fd)
            data = readResult.data
            fingerprint = readResult.fingerprint
        } catch {
            if !StreamingLineReader.verifyUnchanged(at: url, fd: fd, since: openMeta, fileAccess: fileAccess) {
                return .retry
            }
            return .preserveExisting
        }

        onLegacyFileReadForTesting?(relativePath, attempt)

        // Verify the descriptor and path remained completely unchanged before committing or claiming message IDs.
        guard UInt64(data.count) == openMeta.size,
              StreamingLineReader.verifyUnchanged(at: url, fd: fd, since: openMeta, fileAccess: fileAccess) else {
            return .retry
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
                eofFingerprint: fingerprint,
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

        let buckets = Self.activeBuckets(
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
            eofFingerprint: fingerprint,
            seenMessages: ownSeen
        )
        return .done
    }

    private static func activeBuckets(
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

    @discardableResult
    private func refreshSQLite(
        dbURL: URL,
        walURL: URL,
        state: inout SourceCacheState,
        calendar: Calendar
    ) -> EvictedMaterializationOutcome {
        for _ in 1...maxScanAttempts {
            let dbMeta: FileMetadata
            let walMeta: FileMetadata?
            do {
                guard let readDB = try fileAccess.readMetadataOrThrow(at: dbURL), readDB.isRegularFile else {
                    state.files.removeValue(forKey: Self.sqliteCacheKey)
                    return .removed
                }
                dbMeta = readDB
                walMeta = try fileAccess.readMetadataOrThrow(at: walURL)
            } catch {
                // Transient metadata error (e.g. EACCES, EIO): preserve existing cached SQLite state.
                return .failed
            }
            guard !dbMeta.isDataless else {
                return .stillDataless
            }
            if let walMeta, walMeta.isRegularFile, walMeta.isDataless {
                return .stillDataless
            }
            let walSize = walMeta?.size ?? 0
            let walMtime = walMeta?.mtimeNanos ?? 0
            let walInode = walMeta?.inode ?? 0
            let walDevice = walMeta?.device ?? 0

            let dbHash = StreamingLineReader.prefixFingerprint(at: dbURL, upToOffset: dbMeta.size, fileAccess: fileAccess)
            let walHash: String?
            if let walMeta, walMeta.isRegularFile, !walMeta.isDataless {
                walHash = StreamingLineReader.prefixFingerprint(at: walURL, upToOffset: walMeta.size, fileAccess: fileAccess)
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
                if fileAccess.readMetadata(at: dbURL) == dbMeta && fileAccess.readMetadata(at: walURL) == walMeta {
                    return .counted
                }
                continue
            }

            var db: OpaquePointer?
            let openFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
            guard sqlite3_open_v2(dbURL.path, &db, openFlags, nil) == SQLITE_OK, let db else {
                if let db { sqlite3_close(db) }
                return .failed
            }
            defer { sqlite3_close(db) }
            sqlite3_busy_timeout(db, sqliteBusyTimeoutMs)

            // Full scan whenever the DB or WAL changes guarantees deletions, out-of-order updates,
            // and equal-size page rewrites match a fresh scan identically.
            let query = "SELECT id, time_created, time_updated, data FROM message ORDER BY time_updated ASC"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else {
                if let statement { sqlite3_finalize(statement) }
                return .failed
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
                return .failed
            }

            // Verify neither DB nor WAL changed while reading; otherwise retry so metadata and rows match.
            guard fileAccess.readMetadata(at: dbURL) == dbMeta,
                  fileAccess.readMetadata(at: walURL) == walMeta else {
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
                eofFingerprint: combinedFingerprint,
                secondarySize: walSize,
                secondaryMtimeNanos: walMtime,
                secondaryInode: walInode,
                secondaryDevice: walDevice,
                seenMessages: seenMessages,
                watermarkTimestamp: maxWatermark > 0 ? maxWatermark : nil
            )
            return .counted
        }

        // Exhausted retries due to concurrent DB/WAL rotation/mutation: drop cached state so next refresh rescans.
        state.files.removeValue(forKey: Self.sqliteCacheKey)
        return .failed
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
