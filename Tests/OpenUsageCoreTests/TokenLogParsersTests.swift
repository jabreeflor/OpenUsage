import Foundation
import SQLite3
import XCTest
@testable import OpenUsageCore

final class TokenLogParsersTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        super.tearDown()
    }

    private func makeTempDir(prefix: String = "openusage-test") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    private func fixturesRootURL() throws -> URL {
        let bundle = Bundle(for: TokenLogParsersTests.self)
        if let url = bundle.url(forResource: "Fixtures", withExtension: nil) {
            return url
        }
        // Fallback for direct filesystem runs
        let candidate = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.path), "Fixtures folder not found")
        return candidate
    }

    private var utcCalendar: Calendar {
        StatisticsAggregator.gregorianCalendar(timeZone: TimeZone(secondsFromGMT: 0)!)
    }

    // MARK: - 1. Claude Code Parser

    func testClaudeCodeParserWithSyntheticFixture() throws {
        let root = try fixturesRootURL().appendingPathComponent("claude", isDirectory: true)
        let source = ClaudeCodeTokenLogSource(rootDirectory: root)
        XCTAssertEqual(source.provider, .claude)
        XCTAssertEqual(source.toolSource, .claudeCode)

        var state = SourceCacheState()
        let buckets = try source.refresh(state: &state, calendar: utcCalendar)

        // Expected from session-001.jsonl:
        // 1) msg_demo_001|req_demo_001 (repeated identically -> counted once):
        //    day 2026-11-26 hour 4, claude-opus-4-5-20251101, in=1200, out=300, cache=4500 (500+4000), req=1
        // 2) msg_demo_002|req_demo_002 (streaming update 50 -> 250 output tokens -> counted once with 250):
        //    day 2026-11-26 hour 15, claude-sonnet-4-5-20250929, in=800, out=250, cache=1000, req=1
        // 3) msg_demo_003 (missing usage) & msg_demo_004 (zero usage) & malformed line -> ignored!
        XCTAssertEqual(buckets.count, 2)

        let opus = try XCTUnwrap(buckets.first { $0.model == "claude-opus-4-5-20251101" })
        XCTAssertEqual(opus.dayKey, "2026-11-26")
        XCTAssertEqual(opus.hour, 4)
        XCTAssertEqual(opus.inputTokens, 1200)
        XCTAssertEqual(opus.outputTokens, 300)
        XCTAssertEqual(opus.cacheTokens, 4500)
        XCTAssertEqual(opus.requests, 1)

        let sonnet = try XCTUnwrap(buckets.first { $0.model == "claude-sonnet-4-5-20250929" })
        XCTAssertEqual(sonnet.dayKey, "2026-11-26")
        XCTAssertEqual(sonnet.hour, 15)
        XCTAssertEqual(sonnet.inputTokens, 800)
        XCTAssertEqual(sonnet.outputTokens, 250)
        XCTAssertEqual(sonnet.cacheTokens, 1000)
        XCTAssertEqual(sonnet.requests, 1)
    }

    func testSymlinkedRootDirectoryIsTraversed() throws {
        let realRoot = try fixturesRootURL().appendingPathComponent("claude", isDirectory: true)
        let tempContainer = try makeTempDir(prefix: "symlink-root")
        let linkURL = tempContainer.appendingPathComponent("projects-link")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: realRoot)

        let source = ClaudeCodeTokenLogSource(rootDirectory: linkURL)
        var state = SourceCacheState()
        let buckets = try source.refresh(state: &state, calendar: utcCalendar)
        XCTAssertEqual(buckets.count, 2)
        XCTAssertEqual(TokenSummary.aggregate(buckets).totalTokens, 8050)
    }

    // MARK: - 2. Codex CLI Parser

    func testCodexCLIParserWithSyntheticFixture() throws {
        let root = try fixturesRootURL().appendingPathComponent("codex", isDirectory: true)
        let source = CodexCLITokenLogSource(rootDirectory: root)
        XCTAssertEqual(source.provider, .chatgpt)
        XCTAssertEqual(source.toolSource, .codexCLI)

        var state = SourceCacheState()
        let buckets = try source.refresh(state: &state, calendar: utcCalendar)

        // Expected from rollout-2026-11-26-demo.jsonl:
        // Event 1 (14:00:10, gpt-5-codex): total/last in=10000, cached=6000, out=500 -> non-cached in=4000, out=500, cache=6000, req=1
        // token_usage_record: ignored (no double counting)
        // Event 2 (14:00:11): identical total_token_usage -> skipped!
        // Event 3 (14:15:00, gpt-5-codex): delta in=15000, cached=12000, out=700 -> non-cached in=3000, out=700, cache=12000, req=1
        //   Combined hour 14 gpt-5-codex: in=7000, out=1200, cache=18000, total=26200, req=2
        // turn_context switches model -> gpt-5
        // Event 4 (15:05:00, gpt-5): counter reset (total=3000 < 25000) -> fallback last_token_usage: in=2000, out=400, cache=1000, total=3400, req=1
        XCTAssertEqual(buckets.count, 2)

        let codexBucket = try XCTUnwrap(buckets.first { $0.model == "gpt-5-codex" })
        XCTAssertEqual(codexBucket.dayKey, "2026-11-26")
        XCTAssertEqual(codexBucket.hour, 14)
        XCTAssertEqual(codexBucket.inputTokens, 7000)
        XCTAssertEqual(codexBucket.outputTokens, 1200)
        XCTAssertEqual(codexBucket.cacheTokens, 18000)
        XCTAssertEqual(codexBucket.totalTokens, 26200)
        XCTAssertEqual(codexBucket.requests, 2)

        let gpt5Bucket = try XCTUnwrap(buckets.first { $0.model == "gpt-5" })
        XCTAssertEqual(gpt5Bucket.dayKey, "2026-11-26")
        XCTAssertEqual(gpt5Bucket.hour, 15)
        XCTAssertEqual(gpt5Bucket.inputTokens, 2000)
        XCTAssertEqual(gpt5Bucket.outputTokens, 400)
        XCTAssertEqual(gpt5Bucket.cacheTokens, 1000)
        XCTAssertEqual(gpt5Bucket.totalTokens, 3400)
        XCTAssertEqual(gpt5Bucket.requests, 1)
    }

    // MARK: - 3. Gemini CLI Parser

    func testGeminiCLIParserWithSyntheticFixture() throws {
        let root = try fixturesRootURL().appendingPathComponent("gemini", isDirectory: true)
        let source = GeminiCLITokenLogSource(rootDirectory: root)
        XCTAssertEqual(source.provider, .gemini)
        XCTAssertEqual(source.toolSource, .geminiCLI)

        var state = SourceCacheState()
        let buckets = try source.refresh(state: &state, calendar: utcCalendar)

        // Expected from session-2026-11-26-demo.json (corrupt json & logs.json ignored):
        // gem-msg-1 (duplicate skipped): in=7000-5000=2000, out=100+250+50=400, cache=5000, total=7400, req=1
        // gem-msg-zero: skipped
        // gem-msg-2: in=3000, out=200+100=300, cache=0, total=3300, req=1
        XCTAssertEqual(buckets.count, 2)

        let pro = try XCTUnwrap(buckets.first { $0.model == "gemini-2.5-pro" })
        XCTAssertEqual(pro.dayKey, "2026-11-26")
        XCTAssertEqual(pro.hour, 16)
        XCTAssertEqual(pro.inputTokens, 2000)
        XCTAssertEqual(pro.outputTokens, 400)
        XCTAssertEqual(pro.cacheTokens, 5000)
        XCTAssertEqual(pro.totalTokens, 7400)
        XCTAssertEqual(pro.requests, 1)

        let flash = try XCTUnwrap(buckets.first { $0.model == "gemini-2.5-flash" })
        XCTAssertEqual(flash.dayKey, "2026-11-26")
        XCTAssertEqual(flash.hour, 17)
        XCTAssertEqual(flash.inputTokens, 3000)
        XCTAssertEqual(flash.outputTokens, 300)
        XCTAssertEqual(flash.cacheTokens, 0)
        XCTAssertEqual(flash.totalTokens, 3300)
        XCTAssertEqual(flash.requests, 1)
    }

    // MARK: - 4. OpenCode Parser (Legacy JSON + SQLite + Deduplication + Incremental Update)

    func testOpenCodeLegacyJSONFixture() throws {
        let root = try fixturesRootURL().appendingPathComponent("opencode", isDirectory: true)
        let source = OpenCodeTokenLogSource(rootDirectory: root)
        XCTAssertEqual(source.provider, .opencode)
        XCTAssertEqual(source.toolSource, .openCode)

        var state = SourceCacheState()
        let buckets = try source.refresh(state: &state, calendar: utcCalendar)

        // msg_oc_asst_001 completed at 1795701605000 ms (2026-11-26T14:00:05Z)
        // in=4000, out=300+150=450, cache=2000+500=2500, total=6950, req=1
        XCTAssertEqual(buckets.count, 1)
        let bucket = try XCTUnwrap(buckets.first)
        XCTAssertEqual(bucket.dayKey, "2026-11-26")
        XCTAssertEqual(bucket.hour, 14)
        XCTAssertEqual(bucket.model, "kimi-k2")
        XCTAssertEqual(bucket.inputTokens, 4000)
        XCTAssertEqual(bucket.outputTokens, 450)
        XCTAssertEqual(bucket.cacheTokens, 2500)
        XCTAssertEqual(bucket.totalTokens, 6950)
        XCTAssertEqual(bucket.requests, 1)
    }

    func testOpenCodeSQLiteIncrementalAndDeduplicationAgainstLegacyJSON() throws {
        let dir = try makeTempDir(prefix: "opencode-sqlite")
        let legacyDir = dir.appendingPathComponent("storage/message/ses_demo", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)

        // Write a legacy JSON file with the SAME message id ("msg_shared") that will also live in SQLite
        let sharedJSON = """
        {"id":"msg_shared","role":"assistant","modelID":"kimi-k2","time":{"created":1795701600000,"completed":1795701605000},"tokens":{"input":1000,"output":200,"reasoning":50,"cache":{"read":500,"write":0},"total":1750}}
        """
        try sharedJSON.write(to: legacyDir.appendingPathComponent("msg_shared.json"), atomically: true, encoding: .utf8)

        // Create synthetic opencode.db matching real OpenCode schema
        let dbURL = dir.appendingPathComponent("opencode.db")
        try executeSQL(at: dbURL, statements: [
            """
            CREATE TABLE message (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                time_created INTEGER NOT NULL,
                time_updated INTEGER NOT NULL,
                data TEXT NOT NULL
            );
            """,
            """
            INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES
            ('msg_shared', 'ses_1', 1795701600000, 1795701605000, '{"role":"assistant","modelID":"kimi-k2","time":{"created":1795701600000,"completed":1795701605000},"tokens":{"input":1000,"output":200,"reasoning":50,"cache":{"read":500,"write":0}}}'),
            ('msg_user', 'ses_1', 1795701600000, 1795701600000, '{"role":"user","time":{"created":1795701600000}}'),
            ('msg_bad', 'ses_1', 1795701600000, 1795701601000, '{corrupt json');
            """
        ])

        let source = OpenCodeTokenLogSource(rootDirectory: dir)
        var state = SourceCacheState()

        // First scan: msg_shared must only be counted ONCE (deduplicated between DB and legacy JSON)
        let firstBuckets = try source.refresh(state: &state, calendar: utcCalendar)
        XCTAssertEqual(firstBuckets.count, 1)
        XCTAssertEqual(firstBuckets[0].inputTokens, 1000)
        XCTAssertEqual(firstBuckets[0].outputTokens, 250)
        XCTAssertEqual(firstBuckets[0].cacheTokens, 500)
        XCTAssertEqual(firstBuckets[0].requests, 1)

        // Update msg_shared with final streamed tokens AND insert a second message
        // Touch mtime forward by 1 second so FileMetadata detects change deterministically even on 1s mtime filesystems.
        try executeSQL(at: dbURL, statements: [
            """
            UPDATE message
            SET time_updated = 1795701610000,
                data = '{"role":"assistant","modelID":"kimi-k2","time":{"created":1795701600000,"completed":1795701610000},"tokens":{"input":1000,"output":400,"reasoning":100,"cache":{"read":500,"write":100}}}'
            WHERE id = 'msg_shared';
            """,
            """
            INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES
            ('msg_second', 'ses_1', 1795705200000, 1795705205000, '{"role":"assistant","modelID":"glm-4.6","time":{"created":1795705200000,"completed":1795705205000},"tokens":{"input":2000,"output":300,"reasoning":0,"cache":{"read":1000,"write":0}}}');
            """
        ])
        bumpMtime(of: dbURL, by: 2)

        let secondBuckets = try source.refresh(state: &state, calendar: utcCalendar)
        XCTAssertEqual(secondBuckets.count, 2)

        let kimi = try XCTUnwrap(secondBuckets.first { $0.model == "kimi-k2" })
        XCTAssertEqual(kimi.inputTokens, 1000)
        XCTAssertEqual(kimi.outputTokens, 500) // 400 + 100
        XCTAssertEqual(kimi.cacheTokens, 600)  // 500 + 100
        XCTAssertEqual(kimi.requests, 1)       // Still 1 request, updated in place!

        let glm = try XCTUnwrap(secondBuckets.first { $0.model == "glm-4.6" })
        XCTAssertEqual(glm.hour, 15)
        XCTAssertEqual(glm.inputTokens, 2000)
        XCTAssertEqual(glm.outputTokens, 300)
        XCTAssertEqual(glm.cacheTokens, 1000)
        XCTAssertEqual(glm.requests, 1)
    }

    // MARK: - 5. Cursor Stub

    func testCursorStubConformsToProtocolAndReturnsEmpty() async throws {
        let source = CursorTokenLogSource()
        let asProtocol: any TokenLogSource = source
        XCTAssertEqual(asProtocol.provider, .cursor)
        XCTAssertEqual(source.toolSource, .cursor)
        XCTAssertEqual(source.sourceLabel, "from your Cursor account")
        XCTAssertTrue(source.watchDirectories.isEmpty)
        let buckets = try await asProtocol.loadBuckets()
        XCTAssertTrue(buckets.isEmpty)
    }

    // MARK: - 6. Time Zone & Midnight Boundary Aggregation

    func testTimeZoneAndMidnightBoundaryBucketing() throws {
        let root = try fixturesRootURL().appendingPathComponent("claude", isDirectory: true)
        let source = ClaudeCodeTokenLogSource(rootDirectory: root)

        // In session-001.jsonl:
        // msg_demo_001 is at 2026-11-26T04:30:05.120Z
        // - In UTC: 2026-11-26 hour 4
        // - In America/New_York (EST, UTC-5): 2026-11-25 hour 23 (previous day!)
        // - In Asia/Tokyo (JST, UTC+9): 2026-11-26 hour 13
        // msg_demo_002 is at 2026-11-26T15:10:04Z
        // - In America/New_York (UTC-5): 2026-11-26 hour 10
        // - In Asia/Tokyo (UTC+9): 2026-11-27 hour 0 (next day!)
        let nyCal = StatisticsAggregator.gregorianCalendar(timeZone: TimeZone(identifier: "America/New_York")!)
        var nyState = SourceCacheState()
        let nyBuckets = try source.refresh(state: &nyState, calendar: nyCal)
        let nyOpus = try XCTUnwrap(nyBuckets.first { $0.model == "claude-opus-4-5-20251101" })
        let nySonnet = try XCTUnwrap(nyBuckets.first { $0.model == "claude-sonnet-4-5-20250929" })
        XCTAssertEqual(nyOpus.dayKey, "2026-11-25")
        XCTAssertEqual(nyOpus.hour, 23)
        XCTAssertEqual(nySonnet.dayKey, "2026-11-26")
        XCTAssertEqual(nySonnet.hour, 10)

        let tokyoCal = StatisticsAggregator.gregorianCalendar(timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        var tokyoState = SourceCacheState()
        let tokyoBuckets = try source.refresh(state: &tokyoState, calendar: tokyoCal)
        let tokyoOpus = try XCTUnwrap(tokyoBuckets.first { $0.model == "claude-opus-4-5-20251101" })
        let tokyoSonnet = try XCTUnwrap(tokyoBuckets.first { $0.model == "claude-sonnet-4-5-20250929" })
        XCTAssertEqual(tokyoOpus.dayKey, "2026-11-26")
        XCTAssertEqual(tokyoOpus.hour, 13)
        XCTAssertEqual(tokyoSonnet.dayKey, "2026-11-27")
        XCTAssertEqual(tokyoSonnet.hour, 0)
    }

    func testLimitsHitDisplayTextShowsEnDashWhenUnavailable() {
        let anchor = LogTimestampParser.parseISO8601("2026-11-26T12:00:00Z")!
        let unavailable = StatisticsAggregator.summarize(
            buckets: [],
            limitHits: [],
            limitsHitAvailable: false,
            range: .sevenDays,
            filter: .overview,
            anchorDate: anchor,
            calendar: utcCalendar
        )
        XCTAssertFalse(unavailable.limitsHitAvailable)
        XCTAssertEqual(unavailable.limitsHitDisplayText, "\u{2013}")

        let availableZero = StatisticsAggregator.summarize(
            buckets: [],
            limitHits: [],
            limitsHitAvailable: true,
            range: .sevenDays,
            filter: .overview,
            anchorDate: anchor,
            calendar: utcCalendar
        )
        XCTAssertTrue(availableZero.limitsHitAvailable)
        XCTAssertEqual(availableZero.limitsHitDisplayText, "0")
    }

    // MARK: - 7. Incremental Offsets (Append, Partial Trailing Line, Truncation/Rotation, Cache Persistence)

    func testClaudeIncrementalAppendPartialLineAndTruncation() throws {
        let dir = try makeTempDir(prefix: "claude-inc")
        let projDir = dir.appendingPathComponent("proj-a", isDirectory: true)
        try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)
        let logURL = projDir.appendingPathComponent("session.jsonl")

        let line1 = """
        {"type":"assistant","requestId":"r1","timestamp":"2026-11-26T10:00:00Z","message":{"id":"m1","model":"claude-opus-4-5-20251101","usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":0,"cache_read_input_tokens":200}}}\n
        """
        // Append an incomplete partial line without trailing newline
        let partialStart = #"{"type":"assistant","requestId":"r2","timestamp":"2026-11-26T10:05:00Z","message":{"id":"m2","model":"claude-opus-4-5-20251101","usage":{"input_tokens":300,"#
        try (line1 + partialStart).write(to: logURL, atomically: true, encoding: .utf8)

        let source = ClaudeCodeTokenLogSource(rootDirectory: dir)
        var state = SourceCacheState()

        let pass1 = try source.refresh(state: &state, calendar: utcCalendar)
        XCTAssertEqual(pass1.count, 1)
        XCTAssertEqual(pass1[0].inputTokens, 100)
        XCTAssertEqual(pass1[0].outputTokens, 50)
        XCTAssertEqual(pass1[0].cacheTokens, 200)
        XCTAssertEqual(pass1[0].requests, 1)

        // Offset should remain right after line1 so the incomplete line2 is re-read once finished!
        let offsetAfterPass1 = try XCTUnwrap(state.files["proj-a/session.jsonl"]?.offset)
        XCTAssertEqual(offsetAfterPass1, UInt64(line1.utf8.count))

        // Finish writing partial line2 + a duplicate of line1 (dedup must persist across incremental append!)
        let partialEnd = "\"output_tokens\":75,\"cache_creation_input_tokens\":25,\"cache_read_input_tokens\":0}}}\n"
        let dupLine1 = line1
        let fh = try FileHandle(forUpdating: logURL)
        try fh.seekToEnd()
        try fh.write(contentsOf: Data((partialEnd + dupLine1).utf8))
        try fh.close()
        bumpMtime(of: logURL, by: 2)

        let pass2 = try source.refresh(state: &state, calendar: utcCalendar)
        XCTAssertEqual(pass2.count, 1)
        XCTAssertEqual(pass2[0].inputTokens, 400)   // 100 + 300 (dup ignored!)
        XCTAssertEqual(pass2[0].outputTokens, 125)  // 50 + 75
        XCTAssertEqual(pass2[0].cacheTokens, 225)   // 200 + 25
        XCTAssertEqual(pass2[0].requests, 2)        // r1 + r2

        // Now truncate the file to a smaller fresh line (tests truncation reset)
        let freshLine = """
        {"type":"assistant","requestId":"r9","timestamp":"2026-11-26T11:00:00Z","message":{"id":"m9","model":"claude-haiku-4-5","usage":{"input_tokens":50,"output_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}\n
        """
        try freshLine.write(to: logURL, atomically: false, encoding: .utf8)
        bumpMtime(of: logURL, by: 4)

        let pass3 = try source.refresh(state: &state, calendar: utcCalendar)
        XCTAssertEqual(pass3.count, 1)
        XCTAssertEqual(pass3[0].model, "claude-haiku-4-5")
        XCTAssertEqual(pass3[0].hour, 11)
        XCTAssertEqual(pass3[0].inputTokens, 50)
        XCTAssertEqual(pass3[0].outputTokens, 10)
        XCTAssertEqual(pass3[0].requests, 1)
    }

    func testCodexIncrementalAppendPreservesCumulativeTotalsAndModel() throws {
        let dir = try makeTempDir(prefix: "codex-inc")
        let rolloutURL = dir.appendingPathComponent("rollout-2026-11-26-inc.jsonl")

        let initial = """
        {"timestamp":"2026-11-26T10:00:00Z","type":"turn_context","payload":{"model":"gpt-5-codex"}}
        {"timestamp":"2026-11-26T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":5000,"cached_input_tokens":2000,"output_tokens":300,"total_tokens":5300},"last_token_usage":{"input_tokens":5000,"cached_input_tokens":2000,"output_tokens":300,"total_tokens":5300}}}}

        """
        try initial.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let source = CodexCLITokenLogSource(rootDirectory: dir)
        var state = SourceCacheState()

        let pass1 = try source.refresh(state: &state, calendar: utcCalendar)
        XCTAssertEqual(pass1.count, 1)
        XCTAssertEqual(pass1[0].inputTokens, 3000)
        XCTAssertEqual(pass1[0].outputTokens, 300)
        XCTAssertEqual(pass1[0].cacheTokens, 2000)
        XCTAssertEqual(pass1[0].requests, 1)

        // Append a second cumulative event without repeating turn_context (must remember model & previous totals!)
        let appended = """
        {"timestamp":"2026-11-26T10:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":9000,"cached_input_tokens":5000,"output_tokens":500,"total_tokens":9500},"last_token_usage":{"input_tokens":4000,"cached_input_tokens":3000,"output_tokens":200,"total_tokens":4200}}}}

        """
        let fh = try FileHandle(forUpdating: rolloutURL)
        try fh.seekToEnd()
        try fh.write(contentsOf: Data(appended.utf8))
        try fh.close()
        bumpMtime(of: rolloutURL, by: 2)

        let pass2 = try source.refresh(state: &state, calendar: utcCalendar)
        XCTAssertEqual(pass2.count, 1)
        XCTAssertEqual(pass2[0].model, "gpt-5-codex")
        XCTAssertEqual(pass2[0].inputTokens, 4000) // 3000 + (4000 - 3000)
        XCTAssertEqual(pass2[0].outputTokens, 500) // 300 + 200
        XCTAssertEqual(pass2[0].cacheTokens, 5000) // 2000 + 3000
        XCTAssertEqual(pass2[0].requests, 2)
    }

    // MARK: - 8. Coordinator, Persisted Cache, Enable/Disable, Dumper & Watcher

    func testCoordinatorEnableDisableAndCachePersistence() async throws {
        let fixtures = try fixturesRootURL()
        let cacheDir = try makeTempDir(prefix: "cache-test")
        let cacheURL = cacheDir.appendingPathComponent("token-log-cache-v1.json")
        let cacheStore = TokenLogCacheStore(fileURL: cacheURL)

        let sources: [any IncrementalTokenLogSource] = [
            ClaudeCodeTokenLogSource(rootDirectory: fixtures.appendingPathComponent("claude", isDirectory: true)),
            CodexCLITokenLogSource(rootDirectory: fixtures.appendingPathComponent("codex", isDirectory: true)),
            GeminiCLITokenLogSource(rootDirectory: fixtures.appendingPathComponent("gemini", isDirectory: true)),
            OpenCodeTokenLogSource(rootDirectory: fixtures.appendingPathComponent("opencode", isDirectory: true)),
            CursorTokenLogSource()
        ]

        let coordinator = LocalTokenLogCoordinator(sources: sources, cacheStore: cacheStore)

        // Enable only Claude and Gemini (Codex and OpenCode disabled)
        let bySource1 = await coordinator.refresh(
            enabledSources: [.claudeCode, .geminiCLI],
            calendar: utcCalendar,
            persistCache: true
        )
        XCTAssertNotNil(bySource1[.claudeCode])
        XCTAssertNotNil(bySource1[.geminiCLI])
        XCTAssertNil(bySource1[.codexCLI])
        XCTAssertNil(bySource1[.openCode])

        // Cache file must exist on disk and reload cleanly in a fresh coordinator
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))
        let coordinator2 = LocalTokenLogCoordinator(sources: sources, cacheStore: cacheStore)
        let cached = await coordinator2.loadCachedBuckets(calendar: utcCalendar)
        XCTAssertEqual(cached[.claudeCode]?.count, 2)
        XCTAssertEqual(cached[.geminiCLI]?.count, 2)
        XCTAssertTrue(cached[.codexCLI]?.isEmpty ?? true)

        // Active bucket filtering respects live checkbox map: disabling Claude removes its buckets immediately
        let activeOnlyGemini = LocalTokenLogCoordinator.activeBuckets(
            from: cached,
            enabledSources: [.claudeCode: false, .codexCLI: false, .geminiCLI: true, .openCode: false, .cursor: true]
        )
        XCTAssertTrue(activeOnlyGemini.allSatisfy { $0.provider == .gemini })
        XCTAssertEqual(TokenSummary.aggregate(activeOnlyGemini).totalTokens, 10_700)

        // Time zone mismatch invalidates cache cleanly
        let tokyoLoaded = cacheStore.load(expectedTimeZone: TimeZone(identifier: "Asia/Tokyo")!)
        XCTAssertTrue(tokyoLoaded.sources.isEmpty)
        XCTAssertEqual(tokyoLoaded.timeZoneIdentifier, "Asia/Tokyo")
    }

    func testTokenSummaryDumperPrintsNumbersOnlyWithNoPathsOrModels() async throws {
        let fixtures = try fixturesRootURL()
        let cacheDir = try makeTempDir(prefix: "dump-test")
        let cacheStore = TokenLogCacheStore(fileURL: cacheDir.appendingPathComponent("cache.json"))
        let sources: [any IncrementalTokenLogSource] = [
            ClaudeCodeTokenLogSource(rootDirectory: fixtures.appendingPathComponent("claude", isDirectory: true)),
            CodexCLITokenLogSource(rootDirectory: fixtures.appendingPathComponent("codex", isDirectory: true)),
            GeminiCLITokenLogSource(rootDirectory: fixtures.appendingPathComponent("gemini", isDirectory: true)),
            OpenCodeTokenLogSource(rootDirectory: fixtures.appendingPathComponent("opencode", isDirectory: true)),
            CursorTokenLogSource()
        ]
        let coordinator = LocalTokenLogCoordinator(sources: sources, cacheStore: cacheStore)
        let anchor = LogTimestampParser.parseISO8601("2026-11-26T20:00:00Z")!

        let suiteName = "dev.jabree.OpenUsage.test.dumper-all.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        for tool in LocalToolSource.allCases {
            defaults.set(true, forKey: tool.defaultsKey)
        }

        let report = await TokenSummaryDumper.generateReport(
            isDemo: false,
            anchorDate: anchor,
            calendar: utcCalendar,
            coordinator: coordinator,
            defaults: defaults
        )

        XCTAssertTrue(report.contains("OpenUsage token summary (last 7 days)"))
        XCTAssertTrue(report.contains("OpenUsage token summary (last 30 days)"))
        // Claude: (1200+300+4500) + (800+250+1000) = 8050, requests=2
        XCTAssertTrue(report.contains("claude: total=8050 input=2000 output=550 cache=5500 requests=2"))
        // ChatGPT (Codex): 26200 + 3400 = 29600, requests=3
        XCTAssertTrue(report.contains("chatgpt: total=29600 input=9000 output=1600 cache=19000 requests=3"))
        // Cursor: 0
        XCTAssertTrue(report.contains("cursor: total=0 input=0 output=0 cache=0 requests=0"))
        // Gemini: 7400 + 3300 = 10700, requests=2
        XCTAssertTrue(report.contains("gemini: total=10700 input=5000 output=700 cache=5000 requests=2"))
        // OpenCode: 6950, requests=1
        XCTAssertTrue(report.contains("opencode: total=6950 input=4000 output=450 cache=2500 requests=1"))

        // Privacy check: no file paths, no model IDs, no project names, no session IDs
        XCTAssertFalse(report.contains("/Users"))
        XCTAssertFalse(report.contains("claude-opus"))
        XCTAssertFalse(report.contains("gpt-5-codex"))
        XCTAssertFalse(report.contains("demo-project"))
    }

    func testTokenSummaryDumperRespectsPersistedEnabledSourcesAndSkipsDisabledRefresh() async throws {
        let fixtures = try fixturesRootURL()
        let cacheDir = try makeTempDir(prefix: "dump-prefs-test")
        let cacheURL = cacheDir.appendingPathComponent("cache.json")
        let cacheStore = TokenLogCacheStore(fileURL: cacheURL)

        let claudeSpy = SpyIncrementalTokenLogSource(
            wrapped: ClaudeCodeTokenLogSource(rootDirectory: fixtures.appendingPathComponent("claude", isDirectory: true))
        )
        let codexSpy = SpyIncrementalTokenLogSource(
            wrapped: CodexCLITokenLogSource(rootDirectory: fixtures.appendingPathComponent("codex", isDirectory: true))
        )
        let geminiSpy = SpyIncrementalTokenLogSource(
            wrapped: GeminiCLITokenLogSource(rootDirectory: fixtures.appendingPathComponent("gemini", isDirectory: true))
        )
        let openCodeSpy = SpyIncrementalTokenLogSource(
            wrapped: OpenCodeTokenLogSource(rootDirectory: fixtures.appendingPathComponent("opencode", isDirectory: true))
        )
        let cursorSpy = SpyIncrementalTokenLogSource(wrapped: CursorTokenLogSource())

        let coordinator = LocalTokenLogCoordinator(
            sources: [claudeSpy, codexSpy, geminiSpy, openCodeSpy, cursorSpy],
            cacheStore: cacheStore
        )

        let suiteName = "dev.jabree.OpenUsage.test.dumper-prefs.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Persist user preferences: enable Claude & Gemini, disable Codex, OpenCode & Cursor.
        defaults.set(true, forKey: LocalToolSource.claudeCode.defaultsKey)
        defaults.set(false, forKey: LocalToolSource.codexCLI.defaultsKey)
        defaults.set(true, forKey: LocalToolSource.geminiCLI.defaultsKey)
        defaults.set(false, forKey: LocalToolSource.openCode.defaultsKey)
        defaults.set(false, forKey: LocalToolSource.cursor.defaultsKey)

        let anchor = LogTimestampParser.parseISO8601("2026-11-26T20:00:00Z")!
        let report = await TokenSummaryDumper.generateReport(
            isDemo: false,
            anchorDate: anchor,
            calendar: utcCalendar,
            coordinator: coordinator,
            defaults: defaults
        )

        // Disabled sources must receive zero refresh calls.
        XCTAssertEqual(claudeSpy.refreshCallCount, 1)
        XCTAssertEqual(geminiSpy.refreshCallCount, 1)
        XCTAssertEqual(codexSpy.refreshCallCount, 0)
        XCTAssertEqual(openCodeSpy.refreshCallCount, 0)
        XCTAssertEqual(cursorSpy.refreshCallCount, 0)

        // Report includes enabled sources and excludes disabled sources.
        XCTAssertTrue(report.contains("claude: total=8050 input=2000 output=550 cache=5500 requests=2"))
        XCTAssertTrue(report.contains("gemini: total=10700 input=5000 output=700 cache=5000 requests=2"))
        XCTAssertTrue(report.contains("chatgpt: total=0 input=0 output=0 cache=0 requests=0"))
        XCTAssertTrue(report.contains("opencode: total=0 input=0 output=0 cache=0 requests=0"))
        XCTAssertTrue(report.contains("cursor: total=0 input=0 output=0 cache=0 requests=0"))

        // Cache persisted on disk must not contain disabled source entries.
        let cachedDoc = cacheStore.load(expectedTimeZone: utcCalendar.timeZone)
        XCTAssertNotNil(cachedDoc.sources[LocalToolSource.claudeCode.rawValue])
        XCTAssertNotNil(cachedDoc.sources[LocalToolSource.geminiCLI.rawValue])
        XCTAssertNil(cachedDoc.sources[LocalToolSource.codexCLI.rawValue])
        XCTAssertNil(cachedDoc.sources[LocalToolSource.openCode.rawValue])
        XCTAssertNil(cachedDoc.sources[LocalToolSource.cursor.rawValue])
    }

    // MARK: - 9. Same-Inode Rewrite, Truncation+Regrowth, Rotation (Defect 1)

    func testClaudeSameInodeEqualSizeRewriteTruncationRegrowthAndInodeRotation() throws {
        let dir = try makeTempDir(prefix: "claude-rewrite")
        let projDir = dir.appendingPathComponent("proj-rewrite", isDirectory: true)
        try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)
        let logURL = projDir.appendingPathComponent("session.jsonl")

        let recordA = #"{"type":"assistant","requestId":"req_A","timestamp":"2026-11-26T10:00:00Z","message":{"id":"msg_A","model":"claude-opus-4-5-20251101","usage":{"input_tokens":1000,"output_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":200}}}"# + "\n"
        let recordB = #"{"type":"assistant","requestId":"req_B","timestamp":"2026-11-26T12:00:00Z","message":{"id":"msg_B","model":"claude-opus-4-5-20251101","usage":{"input_tokens":4000,"output_tokens":400,"cache_creation_input_tokens":0,"cache_read_input_tokens":500}}}"# + "\n"
        XCTAssertEqual(recordA.utf8.count, recordB.utf8.count, "Synthetic records A and B must have identical byte length")

        try recordA.write(to: logURL, atomically: false, encoding: .utf8)
        let metaA = try XCTUnwrap(FileMetadata.read(at: logURL))

        let source = ClaudeCodeTokenLogSource(rootDirectory: dir)
        var state = SourceCacheState()

        let pass1 = try source.refresh(state: &state, calendar: utcCalendar)
        XCTAssertEqual(pass1.count, 1)
        XCTAssertEqual(pass1[0].hour, 10)
        XCTAssertEqual(pass1[0].inputTokens, 1000)

        // 1) Equal-size same-inode rewrite (even keeping the exact same byte length).
        try overwriteInPlace(url: logURL, content: recordB)
        let metaB = try XCTUnwrap(FileMetadata.read(at: logURL))
        XCTAssertEqual(metaB.inode, metaA.inode, "In-place write must preserve inode")
        XCTAssertEqual(metaB.size, metaA.size, "Equal-size rewrite must preserve file size")

        let pass2 = try source.refresh(state: &state, calendar: utcCalendar)
        XCTAssertEqual(pass2.count, 1)
        XCTAssertEqual(pass2[0].hour, 12)
        XCTAssertEqual(pass2[0].inputTokens, 4000)
        XCTAssertEqual(pass2[0].outputTokens, 400)
        XCTAssertEqual(pass2[0].cacheTokens, 500)
        XCTAssertEqual(pass2[0].requests, 1)

        // 2) Truncation followed by regrowth larger than saved offset on the same inode.
        let recordC1 = #"{"type":"assistant","requestId":"req_C1","timestamp":"2026-11-26T13:00:00Z","message":{"id":"msg_C1","model":"claude-sonnet-4-5-20250929","usage":{"input_tokens":700,"output_tokens":70,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"# + "\n"
        let recordC2 = #"{"type":"assistant","requestId":"req_C2","timestamp":"2026-11-26T13:15:00Z","message":{"id":"msg_C2","model":"claude-sonnet-4-5-20250929","usage":{"input_tokens":300,"output_tokens":30,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"# + "\n"
        let regrown = recordC1 + recordC2
        XCTAssertGreaterThan(UInt64(regrown.utf8.count), metaB.size)
        try overwriteInPlace(url: logURL, content: regrown)
        let metaC = try XCTUnwrap(FileMetadata.read(at: logURL))
        XCTAssertEqual(metaC.inode, metaA.inode)

        let pass3 = try source.refresh(state: &state, calendar: utcCalendar)
        XCTAssertEqual(pass3.count, 1)
        XCTAssertEqual(pass3[0].model, "claude-sonnet-4-5-20250929")
        XCTAssertEqual(pass3[0].hour, 13)
        XCTAssertEqual(pass3[0].inputTokens, 1000)
        XCTAssertEqual(pass3[0].outputTokens, 100)
        XCTAssertEqual(pass3[0].requests, 2)

        // 3) Inode rotation (atomic replacement with a new file/inode).
        let recordD = #"{"type":"assistant","requestId":"req_D","timestamp":"2026-11-26T16:00:00Z","message":{"id":"msg_D","model":"claude-haiku-4-5","usage":{"input_tokens":250,"output_tokens":50,"cache_creation_input_tokens":0,"cache_read_input_tokens":100}}}"# + "\n"
        let replacementURL = projDir.appendingPathComponent("session.jsonl.new")
        try recordD.write(to: replacementURL, atomically: true, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(logURL, withItemAt: replacementURL)
        let metaD = try XCTUnwrap(FileMetadata.read(at: logURL))
        XCTAssertNotEqual(metaD.inode, metaA.inode, "Atomic replacement must rotate inode")

        let pass4 = try source.refresh(state: &state, calendar: utcCalendar)
        XCTAssertEqual(pass4.count, 1)
        XCTAssertEqual(pass4[0].model, "claude-haiku-4-5")
        XCTAssertEqual(pass4[0].hour, 16)
        XCTAssertEqual(pass4[0].inputTokens, 250)
        XCTAssertEqual(pass4[0].outputTokens, 50)
        XCTAssertEqual(pass4[0].cacheTokens, 100)
        XCTAssertEqual(pass4[0].requests, 1)
    }

    func testCodexSameInodeEqualSizeRewriteTruncationRegrowthAndInodeRotation() throws {
        let dir = try makeTempDir(prefix: "codex-rewrite")
        let rolloutURL = dir.appendingPathComponent("rollout-2026-11-26-rw.jsonl")

        let contentA = """
        {"timestamp":"2026-11-26T09:00:00Z","type":"turn_context","payload":{"model":"gpt-5-codex"}}
        {"timestamp":"2026-11-26T09:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2000,"cached_input_tokens":1000,"output_tokens":200,"total_tokens":2200},"last_token_usage":{"input_tokens":2000,"cached_input_tokens":1000,"output_tokens":200,"total_tokens":2200}}}}

        """
        let contentB = """
        {"timestamp":"2026-11-26T11:00:00Z","type":"turn_context","payload":{"model":"gpt-5-codex"}}
        {"timestamp":"2026-11-26T11:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":6000,"cached_input_tokens":1000,"output_tokens":800,"total_tokens":6800},"last_token_usage":{"input_tokens":6000,"cached_input_tokens":1000,"output_tokens":800,"total_tokens":6800}}}}

        """
        XCTAssertEqual(contentA.utf8.count, contentB.utf8.count, "Codex synthetic records A and B must have identical byte length")

        try contentA.write(to: rolloutURL, atomically: false, encoding: .utf8)
        let metaA = try XCTUnwrap(FileMetadata.read(at: rolloutURL))

        let source = CodexCLITokenLogSource(rootDirectory: dir)
        var state = SourceCacheState()

        let pass1 = try source.refresh(state: &state, calendar: utcCalendar)
        XCTAssertEqual(pass1.count, 1)
        XCTAssertEqual(pass1[0].hour, 9)
        XCTAssertEqual(pass1[0].inputTokens, 1000)

        // 1) Equal-size same-inode rewrite.
        try overwriteInPlace(url: rolloutURL, content: contentB)
        let metaB = try XCTUnwrap(FileMetadata.read(at: rolloutURL))
        XCTAssertEqual(metaB.inode, metaA.inode)
        XCTAssertEqual(metaB.size, metaA.size)

        let pass2 = try source.refresh(state: &state, calendar: utcCalendar)
        XCTAssertEqual(pass2.count, 1)
        XCTAssertEqual(pass2[0].hour, 11)
        XCTAssertEqual(pass2[0].inputTokens, 5000)
        XCTAssertEqual(pass2[0].outputTokens, 800)
        XCTAssertEqual(pass2[0].cacheTokens, 1000)
        XCTAssertEqual(pass2[0].requests, 1)

        // 2) Truncation followed by regrowth larger than saved offset on same inode.
        let regrown = """
        {"timestamp":"2026-11-26T14:00:00Z","type":"turn_context","payload":{"model":"gpt-5"}}
        {"timestamp":"2026-11-26T14:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":3000,"cached_input_tokens":500,"output_tokens":150,"total_tokens":3150},"last_token_usage":{"input_tokens":3000,"cached_input_tokens":500,"output_tokens":150,"total_tokens":3150}}}}
        {"timestamp":"2026-11-26T14:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":5000,"cached_input_tokens":1500,"output_tokens":350,"total_tokens":5350},"last_token_usage":{"input_tokens":2000,"cached_input_tokens":1000,"output_tokens":200,"total_tokens":2200}}}}

        """
        XCTAssertGreaterThan(UInt64(regrown.utf8.count), metaB.size)
        try overwriteInPlace(url: rolloutURL, content: regrown)
        let metaC = try XCTUnwrap(FileMetadata.read(at: rolloutURL))
        XCTAssertEqual(metaC.inode, metaA.inode)

        let pass3 = try source.refresh(state: &state, calendar: utcCalendar)
        XCTAssertEqual(pass3.count, 1)
        XCTAssertEqual(pass3[0].model, "gpt-5")
        XCTAssertEqual(pass3[0].hour, 14)
        XCTAssertEqual(pass3[0].inputTokens, 3500)
        XCTAssertEqual(pass3[0].outputTokens, 350)
        XCTAssertEqual(pass3[0].cacheTokens, 1500)
        XCTAssertEqual(pass3[0].requests, 2)

        // 3) Inode rotation.
        let rotated = """
        {"timestamp":"2026-11-26T18:00:00Z","type":"turn_context","payload":{"model":"o3"}}
        {"timestamp":"2026-11-26T18:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":900,"cached_input_tokens":100,"output_tokens":50,"total_tokens":950},"last_token_usage":{"input_tokens":900,"cached_input_tokens":100,"output_tokens":50,"total_tokens":950}}}}

        """
        let replacementURL = dir.appendingPathComponent("rollout-2026-11-26-rw.jsonl.new")
        try rotated.write(to: replacementURL, atomically: true, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(rolloutURL, withItemAt: replacementURL)
        let metaD = try XCTUnwrap(FileMetadata.read(at: rolloutURL))
        XCTAssertNotEqual(metaD.inode, metaA.inode)

        let pass4 = try source.refresh(state: &state, calendar: utcCalendar)
        XCTAssertEqual(pass4.count, 1)
        XCTAssertEqual(pass4[0].model, "o3")
        XCTAssertEqual(pass4[0].hour, 18)
        XCTAssertEqual(pass4[0].inputTokens, 800)
        XCTAssertEqual(pass4[0].outputTokens, 50)
        XCTAssertEqual(pass4[0].cacheTokens, 100)
        XCTAssertEqual(pass4[0].requests, 1)
    }

    // MARK: - 10. Corrected Message Across Hour & Midnight Boundaries (Defect 2)

    func testClaudeCorrectedMessageAcrossHourAndMidnightMovesRequestWithTokens() throws {
        let dir = try makeTempDir(prefix: "claude-midnight-fix")
        let projDir = dir.appendingPathComponent("proj-m", isDirectory: true)
        try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)
        let logURL = projDir.appendingPathComponent("session.jsonl")

        // Streaming message starts at 23:59:59Z on 2026-11-26 and finishes at 00:00:02Z on 2026-11-27.
        let lines = """
        {"type":"assistant","requestId":"req_mid","timestamp":"2026-11-26T23:59:59Z","message":{"id":"msg_mid","model":"claude-opus-4-5-20251101","usage":{"input_tokens":1,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        {"type":"assistant","requestId":"req_mid","timestamp":"2026-11-27T00:00:02Z","message":{"id":"msg_mid","model":"claude-opus-4-5-20251101","usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}

        """
        try lines.write(to: logURL, atomically: true, encoding: .utf8)

        let source = ClaudeCodeTokenLogSource(rootDirectory: dir)
        var state = SourceCacheState()
        let buckets = try source.refresh(state: &state, calendar: utcCalendar)

        // Exactly one complete request in the intended post-midnight bucket; zero ghost buckets on 2026-11-26.
        XCTAssertEqual(buckets.count, 1)
        let bucket = try XCTUnwrap(buckets.first)
        XCTAssertEqual(bucket.dayKey, "2026-11-27")
        XCTAssertEqual(bucket.hour, 0)
        XCTAssertEqual(bucket.inputTokens, 1)
        XCTAssertEqual(bucket.outputTokens, 1)
        XCTAssertEqual(bucket.cacheTokens, 0)
        XCTAssertEqual(bucket.requests, 1)
    }

    func testOpenCodeCorrectedMessageAcrossMidnightMovesRequestWithTokens() throws {
        let dir = try makeTempDir(prefix: "opencode-midnight-fix")
        let dbURL = dir.appendingPathComponent("opencode.db")

        // 2026-11-26T23:59:59Z == 1795737599000 ms
        // 2026-11-27T00:00:02Z == 1795737602000 ms
        try executeSQL(at: dbURL, statements: [
            """
            CREATE TABLE message (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                time_created INTEGER NOT NULL,
                time_updated INTEGER NOT NULL,
                data TEXT NOT NULL
            );
            """,
            """
            INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES
            ('msg_mid', 'ses_mid', 1795737599000, 1795737599000, '{"role":"assistant","modelID":"kimi-k2","time":{"created":1795737599000},"tokens":{"input":100,"output":20,"reasoning":0,"cache":{"read":0,"write":0}}}');
            """
        ])

        let source = OpenCodeTokenLogSource(rootDirectory: dir)
        var state = SourceCacheState()

        let pass1 = try source.refresh(state: &state, calendar: utcCalendar)
        XCTAssertEqual(pass1.count, 1)
        XCTAssertEqual(pass1[0].dayKey, "2026-11-26")
        XCTAssertEqual(pass1[0].hour, 23)
        XCTAssertEqual(pass1[0].requests, 1)

        // Message completes across midnight on 2026-11-27T00:00:02Z with final tokens.
        try executeSQL(at: dbURL, statements: [
            """
            UPDATE message
            SET time_updated = 1795737602000,
                data = '{"role":"assistant","modelID":"kimi-k2","time":{"created":1795737599000,"completed":1795737602000},"tokens":{"input":100,"output":80,"reasoning":20,"cache":{"read":50,"write":0}}}'
            WHERE id = 'msg_mid';
            """
        ])
        bumpMtime(of: dbURL, by: 2)

        let pass2 = try source.refresh(state: &state, calendar: utcCalendar)
        XCTAssertEqual(pass2.count, 1)
        let bucket = try XCTUnwrap(pass2.first)
        XCTAssertEqual(bucket.dayKey, "2026-11-27")
        XCTAssertEqual(bucket.hour, 0)
        XCTAssertEqual(bucket.inputTokens, 100)
        XCTAssertEqual(bucket.outputTokens, 100)
        XCTAssertEqual(bucket.cacheTokens, 50)
        XCTAssertEqual(bucket.requests, 1)
    }

    // MARK: - 11. Malformed Codex Event Does Not Suppress Valid Repeat (Defect 3)

    func testCodexMalformedTimestampDoesNotSuppressValidRepeat() throws {
        let dir = try makeTempDir(prefix: "codex-bad-ts")
        let rolloutURL = dir.appendingPathComponent("rollout-2026-11-26-ts.jsonl")

        let content = """
        {"timestamp":"2026-11-26T14:00:00Z","type":"turn_context","payload":{"model":"gpt-5-codex"}}
        {"timestamp":"not-a-timestamp","type":"event_msg","payload":{"type":"token_count","info":{"model":"wrong-model","total_token_usage":{"input_tokens":8000,"cached_input_tokens":3000,"output_tokens":400,"total_tokens":8400},"last_token_usage":{"input_tokens":8000,"cached_input_tokens":3000,"output_tokens":400,"total_tokens":8400}}}}
        {"timestamp":"2026-11-26T14:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":8000,"cached_input_tokens":3000,"output_tokens":400,"total_tokens":8400},"last_token_usage":{"input_tokens":8000,"cached_input_tokens":3000,"output_tokens":400,"total_tokens":8400}}}}
        {"timestamp":"2026-11-26T14:05:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":8000,"cached_input_tokens":3000,"output_tokens":400,"total_tokens":8400},"last_token_usage":{"input_tokens":8000,"cached_input_tokens":3000,"output_tokens":400,"total_tokens":8400}}}}

        """
        try content.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let source = CodexCLITokenLogSource(rootDirectory: dir)
        var state = SourceCacheState()
        let buckets = try source.refresh(state: &state, calendar: utcCalendar)

        // Valid repeat after malformed timestamp MUST be counted (with original model, not 'wrong-model'),
        // and the subsequent genuine duplicate MUST still be skipped.
        XCTAssertEqual(buckets.count, 1)
        let bucket = try XCTUnwrap(buckets.first)
        XCTAssertEqual(bucket.model, "gpt-5-codex")
        XCTAssertEqual(bucket.hour, 14)
        XCTAssertEqual(bucket.inputTokens, 5000)
        XCTAssertEqual(bucket.outputTokens, 400)
        XCTAssertEqual(bucket.cacheTokens, 3000)
        XCTAssertEqual(bucket.requests, 1)
    }

    // MARK: - 12. Overflow & Unrepresentable Count Protection (Defect 4)

    func testParsersRejectOverflowingAndUnrepresentableCountsWithoutTrapping() throws {
        // 1) Claude: Int.max cache_read + 1 cache_creation, huge >Int.max, negative, plus valid sibling record.
        let claudeDir = try makeTempDir(prefix: "claude-overflow")
        let claudeProj = claudeDir.appendingPathComponent("p", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeProj, withIntermediateDirectories: true)
        let claudeLog = """
        {"type":"assistant","requestId":"ovf1","timestamp":"2026-11-26T10:00:00Z","message":{"id":"m_ovf1","model":"claude-opus-4-5-20251101","usage":{"input_tokens":10,"output_tokens":10,"cache_creation_input_tokens":1,"cache_read_input_tokens":\(Int.max)}}}
        {"type":"assistant","requestId":"ovf2","timestamp":"2026-11-26T10:01:00Z","message":{"id":"m_ovf2","model":"claude-opus-4-5-20251101","usage":{"input_tokens":999999999999999999999999999,"output_tokens":10}}}
        {"type":"assistant","requestId":"ovf3","timestamp":"2026-11-26T10:02:00Z","message":{"id":"m_ovf3","model":"claude-opus-4-5-20251101","usage":{"input_tokens":-50,"output_tokens":10}}}
        {"type":"assistant","requestId":"ok1","timestamp":"2026-11-26T10:03:00Z","message":{"id":"m_ok1","model":"claude-opus-4-5-20251101","usage":{"input_tokens":120,"output_tokens":30,"cache_creation_input_tokens":10,"cache_read_input_tokens":40}}}

        """
        try claudeLog.write(to: claudeProj.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)
        let claudeSource = ClaudeCodeTokenLogSource(rootDirectory: claudeDir)
        var claudeState = SourceCacheState()
        let claudeBuckets = try claudeSource.refresh(state: &claudeState, calendar: utcCalendar)
        XCTAssertEqual(claudeBuckets.count, 1)
        XCTAssertEqual(claudeBuckets[0].inputTokens, 120)
        XCTAssertEqual(claudeBuckets[0].outputTokens, 30)
        XCTAssertEqual(claudeBuckets[0].cacheTokens, 50)
        XCTAssertEqual(claudeBuckets[0].requests, 1)

        // 2) Codex: overflowing cached_input + cache_write followed by valid event.
        let codexDir = try makeTempDir(prefix: "codex-overflow")
        let codexLog = """
        {"timestamp":"2026-11-26T10:00:00Z","type":"turn_context","payload":{"model":"gpt-5-codex"}}
        {"timestamp":"2026-11-26T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\(Int.max),"cached_input_tokens":\(Int.max),"cache_write_input_tokens":1,"output_tokens":10,"total_tokens":\(Int.max)}}}}
        {"timestamp":"2026-11-26T10:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":500,"cached_input_tokens":100,"output_tokens":50,"total_tokens":550},"last_token_usage":{"input_tokens":500,"cached_input_tokens":100,"output_tokens":50,"total_tokens":550}}}}

        """
        try codexLog.write(to: codexDir.appendingPathComponent("rollout-ovf.jsonl"), atomically: true, encoding: .utf8)
        let codexSource = CodexCLITokenLogSource(rootDirectory: codexDir)
        var codexState = SourceCacheState()
        let codexBuckets = try codexSource.refresh(state: &codexState, calendar: utcCalendar)
        XCTAssertEqual(codexBuckets.count, 1)
        XCTAssertEqual(codexBuckets[0].inputTokens, 400)
        XCTAssertEqual(codexBuckets[0].outputTokens, 50)
        XCTAssertEqual(codexBuckets[0].cacheTokens, 100)
        XCTAssertEqual(codexBuckets[0].requests, 1)

        // 3) Gemini: overflowing output + thoughts, >Int.max, negative, alongside valid message.
        let geminiDir = try makeTempDir(prefix: "gemini-overflow")
        let geminiChats = geminiDir.appendingPathComponent("hash/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: geminiChats, withIntermediateDirectories: true)
        let geminiJSON = """
        {
          "sessionId": "ovf",
          "messages": [
            {"id":"g1","timestamp":"2026-11-26T10:00:00Z","model":"gemini-2.5-pro","tokens":{"input":10,"output":\(Int.max),"cached":0,"thoughts":1,"tool":0}},
            {"id":"g2","timestamp":"2026-11-26T10:01:00Z","model":"gemini-2.5-pro","tokens":{"input":999999999999999999999999,"output":10,"cached":0,"thoughts":0,"tool":0}},
            {"id":"g3","timestamp":"2026-11-26T10:02:00Z","model":"gemini-2.5-pro","tokens":{"input":300,"output":40,"cached":100,"thoughts":10,"tool":5}}
          ]
        }
        """
        try geminiJSON.write(to: geminiChats.appendingPathComponent("session-ovf.json"), atomically: true, encoding: .utf8)
        let geminiSource = GeminiCLITokenLogSource(rootDirectory: geminiDir)
        var geminiState = SourceCacheState()
        let geminiBuckets = try geminiSource.refresh(state: &geminiState, calendar: utcCalendar)
        XCTAssertEqual(geminiBuckets.count, 1)
        XCTAssertEqual(geminiBuckets[0].inputTokens, 200)
        XCTAssertEqual(geminiBuckets[0].outputTokens, 55)
        XCTAssertEqual(geminiBuckets[0].cacheTokens, 100)
        XCTAssertEqual(geminiBuckets[0].requests, 1)

        // 4) OpenCode: overflowing output + reasoning alongside valid message.
        let ocDir = try makeTempDir(prefix: "opencode-overflow")
        let ocMsgDir = ocDir.appendingPathComponent("storage/message/ses", isDirectory: true)
        try FileManager.default.createDirectory(at: ocMsgDir, withIntermediateDirectories: true)
        let ocBad = """
        {"id":"oc_bad","role":"assistant","modelID":"kimi-k2","time":{"created":1795701600000},"tokens":{"input":10,"output":\(Int.max),"reasoning":1,"cache":{"read":0,"write":0}}}
        """
        let ocGood = """
        {"id":"oc_good","role":"assistant","modelID":"kimi-k2","time":{"created":1795701600000},"tokens":{"input":80,"output":20,"reasoning":5,"cache":{"read":15,"write":5}}}
        """
        try ocBad.write(to: ocMsgDir.appendingPathComponent("oc_bad.json"), atomically: true, encoding: .utf8)
        try ocGood.write(to: ocMsgDir.appendingPathComponent("oc_good.json"), atomically: true, encoding: .utf8)
        let ocSource = OpenCodeTokenLogSource(rootDirectory: ocDir)
        var ocState = SourceCacheState()
        let ocBuckets = try ocSource.refresh(state: &ocState, calendar: utcCalendar)
        XCTAssertEqual(ocBuckets.count, 1)
        XCTAssertEqual(ocBuckets[0].inputTokens, 80)
        XCTAssertEqual(ocBuckets[0].outputTokens, 25)
        XCTAssertEqual(ocBuckets[0].cacheTokens, 20)
        XCTAssertEqual(ocBuckets[0].requests, 1)
    }

    func testTokenBucketAccumulatorRejectsOverflowWithoutPartialUpdate() throws {
        var accumulator = TokenBucketAccumulator()
        let ok = accumulator.add(
            dayKey: "2026-11-26",
            hour: 10,
            provider: .claude,
            model: "claude-opus-4-5-20251101",
            inputTokens: Int.max - 10,
            outputTokens: 5,
            cacheTokens: 0,
            requests: 1
        )
        XCTAssertTrue(ok)

        // Field overflow on inputTokens must fail atomically without mutating outputTokens, cacheTokens, or requests.
        let fieldOverflow = accumulator.add(
            dayKey: "2026-11-26",
            hour: 10,
            provider: .claude,
            model: "claude-opus-4-5-20251101",
            inputTokens: 20,
            outputTokens: 1,
            cacheTokens: 2,
            requests: 1
        )
        XCTAssertFalse(fieldOverflow)

        // Combined total (input + output + cache) overflow must also fail atomically.
        let totalOverflow = accumulator.add(
            dayKey: "2026-11-26",
            hour: 10,
            provider: .claude,
            model: "claude-opus-4-5-20251101",
            inputTokens: 0,
            outputTokens: 10,
            cacheTokens: 0,
            requests: 1
        )
        XCTAssertFalse(totalOverflow)

        let buckets = accumulator.buckets()
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets[0].inputTokens, Int.max - 10)
        XCTAssertEqual(buckets[0].outputTokens, 5)
        XCTAssertEqual(buckets[0].cacheTokens, 0)
        XCTAssertEqual(buckets[0].requests, 1)

        // Atomic replace that would overflow destination bucket leaves BOTH source and destination untouched.
        XCTAssertTrue(accumulator.add(
            dayKey: "2026-11-26",
            hour: 9,
            provider: .claude,
            model: "claude-opus-4-5-20251101",
            inputTokens: 100,
            outputTokens: 20,
            cacheTokens: 10,
            requests: 1
        ))
        let replaceOverflow = accumulator.replace(
            previous: CountedUsageSnapshot(
                dayKey: "2026-11-26",
                hour: 9,
                model: "claude-opus-4-5-20251101",
                inputTokens: 100,
                outputTokens: 20,
                cacheTokens: 10
            ),
            with: CountedUsageSnapshot(
                dayKey: "2026-11-26",
                hour: 10,
                model: "claude-opus-4-5-20251101",
                inputTokens: 200,
                outputTokens: 20,
                cacheTokens: 10
            ),
            provider: .claude
        )
        XCTAssertFalse(replaceOverflow)

        let afterReplace = accumulator.buckets()
        XCTAssertEqual(afterReplace.count, 2)
        let h9 = try XCTUnwrap(afterReplace.first { $0.hour == 9 })
        let h10 = try XCTUnwrap(afterReplace.first { $0.hour == 10 })
        XCTAssertEqual(h9.inputTokens, 100)
        XCTAssertEqual(h9.requests, 1)
        XCTAssertEqual(h10.inputTokens, Int.max - 10)
        XCTAssertEqual(h10.requests, 1)
    }

    // MARK: - 13. Gemini Streaming Parser Large-Session Fixture (Defect 5)

    func testGeminiStreamingParserHandlesLargeSessionWithBoundedChunks() throws {
        let dir = try makeTempDir(prefix: "gemini-large")
        let chatsDir = dir.appendingPathComponent("large-hash/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)
        let sessionURL = chatsDir.appendingPathComponent("session-2026-11-26-large.json")

        // Generate a >4 MB synthetic Gemini session with large prompt/response bodies,
        // escaped quotes, backslashes, unicode escapes, and nested toolCalls arrays.
        let largeBody = String(repeating: #"Line with \"quotes\", \\backslashes\\, and unicode \u2014 payload. "#, count: 4000)
        var json = #"{"sessionId":"large-session","projectHash":"hash","messages":["#
        let messageCount = 12
        for i in 0..<messageCount {
            if i > 0 { json.append(",") }
            let hour = 10 + (i % 2)
            let model = (i % 2 == 0) ? "gemini-2.5-pro" : "gemini-2.5-flash"
            // Interleave user message with huge content and model message with huge content + toolCalls + tokens.
            json.append("""
            {"id":"u-\(i)","timestamp":"2026-11-26T\(String(format: "%02d", hour)):00:00.000Z","type":"user","content":"\(largeBody)"},
            {"id":"m-\(i)","timestamp":"2026-11-26T\(String(format: "%02d", hour)):05:00.000Z","type":"gemini","model":"\(model)","content":"\(largeBody)","toolCalls":[{"name":"read_file","args":{"path":"demo","blob":"\(largeBody.prefix(4096))"}}],"tokens":{"input":1000,"output":150,"cached":400,"thoughts":30,"tool":20,"total":1200}}
            """)
        }
        // Append a duplicate ID of m-0 to verify deduplication persists while streaming.
        json.append("""
        ,{"id":"m-0","timestamp":"2026-11-26T10:05:00.000Z","type":"gemini","model":"gemini-2.5-pro","content":"dup","tokens":{"input":1000,"output":150,"cached":400,"thoughts":30,"tool":20,"total":1200}}
        ],"metadata":{"tail":"ok"}}
        """)

        let payloadData = Data(json.utf8)
        XCTAssertGreaterThan(payloadData.count, 4 * 1024 * 1024, "Large-session fixture should exceed 4 MB")
        try payloadData.write(to: sessionURL)

        // Force tiny 1 KB chunk buffer (4000x smaller than the file) to verify streaming across chunk boundaries.
        let source = GeminiCLITokenLogSource(rootDirectory: dir, streamChunkSize: 1024)
        var state = SourceCacheState()
        let buckets = try source.refresh(state: &state, calendar: utcCalendar)

        XCTAssertEqual(buckets.count, 2)
        let pro = try XCTUnwrap(buckets.first { $0.model == "gemini-2.5-pro" })
        let flash = try XCTUnwrap(buckets.first { $0.model == "gemini-2.5-flash" })
        // 6 unique messages per model: input=(1000-400)=600, output=(150+30+20)=200, cache=400
        XCTAssertEqual(pro.hour, 10)
        XCTAssertEqual(pro.requests, 6)
        XCTAssertEqual(pro.inputTokens, 3600)
        XCTAssertEqual(pro.outputTokens, 1200)
        XCTAssertEqual(pro.cacheTokens, 2400)

        XCTAssertEqual(flash.hour, 11)
        XCTAssertEqual(flash.requests, 6)
        XCTAssertEqual(flash.inputTokens, 3600)
        XCTAssertEqual(flash.outputTokens, 1200)
        XCTAssertEqual(flash.cacheTokens, 2400)

        // Also verify a truncated large session is rejected cleanly without emitting partial buckets.
        let truncatedURL = chatsDir.appendingPathComponent("session-2026-11-26-truncated.json")
        try payloadData.prefix(payloadData.count / 2).write(to: truncatedURL)
        let afterTruncated = try source.refresh(state: &state, calendar: utcCalendar)
        XCTAssertEqual(afterTruncated, buckets)
    }

    // MARK: - 14. DirectoryWatcher Retry, Deterministic Debounce & FSEvents Integration (Defect 7)

    func testDirectoryWatcherDeterministicBurstYieldsExactlyOneCallback() throws {
        let dir = try makeTempDir(prefix: "watcher-burst")
        let backend = FakeDirectoryWatchBackend()
        let scheduler = ManualDirectoryWatchScheduler()
        let callbackCounter = LockedCounter()

        let watcher = DirectoryWatcher(
            debounceInterval: 0.75,
            backend: backend,
            scheduler: scheduler
        ) {
            callbackCounter.increment()
        }
        defer { watcher.stop() }

        XCTAssertTrue(watcher.watch(directories: [dir]))
        XCTAssertTrue(watcher.isWatching)
        XCTAssertEqual(backend.startCallCount, 1)

        // Burst of 5 events spaced 0.20s apart (each resets the 0.75s trailing debounce timer).
        for i in 0..<5 {
            backend.emitEvent()
            if i < 4 {
                scheduler.advance(by: 0.20)
            }
        }
        // At 0.74s after the final event in the burst, callback must NOT have fired yet.
        scheduler.advance(by: 0.74)
        XCTAssertEqual(callbackCounter.value, 0)

        // Crossing 0.75s fires EXACTLY ONE callback for the entire burst.
        scheduler.advance(by: 0.02)
        XCTAssertEqual(callbackCounter.value, 1)

        // Further idle time produces no extra callbacks.
        scheduler.advance(by: 5.0)
        XCTAssertEqual(callbackCounter.value, 1)

        // A second distinct burst yields a second single callback.
        backend.emitEvent()
        scheduler.advance(by: 0.10)
        backend.emitEvent()
        scheduler.advance(by: 0.75)
        XCTAssertEqual(callbackCounter.value, 2)
    }

    func testDirectoryWatcherRetriesAfterFailedStart() throws {
        let dir = try makeTempDir(prefix: "watcher-retry")
        let backend = FakeDirectoryWatchBackend()
        let scheduler = ManualDirectoryWatchScheduler()
        let callbackCounter = LockedCounter()

        backend.shouldFailStart = true

        let watcher = DirectoryWatcher(
            debounceInterval: 0.5,
            backend: backend,
            scheduler: scheduler
        ) {
            callbackCounter.increment()
        }
        defer { watcher.stop() }

        // First startup fails: watch returns false, isWatching is false, paths are NOT recorded as active.
        XCTAssertFalse(watcher.watch(directories: [dir]))
        XCTAssertFalse(watcher.isWatching)
        XCTAssertEqual(backend.startCallCount, 1)

        // Retry with the EXACT SAME directory list once backend can start: must NOT short-circuit!
        backend.shouldFailStart = false
        XCTAssertTrue(watcher.watch(directories: [dir]))
        XCTAssertTrue(watcher.isWatching)
        XCTAssertEqual(backend.startCallCount, 2)

        // Subsequent call with identical active paths now short-circuits cleanly.
        XCTAssertTrue(watcher.watch(directories: [dir]))
        XCTAssertEqual(backend.startCallCount, 2)

        // Events on the retried session deliver normally after debounce.
        backend.emitEvent()
        scheduler.advance(by: 0.5)
        XCTAssertEqual(callbackCounter.value, 1)
    }

    func testDirectoryWatcherStopCancelsPendingDebouncedCallback() throws {
        let dir = try makeTempDir(prefix: "watcher-stop")
        let backend = FakeDirectoryWatchBackend()
        let scheduler = ManualDirectoryWatchScheduler()
        let callbackCounter = LockedCounter()

        let watcher = DirectoryWatcher(
            debounceInterval: 0.5,
            backend: backend,
            scheduler: scheduler
        ) {
            callbackCounter.increment()
        }

        XCTAssertTrue(watcher.watch(directories: [dir]))
        backend.emitEvent()
        scheduler.advance(by: 0.25)
        watcher.stop()
        XCTAssertFalse(watcher.isWatching)
        XCTAssertEqual(backend.invalidatedCount, 1)

        scheduler.advance(by: 2.0)
        XCTAssertEqual(callbackCounter.value, 0)
    }

    func testDirectoryWatcherFSEventsIntegrationBurstYieldsExactlyOneCallback() throws {
        let dir = try makeTempDir(prefix: "watcher-fsevents")
        let callbackCounter = LockedCounter()
        let firstCallback = expectation(description: "FSEvents debounced callback fires once")

        let watcher = DirectoryWatcher(debounceInterval: 0.30) {
            if callbackCounter.increment() == 1 {
                firstCallback.fulfill()
            }
        }
        defer { watcher.stop() }

        guard watcher.watch(directories: [dir]) else {
            throw XCTSkip("FSEvents stream could not start in this sandbox environment")
        }

        // Write a rapid burst of 5 updates well within the 0.25s debounce interval.
        let fileURL = dir.appendingPathComponent("log.jsonl")
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.05) {
            for i in 1...5 {
                try? "line\(i)\n".write(to: fileURL, atomically: false, encoding: .utf8)
            }
        }

        wait(for: [firstCallback], timeout: 3.0)
        // Wait past another debounce interval to ensure the burst produced exactly one callback.
        Thread.sleep(forTimeInterval: 0.45)
        XCTAssertEqual(callbackCounter.value, 1)
    }

    // MARK: - 15. Round 3 Regressions (Defects 1–8 & Property-Style Incremental == Fresh Tests)

    func testClaudeAndCodexMultiKilobyteEqualLengthRewriteBetweenWindows() throws {
        // Defect 1: Build multi-kilobyte (>8 KB) files and mutate a count from 100 -> 900 squarely
        // between the old 256-byte head/mid/tail windows, preserving inode, exact byte size, and mtime.
        let claudeDir = try makeTempDir(prefix: "claude-multikb")
        let projDir = claudeDir.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)
        let claudeURL = projDir.appendingPathComponent("session.jsonl")

        let padLine = #"{"type":"user","timestamp":"2026-11-26T10:00:00Z","content":""# + String(repeating: "x", count: 400) + #"\"}"# + "\n"
        let claudeBefore = (0..<4).map { _ in padLine }.joined()
            + #"{"type":"assistant","requestId":"r_mid","timestamp":"2026-11-26T10:05:00Z","message":{"id":"m_mid","model":"claude-opus-4-5-20251101","usage":{"input_tokens":100,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"# + "\n"
            + (0..<16).map { _ in padLine }.joined()
        let claudeAfter = claudeBefore.replacingOccurrences(of: #""input_tokens":100"#, with: #""input_tokens":900"#)
        XCTAssertGreaterThan(claudeBefore.utf8.count, 8 * 1024)
        XCTAssertEqual(claudeBefore.utf8.count, claudeAfter.utf8.count)

        try claudeBefore.write(to: claudeURL, atomically: false, encoding: .utf8)
        let claudeMeta1 = try XCTUnwrap(FileMetadata.read(at: claudeURL))
        let originalModDate = (try FileManager.default.attributesOfItem(atPath: claudeURL.path)[.modificationDate]) as? Date

        let claudeSource = ClaudeCodeTokenLogSource(rootDirectory: claudeDir)
        var claudeState = SourceCacheState()
        let claudePass1 = try claudeSource.refresh(state: &claudeState, calendar: utcCalendar)
        XCTAssertEqual(TokenSummary.aggregate(claudePass1).totalTokens, 100)

        try overwriteInPlace(url: claudeURL, content: claudeAfter)
        if let originalModDate {
            try FileManager.default.setAttributes([.modificationDate: originalModDate], ofItemAtPath: claudeURL.path)
        }
        let claudeMeta2 = try XCTUnwrap(FileMetadata.read(at: claudeURL))
        XCTAssertEqual(claudeMeta2.inode, claudeMeta1.inode)
        XCTAssertEqual(claudeMeta2.size, claudeMeta1.size)

        let claudePass2 = try claudeSource.refresh(state: &claudeState, calendar: utcCalendar)
        var claudeFreshState = SourceCacheState()
        let claudeFresh = try claudeSource.refresh(state: &claudeFreshState, calendar: utcCalendar)
        XCTAssertEqual(TokenSummary.aggregate(claudePass2).totalTokens, 900)
        XCTAssertEqual(claudePass2, claudeFresh)

        // Same multi-KB equal-length rewrite regression for Codex CLI.
        let codexDir = try makeTempDir(prefix: "codex-multikb")
        let codexURL = codexDir.appendingPathComponent("rollout-2026-11-26-multikb.jsonl")

        let codexPad = #"{"timestamp":"2026-11-26T10:00:00Z","type":"response_item","payload":{"text":""# + String(repeating: "y", count: 400) + #""}}"# + "\n"
        let codexBefore = #"{"timestamp":"2026-11-26T10:00:00Z","type":"turn_context","payload":{"model":"gpt-5-codex"}}"# + "\n"
            + (0..<4).map { _ in codexPad }.joined()
            + #"{"timestamp":"2026-11-26T10:05:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}"# + "\n"
            + (0..<16).map { _ in codexPad }.joined()
        let codexAfter = codexBefore
            .replacingOccurrences(of: #""input_tokens":100"#, with: #""input_tokens":900"#)
            .replacingOccurrences(of: #""total_tokens":100"#, with: #""total_tokens":900"#)
        XCTAssertGreaterThan(codexBefore.utf8.count, 8 * 1024)
        XCTAssertEqual(codexBefore.utf8.count, codexAfter.utf8.count)

        try codexBefore.write(to: codexURL, atomically: false, encoding: .utf8)
        let codexMeta1 = try XCTUnwrap(FileMetadata.read(at: codexURL))
        let codexModDate = (try FileManager.default.attributesOfItem(atPath: codexURL.path)[.modificationDate]) as? Date

        let codexSource = CodexCLITokenLogSource(rootDirectory: codexDir)
        var codexState = SourceCacheState()
        let codexPass1 = try codexSource.refresh(state: &codexState, calendar: utcCalendar)
        XCTAssertEqual(TokenSummary.aggregate(codexPass1).totalTokens, 100)

        try overwriteInPlace(url: codexURL, content: codexAfter)
        if let codexModDate {
            try FileManager.default.setAttributes([.modificationDate: codexModDate], ofItemAtPath: codexURL.path)
        }
        let codexMeta2 = try XCTUnwrap(FileMetadata.read(at: codexURL))
        XCTAssertEqual(codexMeta2.inode, codexMeta1.inode)
        XCTAssertEqual(codexMeta2.size, codexMeta1.size)

        let codexPass2 = try codexSource.refresh(state: &codexState, calendar: utcCalendar)
        var codexFreshState = SourceCacheState()
        let codexFresh = try codexSource.refresh(state: &codexFreshState, calendar: utcCalendar)
        XCTAssertEqual(TokenSummary.aggregate(codexPass2).totalTokens, 900)
        XCTAssertEqual(codexPass2, codexFresh)
    }

    func testStrictISO8601CalendarDatesAndCodexImpossibleDateDoesNotSuppressValidRepeat() throws {
        // Defect 3: Impossible calendar dates must be rejected instead of normalized by timegm.
        XCTAssertNil(LogTimestampParser.parseISO8601("2026-02-31T10:00:00Z"))
        XCTAssertNil(LogTimestampParser.parseISO8601("2026-02-29T10:00:00Z")) // non-leap year
        XCTAssertNil(LogTimestampParser.parseISO8601("1900-02-29T10:00:00Z")) // century non-leap year
        XCTAssertNil(LogTimestampParser.parseISO8601("2026-04-31T10:00:00Z"))
        XCTAssertNil(LogTimestampParser.parseISO8601("2026-06-31T10:00:00Z"))
        XCTAssertNil(LogTimestampParser.parseISO8601("2026-00-10T10:00:00Z"))
        XCTAssertNil(LogTimestampParser.parseISO8601("2026-13-01T10:00:00Z"))
        XCTAssertNil(LogTimestampParser.parseISO8601("2026-02-28T10:00:00+05:")) // dangling timezone colon
        XCTAssertNotNil(LogTimestampParser.parseISO8601("2024-02-29T10:00:00Z")) // leap year
        XCTAssertNotNil(LogTimestampParser.parseISO8601("2000-02-29T10:00:00Z")) // 400-year leap year
        XCTAssertNotNil(LogTimestampParser.parseISO8601("2026-02-28T10:00:00Z"))

        let dir = try makeTempDir(prefix: "codex-feb31")
        let rolloutURL = dir.appendingPathComponent("rollout-2026-02-28-strict.jsonl")
        let content = """
        {"timestamp":"2026-02-28T09:00:00Z","type":"turn_context","payload":{"model":"gpt-5-codex"}}
        {"timestamp":"2026-02-31T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":500,"cached_input_tokens":100,"output_tokens":50,"total_tokens":550},"last_token_usage":{"input_tokens":500,"cached_input_tokens":100,"output_tokens":50,"total_tokens":550}}}}
        {"timestamp":"2026-02-28T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":500,"cached_input_tokens":100,"output_tokens":50,"total_tokens":550},"last_token_usage":{"input_tokens":500,"cached_input_tokens":100,"output_tokens":50,"total_tokens":550}}}}

        """
        try content.write(to: rolloutURL, atomically: true, encoding: .utf8)

        let source = CodexCLITokenLogSource(rootDirectory: dir)
        var state = SourceCacheState()
        let buckets = try source.refresh(state: &state, calendar: utcCalendar)

        // Must produce exactly one 2026-02-28 bucket (never normalized to 2026-03-03).
        XCTAssertEqual(buckets.count, 1)
        let bucket = try XCTUnwrap(buckets.first)
        XCTAssertEqual(bucket.dayKey, "2026-02-28")
        XCTAssertEqual(bucket.hour, 10)
        XCTAssertEqual(bucket.inputTokens, 400)
        XCTAssertEqual(bucket.outputTokens, 50)
        XCTAssertEqual(bucket.cacheTokens, 100)
        XCTAssertEqual(bucket.requests, 1)
    }

    func testGeminiMalformedMessageDoesNotSuppressValidMessageWithSameID() throws {
        // Defect 5: Invalid timestamp, impossible date, or invalid/zero counts with message ID `m1`
        // must NOT record `m1` in seenMessageIDs before accumulation succeeds.
        let dir = try makeTempDir(prefix: "gemini-malformed-id")
        let chatsDir = dir.appendingPathComponent("h/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)

        let json = """
        {
          "sessionId": "s1",
          "messages": [
            {"id":"m1","timestamp":"not-a-timestamp","type":"gemini","model":"gemini-2.5-pro","tokens":{"input":50,"output":10,"cached":0,"thoughts":0,"tool":0}},
            {"id":"m1","timestamp":"2026-02-31T10:00:00Z","type":"gemini","model":"gemini-2.5-pro","tokens":{"input":50,"output":10,"cached":0,"thoughts":0,"tool":0}},
            {"id":"m1","timestamp":"2026-11-26T12:00:00Z","type":"gemini","model":"gemini-2.5-pro","tokens":{"input":5,"output":2,"cached":0,"thoughts":0,"tool":0}},
            {"id":"m1","timestamp":"2026-11-26T12:00:00Z","type":"gemini","model":"gemini-2.5-pro","tokens":{"input":99,"output":1,"cached":0,"thoughts":0,"tool":0}}
          ]
        }
        """
        try json.write(to: chatsDir.appendingPathComponent("session-2026-11-26-dup.json"), atomically: true, encoding: .utf8)

        let source = GeminiCLITokenLogSource(rootDirectory: dir)
        var state = SourceCacheState()
        let buckets = try source.refresh(state: &state, calendar: utcCalendar)

        // First valid m1 yields 7 tokens and 1 request; subsequent genuine duplicate m1 is skipped.
        XCTAssertEqual(buckets.count, 1)
        let bucket = try XCTUnwrap(buckets.first)
        XCTAssertEqual(bucket.totalTokens, 7)
        XCTAssertEqual(bucket.inputTokens, 5)
        XCTAssertEqual(bucket.outputTokens, 2)
        XCTAssertEqual(bucket.requests, 1)
    }

    func testJSONBooleansAndInvalidNumbersRejectedBySharedParserAndAllSources() throws {
        // Defect 6: JSON `true` / `false` must be rejected BEFORE any `as? Int` bridge runs.
        let rawJSON = #"{"t":true,"f":false,"str":"10","frac":1.5,"neg":-1,"over":1000000000001,"ok":42,"nul":null}"#
        let parsed = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(rawJSON.utf8)) as? [String: Any])

        XCTAssertNil(CheckedTokenMath.parseNonNegativeInt(parsed["t"]))
        XCTAssertNil(CheckedTokenMath.parseNonNegativeInt(parsed["f"]))
        XCTAssertNil(CheckedTokenMath.parseNonNegativeInt(true))
        XCTAssertNil(CheckedTokenMath.parseNonNegativeInt(false))
        XCTAssertNil(CheckedTokenMath.parseNonNegativeInt(parsed["str"]))
        XCTAssertNil(CheckedTokenMath.parseNonNegativeInt(parsed["frac"]))
        XCTAssertNil(CheckedTokenMath.parseNonNegativeInt(parsed["neg"]))
        XCTAssertNil(CheckedTokenMath.parseNonNegativeInt(parsed["over"]))
        XCTAssertEqual(CheckedTokenMath.parseNonNegativeInt(parsed["ok"]), 42)
        XCTAssertEqual(CheckedTokenMath.parseNonNegativeInt(parsed["nul"]), 0)
        XCTAssertEqual(CheckedTokenMath.parseNonNegativeInt(nil), 0)
        XCTAssertNil(CheckedTokenMath.parseNonNegativeInt(asciiDigits: Array("1000000000001".utf8)))
        XCTAssertEqual(CheckedTokenMath.parseNonNegativeInt(asciiDigits: Array("1000000000000".utf8)), 1_000_000_000_000)

        // Verify a boolean counter contributes neither tokens nor a request across ALL 4 parsers:
        // 1) Claude
        let claudeDir = try makeTempDir(prefix: "claude-bool")
        let claudeProj = claudeDir.appendingPathComponent("p", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeProj, withIntermediateDirectories: true)
        try """
        {"type":"assistant","requestId":"r_bool","timestamp":"2026-11-26T10:00:00Z","message":{"id":"m_bool","model":"claude-opus-4-5-20251101","usage":{"input_tokens":true,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        {"type":"assistant","requestId":"r_bool2","timestamp":"2026-11-26T10:01:00Z","message":{"id":"m_bool2","model":"claude-opus-4-5-20251101","usage":{"input_tokens":10,"output_tokens":false}}}

        """.write(to: claudeProj.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)
        var claudeState = SourceCacheState()
        XCTAssertTrue(try ClaudeCodeTokenLogSource(rootDirectory: claudeDir).refresh(state: &claudeState, calendar: utcCalendar).isEmpty)

        // 2) Codex
        let codexDir = try makeTempDir(prefix: "codex-bool")
        try """
        {"timestamp":"2026-11-26T10:00:00Z","type":"turn_context","payload":{"model":"gpt-5-codex"}}
        {"timestamp":"2026-11-26T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":true,"cached_input_tokens":0,"output_tokens":0,"total_tokens":1}}}}

        """.write(to: codexDir.appendingPathComponent("rollout-bool.jsonl"), atomically: true, encoding: .utf8)
        var codexState = SourceCacheState()
        XCTAssertTrue(try CodexCLITokenLogSource(rootDirectory: codexDir).refresh(state: &codexState, calendar: utcCalendar).isEmpty)

        // 3) Gemini
        let geminiDir = try makeTempDir(prefix: "gemini-bool")
        let geminiChats = geminiDir.appendingPathComponent("h/chats", isDirectory: true)
        try FileManager.default.createDirectory(at: geminiChats, withIntermediateDirectories: true)
        try """
        {"sessionId":"s","messages":[{"id":"gb","timestamp":"2026-11-26T10:00:00Z","model":"gemini-2.5-pro","tokens":{"input":true,"output":5,"cached":0,"thoughts":0,"tool":0}}]}
        """.write(to: geminiChats.appendingPathComponent("session-bool.json"), atomically: true, encoding: .utf8)
        var geminiState = SourceCacheState()
        XCTAssertTrue(try GeminiCLITokenLogSource(rootDirectory: geminiDir).refresh(state: &geminiState, calendar: utcCalendar).isEmpty)

        // 4) OpenCode
        let ocDir = try makeTempDir(prefix: "opencode-bool")
        let ocMsgDir = ocDir.appendingPathComponent("storage/message/ses", isDirectory: true)
        try FileManager.default.createDirectory(at: ocMsgDir, withIntermediateDirectories: true)
        try """
        {"id":"oc_bool","role":"assistant","modelID":"kimi-k2","time":{"created":1795701600000},"tokens":{"input":true,"output":5,"reasoning":0,"cache":{"read":0,"write":0}}}
        """.write(to: ocMsgDir.appendingPathComponent("oc_bool.json"), atomically: true, encoding: .utf8)
        var ocState = SourceCacheState()
        XCTAssertTrue(try OpenCodeTokenLogSource(rootDirectory: ocDir).refresh(state: &ocState, calendar: utcCalendar).isEmpty)
    }

    func testOpenCodeDeletionsAndDatabaseRemovalMatchFreshScan() throws {
        // Defect 7: Probe 1 (SQLite row deletion) & Probe 2 (DB removal with surviving legacy JSON).
        let dir = try makeTempDir(prefix: "opencode-deletions")
        let dbURL = dir.appendingPathComponent("opencode.db")
        let legacyDir = dir.appendingPathComponent("storage/message/ses_1", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)

        func assertIncrementalMatchesFresh(_ source: OpenCodeTokenLogSource, incremental: [TokenBucket], expectedTokens: Int) throws {
            var freshState = SourceCacheState()
            let fresh = try source.refresh(state: &freshState, calendar: utcCalendar)
            XCTAssertEqual(incremental, fresh)
            XCTAssertEqual(TokenSummary.aggregate(incremental).totalTokens, expectedTokens)
        }

        // Probe 1: SQLite-only message (15 tokens) -> delete row -> 0 tokens incrementally & fresh.
        try executeSQL(at: dbURL, statements: [
            """
            CREATE TABLE message (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                time_created INTEGER NOT NULL,
                time_updated INTEGER NOT NULL,
                data TEXT NOT NULL
            );
            """,
            """
            INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES
            ('msg_del', 'ses_1', 1795701600000, 1795701605000, '{"role":"assistant","modelID":"kimi-k2","time":{"created":1795701600000,"completed":1795701605000},"tokens":{"input":10,"output":5,"reasoning":0,"cache":{"read":0,"write":0}}}');
            """
        ])

        let source = OpenCodeTokenLogSource(rootDirectory: dir)
        var state = SourceCacheState()

        let pass1 = try source.refresh(state: &state, calendar: utcCalendar)
        try assertIncrementalMatchesFresh(source, incremental: pass1, expectedTokens: 15)

        try executeSQL(at: dbURL, statements: ["DELETE FROM message WHERE id = 'msg_del';"])
        let pass2 = try source.refresh(state: &state, calendar: utcCalendar)
        try assertIncrementalMatchesFresh(source, incremental: pass2, expectedTokens: 0)

        // Probe 2: Both SQLite and legacy JSON hold msg_dup (15 tokens) -> remove opencode.db -> legacy JSON restores 15 tokens.
        let legacyFile = legacyDir.appendingPathComponent("msg_dup.json")
        try """
        {"id":"msg_dup","role":"assistant","modelID":"kimi-k2","time":{"created":1795701600000,"completed":1795701605000},"tokens":{"input":10,"output":5,"reasoning":0,"cache":{"read":0,"write":0}}}
        """.write(to: legacyFile, atomically: true, encoding: .utf8)
        try executeSQL(at: dbURL, statements: [
            """
            INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES
            ('msg_dup', 'ses_1', 1795701600000, 1795701605000, '{"role":"assistant","modelID":"kimi-k2","time":{"created":1795701600000,"completed":1795701605000},"tokens":{"input":10,"output":5,"reasoning":0,"cache":{"read":0,"write":0}}}');
            """
        ])

        let pass3 = try source.refresh(state: &state, calendar: utcCalendar)
        try assertIncrementalMatchesFresh(source, incremental: pass3, expectedTokens: 15)

        try FileManager.default.removeItem(at: dbURL)
        let pass4 = try source.refresh(state: &state, calendar: utcCalendar)
        try assertIncrementalMatchesFresh(source, incremental: pass4, expectedTokens: 15)

        // Probe 3: Recreate DB with updated 25-token msg_dup, then delete the SQLite row while DB remains -> legacy 15 tokens restored.
        try executeSQL(at: dbURL, statements: [
            """
            CREATE TABLE message (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                time_created INTEGER NOT NULL,
                time_updated INTEGER NOT NULL,
                data TEXT NOT NULL
            );
            """,
            """
            INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES
            ('msg_dup', 'ses_1', 1795701600000, 1795701610000, '{"role":"assistant","modelID":"kimi-k2","time":{"created":1795701600000,"completed":1795701610000},"tokens":{"input":20,"output":5,"reasoning":0,"cache":{"read":0,"write":0}}}');
            """
        ])
        let pass5 = try source.refresh(state: &state, calendar: utcCalendar)
        try assertIncrementalMatchesFresh(source, incremental: pass5, expectedTokens: 25)

        try executeSQL(at: dbURL, statements: ["DELETE FROM message WHERE id = 'msg_dup';"])
        let pass6 = try source.refresh(state: &state, calendar: utcCalendar)
        try assertIncrementalMatchesFresh(source, incremental: pass6, expectedTokens: 15)
    }

    func testOpenCodeInterruptedOrLockedQueryPreservesPriorStateAndRetries() throws {
        // Defect 8, Probe A: Mid-query SQLite error after SQLITE_ROW must NOT commit partial state.
        let dirA = try makeTempDir(prefix: "opencode-err")
        let dbURLA = dirA.appendingPathComponent("opencode.db")
        try executeSQL(at: dbURLA, statements: [
            """
            CREATE VIEW message AS
            SELECT 'm1' AS id, 's1' AS session_id, 1795701600000 AS time_created, 1795701600000 AS time_updated,
                   '{"role":"assistant","modelID":"kimi-k2","time":{"created":1795701600000},"tokens":{"input":10,"output":5,"reasoning":0,"cache":{"read":0,"write":0}}}' AS data
            UNION ALL
            SELECT 'm2', 's1', 1795701605000, abs(-9223372036854775808), '{}';
            """
        ])

        let sourceA = OpenCodeTokenLogSource(rootDirectory: dirA, sqliteBusyTimeoutMs: 0)
        var stateA = SourceCacheState()
        let partial = try sourceA.refresh(state: &stateA, calendar: utcCalendar)
        // Row 2 fails with SQLITE_ERROR (integer overflow), so nothing must be committed to cache.
        XCTAssertTrue(partial.isEmpty)
        XCTAssertNil(stateA.files["__sqlite__/opencode.db"])

        // Defect 8, Probe B: SQLITE_BUSY preserves prior cached state and retries on the next refresh
        // even when the database file metadata has not changed between the failed attempt and the retry.
        let dirB = try makeTempDir(prefix: "opencode-busy")
        let dbURLB = dirB.appendingPathComponent("opencode.db")
        try executeSQL(at: dbURLB, statements: [
            """
            CREATE TABLE message (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                time_created INTEGER NOT NULL,
                time_updated INTEGER NOT NULL,
                data TEXT NOT NULL
            );
            """,
            """
            INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES
            ('m1', 's1', 1795701600000, 1795701600000, '{"role":"assistant","modelID":"kimi-k2","time":{"created":1795701600000},"tokens":{"input":10,"output":0,"reasoning":0,"cache":{"read":0,"write":0}}}');
            """
        ])

        let sourceB = OpenCodeTokenLogSource(rootDirectory: dirB, sqliteBusyTimeoutMs: 0)
        var stateB = SourceCacheState()
        let initial = try sourceB.refresh(state: &stateB, calendar: utcCalendar)
        XCTAssertEqual(TokenSummary.aggregate(initial).totalTokens, 10)

        // Commit a second row (total becomes 30), then hold an EXCLUSIVE lock on another connection.
        try executeSQL(at: dbURLB, statements: [
            """
            INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES
            ('m2', 's1', 1795701605000, 1795701605000, '{"role":"assistant","modelID":"kimi-k2","time":{"created":1795701605000},"tokens":{"input":20,"output":0,"reasoning":0,"cache":{"read":0,"write":0}}}');
            """
        ])

        var lockDB: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(dbURLB.path, &lockDB, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer {
            if let lockDB {
                _ = sqlite3_exec(lockDB, "ROLLBACK;", nil, nil, nil)
                sqlite3_close(lockDB)
            }
        }
        XCTAssertEqual(sqlite3_exec(lockDB, "BEGIN EXCLUSIVE;", nil, nil, nil), SQLITE_OK)

        // Refresh while locked must preserve prior 10 tokens and NOT mark the updated DB as current.
        let whileLocked = try sourceB.refresh(state: &stateB, calendar: utcCalendar)
        XCTAssertEqual(TokenSummary.aggregate(whileLocked).totalTokens, 10)

        // Release lock without touching the DB file again; next refresh MUST retry and observe 30 tokens.
        XCTAssertEqual(sqlite3_exec(lockDB, "ROLLBACK;", nil, nil, nil), SQLITE_OK)
        let afterUnlock = try sourceB.refresh(state: &stateB, calendar: utcCalendar)
        XCTAssertEqual(TokenSummary.aggregate(afterUnlock).totalTokens, 30)
    }

    func testIncrementalRefreshMatchesFreshScanAcrossFileMutationsForAllSources() throws {
        // Property-style mutation suite verifying incremental == fresh scan across all 4 sources.

        // 1) Claude: append, equal-length rewrite, truncate, truncate+regrow, partial trailing nested '}', rotate, delete
        do {
            let dir = try makeTempDir(prefix: "prop-claude")
            let proj = dir.appendingPathComponent("p", isDirectory: true)
            try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
            let url = proj.appendingPathComponent("s.jsonl")
            let source = ClaudeCodeTokenLogSource(rootDirectory: dir)
            var incState = SourceCacheState()

            func check(_ label: String) throws {
                let inc = try source.refresh(state: &incState, calendar: utcCalendar)
                var freshState = SourceCacheState()
                let fresh = try source.refresh(state: &freshState, calendar: utcCalendar)
                XCTAssertEqual(inc, fresh, "Claude mismatch at step: \(label)")
            }

            let l1 = #"{"type":"assistant","requestId":"r1","timestamp":"2026-11-26T10:00:00Z","message":{"id":"m1","model":"claude-opus-4-5-20251101","usage":{"input_tokens":111,"output_tokens":22,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"# + "\n"
            let l2 = #"{"type":"assistant","requestId":"r2","timestamp":"2026-11-26T10:10:00Z","message":{"id":"m2","model":"claude-opus-4-5-20251101","usage":{"input_tokens":333,"output_tokens":44,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"# + "\n"
            let pad = String(repeating: #"{"type":"user","content":"padding-padding-padding-padding"}"# + "\n", count: 30)

            try (pad + l1 + pad).write(to: url, atomically: false, encoding: .utf8)
            try check("initial")

            // Append
            let fh = try FileHandle(forUpdating: url)
            try fh.seekToEnd()
            try fh.write(contentsOf: Data(l2.utf8))
            try fh.close()
            try check("append")

            // Equal-length rewrite in middle
            let rewritten = (pad + l1 + pad + l2).replacingOccurrences(of: "111", with: "777")
            try overwriteInPlace(url: url, content: rewritten)
            try check("equal-length rewrite")

            // Truncate smaller
            try overwriteInPlace(url: url, content: l1)
            try check("truncate")

            // Truncate + regrow larger with partial line ending in nested '}'
            let partialNested = #"{"type":"assistant","requestId":"r3","timestamp":"2026-11-26T10:20:00Z","message":{"id":"m3","model":"claude-opus-4-5-20251101"}"#
            try overwriteInPlace(url: url, content: pad + l1 + l2 + pad + partialNested)
            try check("truncate+regrow+partialNested")

            // Complete the partial line
            let fh2 = try FileHandle(forUpdating: url)
            try fh2.seekToEnd()
            try fh2.write(contentsOf: Data((#","usage":{"input_tokens":50,"output_tokens":10}}"# + "\n").utf8))
            try fh2.close()
            try check("complete partial")

            // Rotate (new inode)
            let tmp = proj.appendingPathComponent("s.jsonl.tmp")
            try l2.write(to: tmp, atomically: true, encoding: .utf8)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            try check("rotate")

            // Delete
            try FileManager.default.removeItem(at: url)
            try check("delete")
        }

        // 2) Codex: initial, append, equal-length rewrite, truncate, truncate+regrow, rotate, delete
        do {
            let dir = try makeTempDir(prefix: "prop-codex")
            let url = dir.appendingPathComponent("rollout-prop.jsonl")
            let source = CodexCLITokenLogSource(rootDirectory: dir)
            var incState = SourceCacheState()

            func check(_ label: String) throws {
                let inc = try source.refresh(state: &incState, calendar: utcCalendar)
                var freshState = SourceCacheState()
                let fresh = try source.refresh(state: &freshState, calendar: utcCalendar)
                XCTAssertEqual(inc, fresh, "Codex mismatch at step: \(label)")
            }

            let ctx = #"{"timestamp":"2026-11-26T10:00:00Z","type":"turn_context","payload":{"model":"gpt-5-codex"}}"# + "\n"
            let e1 = #"{"timestamp":"2026-11-26T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10,"total_tokens":110},"last_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10,"total_tokens":110}}}}"# + "\n"
            let e2 = #"{"timestamp":"2026-11-26T10:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":250,"cached_input_tokens":50,"output_tokens":30,"total_tokens":280},"last_token_usage":{"input_tokens":150,"cached_input_tokens":30,"output_tokens":20,"total_tokens":170}}}}"# + "\n"
            let pad = String(repeating: #"{"timestamp":"2026-11-26T10:00:00Z","type":"response_item","payload":{"text":"pad-pad-pad-pad-pad"}}"# + "\n", count: 30)

            try (ctx + pad + e1 + pad).write(to: url, atomically: false, encoding: .utf8)
            try check("initial")

            let fh = try FileHandle(forUpdating: url)
            try fh.seekToEnd()
            try fh.write(contentsOf: Data(e2.utf8))
            try fh.close()
            try check("append")

            let rewritten = (ctx + pad + e1 + pad + e2).replacingOccurrences(of: #""output_tokens":10"#, with: #""output_tokens":90"#)
            try overwriteInPlace(url: url, content: rewritten)
            try check("equal-length rewrite")

            try overwriteInPlace(url: url, content: ctx + e1)
            try check("truncate")

            try overwriteInPlace(url: url, content: ctx + pad + pad + e1 + e2)
            try check("truncate+regrow")

            let tmp = dir.appendingPathComponent("rollout-prop.jsonl.tmp")
            try (ctx + e2).write(to: tmp, atomically: true, encoding: .utf8)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            try check("rotate")

            try FileManager.default.removeItem(at: url)
            try check("delete")
        }

        // 3) Gemini: initial, multi-KB equal-length rewrite, corrupt/truncate, repair, rotate, delete
        do {
            let dir = try makeTempDir(prefix: "prop-gemini")
            let chats = dir.appendingPathComponent("h/chats", isDirectory: true)
            try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
            let url = chats.appendingPathComponent("session-prop.json")
            let source = GeminiCLITokenLogSource(rootDirectory: dir)
            var incState = SourceCacheState()

            func check(_ label: String) throws {
                let inc = try source.refresh(state: &incState, calendar: utcCalendar)
                var freshState = SourceCacheState()
                let fresh = try source.refresh(state: &freshState, calendar: utcCalendar)
                XCTAssertEqual(inc, fresh, "Gemini mismatch at step: \(label)")
            }

            let blob = String(repeating: "z", count: 2500)
            let g1 = #"{"sessionId":"s","messages":[{"id":"u","content":""# + blob + #""},{"id":"g1","timestamp":"2026-11-26T10:00:00Z","model":"gemini-2.5-pro","tokens":{"input":100,"output":20,"cached":10,"thoughts":0,"tool":0}},{"id":"u2","content":""# + blob + #""}]}"#
            try g1.write(to: url, atomically: false, encoding: .utf8)
            try check("initial")

            let g2 = g1.replacingOccurrences(of: #""input":100"#, with: #""input":900"#)
            XCTAssertEqual(g1.utf8.count, g2.utf8.count)
            try overwriteInPlace(url: url, content: g2)
            try check("equal-length rewrite")

            try overwriteInPlace(url: url, content: String(g2.prefix(50)))
            try check("corrupt/truncate")

            try overwriteInPlace(url: url, content: g2)
            try check("repair")

            let tmp = chats.appendingPathComponent("session-prop.json.tmp")
            try g1.write(to: tmp, atomically: true, encoding: .utf8)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            try check("rotate")

            try FileManager.default.removeItem(at: url)
            try check("delete")
        }

        // 4) OpenCode: legacy JSON equal-length rewrite, corrupt, SQLite insert/update/delete, DB remove
        do {
            let dir = try makeTempDir(prefix: "prop-opencode")
            let legacy = dir.appendingPathComponent("storage/message/s", isDirectory: true)
            try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
            let jsonURL = legacy.appendingPathComponent("m1.json")
            let dbURL = dir.appendingPathComponent("opencode.db")
            let source = OpenCodeTokenLogSource(rootDirectory: dir)
            var incState = SourceCacheState()

            func check(_ label: String) throws {
                let inc = try source.refresh(state: &incState, calendar: utcCalendar)
                var freshState = SourceCacheState()
                let fresh = try source.refresh(state: &freshState, calendar: utcCalendar)
                XCTAssertEqual(inc, fresh, "OpenCode mismatch at step: \(label)")
            }

            let j1 = #"{"id":"m1","role":"assistant","modelID":"kimi-k2","time":{"created":1795701600000},"tokens":{"input":100,"output":20,"reasoning":0,"cache":{"read":0,"write":0}}}"#
            try j1.write(to: jsonURL, atomically: false, encoding: .utf8)
            try check("legacy initial")

            let j2 = j1.replacingOccurrences(of: #""input":100"#, with: #""input":800"#)
            try overwriteInPlace(url: jsonURL, content: j2)
            try check("legacy equal-length rewrite")

            try overwriteInPlace(url: jsonURL, content: "{corrupt")
            try check("legacy corrupt")

            try overwriteInPlace(url: jsonURL, content: j2)
            try check("legacy repaired")

            try executeSQL(at: dbURL, statements: [
                "CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL);",
                "INSERT INTO message VALUES ('m1', 's', 1795701600000, 1795701605000, '\(j1)');"
            ])
            try check("sqlite shadows legacy")

            try executeSQL(at: dbURL, statements: ["DELETE FROM message WHERE id = 'm1';"])
            try check("sqlite row deleted -> legacy restored")

            try FileManager.default.removeItem(at: dbURL)
            try check("sqlite db removed")

            try FileManager.default.removeItem(at: jsonURL)
            try check("all removed")
        }
    }

    @MainActor
    func testLocalLogPipelineControllerAutomaticallyRetriesInactiveWatcherOnPeriodicRefresh() async throws {
        // Defect 4: Verify that after initial watcher startup fails, a normal periodic refresh
        // driven by RefreshScheduler recovers the watcher WITHOUT any user action or manual watch() call,
        // and event-driven refreshes resume immediately once recovered.
        let dir = try makeTempDir(prefix: "pipeline-retry")
        let projDir = dir.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)
        let logURL = projDir.appendingPathComponent("session.jsonl")
        let cacheURL = dir.appendingPathComponent("cache.json")

        let line1 = #"{"type":"assistant","requestId":"r1","timestamp":"2026-11-26T10:00:00Z","message":{"id":"m1","model":"claude-opus-4-5-20251101","usage":{"input_tokens":100,"output_tokens":20,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"# + "\n"
        try line1.write(to: logURL, atomically: true, encoding: .utf8)

        let coordinator = LocalTokenLogCoordinator(
            sources: [ClaudeCodeTokenLogSource(rootDirectory: dir)],
            cacheStore: TokenLogCacheStore(fileURL: cacheURL)
        )
        let backend = FakeDirectoryWatchBackend()
        backend.shouldFailStart = true
        let watchScheduler = ManualDirectoryWatchScheduler()

        var latestBuckets: [LocalToolSource: [TokenBucket]] = [:]
        var updateCount = 0

        let controller = LocalLogPipelineController(
            coordinator: coordinator,
            debounceInterval: 0.5,
            watchBackend: backend,
            watchScheduler: watchScheduler,
            calendar: utcCalendar,
            enabledSources: { [.claudeCode] },
            onBucketsUpdated: { updated, refreshedAt in
                latestBuckets = updated
                if refreshedAt != nil {
                    updateCount += 1
                }
            }
        )
        defer { controller.stop() }

        // 1) Startup: watcher backend fails -> isWatching is false, initial logs still load.
        await controller.runInitialLoad()
        XCTAssertFalse(controller.isWatching)
        XCTAssertEqual(backend.startCallCount, 1)
        XCTAssertEqual(TokenSummary.aggregate(latestBuckets[.claudeCode] ?? []).totalTokens, 120)

        // 2) Backend recovers; a periodic RefreshScheduler tick runs automatically (no user toggle or manual watch call).
        backend.shouldFailStart = false
        let clockBox = LockedDateBox(LogTimestampParser.parseISO8601("2026-11-26T10:00:00Z")!)
        let scheduler = RefreshScheduler(
            lastRefreshDate: clockBox.value.addingTimeInterval(-300),
            isDropdownOpen: false,
            clock: { clockBox.value },
            sleeper: { _ in try await Task.sleep(nanoseconds: 30_000_000_000) },
            onRefresh: {
                await controller.refreshLogs()
            }
        )
        defer { scheduler.stop() }

        scheduler.start()
        // Wait briefly for the due periodic refresh task to execute on @MainActor.
        for _ in 0..<50 where !controller.isWatching {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertTrue(controller.isWatching, "Periodic refresh must automatically recover an inactive watcher")
        XCTAssertEqual(backend.startCallCount, 2)
        XCTAssertEqual(backend.invalidatedCount, 0)

        // 3) Another periodic refresh when already active must NOT recreate the watcher session.
        await controller.refreshLogs()
        XCTAssertTrue(controller.isWatching)
        XCTAssertEqual(backend.startCallCount, 2)
        XCTAssertEqual(backend.invalidatedCount, 0)

        // 4) Event-driven refresh now works end-to-end on the recovered watcher!
        let line2 = #"{"type":"assistant","requestId":"r2","timestamp":"2026-11-26T10:05:00Z","message":{"id":"m2","model":"claude-opus-4-5-20251101","usage":{"input_tokens":300,"output_tokens":50,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"# + "\n"
        let fh = try FileHandle(forUpdating: logURL)
        try fh.seekToEnd()
        try fh.write(contentsOf: Data(line2.utf8))
        try fh.close()

        let updatesBeforeEvent = updateCount
        backend.emitEvent()
        watchScheduler.advance(by: 0.5)

        for _ in 0..<50 where updateCount == updatesBeforeEvent {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertGreaterThan(updateCount, updatesBeforeEvent)
        XCTAssertEqual(TokenSummary.aggregate(latestBuckets[.claudeCode] ?? []).totalTokens, 470)
    }

    func testMidScanSameLengthRotationRetriesAndMatchesFreshScanForClaudeAndCodex() throws {
        let cal = StatisticsAggregator.gregorianCalendar(timeZone: TimeZone(secondsFromGMT: 0)!)

        // 1. Claude: swap file mid-scan (after record 1) with an equal-length replacement (112 -> 912 tokens).
        do {
            let claudeRoot = try makeTempDir(prefix: "claude-midscan-rotate")
            let projectDir = claudeRoot.appendingPathComponent("proj", isDirectory: true)
            try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
            let logURL = projectDir.appendingPathComponent("session.jsonl")

            let original = """
            {"type":"assistant","requestId":"r1","timestamp":"2026-11-26T10:00:00Z","message":{"id":"m1","model":"claude-opus-4-5-20251101","usage":{"input_tokens":100,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
            {"type":"assistant","requestId":"r2","timestamp":"2026-11-26T10:01:00Z","message":{"id":"m2","model":"claude-opus-4-5-20251101","usage":{"input_tokens":10,"output_tokens":2,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
            """ + "\n"
            let replacement = """
            {"type":"assistant","requestId":"r1","timestamp":"2026-11-26T10:00:00Z","message":{"id":"m1","model":"claude-opus-4-5-20251101","usage":{"input_tokens":900,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
            {"type":"assistant","requestId":"r2","timestamp":"2026-11-26T10:01:00Z","message":{"id":"m2","model":"claude-opus-4-5-20251101","usage":{"input_tokens":10,"output_tokens":2,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
            """ + "\n"
            XCTAssertEqual(original.utf8.count, replacement.utf8.count)
            try original.write(to: logURL, atomically: true, encoding: .utf8)

            let swapCount = LockedCounter()
            let source = ClaudeCodeTokenLogSource(
                rootDirectory: claudeRoot,
                maxScanAttempts: 3
            ) { _, attempt, lineNumber in
                if attempt == 1 && lineNumber == 1 {
                    swapCount.increment()
                    try? Self.atomicReplaceWithNewInode(at: logURL, content: replacement)
                }
            }

            var state = SourceCacheState()
            let firstRefresh = try source.refresh(state: &state, calendar: cal)
            XCTAssertEqual(swapCount.value, 1)
            XCTAssertEqual(TokenSummary.aggregate(firstRefresh).totalTokens, 912)

            // Subsequent refresh with no further edit must match a fresh scan.
            let secondRefresh = try source.refresh(state: &state, calendar: cal)
            var freshState = SourceCacheState()
            let freshScan = try ClaudeCodeTokenLogSource(rootDirectory: claudeRoot)
                .refresh(state: &freshState, calendar: cal)
            XCTAssertEqual(secondRefresh, freshScan)
            XCTAssertEqual(TokenSummary.aggregate(secondRefresh).totalTokens, 912)
        }

        // 2. Codex: swap file mid-scan (after first token_count) with an equal-length replacement (205 -> 905 tokens).
        do {
            let codexRoot = try makeTempDir(prefix: "codex-midscan-rotate")
            let dayDir = codexRoot.appendingPathComponent("2026/11/26", isDirectory: true)
            try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
            let rolloutURL = dayDir.appendingPathComponent("rollout-2026-11-26.jsonl")

            let original = """
            {"timestamp":"2026-11-26T10:00:00Z","type":"turn_context","payload":{"model":"gpt-5-codex"}}
            {"timestamp":"2026-11-26T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":5,"total_tokens":105},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":5,"total_tokens":105}}}}
            {"timestamp":"2026-11-26T10:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":200,"cached_input_tokens":0,"output_tokens":5,"total_tokens":205},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0,"total_tokens":100}}}}
            """ + "\n"
            let replacement = """
            {"timestamp":"2026-11-26T10:00:00Z","type":"turn_context","payload":{"model":"gpt-5-codex"}}
            {"timestamp":"2026-11-26T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":5,"total_tokens":105},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":5,"total_tokens":105}}}}
            {"timestamp":"2026-11-26T10:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":900,"cached_input_tokens":0,"output_tokens":5,"total_tokens":905},"last_token_usage":{"input_tokens":800,"cached_input_tokens":0,"output_tokens":0,"total_tokens":800}}}}
            """ + "\n"
            XCTAssertEqual(original.utf8.count, replacement.utf8.count)
            try original.write(to: rolloutURL, atomically: true, encoding: .utf8)

            let swapCount = LockedCounter()
            let source = CodexCLITokenLogSource(
                rootDirectory: codexRoot,
                maxScanAttempts: 3
            ) { _, attempt, lineNumber in
                if attempt == 1 && lineNumber == 2 {
                    swapCount.increment()
                    try? Self.atomicReplaceWithNewInode(at: rolloutURL, content: replacement)
                }
            }

            var state = SourceCacheState()
            let firstRefresh = try source.refresh(state: &state, calendar: cal)
            XCTAssertEqual(swapCount.value, 1)
            XCTAssertEqual(TokenSummary.aggregate(firstRefresh).totalTokens, 905)

            // Subsequent refresh with no further edit must match a fresh scan.
            let secondRefresh = try source.refresh(state: &state, calendar: cal)
            var freshState = SourceCacheState()
            let freshScan = try CodexCLITokenLogSource(rootDirectory: codexRoot)
                .refresh(state: &freshState, calendar: cal)
            XCTAssertEqual(secondRefresh, freshScan)
            XCTAssertEqual(TokenSummary.aggregate(secondRefresh).totalTokens, 905)
        }
    }

    func testMidScanRotationRetryExhaustionDropsStateSoNextRefreshMatchesFreshScan() throws {
        let cal = StatisticsAggregator.gregorianCalendar(timeZone: TimeZone(secondsFromGMT: 0)!)

        // Claude retry exhaustion: swap on every attempt (1, 2, 3), ending on the 912-token file.
        do {
            let claudeRoot = try makeTempDir(prefix: "claude-midscan-exhaust")
            let projectDir = claudeRoot.appendingPathComponent("proj", isDirectory: true)
            try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
            let logURL = projectDir.appendingPathComponent("session.jsonl")

            let fileA = """
            {"type":"assistant","requestId":"r1","timestamp":"2026-11-26T10:00:00Z","message":{"id":"m1","model":"claude-opus-4-5-20251101","usage":{"input_tokens":100,"output_tokens":12,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
            """ + "\n"
            let fileB = """
            {"type":"assistant","requestId":"r1","timestamp":"2026-11-26T10:00:00Z","message":{"id":"m1","model":"claude-opus-4-5-20251101","usage":{"input_tokens":900,"output_tokens":12,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
            """ + "\n"
            XCTAssertEqual(fileA.utf8.count, fileB.utf8.count)
            try fileA.write(to: logURL, atomically: true, encoding: .utf8)

            let shouldSwap = LockedCounter()
            shouldSwap.increment() // 1 = active
            let attemptsSeen = LockedCounter()
            let source = ClaudeCodeTokenLogSource(
                rootDirectory: claudeRoot,
                maxScanAttempts: 3
            ) { _, _, lineNumber in
                if shouldSwap.value > 0 && lineNumber == 1 {
                    attemptsSeen.increment()
                    try? Self.atomicReplaceWithNewInode(at: logURL, content: fileB)
                }
            }

            var state = SourceCacheState()
            _ = try source.refresh(state: &state, calendar: cal)
            XCTAssertEqual(attemptsSeen.value, 3)
            // Exhausted retries must store NO state for the file.
            XCTAssertNil(state.files["proj/session.jsonl"])

            // Next refresh with no hook firing and NO further file edit rescans from zero and matches fresh scan.
            let cleanSource = ClaudeCodeTokenLogSource(rootDirectory: claudeRoot)
            let recovered = try cleanSource.refresh(state: &state, calendar: cal)
            var freshState = SourceCacheState()
            let fresh = try cleanSource.refresh(state: &freshState, calendar: cal)
            XCTAssertEqual(recovered, fresh)
            XCTAssertEqual(TokenSummary.aggregate(recovered).totalTokens, 912)
        }

        // Codex retry exhaustion: swap on every attempt (1, 2, 3), ending on the 905-token file.
        do {
            let codexRoot = try makeTempDir(prefix: "codex-midscan-exhaust")
            let dayDir = codexRoot.appendingPathComponent("2026/11/26", isDirectory: true)
            try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
            let rolloutURL = dayDir.appendingPathComponent("rollout-2026-11-26.jsonl")

            let fileA = """
            {"timestamp":"2026-11-26T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":200,"cached_input_tokens":0,"output_tokens":5,"total_tokens":205},"last_token_usage":{"input_tokens":200,"cached_input_tokens":0,"output_tokens":5,"total_tokens":205}}}}
            """ + "\n"
            let fileB = """
            {"timestamp":"2026-11-26T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":900,"cached_input_tokens":0,"output_tokens":5,"total_tokens":905},"last_token_usage":{"input_tokens":900,"cached_input_tokens":0,"output_tokens":5,"total_tokens":905}}}}
            """ + "\n"
            XCTAssertEqual(fileA.utf8.count, fileB.utf8.count)
            try fileA.write(to: rolloutURL, atomically: true, encoding: .utf8)

            let attemptsSeen = LockedCounter()
            let source = CodexCLITokenLogSource(
                rootDirectory: codexRoot,
                maxScanAttempts: 3
            ) { _, _, lineNumber in
                if lineNumber == 1 {
                    attemptsSeen.increment()
                    try? Self.atomicReplaceWithNewInode(at: rolloutURL, content: fileB)
                }
            }

            var state = SourceCacheState()
            _ = try source.refresh(state: &state, calendar: cal)
            XCTAssertEqual(attemptsSeen.value, 3)
            XCTAssertNil(state.files["2026/11/26/rollout-2026-11-26.jsonl"])

            let cleanSource = CodexCLITokenLogSource(rootDirectory: codexRoot)
            let recovered = try cleanSource.refresh(state: &state, calendar: cal)
            var freshState = SourceCacheState()
            let fresh = try cleanSource.refresh(state: &freshState, calendar: cal)
            XCTAssertEqual(recovered, fresh)
            XCTAssertEqual(TokenSummary.aggregate(recovered).totalTokens, 905)
        }
    }

    func testMidScanSameLengthRotationForGeminiAndOpenCodeLegacyJSON() throws {
        let cal = StatisticsAggregator.gregorianCalendar(timeZone: TimeZone(secondsFromGMT: 0)!)

        // 1. Gemini mid-scan same-length rotation
        do {
            let geminiRoot = try makeTempDir(prefix: "gemini-midscan-rotate")
            let chatsDir = geminiRoot.appendingPathComponent("hash/chats", isDirectory: true)
            try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)
            let sessionURL = chatsDir.appendingPathComponent("session-2026-11-26.json")

            let original = """
            {"sessionId":"s1","messages":[{"id":"m1","timestamp":"2026-11-26T10:00:00Z","model":"gemini-2.5-pro","tokens":{"input":100,"output":10,"cached":20,"thoughts":0,"tool":0,"total":110}},{"id":"m2","timestamp":"2026-11-26T10:01:00Z","model":"gemini-2.5-pro","tokens":{"input":100,"output":10,"cached":20,"thoughts":0,"tool":0,"total":110}}]}
            """
            let replacement = """
            {"sessionId":"s1","messages":[{"id":"m1","timestamp":"2026-11-26T10:00:00Z","model":"gemini-2.5-pro","tokens":{"input":500,"output":10,"cached":20,"thoughts":0,"tool":0,"total":510}},{"id":"m2","timestamp":"2026-11-26T10:01:00Z","model":"gemini-2.5-pro","tokens":{"input":400,"output":10,"cached":20,"thoughts":0,"tool":0,"total":410}}]}
            """
            XCTAssertEqual(original.utf8.count, replacement.utf8.count)
            try original.write(to: sessionURL, atomically: true, encoding: .utf8)

            let source = GeminiCLITokenLogSource(
                rootDirectory: geminiRoot,
                maxScanAttempts: 3
            ) { _, attempt, messageIndex in
                if attempt == 1 && messageIndex == 1 {
                    try? Self.atomicReplaceWithNewInode(at: sessionURL, content: replacement)
                }
            }

            var state = SourceCacheState()
            let first = try source.refresh(state: &state, calendar: cal)
            XCTAssertEqual(TokenSummary.aggregate(first).totalTokens, 920)
            let second = try source.refresh(state: &state, calendar: cal)
            var freshState = SourceCacheState()
            let fresh = try GeminiCLITokenLogSource(rootDirectory: geminiRoot)
                .refresh(state: &freshState, calendar: cal)
            XCTAssertEqual(second, fresh)
        }

        // 2. OpenCode legacy JSON mid-scan same-length rotation
        do {
            let opencodeRoot = try makeTempDir(prefix: "opencode-midscan-rotate")
            let msgDir = opencodeRoot.appendingPathComponent("storage/message/ses1", isDirectory: true)
            try FileManager.default.createDirectory(at: msgDir, withIntermediateDirectories: true)
            let msgURL = msgDir.appendingPathComponent("msg1.json")

            let original = """
            {"id":"msg1","role":"assistant","modelID":"kimi-k2","time":{"created":1795701600000},"tokens":{"input":100,"output":10,"reasoning":0,"cache":{"read":10,"write":0},"total":120}}
            """
            let replacement = """
            {"id":"msg1","role":"assistant","modelID":"kimi-k2","time":{"created":1795701600000},"tokens":{"input":800,"output":10,"reasoning":0,"cache":{"read":10,"write":0},"total":820}}
            """
            XCTAssertEqual(original.utf8.count, replacement.utf8.count)
            try original.write(to: msgURL, atomically: true, encoding: .utf8)

            let source = OpenCodeTokenLogSource(
                rootDirectory: opencodeRoot,
                maxScanAttempts: 3
            ) { _, attempt in
                if attempt == 1 {
                    try? Self.atomicReplaceWithNewInode(at: msgURL, content: replacement)
                }
            }

            var state = SourceCacheState()
            let first = try source.refresh(state: &state, calendar: cal)
            XCTAssertEqual(TokenSummary.aggregate(first).totalTokens, 820)
            let second = try source.refresh(state: &state, calendar: cal)
            var freshState = SourceCacheState()
            let fresh = try OpenCodeTokenLogSource(rootDirectory: opencodeRoot)
                .refresh(state: &freshState, calendar: cal)
            XCTAssertEqual(second, fresh)
        }
    }

    func testImpossibleCachedInputRejectedBeforeStateMutationForGeminiAndCodex() throws {
        let cal = StatisticsAggregator.gregorianCalendar(timeZone: TimeZone(secondsFromGMT: 0)!)

        // 1. Gemini exact reviewer scenario:
        //    Record 1: input=10, cached=80, total=10 (impossible cached > input)
        //    Record 2 (same message ID correction): input=10, cached=8, total=10
        //    Expect: 10 total tokens, 1 request, 2 uncached input, 0 output, 8 cached.
        do {
            let geminiRoot = try makeTempDir(prefix: "gemini-impossible-cached")
            let chatsDir = geminiRoot.appendingPathComponent("hash/chats", isDirectory: true)
            try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)
            let sessionURL = chatsDir.appendingPathComponent("session-2026-11-26.json")

            let content = """
            {
              "sessionId": "s-bad-cache",
              "messages": [
                {
                  "id": "m-fixable",
                  "timestamp": "2026-11-26T10:00:00Z",
                  "type": "gemini",
                  "model": "gemini-2.5-pro",
                  "tokens": { "input": 10, "output": 0, "cached": 80, "thoughts": 0, "tool": 0, "total": 10 }
                },
                {
                  "id": "m-fixable",
                  "timestamp": "2026-11-26T10:00:00Z",
                  "type": "gemini",
                  "model": "gemini-2.5-pro",
                  "tokens": { "input": 10, "output": 0, "cached": 8, "thoughts": 0, "tool": 0, "total": 10 }
                }
              ]
            }
            """
            try content.write(to: sessionURL, atomically: true, encoding: .utf8)

            var state = SourceCacheState()
            let buckets = try GeminiCLITokenLogSource(rootDirectory: geminiRoot)
                .refresh(state: &state, calendar: cal)
            let summary = TokenSummary.aggregate(buckets)
            XCTAssertEqual(summary.totalTokens, 10)
            XCTAssertEqual(summary.requests, 1)
            XCTAssertEqual(summary.inputTokens, 2)
            XCTAssertEqual(summary.outputTokens, 0)
            XCTAssertEqual(summary.cacheTokens, 8)
        }

        // 2. Codex exact reviewer scenario:
        //    Record 1: input_tokens=10, cached_input_tokens=80, output_tokens=0, total_tokens=10
        //    Record 2 (correction): input_tokens=10, cached_input_tokens=8, output_tokens=0, total_tokens=10
        //    Expect: 10 total tokens, 1 request, 2 uncached input, 0 output, 8 cached.
        do {
            let codexRoot = try makeTempDir(prefix: "codex-impossible-cached")
            let dayDir = codexRoot.appendingPathComponent("2026/11/26", isDirectory: true)
            try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
            let rolloutURL = dayDir.appendingPathComponent("rollout-2026-11-26.jsonl")

            let content = """
            {"timestamp":"2026-11-26T10:00:00Z","type":"turn_context","payload":{"model":"gpt-5-codex"}}
            {"timestamp":"2026-11-26T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":80,"output_tokens":0,"total_tokens":10},"last_token_usage":{"input_tokens":10,"cached_input_tokens":80,"output_tokens":0,"total_tokens":10}}}}
            {"timestamp":"2026-11-26T10:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":8,"output_tokens":0,"total_tokens":10},"last_token_usage":{"input_tokens":10,"cached_input_tokens":8,"output_tokens":0,"total_tokens":10}}}}
            """ + "\n"
            try content.write(to: rolloutURL, atomically: true, encoding: .utf8)

            var state = SourceCacheState()
            let buckets = try CodexCLITokenLogSource(rootDirectory: codexRoot)
                .refresh(state: &state, calendar: cal)
            let summary = TokenSummary.aggregate(buckets)
            XCTAssertEqual(summary.totalTokens, 10)
            XCTAssertEqual(summary.requests, 1)
            XCTAssertEqual(summary.inputTokens, 2)
            XCTAssertEqual(summary.outputTokens, 0)
            XCTAssertEqual(summary.cacheTokens, 8)
        }

        // 3. Codex cumulative delta where record 2 is individually valid (cached 90 <= input 110)
        //    but its delta from record 1 has delta_cached=40 > delta_input=10:
        //    must be rejected before advancing cumulative state so record 3 computes the true delta.
        do {
            let codexRoot = try makeTempDir(prefix: "codex-impossible-delta-cached")
            let dayDir = codexRoot.appendingPathComponent("2026/11/26", isDirectory: true)
            try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
            let rolloutURL = dayDir.appendingPathComponent("rollout-2026-11-26.jsonl")

            let content = """
            {"timestamp":"2026-11-26T10:00:00Z","type":"turn_context","payload":{"model":"gpt-5-codex"}}
            {"timestamp":"2026-11-26T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":50,"output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":100,"cached_input_tokens":50,"output_tokens":0,"total_tokens":100}}}}
            {"timestamp":"2026-11-26T10:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":110,"cached_input_tokens":90,"output_tokens":0,"total_tokens":110}}}}
            {"timestamp":"2026-11-26T10:03:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":110,"cached_input_tokens":58,"output_tokens":0,"total_tokens":110}}}}
            """ + "\n"
            try content.write(to: rolloutURL, atomically: true, encoding: .utf8)

            var state = SourceCacheState()
            let buckets = try CodexCLITokenLogSource(rootDirectory: codexRoot)
                .refresh(state: &state, calendar: cal)
            let summary = TokenSummary.aggregate(buckets)
            XCTAssertEqual(summary.totalTokens, 110)
            XCTAssertEqual(summary.requests, 2)
            XCTAssertEqual(summary.inputTokens, 52)
            XCTAssertEqual(summary.outputTokens, 0)
            XCTAssertEqual(summary.cacheTokens, 58)
        }
    }

    func testInconsistentDeclaredTotalsRejectedAcrossAllSourcesWithoutAffectingValidDisjointCache() throws {
        let cal = StatisticsAggregator.gregorianCalendar(timeZone: TimeZone(secondsFromGMT: 0)!)

        // 1. Gemini: declared total < sum of parts must not claim message ID.
        do {
            let root = try makeTempDir(prefix: "gemini-bad-total")
            let chatsDir = root.appendingPathComponent("h/chats", isDirectory: true)
            try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)
            let content = """
            {"sessionId":"s","messages":[
              {"id":"m1","timestamp":"2026-11-26T10:00:00Z","model":"gemini-2.5-pro","tokens":{"input":10,"output":5,"cached":2,"thoughts":0,"tool":0,"total":10}},
              {"id":"m1","timestamp":"2026-11-26T10:00:00Z","model":"gemini-2.5-pro","tokens":{"input":10,"output":5,"cached":2,"thoughts":0,"tool":0,"total":15}}
            ]}
            """
            try content.write(to: chatsDir.appendingPathComponent("session-1.json"), atomically: true, encoding: .utf8)
            var state = SourceCacheState()
            let summary = TokenSummary.aggregate(try GeminiCLITokenLogSource(rootDirectory: root).refresh(state: &state, calendar: cal))
            XCTAssertEqual(summary.totalTokens, 15)
            XCTAssertEqual(summary.requests, 1)
            XCTAssertEqual(summary.inputTokens, 8)
            XCTAssertEqual(summary.outputTokens, 5)
            XCTAssertEqual(summary.cacheTokens, 2)
        }

        // 2. Codex: declared total < input+output AND reasoning > output rejected before advancing state.
        do {
            let root = try makeTempDir(prefix: "codex-bad-total")
            let dir = root.appendingPathComponent("2026/11/26", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let content = """
            {"timestamp":"2026-11-26T10:00:00Z","type":"turn_context","payload":{"model":"gpt-5-codex"}}
            {"timestamp":"2026-11-26T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":5,"reasoning_output_tokens":0,"total_tokens":10}}}}
            {"timestamp":"2026-11-26T10:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":5,"reasoning_output_tokens":9,"total_tokens":15}}}}
            {"timestamp":"2026-11-26T10:03:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":5,"reasoning_output_tokens":3,"total_tokens":15}}}}
            """ + "\n"
            try content.write(to: dir.appendingPathComponent("rollout-1.jsonl"), atomically: true, encoding: .utf8)
            var state = SourceCacheState()
            let summary = TokenSummary.aggregate(try CodexCLITokenLogSource(rootDirectory: root).refresh(state: &state, calendar: cal))
            XCTAssertEqual(summary.totalTokens, 15)
            XCTAssertEqual(summary.requests, 1)
            XCTAssertEqual(summary.inputTokens, 8)
            XCTAssertEqual(summary.outputTokens, 5)
            XCTAssertEqual(summary.cacheTokens, 2)
        }

        // 3. OpenCode: declared total < parts rejected, while valid disjoint cache.read > input is accepted.
        do {
            let root = try makeTempDir(prefix: "opencode-bad-total")
            let msgDir = root.appendingPathComponent("storage/message/s1", isDirectory: true)
            try FileManager.default.createDirectory(at: msgDir, withIntermediateDirectories: true)
            // Bad declared total (10 < 10 + 5 + 80 = 95) -> rejected
            let bad = """
            {"id":"m-bad","role":"assistant","modelID":"kimi-k2","time":{"created":1795701600000},"tokens":{"input":10,"output":5,"reasoning":0,"cache":{"read":80,"write":0},"total":10}}
            """
            // Valid disjoint cache.read > input (10 + 5 + 80 == 95) -> accepted!
            let good = """
            {"id":"m-good","role":"assistant","modelID":"kimi-k2","time":{"created":1795701600000},"tokens":{"input":10,"output":5,"reasoning":0,"cache":{"read":80,"write":0},"total":95}}
            """
            try bad.write(to: msgDir.appendingPathComponent("m-bad.json"), atomically: true, encoding: .utf8)
            try good.write(to: msgDir.appendingPathComponent("m-good.json"), atomically: true, encoding: .utf8)
            var state = SourceCacheState()
            let summary = TokenSummary.aggregate(try OpenCodeTokenLogSource(rootDirectory: root).refresh(state: &state, calendar: cal))
            XCTAssertEqual(summary.totalTokens, 95)
            XCTAssertEqual(summary.requests, 1)
            XCTAssertEqual(summary.inputTokens, 10)
            XCTAssertEqual(summary.outputTokens, 5)
            XCTAssertEqual(summary.cacheTokens, 80)
        }

        // 4. Claude: valid disjoint cache_read_input_tokens > input_tokens accepted; inconsistent optional total_tokens rejected.
        do {
            let root = try makeTempDir(prefix: "claude-bad-total")
            let proj = root.appendingPathComponent("p", isDirectory: true)
            try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
            let content = """
            {"type":"assistant","requestId":"r1","timestamp":"2026-11-26T10:00:00Z","message":{"id":"m1","model":"claude-opus-4-5-20251101","usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":80,"total_tokens":10}}}
            {"type":"assistant","requestId":"r1","timestamp":"2026-11-26T10:00:00Z","message":{"id":"m1","model":"claude-opus-4-5-20251101","usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":80}}}
            """ + "\n"
            try content.write(to: proj.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)
            var state = SourceCacheState()
            let summary = TokenSummary.aggregate(try ClaudeCodeTokenLogSource(rootDirectory: root).refresh(state: &state, calendar: cal))
            XCTAssertEqual(summary.totalTokens, 95)
            XCTAssertEqual(summary.requests, 1)
            XCTAssertEqual(summary.inputTokens, 10)
            XCTAssertEqual(summary.outputTokens, 5)
            XCTAssertEqual(summary.cacheTokens, 80)
        }
    }

    // MARK: - Helpers

    private static func atomicReplaceWithNewInode(at url: URL, content: String) throws {
        let dir = url.deletingLastPathComponent()
        let tempURL = dir.appendingPathComponent(".tmp-\(UUID().uuidString)")
        try Data(content.utf8).write(to: tempURL, options: [])
        let rc = tempURL.withUnsafeFileSystemRepresentation { src -> Int32 in
            url.withUnsafeFileSystemRepresentation { dst -> Int32 in
                guard let src, let dst else { return -1 }
                return Darwin.rename(src, dst)
            }
        }
        if rc != 0 {
            try? FileManager.default.removeItem(at: tempURL)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func overwriteInPlace(url: URL, content: String) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data(content.utf8))
    }

    private func bumpMtime(of url: URL, by seconds: TimeInterval) {
        let future = Date().addingTimeInterval(seconds)
        try? FileManager.default.setAttributes([.modificationDate: future], ofItemAtPath: url.path)
    }

    private func executeSQL(at dbURL: URL, statements: [String]) throws {
        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(
            dbURL.path,
            &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            nil
        )
        guard openResult == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            XCTFail("Failed to open SQLite test DB")
            return
        }
        defer { sqlite3_close(db) }

        for sql in statements {
            var errMsg: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
            if rc != SQLITE_OK {
                let message = errMsg.map { String(cString: $0) } ?? "unknown error"
                sqlite3_free(errMsg)
                XCTFail("SQLite exec failed: \(message)")
            }
        }
    }
}

// MARK: - Test Doubles

private final class LockedDateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Date

    init(_ value: Date) {
        self._value = value
    }

    var value: Date {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }
        set {
            lock.lock()
            _value = newValue
            lock.unlock()
        }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}

private final class SpyIncrementalTokenLogSource: IncrementalTokenLogSource, @unchecked Sendable {
    private let wrapped: any IncrementalTokenLogSource
    private let calls = LockedCounter()

    var provider: ProviderID { wrapped.provider }
    var toolSource: LocalToolSource { wrapped.toolSource }
    var sourceLabel: String { wrapped.sourceLabel }
    var watchDirectories: [URL] { wrapped.watchDirectories }

    var refreshCallCount: Int { calls.value }

    init(wrapped: any IncrementalTokenLogSource) {
        self.wrapped = wrapped
    }

    func refresh(state: inout SourceCacheState, calendar: Calendar) throws -> [TokenBucket] {
        calls.increment()
        return try wrapped.refresh(state: &state, calendar: calendar)
    }
}

private final class FakeDirectoryWatchBackend: DirectoryWatchBackend, @unchecked Sendable {
    private final class FakeSession: DirectoryWatchSession, @unchecked Sendable {
        let onInvalidate: @Sendable () -> Void
        private let lock = NSLock()
        private var invalidated = false

        init(onInvalidate: @escaping @Sendable () -> Void) {
            self.onInvalidate = onInvalidate
        }

        func invalidate() {
            lock.lock()
            let already = invalidated
            invalidated = true
            lock.unlock()
            if !already {
                onInvalidate()
            }
        }
    }

    private let lock = NSLock()
    private var _shouldFailStart = false
    private var _startCallCount = 0
    private var _invalidatedCount = 0
    private var activeHandler: (@Sendable () -> Void)?

    var shouldFailStart: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _shouldFailStart
        }
        set {
            lock.lock()
            _shouldFailStart = newValue
            lock.unlock()
        }
    }

    var startCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _startCallCount
    }

    var invalidatedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _invalidatedCount
    }

    func startWatching(
        paths: [String],
        queue: DispatchQueue,
        onEvent: @escaping @Sendable () -> Void
    ) -> (any DirectoryWatchSession)? {
        lock.lock()
        _startCallCount += 1
        let fail = _shouldFailStart
        if !fail {
            activeHandler = onEvent
        }
        lock.unlock()

        if fail {
            return nil
        }

        return FakeSession { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self._invalidatedCount += 1
            self.activeHandler = nil
            self.lock.unlock()
        }
    }

    func emitEvent() {
        lock.lock()
        let handler = activeHandler
        lock.unlock()
        handler?()
    }
}

private final class ManualDirectoryWatchScheduler: DirectoryWatchScheduler, @unchecked Sendable {
    private final class Entry: DirectoryWatchTimerToken, @unchecked Sendable {
        let id: UInt64
        let fireTime: TimeInterval
        let action: @Sendable () -> Void
        private let lock = NSLock()
        private var _cancelled = false

        init(id: UInt64, fireTime: TimeInterval, action: @escaping @Sendable () -> Void) {
            self.id = id
            self.fireTime = fireTime
            self.action = action
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return _cancelled
        }

        func cancel() {
            lock.lock()
            _cancelled = true
            lock.unlock()
        }
    }

    private let lock = NSLock()
    private var now: TimeInterval = 0
    private var nextID: UInt64 = 0
    private var entries: [Entry] = []

    func schedule(
        after delay: TimeInterval,
        on queue: DispatchQueue,
        action: @escaping @Sendable () -> Void
    ) -> any DirectoryWatchTimerToken {
        lock.lock()
        nextID += 1
        let entry = Entry(id: nextID, fireTime: now + delay, action: action)
        entries.append(entry)
        lock.unlock()
        return entry
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        now += seconds
        let targetTime = now
        lock.unlock()

        while true {
            lock.lock()
            let nextIndex = entries.enumerated()
                .filter { !$0.element.isCancelled && $0.element.fireTime <= targetTime + 1e-9 }
                .min { lhs, rhs in
                    if lhs.element.fireTime != rhs.element.fireTime {
                        return lhs.element.fireTime < rhs.element.fireTime
                    }
                    return lhs.element.id < rhs.element.id
                }?
                .offset

            guard let index = nextIndex else {
                entries.removeAll { $0.isCancelled }
                lock.unlock()
                return
            }

            let entry = entries.remove(at: index)
            lock.unlock()

            if !entry.isCancelled {
                entry.action()
            }
        }
    }
}
