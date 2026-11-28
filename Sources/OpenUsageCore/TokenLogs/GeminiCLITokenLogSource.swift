import CryptoKit
import Darwin
import Foundation

/// Parses Gemini CLI local session JSON files under `~/.gemini/tmp` (e.g. `**/chats/session-*.json`).
///
/// Verified against real Gemini CLI session logs on macOS:
/// - Session files are JSON objects containing a `messages` array.
/// - Model responses (`type == "gemini"`, or any message with a `tokens` object) include `id`, `timestamp` (ISO 8601),
///   `model`, and `tokens` (`input`, `output`, `cached`, `thoughts`, `tool`, `total`).
/// - In Gemini CLI logs, `cached` is a subset of `input` (`input + output + thoughts + tool == total`),
///   so non-cached input is `input - cached`, output is `output + thoughts + tool`, and cache is `cached`.
///   Records where `cached > input` or declared `total < sum of parts` are rejected before updating dedup state.
/// - Streams session files through a fixed-size buffer so prompt/response bodies (`content`, `toolCalls`, etc.)
///   are skipped in place without materializing the full conversation in memory.
public struct GeminiCLITokenLogSource: IncrementalTokenLogSource, Sendable {
    public let provider: ProviderID = .gemini
    public let toolSource: LocalToolSource = .geminiCLI
    public let sourceLabel: String = "~/.gemini/tmp"
    public let rootDirectory: URL
    public let streamChunkSize: Int
    public let fileAccess: any TokenLogFileAccess
    internal let maxScanAttempts: Int
    internal let onMessageScannedForTesting: (@Sendable (_ relativePath: String, _ attempt: Int, _ messageIndex: Int) -> Void)?

    public init(
        rootDirectory: URL = GeminiCLITokenLogSource.defaultRootDirectory(),
        streamChunkSize: Int = GeminiSessionStreamParser.defaultChunkSize,
        fileAccess: any TokenLogFileAccess = SystemTokenLogFileAccess()
    ) {
        self.rootDirectory = rootDirectory
        self.streamChunkSize = max(256, streamChunkSize)
        self.fileAccess = fileAccess
        self.maxScanAttempts = 3
        self.onMessageScannedForTesting = nil
    }

    internal init(
        rootDirectory: URL = GeminiCLITokenLogSource.defaultRootDirectory(),
        streamChunkSize: Int = GeminiSessionStreamParser.defaultChunkSize,
        fileAccess: any TokenLogFileAccess = SystemTokenLogFileAccess(),
        maxScanAttempts: Int = 3,
        onMessageScannedForTesting: (@Sendable (_ relativePath: String, _ attempt: Int, _ messageIndex: Int) -> Void)? = nil
    ) {
        self.rootDirectory = rootDirectory
        self.streamChunkSize = max(256, streamChunkSize)
        self.fileAccess = fileAccess
        self.maxScanAttempts = max(1, maxScanAttempts)
        self.onMessageScannedForTesting = onMessageScannedForTesting
    }

