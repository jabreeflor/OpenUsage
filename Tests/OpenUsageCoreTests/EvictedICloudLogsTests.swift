import Darwin
import Foundation
import SQLite3
import XCTest
@testable import OpenUsageCore

/// Controllable `TokenLogFileAccess` test double that simulates macOS iCloud-evicted (`isDataless`)
/// files, materialization delays/timeouts, persistent dataless failures, and concurrency tracking
/// without touching real iCloud Drive.
private final class SimulatedICloudFileAccess: TokenLogFileAccess, @unchecked Sendable {
    enum MaterializationBehavior: Sendable {
        case succeed
        case delayAndSucceed(TimeInterval)
        case stayDataless
        case failOpen(Int32)
        case blockUntilReleased(DispatchSemaphore)
        case blockUntilReleasedAndFail(DispatchSemaphore, Int32)
        case signalAndBlock(entered: DispatchSemaphore, release: DispatchSemaphore)
    }

    private let lock = NSLock()
    private let underlying = SystemTokenLogFileAccess()

    private var evictedPaths: Set<String>
    private var mtimeOverrideNanos: [String: Int64]
    private var behaviorsByPath: [String: [MaterializationBehavior]]
    private var metadataErrorByPath: [String: POSIXErrorCode] = [:]
    private var fdToPath: [Int32: String] = [:]

    private(set) var openCallsByPath: [String: [(allowMaterialization: Bool, onMainThread: Bool)]] = [:]
    private var activeMaterializations = 0
    private(set) var maxConcurrentMaterializations = 0

    init(
        evictedURLs: [URL],
        mtimeOverrides: [URL: Date] = [:],
        behaviors: [URL: [MaterializationBehavior]] = [:]
    ) {
        self.evictedPaths = Set(evictedURLs.map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
        self.mtimeOverrideNanos = Dictionary(
            uniqueKeysWithValues: mtimeOverrides.map {
                ($0.key.standardizedFileURL.resolvingSymlinksInPath().path, Int64($0.value.timeIntervalSince1970 * 1_000_000_000.0))
            }
        )
        self.behaviorsByPath = Dictionary(
            uniqueKeysWithValues: behaviors.map {
                ($0.key.standardizedFileURL.resolvingSymlinksInPath().path, $0.value)
            }
        )
    }

    private func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    func setEvicted(_ evicted: Bool, for url: URL) {
        let path = normalizedPath(url)
        lock.lock()
        if evicted {
            evictedPaths.insert(path)
        } else {
            evictedPaths.remove(path)
        }
        lock.unlock()
    }

    func setBehaviors(_ behaviors: [MaterializationBehavior], for url: URL) {
        let path = normalizedPath(url)
        lock.lock()
        behaviorsByPath[path] = behaviors
        lock.unlock()
    }

    func setMtimeOverride(_ date: Date?, for url: URL) {
        let path = normalizedPath(url)
        lock.lock()
        if let date {
            mtimeOverrideNanos[path] = Int64(date.timeIntervalSince1970 * 1_000_000_000.0)
        } else {
            mtimeOverrideNanos.removeValue(forKey: path)
        }
        lock.unlock()
    }

    func setMetadataError(_ code: POSIXErrorCode?, for url: URL) {
        let path = normalizedPath(url)
        lock.lock()
        if let code {
            metadataErrorByPath[path] = code
        } else {
            metadataErrorByPath.removeValue(forKey: path)
        }
        lock.unlock()
    }

    func openCount(for url: URL) -> Int {
        let path = normalizedPath(url)
        lock.lock()
        defer { lock.unlock() }
        return openCallsByPath[path]?.count ?? 0
    }

    func openCalls(for url: URL) -> [(allowMaterialization: Bool, onMainThread: Bool)] {
        let path = normalizedPath(url)
        lock.lock()
        defer { lock.unlock() }
        return openCallsByPath[path] ?? []
    }

    func discoverFiles(under root: URL, matching predicate: (URL) -> Bool) -> [DiscoveredLogFile] {
        underlying.discoverFiles(under: root, matching: predicate).map { item in
            let meta = adjust(metadata: item.metadata, path: normalizedPath(item.url))
            return DiscoveredLogFile(url: item.url, relativePath: item.relativePath, metadata: meta)
        }
    }

    func readMetadata(at url: URL) -> FileMetadata? {
        try? readMetadataOrThrow(at: url)
    }

    func readMetadataOrThrow(at url: URL) throws -> FileMetadata? {
        let path = normalizedPath(url)
        lock.lock()
        let injectedError = metadataErrorByPath[path]
        lock.unlock()
        if let injectedError {
            throw POSIXError(injectedError)
        }
        guard let meta = try underlying.readMetadataOrThrow(at: url) else { return nil }
        return adjust(metadata: meta, path: path)
    }

    func readMetadata(fd: Int32) -> FileMetadata? {
        guard let meta = underlying.readMetadata(fd: fd) else { return nil }
        lock.lock()
        let path = fdToPath[fd]
        lock.unlock()
        guard let path else { return meta }
        return adjust(metadata: meta, path: path)
    }

    func openReadOnly(at url: URL, allowMaterialization: Bool) -> Int32 {
        let path = normalizedPath(url)
        let onMain = Thread.isMainThread

        var behavior: MaterializationBehavior = .succeed
        var wasEvicted = false

        lock.lock()
        openCallsByPath[path, default: []].append((allowMaterialization: allowMaterialization, onMainThread: onMain))
        wasEvicted = evictedPaths.contains(path)
        if allowMaterialization && wasEvicted {
            activeMaterializations += 1
            if activeMaterializations > maxConcurrentMaterializations {
                maxConcurrentMaterializations = activeMaterializations
            }
            if var queue = behaviorsByPath[path], !queue.isEmpty {
                behavior = queue.removeFirst()
                behaviorsByPath[path] = queue
            }
        }
        lock.unlock()

        defer {
            if allowMaterialization && wasEvicted {
                lock.lock()
                activeMaterializations = max(0, activeMaterializations - 1)
                lock.unlock()
            }
        }

        if allowMaterialization && wasEvicted {
            switch behavior {
            case .succeed:
                setEvicted(false, for: url)
            case .delayAndSucceed(let seconds):
                Thread.sleep(forTimeInterval: seconds)
                setEvicted(false, for: url)
            case .stayDataless:
                // Leave path marked evicted so fstat(fd) still reports isDataless == true.
                break
            case .failOpen(let err):
                errno = err
                return -1
            case .blockUntilReleased(let semaphore):
                semaphore.wait()
                setEvicted(false, for: url)
            case .blockUntilReleasedAndFail(let semaphore, let err):
                semaphore.wait()
                errno = err
                return -1
            case .signalAndBlock(let entered, let release):
                entered.signal()
                release.wait()
                setEvicted(false, for: url)
            }
        }

        let fd = underlying.openReadOnly(at: url, allowMaterialization: false)
        if fd >= 0 {
            lock.lock()
            fdToPath[fd] = path
            lock.unlock()
        }
        return fd
    }

    func close(fd: Int32) {
        lock.lock()
        fdToPath.removeValue(forKey: fd)
        lock.unlock()
        underlying.close(fd: fd)
    }

    private func adjust(metadata: FileMetadata, path: String) -> FileMetadata {
        lock.lock()
        let isEvicted = evictedPaths.contains(path)
        let mtime = mtimeOverrideNanos[path] ?? metadata.mtimeNanos
        lock.unlock()

        return FileMetadata(
            size: metadata.size,
            mtimeNanos: mtime,
            inode: metadata.inode,
            device: metadata.device,
            isRegularFile: metadata.isRegularFile,
            isDataless: isEvicted
        )
    }
}

private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ initial: Date) {
        self.current = initial
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}