    public static func defaultRootDirectory() -> URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".gemini/tmp", isDirectory: true)
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
            return name.hasPrefix("session-") && url.pathExtension.lowercased() == "json"
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

        if let existing = state.files[relativePath],
           existing.device == openMeta.device,
           existing.inode == openMeta.inode,
           existing.fileSize == openMeta.size,
           existing.mtimeNanos == openMeta.mtimeNanos,
           let savedFingerprint = existing.prefixFingerprint,
           let hasher = StreamingLineReader.prefixHasher(fd: fd, upToOffset: openMeta.size),
           StreamingLineReader.hexDigest(of: hasher) == savedFingerprint {
            return StreamingLineReader.verifyUnchanged(at: url, fd: fd, since: openMeta, fileAccess: fileAccess)
                ? .done
                : .retry
        }

        var accumulator = TokenBucketAccumulator()
        var seenMessageIDs: Set<String> = []
        var messageIndex = 0

        let parseResult: GeminiSessionStreamParser.StreamParseResult
        do {
            parseResult = try GeminiSessionStreamParser.parse(
                fd: fd,
                chunkSize: streamChunkSize
            ) { message in
                messageIndex += 1
                defer {
                    onMessageScannedForTesting?(relativePath, attempt, messageIndex)
                }

                // Check duplicates without mutating seenMessageIDs until validation and accumulation succeed.
                if let msgID = message.id, seenMessageIDs.contains(msgID) {
                    return
                }

                guard let timestampString = message.timestamp,
                      let date = LogTimestampParser.parseISO8601(timestampString) else {
                    return
                }

                guard let inputTokens = CheckedTokenMath.validateSubset(
                    message.tokens.cached,
                    of: message.tokens.input
                ) else {
                    return
                }
                guard let outputTokens = CheckedTokenMath.sum(
                    message.tokens.output,
                    message.tokens.thoughts,
                    message.tokens.tool
                ) else {
                    return
                }
                let cacheTokens = message.tokens.cached

                guard let total = CheckedTokenMath.sum(inputTokens, outputTokens, cacheTokens),
                      total > 0,
                      CheckedTokenMath.validateDeclaredTotal(message.tokens.total, partsSum: total) else {
                    return
                }

                let model = message.model ?? "unknown"
                let dayKey = StatisticsAggregator.dayKey(for: date, calendar: calendar)
                let hour = calendar.component(.hour, from: date)

                guard accumulator.add(
                    dayKey: dayKey,
                    hour: hour,
                    provider: .gemini,
                    model: model,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    cacheTokens: cacheTokens,
                    requests: 1
                ) else {
                    return
                }

                if let msgID = message.id {
                    seenMessageIDs.insert(msgID)
                }
            }
        } catch GeminiSessionStreamParser.ParseError.malformedJSON {
            guard let fullHasher = StreamingLineReader.prefixHasher(fd: fd, upToOffset: openMeta.size),
                  StreamingLineReader.verifyUnchanged(at: url, fd: fd, since: openMeta, fileAccess: fileAccess) else {
                return .retry
            }
            let fingerprint = StreamingLineReader.hexDigest(of: fullHasher)
            // Static malformed/truncated JSON: cache empty buckets for this exact version so unchanged
            // re-evicted or local files are not repeatedly downloaded/re-parsed while matching a fresh scan.
            state.files[relativePath] = FileCacheEntry(
                fileSize: openMeta.size,
                mtimeNanos: openMeta.mtimeNanos,
                inode: openMeta.inode,
                device: openMeta.device,
                offset: openMeta.size,
                buckets: [],
                prefixFingerprint: fingerprint,
                eofFingerprint: fingerprint
            )
            return .done
        } catch {
            if !StreamingLineReader.verifyUnchanged(at: url, fd: fd, since: openMeta, fileAccess: fileAccess) {
                return .retry
            }
            // Transient open/read I/O error: skip gracefully without crashing.
            return .preserveExisting
        }

        guard parseResult.bytesRead == openMeta.size,
              StreamingLineReader.verifyUnchanged(at: url, fd: fd, since: openMeta, fileAccess: fileAccess) else {
            return .retry
        }

        guard parseResult.parsedSuccessfully else {
            state.files[relativePath] = FileCacheEntry(
                fileSize: openMeta.size,
                mtimeNanos: openMeta.mtimeNanos,
                inode: openMeta.inode,
                device: openMeta.device,
                offset: openMeta.size,
                buckets: [],
                prefixFingerprint: parseResult.fingerprint,
                eofFingerprint: parseResult.fingerprint
            )
            return .done
        }

        state.files[relativePath] = FileCacheEntry(
            fileSize: openMeta.size,
            mtimeNanos: openMeta.mtimeNanos,
            inode: openMeta.inode,
            device: openMeta.device,
            offset: openMeta.size,
            buckets: accumulator.buckets(),
            prefixFingerprint: parseResult.fingerprint,
            eofFingerprint: parseResult.fingerprint
        )
        return .done
    }
}

/// Bounded-memory POSIX streaming JSON parser for Gemini CLI session files.
/// Extracts only message metadata (`id`, `timestamp`, `model`, `tokens`) while skipping
/// arbitrarily large prompt/response fields (`content`, `toolCalls`, `thoughts`, etc.) with zero allocation.
public enum GeminiSessionStreamParser {
    public static let defaultChunkSize = 64 * 1024

    public struct MessageTokens: Sendable, Equatable {
        public let input: Int
        public let output: Int
        public let cached: Int
        public let thoughts: Int
        public let tool: Int
        public let total: Int?

        public init(
            input: Int,
            output: Int,
            cached: Int,
            thoughts: Int,
            tool: Int,
            total: Int? = nil
        ) {
            self.input = input
            self.output = output
            self.cached = cached
            self.thoughts = thoughts
            self.tool = tool
            self.total = total
        }
    }

    public struct StreamedMessage: Sendable, Equatable {
        public let id: String?
        public let timestamp: String?
        public let model: String?
        public let tokens: MessageTokens
    }

    public struct StreamParseResult: Sendable, Equatable {
        public let parsedSuccessfully: Bool
        public let bytesRead: UInt64
        public let fingerprint: String
    }

    public enum ParseError: Error {
        case openFailed(Int32)
        case readFailed(Int32)
        case malformedJSON
    }

    /// Streams a Gemini session JSON file from an already-open descriptor `fd`, computing the SHA-256
    /// fingerprint over the exact bytes parsed in a single sequential pass.
    public static func parse(
        fd: Int32,
        chunkSize: Int = defaultChunkSize,
        onMessage: (StreamedMessage) -> Void
    ) throws -> StreamParseResult {
        guard Darwin.lseek(fd, 0, SEEK_SET) == 0 else {
            throw ParseError.readFailed(errno)
        }
        let effectiveChunkSize = max(256, chunkSize)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: effectiveChunkSize)
        defer { buffer.deallocate() }