final class EvictedICloudLogsTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        super.tearDown()
    }

    private func makeTempDir(prefix: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    private var utcCalendar: Calendar {
        StatisticsAggregator.gregorianCalendar(timeZone: TimeZone(secondsFromGMT: 0)!)
    }

    private func claudeLine(id: String, timestamp: String, model: String, input: Int, output: Int, cacheRead: Int) -> String {
        #"{"type":"assistant","requestId":"req_\#(id)","timestamp":"\#(timestamp)","message":{"id":"msg_\#(id)","model":"\#(model)","usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_creation_input_tokens":0,"cache_read_input_tokens":\#(cacheRead)}}}"# + "\n"
    }

    private func codexLines(timestamp: String, model: String, input: Int, cached: Int, output: Int) -> String {
        let total = input + output
        return """
        {"timestamp":"\(timestamp)","type":"turn_context","payload":{"model":"\(model)"}}
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),"output_tokens":\(output),"reasoning_output_tokens":0,"total_tokens":\(total)},"last_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),"output_tokens":\(output),"reasoning_output_tokens":0,"total_tokens":\(total)}}}}
        """ + "\n"
    }

    private func geminiSessionJSON(id: String, timestamp: String, model: String, input: Int, cached: Int, output: Int) -> String {
        let total = input + output
        return """
        {"messages":[{"id":"\(id)","type":"gemini","timestamp":"\(timestamp)","model":"\(model)","tokens":{"input":\(input),"output":\(output),"cached":\(cached),"thoughts":0,"tool":0,"total":\(total)}}]}
        """
    }

    private func openCodeLegacyJSON(id: String, completedMs: Int64, model: String, input: Int, output: Int, cacheRead: Int) -> String {
        let total = input + output + cacheRead
        return """
        {"id":"\(id)","role":"assistant","modelID":"\(model)","time":{"created":\(completedMs - 1000),"completed":\(completedMs)},"tokens":{"input":\(input),"output":\(output),"reasoning":0,"cache":{"read":\(cacheRead),"write":0},"total":\(total)}}
        """
    }

    // MARK: - 1. First pass skips evicted files; background pass counts them and matches a fresh full scan

    func testEvictedFilesSkippedByFirstPassAndCountedByBackgroundPassMatchingFreshFullScan() async throws {
        let root = try makeTempDir(prefix: "evicted-all-sources")
        let anchor = LogTimestampParser.parseISO8601("2026-11-26T18:00:00Z")!

        // Claude: 1 local + 1 evicted
        let claudeDir = root.appendingPathComponent("claude/proj", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let claudeLocal = claudeDir.appendingPathComponent("local.jsonl")
        let claudeEvicted = claudeDir.appendingPathComponent("evicted.jsonl")
        try claudeLine(id: "c1", timestamp: "2026-11-26T10:00:00Z", model: "claude-opus-4.5", input: 1000, output: 200, cacheRead: 3000)
            .write(to: claudeLocal, atomically: true, encoding: .utf8)
        try claudeLine(id: "c2", timestamp: "2026-11-25T11:00:00Z", model: "claude-sonnet-4.5", input: 5000, output: 1000, cacheRead: 9000)
            .write(to: claudeEvicted, atomically: true, encoding: .utf8)

        // Codex: 1 evicted
        let codexDir = root.appendingPathComponent("codex/2026/11", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let codexEvicted = codexDir.appendingPathComponent("rollout-2026-11-25.jsonl")
        try codexLines(timestamp: "2026-11-25T12:00:00Z", model: "gpt-5-codex", input: 8000, cached: 5000, output: 400)
            .write(to: codexEvicted, atomically: true, encoding: .utf8)

        // Gemini: 1 evicted
        let geminiDir = root.appendingPathComponent("gemini/hash/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: geminiDir, withIntermediateDirectories: true)
        let geminiEvicted = geminiDir.appendingPathComponent("session-2026-11-25.json")
        try geminiSessionJSON(id: "g1", timestamp: "2026-11-25T13:00:00Z", model: "gemini-3-pro", input: 4000, cached: 1500, output: 300)
            .write(to: geminiEvicted, atomically: true, encoding: .utf8)

        // OpenCode: 1 evicted legacy JSON
        let openCodeDir = root.appendingPathComponent("opencode", isDirectory: true)
        let openCodeLegacyDir = openCodeDir.appendingPathComponent("storage/message/ses1", isDirectory: true)
        try FileManager.default.createDirectory(at: openCodeLegacyDir, withIntermediateDirectories: true)
        let openCodeEvicted = openCodeLegacyDir.appendingPathComponent("msg_oc_evicted.json")
        try openCodeLegacyJSON(id: "msg_oc_evicted", completedMs: 1795615200000, model: "kimi-k2", input: 2000, output: 500, cacheRead: 1000)
            .write(to: openCodeEvicted, atomically: true, encoding: .utf8)

        let recentDate = anchor.addingTimeInterval(-2 * 86_400)
        let evictedURLs = [claudeEvicted, codexEvicted, geminiEvicted, openCodeEvicted]
        let fileAccess = SimulatedICloudFileAccess(
            evictedURLs: evictedURLs,
            mtimeOverrides: Dictionary(uniqueKeysWithValues: evictedURLs.map { ($0, recentDate) })
        )

        let cacheURL = root.appendingPathComponent("cache.json")
        let cacheStore = TokenLogCacheStore(fileURL: cacheURL)
        let sources: [any IncrementalTokenLogSource] = [
            ClaudeCodeTokenLogSource(rootDirectory: root.appendingPathComponent("claude", isDirectory: true), fileAccess: fileAccess),
            CodexCLITokenLogSource(rootDirectory: root.appendingPathComponent("codex", isDirectory: true), fileAccess: fileAccess),
            GeminiCLITokenLogSource(rootDirectory: root.appendingPathComponent("gemini", isDirectory: true), fileAccess: fileAccess),
            OpenCodeTokenLogSource(rootDirectory: openCodeDir, fileAccess: fileAccess)
        ]

        let enabled: Set<LocalToolSource> = [.claudeCode, .codexCLI, .geminiCLI, .openCode]
        let coordinator = LocalTokenLogCoordinator(
            sources: sources,
            cacheStore: cacheStore,
            perFileTimeout: 5.0,
            clock: { anchor }
        )

        // Pass 1 (local only): must skip all 4 evicted files without opening them, and return local Claude immediately.
        let firstPass = await coordinator.refreshLocalPass(enabledSources: enabled, calendar: utcCalendar, now: anchor)
        XCTAssertEqual(firstPass.pendingICloudFiles, 4)
        for url in evictedURLs {
            XCTAssertEqual(fileAccess.openCount(for: url), 0, "First pass must never open evicted file \(url.lastPathComponent)")
        }
        let firstPassAll = TokenBucketAggregator.merge(firstPass.bucketsBySource.values.flatMap { $0 })
        XCTAssertEqual(TokenSummary.aggregate(firstPassAll).totalTokens, 4200, "Local Claude file should be counted immediately")

        // Pass 2 (low-priority background pass): counts all 4 evicted files one at a time off the main thread.
        let afterPass = await coordinator.runBackgroundMaterializationPass(
            enabledSources: enabled,
            calendar: utcCalendar,
            persistCache: true
        )
        XCTAssertEqual(afterPass.pendingICloudFiles, 0)
        XCTAssertLessThanOrEqual(fileAccess.maxConcurrentMaterializations, 1, "Evicted files must be materialized one at a time")

        for url in evictedURLs {
            let calls = fileAccess.openCalls(for: url)
            XCTAssertEqual(calls.count, 1, "Each evicted file should be downloaded/read exactly once")
            XCTAssertTrue(calls[0].allowMaterialization)
            XCTAssertFalse(calls[0].onMainThread, "Background materialization must never run on the main thread")
        }

        // Totals after the background pass must equal a fresh full scan (with all files local).
        let freshSources: [any IncrementalTokenLogSource] = [
            ClaudeCodeTokenLogSource(rootDirectory: root.appendingPathComponent("claude", isDirectory: true)),
            CodexCLITokenLogSource(rootDirectory: root.appendingPathComponent("codex", isDirectory: true)),
            GeminiCLITokenLogSource(rootDirectory: root.appendingPathComponent("gemini", isDirectory: true)),
            OpenCodeTokenLogSource(rootDirectory: openCodeDir)
        ]
        var freshBuckets: [TokenBucket] = []
        for source in freshSources {
            var s = SourceCacheState()
            freshBuckets.append(contentsOf: try source.refresh(state: &s, calendar: utcCalendar))
        }
        let expectedMerged = TokenBucketAggregator.merge(freshBuckets)
        let actualMerged = TokenBucketAggregator.merge(afterPass.bucketsBySource.values.flatMap { $0 })
        XCTAssertEqual(actualMerged, expectedMerged, "Totals after background pass must equal a fresh full scan")

        // If macOS later re-evicts the already-cached file (same identity, size, mtime), it must NOT be re-downloaded.
        fileAccess.setEvicted(true, for: claudeEvicted)
        let thirdPass = await coordinator.refreshLocalPass(enabledSources: enabled, calendar: utcCalendar, now: anchor)
        XCTAssertEqual(thirdPass.pendingICloudFiles, 0)
        XCTAssertEqual(fileAccess.openCount(for: claudeEvicted), 1, "Already-cached evicted file must not be re-read")
        let thirdMerged = TokenBucketAggregator.merge(thirdPass.bucketsBySource.values.flatMap { $0 })
        XCTAssertEqual(thirdMerged, expectedMerged)
    }

    // MARK: - 2. Old evicted files (> 30 + 1 days) are never read

    func testOldEvictedFileOlderThan31DaysIsNeverRead() async throws {
        let root = try makeTempDir(prefix: "evicted-old-cutoff")
        let projDir = root.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)

        let anchor = LogTimestampParser.parseISO8601("2026-11-26T18:00:00Z")!
        let recentURL = projDir.appendingPathComponent("recent.jsonl")
        let oldURL = projDir.appendingPathComponent("old.jsonl")

        try claudeLine(id: "r1", timestamp: "2026-11-20T10:00:00Z", model: "claude-opus-4.5", input: 1000, output: 100, cacheRead: 0)
            .write(to: recentURL, atomically: true, encoding: .utf8)
        try claudeLine(id: "o1", timestamp: "2026-10-01T10:00:00Z", model: "claude-opus-4.5", input: 9999, output: 1, cacheRead: 0)
            .write(to: oldURL, atomically: true, encoding: .utf8)

        let fileAccess = SimulatedICloudFileAccess(
            evictedURLs: [recentURL, oldURL],
            mtimeOverrides: [
                recentURL: anchor.addingTimeInterval(-6 * 86_400),   // 6 days old -> inside 31d window
                oldURL: anchor.addingTimeInterval(-32 * 86_400)      // 32 days old -> outside 31d window
            ]
        )

        let source = ClaudeCodeTokenLogSource(rootDirectory: root, fileAccess: fileAccess)
        let coordinator = LocalTokenLogCoordinator(
            sources: [source],
            cacheStore: TokenLogCacheStore(fileURL: root.appendingPathComponent("cache.json")),
            clock: { anchor }
        )

        let localPass = await coordinator.refreshLocalPass(enabledSources: [.claudeCode], calendar: utcCalendar, now: anchor)
        XCTAssertEqual(localPass.pendingICloudFiles, 1, "Only the recent evicted file should be pending")
        XCTAssertEqual(fileAccess.openCount(for: oldURL), 0)

        let afterPass = await coordinator.runBackgroundMaterializationPass(enabledSources: [.claudeCode], calendar: utcCalendar)
        XCTAssertEqual(afterPass.pendingICloudFiles, 0)
        XCTAssertEqual(fileAccess.openCount(for: recentURL), 1)
        XCTAssertEqual(fileAccess.openCount(for: oldURL), 0, "Old evicted file (>31 days) must never be materialized or read")

        let total = TokenSummary.aggregate(afterPass.bucketsBySource[.claudeCode] ?? []).totalTokens
        XCTAssertEqual(total, 1100)
    }

    // MARK: - 3. Read timeout & still-dataless leave file pending and retry with backoff

    func testTimedOutAndStillDatalessReadsLeaveFilePendingAndRetryWithBackoff() async throws {
        let root = try makeTempDir(prefix: "evicted-timeout-retry")
        let projDir = root.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)

        let anchor = LogTimestampParser.parseISO8601("2026-11-26T18:00:00Z")!
        let clock = MutableClock(anchor)

        let evictedURL = projDir.appendingPathComponent("flaky.jsonl")
        try claudeLine(id: "f1", timestamp: "2026-11-26T14:00:00Z", model: "claude-opus-4.5", input: 2500, output: 500, cacheRead: 1000)
            .write(to: evictedURL, atomically: true, encoding: .utf8)

        let releaseTimedOutRead = DispatchSemaphore(value: 0)
        defer { releaseTimedOutRead.signal() }

        let fileAccess = SimulatedICloudFileAccess(
            evictedURLs: [evictedURL],
            mtimeOverrides: [evictedURL: anchor.addingTimeInterval(-3600)],
            behaviors: [
                evictedURL: [
                    .blockUntilReleasedAndFail(releaseTimedOutRead, ETIMEDOUT), // Attempt 1: hangs -> hits perFileTimeout & fails
                    .stayDataless,                                              // Attempt 2: remains dataless -> still pending
                    .succeed                                                    // Attempt 3: materializes and counts cleanly
                ]
            ]
        )

        let source = ClaudeCodeTokenLogSource(rootDirectory: root, fileAccess: fileAccess)
        let coordinator = LocalTokenLogCoordinator(
            sources: [source],
            cacheStore: TokenLogCacheStore(fileURL: root.appendingPathComponent("cache.json")),
            perFileTimeout: 0.12,
            backoffPolicy: EvictedRetryBackoffPolicy(baseDelay: 30.0, maxDelay: 600.0),
            clock: { clock.now() }
        )

        // First local pass discovers the evicted file.
        let localPass = await coordinator.refreshLocalPass(enabledSources: [.claudeCode], calendar: utcCalendar)
        XCTAssertEqual(localPass.pendingICloudFiles, 1)

        // Attempt 1: times out cleanly without hanging, leaves file pending with 30s backoff.
        let afterTimeout = await coordinator.runBackgroundMaterializationPass(enabledSources: [.claudeCode], calendar: utcCalendar)
        XCTAssertEqual(afterTimeout.pendingICloudFiles, 1, "Timed-out file must remain pending")
        XCTAssertEqual(fileAccess.openCount(for: evictedURL), 1)
        XCTAssertEqual(TokenSummary.aggregate(afterTimeout.bucketsBySource[.claudeCode] ?? []).totalTokens, 0)

        // Unblock the abandoned attempt 1 worker cleanly and re-assert evicted state before attempt 2.
        releaseTimedOutRead.signal()
        try await Task.sleep(nanoseconds: 50_000_000)
        fileAccess.setEvicted(true, for: evictedURL)

        // Immediate retry before backoff expires must NOT re-attempt yet.
        let duringBackoff = await coordinator.runBackgroundMaterializationPass(enabledSources: [.claudeCode], calendar: utcCalendar)
        XCTAssertEqual(duringBackoff.pendingICloudFiles, 1)
        XCTAssertEqual(fileAccess.openCount(for: evictedURL), 1, "Backoff must suppress immediate retry")

        // Advance clock past 30s backoff -> Attempt 2 runs, file stays dataless -> still pending with 60s backoff.
        clock.advance(by: 31.0)
        let afterStillDataless = await coordinator.runBackgroundMaterializationPass(enabledSources: [.claudeCode], calendar: utcCalendar)
        XCTAssertEqual(afterStillDataless.pendingICloudFiles, 1)
        XCTAssertEqual(fileAccess.openCount(for: evictedURL), 2)

        // Advance clock by only 40s (< 60s second backoff) -> still backed off.
        clock.advance(by: 40.0)
        let stillBackedOff = await coordinator.runBackgroundMaterializationPass(enabledSources: [.claudeCode], calendar: utcCalendar)
        XCTAssertEqual(stillBackedOff.pendingICloudFiles, 1)
        XCTAssertEqual(fileAccess.openCount(for: evictedURL), 2)

        // Advance clock past 60s backoff -> Attempt 3 succeeds, counts file, pending drops to 0.
        clock.advance(by: 25.0)
        let afterSuccess = await coordinator.runBackgroundMaterializationPass(enabledSources: [.claudeCode], calendar: utcCalendar)
        XCTAssertEqual(afterSuccess.pendingICloudFiles, 0)
        XCTAssertEqual(fileAccess.openCount(for: evictedURL), 3)
        XCTAssertEqual(TokenSummary.aggregate(afterSuccess.bucketsBySource[.claudeCode] ?? []).totalTokens, 4000)
    }

    // MARK: - 4. --dump-token-summary waits for background pass and prints pending_icloud_files=N

    func testDumpTokenSummaryWaitsForBackgroundPassAndPrintsPendingLine() async throws {
        let root = try makeTempDir(prefix: "evicted-dumper")
        let projDir = root.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)

        let anchor = LogTimestampParser.parseISO8601("2026-11-26T18:00:00Z")!
        let evictedURL = projDir.appendingPathComponent("evicted.jsonl")
        try claudeLine(id: "d1", timestamp: "2026-11-26T15:00:00Z", model: "claude-opus-4.5", input: 3000, output: 700, cacheRead: 1300)
            .write(to: evictedURL, atomically: true, encoding: .utf8)

        let fileAccess = SimulatedICloudFileAccess(
            evictedURLs: [evictedURL],
            mtimeOverrides: [evictedURL: anchor.addingTimeInterval(-600)],
            behaviors: [evictedURL: [.delayAndSucceed(0.05)]]
        )

        let source = ClaudeCodeTokenLogSource(rootDirectory: root, fileAccess: fileAccess)
        let coordinator = LocalTokenLogCoordinator(
            sources: [source],
            cacheStore: TokenLogCacheStore(fileURL: root.appendingPathComponent("cache.json")),
            clock: { anchor }
        )

        let report = await TokenSummaryDumper.generateReport(
            isDemo: false,
            anchorDate: anchor,
            calendar: utcCalendar,
            coordinator: coordinator,
            enabledSources: [.claudeCode],
            backgroundWaitTimeout: 10.0
        )

        XCTAssertTrue(report.contains("claude: total=5000 input=3000 output=700 cache=1300 requests=1"))
        let lines = report.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.last, "pending_icloud_files=0")

        // When a file cannot be materialized (stays dataless), report finishes cleanly with pending_icloud_files=1.
        let stuckURL = projDir.appendingPathComponent("stuck.jsonl")
        try claudeLine(id: "d2", timestamp: "2026-11-26T16:00:00Z", model: "claude-opus-4.5", input: 100, output: 50, cacheRead: 0)
            .write(to: stuckURL, atomically: true, encoding: .utf8)

        let stuckAccess = SimulatedICloudFileAccess(
            evictedURLs: [stuckURL],
            mtimeOverrides: [stuckURL: anchor.addingTimeInterval(-300)],
            behaviors: [stuckURL: [.stayDataless]]
        )
        let stuckCoordinator = LocalTokenLogCoordinator(
            sources: [ClaudeCodeTokenLogSource(rootDirectory: root, fileAccess: stuckAccess)],
            cacheStore: TokenLogCacheStore(fileURL: root.appendingPathComponent("cache-stuck.json")),
            clock: { anchor }
        )
        let stuckReport = await TokenSummaryDumper.generateReport(
            isDemo: false,
            anchorDate: anchor,
            calendar: utcCalendar,
            coordinator: stuckCoordinator,
            enabledSources: [.claudeCode],
            backgroundWaitTimeout: 5.0
        )
        XCTAssertEqual(stuckReport.split(separator: "\n").map(String.init).last, "pending_icloud_files=1")
    }

    // MARK: - 5. Demo mode never starts the background pass

    func testDemoModeNeverStartsBackgroundPass() async throws {
        let root = try makeTempDir(prefix: "evicted-demo")
        let projDir = root.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)

        let anchor = LogTimestampParser.parseISO8601("2026-11-26T18:00:00Z")!
        let evictedURL = projDir.appendingPathComponent("evicted.jsonl")
        try claudeLine(id: "demo1", timestamp: "2026-11-26T15:00:00Z", model: "claude-opus-4.5", input: 3000, output: 700, cacheRead: 1300)
            .write(to: evictedURL, atomically: true, encoding: .utf8)

        let fileAccess = SimulatedICloudFileAccess(
            evictedURLs: [evictedURL],
            mtimeOverrides: [evictedURL: anchor.addingTimeInterval(-600)]
        )
        let source = ClaudeCodeTokenLogSource(rootDirectory: root, fileAccess: fileAccess)
        let coordinator = LocalTokenLogCoordinator(
            sources: [source],
            cacheStore: TokenLogCacheStore(fileURL: root.appendingPathComponent("cache.json")),
            clock: { anchor }
        )

        let report = await TokenSummaryDumper.generateReport(
            isDemo: true,
            anchorDate: anchor,
            calendar: utcCalendar,
            coordinator: coordinator,
            enabledSources: [.claudeCode]
        )

        XCTAssertEqual(fileAccess.openCount(for: evictedURL), 0, "Demo mode must never read or materialize local files")
        let pendingCount = await coordinator.pendingICloudFileCount(for: [.claudeCode])
        XCTAssertEqual(pendingCount, 0, "Demo mode must never run local or background discovery passes")
        XCTAssertEqual(report.split(separator: "\n").map(String.init).last, "pending_icloud_files=0")
    }

    // MARK: - 6. Pipeline publishes local results immediately without blocking on evicted files

    @MainActor
    func testPipelinePublishesLocalResultsImmediatelyThenCountsEvictedInBackground() async throws {
        let root = try makeTempDir(prefix: "evicted-pipeline")
        let projDir = root.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)

        let anchor = LogTimestampParser.parseISO8601("2026-11-26T18:00:00Z")!
        let localURL = projDir.appendingPathComponent("local.jsonl")
        let evictedURL = projDir.appendingPathComponent("evicted.jsonl")

        try claudeLine(id: "p1", timestamp: "2026-11-26T12:00:00Z", model: "claude-opus-4.5", input: 1000, output: 200, cacheRead: 0)
            .write(to: localURL, atomically: true, encoding: .utf8)
        try claudeLine(id: "p2", timestamp: "2026-11-26T13:00:00Z", model: "claude-sonnet-4.5", input: 4000, output: 800, cacheRead: 0)
            .write(to: evictedURL, atomically: true, encoding: .utf8)

        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }

        let fileAccess = SimulatedICloudFileAccess(
            evictedURLs: [evictedURL],
            mtimeOverrides: [evictedURL: anchor.addingTimeInterval(-600)],
            behaviors: [evictedURL: [.blockUntilReleased(gate)]]
        )
        let source = ClaudeCodeTokenLogSource(rootDirectory: root, fileAccess: fileAccess)
        let coordinator = LocalTokenLogCoordinator(
            sources: [source],
            cacheStore: TokenLogCacheStore(fileURL: root.appendingPathComponent("cache.json")),
            perFileTimeout: 5.0,
            clock: { anchor }
        )

        var latestTotalTokens = 0
        var pendingHistory: [Int] = []

        let pipeline = LocalLogPipelineController(
            coordinator: coordinator,
            calendar: utcCalendar,
            clock: { anchor },
            enabledSources: { [.claudeCode] },
            onBucketsUpdated: { bySource, _ in
                let merged = TokenBucketAggregator.merge(bySource.values.flatMap { $0 })
                latestTotalTokens = TokenSummary.aggregate(merged).totalTokens
            },
            onPendingICloudFilesChanged: { count in
                pendingHistory.append(count)
            }
        )
        defer { pipeline.stop() }

        // refreshLogs() MUST return immediately with local-only results while evicted file is still gated.
        await pipeline.refreshLogs()
        XCTAssertEqual(latestTotalTokens, 1200, "Local results must be published without waiting for iCloud materialization")
        XCTAssertEqual(pendingHistory.last, 1)

        // Release the gate and wait for the low-priority background pass to finish.
        gate.signal()
        await pipeline.waitForBackgroundMaterialization()

        XCTAssertEqual(latestTotalTokens, 6000, "Background pass must add the evicted file's tokens")
        XCTAssertEqual(pendingHistory.last, 0, "Pending count must drop to 0 once background pass completes")
    }

    // MARK: - 7. Defect 1: Timed-out reads hold the single slot and never overlap

    func testTimedOutReadHoldsSingleSlotPreventingConcurrentOrRetryOverlap() async throws {
        let root = try makeTempDir(prefix: "evicted-single-slot")
        let projDir = root.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)

        let anchor = LogTimestampParser.parseISO8601("2026-11-26T18:00:00Z")!
        let clock = MutableClock(anchor)

        let blockedURL = projDir.appendingPathComponent("a-blocked.jsonl")
        let queuedURL = projDir.appendingPathComponent("b-queued.jsonl")
        try claudeLine(id: "s1", timestamp: "2026-11-26T12:00:00Z", model: "claude-opus-4.5", input: 1000, output: 200, cacheRead: 0)
            .write(to: blockedURL, atomically: true, encoding: .utf8)
        try claudeLine(id: "s2", timestamp: "2026-11-26T13:00:00Z", model: "claude-sonnet-4.5", input: 2000, output: 300, cacheRead: 0)
            .write(to: queuedURL, atomically: true, encoding: .utf8)

        let enteredFirst = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        defer { releaseFirst.signal() }

        let fileAccess = SimulatedICloudFileAccess(
            evictedURLs: [blockedURL, queuedURL],
            mtimeOverrides: [
                blockedURL: anchor.addingTimeInterval(-60),   // newer -> attempted first
                queuedURL: anchor.addingTimeInterval(-120)    // older -> queued second
            ],
            behaviors: [
                blockedURL: [.signalAndBlock(entered: enteredFirst, release: releaseFirst), .succeed],
                queuedURL: [.succeed]
            ]
        )

        let source = ClaudeCodeTokenLogSource(rootDirectory: root, fileAccess: fileAccess)
        let coordinator = LocalTokenLogCoordinator(
            sources: [source],
            cacheStore: TokenLogCacheStore(fileURL: root.appendingPathComponent("cache.json")),
            perFileTimeout: 0.12,
            backoffPolicy: EvictedRetryBackoffPolicy(baseDelay: 30.0, maxDelay: 300.0),
            clock: { clock.now() }
        )

        let local = await coordinator.refreshLocalPass(enabledSources: [.claudeCode], calendar: utcCalendar)
        XCTAssertEqual(local.pendingICloudFiles, 2)

        // Pass 1: first file blocks past perFileTimeout AND totalTimeout.
        // Pass MUST return within deadline, leave both files pending, and NEVER start a second materialization.
        let start1 = Date()
        let pass1 = await coordinator.runBackgroundMaterializationPass(
            enabledSources: [.claudeCode],
            calendar: utcCalendar,
            totalTimeout: 0.25
        )
        let elapsed1 = Date().timeIntervalSince(start1)
        XCTAssertEqual(enteredFirst.wait(timeout: .now() + 1.0), .success)
        XCTAssertLessThan(elapsed1, 1.0, "Pass must return within its bounded deadline")
        XCTAssertEqual(pass1.pendingICloudFiles, 2)
        XCTAssertEqual(fileAccess.openCount(for: blockedURL), 1)
        XCTAssertEqual(fileAccess.openCount(for: queuedURL), 0, "Second file must not start while first read is active")
        XCTAssertEqual(fileAccess.maxConcurrentMaterializations, 1, "Peak concurrency must stay 1")

        // Advance logical clock past backoff while keeping the FIRST reader STILL blocked!
        clock.advance(by: 60.0)
        let start2 = Date()
        let pass2 = await coordinator.runBackgroundMaterializationPass(
            enabledSources: [.claudeCode],
            calendar: utcCalendar,
            totalTimeout: 0.20
        )
        let elapsed2 = Date().timeIntervalSince(start2)
        XCTAssertLessThan(elapsed2, 1.0, "Retry pass must also return within its bounded deadline")
        XCTAssertEqual(pass2.pendingICloudFiles, 2)
        XCTAssertEqual(fileAccess.openCount(for: blockedURL), 1, "Blocked file must not be reopened while first read is active")
        XCTAssertEqual(fileAccess.openCount(for: queuedURL), 0, "Queued file must not start while first read is active")
        XCTAssertEqual(fileAccess.maxConcurrentMaterializations, 1, "Peak concurrency must stay 1 across retries")

        // Now release the blocked read, re-evict blockedURL so the retry counts it cleanly, and finish both files.
        releaseFirst.signal()
        try await Task.sleep(nanoseconds: 60_000_000)
        fileAccess.setEvicted(true, for: blockedURL)
        clock.advance(by: 60.0)

        let pass3 = await coordinator.runBackgroundMaterializationPass(
            enabledSources: [.claudeCode],
            calendar: utcCalendar,
            totalTimeout: 5.0
        )
        XCTAssertEqual(pass3.pendingICloudFiles, 0)
        XCTAssertEqual(fileAccess.maxConcurrentMaterializations, 1)
        XCTAssertEqual(TokenSummary.aggregate(pass3.bucketsBySource[.claudeCode] ?? []).totalTokens, 3500)
    }

    // MARK: - 8. Defect 2: Disabling a local source stops subsequent opens and updates pending count

    @MainActor
    func testDisablingLocalSourceStopsQueuedBackgroundDownloadsAndUpdatesPendingCount() async throws {
        let root = try makeTempDir(prefix: "evicted-disable-source")
        let claudeDir = root.appendingPathComponent("claude/proj", isDirectory: true)
        let codexDir = root.appendingPathComponent("codex/2026/11", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)

        let anchor = LogTimestampParser.parseISO8601("2026-11-26T18:00:00Z")!
        let claudeFile = claudeDir.appendingPathComponent("first.jsonl")
        let codexFile1 = codexDir.appendingPathComponent("rollout-1.jsonl")
        let codexFile2 = codexDir.appendingPathComponent("rollout-2.jsonl")

        try claudeLine(id: "d1", timestamp: "2026-11-26T12:00:00Z", model: "claude-opus-4.5", input: 1000, output: 100, cacheRead: 0)
            .write(to: claudeFile, atomically: true, encoding: .utf8)
        try codexLines(timestamp: "2026-11-26T13:00:00Z", model: "gpt-5-codex", input: 4000, cached: 1000, output: 200)
            .write(to: codexFile1, atomically: true, encoding: .utf8)
        try codexLines(timestamp: "2026-11-26T14:00:00Z", model: "gpt-5-codex", input: 5000, cached: 1000, output: 300)
            .write(to: codexFile2, atomically: true, encoding: .utf8)

        let claudeEntered = DispatchSemaphore(value: 0)
        let claudeRelease = DispatchSemaphore(value: 0)
        defer { claudeRelease.signal() }

        let fileAccess = SimulatedICloudFileAccess(
            evictedURLs: [claudeFile, codexFile1, codexFile2],
            mtimeOverrides: [
                claudeFile: anchor.addingTimeInterval(-60),   // newest -> picked first
                codexFile1: anchor.addingTimeInterval(-120),
                codexFile2: anchor.addingTimeInterval(-180)
            ],
            behaviors: [
                claudeFile: [.signalAndBlock(entered: claudeEntered, release: claudeRelease)],
                codexFile1: [.succeed],
                codexFile2: [.succeed]
            ]
        )

        let sources: [any IncrementalTokenLogSource] = [
            ClaudeCodeTokenLogSource(rootDirectory: root.appendingPathComponent("claude", isDirectory: true), fileAccess: fileAccess),
            CodexCLITokenLogSource(rootDirectory: root.appendingPathComponent("codex", isDirectory: true), fileAccess: fileAccess)
        ]
        let coordinator = LocalTokenLogCoordinator(
            sources: sources,
            cacheStore: TokenLogCacheStore(fileURL: root.appendingPathComponent("cache.json")),
            perFileTimeout: 5.0,
            clock: { anchor }
        )

        @MainActor
        final class ToggleTestState {
            var enabled: Set<LocalToolSource> = [.claudeCode, .codexCLI]
            var pendingAfterDisable: [Int] = []
            var sawDisable = false
        }
        let state = ToggleTestState()

        let pipeline = LocalLogPipelineController(
            coordinator: coordinator,
            calendar: utcCalendar,
            clock: { anchor },
            enabledSources: { state.enabled },
            onBucketsUpdated: { _, _ in },
            onPendingICloudFilesChanged: { count in
                if state.sawDisable {
                    state.pendingAfterDisable.append(count)
                }
            }
        )
        defer { pipeline.stop() }

        await pipeline.refreshLogs()
        XCTAssertEqual(claudeEntered.wait(timeout: .now() + 2.0), .success, "Background pass should start on Claude file")

        // Disable Codex while background pass is in flight on Claude.
        state.enabled.remove(.codexCLI)
        state.sawDisable = true
        await pipeline.handleSourceToggled(isNowEnabled: false)
        XCTAssertEqual(state.pendingAfterDisable.first, 1, "Disabling Codex must immediately drop pending count from 3 to 1")

        // Release Claude and let background pass complete.
        claudeRelease.signal()
        await pipeline.waitForBackgroundMaterialization()

        XCTAssertEqual(fileAccess.openCount(for: claudeFile), 1)
        XCTAssertEqual(fileAccess.openCount(for: codexFile1), 0, "Disabled Codex file must never be opened")
        XCTAssertEqual(fileAccess.openCount(for: codexFile2), 0, "Disabled Codex file must never be opened")
        XCTAssertTrue(state.pendingAfterDisable.allSatisfy { $0 <= 1 }, "Progress updates must never flash disabled source's old pending count: \(state.pendingAfterDisable)")
        XCTAssertEqual(state.pendingAfterDisable.last, 0)
    }

    // MARK: - 9. Defect 3: Worker re-validates 31-day cutoff and version before opening

    func testBackgroundWorkerValidatesCurrentAgeAndVersionBeforeOpening() async throws {
        let root = try makeTempDir(prefix: "evicted-recheck-age-version")
        let projDir = root.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)

        let anchor = LogTimestampParser.parseISO8601("2026-11-26T18:00:00Z")!
        let agedURL = projDir.appendingPathComponent("aged.jsonl")
        let replacedURL = projDir.appendingPathComponent("replaced.jsonl")

        try claudeLine(id: "a1", timestamp: "2026-11-25T10:00:00Z", model: "claude-opus-4.5", input: 1000, output: 100, cacheRead: 0)
            .write(to: agedURL, atomically: true, encoding: .utf8)
        try claudeLine(id: "r1", timestamp: "2026-11-25T11:00:00Z", model: "claude-opus-4.5", input: 2000, output: 100, cacheRead: 0)
            .write(to: replacedURL, atomically: true, encoding: .utf8)

        let fileAccess = SimulatedICloudFileAccess(
            evictedURLs: [agedURL, replacedURL],
            mtimeOverrides: [
                agedURL: anchor.addingTimeInterval(-2 * 86_400),
                replacedURL: anchor.addingTimeInterval(-2 * 86_400)
            ]
        )

        let source = ClaudeCodeTokenLogSource(rootDirectory: root, fileAccess: fileAccess)
        let coordinator = LocalTokenLogCoordinator(
            sources: [source],
            cacheStore: TokenLogCacheStore(fileURL: root.appendingPathComponent("cache.json")),
            clock: { anchor }
        )

        let local = await coordinator.refreshLocalPass(enabledSources: [.claudeCode], calendar: utcCalendar, now: anchor)
        XCTAssertEqual(local.pendingICloudFiles, 2)

        // Probe 1: Mutate agedURL's mtime to 60 days old after discovery.
        fileAccess.setMtimeOverride(anchor.addingTimeInterval(-60 * 86_400), for: agedURL)

        // Probe 2: Atomically replace replacedURL with a different inode after discovery (still evicted).
        let replacementTemp = projDir.appendingPathComponent("replaced.tmp")
        try claudeLine(id: "r2", timestamp: "2026-11-25T12:00:00Z", model: "claude-opus-4.5", input: 9000, output: 500, cacheRead: 0)
            .write(to: replacementTemp, atomically: false, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(replacedURL, withItemAt: replacementTemp)
        fileAccess.setEvicted(true, for: replacedURL)

        // Background pass MUST record ZERO opens for both files!
        let afterPass = await coordinator.runBackgroundMaterializationPass(
            enabledSources: [.claudeCode],
            calendar: utcCalendar
        )
        XCTAssertEqual(fileAccess.openCount(for: agedURL), 0, "File aged past 31 days before background pass must record zero opens")
        XCTAssertEqual(fileAccess.openCount(for: replacedURL), 0, "Replaced file version must record zero opens")
        XCTAssertEqual(afterPass.pendingICloudFiles, 0)
    }

    // MARK: - 10. Defect 4: Stale worker cannot overwrite replacement inode cache or clear its pending entry

    func testStaleWorkerDoesNotOverwriteReplacementInodeCacheOrPendingState() async throws {
        let root = try makeTempDir(prefix: "evicted-rotation-race")
        let projDir = root.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)

        let anchor = LogTimestampParser.parseISO8601("2026-11-26T18:00:00Z")!

        // Case A: While worker scans evicted inode 1, file is rotated to a LOCAL replacement inode 2 (with earlier mtime!)
        // and counted by a concurrent refreshLocalPass.
        let fileA = projDir.appendingPathComponent("rot-local.jsonl")
        try claudeLine(id: "oldA", timestamp: "2026-11-26T10:00:00Z", model: "claude-opus-4.5", input: 1000, output: 100, cacheRead: 0)
            .write(to: fileA, atomically: false, encoding: .utf8)

        let enteredA = DispatchSemaphore(value: 0)
        let releaseA = DispatchSemaphore(value: 0)
        defer { releaseA.signal() }

        let accessA = SimulatedICloudFileAccess(
            evictedURLs: [fileA],
            mtimeOverrides: [fileA: anchor.addingTimeInterval(-60)],
            behaviors: [fileA: [.signalAndBlock(entered: enteredA, release: releaseA)]]
        )
        let sourceA = ClaudeCodeTokenLogSource(rootDirectory: root, fileAccess: accessA)
        let coordinatorA = LocalTokenLogCoordinator(
            sources: [sourceA],
            cacheStore: TokenLogCacheStore(fileURL: root.appendingPathComponent("cacheA.json")),
            perFileTimeout: 5.0,
            clock: { anchor }
        )

        let localA = await coordinatorA.refreshLocalPass(enabledSources: [.claudeCode], calendar: utcCalendar, now: anchor)
        XCTAssertEqual(localA.pendingICloudFiles, 1)

        let calendarA = utcCalendar
        let bgTaskA = Task {
            await coordinatorA.runBackgroundMaterializationPass(enabledSources: [.claudeCode], calendar: calendarA)
        }
        XCTAssertEqual(enteredA.wait(timeout: .now() + 2.0), .success)

        // Rotate fileA to a brand new LOCAL inode with 9,500 tokens AND an earlier mtime (-3600s < -60s).
        let tempA = projDir.appendingPathComponent("rot-local.tmp")
        try claudeLine(id: "newA", timestamp: "2026-11-26T11:00:00Z", model: "claude-sonnet-4.5", input: 9000, output: 500, cacheRead: 0)
            .write(to: tempA, atomically: false, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(fileA, withItemAt: tempA)
        accessA.setEvicted(false, for: fileA)
        accessA.setMtimeOverride(anchor.addingTimeInterval(-3600), for: fileA)

        // Concurrent local refresh counts the replacement inode.
        let duringA = await coordinatorA.refreshLocalPass(enabledSources: [.claudeCode], calendar: utcCalendar, now: anchor)
        XCTAssertEqual(duringA.pendingICloudFiles, 0)
        XCTAssertEqual(TokenSummary.aggregate(duringA.bucketsBySource[.claudeCode] ?? []).totalTokens, 9500)

        // Release stale worker for inode 1; it must NOT overwrite inode 2's cache entry!
        releaseA.signal()
        let finalA = await bgTaskA.value
        XCTAssertEqual(finalA.pendingICloudFiles, 0)
        XCTAssertEqual(TokenSummary.aggregate(finalA.bucketsBySource[.claudeCode] ?? []).totalTokens, 9500)

        var freshStateA = SourceCacheState()
        let freshA = try ClaudeCodeTokenLogSource(rootDirectory: root).refresh(state: &freshStateA, calendar: utcCalendar)
        XCTAssertEqual(finalA.bucketsBySource[.claudeCode], freshA, "Totals after rotation must equal a fresh scan")

        // Case B: While worker scans evicted inode 1, file is rotated to a NEW EVICTED inode 2 and queued by refreshLocalPass.
        let rootB = try makeTempDir(prefix: "evicted-rotation-evicted")
        let projB = rootB.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projB, withIntermediateDirectories: true)
        let fileB = projB.appendingPathComponent("rot-evicted.jsonl")
        try claudeLine(id: "oldB", timestamp: "2026-11-26T10:00:00Z", model: "claude-opus-4.5", input: 1000, output: 100, cacheRead: 0)
            .write(to: fileB, atomically: false, encoding: .utf8)

        let enteredB = DispatchSemaphore(value: 0)
        let releaseB = DispatchSemaphore(value: 0)
        defer { releaseB.signal() }

        let accessB = SimulatedICloudFileAccess(
            evictedURLs: [fileB],
            mtimeOverrides: [fileB: anchor.addingTimeInterval(-120)],
            behaviors: [fileB: [.signalAndBlock(entered: enteredB, release: releaseB), .succeed]]
        )
        let sourceB = ClaudeCodeTokenLogSource(rootDirectory: rootB, fileAccess: accessB)
        let coordinatorB = LocalTokenLogCoordinator(
            sources: [sourceB],
            cacheStore: TokenLogCacheStore(fileURL: rootB.appendingPathComponent("cacheB.json")),
            perFileTimeout: 5.0,
            clock: { anchor }
        )

        let localB = await coordinatorB.refreshLocalPass(enabledSources: [.claudeCode], calendar: utcCalendar, now: anchor)
        XCTAssertEqual(localB.pendingICloudFiles, 1)

        let calendarB = utcCalendar
        let bgTaskB = Task {
            await coordinatorB.runBackgroundMaterializationPass(enabledSources: [.claudeCode], calendar: calendarB)
        }
        XCTAssertEqual(enteredB.wait(timeout: .now() + 2.0), .success)

        // Rotate fileB to a new EVICTED inode 2 with 7,200 tokens.
        let tempB = projB.appendingPathComponent("rot-evicted.tmp")
        try claudeLine(id: "newB", timestamp: "2026-11-26T12:00:00Z", model: "claude-sonnet-4.5", input: 7000, output: 200, cacheRead: 0)
            .write(to: tempB, atomically: false, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(fileB, withItemAt: tempB)
        accessB.setEvicted(true, for: fileB)
        accessB.setMtimeOverride(anchor.addingTimeInterval(-30), for: fileB)

        // Concurrent local refresh queues replacement inode 2 as pending.
        let duringB = await coordinatorB.refreshLocalPass(enabledSources: [.claudeCode], calendar: utcCalendar, now: anchor)
        XCTAssertEqual(duringB.pendingICloudFiles, 1)

        // Release stale inode 1 worker; it must NOT clear inode 2's pending entry or install inode 1's buckets.
        // Instead, inode 2 is materialized and final totals match a fresh scan (7,200 tokens).
        releaseB.signal()
        let finalB = await bgTaskB.value
        XCTAssertEqual(finalB.pendingICloudFiles, 0)
        XCTAssertEqual(TokenSummary.aggregate(finalB.bucketsBySource[.claudeCode] ?? []).totalTokens, 7200)

        var freshStateB = SourceCacheState()
        let freshB = try ClaudeCodeTokenLogSource(rootDirectory: rootB).refresh(state: &freshStateB, calendar: utcCalendar)
        XCTAssertEqual(finalB.bucketsBySource[.claudeCode], freshB, "Totals after evicted-to-evicted rotation must equal a fresh scan")
    }

    // MARK: - 11. Defect 5: Transient metadata errors preserve cached usage and retry with backoff

    func testTransientMetadataErrorPreservesCachedUsageAndQueuesRetry() async throws {
        let root = try makeTempDir(prefix: "evicted-transient-metadata-err")
        let projDir = root.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)

        let anchor = LogTimestampParser.parseISO8601("2026-11-26T18:00:00Z")!
        let clock = MutableClock(anchor)
        let logURL = projDir.appendingPathComponent("session.jsonl")

        // Step 1: Start local with 4,200 tokens and scan it into cache.
        let line1 = claudeLine(id: "m1", timestamp: "2026-11-26T10:00:00Z", model: "claude-opus-4.5", input: 1000, output: 200, cacheRead: 3000)
        try line1.write(to: logURL, atomically: false, encoding: .utf8)

        let fileAccess = SimulatedICloudFileAccess(
            evictedURLs: [],
            mtimeOverrides: [logURL: anchor.addingTimeInterval(-300)]
        )
        let source = ClaudeCodeTokenLogSource(rootDirectory: root, fileAccess: fileAccess)
        let coordinator = LocalTokenLogCoordinator(
            sources: [source],
            cacheStore: TokenLogCacheStore(fileURL: root.appendingPathComponent("cache.json")),
            backoffPolicy: EvictedRetryBackoffPolicy(baseDelay: 30.0, maxDelay: 300.0),
            clock: { clock.now() }
        )

        let initial = await coordinator.refreshLocalPass(enabledSources: [.claudeCode], calendar: utcCalendar)
        XCTAssertEqual(initial.pendingICloudFiles, 0)
        XCTAssertEqual(TokenSummary.aggregate(initial.bucketsBySource[.claudeCode] ?? []).totalTokens, 4200)

        // Step 2: Append another 1,800 tokens and simulate macOS evicting the updated file.
        let line2 = claudeLine(id: "m2", timestamp: "2026-11-26T11:00:00Z", model: "claude-opus-4.5", input: 1500, output: 300, cacheRead: 0)
        try (line1 + line2).write(to: logURL, atomically: false, encoding: .utf8)
        fileAccess.setEvicted(true, for: logURL)
        fileAccess.setMtimeOverride(anchor.addingTimeInterval(-60), for: logURL)

        let discovered = await coordinator.refreshLocalPass(enabledSources: [.claudeCode], calendar: utcCalendar)
        XCTAssertEqual(discovered.pendingICloudFiles, 1)
        XCTAssertEqual(TokenSummary.aggregate(discovered.bucketsBySource[.claudeCode] ?? []).totalTokens, 4200, "Prior cached buckets remain available while evicted update is pending")

        // Step 3: Inject transient EACCES on metadata read during background pass.
        fileAccess.setMetadataError(.EACCES, for: logURL)
        let afterEACCES = await coordinator.runBackgroundMaterializationPass(enabledSources: [.claudeCode], calendar: utcCalendar)
        XCTAssertEqual(afterEACCES.pendingICloudFiles, 1, "Transient EACCES must keep file pending instead of treating it as removed")
        XCTAssertEqual(TokenSummary.aggregate(afterEACCES.bucketsBySource[.claudeCode] ?? []).totalTokens, 4200, "Transient EACCES must preserve existing cached usage")

        // Immediate retry before backoff expires must not run yet (even if error cleared).
        fileAccess.setMetadataError(nil, for: logURL)
        let duringBackoff = await coordinator.runBackgroundMaterializationPass(enabledSources: [.claudeCode], calendar: utcCalendar)
        XCTAssertEqual(duringBackoff.pendingICloudFiles, 1, "Transient metadata failure must schedule retry backoff")
        XCTAssertEqual(fileAccess.openCount(for: logURL), 1, "Only the initial local scan opened the file so far")

        // Step 4: Inject transient EIO after advancing clock past backoff -> still preserves cache and stays pending.
        clock.advance(by: 31.0)
        fileAccess.setMetadataError(.EIO, for: logURL)
        let afterEIO = await coordinator.runBackgroundMaterializationPass(enabledSources: [.claudeCode], calendar: utcCalendar)
        XCTAssertEqual(afterEIO.pendingICloudFiles, 1, "Transient EIO must keep file pending")
        XCTAssertEqual(TokenSummary.aggregate(afterEIO.bucketsBySource[.claudeCode] ?? []).totalTokens, 4200, "Transient EIO must preserve existing cached usage")

        // Step 5: Clear error, advance past second backoff (60s) -> materializes and counts full 6,000 tokens.
        fileAccess.setMetadataError(nil, for: logURL)
        clock.advance(by: 61.0)
        let recovered = await coordinator.runBackgroundMaterializationPass(enabledSources: [.claudeCode], calendar: utcCalendar)
        XCTAssertEqual(recovered.pendingICloudFiles, 0)
        XCTAssertEqual(TokenSummary.aggregate(recovered.bucketsBySource[.claudeCode] ?? []).totalTokens, 6000)

        // Step 6: Confirmed disappearance (ENOENT) removes entry cleanly.
        try (line1 + line2 + line2).write(to: logURL, atomically: false, encoding: .utf8)
        fileAccess.setEvicted(true, for: logURL)
        fileAccess.setMtimeOverride(anchor.addingTimeInterval(-10), for: logURL)
        let queuedBeforeDelete = await coordinator.refreshLocalPass(enabledSources: [.claudeCode], calendar: utcCalendar)
        XCTAssertEqual(queuedBeforeDelete.pendingICloudFiles, 1)

        try FileManager.default.removeItem(at: logURL)
        let afterDelete = await coordinator.runBackgroundMaterializationPass(enabledSources: [.claudeCode], calendar: utcCalendar)
        XCTAssertEqual(afterDelete.pendingICloudFiles, 0)
        XCTAssertEqual(TokenSummary.aggregate(afterDelete.bucketsBySource[.claudeCode] ?? []).totalTokens, 0, "Confirmed disappearance must remove cached entry")
    }

    // MARK: - 12. Round 3 Defect 1: Ordinary refresh retains pending file & backoff across transient metadata errors

    func testLocalRefreshRetainsPendingFileAndRetryBackoffDuringTransientMetadataError() async throws {
        let root = try makeTempDir(prefix: "evicted-refresh-retains-backoff")
        let projDir = root.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)

        let anchor = LogTimestampParser.parseISO8601("2026-11-26T18:00:00Z")!
        let clock = MutableClock(anchor)
        let logURL = projDir.appendingPathComponent("session.jsonl")
        try claudeLine(id: "r1", timestamp: "2026-11-26T10:00:00Z", model: "claude-opus-4.5", input: 1000, output: 200, cacheRead: 3000)
            .write(to: logURL, atomically: false, encoding: .utf8)

        let fileAccess = SimulatedICloudFileAccess(
            evictedURLs: [logURL],
            mtimeOverrides: [logURL: anchor.addingTimeInterval(-60)]
        )
        let source = ClaudeCodeTokenLogSource(rootDirectory: root, fileAccess: fileAccess)
        let coordinator = LocalTokenLogCoordinator(
            sources: [source],
            cacheStore: TokenLogCacheStore(fileURL: root.appendingPathComponent("cache.json")),
            backoffPolicy: EvictedRetryBackoffPolicy(baseDelay: 30.0, maxDelay: 300.0),
            clock: { clock.now() }
        )

        // 1. Discover evicted file.
        let initial = await coordinator.refreshLocalPass(enabledSources: [.claudeCode], calendar: utcCalendar)
        XCTAssertEqual(initial.pendingICloudFiles, 1)

        // 2. Background pass hits EIO -> pending stays 1 with 30s backoff.
        fileAccess.setMetadataError(.EIO, for: logURL)
        let afterBgEIO = await coordinator.runBackgroundMaterializationPass(enabledSources: [.claudeCode], calendar: utcCalendar)
        XCTAssertEqual(afterBgEIO.pendingICloudFiles, 1)

        // 3. Ordinary local refresh during the same EIO error MUST retain pending == 1 AND backoff!
        let duringLocalEIO = await coordinator.refreshLocalPass(enabledSources: [.claudeCode], calendar: utcCalendar)
        XCTAssertEqual(duringLocalEIO.pendingICloudFiles, 1, "Local refresh during transient EIO must retain pending file")

        // 4. Clear EIO and run another local refresh + background pass STILL inside the 30s backoff window.
        fileAccess.setMetadataError(nil, for: logURL)
        let afterClearLocal = await coordinator.refreshLocalPass(enabledSources: [.claudeCode], calendar: utcCalendar)
        XCTAssertEqual(afterClearLocal.pendingICloudFiles, 1)

        clock.advance(by: 10.0) // Still inside 30s backoff
        let insideBackoff = await coordinator.runBackgroundMaterializationPass(enabledSources: [.claudeCode], calendar: utcCalendar)
        XCTAssertEqual(insideBackoff.pendingICloudFiles, 1, "Retry deadline must survive inconclusive local refresh")
        XCTAssertEqual(fileAccess.openCount(for: logURL), 0, "Cleared error must not trigger immediate retry inside backoff")

        // 5. Advance past 30s backoff -> background pass materializes and counts it.
        clock.advance(by: 25.0)
        let recovered = await coordinator.runBackgroundMaterializationPass(enabledSources: [.claudeCode], calendar: utcCalendar)
        XCTAssertEqual(recovered.pendingICloudFiles, 0)
        XCTAssertEqual(fileAccess.openCount(for: logURL), 1)
        XCTAssertEqual(TokenSummary.aggregate(recovered.bucketsBySource[.claudeCode] ?? []).totalTokens, 4200)

        // 6. Confirmed deletion removes pending file cleanly during local refresh.
        try claudeLine(id: "r2", timestamp: "2026-11-26T11:00:00Z", model: "claude-opus-4.5", input: 500, output: 100, cacheRead: 0)
            .write(to: logURL, atomically: false, encoding: .utf8)
        fileAccess.setEvicted(true, for: logURL)
        fileAccess.setMtimeOverride(anchor.addingTimeInterval(-30), for: logURL)
        let pendingAgain = await coordinator.refreshLocalPass(enabledSources: [.claudeCode], calendar: utcCalendar)
        XCTAssertEqual(pendingAgain.pendingICloudFiles, 1)

        try FileManager.default.removeItem(at: logURL)
        let afterDeleteLocal = await coordinator.refreshLocalPass(enabledSources: [.claudeCode], calendar: utcCalendar)
        XCTAssertEqual(afterDeleteLocal.pendingICloudFiles, 0, "Confirmed deletion must remove pending entry on local refresh")
    }

    // MARK: - 13. Round 3 Defect 2: OpenCode background pass matches fresh scan deterministic message-ID precedence

    func testOpenCodeBackgroundPassMatchesFreshScanMessageIDPrecedenceRegardlessOfDownloadOrder() async throws {
        let root = try makeTempDir(prefix: "evicted-opencode-precedence")
        let legacyDir = root.appendingPathComponent("storage/message/ses1", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)

        let anchor = LogTimestampParser.parseISO8601("2026-11-26T18:00:00Z")!
        let fileA = legacyDir.appendingPathComponent("a_first.json")
        let fileB = legacyDir.appendingPathComponent("b_second.json")

        // Same message ID "msg_dup" in both legacy files: alphabetically first has 120 tokens, second has 400 tokens.
        try openCodeLegacyJSON(id: "msg_dup", completedMs: 1795615200000, model: "kimi-k2", input: 100, output: 20, cacheRead: 0)
            .write(to: fileA, atomically: true, encoding: .utf8)
        try openCodeLegacyJSON(id: "msg_dup", completedMs: 1795615200000, model: "kimi-k2", input: 300, output: 100, cacheRead: 0)
            .write(to: fileB, atomically: true, encoding: .utf8)

        // Fresh scan baseline: alphabetically first file (a_first.json) wins -> 120 tokens.
        var freshState = SourceCacheState()
        let freshBuckets = try OpenCodeTokenLogSource(rootDirectory: root).refresh(state: &freshState, calendar: utcCalendar)
        XCTAssertEqual(TokenSummary.aggregate(freshBuckets).totalTokens, 120)

        // Case 1: a_first.json is evicted while b_second.json is already local.
        let access1 = SimulatedICloudFileAccess(
            evictedURLs: [fileA],
            mtimeOverrides: [fileA: anchor.addingTimeInterval(-60)]
        )
        let coord1 = LocalTokenLogCoordinator(
            sources: [OpenCodeTokenLogSource(rootDirectory: root, fileAccess: access1)],
            cacheStore: TokenLogCacheStore(fileURL: root.appendingPathComponent("cache1.json")),
            clock: { anchor }
        )

        let local1 = await coord1.refreshLocalPass(enabledSources: [.openCode], calendar: utcCalendar, now: anchor)
        XCTAssertEqual(local1.pendingICloudFiles, 1)
        XCTAssertEqual(TokenSummary.aggregate(local1.bucketsBySource[.openCode] ?? []).totalTokens, 400)

        let afterBg1 = await coord1.runBackgroundMaterializationPass(enabledSources: [.openCode], calendar: utcCalendar)
        XCTAssertEqual(afterBg1.pendingICloudFiles, 0)
        XCTAssertEqual(
            afterBg1.bucketsBySource[.openCode],
            freshBuckets,
            "OpenCode background pass must match fresh scan precedence (120 tokens) when earlier file materializes later"
        )

        // Case 2: Both files are evicted, with b_second.json newer so b_second.json downloads BEFORE a_first.json.
        let access2 = SimulatedICloudFileAccess(
            evictedURLs: [fileA, fileB],
            mtimeOverrides: [
                fileB: anchor.addingTimeInterval(-30),  // newer -> materialized first
                fileA: anchor.addingTimeInterval(-120)  // older -> materialized second
            ]
        )
        let coord2 = LocalTokenLogCoordinator(
            sources: [OpenCodeTokenLogSource(rootDirectory: root, fileAccess: access2)],
            cacheStore: TokenLogCacheStore(fileURL: root.appendingPathComponent("cache2.json")),
            clock: { anchor }
        )

        let local2 = await coord2.refreshLocalPass(enabledSources: [.openCode], calendar: utcCalendar, now: anchor)
        XCTAssertEqual(local2.pendingICloudFiles, 2)
        let afterBg2 = await coord2.runBackgroundMaterializationPass(enabledSources: [.openCode], calendar: utcCalendar)
        XCTAssertEqual(afterBg2.pendingICloudFiles, 0)
        XCTAssertEqual(
            afterBg2.bucketsBySource[.openCode],
            freshBuckets,
            "OpenCode buckets must be identical regardless of background download order"
        )
    }

    // MARK: - 14. Round 3 Defect 3: Recent local WAL must not trigger download of an evicted DB older than 31 days

    func testRecentLocalWALDoesNotTriggerDownloadOfEvictedDatabaseOlderThan31Days() async throws {
        let root = try makeTempDir(prefix: "evicted-opencode-wal-cutoff")
        let anchor = LogTimestampParser.parseISO8601("2026-11-26T18:00:00Z")!

        let dbURL = root.appendingPathComponent("opencode.db")
        let walURL = root.appendingPathComponent("opencode.db-wal")

        // Create a real SQLite DB in WAL mode with a recent local WAL file.
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { if let db { sqlite3_close(db) } }
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(
                db,
                "CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);",
                nil, nil, nil
            ),
            SQLITE_OK
        )
        let payload = openCodeLegacyJSON(id: "msg_sql_1", completedMs: 1795615200000, model: "kimi-k2", input: 500, output: 100, cacheRead: 0)
        let escapedPayload = payload.replacingOccurrences(of: "'", with: "''")
        XCTAssertEqual(
            sqlite3_exec(
                db,
                "INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES ('msg_sql_1', 's1', 1795615200000, 1795615200000, '\(escapedPayload)');",
                nil, nil, nil
            ),
            SQLITE_OK
        )
        // Ensure WAL file exists on disk.
        if !FileManager.default.fileExists(atPath: walURL.path) {
            try Data([0x01, 0x02]).write(to: walURL)
        }

        // Pair a 60-day-old evicted opencode.db with a current (1-minute-old) local WAL.
        let fileAccess = SimulatedICloudFileAccess(
            evictedURLs: [dbURL],
            mtimeOverrides: [
                dbURL: anchor.addingTimeInterval(-60 * 86_400),
                walURL: anchor.addingTimeInterval(-60)
            ]
        )

        let source = OpenCodeTokenLogSource(rootDirectory: root, fileAccess: fileAccess)
        let coordinator = LocalTokenLogCoordinator(
            sources: [source],
            cacheStore: TokenLogCacheStore(fileURL: root.appendingPathComponent("cache.json")),
            clock: { anchor }
        )

        let local = await coordinator.refreshLocalPass(enabledSources: [.openCode], calendar: utcCalendar, now: anchor)
        XCTAssertEqual(local.pendingICloudFiles, 0, "60-day-old evicted DB must not be queued just because local WAL is recent")
        let afterBg = await coordinator.runBackgroundMaterializationPass(enabledSources: [.openCode], calendar: utcCalendar)
        XCTAssertEqual(afterBg.pendingICloudFiles, 0)
        XCTAssertEqual(fileAccess.openCount(for: dbURL), 0, "60-day-old evicted opencode.db must record zero download/open attempts")

        // Direct scanEvictedFile probe must also reject without opening the old evicted DB.
        let dbMeta = try XCTUnwrap(fileAccess.readMetadataOrThrow(at: dbURL))
        let walMeta = try fileAccess.readMetadataOrThrow(at: walURL)
        var state = SourceCacheState()
        let directOutcome = source.scanEvictedFile(
            PendingEvictedLogFile(
                toolSource: .openCode,
                url: dbURL,
                relativePath: "opencode.db",
                cacheKey: "__sqlite__/opencode.db",
                metadata: dbMeta,
                secondaryMetadata: walMeta
            ),
            state: &state,
            calendar: utcCalendar,
            now: anchor
        )
        XCTAssertEqual(directOutcome, .skippedTooOld)
        XCTAssertEqual(fileAccess.openCount(for: dbURL), 0, "Direct scanEvictedFile must also record zero downloads for old evicted DB")
    }

    private func waitForBackgroundSlotIdle(timeout: TimeInterval = 2.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while BoundedBackgroundWork.isSlotOccupied && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        try? await Task.sleep(nanoseconds: 25_000_000)
    }

    // MARK: - 15. Round 4 Defect 1: Late success after timeout populates cache without a second parse

    func testLateSuccessAfterTimeoutPopulatesCacheWithoutSecondParseAcrossAllSources() async throws {
        let anchor = LogTimestampParser.parseISO8601("2026-11-26T18:00:00Z")!

        final class CounterBox: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func increment() {
                lock.lock()
                value += 1
                lock.unlock()
            }
            var count: Int {
                lock.lock()
                defer { lock.unlock() }
                return value
            }
        }

        // 1. Claude: 40 ms deadline + 200 ms simulated download -> line callback runs ONCE (not twice).
        do {
            let root = try makeTempDir(prefix: "evicted-late-claude")
            let projDir = root.appendingPathComponent("proj", isDirectory: true)
            try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)
            let logURL = projDir.appendingPathComponent("slow.jsonl")
            try claudeLine(id: "late_c1", timestamp: "2026-11-26T12:00:00Z", model: "claude-opus-4.5", input: 3000, output: 500, cacheRead: 1500)
                .write(to: logURL, atomically: true, encoding: .utf8)

            let fileAccess = SimulatedICloudFileAccess(
                evictedURLs: [logURL],
                mtimeOverrides: [logURL: anchor.addingTimeInterval(-60)],
                behaviors: [logURL: [.delayAndSucceed(0.20)]]
            )
            let linesScanned = CounterBox()
            let source = ClaudeCodeTokenLogSource(
                rootDirectory: root,
                fileAccess: fileAccess
            ) { _, _, _ in
                linesScanned.increment()
            }
            let cacheURL = root.appendingPathComponent("cache.json")
            let coordinator = LocalTokenLogCoordinator(
                sources: [source],
                cacheStore: TokenLogCacheStore(fileURL: cacheURL),
                perFileTimeout: 0.04,
                clock: { anchor }
            )

            let local1 = await coordinator.refreshLocalPass(enabledSources: [.claudeCode], calendar: utcCalendar, now: anchor)
            XCTAssertEqual(local1.pendingICloudFiles, 1)
            XCTAssertEqual(linesScanned.count, 0)

            let progressLatestPending = CounterBox()
            let bgStart = Date()
            let afterTimeout = await coordinator.runBackgroundMaterializationPass(
                enabledSources: [.claudeCode],
                calendar: utcCalendar,
                onProgress: { snapshot in
                    if snapshot.pendingICloudFiles == 0 {
                        progressLatestPending.increment()
                    }
                }
            )
            let bgElapsed = Date().timeIntervalSince(bgStart)
            XCTAssertLessThan(bgElapsed, 0.16, "Caller must return promptly on 40 ms timeout")
            XCTAssertEqual(afterTimeout.pendingICloudFiles, 1, "Timed-out file stays pending immediately after timeout")
            XCTAssertEqual(TokenSummary.aggregate(afterTimeout.bucketsBySource[.claudeCode] ?? []).totalTokens, 0)

            // Wait for the 200 ms simulated download + scan to finish in the background.
            await waitForBackgroundSlotIdle()

            // Next local refresh must reuse the late-populated cache WITHOUT parsing the line a second time.
            let local2 = await coordinator.refreshLocalPass(enabledSources: [.claudeCode], calendar: utcCalendar, now: anchor)
            XCTAssertEqual(local2.pendingICloudFiles, 0)
            XCTAssertEqual(TokenSummary.aggregate(local2.bucketsBySource[.claudeCode] ?? []).totalTokens, 5000)
            XCTAssertEqual(linesScanned.count, 1, "Claude line must be parsed exactly once even after a late timeout completion")
            XCTAssertGreaterThanOrEqual(progressLatestPending.count, 1, "Late completion should notify progress when pending reaches 0")

            // If macOS re-evicts the file immediately afterward, zero additional opens or parses occur.
            fileAccess.setEvicted(true, for: logURL)
            let opensBeforeReevict = fileAccess.openCount(for: logURL)
            let local3 = await coordinator.refreshLocalPass(enabledSources: [.claudeCode], calendar: utcCalendar, now: anchor)
            XCTAssertEqual(local3.pendingICloudFiles, 0)
            XCTAssertEqual(fileAccess.openCount(for: logURL), opensBeforeReevict)
            XCTAssertEqual(linesScanned.count, 1)
        }

        // 2. Codex: 40 ms deadline + 200 ms simulated download -> line callback runs ONCE per line (2 lines total, not 4).
        do {
            let root = try makeTempDir(prefix: "evicted-late-codex")
            let dayDir = root.appendingPathComponent("2026/11", isDirectory: true)
            try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
            let logURL = dayDir.appendingPathComponent("rollout-slow.jsonl")
            try codexLines(timestamp: "2026-11-26T12:00:00Z", model: "gpt-5-codex", input: 6000, cached: 2000, output: 400)
                .write(to: logURL, atomically: true, encoding: .utf8)

            let fileAccess = SimulatedICloudFileAccess(
                evictedURLs: [logURL],
                mtimeOverrides: [logURL: anchor.addingTimeInterval(-60)],
                behaviors: [logURL: [.delayAndSucceed(0.20)]]
            )
            let linesScanned = CounterBox()
            let source = CodexCLITokenLogSource(
                rootDirectory: root,
                fileAccess: fileAccess
            ) { _, _, _ in
                linesScanned.increment()
            }
            let coordinator = LocalTokenLogCoordinator(
                sources: [source],
                cacheStore: TokenLogCacheStore(fileURL: root.appendingPathComponent("cache.json")),
                perFileTimeout: 0.04,
                clock: { anchor }
            )

            let local1 = await coordinator.refreshLocalPass(enabledSources: [.codexCLI], calendar: utcCalendar, now: anchor)
            XCTAssertEqual(local1.pendingICloudFiles, 1)

            let afterTimeout = await coordinator.runBackgroundMaterializationPass(enabledSources: [.codexCLI], calendar: utcCalendar)
            XCTAssertEqual(afterTimeout.pendingICloudFiles, 1)

            await waitForBackgroundSlotIdle()

            let local2 = await coordinator.refreshLocalPass(enabledSources: [.codexCLI], calendar: utcCalendar, now: anchor)
            XCTAssertEqual(local2.pendingICloudFiles, 0)
            XCTAssertEqual(TokenSummary.aggregate(local2.bucketsBySource[.codexCLI] ?? []).totalTokens, 6400)
            XCTAssertEqual(linesScanned.count, 2, "Codex rollout lines must be scanned once (2 lines), not twice (4 lines)")
        }

        // 3. Gemini: 40 ms deadline + 200 ms simulated download -> message callback runs ONCE.
        do {
            let root = try makeTempDir(prefix: "evicted-late-gemini")
            let chatsDir = root.appendingPathComponent("hash/chats", isDirectory: true)
            try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)
            let sessionURL = chatsDir.appendingPathComponent("session-slow.json")
            try geminiSessionJSON(id: "late_g1", timestamp: "2026-11-26T12:00:00Z", model: "gemini-3-pro", input: 4000, cached: 1000, output: 300)
                .write(to: sessionURL, atomically: true, encoding: .utf8)

            let fileAccess = SimulatedICloudFileAccess(
                evictedURLs: [sessionURL],
                mtimeOverrides: [sessionURL: anchor.addingTimeInterval(-60)],
                behaviors: [sessionURL: [.delayAndSucceed(0.20)]]
            )
            let messagesScanned = CounterBox()
            let source = GeminiCLITokenLogSource(
                rootDirectory: root,
                fileAccess: fileAccess
            ) { _, _, _ in
                messagesScanned.increment()
            }
            let coordinator = LocalTokenLogCoordinator(
                sources: [source],
                cacheStore: TokenLogCacheStore(fileURL: root.appendingPathComponent("cache.json")),
                perFileTimeout: 0.04,
                clock: { anchor }
            )

            let local1 = await coordinator.refreshLocalPass(enabledSources: [.geminiCLI], calendar: utcCalendar, now: anchor)
            XCTAssertEqual(local1.pendingICloudFiles, 1)

            let afterTimeout = await coordinator.runBackgroundMaterializationPass(enabledSources: [.geminiCLI], calendar: utcCalendar)
            XCTAssertEqual(afterTimeout.pendingICloudFiles, 1)

            await waitForBackgroundSlotIdle()

            let local2 = await coordinator.refreshLocalPass(enabledSources: [.geminiCLI], calendar: utcCalendar, now: anchor)
            XCTAssertEqual(local2.pendingICloudFiles, 0)
            XCTAssertEqual(TokenSummary.aggregate(local2.bucketsBySource[.geminiCLI] ?? []).totalTokens, 4300)
            XCTAssertEqual(messagesScanned.count, 1, "Gemini session message must be parsed exactly once")
        }

        // 4. OpenCode legacy JSON: 40 ms deadline + 200 ms simulated download -> legacy read callback runs ONCE.
        do {
            let root = try makeTempDir(prefix: "evicted-late-opencode")
            let legacyDir = root.appendingPathComponent("storage/message/ses1", isDirectory: true)
            try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
            let msgURL = legacyDir.appendingPathComponent("msg_slow.json")
            try openCodeLegacyJSON(id: "msg_slow", completedMs: 1795615200000, model: "kimi-k2", input: 2000, output: 400, cacheRead: 600)
                .write(to: msgURL, atomically: true, encoding: .utf8)

            let fileAccess = SimulatedICloudFileAccess(
                evictedURLs: [msgURL],
                mtimeOverrides: [msgURL: anchor.addingTimeInterval(-60)],
                behaviors: [msgURL: [.delayAndSucceed(0.20)]]
            )
            let legacyReads = CounterBox()
            let source = OpenCodeTokenLogSource(
                rootDirectory: root,
                fileAccess: fileAccess
            ) { _, _ in
                legacyReads.increment()
            }
            let coordinator = LocalTokenLogCoordinator(
                sources: [source],
                cacheStore: TokenLogCacheStore(fileURL: root.appendingPathComponent("cache.json")),
                perFileTimeout: 0.04,
                clock: { anchor }
            )

            let local1 = await coordinator.refreshLocalPass(enabledSources: [.openCode], calendar: utcCalendar, now: anchor)
            XCTAssertEqual(local1.pendingICloudFiles, 1)

            let afterTimeout = await coordinator.runBackgroundMaterializationPass(enabledSources: [.openCode], calendar: utcCalendar)
            XCTAssertEqual(afterTimeout.pendingICloudFiles, 1)

            await waitForBackgroundSlotIdle()

            let local2 = await coordinator.refreshLocalPass(enabledSources: [.openCode], calendar: utcCalendar, now: anchor)
            XCTAssertEqual(local2.pendingICloudFiles, 0)
            XCTAssertEqual(TokenSummary.aggregate(local2.bucketsBySource[.openCode] ?? []).totalTokens, 3000)
            XCTAssertEqual(legacyReads.count, 1, "OpenCode legacy JSON must be parsed exactly once")
        }

        // 5. Late completion must NOT overwrite a newer replacement version written while timed-out worker ran.
        do {
            let root = try makeTempDir(prefix: "evicted-late-stale-version")
            let projDir = root.appendingPathComponent("proj", isDirectory: true)
            try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)
            let logURL = projDir.appendingPathComponent("rotating.jsonl")
            try claudeLine(id: "old_v1", timestamp: "2026-11-26T10:00:00Z", model: "claude-opus-4.5", input: 1000, output: 100, cacheRead: 0)
                .write(to: logURL, atomically: false, encoding: .utf8)

            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            defer { release.signal() }

            let fileAccess = SimulatedICloudFileAccess(
                evictedURLs: [logURL],
                mtimeOverrides: [logURL: anchor.addingTimeInterval(-60)],
                behaviors: [logURL: [.signalAndBlock(entered: entered, release: release)]]
            )
            let source = ClaudeCodeTokenLogSource(rootDirectory: root, fileAccess: fileAccess)
            let coordinator = LocalTokenLogCoordinator(
                sources: [source],
                cacheStore: TokenLogCacheStore(fileURL: root.appendingPathComponent("cache.json")),
                perFileTimeout: 0.04,
                clock: { anchor }
            )

            let local1 = await coordinator.refreshLocalPass(enabledSources: [.claudeCode], calendar: utcCalendar, now: anchor)
            XCTAssertEqual(local1.pendingICloudFiles, 1)

            let afterTimeout = await coordinator.runBackgroundMaterializationPass(enabledSources: [.claudeCode], calendar: utcCalendar)
            XCTAssertEqual(entered.wait(timeout: .now() + 2.0), .success)
            XCTAssertEqual(afterTimeout.pendingICloudFiles, 1)

            // Replace with a newer local file (8,500 tokens) and refresh locally BEFORE releasing the timed-out worker.
            let tempURL = projDir.appendingPathComponent("rotating.tmp")
            try claudeLine(id: "new_v2", timestamp: "2026-11-26T11:00:00Z", model: "claude-sonnet-4.5", input: 8000, output: 500, cacheRead: 0)
                .write(to: tempURL, atomically: false, encoding: .utf8)
            _ = try FileManager.default.replaceItemAt(logURL, withItemAt: tempURL)
            fileAccess.setEvicted(false, for: logURL)
            fileAccess.setMtimeOverride(anchor.addingTimeInterval(-10), for: logURL)

            let afterLocalV2 = await coordinator.refreshLocalPass(enabledSources: [.claudeCode], calendar: utcCalendar, now: anchor)
            XCTAssertEqual(afterLocalV2.pendingICloudFiles, 0)
            XCTAssertEqual(TokenSummary.aggregate(afterLocalV2.bucketsBySource[.claudeCode] ?? []).totalTokens, 8500)

            // Release the old timed-out worker; it must NOT clobber v2.
            release.signal()
            await waitForBackgroundSlotIdle()

            let finalLocal = await coordinator.refreshLocalPass(enabledSources: [.claudeCode], calendar: utcCalendar, now: anchor)
            XCTAssertEqual(finalLocal.pendingICloudFiles, 0)
            XCTAssertEqual(TokenSummary.aggregate(finalLocal.bucketsBySource[.claudeCode] ?? []).totalTokens, 8500)
        }

        // 6. Concurrent local refresh while timed-out worker is mid-parse (already local on disk)
        //    must skip the in-flight version and NOT parse it a second time.
        do {
            let root = try makeTempDir(prefix: "evicted-late-midparse-local-refresh")
            let projDir = root.appendingPathComponent("proj", isDirectory: true)
            try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)
            let logURL = projDir.appendingPathComponent("midparse.jsonl")
            try claudeLine(id: "mp1", timestamp: "2026-11-26T12:00:00Z", model: "claude-opus-4.5", input: 2000, output: 300, cacheRead: 700)
                .write(to: logURL, atomically: true, encoding: .utf8)

            let enteredParse = DispatchSemaphore(value: 0)
            let releaseParse = DispatchSemaphore(value: 0)
            defer { releaseParse.signal() }

            let fileAccess = SimulatedICloudFileAccess(
                evictedURLs: [logURL],
                mtimeOverrides: [logURL: anchor.addingTimeInterval(-60)],
                behaviors: [logURL: [.succeed]]
            )
            let linesScanned = CounterBox()
            let source = ClaudeCodeTokenLogSource(
                rootDirectory: root,
                fileAccess: fileAccess
            ) { _, _, _ in
                linesScanned.increment()
                enteredParse.signal()
                releaseParse.wait()
            }
            let coordinator = LocalTokenLogCoordinator(
                sources: [source],
                cacheStore: TokenLogCacheStore(fileURL: root.appendingPathComponent("cache.json")),
                perFileTimeout: 0.04,
                clock: { anchor }
            )

            let local1 = await coordinator.refreshLocalPass(enabledSources: [.claudeCode], calendar: utcCalendar, now: anchor)
            XCTAssertEqual(local1.pendingICloudFiles, 1)

            // Worker materializes file (now local!) and blocks inside line parser past 40 ms timeout.
            let afterTimeout = await coordinator.runBackgroundMaterializationPass(enabledSources: [.claudeCode], calendar: utcCalendar)
            XCTAssertEqual(enteredParse.wait(timeout: .now() + 2.0), .success)
            XCTAssertEqual(afterTimeout.pendingICloudFiles, 1)

            // Run refreshLocalPass while file is ALREADY local on disk and worker is mid-parse:
            // must NOT scan it a second time and must keep it pending until the worker finishes.
            let duringParse = await coordinator.refreshLocalPass(enabledSources: [.claudeCode], calendar: utcCalendar, now: anchor)
            XCTAssertEqual(duringParse.pendingICloudFiles, 1)
            XCTAssertEqual(linesScanned.count, 1, "Concurrent local refresh must skip in-flight version instead of double-parsing")

            // Let worker finish -> late completion populates cache; next refresh sees 0 pending and still 1 parse total.
            releaseParse.signal()
            await waitForBackgroundSlotIdle()

            let afterFinish = await coordinator.refreshLocalPass(enabledSources: [.claudeCode], calendar: utcCalendar, now: anchor)
            XCTAssertEqual(afterFinish.pendingICloudFiles, 0)
            XCTAssertEqual(TokenSummary.aggregate(afterFinish.bucketsBySource[.claudeCode] ?? []).totalTokens, 3000)
            XCTAssertEqual(linesScanned.count, 1)
        }
    }

    // MARK: - 16. Round 4 Defect 2: Incomplete final record does not repeat download after re-eviction

    func testIncompleteFinalRecordDoesNotRepeatDownloadAfterReEvictionAndResumesOnChange() async throws {
        let anchor = LogTimestampParser.parseISO8601("2026-11-26T18:00:00Z")!

        final class LineRecordBox: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func increment() {
                lock.lock()
                count += 1
                lock.unlock()
            }
            var value: Int {
                lock.lock()
                defer { lock.unlock() }
                return count
            }
        }

        // 1. Claude: 1 complete line + partial final line -> re-evicted unchanged -> 0 repeat downloads;
        //    later completed -> resumes from retained offset without re-parsing line 1.
        do {
            let root = try makeTempDir(prefix: "evicted-partial-claude")
            let projDir = root.appendingPathComponent("proj", isDirectory: true)
            try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)
            let logURL = projDir.appendingPathComponent("partial.jsonl")

            let line1 = claudeLine(id: "p1", timestamp: "2026-11-26T10:00:00Z", model: "claude-opus-4.5", input: 1000, output: 200, cacheRead: 300)
            let partialLine2Prefix = #"{"type":"assistant","requestId":"req_p2","timestamp":"2026-11-26T11:00:00Z","message":{"id":"msg_p2","model":"claude-sonnet-4.5","usage":{"input_tokens":4000,"#
            let partialLine2Suffix = "\"output_tokens\":500,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":500}}}\n"
            try (line1 + partialLine2Prefix).write(to: logURL, atomically: false, encoding: .utf8)

            let fileAccess = SimulatedICloudFileAccess(
                evictedURLs: [logURL],
                mtimeOverrides: [logURL: anchor.addingTimeInterval(-120)]
            )
            let linesScanned = LineRecordBox()
            let source = ClaudeCodeTokenLogSource(
                rootDirectory: root,
                fileAccess: fileAccess
            ) { _, _, _ in
                linesScanned.increment()
            }
            let cacheURL = root.appendingPathComponent("cache.json")
            let cacheStore = TokenLogCacheStore(fileURL: cacheURL)
            let coordinator = LocalTokenLogCoordinator(
                sources: [source],
                cacheStore: cacheStore,
                clock: { anchor }
            )

            // Discover evicted file and materialize it once.
            let local1 = await coordinator.refreshLocalPass(enabledSources: [.claudeCode], calendar: utcCalendar, now: anchor)
            XCTAssertEqual(local1.pendingICloudFiles, 1)
            XCTAssertEqual(fileAccess.openCount(for: logURL), 0)

            let bg1 = await coordinator.runBackgroundMaterializationPass(enabledSources: [.claudeCode], calendar: utcCalendar)
            XCTAssertEqual(bg1.pendingICloudFiles, 0)
            XCTAssertEqual(fileAccess.openCount(for: logURL), 1)
            XCTAssertEqual(TokenSummary.aggregate(bg1.bucketsBySource[.claudeCode] ?? []).totalTokens, 1500)
            XCTAssertEqual(linesScanned.value, 2, "Initial scan reads line 1 + inspects incomplete trailing line 2")

            // Verify retained offset stays before the incomplete final line while eofFingerprint was saved.
            let cachedDoc = cacheStore.load(expectedTimeZone: utcCalendar.timeZone)
            let entry = try XCTUnwrap(cachedDoc.state(for: .claudeCode).files["proj/partial.jsonl"])
            XCTAssertEqual(entry.offset, UInt64(line1.utf8.count), "Offset must remain before the incomplete final record")
            XCTAssertEqual(entry.fileSize, UInt64((line1 + partialLine2Prefix).utf8.count))
            XCTAssertNotNil(entry.eofFingerprint)

            // Re-evict the exact same version (unchanged identity, size, mtime): MUST NOT queue or download again!
            fileAccess.setEvicted(true, for: logURL)
            let localReevicted = await coordinator.refreshLocalPass(enabledSources: [.claudeCode], calendar: utcCalendar, now: anchor)
            XCTAssertEqual(localReevicted.pendingICloudFiles, 0, "Unchanged re-evicted file with partial final line must NOT be re-queued")
            XCTAssertEqual(fileAccess.openCount(for: logURL), 1, "Unchanged re-evicted file must NOT be downloaded a second time")
            XCTAssertEqual(TokenSummary.aggregate(localReevicted.bucketsBySource[.claudeCode] ?? []).totalTokens, 1500)

            // Also verify local refresh of the unchanged file does NOT re-parse the incomplete trailing line.
            fileAccess.setEvicted(false, for: logURL)
            let localUnchanged = await coordinator.refreshLocalPass(enabledSources: [.claudeCode], calendar: utcCalendar, now: anchor)
            XCTAssertEqual(localUnchanged.pendingICloudFiles, 0)
            XCTAssertEqual(linesScanned.value, 2, "Unchanged local file with partial final line must not re-parse")

            // Complete the partial line on the same inode and mark evicted -> MUST queue, resume from line1 offset,
            // scan ONLY the newly completed line 2 (total linesScanned == 3, not 4!), and match a fresh scan.
            let fh = try FileHandle(forWritingTo: logURL)
            try fh.seekToEnd()
            try fh.write(contentsOf: Data(partialLine2Suffix.utf8))
            try fh.close()
            fileAccess.setEvicted(true, for: logURL)
            fileAccess.setMtimeOverride(anchor.addingTimeInterval(-30), for: logURL)

            let localUpdated = await coordinator.refreshLocalPass(enabledSources: [.claudeCode], calendar: utcCalendar, now: anchor)
            XCTAssertEqual(localUpdated.pendingICloudFiles, 1, "Changed file must be queued for materialization")
            let bg2 = await coordinator.runBackgroundMaterializationPass(enabledSources: [.claudeCode], calendar: utcCalendar)
            XCTAssertEqual(bg2.pendingICloudFiles, 0)
            XCTAssertEqual(TokenSummary.aggregate(bg2.bucketsBySource[.claudeCode] ?? []).totalTokens, 6500)
            XCTAssertEqual(linesScanned.value, 3, "Resuming from retained offset must parse only the newly completed line 2")

            var freshState = SourceCacheState()
            let freshBuckets = try ClaudeCodeTokenLogSource(rootDirectory: root).refresh(state: &freshState, calendar: utcCalendar)
            XCTAssertEqual(bg2.bucketsBySource[.claudeCode], freshBuckets)
        }

        // 2. Claude partial-only file (offset == 0 < fileSize): re-evicted unchanged -> 0 repeat downloads.
        do {
            let root = try makeTempDir(prefix: "evicted-partial-only-claude")
            let projDir = root.appendingPathComponent("proj", isDirectory: true)
            try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)
            let logURL = projDir.appendingPathComponent("only-partial.jsonl")

            let prefix = #"{"type":"assistant","requestId":"req_only","timestamp":"2026-11-26T10:00:00Z","message":{"id":"msg_only","model":"claude-opus-4.5","usage":{"input_tokens":700,"#
            let suffix = "\"output_tokens\":300,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}}\n"
            try prefix.write(to: logURL, atomically: false, encoding: .utf8)

            let fileAccess = SimulatedICloudFileAccess(
                evictedURLs: [logURL],
                mtimeOverrides: [logURL: anchor.addingTimeInterval(-120)]
            )
            let source = ClaudeCodeTokenLogSource(rootDirectory: root, fileAccess: fileAccess)
            let coordinator = LocalTokenLogCoordinator(
                sources: [source],
                cacheStore: TokenLogCacheStore(fileURL: root.appendingPathComponent("cache.json")),
                clock: { anchor }
            )

            _ = await coordinator.refreshLocalPass(enabledSources: [.claudeCode], calendar: utcCalendar, now: anchor)
            let bg1 = await coordinator.runBackgroundMaterializationPass(enabledSources: [.claudeCode], calendar: utcCalendar)
            XCTAssertEqual(bg1.pendingICloudFiles, 0)
            XCTAssertEqual(fileAccess.openCount(for: logURL), 1)
            XCTAssertEqual(TokenSummary.aggregate(bg1.bucketsBySource[.claudeCode] ?? []).totalTokens, 0)

            fileAccess.setEvicted(true, for: logURL)
            let reevicted = await coordinator.refreshLocalPass(enabledSources: [.claudeCode], calendar: utcCalendar, now: anchor)
            XCTAssertEqual(reevicted.pendingICloudFiles, 0)
            XCTAssertEqual(fileAccess.openCount(for: logURL), 1)

            // Finish writing the line -> counts 1,000 tokens.
            let fh = try FileHandle(forWritingTo: logURL)
            try fh.seekToEnd()
            try fh.write(contentsOf: Data(suffix.utf8))
            try fh.close()
            fileAccess.setMtimeOverride(anchor.addingTimeInterval(-30), for: logURL)

            _ = await coordinator.refreshLocalPass(enabledSources: [.claudeCode], calendar: utcCalendar, now: anchor)
            let bg2 = await coordinator.runBackgroundMaterializationPass(enabledSources: [.claudeCode], calendar: utcCalendar)
            XCTAssertEqual(bg2.pendingICloudFiles, 0)
            XCTAssertEqual(TokenSummary.aggregate(bg2.bucketsBySource[.claudeCode] ?? []).totalTokens, 1000)
        }

        // 3. Codex: complete rollout lines + incomplete final line -> re-evicted unchanged -> 0 repeat downloads;
        //    later completed -> resumes from retained offset and matches fresh scan.
        do {
            let root = try makeTempDir(prefix: "evicted-partial-codex")
            let dayDir = root.appendingPathComponent("2026/11", isDirectory: true)
            try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
            let logURL = dayDir.appendingPathComponent("rollout-partial.jsonl")

            let initial = codexLines(timestamp: "2026-11-26T10:00:00Z", model: "gpt-5-codex", input: 2000, cached: 500, output: 100)
            let partialLinePrefix = #"{"timestamp":"2026-11-26T10:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":5000,"#
            let partialLineSuffix = "\"cached_input_tokens\":1000,\"output_tokens\":300,\"reasoning_output_tokens\":0,\"total_tokens\":5300},\"last_token_usage\":{\"input_tokens\":3000,\"cached_input_tokens\":500,\"output_tokens\":200,\"reasoning_output_tokens\":0,\"total_tokens\":3200}}}}\n"
            try (initial + partialLinePrefix).write(to: logURL, atomically: false, encoding: .utf8)

            let fileAccess = SimulatedICloudFileAccess(
                evictedURLs: [logURL],
                mtimeOverrides: [logURL: anchor.addingTimeInterval(-120)]
            )
            let linesScanned = LineRecordBox()
            let source = CodexCLITokenLogSource(
                rootDirectory: root,
                fileAccess: fileAccess
            ) { _, _, _ in
                linesScanned.increment()
            }
            let coordinator = LocalTokenLogCoordinator(
                sources: [source],
                cacheStore: TokenLogCacheStore(fileURL: root.appendingPathComponent("cache.json")),
                clock: { anchor }
            )

            _ = await coordinator.refreshLocalPass(enabledSources: [.codexCLI], calendar: utcCalendar, now: anchor)
            let bg1 = await coordinator.runBackgroundMaterializationPass(enabledSources: [.codexCLI], calendar: utcCalendar)
            XCTAssertEqual(bg1.pendingICloudFiles, 0)
            XCTAssertEqual(fileAccess.openCount(for: logURL), 1)
            XCTAssertEqual(TokenSummary.aggregate(bg1.bucketsBySource[.codexCLI] ?? []).totalTokens, 2100)
            XCTAssertEqual(linesScanned.value, 3)

            // Re-evict unchanged: MUST NOT queue or download again.
            fileAccess.setEvicted(true, for: logURL)
            let reevicted = await coordinator.refreshLocalPass(enabledSources: [.codexCLI], calendar: utcCalendar, now: anchor)
            XCTAssertEqual(reevicted.pendingICloudFiles, 0)
            XCTAssertEqual(fileAccess.openCount(for: logURL), 1)

            // Complete the partial line and keep evicted -> resumes from retained offset and parses only 1 new line!
            let fh = try FileHandle(forWritingTo: logURL)
            try fh.seekToEnd()
            try fh.write(contentsOf: Data(partialLineSuffix.utf8))
            try fh.close()
            fileAccess.setMtimeOverride(anchor.addingTimeInterval(-30), for: logURL)

            let updated = await coordinator.refreshLocalPass(enabledSources: [.codexCLI], calendar: utcCalendar, now: anchor)
            XCTAssertEqual(updated.pendingICloudFiles, 1)
            let bg2 = await coordinator.runBackgroundMaterializationPass(enabledSources: [.codexCLI], calendar: utcCalendar)
            XCTAssertEqual(bg2.pendingICloudFiles, 0)
            XCTAssertEqual(TokenSummary.aggregate(bg2.bucketsBySource[.codexCLI] ?? []).totalTokens, 5300)
            XCTAssertEqual(linesScanned.value, 4, "Codex resume must scan only the newly completed line")

            var freshState = SourceCacheState()
            let freshBuckets = try CodexCLITokenLogSource(rootDirectory: root).refresh(state: &freshState, calendar: utcCalendar)
            XCTAssertEqual(bg2.bucketsBySource[.codexCLI], freshBuckets)
        }

        // 4. Gemini: truncated/malformed JSON -> re-evicted unchanged -> 0 repeat downloads;
        //    later completed -> rescans cleanly and matches fresh scan.
        do {
            let root = try makeTempDir(prefix: "evicted-partial-gemini")
            let chatsDir = root.appendingPathComponent("hash/chats", isDirectory: true)
            try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)
            let sessionURL = chatsDir.appendingPathComponent("session-partial.json")

            let truncatedJSON = #"{"messages":[{"id":"g_trunc","type":"gemini","timestamp":"2026-11-26T10:00:00Z","model":"gemini-3-pro","tokens":{"input":1000"#
            try truncatedJSON.write(to: sessionURL, atomically: false, encoding: .utf8)

            let fileAccess = SimulatedICloudFileAccess(
                evictedURLs: [sessionURL],
                mtimeOverrides: [sessionURL: anchor.addingTimeInterval(-120)]
            )
            let source = GeminiCLITokenLogSource(rootDirectory: root, fileAccess: fileAccess)
            let coordinator = LocalTokenLogCoordinator(
                sources: [source],
                cacheStore: TokenLogCacheStore(fileURL: root.appendingPathComponent("cache.json")),
                clock: { anchor }
            )

            _ = await coordinator.refreshLocalPass(enabledSources: [.geminiCLI], calendar: utcCalendar, now: anchor)
            let bg1 = await coordinator.runBackgroundMaterializationPass(enabledSources: [.geminiCLI], calendar: utcCalendar)
            XCTAssertEqual(bg1.pendingICloudFiles, 0)
            XCTAssertEqual(fileAccess.openCount(for: sessionURL), 1)
            XCTAssertEqual(TokenSummary.aggregate(bg1.bucketsBySource[.geminiCLI] ?? []).totalTokens, 0)

            // Re-evict unchanged: MUST NOT queue or download again!
            fileAccess.setEvicted(true, for: sessionURL)
            let reevicted = await coordinator.refreshLocalPass(enabledSources: [.geminiCLI], calendar: utcCalendar, now: anchor)
            XCTAssertEqual(reevicted.pendingICloudFiles, 0, "Unchanged re-evicted truncated Gemini file must NOT re-download")
            XCTAssertEqual(fileAccess.openCount(for: sessionURL), 1)

            // Complete the JSON -> downloads once and counts tokens cleanly.
            let fullJSON = geminiSessionJSON(id: "g_trunc", timestamp: "2026-11-26T10:00:00Z", model: "gemini-3-pro", input: 1000, cached: 200, output: 150)
            try fullJSON.write(to: sessionURL, atomically: false, encoding: .utf8)
            fileAccess.setMtimeOverride(anchor.addingTimeInterval(-30), for: sessionURL)

            let updated = await coordinator.refreshLocalPass(enabledSources: [.geminiCLI], calendar: utcCalendar, now: anchor)
            XCTAssertEqual(updated.pendingICloudFiles, 1)
            let bg2 = await coordinator.runBackgroundMaterializationPass(enabledSources: [.geminiCLI], calendar: utcCalendar)
            XCTAssertEqual(bg2.pendingICloudFiles, 0)
            XCTAssertEqual(TokenSummary.aggregate(bg2.bucketsBySource[.geminiCLI] ?? []).totalTokens, 1150)
        }

        // 5. OpenCode legacy JSON: truncated JSON -> re-evicted unchanged -> 0 repeat downloads;
        //    later completed -> rescans cleanly and matches fresh scan.
        do {
            let root = try makeTempDir(prefix: "evicted-partial-opencode")
            let legacyDir = root.appendingPathComponent("storage/message/ses1", isDirectory: true)
            try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
            let msgURL = legacyDir.appendingPathComponent("msg_partial.json")

            let truncatedJSON = #"{"id":"msg_partial","role":"assistant","modelID":"kimi-k2","tokens":{"input":900"#
            try truncatedJSON.write(to: msgURL, atomically: false, encoding: .utf8)

            let fileAccess = SimulatedICloudFileAccess(
                evictedURLs: [msgURL],
                mtimeOverrides: [msgURL: anchor.addingTimeInterval(-120)]
            )
            let source = OpenCodeTokenLogSource(rootDirectory: root, fileAccess: fileAccess)
            let coordinator = LocalTokenLogCoordinator(
                sources: [source],
                cacheStore: TokenLogCacheStore(fileURL: root.appendingPathComponent("cache.json")),
                clock: { anchor }
            )

            _ = await coordinator.refreshLocalPass(enabledSources: [.openCode], calendar: utcCalendar, now: anchor)
            let bg1 = await coordinator.runBackgroundMaterializationPass(enabledSources: [.openCode], calendar: utcCalendar)
            XCTAssertEqual(bg1.pendingICloudFiles, 0)
            XCTAssertEqual(fileAccess.openCount(for: msgURL), 1)
            XCTAssertEqual(TokenSummary.aggregate(bg1.bucketsBySource[.openCode] ?? []).totalTokens, 0)

            // Re-evict unchanged: MUST NOT queue or download again!
            fileAccess.setEvicted(true, for: msgURL)
            let reevicted = await coordinator.refreshLocalPass(enabledSources: [.openCode], calendar: utcCalendar, now: anchor)
            XCTAssertEqual(reevicted.pendingICloudFiles, 0, "Unchanged re-evicted truncated OpenCode file must NOT re-download")
            XCTAssertEqual(fileAccess.openCount(for: msgURL), 1)

            // Complete the JSON -> counts tokens cleanly.
            let fullJSON = openCodeLegacyJSON(id: "msg_partial", completedMs: 1795615200000, model: "kimi-k2", input: 900, output: 100, cacheRead: 200)
            try fullJSON.write(to: msgURL, atomically: false, encoding: .utf8)
            fileAccess.setMtimeOverride(anchor.addingTimeInterval(-30), for: msgURL)

            let updated = await coordinator.refreshLocalPass(enabledSources: [.openCode], calendar: utcCalendar, now: anchor)
            XCTAssertEqual(updated.pendingICloudFiles, 1)
            let bg2 = await coordinator.runBackgroundMaterializationPass(enabledSources: [.openCode], calendar: utcCalendar)
            XCTAssertEqual(bg2.pendingICloudFiles, 0)
            XCTAssertEqual(TokenSummary.aggregate(bg2.bucketsBySource[.openCode] ?? []).totalTokens, 1200)
        }
    }
}