        var scanner = Scanner(fd: fd, buffer: buffer, capacity: effectiveChunkSize)
        let parsedSuccessfully = try scanner.parseSession(onMessage: onMessage)
        return StreamParseResult(
            parsedSuccessfully: parsedSuccessfully,
            bytesRead: scanner.totalBytesRead,
            fingerprint: StreamingLineReader.hexDigest(of: scanner.hasher)
        )
    }

    /// Streams a Gemini session JSON file in fixed-size chunks and invokes `onMessage` for each message
    /// containing a valid `tokens` object. Returns `true` if the file was valid JSON with a top-level
    /// `messages` array; throws `ParseError` on I/O error or malformed/truncated JSON.
    @discardableResult
    public static func parseFile(
        at url: URL,
        chunkSize: Int = defaultChunkSize,
        onMessage: (StreamedMessage) -> Void
    ) throws -> Bool {
        let fd = StreamingLineReader.openReadOnly(at: url)
        guard fd >= 0 else {
            throw ParseError.openFailed(errno)
        }
        defer { _ = Darwin.close(fd) }

        return try parse(fd: fd, chunkSize: chunkSize, onMessage: onMessage).parsedSuccessfully
    }

    private struct Scanner {
        let fd: Int32
        let buffer: UnsafeMutablePointer<UInt8>
        let capacity: Int
        var length: Int = 0
        var pos: Int = 0
        var reachedEOF: Bool = false
        var hasher = SHA256()
        var totalBytesRead: UInt64 = 0

        private mutating func refill() throws {
            if reachedEOF { return }
            while true {
                let n = Darwin.read(fd, buffer, capacity)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw ParseError.readFailed(errno)
                }
                if n == 0 {
                    reachedEOF = true
                    length = 0
                    pos = 0
                    return
                }
                hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: n))
                totalBytesRead += UInt64(n)
                length = n
                pos = 0
                return
            }
        }

        private mutating func peekByte() throws -> UInt8? {
            if pos >= length {
                try refill()
                if pos >= length {
                    return nil
                }
            }
            return buffer[pos]
        }

        private mutating func readByte() throws -> UInt8? {
            guard let b = try peekByte() else { return nil }
            pos += 1
            return b
        }

        private mutating func advanceByte() {
            pos += 1
        }

        private mutating func skipWhitespace() throws {
            while let b = try peekByte() {
                if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D {
                    advanceByte()
                } else {
                    return
                }
            }
        }

        private mutating func expectByte(_ expected: UInt8) throws {
            try skipWhitespace()
            guard let b = try readByte(), b == expected else {
                throw ParseError.malformedJSON
            }
        }

        private mutating func expectLiteral(_ literal: StaticString) throws {
            let count = literal.utf8CodeUnitCount
            let start = literal.utf8Start
            for idx in 0..<count {
                guard let b = try readByte(), b == start[idx] else {
                    throw ParseError.malformedJSON
                }
            }
        }

        mutating func parseSession(onMessage: (StreamedMessage) -> Void) throws -> Bool {
            try skipWhitespace()
            try expectByte(0x7B) // '{'
            try skipWhitespace()

            var foundMessagesArray = false
            if try peekByte() == 0x7D { // '}'
                advanceByte()
            } else {
                while true {
                    try skipWhitespace()
                    let key = try readShortString(maxBytes: 256)
                    try expectByte(0x3A) // ':'
                    try skipWhitespace()

                    if key == "messages", try peekByte() == 0x5B {
                        foundMessagesArray = true
                        try parseMessagesArray(onMessage: onMessage)
                    } else {
                        try skipValue()
                    }

                    try skipWhitespace()
                    guard let sep = try readByte() else {
                        throw ParseError.malformedJSON
                    }
                    if sep == 0x2C { // ','
                        continue
                    } else if sep == 0x7D { // '}'
                        break
                    } else {
                        throw ParseError.malformedJSON
                    }
                }
            }

            try skipWhitespace()
            if try peekByte() != nil {
                throw ParseError.malformedJSON
            }
            return foundMessagesArray
        }

        private mutating func parseMessagesArray(onMessage: (StreamedMessage) -> Void) throws {
            try expectByte(0x5B) // '['
            try skipWhitespace()
            if try peekByte() == 0x5D { // ']'
                advanceByte()
                return
            }

            while true {
                try skipWhitespace()
                guard let b = try peekByte() else {
                    throw ParseError.malformedJSON
                }
                if b == 0x7B { // '{'
                    if let message = try parseMessageObject() {
                        onMessage(message)
                    }
                } else {
                    try skipValue()
                }

                try skipWhitespace()
                guard let sep = try readByte() else {
                    throw ParseError.malformedJSON
                }
                if sep == 0x2C { // ','
                    continue
                } else if sep == 0x5D { // ']'
                    break
                } else {
                    throw ParseError.malformedJSON
                }
            }
        }

        private mutating func parseMessageObject() throws -> StreamedMessage? {
            try expectByte(0x7B) // '{'
            try skipWhitespace()
            if try peekByte() == 0x7D { // '}'
                advanceByte()
                return nil
            }

            var messageID: String?
            var timestamp: String?
            var model: String?
            var tokensResult: ParsedTokens = .absent

            while true {
                try skipWhitespace()
                let key = try readShortString(maxBytes: 128)
                try expectByte(0x3A) // ':'
                try skipWhitespace()

                switch key {
                case "id":
                    if try peekByte() == 0x22 {
                        messageID = cleaned(try readShortString(maxBytes: 1024))
                    } else {
                        try skipValue()
                    }
                case "timestamp":
                    if try peekByte() == 0x22 {
                        timestamp = try readShortString(maxBytes: 128)
                    } else {
                        try skipValue()
                    }
                case "model":
                    if try peekByte() == 0x22 {
                        model = cleaned(try readShortString(maxBytes: 512))
                    } else {
                        try skipValue()
                    }
                case "tokens":
                    if try peekByte() == 0x7B {
                        tokensResult = try parseTokensObject()
                    } else {
                        try skipValue()
                    }
                default:
                    try skipValue()
                }

                try skipWhitespace()
                guard let sep = try readByte() else {
                    throw ParseError.malformedJSON
                }
                if sep == 0x2C { // ','
                    continue
                } else if sep == 0x7D { // '}'
                    break
                } else {
                    throw ParseError.malformedJSON
                }
            }

            guard case .valid(let tokens) = tokensResult else {
                return nil
            }

            return StreamedMessage(
                id: messageID,
                timestamp: timestamp,
                model: model,
                tokens: tokens
            )
        }

        private enum ParsedTokens {
            case absent
            case invalid
            case valid(MessageTokens)
        }

        private mutating func parseTokensObject() throws -> ParsedTokens {
            try expectByte(0x7B) // '{'
            try skipWhitespace()
            if try peekByte() == 0x7D { // '}'
                advanceByte()
                return .valid(MessageTokens(input: 0, output: 0, cached: 0, thoughts: 0, tool: 0, total: nil))
            }

            var input = 0
            var output = 0
            var cached = 0
            var thoughts = 0
            var tool = 0
            var total: Int? = nil
            var hasInvalidField = false

            while true {
                try skipWhitespace()
                let key = try readShortString(maxBytes: 64)
                try expectByte(0x3A) // ':'
                try skipWhitespace()

                switch key {
                case "input":
                    if let v = try readTokenIntValue() { input = v } else { hasInvalidField = true }
                case "output":
                    if let v = try readTokenIntValue() { output = v } else { hasInvalidField = true }
                case "cached":
                    if let v = try readTokenIntValue() { cached = v } else { hasInvalidField = true }
                case "thoughts":
                    if let v = try readTokenIntValue() { thoughts = v } else { hasInvalidField = true }
                case "tool":
                    if let v = try readTokenIntValue() { tool = v } else { hasInvalidField = true }
                case "total":
                    switch try readOptionalTokenIntValue() {
                    case .absent:
                        total = nil
                    case .value(let v):
                        total = v
                    case .invalid:
                        hasInvalidField = true
                    }
                default:
                    try skipValue()
                }

                try skipWhitespace()
                guard let sep = try readByte() else {
                    throw ParseError.malformedJSON
                }
                if sep == 0x2C { // ','
                    continue
                } else if sep == 0x7D { // '}'
                    break
                } else {
                    throw ParseError.malformedJSON
                }
            }

            if hasInvalidField {
                return .invalid
            }
            return .valid(
                MessageTokens(
                    input: input,
                    output: output,
                    cached: cached,
                    thoughts: thoughts,
                    tool: tool,
                    total: total
                )
            )
        }

        private mutating func readTokenIntValue() throws -> Int? {
            switch try readOptionalTokenIntValue() {
            case .absent:
                return 0
            case .value(let v):
                return v
            case .invalid:
                return nil
            }
        }

        private mutating func readOptionalTokenIntValue() throws -> CheckedTokenMath.OptionalParsedInt {
            try skipWhitespace()
            guard let b = try peekByte() else {
                throw ParseError.malformedJSON
            }
            if b == 0x6E { // 'n' -> null
                try expectLiteral("null")
                return .absent
            }
            guard b == 0x2D || (b >= 0x30 && b <= 0x39) else {
                // Valid JSON value of non-numeric type: skip cleanly and mark token field invalid.
                try skipValue()
                return .invalid
            }

            var isSimpleNonNegativeInt = true
            var digits: [UInt8] = []
            digits.reserveCapacity(24)

            if b == 0x2D { // '-'
                isSimpleNonNegativeInt = false
                advanceByte()
            }

            guard let firstDigit = try readByte(), firstDigit >= 0x30 && firstDigit <= 0x39 else {
                throw ParseError.malformedJSON
            }
            if isSimpleNonNegativeInt {
                digits.append(firstDigit)
            }

            if firstDigit != 0x30 { // leading '0' cannot be followed by more integer digits in RFC 8259
                while let next = try peekByte(), next >= 0x30 && next <= 0x39 {
                    advanceByte()
                    if isSimpleNonNegativeInt {
                        if digits.count < 32 {
                            digits.append(next)
                        } else {
                            isSimpleNonNegativeInt = false
                        }
                    }
                }
            }

            if try peekByte() == 0x2E { // '.'
                isSimpleNonNegativeInt = false
                advanceByte()
                guard let frac = try readByte(), frac >= 0x30 && frac <= 0x39 else {
                    throw ParseError.malformedJSON
                }
                while let next = try peekByte(), next >= 0x30 && next <= 0x39 {
                    advanceByte()
                }
            }

            if let exp = try peekByte(), exp == 0x65 || exp == 0x45 { // 'e' or 'E'
                isSimpleNonNegativeInt = false
                advanceByte()
                if let sign = try peekByte(), sign == 0x2B || sign == 0x2D {
                    advanceByte()
                }
                guard let expDigit = try readByte(), expDigit >= 0x30 && expDigit <= 0x39 else {
                    throw ParseError.malformedJSON
                }
                while let next = try peekByte(), next >= 0x30 && next <= 0x39 {
                    advanceByte()
                }
            }

            guard isSimpleNonNegativeInt,
                  let parsed = CheckedTokenMath.parseNonNegativeInt(asciiDigits: digits) else {
                return .invalid
            }
            return .value(parsed)
        }

        private mutating func readShortString(maxBytes: Int) throws -> String? {
            try expectByte(0x22) // '"'
            var out: [UInt8] = []
            out.reserveCapacity(min(128, maxBytes))
            var overflowed = false

            while true {
                guard let b = try readByte() else {
                    throw ParseError.malformedJSON
                }
                if b == 0x22 { // '"'
                    if overflowed { return nil }
                    return String(decoding: out, as: UTF8.self)
                }
                if b < 0x20 {
                    throw ParseError.malformedJSON
                }
                if b == 0x5C { // '\'
                    guard let esc = try readByte() else {
                        throw ParseError.malformedJSON
                    }
                    switch esc {
                    case 0x22: appendByte(0x22, to: &out, maxBytes: maxBytes, overflowed: &overflowed)
                    case 0x5C: appendByte(0x5C, to: &out, maxBytes: maxBytes, overflowed: &overflowed)
                    case 0x2F: appendByte(0x2F, to: &out, maxBytes: maxBytes, overflowed: &overflowed)
                    case 0x62: appendByte(0x08, to: &out, maxBytes: maxBytes, overflowed: &overflowed)
                    case 0x66: appendByte(0x0C, to: &out, maxBytes: maxBytes, overflowed: &overflowed)
                    case 0x6E: appendByte(0x0A, to: &out, maxBytes: maxBytes, overflowed: &overflowed)
                    case 0x72: appendByte(0x0D, to: &out, maxBytes: maxBytes, overflowed: &overflowed)
                    case 0x74: appendByte(0x09, to: &out, maxBytes: maxBytes, overflowed: &overflowed)
                    case 0x75: // \uXXXX
                        let unit1 = try readHex4()
                        let scalarValue: UInt32
                        if unit1 >= 0xD800 && unit1 <= 0xDBFF {
                            guard try readByte() == 0x5C, try readByte() == 0x75 else {
                                throw ParseError.malformedJSON
                            }
                            let unit2 = try readHex4()
                            guard unit2 >= 0xDC00 && unit2 <= 0xDFFF else {
                                throw ParseError.malformedJSON
                            }
                            scalarValue = 0x10000 + ((unit1 - 0xD800) << 10) + (unit2 - 0xDC00)
                        } else if unit1 >= 0xDC00 && unit1 <= 0xDFFF {
                            throw ParseError.malformedJSON
                        } else {
                            scalarValue = unit1
                        }
                        guard let scalar = UnicodeScalar(scalarValue) else {
                            throw ParseError.malformedJSON
                        }
                        for utf8Byte in String(scalar).utf8 {
                            appendByte(utf8Byte, to: &out, maxBytes: maxBytes, overflowed: &overflowed)
                        }
                    default:
                        throw ParseError.malformedJSON
                    }
                } else {
                    appendByte(b, to: &out, maxBytes: maxBytes, overflowed: &overflowed)
                }
            }
        }

        private func appendByte(
            _ byte: UInt8,
            to out: inout [UInt8],
            maxBytes: Int,
            overflowed: inout Bool
        ) {
            if !overflowed {
                if out.count < maxBytes {
                    out.append(byte)
                } else {
                    overflowed = true
                    out.removeAll(keepingCapacity: false)
                }
            }
        }

        private mutating func readHex4() throws -> UInt32 {
            var value: UInt32 = 0
            for _ in 0..<4 {
                guard let b = try readByte(), let nibble = hexValue(b) else {
                    throw ParseError.malformedJSON
                }
                value = (value << 4) | nibble
            }
            return value
        }

        private func hexValue(_ b: UInt8) -> UInt32? {
            switch b {
            case 0x30...0x39: return UInt32(b - 0x30)
            case 0x41...0x46: return UInt32(b - 0x41 + 10)
            case 0x61...0x66: return UInt32(b - 0x61 + 10)
            default: return nil
            }
        }

        /// Skips an arbitrarily large JSON string without allocating any memory.
        private mutating func skipString() throws {
            try expectByte(0x22) // '"'
            while true {
                if pos >= length {
                    try refill()
                    if pos >= length {
                        throw ParseError.malformedJSON
                    }
                }
                // Tight in-buffer scan for '"' (0x22), '\' (0x5C), or unescaped control byte (< 0x20).
                while pos < length {
                    let b = buffer[pos]
                    if b == 0x22 {
                        pos += 1
                        return
                    }
                    if b == 0x5C {
                        pos += 1
                        guard let esc = try readByte() else {
                            throw ParseError.malformedJSON
                        }
                        switch esc {
                        case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74:
                            break
                        case 0x75:
                            _ = try readHex4()
                        default:
                            throw ParseError.malformedJSON
                        }
                        continue
                    }
                    if b < 0x20 {
                        throw ParseError.malformedJSON
                    }
                    pos += 1
                }
            }
        }

        private mutating func skipNumber() throws {
            if try peekByte() == 0x2D { // '-'
                advanceByte()
            }
            guard let first = try readByte(), first >= 0x30 && first <= 0x39 else {
                throw ParseError.malformedJSON
            }
            if first != 0x30 {
                while let b = try peekByte(), b >= 0x30 && b <= 0x39 {
                    advanceByte()
                }
            }
            if try peekByte() == 0x2E { // '.'
                advanceByte()
                guard let frac = try readByte(), frac >= 0x30 && frac <= 0x39 else {
                    throw ParseError.malformedJSON
                }
                while let b = try peekByte(), b >= 0x30 && b <= 0x39 {
                    advanceByte()
                }
            }
            if let exp = try peekByte(), exp == 0x65 || exp == 0x45 { // 'e' or 'E'
                advanceByte()
                if let sign = try peekByte(), sign == 0x2B || sign == 0x2D {
                    advanceByte()
                }
                guard let expDigit = try readByte(), expDigit >= 0x30 && expDigit <= 0x39 else {
                    throw ParseError.malformedJSON
                }
                while let b = try peekByte(), b >= 0x30 && b <= 0x39 {
                    advanceByte()
                }
            }
        }

        /// Skips any JSON value iteratively using an explicit container stack (bounded depth 512, zero body allocation).
        private mutating func skipValue() throws {
            enum Container {
                case object
                case array
            }
            var stack: [Container] = []
            var expectValue = true

            while true {
                try skipWhitespace()
                if expectValue {
                    guard let b = try peekByte() else {
                        throw ParseError.malformedJSON
                    }
                    switch b {
                    case 0x7B: // '{'
                        guard stack.count < 512 else { throw ParseError.malformedJSON }
                        advanceByte()
                        try skipWhitespace()
                        if try peekByte() == 0x7D {
                            advanceByte()
                            expectValue = false
                        } else {
                            stack.append(.object)
                            try skipString()
                            try expectByte(0x3A) // ':'
                            expectValue = true
                        }
                    case 0x5B: // '['
                        guard stack.count < 512 else { throw ParseError.malformedJSON }
                        advanceByte()
                        try skipWhitespace()
                        if try peekByte() == 0x5D {
                            advanceByte()
                            expectValue = false
                        } else {
                            stack.append(.array)
                            expectValue = true
                        }
                    case 0x22: // '"'
                        try skipString()
                        expectValue = false
                    case 0x74: // 't'
                        try expectLiteral("true")
                        expectValue = false
                    case 0x66: // 'f'
                        try expectLiteral("false")
                        expectValue = false
                    case 0x6E: // 'n'
                        try expectLiteral("null")
                        expectValue = false
                    case 0x2D, 0x30...0x39:
                        try skipNumber()
                        expectValue = false
                    default:
                        throw ParseError.malformedJSON
                    }
                } else {
                    guard let current = stack.last else {
                        return
                    }
                    guard let b = try peekByte() else {
                        throw ParseError.malformedJSON
                    }
                    switch current {
                    case .array:
                        if b == 0x2C { // ','
                            advanceByte()
                            expectValue = true
                        } else if b == 0x5D { // ']'
                            advanceByte()
                            stack.removeLast()
                            expectValue = false
                        } else {
                            throw ParseError.malformedJSON
                        }
                    case .object:
                        if b == 0x2C { // ','
                            advanceByte()
                            try skipWhitespace()
                            try skipString()
                            try expectByte(0x3A) // ':'
                            expectValue = true
                        } else if b == 0x7D { // '}'
                            advanceByte()
                            stack.removeLast()
                            expectValue = false
                        } else {
                            throw ParseError.malformedJSON
                        }
                    }
                }
            }
        }

        private func cleaned(_ str: String?) -> String? {
            guard let str else { return nil }
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}
