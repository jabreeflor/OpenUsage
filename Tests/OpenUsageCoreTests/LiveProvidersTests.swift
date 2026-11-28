import Foundation
import SQLite3
import XCTest
@testable import OpenUsageCore

// MARK: - Test Doubles

private final class StubHTTPTransport: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, TimeInterval) async throws -> HTTPResponseData

    private let lock = NSLock()
    private let handler: Handler
    private var _requests: [(url: String, method: String, timeout: TimeInterval)] = []

    var requests: [(url: String, method: String, timeout: TimeInterval)] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func send(_ request: URLRequest, timeout: TimeInterval) async throws -> HTTPResponseData {
        lock.withLock {
            _requests.append((request.url?.absoluteString ?? "", request.httpMethod ?? "GET", timeout))
        }
        return try await handler(request, timeout)
    }
}

private final class StubKeychain: KeychainReading, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data]
    private var error: Error?
    private var _readCount = 0

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _readCount
    }

    init(items: [String: Data] = [:], error: Error? = nil) {
        self.items = items
        self.error = error
    }

    func setItem(_ data: Data?, forService service: String) {
        lock.lock()
        defer { lock.unlock() }
        items[service] = data
    }

    func readGenericPassword(service: String, account: String?) throws -> Data? {
        lock.lock()
        _readCount += 1
        let err = error
        let data = items[service]
        lock.unlock()
        if let err { throw err }
        return data
    }
}

private final class StubLocalFileReader: LocalFileReader, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data]
    private var discovered: [DiscoveredLocalFile]
    private var sqliteItemsByPath: [String: [String: String]]
    private var sqliteError: Error?
    private var _readCalls = 0

    var readCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return _readCalls
    }

    init(
        files: [String: Data] = [:],
        discovered: [DiscoveredLocalFile] = [],
        sqliteItemsByPath: [String: [String: String]] = [:],
        sqliteError: Error? = nil
    ) {
        self.files = files
        self.discovered = discovered
        self.sqliteItemsByPath = sqliteItemsByPath
        self.sqliteError = sqliteError
    }

    func readFile(at url: URL) throws -> Data? {
        lock.lock()
        _readCalls += 1
        let value = files[url.path]
        lock.unlock()
        return value
    }

    func discoverFiles(under root: URL, matching predicate: @Sendable (URL) -> Bool) -> [DiscoveredLocalFile] {
        lock.lock()
        _readCalls += 1
        let items = discovered
        lock.unlock()
        return items.filter { predicate($0.url) }
    }

    func readSQLiteItems(at dbURL: URL, keys: [String]) throws -> [String: String]? {
        lock.lock()
        _readCalls += 1
        let err = sqliteError
        let table = sqliteItemsByPath[dbURL.path]
        lock.unlock()
        if let err { throw err }
        guard let table else { return nil }
        var filtered: [String: String] = [:]
        for key in keys {
            if let value = table[key] {
                filtered[key] = value
            }
        }
        return filtered
    }
}

private final class RecordingURLOpener: URLOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var _openedURLs: [URL] = []

    var openedURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return _openedURLs
    }

    @discardableResult
    func open(_ url: URL) -> Bool {
        lock.lock()
        _openedURLs.append(url)
        lock.unlock()
        return true
    }
}

private final class FailingHTTPTransport: HTTPTransport, @unchecked Sendable {
    func send(_ request: URLRequest, timeout: TimeInterval) async throws -> HTTPResponseData {
        XCTFail("Demo mode must never perform HTTP requests")
        throw LiveProviderTransportError.networkUnavailable
    }
}

private final class FailingKeychain: KeychainReading, @unchecked Sendable {
    func readGenericPassword(service: String, account: String?) throws -> Data? {
        XCTFail("Demo mode must never read the Keychain")
        return nil
    }
}

private final class FailingLocalFileReader: LocalFileReader, @unchecked Sendable {
    func readFile(at url: URL) throws -> Data? {
        XCTFail("Demo mode must never read local files")
        return nil
    }

    func discoverFiles(under root: URL, matching predicate: @Sendable (URL) -> Bool) -> [DiscoveredLocalFile] {
        XCTFail("Demo mode must never scan local directories")
        return []
    }

    func readSQLiteItems(at dbURL: URL, keys: [String]) throws -> [String: String]? {
        XCTFail("Demo mode must never read local SQLite databases")
        return nil
    }
}

private final class FailingDisableStore: ProviderDisableStoring, @unchecked Sendable {
    func isDisabled(_ provider: ProviderID) -> Bool {
        XCTFail("Demo mode must never read live disable flags")
        return false
    }

    func setDisabled(_ disabled: Bool, for provider: ProviderID) {
        XCTFail("Demo mode must never write live disable flags")
    }
}

private final class FailingURLOpener: URLOpening, @unchecked Sendable {
    @discardableResult
    func open(_ url: URL) -> Bool {
        XCTFail("Demo mode must never open external URLs")
        return false
    }
}

private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date

    init(_ date: Date) {
        self._now = date
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return _now
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        _now = _now.addingTimeInterval(seconds)
        lock.unlock()
    }
}

private final class ToggleableDiagnosableProvider: DiagnosableUsageProvider, @unchecked Sendable {
    let provider: ProviderID
    private let lock = NSLock()
    private var _result: ProviderFetchResult
    private var _fetchCount = 0

    var fetchCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _fetchCount
    }

    init(provider: ProviderID, result: ProviderFetchResult) {
        self.provider = provider
        self._result = result
    }

    func setResult(_ result: ProviderFetchResult) {
        lock.lock()
        _result = result
        lock.unlock()
    }

    func fetchResult() async -> ProviderFetchResult {
        lock.withLock {
            _fetchCount += 1
            return _result
        }
    }

    func signIn() async throws -> ProviderSnapshot {
        await fetchResult().snapshot
    }

    func signOut() async throws -> ProviderSnapshot {
        ProviderSnapshot(
            provider: provider,
            plan: "",
            connectionState: .notConnected,
            limits: [],
            connectedVia: "Not connected"
        )
    }
}

// MARK: - Fixture Loader Helper

private func loadLiveFixture(_ filename: String) throws -> Data {
    let bundle = Bundle(for: LiveProvidersTests.self)
    if let url = bundle.url(forResource: filename, withExtension: nil, subdirectory: "Fixtures/live-providers") {
        return try Data(contentsOf: url)
    }
    let fallback = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/live-providers/\(filename)")
    return try Data(contentsOf: fallback)
}

private func makeSyntheticJWT(expEpochSeconds: Int) -> String {
    let header = Data("{\"alg\":\"HS256\",\"typ\":\"JWT\"}".utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    let payload = Data("{\"sub\":\"fixture-user-0001\",\"exp\":\(expEpochSeconds)}".utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "\(header).\(payload).fixtureSignatureSegment"
}

// MARK: - Live Providers Tests

final class LiveProvidersTests: XCTestCase {
    private static let referenceNow = LogTimestampParser.parseISO8601("2026-11-26T18:41:00Z")!
    private static let utc = TimeZone(secondsFromGMT: 0)!
    private var referenceNow: Date { Self.referenceNow }
    private var utc: TimeZone { Self.utc }

    // MARK: - Claude Provider

    func testClaudeProviderSuccessExpiredNotConnectedAndMalformed() async throws {
        let successBody = try loadLiveFixture("claude-usage-success.json")
        let malformedBody = try loadLiveFixture("claude-usage-malformed.json")
        let futureMs = Int64(referenceNow.addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        let pastMs = Int64(referenceNow.addingTimeInterval(-600).timeIntervalSince1970 * 1000)

        let validCred = Data("""
        {"claudeAiOauth":{"accessToken":"fixture-claude-token-alpha-001","expiresAt":\(futureMs),"subscriptionType":"max","rateLimitTier":"default_claude_max_5x"}}
        """.utf8)
        let expiredCred = Data("""
        {"claudeAiOauth":{"accessToken":"fixture-claude-token-expired-002","expiresAt":\(pastMs),"subscriptionType":"pro"}}
        """.utf8)

        // 1. Not connected (missing Keychain item, zero network calls)
        let emptyKeychain = StubKeychain()
        let transportNever = StubHTTPTransport { _, _ in
            XCTFail("Should not hit network without local credentials")
            return HTTPResponseData(statusCode: 500, body: Data())
        }
        let notConnectedProvider = ClaudeUsageProvider(
            keychain: emptyKeychain,
            httpTransport: transportNever,
            disableStore: InMemoryProviderDisableStore(),
            clock: { Self.referenceNow },
            timeZone: utc
        )
        let notConnected = await notConnectedProvider.fetchResult()
        XCTAssertEqual(notConnected.snapshot.connectionState, .notConnected)
        XCTAssertTrue(transportNever.requests.isEmpty)

        // 2. Success
        let keychain = StubKeychain(items: [ClaudeUsageProvider.defaultKeychainService: validCred])
        let successTransport = StubHTTPTransport { req, timeout in
            XCTAssertEqual(timeout, URLSessionHTTPTransport.defaultTimeout)
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-claude-token-alpha-001")
            XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
            return HTTPResponseData(statusCode: 200, body: successBody)
        }
        let disableStore = InMemoryProviderDisableStore()
        let urlOpener = RecordingURLOpener()
        let successProvider = ClaudeUsageProvider(
            keychain: keychain,
            httpTransport: successTransport,
            disableStore: disableStore,
            urlOpener: urlOpener,
            clock: { Self.referenceNow },
            timeZone: utc
        )
        let successResult = await successProvider.fetchResult()
        XCTAssertEqual(successResult.snapshot.connectionState, .connected)
        XCTAssertEqual(successResult.snapshot.plan, "Max 5x")
        XCTAssertEqual(successResult.snapshot.connectedVia, ClaudeUsageProvider.connectedSourceLabel)
        XCTAssertEqual(successResult.snapshot.limits.map(\.name), ["5-hour session", "Weekly · all models", "Weekly · Opus"])
        XCTAssertEqual(successResult.snapshot.limits.map(\.percentUsed), [62, 38, 81])
        XCTAssertEqual(successResult.snapshot.fullestLimit?.percentUsed, 81)

        // 3. Sign out disables OpenUsage without touching Keychain, and fetch skips Keychain/network
        let signedOut = try await successProvider.signOut()
        XCTAssertEqual(signedOut.connectionState, .notConnected)
        XCTAssertTrue(disableStore.isDisabled(.claude))
        let readsBefore = keychain.readCount
        let reqsBefore = successTransport.requests.count
        let disabledFetch = await successProvider.fetchResult()
        XCTAssertEqual(disabledFetch.snapshot.connectionState, .notConnected)
        XCTAssertEqual(keychain.readCount, readsBefore)
        XCTAssertEqual(successTransport.requests.count, reqsBefore)

        // Sign in clears disable flag and reconnects via local login without opening browser
        let reconnected = try await successProvider.signIn()
        XCTAssertEqual(reconnected.connectionState, .connected)
        XCTAssertFalse(disableStore.isDisabled(.claude))
        XCTAssertTrue(urlOpener.openedURLs.isEmpty)

        // 4. Local expiry -> .expired without network
        let expiredLocalProvider = ClaudeUsageProvider(
            keychain: StubKeychain(items: [ClaudeUsageProvider.defaultKeychainService: expiredCred]),
            httpTransport: transportNever,
            disableStore: InMemoryProviderDisableStore(),
            clock: { Self.referenceNow },
            timeZone: utc
        )
        let localExpired = await expiredLocalProvider.fetchResult()
        XCTAssertEqual(localExpired.snapshot.connectionState, .expired)
        XCTAssertEqual(localExpired.snapshot.plan, "Pro")

        // 5. HTTP 401 -> .expired with status diagnostic
        let unauthorizedProvider = ClaudeUsageProvider(
            keychain: keychain,
            httpTransport: StubHTTPTransport { _, _ in HTTPResponseData(statusCode: 401, body: Data("{\"error\":\"unauthorized\"}".utf8)) },
            disableStore: InMemoryProviderDisableStore(),
            clock: { Self.referenceNow },
            timeZone: utc
        )
        let unauthorized = await unauthorizedProvider.fetchResult()
        XCTAssertEqual(unauthorized.snapshot.connectionState, .expired)
        XCTAssertEqual(unauthorized.diagnostic?.httpStatus, 401)

        // 6. Malformed 200 JSON -> .unsupported
        let malformedProvider = ClaudeUsageProvider(
            keychain: keychain,
            httpTransport: StubHTTPTransport { _, _ in HTTPResponseData(statusCode: 200, body: malformedBody) },
            disableStore: InMemoryProviderDisableStore(),
            clock: { Self.referenceNow },
            timeZone: utc
        )
        let malformed = await malformedProvider.fetchResult()
        XCTAssertEqual(malformed.snapshot.connectionState, .unsupported)
        XCTAssertEqual(malformed.snapshot.menuBarEntryState, .omitted)

        // 7. Sign-in when missing local login opens provider web login page
        let missingOpener = RecordingURLOpener()
        let missingSignInProvider = ClaudeUsageProvider(
            keychain: emptyKeychain,
            httpTransport: transportNever,
            disableStore: InMemoryProviderDisableStore(),
            urlOpener: missingOpener,
            clock: { Self.referenceNow },
            timeZone: utc
        )
        let missingSignIn = try await missingSignInProvider.signIn()
        XCTAssertEqual(missingSignIn.connectionState, .notConnected)
        XCTAssertEqual(missingOpener.openedURLs, [ClaudeUsageProvider.loginPageURL])
    }

    // MARK: - ChatGPT / Codex Provider

    func testChatGPTProviderRolloutSuccessStaleExpiredNotConnectedAndMalformed() async throws {
        let rolloutData = try loadLiveFixture("codex-rollout-rate-limits.jsonl")
        let malformedRollout = try loadLiveFixture("codex-rollout-malformed.jsonl")
        let sessionsDir = URL(fileURLWithPath: "/virtual/.codex/sessions", isDirectory: true)
        let rolloutURL = sessionsDir.appendingPathComponent("2026/11/26/rollout-2026-11-26.jsonl")
        let authURL = URL(fileURLWithPath: "/virtual/.codex/auth.json")
        let meta = FileMetadata(size: UInt64(rolloutData.count), mtimeNanos: 1_795_718_100_000_000_000, inode: 10, isRegularFile: true, isDataless: false)

        let validJWT = makeSyntheticJWT(expEpochSeconds: Int(referenceNow.addingTimeInterval(3600).timeIntervalSince1970))
        let validAuth = Data("{\"tokens\":{\"access_token\":\"\(validJWT)\"},\"plan_type\":\"plus\"}".utf8)

        // 1. Fresh rollout data with valid auth.json -> .connected (no network!)
        let freshReader = StubLocalFileReader(
            files: [
                authURL.path: validAuth,
                rolloutURL.path: rolloutData
            ],
            discovered: [DiscoveredLocalFile(url: rolloutURL, relativePath: "2026/11/26/rollout-2026-11-26.jsonl", metadata: meta)]
        )
        let freshProvider = ChatGPTUsageProvider(
            fileReader: freshReader,
            disableStore: InMemoryProviderDisableStore(),
            sessionsDirectory: sessionsDir,
            authFileURL: authURL,
            clock: { Self.referenceNow }, // 6 minutes after 18:35Z event
            timeZone: utc
        )
        let fresh = await freshProvider.fetchResult()
        XCTAssertEqual(fresh.snapshot.connectionState, .connected)
        XCTAssertEqual(fresh.snapshot.plan, "Plus · Codex")
        XCTAssertEqual(fresh.snapshot.connectedVia, ChatGPTUsageProvider.freshSourceLabel)
        XCTAssertEqual(fresh.snapshot.limits.map(\.name), ["5-hour", "Weekly"])
        XCTAssertEqual(fresh.snapshot.limits.map(\.percentUsed), [21, 54])

        // 2. Stale rollout data (2 hours later, valid auth) shows age in connectedVia
        let staleNow = referenceNow.addingTimeInterval(2 * 3600)
        let staleValidJWT = makeSyntheticJWT(expEpochSeconds: Int(staleNow.addingTimeInterval(3600).timeIntervalSince1970))
        let staleValidAuth = Data("{\"tokens\":{\"access_token\":\"\(staleValidJWT)\"},\"plan_type\":\"plus\"}".utf8)
        let staleReader = StubLocalFileReader(
            files: [
                authURL.path: staleValidAuth,
                rolloutURL.path: rolloutData
            ],
            discovered: [DiscoveredLocalFile(url: rolloutURL, relativePath: "2026/11/26/rollout-2026-11-26.jsonl", metadata: meta)]
        )
        let staleProvider = ChatGPTUsageProvider(
            fileReader: staleReader,
            disableStore: InMemoryProviderDisableStore(),
            sessionsDirectory: sessionsDir,
            authFileURL: authURL,
            clock: { staleNow },
            timeZone: utc
        )
        let stale = await staleProvider.fetchResult()
        XCTAssertEqual(stale.snapshot.connectionState, .connected)
        XCTAssertTrue(stale.snapshot.connectedVia.contains("2h ago"))

        // 3. Not connected (no rollout files, no auth.json)
        let emptyProvider = ChatGPTUsageProvider(
            fileReader: StubLocalFileReader(),
            disableStore: InMemoryProviderDisableStore(),
            sessionsDirectory: sessionsDir,
            authFileURL: authURL,
            clock: { Self.referenceNow },
            timeZone: utc
        )
        let notConnected = await emptyProvider.fetchResult()
        XCTAssertEqual(notConnected.snapshot.connectionState, .notConnected)

        // 4. Expired JWT in auth.json (no rollout rate limits) -> .expired
        let expiredJWT = makeSyntheticJWT(expEpochSeconds: Int(referenceNow.addingTimeInterval(-3600).timeIntervalSince1970))
        let expiredAuth = Data("{\"tokens\":{\"access_token\":\"\(expiredJWT)\"},\"plan_type\":\"plus\"}".utf8)
        let expiredProvider = ChatGPTUsageProvider(
            fileReader: StubLocalFileReader(files: [authURL.path: expiredAuth]),
            disableStore: InMemoryProviderDisableStore(),
            sessionsDirectory: sessionsDir,
            authFileURL: authURL,
            clock: { Self.referenceNow },
            timeZone: utc
        )
        let expired = await expiredProvider.fetchResult()
        XCTAssertEqual(expired.snapshot.connectionState, .expired)
        XCTAssertEqual(expired.snapshot.plan, "Plus · Codex")

        // 5. Malformed rollout rate_limits with valid auth -> .unsupported
        let malformedProvider = ChatGPTUsageProvider(
            fileReader: StubLocalFileReader(
                files: [
                    authURL.path: validAuth,
                    rolloutURL.path: malformedRollout
                ],
                discovered: [DiscoveredLocalFile(url: rolloutURL, relativePath: "2026/11/26/rollout-2026-11-26.jsonl", metadata: meta)]
            ),
            disableStore: InMemoryProviderDisableStore(),
            sessionsDirectory: sessionsDir,
            authFileURL: authURL,
            clock: { Self.referenceNow },
            timeZone: utc
        )
        let malformed = await malformedProvider.fetchResult()
        XCTAssertEqual(malformed.snapshot.connectionState, .unsupported)
    }

    // MARK: - Cursor Provider (including real read-only SQLite test)

    func testCursorProviderSuccessExpiredNotConnectedMalformedAndReadOnlySQLite() async throws {
        let successBody = try loadLiveFixture("cursor-usage-success.json")
        let malformedBody = try loadLiveFixture("cursor-usage-malformed.json")

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("openusage-cursor-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("state.vscdb")
        let validJWT = makeSyntheticJWT(expEpochSeconds: Int(referenceNow.addingTimeInterval(3600).timeIntervalSince1970))
        try createCursorStateDB(at: dbURL, entries: [
            "cursorAuth/accessToken": validJWT,
            "cursorAuth/stripeMembershipType": "pro",
            "cursorAuth/cachedEmail": "private.fixture.user@example.com"
        ])

        // Verify SystemLocalFileReader reads ONLY requested keys (never email)
        let realReader = SystemLocalFileReader()
        let readBack = try realReader.readSQLiteItems(at: dbURL, keys: ["cursorAuth/accessToken", "cursorAuth/stripeMembershipType"])
        XCTAssertEqual(readBack?["cursorAuth/accessToken"], validJWT)
        XCTAssertEqual(readBack?["cursorAuth/stripeMembershipType"], "pro")
        XCTAssertNil(readBack?["cursorAuth/cachedEmail"])

        // 1. Success with real SQLite read-only file reader
        let successTransport = StubHTTPTransport { req, _ in
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer \(validJWT)")
            return HTTPResponseData(statusCode: 200, body: successBody)
        }
        let cursorProvider = CursorUsageProvider(
            fileReader: realReader,
            httpTransport: successTransport,
            disableStore: InMemoryProviderDisableStore(),
            stateDBURL: dbURL,
            clock: { Self.referenceNow },
            timeZone: utc
        )
        let success = await cursorProvider.fetchResult()
        XCTAssertEqual(success.snapshot.connectionState, .connected)
        XCTAssertEqual(success.snapshot.plan, "Pro")
        XCTAssertEqual(success.snapshot.connectedVia, CursorUsageProvider.connectedSourceLabel)
        XCTAssertEqual(success.snapshot.limits.count, 1)
        XCTAssertEqual(success.snapshot.limits.first?.name, "Included usage")
        XCTAssertEqual(success.snapshot.limits.first?.percentUsed, 67)
        XCTAssertTrue(success.snapshot.limits.first?.resetText.contains("$13.40 of $20") == true)
        XCTAssertFalse(success.snapshot.connectedVia.contains("private.fixture.user@example.com"))

        // 2. Not connected (missing DB)
        let missingDB = tempDir.appendingPathComponent("missing.vscdb")
        let missingProvider = CursorUsageProvider(
            fileReader: realReader,
            httpTransport: StubHTTPTransport { _, _ in
                XCTFail("No HTTP expected when state.vscdb is missing")
                return HTTPResponseData(statusCode: 500, body: Data())
            },
            disableStore: InMemoryProviderDisableStore(),
            stateDBURL: missingDB,
            clock: { Self.referenceNow },
            timeZone: utc
        )
        let notConnected = await missingProvider.fetchResult()
        XCTAssertEqual(notConnected.snapshot.connectionState, .notConnected)

        // 3. Expired (401)
        let expiredProvider = CursorUsageProvider(
            fileReader: realReader,
            httpTransport: StubHTTPTransport { _, _ in HTTPResponseData(statusCode: 401, body: Data()) },
            disableStore: InMemoryProviderDisableStore(),
            stateDBURL: dbURL,
            clock: { Self.referenceNow },
            timeZone: utc
        )
        let expired = await expiredProvider.fetchResult()
        XCTAssertEqual(expired.snapshot.connectionState, .expired)
        XCTAssertEqual(expired.diagnostic?.httpStatus, 401)

        // 4. Malformed 200 -> .unsupported
        let malformedProvider = CursorUsageProvider(
            fileReader: realReader,
            httpTransport: StubHTTPTransport { _, _ in HTTPResponseData(statusCode: 200, body: malformedBody) },
            disableStore: InMemoryProviderDisableStore(),
            stateDBURL: dbURL,
            clock: { Self.referenceNow },
            timeZone: utc
        )
        let malformed = await malformedProvider.fetchResult()
        XCTAssertEqual(malformed.snapshot.connectionState, .unsupported)
    }

    // MARK: - Gemini Provider

    func testGeminiProviderSuccessExpiredNotConnectedAndMalformed() async throws {
        let loadBody = try loadLiveFixture("gemini-load-code-assist-success.json")
        let quotaSuccessBody = try loadLiveFixture("gemini-quota-success.json")
        let quotaMalformedBody = try loadLiveFixture("gemini-quota-malformed.json")
        let credsURL = URL(fileURLWithPath: "/virtual/.gemini/oauth_creds.json")
        let futureMs = Int64(referenceNow.addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        let pastMs = Int64(referenceNow.addingTimeInterval(-3600).timeIntervalSince1970 * 1000)

        let validCreds = Data("{\"access_token\":\"fixture-gemini-token-001\",\"expiry_date\":\(futureMs)}".utf8)
        let expiredCreds = Data("{\"access_token\":\"fixture-gemini-token-old\",\"expiry_date\":\(pastMs)}".utf8)

        // 1. Not connected
        let missingProvider = GeminiUsageProvider(
            fileReader: StubLocalFileReader(),
            httpTransport: StubHTTPTransport { _, _ in
                XCTFail("No HTTP expected when oauth_creds.json is missing")
                return HTTPResponseData(statusCode: 500, body: Data())
            },
            disableStore: InMemoryProviderDisableStore(),
            oauthCredsURL: credsURL,
            clock: { Self.referenceNow },
            timeZone: utc
        )
        let notConnected = await missingProvider.fetchResult()
        XCTAssertEqual(notConnected.snapshot.connectionState, .notConnected)

        // 2. Success via injected quota endpoint (loadCodeAssist + retrieveUserQuota)
        let successTransport = StubHTTPTransport { req, _ in
            if req.url?.absoluteString.contains("loadCodeAssist") == true {
                return HTTPResponseData(statusCode: 200, body: loadBody)
            }
            return HTTPResponseData(statusCode: 200, body: quotaSuccessBody)
        }
        let successProvider = GeminiUsageProvider(
            fileReader: StubLocalFileReader(files: [credsURL.path: validCreds]),
            httpTransport: successTransport,
            disableStore: InMemoryProviderDisableStore(),
            oauthCredsURL: credsURL,
            quotaEndpoint: GeminiUsageProvider.defaultQuotaEndpoint,
            clock: { Self.referenceNow },
            timeZone: utc
        )
        let success = await successProvider.fetchResult()
        XCTAssertEqual(success.snapshot.connectionState, .connected)
        XCTAssertEqual(success.snapshot.plan, "Google AI Pro")
        XCTAssertEqual(success.snapshot.connectedVia, GeminiUsageProvider.connectedSourceLabel)
        XCTAssertEqual(success.snapshot.limits.count, 1)
        XCTAssertEqual(success.snapshot.limits.first?.name, "Daily requests")
        XCTAssertEqual(success.snapshot.limits.first?.percentUsed, 21)

        // 3. Expired locally (with injected quota endpoint)
        let expiredLocal = await GeminiUsageProvider(
            fileReader: StubLocalFileReader(files: [credsURL.path: expiredCreds]),
            httpTransport: StubHTTPTransport { _, _ in
                XCTFail("No HTTP expected when token already expired locally")
                return HTTPResponseData(statusCode: 500, body: Data())
            },
            disableStore: InMemoryProviderDisableStore(),
            oauthCredsURL: credsURL,
            quotaEndpoint: GeminiUsageProvider.defaultQuotaEndpoint,
            clock: { Self.referenceNow },
            timeZone: utc
        ).fetchResult()
        XCTAssertEqual(expiredLocal.snapshot.connectionState, .expired)

        // 4. HTTP 401 (with injected quota endpoint)
        let expiredHTTP = await GeminiUsageProvider(
            fileReader: StubLocalFileReader(files: [credsURL.path: validCreds]),
            httpTransport: StubHTTPTransport { _, _ in HTTPResponseData(statusCode: 401, body: Data()) },
            disableStore: InMemoryProviderDisableStore(),
            oauthCredsURL: credsURL,
            quotaEndpoint: GeminiUsageProvider.defaultQuotaEndpoint,
            clock: { Self.referenceNow },
            timeZone: utc
        ).fetchResult()
        XCTAssertEqual(expiredHTTP.snapshot.connectionState, .expired)
        XCTAssertEqual(expiredHTTP.diagnostic?.httpStatus, 401)

        // 5. Malformed quota response -> .unsupported
        let malformed = await GeminiUsageProvider(
            fileReader: StubLocalFileReader(files: [credsURL.path: validCreds]),
            httpTransport: StubHTTPTransport { req, _ in
                if req.url?.absoluteString.contains("loadCodeAssist") == true {
                    return HTTPResponseData(statusCode: 200, body: loadBody)
                }
                return HTTPResponseData(statusCode: 200, body: quotaMalformedBody)
            },
            disableStore: InMemoryProviderDisableStore(),
            oauthCredsURL: credsURL,
            quotaEndpoint: GeminiUsageProvider.defaultQuotaEndpoint,
            clock: { Self.referenceNow },
            timeZone: utc
        ).fetchResult()
        XCTAssertEqual(malformed.snapshot.connectionState, .unsupported)
    }

    // MARK: - OpenCode Provider

    func testOpenCodeProviderDefaultGoEndpointSuccessExpiredNotConnectedMalformed() async throws {
        let goAuthFixture = try loadLiveFixture("opencode-auth-go.json")
        let successBody = try loadLiveFixture("opencode-usage-success.json")
        let malformedBody = try loadLiveFixture("opencode-usage-malformed.json")
        let authURL = URL(fileURLWithPath: "/virtual/.local/share/opencode/auth.json")
        let testEndpoint = URL(string: "https://opencode.invalid/inference/go/v1/usage")!

        let pastMs = Int64(referenceNow.addingTimeInterval(-3600).timeIntervalSince1970 * 1000)
        let expiredGoOAuth = Data("{\"opencode-go\":{\"type\":\"oauth\",\"access\":\"fixture-opencode-go-oauth-002\",\"expires\":\(pastMs)}}".utf8)

        // 1. Not connected (missing file)
        let missing = await OpenCodeUsageProvider(
            fileReader: StubLocalFileReader(),
            httpTransport: StubHTTPTransport { _, _ in
                XCTFail("No HTTP expected when OpenCode auth.json is missing")
                return HTTPResponseData(statusCode: 500, body: Data())
            },
            disableStore: InMemoryProviderDisableStore(),
            authFileURL: authURL,
            clock: { Self.referenceNow },
            timeZone: utc
        ).fetchResult()
        XCTAssertEqual(missing.snapshot.connectionState, .notConnected)
        XCTAssertEqual(missing.snapshot.menuBarEntryState, .omitted)

        // 2. Default production endpoint hits GET https://opencode.ai/inference/go/v1/usage with Bearer Go key
        let defaultTransport = StubHTTPTransport { req, timeout in
            XCTAssertEqual(timeout, URLSessionHTTPTransport.defaultTimeout)
            XCTAssertEqual(req.httpMethod, "GET")
            XCTAssertEqual(req.url?.absoluteString, "https://opencode.ai/inference/go/v1/usage")
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-opencode-go-key-001")
            XCTAssertEqual(req.value(forHTTPHeaderField: "Accept"), "application/json")
            return HTTPResponseData(statusCode: 200, body: successBody)
        }
        let disableStore = InMemoryProviderDisableStore()
        let urlOpener = RecordingURLOpener()
        let defaultProvider = OpenCodeUsageProvider(
            fileReader: StubLocalFileReader(files: [authURL.path: goAuthFixture]),
            httpTransport: defaultTransport,
            disableStore: disableStore,
            urlOpener: urlOpener,
            authFileURL: authURL,
            clock: { Self.referenceNow },
            timeZone: utc
        )
        let success = await defaultProvider.fetchResult()
        XCTAssertEqual(success.snapshot.connectionState, .connected)
        XCTAssertEqual(success.snapshot.plan, "Go")
        XCTAssertEqual(success.snapshot.connectedVia, OpenCodeUsageProvider.connectedSourceLabel)
        XCTAssertEqual(success.snapshot.limits.map(\.id), ["opencode-rolling", "opencode-weekly", "opencode-monthly"])
        XCTAssertEqual(success.snapshot.limits.map(\.name), ["5-hour", "Weekly", "Monthly"])
        XCTAssertEqual(success.snapshot.limits.map(\.percentUsed), [30, 100, 50])
        XCTAssertEqual(success.snapshot.limits[0].resetText, "Resets in 2h 19m")
        XCTAssertEqual(success.snapshot.limits[1].resetText, "Rate limited · Resets Mon 12:00 AM")
        XCTAssertEqual(success.snapshot.limits[2].resetText, "Resets Tue 12:00 AM")
        XCTAssertEqual(success.snapshot.fullestLimit?.name, "Weekly")
        XCTAssertEqual(success.snapshot.fullestLimit?.percentUsed, 100)
        XCTAssertEqual(success.snapshot.menuBarEntryState, .connected(percent: 100))
        XCTAssertEqual(success.diagnostic?.httpStatus, 200)
        XCTAssertEqual(success.diagnostic?.warnings, [])
        XCTAssertEqual(defaultTransport.requests.count, 1)

        // Sign out disables provider without touching local file or network; sign in reconnects cleanly
        let signedOut = try await defaultProvider.signOut()
        XCTAssertEqual(signedOut.connectionState, .notConnected)
        XCTAssertTrue(disableStore.isDisabled(.opencode))
        let disabledFetch = await defaultProvider.fetchResult()
        XCTAssertEqual(disabledFetch.snapshot.connectionState, .notConnected)
        XCTAssertEqual(defaultTransport.requests.count, 1)

        let reconnected = try await defaultProvider.signIn()
        XCTAssertEqual(reconnected.connectionState, .connected)
        XCTAssertFalse(disableStore.isDisabled(.opencode))
        XCTAssertTrue(urlOpener.openedURLs.isEmpty)
        XCTAssertEqual(defaultTransport.requests.count, 2)

        // 3. Injected custom usageEndpoint works for tests
        let injectedTransport = StubHTTPTransport { req, _ in
            XCTAssertEqual(req.url, testEndpoint)
            return HTTPResponseData(statusCode: 200, body: successBody)
        }
        let injected = await OpenCodeUsageProvider(
            fileReader: StubLocalFileReader(files: [authURL.path: goAuthFixture]),
            httpTransport: injectedTransport,
            disableStore: InMemoryProviderDisableStore(),
            authFileURL: authURL,
            usageEndpoint: testEndpoint,
            clock: { Self.referenceNow },
            timeZone: utc
        ).fetchResult()
        XCTAssertEqual(injected.snapshot.connectionState, .connected)
        XCTAssertEqual(injectedTransport.requests.map(\.url), [testEndpoint.absoluteString])

        // 4. Local OAuth expiry on opencode-go -> .expired without network
        let expiredLocal = await OpenCodeUsageProvider(
            fileReader: StubLocalFileReader(files: [authURL.path: expiredGoOAuth]),
            httpTransport: StubHTTPTransport { _, _ in
                XCTFail("No HTTP expected when opencode-go OAuth token is already expired locally")
                return HTTPResponseData(statusCode: 200, body: successBody)
            },
            disableStore: InMemoryProviderDisableStore(),
            authFileURL: authURL,
            usageEndpoint: testEndpoint,
            clock: { Self.referenceNow },
            timeZone: utc
        ).fetchResult()
        XCTAssertEqual(expiredLocal.snapshot.connectionState, .expired)
        XCTAssertEqual(expiredLocal.snapshot.menuBarEntryState, .dimmedPlaceholder)

        // 5. Malformed 200 fixture -> .unsupported with warnings
        let malformed = await OpenCodeUsageProvider(
            fileReader: StubLocalFileReader(files: [authURL.path: goAuthFixture]),
            httpTransport: StubHTTPTransport { _, _ in HTTPResponseData(statusCode: 200, body: malformedBody) },
            disableStore: InMemoryProviderDisableStore(),
            authFileURL: authURL,
            usageEndpoint: testEndpoint,
            clock: { Self.referenceNow },
            timeZone: utc
        ).fetchResult()
        XCTAssertEqual(malformed.snapshot.connectionState, .unsupported)
        XCTAssertTrue(malformed.snapshot.limits.isEmpty)
        XCTAssertEqual(malformed.snapshot.menuBarEntryState, .omitted)
        XCTAssertEqual(malformed.diagnostic?.httpStatus, 200)
        XCTAssertTrue(malformed.diagnostic?.warnings.contains("usage.rolling.status: present but not parseable") == true)
        XCTAssertTrue(malformed.diagnostic?.warnings.contains("usage.rolling.percent: present but not parseable") == true)
        XCTAssertTrue(malformed.diagnostic?.warnings.contains("usage.rolling.resetsAt: present but not parseable") == true)
        XCTAssertTrue(malformed.diagnostic?.warnings.contains("usage.weekly.percent: present but not parseable") == true)
        XCTAssertTrue(malformed.diagnostic?.warnings.contains("usage.monthly.percent: present but not parseable") == true)
    }

    // MARK: - KeychainStore Round-Trip Tests

    func testKeychainStoreQueryLogicAndRoundTripWithInMemorySecItemBackend() throws {
        final class InMemorySecItemBackend: SecItemBackend, @unchecked Sendable {
            private let lock = NSLock()
            private var storage: [String: [String: Data]] = [:]

            func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: Any?) {
                guard let service = query[kSecAttrService as String] as? String else {
                    return (errSecParam, nil)
                }
                let account = query[kSecAttrAccount as String] as? String
                return lock.withLock {
                    guard let entries = storage[service], !entries.isEmpty else {
                        return (errSecItemNotFound, nil)
                    }
                    if let account {
                        guard let data = entries[account] else {
                            return (errSecItemNotFound, nil)
                        }
                        return (errSecSuccess, data)
                    }
                    return (errSecSuccess, entries.values.first)
                }
            }

            func add(_ attributes: [String: Any]) -> OSStatus {
                guard let service = attributes[kSecAttrService as String] as? String,
                      let account = attributes[kSecAttrAccount as String] as? String,
                      let data = attributes[kSecValueData as String] as? Data else {
                    return errSecParam
                }
                return lock.withLock {
                    if storage[service]?[account] != nil {
                        return errSecDuplicateItem
                    }
                    storage[service, default: [:]][account] = data
                    return errSecSuccess
                }
            }

            func update(_ query: [String: Any], attributesToUpdate: [String: Any]) -> OSStatus {
                guard let service = query[kSecAttrService as String] as? String,
                      let account = query[kSecAttrAccount as String] as? String,
                      let data = attributesToUpdate[kSecValueData as String] as? Data else {
                    return errSecParam
                }
                return lock.withLock {
                    guard storage[service]?[account] != nil else {
                        return errSecItemNotFound
                    }
                    storage[service]?[account] = data
                    return errSecSuccess
                }
            }

            func delete(_ query: [String: Any]) -> OSStatus {
                guard let service = query[kSecAttrService as String] as? String,
                      let account = query[kSecAttrAccount as String] as? String else {
                    return errSecParam
                }
                return lock.withLock {
                    guard storage[service]?.removeValue(forKey: account) != nil else {
                        return errSecItemNotFound
                    }
                    return errSecSuccess
                }
            }
        }

        let store = SystemKeychainStore(backend: InMemorySecItemBackend())
        let service = "dev.jabree.OpenUsage.tests.unit"
        let account = "test-account"

        XCTAssertNil(try store.readGenericPassword(service: service, account: account))

        let firstPayload = Data("fixture-secret-v1".utf8)
        try store.writeGenericPassword(firstPayload, service: service, account: account)
        XCTAssertEqual(try store.readGenericPassword(service: service, account: account), firstPayload)
        XCTAssertEqual(try store.readGenericPassword(service: service, account: nil), firstPayload)

        let updatedPayload = Data("fixture-secret-v2-updated".utf8)
        try store.writeGenericPassword(updatedPayload, service: service, account: account)
        XCTAssertEqual(try store.readGenericPassword(service: service, account: account), updatedPayload)

        try store.deleteGenericPassword(service: service, account: account)
        XCTAssertNil(try store.readGenericPassword(service: service, account: account))

        // Deleting again is idempotent
        try store.deleteGenericPassword(service: service, account: account)
    }

    func testKeychainStoreWriteReadUpdateDeleteAgainstIsolatedTestService() throws {
        let store = SystemKeychainStore()
        let service = "dev.jabree.OpenUsage.tests.\(UUID().uuidString)"
        let account = "test-account"
        defer { try? store.deleteGenericPassword(service: service, account: account) }

        do {
            let initial = try store.readGenericPassword(service: service, account: account)
            XCTAssertNil(initial)

            let firstPayload = Data("fixture-secret-v1".utf8)
            try store.writeGenericPassword(firstPayload, service: service, account: account)
            let readFirst = try store.readGenericPassword(service: service, account: account)
            XCTAssertEqual(readFirst, firstPayload)

            let updatedPayload = Data("fixture-secret-v2-updated".utf8)
            try store.writeGenericPassword(updatedPayload, service: service, account: account)
            let readUpdated = try store.readGenericPassword(service: service, account: account)
            XCTAssertEqual(readUpdated, updatedPayload)

            try store.deleteGenericPassword(service: service, account: account)
            let afterDelete = try store.readGenericPassword(service: service, account: account)
            XCTAssertNil(afterDelete)

            // Deleting again is idempotent
            try store.deleteGenericPassword(service: service, account: account)
        } catch let error as KeychainStoreError {
            if case .osStatus(let code) = error,
               code == errSecParam || code == errSecInteractionNotAllowed || code == errSecNotAvailable || code == errSecNoSuchKeychain {
                throw XCTSkip("macOS login Keychain unavailable in restricted sandbox (OSStatus \(code))")
            }
            throw error
        }
    }

    // MARK: - Demo Mode Isolation Test

    @MainActor
    func testDemoModeNeverTouchesKeychainFilesNetworkDisableStoreOrURLOpener() async {
        let providers = UsageProviderRegistry.makeProviders(
            isDemo: true,
            demoScenario: .disconnected,
            httpTransport: FailingHTTPTransport(),
            fileReader: FailingLocalFileReader(),
            keychain: FailingKeychain(),
            disableStore: FailingDisableStore(),
            urlOpener: FailingURLOpener()
        )
        XCTAssertEqual(providers.count, ProviderID.allCases.count)

        let controller = AccountsController(
            isDemo: true,
            initialSnapshots: DemoFixtures.snapshots(for: .disconnected),
            providers: providers
        )
        defer { controller.cancelAll() }

        await controller.refreshAll()
        XCTAssertEqual(controller.snapshot(for: .claude).connectionState, .connected)
        XCTAssertEqual(controller.snapshot(for: .gemini).connectionState, .expired)
        XCTAssertEqual(controller.snapshot(for: .opencode).connectionState, .notConnected)

        let report = await LimitsDumper.generateReport(
            isDemo: true,
            demoScenario: .all,
            httpTransport: FailingHTTPTransport(),
            fileReader: FailingLocalFileReader(),
            keychain: FailingKeychain(),
            disableStore: FailingDisableStore(),
            urlOpener: FailingURLOpener()
        )
        XCTAssertTrue(report.contains("OpenUsage limits (demo)"))
        XCTAssertTrue(report.contains("claude: state=connected"))
        XCTAssertTrue(report.contains("Weekly · Opus: 81%"))
    }

    // MARK: - Secret Redaction Test

    func testSecretRedactorAndProviderErrorPathsNeverLeakTokensOrEmails() async {
        // Assemble synthetic secret patterns dynamically so literal secret scanners are not triggered.
        let syntheticAnthropicToken = ["sk", "ant", "oat01", "syntheticfixturetoken987654"].joined(separator: "-")
        let syntheticGoogleToken = ["ya29", "syntheticfixturetoken987654321"].joined(separator: ".")
        let syntheticJWT = makeSyntheticJWT(expEpochSeconds: Int(referenceNow.addingTimeInterval(3600).timeIntervalSince1970))
        let syntheticEmail = "fixture.person@example.com"

        // Direct SecretRedactor assertions
        let rawLeak = """
        Authorization: Bearer \(syntheticAnthropicToken) failed for \(syntheticEmail) with jwt \(syntheticJWT) and token \(syntheticGoogleToken) ?access_token=mysecretparam123 {"refresh_token":"supersecretrefresh"}
        """
        let redacted = SecretRedactor.sanitize(rawLeak, secrets: [syntheticAnthropicToken, syntheticGoogleToken, syntheticJWT], maxLength: 400)
        XCTAssertFalse(redacted.contains(syntheticAnthropicToken))
        XCTAssertFalse(redacted.contains(syntheticGoogleToken))
        XCTAssertFalse(redacted.contains(syntheticJWT))
        XCTAssertFalse(redacted.contains(syntheticEmail))
        XCTAssertFalse(redacted.contains("mysecretparam123"))
        XCTAssertFalse(redacted.contains("supersecretrefresh"))
        XCTAssertTrue(redacted.contains("[REDACTED]"))

        // Provider error path + --dump-limits redaction test when upstream echoes token & email in error body
        let futureMs = Int64(referenceNow.addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        let claudeCred = Data("""
        {"claudeAiOauth":{"accessToken":"\(syntheticAnthropicToken)","expiresAt":\(futureMs),"subscriptionType":"max"}}
        """.utf8)
        let leakyBody = Data("{\"error\":\"Invalid Bearer \(syntheticAnthropicToken) for \(syntheticEmail)\"}".utf8)

        let claude401 = ClaudeUsageProvider(
            keychain: StubKeychain(items: [ClaudeUsageProvider.defaultKeychainService: claudeCred]),
            httpTransport: StubHTTPTransport { _, _ in HTTPResponseData(statusCode: 401, body: leakyBody) },
            disableStore: InMemoryProviderDisableStore(),
            clock: { Self.referenceNow },
            timeZone: utc
        )
        let claude500 = ClaudeUsageProvider(
            keychain: StubKeychain(items: [ClaudeUsageProvider.defaultKeychainService: claudeCred]),
            httpTransport: StubHTTPTransport { _, _ in HTTPResponseData(statusCode: 500, body: leakyBody) },
            disableStore: InMemoryProviderDisableStore(),
            clock: { Self.referenceNow },
            timeZone: utc
        )
        let claudeMalformed = ClaudeUsageProvider(
            keychain: StubKeychain(items: [ClaudeUsageProvider.defaultKeychainService: claudeCred]),
            httpTransport: StubHTTPTransport { _, _ in HTTPResponseData(statusCode: 200, body: leakyBody) },
            disableStore: InMemoryProviderDisableStore(),
            clock: { Self.referenceNow },
            timeZone: utc
        )

        for provider in [claude401, claude500, claudeMalformed] {
            let result = await provider.fetchResult()
            let combined = [
                result.snapshot.plan,
                result.snapshot.connectedVia,
                result.diagnostic?.shortReason ?? ""
            ].joined(separator: " ")
            XCTAssertFalse(combined.contains(syntheticAnthropicToken))
            XCTAssertFalse(combined.contains(syntheticEmail))

            let report = LimitsDumper.formatReport(results: [result], isDemo: false)
            XCTAssertFalse(report.contains(syntheticAnthropicToken))
            XCTAssertFalse(report.contains(syntheticEmail))
        }
    }

    // MARK: - Failure Isolation & Exponential Backoff Test

    @MainActor
    func testPerProviderFailureIsolationAndExponentialBackoff() async {
        let clock = MutableClock(referenceNow)

        let claudeHealthy = DemoFixtures.snapshot(for: .claude, scenario: .all)
        let chatgptInitial = DemoFixtures.snapshot(for: .chatgpt, scenario: .all)
        let chatgptUpdated = ProviderSnapshot(
            provider: .chatgpt,
            plan: "Plus · Codex",
            connectionState: .connected,
            limits: [
                UsageLimit(id: "chatgpt-5h", name: "5-hour", percentUsed: 33, resetText: "Resets in 3h")
            ],
            connectedVia: ChatGPTUsageProvider.freshSourceLabel,
            updatedAt: referenceNow
        )

        let claudeProvider = ToggleableDiagnosableProvider(
            provider: .claude,
            result: ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: .claude,
                    plan: "Max 5x",
                    connectionState: .unsupported,
                    limits: [],
                    connectedVia: "Request timed out",
                    updatedAt: referenceNow
                ),
                diagnostic: ProviderFetchDiagnostic(shortReason: "Request timed out", isTransientError: true)
            )
        )
        let chatgptProvider = ToggleableDiagnosableProvider(
            provider: .chatgpt,
            result: ProviderFetchResult(snapshot: chatgptUpdated)
        )

        let providers: [any UsageProvider] = [
            claudeProvider,
            chatgptProvider,
            UnconfiguredUsageProvider(provider: .cursor),
            UnconfiguredUsageProvider(provider: .gemini),
            UnconfiguredUsageProvider(provider: .opencode)
        ]

        let initialSnapshots: [ProviderSnapshot] = [
            claudeHealthy,
            chatgptInitial,
            ProviderSnapshot(provider: .cursor, plan: "", connectionState: .notConnected, limits: [], connectedVia: "Not connected"),
            ProviderSnapshot(provider: .gemini, plan: "", connectionState: .notConnected, limits: [], connectedVia: "Not connected"),
            ProviderSnapshot(provider: .opencode, plan: "", connectionState: .notConnected, limits: [], connectedVia: "Not connected")
        ]

        let controller = AccountsController(
            isDemo: false,
            initialSnapshots: initialSnapshots,
            providers: providers,
            clock: { clock.now }
        )

        // 1st refresh: Claude fails transiently -> keeps its previously connected snapshot; ChatGPT updates!
        await controller.refreshAll()
        XCTAssertEqual(claudeProvider.fetchCount, 1)
        XCTAssertEqual(chatgptProvider.fetchCount, 1)
        XCTAssertEqual(controller.snapshot(for: .claude).connectionState, .connected)
        XCTAssertEqual(controller.snapshot(for: .claude).fullestLimit?.percentUsed, 81)
        XCTAssertEqual(controller.snapshot(for: .chatgpt).fullestLimit?.percentUsed, 33)
        XCTAssertEqual(controller.consecutiveFailureCount(for: .claude), 1)
        XCTAssertEqual(controller.nextAllowedRefreshDate(for: .claude), referenceNow.addingTimeInterval(60))

        // Refresh 30s later: Claude is skipped due to backoff (60s), ChatGPT still refreshes!
        clock.advance(by: 30)
        await controller.refreshAll()
        XCTAssertEqual(claudeProvider.fetchCount, 1)
        XCTAssertEqual(chatgptProvider.fetchCount, 2)

        // Advance past 60s -> 2nd failure doubles backoff to 120s
        clock.advance(by: 31)
        await controller.refreshAll()
        XCTAssertEqual(claudeProvider.fetchCount, 2)
        XCTAssertEqual(controller.consecutiveFailureCount(for: .claude), 2)
        XCTAssertEqual(controller.nextAllowedRefreshDate(for: .claude), clock.now.addingTimeInterval(120))

        // Advance past 120s and recover -> resets failure counter and backoff
        claudeProvider.setResult(ProviderFetchResult(snapshot: claudeHealthy))
        clock.advance(by: 121)
        await controller.refreshAll()
        XCTAssertEqual(claudeProvider.fetchCount, 3)
        XCTAssertEqual(controller.consecutiveFailureCount(for: .claude), 0)
        XCTAssertNil(controller.nextAllowedRefreshDate(for: .claude))

        // Verify backoff policy cap
        XCTAssertEqual(ProviderBackoffPolicy.delay(forConsecutiveFailures: 1), 60)
        XCTAssertEqual(ProviderBackoffPolicy.delay(forConsecutiveFailures: 2), 120)
        XCTAssertEqual(ProviderBackoffPolicy.delay(forConsecutiveFailures: 3), 240)
        XCTAssertEqual(ProviderBackoffPolicy.delay(forConsecutiveFailures: 4), 480)
        XCTAssertEqual(ProviderBackoffPolicy.delay(forConsecutiveFailures: 5), 900)
        XCTAssertEqual(ProviderBackoffPolicy.delay(forConsecutiveFailures: 10), 900)
    }

    // MARK: - LimitsDumper Output Format Test

    func testLimitsDumperFormatsAllStatesWithoutSecrets() async {
        let results: [ProviderFetchResult] = [
            ProviderFetchResult(snapshot: DemoFixtures.snapshot(for: .claude, scenario: .all)),
            ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: .chatgpt,
                    plan: "Plus · Codex",
                    connectionState: .expired,
                    limits: [],
                    connectedVia: "Codex CLI login expired"
                ),
                diagnostic: ProviderFetchDiagnostic(httpStatus: 401, shortReason: "HTTP 401")
            ),
            ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: .cursor,
                    plan: "",
                    connectionState: .notConnected,
                    limits: [],
                    connectedVia: "Not connected"
                )
            ),
            ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: .gemini,
                    plan: "",
                    connectionState: .unsupported,
                    limits: [],
                    connectedVia: "Gemini quota endpoint unsupported (HTTP 404)"
                ),
                diagnostic: ProviderFetchDiagnostic(httpStatus: 404, shortReason: "HTTP 404")
            ),
            ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: .opencode,
                    plan: "",
                    connectionState: .unsupported,
                    limits: [],
                    connectedVia: "Not yet supported — OpenCode login detected on this Mac"
                ),
                diagnostic: ProviderFetchDiagnostic(shortReason: "OpenCode credit API is not yet supported")
            )
        ]

        let report = LimitsDumper.formatReport(results: results, isDemo: false)
        XCTAssertTrue(report.contains("OpenUsage limits (live)"))
        XCTAssertTrue(report.contains("claude: state=connected plan=\"Max 5x\""))
        XCTAssertTrue(report.contains("  - 5-hour session: 62% (Resets in 2h 14m)"))
        XCTAssertTrue(report.contains("chatgpt: state=expired plan=\"Plus · Codex\" source=\"Codex CLI login expired\" status=401 reason=\"HTTP 401\""))
        XCTAssertTrue(report.contains("cursor: state=notConnected plan=\"\" source=\"Not connected\""))
        XCTAssertTrue(report.contains("gemini: state=unsupported"))
        XCTAssertTrue(report.contains("status=404"))
        XCTAssertTrue(report.contains("opencode: state=unsupported"))
        XCTAssertTrue(report.contains("OpenCode credit API is not yet supported"))
    }

    // MARK: - Finding 1: --dump-limits-shape Structure & Redaction Tests

    func testPayloadShapeDumpRedactsTokensEmailsIDsAndPrintsStructureOnly() async throws {
        let syntheticToken = ["sk", "ant", "oat01", "supersecrettokenvalue999"].joined(separator: "-")
        let syntheticOpaqueToken = "opaque_session_secret_abc123xyz"
        let syntheticEmail = "private.person@example.com"
        let syntheticID = "usr_9f8e7d6c5b4a3210"
        let syntheticName = "Jane Private"
        let syntheticURL = "https://private.example.invalid/account/billing"
        let isoTimestamp = "2026-11-26T20:55:00Z"

        let sensitivePayload = Data("""
        {
          "five_hour": {
            "utilization": 42,
            "resets_at": "\(isoTimestamp)"
          },
          "seven_day": {
            "utilization": 73.5,
            "resets_at": "2026-12-01T14:00:00Z"
          },
          "seven_day_opus": null,
          "enabled": true,
          "account": {
            "id": "\(syntheticID)",
            "email": "\(syntheticEmail)",
            "name": "\(syntheticName)",
            "token": "\(syntheticToken)",
            "session": "\(syntheticOpaqueToken)",
            "dashboard_url": "\(syntheticURL)"
          },
          "items": [
            {
              "item_id": "\(syntheticID)",
              "count": 7,
              "active": false
            },
            {
              "item_id": "second-hidden-id-should-not-print",
              "count": 99
            }
          ]
        }
        """.utf8)

        let futureMs = Int64(referenceNow.addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        let claudeCred = Data("""
        {"claudeAiOauth":{"accessToken":"\(syntheticToken)","expiresAt":\(futureMs),"subscriptionType":"max"}}
        """.utf8)
        let openCodeGoAuth = try loadLiveFixture("opencode-auth-go.json")
        let openCodeAuthURL = OpenCodeUsageProvider.defaultAuthFileURL()

        let report = await LimitsDumper.generateShapeReport(
            httpTransport: StubHTTPTransport { _, _ in
                HTTPResponseData(statusCode: 200, body: sensitivePayload)
            },
            fileReader: StubLocalFileReader(files: [openCodeAuthURL.path: openCodeGoAuth]),
            keychain: StubKeychain(items: [ClaudeUsageProvider.defaultKeychainService: claudeCred]),
            disableStore: InMemoryProviderDisableStore(),
            clock: { Self.referenceNow },
            timeZone: utc
        )

        // Must never leak tokens, emails, IDs, names, URLs, or second-element strings
        XCTAssertFalse(report.contains(syntheticToken))
        XCTAssertFalse(report.contains(syntheticOpaqueToken))
        XCTAssertFalse(report.contains(syntheticEmail))
        XCTAssertFalse(report.contains(syntheticID))
        XCTAssertFalse(report.contains(syntheticName))
        XCTAssertFalse(report.contains(syntheticURL))
        XCTAssertFalse(report.contains("fixture-opencode-go-key-001"))
        XCTAssertFalse(report.contains("second-hidden-id-should-not-print"))

        // Must include header, HTTP status, known schema numbers, bools, null, ISO-8601 timestamp, <string len=N>,
        // and redact unknown keys & numbers to <key> / <number>.
        XCTAssertTrue(report.contains("OpenUsage limits shape (live)"))
        XCTAssertTrue(report.contains("source=http:usage http_status=200"))
        XCTAssertTrue(report.contains("five_hour.utilization: number = 42"))
        XCTAssertTrue(report.contains("five_hour.resets_at: string = \(isoTimestamp)"))
        XCTAssertTrue(report.contains("seven_day.utilization: number = 73.5"))
        XCTAssertTrue(report.contains("seven_day_opus: null = null"))
        XCTAssertTrue(report.contains("enabled: bool = true"))
        XCTAssertTrue(report.contains("<key>.<key>: string = <string len=\(syntheticEmail.count)>"))
        XCTAssertTrue(report.contains("<key>.<key>: string = <string len=\(syntheticID.count)>"))
        XCTAssertTrue(report.contains("<key>.<key>: string = <string len=\(syntheticToken.count)>"))
        XCTAssertTrue(report.contains("<key>: array (len=2)"))
        XCTAssertTrue(report.contains("<key>[0].<key>: number = <number>"))
        XCTAssertTrue(report.contains("<key>[0].<key>: bool = false"))
        XCTAssertTrue(report.contains("<key>[1].<key>: number = <number>"))
        XCTAssertFalse(report.contains("account.email"))
        XCTAssertFalse(report.contains("items[0].count: number = 7"))

        // OpenCode local auth.json shape captured with allowlisted enum `type` and redacted `key`
        XCTAssertTrue(report.contains("source=local:auth.json"))
        XCTAssertTrue(report.contains("opencode-go.type: string = api"))
        XCTAssertTrue(report.contains("opencode-go.key: string = <string len=\("fixture-opencode-go-key-001".count)>"))
    }

    // MARK: - Finding 2 / Defect 10: OpenCode Legacy Zen & Unrelated Key Handling Without HTTP

    func testOpenCodeLegacyZenRemainsUnsupportedAndUnrelatedThirdPartyKeysNeverTriggerHTTP() async throws {
        let authURL = URL(fileURLWithPath: "/virtual/.local/share/opencode/auth.json")
        let neverHTTP = StubHTTPTransport { _, _ in
            XCTFail("Legacy Zen and unrelated third-party keys must never call the Go usage endpoint")
            return HTTPResponseData(statusCode: 500, body: Data())
        }

        // Legacy Zen-only logins (`opencode`, `opencode-zen`, `zen`) remain detected as .unsupported with zero HTTP
        let futureMs = Int64(referenceNow.addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        let legacyZenPayloads: [Data] = [
            Data("{\"opencode\":{\"type\":\"api\",\"key\":\"fixture-zen-key-1\"}}".utf8),
            Data("{\"opencode-zen\":{\"type\":\"oauth\",\"access\":\"fixture-zen-access-2\",\"expires\":\(futureMs)}}".utf8),
            Data("{\"zen\":{\"token\":\"fixture-zen-token-3\"}}".utf8)
        ]

        for payload in legacyZenPayloads {
            let result = await OpenCodeUsageProvider(
                fileReader: StubLocalFileReader(files: [authURL.path: payload]),
                httpTransport: neverHTTP,
                disableStore: InMemoryProviderDisableStore(),
                authFileURL: authURL,
                clock: { Self.referenceNow },
                timeZone: utc
            ).fetchResult()
            XCTAssertEqual(result.snapshot.connectionState, .unsupported)
            XCTAssertTrue(result.snapshot.connectedVia.localizedCaseInsensitiveContains("Not yet supported"))
            XCTAssertTrue(result.snapshot.connectedVia.localizedCaseInsensitiveContains("Zen"))
            XCTAssertEqual(result.snapshot.menuBarEntryState, .omitted)
        }

        // Unrelated vendor entries ONLY (even valid or expired!) -> .notConnected with zero HTTP
        let pastMs = Int64(referenceNow.addingTimeInterval(-3600).timeIntervalSince1970 * 1000)
        let unrelatedPayloads: [Data] = [
            Data("{\"anthropic\":{\"type\":\"api\",\"key\":\"fixture-vendor-key-1\"}}".utf8),
            Data("{\"openai\":{\"type\":\"oauth\",\"access\":\"fixture-vendor-access-2\",\"expires\":\(pastMs)}}".utf8),
            Data("{\"custom-provider\":{\"token\":\"fixture-vendor-token-3\"}}".utf8),
            Data("{\"empty-provider\":{\"type\":\"api\"}}".utf8)
        ]
        for payload in unrelatedPayloads {
            let result = await OpenCodeUsageProvider(
                fileReader: StubLocalFileReader(files: [authURL.path: payload]),
                httpTransport: neverHTTP,
                disableStore: InMemoryProviderDisableStore(),
                authFileURL: authURL,
                clock: { Self.referenceNow },
                timeZone: utc
            ).fetchResult()
            XCTAssertEqual(result.snapshot.connectionState, .notConnected)
        }
        XCTAssertTrue(neverHTTP.requests.isEmpty)
    }

    // MARK: - Finding 3: Tolerant Bucket Parsing, >100% Clamping & Unparseable Warnings

    func testClaudeTolerantBucketParsingOver100ClampAndUnparseableWarningInDumpLimits() async {
        let futureMs = Int64(referenceNow.addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        let validCred = Data("""
        {"claudeAiOauth":{"accessToken":"fixture-claude-token-tolerant","expiresAt":\(futureMs),"subscriptionType":"max","rateLimitTier":"default_claude_max_20x"}}
        """.utf8)
        let keychain = StubKeychain(items: [ClaudeUsageProvider.defaultKeychainService: validCred])

        // 1. Integer utilization, double utilization, >100 utilization (clamped to 100, stays red), null bucket omitted cleanly
        let over100Body = Data("""
        {
          "five_hour": { "utilization": 118.4, "resets_at": "2026-11-26T20:55:00Z" },
          "seven_day": { "utilization": 42, "resets_at": "2026-12-01T14:00:00Z" },
          "seven_day_opus": { "utilization": 62.6, "resets_at": "2026-12-01T14:00:00Z" },
          "seven_day_sonnet": null
        }
        """.utf8)
        let over100Provider = ClaudeUsageProvider(
            keychain: keychain,
            httpTransport: StubHTTPTransport { _, _ in HTTPResponseData(statusCode: 200, body: over100Body) },
            disableStore: InMemoryProviderDisableStore(),
            clock: { Self.referenceNow },
            timeZone: utc
        )
        let over100Result = await over100Provider.fetchResult()
        XCTAssertEqual(over100Result.snapshot.connectionState, .connected)
        XCTAssertEqual(over100Result.snapshot.limits.map(\.name), ["5-hour session", "Weekly · all models", "Weekly · Opus"])
        XCTAssertEqual(over100Result.snapshot.limits.map(\.percentUsed), [100, 42, 63])
        XCTAssertEqual(DepletionColor.level(percent: over100Result.snapshot.limits[0].percentUsed), .red)
        XCTAssertEqual(over100Result.diagnostic?.warnings ?? [], [])

        // 2. Present-but-unparseable bucket (five_hour) must surface as `! five_hour: present but not parseable` in --dump-limits
        //    while valid seven_day is still parsed!
        let partialBody = Data("""
        {
          "five_hour": { "utilization": "unexpected-string", "resets_at": "2026-11-26T20:55:00Z" },
          "seven_day": { "utilization": 15, "resets_at": "2026-12-01T14:00:00Z" },
          "seven_day_opus": null
        }
        """.utf8)
        let partialProvider = ClaudeUsageProvider(
            keychain: keychain,
            httpTransport: StubHTTPTransport { _, _ in HTTPResponseData(statusCode: 200, body: partialBody) },
            disableStore: InMemoryProviderDisableStore(),
            clock: { Self.referenceNow },
            timeZone: utc
        )
        let partialResult = await partialProvider.fetchResult()
        XCTAssertEqual(partialResult.snapshot.connectionState, .connected)
        XCTAssertEqual(partialResult.snapshot.limits.map(\.name), ["Weekly · all models"])
        XCTAssertEqual(partialResult.snapshot.limits.map(\.percentUsed), [15])
        XCTAssertEqual(partialResult.diagnostic?.warnings, ["five_hour: present but not parseable"])

        let dump = LimitsDumper.formatReport(results: [partialResult], isDemo: false)
        XCTAssertTrue(dump.contains("  - Weekly · all models: 15%"))
        XCTAssertTrue(dump.contains("  ! five_hour: present but not parseable"))
        XCTAssertFalse(dump.contains("seven_day_opus"))
    }

    func testOtherProvidersReportUnparseableLimitFieldsInDumpLimits() async {
        // ChatGPT: primary unparseable, secondary valid (with valid auth.json) -> connected + warning
        let sessionsDir = URL(fileURLWithPath: "/virtual/.codex/sessions", isDirectory: true)
        let rolloutURL = sessionsDir.appendingPathComponent("2026/11/26/rollout-partial.jsonl")
        let codexAuthURL = URL(fileURLWithPath: "/virtual/.codex/auth.json")
        let codexJWT = makeSyntheticJWT(expEpochSeconds: Int(referenceNow.addingTimeInterval(3600).timeIntervalSince1970))
        let codexAuth = Data("{\"tokens\":{\"access_token\":\"\(codexJWT)\"},\"plan_type\":\"plus\"}".utf8)
        let partialRollout = Data("""
        {"timestamp":"2026-11-26T18:35:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":"bad"},"secondary":{"used_percent":125,"window_minutes":10080,"resets_at":1796036400},"plan_type":"plus"}}}
        """.utf8)
        let meta = FileMetadata(size: UInt64(partialRollout.count), mtimeNanos: 1_795_718_100_000_000_000, inode: 11, isRegularFile: true, isDataless: false)
        let chatgptResult = await ChatGPTUsageProvider(
            fileReader: StubLocalFileReader(
                files: [
                    codexAuthURL.path: codexAuth,
                    rolloutURL.path: partialRollout
                ],
                discovered: [DiscoveredLocalFile(url: rolloutURL, relativePath: "2026/11/26/rollout-partial.jsonl", metadata: meta)]
            ),
            disableStore: InMemoryProviderDisableStore(),
            sessionsDirectory: sessionsDir,
            authFileURL: codexAuthURL,
            clock: { Self.referenceNow },
            timeZone: utc
        ).fetchResult()
        XCTAssertEqual(chatgptResult.snapshot.connectionState, .connected)
        XCTAssertEqual(chatgptResult.snapshot.limits.map(\.percentUsed), [100])
        XCTAssertEqual(chatgptResult.diagnostic?.warnings, ["primary: present but not parseable"])

        // Gemini: one bucket unparseable, one valid (injected endpoint) -> connected + warning
        let credsURL = URL(fileURLWithPath: "/virtual/.gemini/oauth_creds.json")
        let futureMs = Int64(referenceNow.addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        let validCreds = Data("{\"access_token\":\"fixture-gemini-token-warn\",\"expiry_date\":\(futureMs)}".utf8)
        let partialQuota = Data("""
        {"buckets":[{"remainingFraction":"bad","tokenType":"REQUESTS"},{"remainingFraction":0.4,"resetTime":"2026-11-27T05:00:00Z","tokenType":"REQUESTS"}]}
        """.utf8)
        let geminiResult = await GeminiUsageProvider(
            fileReader: StubLocalFileReader(files: [credsURL.path: validCreds]),
            httpTransport: StubHTTPTransport { req, _ in
                if req.url?.absoluteString.contains("loadCodeAssist") == true {
                    return HTTPResponseData(statusCode: 200, body: Data("{}".utf8))
                }
                return HTTPResponseData(statusCode: 200, body: partialQuota)
            },
            disableStore: InMemoryProviderDisableStore(),
            oauthCredsURL: credsURL,
            quotaEndpoint: GeminiUsageProvider.defaultQuotaEndpoint,
            clock: { Self.referenceNow },
            timeZone: utc
        ).fetchResult()
        XCTAssertEqual(geminiResult.snapshot.connectionState, .connected)
        XCTAssertEqual(geminiResult.snapshot.limits.first?.percentUsed, 60)
        XCTAssertEqual(geminiResult.diagnostic?.warnings, ["buckets[0].remainingFraction: present but not parseable"])

        // Cursor: planUsage.limit unparseable, falls back to totalPercentUsed (>100 clamped to 100) + warning
        let cursorDBURL = URL(fileURLWithPath: "/virtual/state.vscdb")
        let validJWT = makeSyntheticJWT(expEpochSeconds: Int(referenceNow.addingTimeInterval(3600).timeIntervalSince1970))
        let partialCursor = Data("""
        {"billingCycleEnd":"1796774400000","planUsage":{"limit":"not-a-number","totalPercentUsed":112}}
        """.utf8)
        let cursorResult = await CursorUsageProvider(
            fileReader: StubLocalFileReader(sqliteItemsByPath: [cursorDBURL.path: ["cursorAuth/accessToken": validJWT]]),
            httpTransport: StubHTTPTransport { _, _ in HTTPResponseData(statusCode: 200, body: partialCursor) },
            disableStore: InMemoryProviderDisableStore(),
            stateDBURL: cursorDBURL,
            clock: { Self.referenceNow },
            timeZone: utc
        ).fetchResult()
        XCTAssertEqual(cursorResult.snapshot.connectionState, .connected)
        XCTAssertEqual(cursorResult.snapshot.limits.first?.percentUsed, 100)
        XCTAssertEqual(cursorResult.diagnostic?.warnings, ["planUsage.limit: present but not parseable"])

        let dump = LimitsDumper.formatReport(results: [chatgptResult, geminiResult, cursorResult], isDemo: false)
        XCTAssertTrue(dump.contains("  ! primary: present but not parseable"))
        XCTAssertTrue(dump.contains("  ! buckets[0].remainingFraction: present but not parseable"))
        XCTAssertTrue(dump.contains("  ! planUsage.limit: present but not parseable"))
    }

    // MARK: - Finding 4: Past Reset Time -> "Resetting" with Injected Clock

    func testPastResetTimeShowsResettingWithInjectedClock() async {
        let resetDate = LogTimestampParser.parseISO8601("2026-11-26T20:00:00Z")!
        let beforeReset = LogTimestampParser.parseISO8601("2026-11-26T19:30:00Z")!
        let afterReset = LogTimestampParser.parseISO8601("2026-11-26T20:05:00Z")!

        // Direct ResetTimeFormatter assertions
        XCTAssertEqual(ResetTimeFormatter.formatResetText(resetsAt: resetDate, now: beforeReset, timeZone: utc), "Resets in 30m")
        XCTAssertEqual(ResetTimeFormatter.formatResetText(resetsAt: resetDate, now: resetDate, timeZone: utc), "Resetting")
        XCTAssertEqual(ResetTimeFormatter.formatResetText(resetsAt: resetDate, now: afterReset, timeZone: utc), "Resetting")
        XCTAssertFalse(ResetTimeFormatter.formatResetText(resetsAt: resetDate, now: afterReset, timeZone: utc).contains("…"))
        XCTAssertFalse(ResetTimeFormatter.formatResetText(resetsAt: resetDate, now: afterReset, timeZone: utc).contains("..."))

        // Injected clock advancing past resets_at on Claude & ChatGPT & Cursor
        let clock = MutableClock(beforeReset)
        let futureCredMs = Int64(afterReset.addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        let claudeCred = Data("""
        {"claudeAiOauth":{"accessToken":"fixture-claude-clock-token","expiresAt":\(futureCredMs),"subscriptionType":"max"}}
        """.utf8)
        let claudeBody = Data("""
        {"five_hour":{"utilization":55,"resets_at":"2026-11-26T20:00:00Z"}}
        """.utf8)
        let claudeProvider = ClaudeUsageProvider(
            keychain: StubKeychain(items: [ClaudeUsageProvider.defaultKeychainService: claudeCred]),
            httpTransport: StubHTTPTransport { _, _ in HTTPResponseData(statusCode: 200, body: claudeBody) },
            disableStore: InMemoryProviderDisableStore(),
            clock: { clock.now },
            timeZone: utc
        )

        let claudeBefore = await claudeProvider.fetchResult()
        XCTAssertEqual(claudeBefore.snapshot.limits.first?.resetText, "Resets in 30m")

        // Advance injected clock past resets_at
        clock.advance(by: 35 * 60)
        let claudeAfter = await claudeProvider.fetchResult()
        XCTAssertEqual(claudeAfter.snapshot.limits.first?.resetText, "Resetting")

        // ChatGPT rollout with past resets_at (and valid auth.json)
        let sessionsDir = URL(fileURLWithPath: "/virtual/.codex/sessions", isDirectory: true)
        let rolloutURL = sessionsDir.appendingPathComponent("2026/11/26/rollout-past.jsonl")
        let codexAuthURL = URL(fileURLWithPath: "/virtual/.codex/auth.json")
        let codexJWT = makeSyntheticJWT(expEpochSeconds: Int(afterReset.addingTimeInterval(3600).timeIntervalSince1970))
        let codexAuth = Data("{\"tokens\":{\"access_token\":\"\(codexJWT)\"},\"plan_type\":\"plus\"}".utf8)
        let resetEpoch = Int(resetDate.timeIntervalSince1970)
        let rolloutData = Data("""
        {"timestamp":"2026-11-26T19:00:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":40,"window_minutes":300,"resets_at":\(resetEpoch)},"plan_type":"plus"}}}
        """.utf8)
        let meta = FileMetadata(size: UInt64(rolloutData.count), mtimeNanos: 1_795_719_600_000_000_000, inode: 12, isRegularFile: true, isDataless: false)
        let chatgptProvider = ChatGPTUsageProvider(
            fileReader: StubLocalFileReader(
                files: [
                    codexAuthURL.path: codexAuth,
                    rolloutURL.path: rolloutData
                ],
                discovered: [DiscoveredLocalFile(url: rolloutURL, relativePath: "2026/11/26/rollout-past.jsonl", metadata: meta)]
            ),
            disableStore: InMemoryProviderDisableStore(),
            sessionsDirectory: sessionsDir,
            authFileURL: codexAuthURL,
            clock: { clock.now },
            timeZone: utc
        )
        let chatgptAfter = await chatgptProvider.fetchResult()
        XCTAssertEqual(chatgptAfter.snapshot.limits.first?.resetText, "Resetting")

        // Cursor billingCycleEnd in the past
        let cursorDBURL = URL(fileURLWithPath: "/virtual/state.vscdb")
        let validJWT = makeSyntheticJWT(expEpochSeconds: Int(afterReset.addingTimeInterval(3600).timeIntervalSince1970))
        let pastBillingMs = Int64(resetDate.timeIntervalSince1970 * 1000)
        let cursorBody = Data("""
        {"billingCycleEnd":"\(pastBillingMs)","planUsage":{"totalPercentUsed":25}}
        """.utf8)
        let cursorProvider = CursorUsageProvider(
            fileReader: StubLocalFileReader(sqliteItemsByPath: [cursorDBURL.path: ["cursorAuth/accessToken": validJWT]]),
            httpTransport: StubHTTPTransport { _, _ in HTTPResponseData(statusCode: 200, body: cursorBody) },
            disableStore: InMemoryProviderDisableStore(),
            stateDBURL: cursorDBURL,
            clock: { clock.now },
            timeZone: utc
        )
        let cursorAfter = await cursorProvider.fetchResult()
        XCTAssertEqual(cursorAfter.snapshot.limits.first?.resetText, "Resetting")
    }

    // MARK: - Round 2 Defect 1: CLI Demo + --dump-limits-shape Isolation

    func testCLIDispatchRejectsDemoCombinedWithDumpLimitsShapeWithoutTouchingLiveTransports() async {
        // 1. Flag form: --demo --dump-limits-shape
        let flagResult = await CLIDumpDispatcher.run(
            arguments: ["OpenUsage", "--demo", "--dump-limits-shape"],
            environment: [:],
            httpTransport: FailingHTTPTransport(),
            fileReader: FailingLocalFileReader(),
            keychain: FailingKeychain(),
            disableStore: FailingDisableStore(),
            urlOpener: FailingURLOpener()
        )
        XCTAssertNotNil(flagResult)
        XCTAssertNotEqual(flagResult?.exitCode, 0)
        XCTAssertEqual(flagResult?.stdout, "")
        XCTAssertTrue(flagResult?.stderr.contains("--dump-limits-shape") == true)

        // 2. Environment-variable form: OPENUSAGE_DEMO=1 + --dump-limits-shape
        let envResult = await CLIDumpDispatcher.run(
            arguments: ["OpenUsage", "--dump-limits-shape"],
            environment: ["OPENUSAGE_DEMO": "1"],
            httpTransport: FailingHTTPTransport(),
            fileReader: FailingLocalFileReader(),
            keychain: FailingKeychain(),
            disableStore: FailingDisableStore(),
            urlOpener: FailingURLOpener()
        )
        XCTAssertNotNil(envResult)
        XCTAssertNotEqual(envResult?.exitCode, 0)
        XCTAssertEqual(envResult?.stdout, "")
        XCTAssertTrue(envResult?.stderr.contains("--dump-limits-shape") == true)

        // 3. Direct generateShapeReport(isDemo: true) also never touches live transports
        let demoShape = await LimitsDumper.generateShapeReport(
            isDemo: true,
            demoScenario: .all,
            httpTransport: FailingHTTPTransport(),
            fileReader: FailingLocalFileReader(),
            keychain: FailingKeychain(),
            disableStore: FailingDisableStore(),
            urlOpener: FailingURLOpener()
        )
        XCTAssertTrue(demoShape.contains("OpenUsage limits shape (demo)"))
    }

    // MARK: - Round 2 & 3 Defect 1: Schema-Path Shape Dump Rules (No Dynamic Keys, Arbitrary Enums, or Unknown Numbers)

    func testShapeDumpRedactsNumericIDsDynamicKeysCapsArraysAndAllowlistsEnums() async {
        let syntheticNumericAccountID = "987654321098"
        let syntheticDynamicAccountKey = "fixture-account-17"
        let syntheticNestedNumber = "19347"
        let arbitraryLowercasePlan = "internal_enterprise_tier_9"

        // 1. Claude HTTP usage shape: dynamic keys, unknown numeric paths, arbitrary lowercase enums, and <=8 vs >8 arrays
        let claudePayload = Data("""
        {
          "account_id": \(syntheticNumericAccountID),
          "\(syntheticDynamicAccountKey)": {
            "utilization": 45,
            "number": \(syntheticNestedNumber)
          },
          "accounts": {
            "\(syntheticDynamicAccountKey)": {
              "number": \(syntheticNestedNumber)
            }
          },
          "limits": [
            {"kind": "five_hour", "group": "all_models", "scope": "usage", "severity": "warning", "utilization": 42, "label": "five_hour"},
            {"kind": "custom_kind", "group": "org_default", "scope": "private_scope", "severity": "custom_sev", "utilization": 10},
            {"kind": "seven_day", "group": "opus", "scope": "model", "severity": "exceeded", "utilization": 81}
          ]
        }
        """.utf8)
        let claudeLines = JSONShapeFormatter.formatLines(data: claudePayload, provider: .claude).joined(separator: "\n")

        XCTAssertFalse(claudeLines.contains(syntheticNumericAccountID))
        XCTAssertFalse(claudeLines.contains(syntheticDynamicAccountKey))
        XCTAssertFalse(claudeLines.contains(syntheticNestedNumber))
        XCTAssertFalse(claudeLines.contains("accounts"))
        XCTAssertFalse(claudeLines.contains("custom_kind"))
        XCTAssertFalse(claudeLines.contains("org_default"))
        XCTAssertFalse(claudeLines.contains("private_scope"))
        XCTAssertFalse(claudeLines.contains("custom_sev"))

        XCTAssertTrue(claudeLines.contains("<key>: number = <number>"))
        XCTAssertTrue(claudeLines.contains("<key>.<key>.<key>: number = <number>"))
        XCTAssertTrue(claudeLines.contains("limits[0].kind: string = five_hour"))
        XCTAssertTrue(claudeLines.contains("limits[0].group: string = all_models"))
        XCTAssertTrue(claudeLines.contains("limits[0].scope: string = usage"))
        XCTAssertTrue(claudeLines.contains("limits[0].severity: string = warning"))
        XCTAssertTrue(claudeLines.contains("limits[0].utilization: number = 42"))
        XCTAssertTrue(claudeLines.contains("limits[0].<key>: string = <string len=9>"))
        XCTAssertTrue(claudeLines.contains("limits[1].kind: string = <string len=\("custom_kind".count)>"))
        XCTAssertTrue(claudeLines.contains("limits[1].group: string = <string len=\("org_default".count)>"))
        XCTAssertTrue(claudeLines.contains("limits[1].scope: string = <string len=\("private_scope".count)>"))
        XCTAssertTrue(claudeLines.contains("limits[1].severity: string = <string len=\("custom_sev".count)>"))
        XCTAssertTrue(claudeLines.contains("limits[2].kind: string = seven_day"))
        XCTAssertTrue(claudeLines.contains("limits[2].group: string = opus"))
        XCTAssertTrue(claudeLines.contains("limits[2].severity: string = exceeded"))

        // 2. Arrays <= 8 elements print every element; arrays > 8 print only [0]
        let arrayPayload = Data("""
        {
          "limits": [
            {"utilization": 11}, {"utilization": 12}, {"utilization": 13}, {"utilization": 14},
            {"utilization": 15}, {"utilization": 16}, {"utilization": 17}, {"utilization": 18}
          ]
        }
        """.utf8)
        let eightLines = JSONShapeFormatter.formatLines(data: arrayPayload, provider: .claude).joined(separator: "\n")
        XCTAssertTrue(eightLines.contains("limits: array (len=8)"))
        XCTAssertTrue(eightLines.contains("limits[0].utilization: number = 11"))
        XCTAssertTrue(eightLines.contains("limits[7].utilization: number = 18"))

        let ninePayload = Data("""
        {
          "limits": [
            {"utilization": 1}, {"utilization": 2}, {"utilization": 3}, {"utilization": 4},
            {"utilization": 5}, {"utilization": 6}, {"utilization": 7}, {"utilization": 8},
            {"utilization": 9}
          ]
        }
        """.utf8)
        let nineLines = JSONShapeFormatter.formatLines(data: ninePayload, provider: .claude).joined(separator: "\n")
        XCTAssertTrue(nineLines.contains("limits: array (len=9)"))
        XCTAssertTrue(nineLines.contains("limits[0].utilization: number = 1"))
        XCTAssertFalse(nineLines.contains("limits[1]"))

        // 3. Codex auth.json & rollout shapes: only known plan_type enums print, dynamic keys/numbers redacted
        let codexUnknownPlan = Data("""
        {
          "plan_type": "\(arbitraryLowercasePlan)",
          "tokens": {"access_token": "fixture-secret", "account_id": \(syntheticNumericAccountID)},
          "accounts": {"\(syntheticDynamicAccountKey)": {"number": \(syntheticNestedNumber)}}
        }
        """.utf8)
        let codexUnknownLines = JSONShapeFormatter.formatLines(data: codexUnknownPlan, provider: .chatgpt).joined(separator: "\n")
        XCTAssertFalse(codexUnknownLines.contains(arbitraryLowercasePlan))
        XCTAssertFalse(codexUnknownLines.contains(syntheticNumericAccountID))
        XCTAssertFalse(codexUnknownLines.contains(syntheticDynamicAccountKey))
        XCTAssertFalse(codexUnknownLines.contains(syntheticNestedNumber))
        XCTAssertTrue(codexUnknownLines.contains("plan_type: string = <string len=\(arbitraryLowercasePlan.count)>"))
        XCTAssertTrue(codexUnknownLines.contains("tokens.account_id: number = <number>"))
        XCTAssertTrue(codexUnknownLines.contains("<key>.<key>.<key>: number = <number>"))

        let codexKnownPlan = Data("""
        {"plan_type": "prolite", "primary": {"used_percent": 35, "window_minutes": 300}}
        """.utf8)
        let codexKnownLines = JSONShapeFormatter.formatLines(data: codexKnownPlan, provider: .chatgpt).joined(separator: "\n")
        XCTAssertTrue(codexKnownLines.contains("plan_type: string = prolite"))
        XCTAssertTrue(codexKnownLines.contains("primary.used_percent: number = 35"))
        XCTAssertTrue(codexKnownLines.contains("primary.window_minutes: number = 300"))

        // 4. Cursor spendLimitUsage.limitType enum allowlist
        let cursorPayload = Data("""
        {"spendLimitUsage": {"limitType": "team", "pooledLimit": 5000}, "\(syntheticDynamicAccountKey)": {"number": \(syntheticNestedNumber)}}
        """.utf8)
        let cursorLines = JSONShapeFormatter.formatLines(data: cursorPayload, provider: .cursor).joined(separator: "\n")
        XCTAssertTrue(cursorLines.contains("spendLimitUsage.limitType: string = team"))
        XCTAssertTrue(cursorLines.contains("spendLimitUsage.pooledLimit: number = 5000"))
        XCTAssertFalse(cursorLines.contains(syntheticDynamicAccountKey))
        XCTAssertFalse(cursorLines.contains(syntheticNestedNumber))

        let cursorUnknownLimitType = Data("""
        {"spendLimitUsage": {"limitType": "custom_enterprise"}}
        """.utf8)
        let cursorUnknownLines = JSONShapeFormatter.formatLines(data: cursorUnknownLimitType, provider: .cursor).joined(separator: "\n")
        XCTAssertFalse(cursorUnknownLines.contains("custom_enterprise"))
        XCTAssertTrue(cursorUnknownLines.contains("spendLimitUsage.limitType: string = <string len=17>"))

        // 5. OpenCode local auth.json: known subscription keys & *.type enum only; dynamic keys & unknown numbers masked
        let localAuth = Data("""
        {
          "opencode-go": {"type": "api", "key": "fixture-secret-key", "account_id": \(syntheticNumericAccountID)},
          "\(syntheticDynamicAccountKey)": {"type": "oauth", "access": "fixture-other-token", "number": \(syntheticNestedNumber)},
          "accounts": {"\(syntheticDynamicAccountKey)": {"number": \(syntheticNestedNumber), "type": "oauth"}}
        }
        """.utf8)
        let localLines = JSONShapeFormatter.formatLines(data: localAuth, provider: .opencode).joined(separator: "\n")
        XCTAssertFalse(localLines.contains(syntheticNumericAccountID))
        XCTAssertFalse(localLines.contains(syntheticDynamicAccountKey))
        XCTAssertFalse(localLines.contains(syntheticNestedNumber))
        XCTAssertFalse(localLines.contains("fixture-secret-key"))
        XCTAssertFalse(localLines.contains("accounts"))
        XCTAssertTrue(localLines.contains("opencode-go.type: string = api"))
        XCTAssertTrue(localLines.contains("opencode-go.<key>: number = <number>"))
        XCTAssertTrue(localLines.contains("<key>.type: string = oauth"))
        XCTAssertTrue(localLines.contains("<key>.<key>: number = <number>"))
        XCTAssertTrue(localLines.contains("<key>.<key>.<key>: number = <number>"))

        // 6. Default (nil provider) union schema also blocks dynamic keys, unknown numbers, and arbitrary plan_type
        let genericProbe = Data("""
        {
          "account_id": \(syntheticNumericAccountID),
          "\(syntheticDynamicAccountKey)": {"number": \(syntheticNestedNumber)},
          "accounts": {"\(syntheticDynamicAccountKey)": {"number": \(syntheticNestedNumber)}},
          "plan_type": "\(arbitraryLowercasePlan)"
        }
        """.utf8)
        let genericLines = JSONShapeFormatter.formatLines(data: genericProbe).joined(separator: "\n")
        XCTAssertFalse(genericLines.contains(syntheticNumericAccountID))
        XCTAssertFalse(genericLines.contains(syntheticDynamicAccountKey))
        XCTAssertFalse(genericLines.contains(syntheticNestedNumber))
        XCTAssertFalse(genericLines.contains(arbitraryLowercasePlan))
        XCTAssertFalse(genericLines.contains("accounts"))
        XCTAssertTrue(genericLines.contains("plan_type: string = <string len=\(arbitraryLowercasePlan.count)>"))
    }

    // MARK: - Round 2 Defect 3: Unknown Plan Identifiers Must Never Echo Credential Material

    func testUnknownPlanValuesNeverLeakCredentialMaterialInNormalDumpLimits() async throws {
        let opaqueSecret = "opaqueRefreshMaterial998877"
        let futureMs = Int64(referenceNow.addingTimeInterval(3600).timeIntervalSince1970 * 1000)

        // 1. Claude: malformed synthetic credential with same opaque value in refreshToken & subscriptionType
        let claudeSuccessBody = try loadLiveFixture("claude-usage-success.json")
        let claudeCred = Data("""
        {"claudeAiOauth":{"accessToken":"fixture-claude-access-1","refreshToken":"\(opaqueSecret)","expiresAt":\(futureMs),"subscriptionType":"\(opaqueSecret)","rateLimitTier":"\(opaqueSecret)"}}
        """.utf8)
        let claudeResult = await ClaudeUsageProvider(
            keychain: StubKeychain(items: [ClaudeUsageProvider.defaultKeychainService: claudeCred]),
            httpTransport: StubHTTPTransport { _, _ in HTTPResponseData(statusCode: 200, body: claudeSuccessBody) },
            disableStore: InMemoryProviderDisableStore(),
            clock: { Self.referenceNow },
            timeZone: utc
        ).fetchResult()
        XCTAssertEqual(claudeResult.snapshot.connectionState, .connected)
        XCTAssertEqual(claudeResult.snapshot.plan, "")

        // 2. ChatGPT: unknown plan_type in auth.json & rollout
        let sessionsDir = URL(fileURLWithPath: "/virtual/.codex/sessions", isDirectory: true)
        let authURL = URL(fileURLWithPath: "/virtual/.codex/auth.json")
        let rolloutURL = sessionsDir.appendingPathComponent("2026/11/26/rollout-plan.jsonl")
        let validJWT = makeSyntheticJWT(expEpochSeconds: Int(referenceNow.addingTimeInterval(3600).timeIntervalSince1970))
        let codexAuth = Data("{\"tokens\":{\"access_token\":\"\(validJWT)\"},\"plan_type\":\"\(opaqueSecret)\"}".utf8)
        let codexRollout = Data("""
        {"timestamp":"2026-11-26T18:35:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":20,"window_minutes":300,"resets_at":1795734000},"plan_type":"\(opaqueSecret)"}}}
        """.utf8)
        let meta = FileMetadata(size: UInt64(codexRollout.count), mtimeNanos: 1_795_718_100_000_000_000, inode: 20, isRegularFile: true, isDataless: false)
        let chatgptResult = await ChatGPTUsageProvider(
            fileReader: StubLocalFileReader(
                files: [authURL.path: codexAuth, rolloutURL.path: codexRollout],
                discovered: [DiscoveredLocalFile(url: rolloutURL, relativePath: "2026/11/26/rollout-plan.jsonl", metadata: meta)]
            ),
            disableStore: InMemoryProviderDisableStore(),
            sessionsDirectory: sessionsDir,
            authFileURL: authURL,
            clock: { Self.referenceNow },
            timeZone: utc
        ).fetchResult()
        XCTAssertEqual(chatgptResult.snapshot.plan, "Codex")

        // 3. Cursor: unknown stripeMembershipType
        let cursorDBURL = URL(fileURLWithPath: "/virtual/cursor-plan.vscdb")
        let cursorSuccessBody = try loadLiveFixture("cursor-usage-success.json")
        let cursorResult = await CursorUsageProvider(
            fileReader: StubLocalFileReader(sqliteItemsByPath: [
                cursorDBURL.path: [
                    "cursorAuth/accessToken": validJWT,
                    "cursorAuth/stripeMembershipType": opaqueSecret
                ]
            ]),
            httpTransport: StubHTTPTransport { _, _ in HTTPResponseData(statusCode: 200, body: cursorSuccessBody) },
            disableStore: InMemoryProviderDisableStore(),
            stateDBURL: cursorDBURL,
            clock: { Self.referenceNow },
            timeZone: utc
        ).fetchResult()
        XCTAssertEqual(cursorResult.snapshot.plan, "")

        // 4. Gemini (injected): unknown paidTier.name
        let geminiCredsURL = URL(fileURLWithPath: "/virtual/.gemini/oauth_creds.json")
        let geminiQuota = try loadLiveFixture("gemini-quota-success.json")
        let geminiResult = await GeminiUsageProvider(
            fileReader: StubLocalFileReader(files: [
                geminiCredsURL.path: Data("{\"access_token\":\"fixture-gemini-token\",\"expiry_date\":\(futureMs)}".utf8)
            ]),
            httpTransport: StubHTTPTransport { req, _ in
                if req.url?.absoluteString.contains("loadCodeAssist") == true {
                    return HTTPResponseData(statusCode: 200, body: Data("{\"paidTier\":{\"name\":\"\(opaqueSecret)\"}}".utf8))
                }
                return HTTPResponseData(statusCode: 200, body: geminiQuota)
            },
            disableStore: InMemoryProviderDisableStore(),
            oauthCredsURL: geminiCredsURL,
            quotaEndpoint: GeminiUsageProvider.defaultQuotaEndpoint,
            clock: { Self.referenceNow },
            timeZone: utc
        ).fetchResult()
        XCTAssertEqual(geminiResult.snapshot.plan, "")

        // 5. OpenCode Go: extra upstream plan/secret fields never echo into snapshot or report
        let openCodeAuthURL = URL(fileURLWithPath: "/virtual/.local/share/opencode/auth.json")
        let openCodeResult = await OpenCodeUsageProvider(
            fileReader: StubLocalFileReader(files: [
                openCodeAuthURL.path: Data("{\"opencode-go\":{\"type\":\"api\",\"key\":\"fixture-go-key\"}}".utf8)
            ]),
            httpTransport: StubHTTPTransport { _, _ in
                HTTPResponseData(
                    statusCode: 200,
                    body: Data("""
                    {"plan":"\(opaqueSecret)","usage":{"rolling":{"status":"ok","percent":25,"resetsAt":"2026-11-26T21:00:00.000Z"}}}
                    """.utf8)
                )
            },
            disableStore: InMemoryProviderDisableStore(),
            authFileURL: openCodeAuthURL,
            usageEndpoint: URL(string: "https://opencode.invalid/inference/go/v1/usage")!,
            clock: { Self.referenceNow },
            timeZone: utc
        ).fetchResult()
        XCTAssertEqual(openCodeResult.snapshot.connectionState, .connected)
        XCTAssertEqual(openCodeResult.snapshot.plan, "Go")

        // Normal --dump-limits report must not contain opaqueSecret in any casing
        let report = LimitsDumper.formatReport(
            results: [claudeResult, chatgptResult, cursorResult, geminiResult, openCodeResult],
            isDemo: false
        )
        XCTAssertFalse(report.localizedCaseInsensitiveContains(opaqueSecret))
    }

    // MARK: - Round 2 Defect 4: Codex Rollout Cannot Override Missing or Expired auth.json

    func testChatGPTOldRolloutDoesNotOverrideMissingOrExpiredAuth() async throws {
        let rolloutData = try loadLiveFixture("codex-rollout-rate-limits.jsonl")
        let sessionsDir = URL(fileURLWithPath: "/virtual/.codex/sessions", isDirectory: true)
        let rolloutURL = sessionsDir.appendingPathComponent("2026/11/26/rollout-2026-11-26.jsonl")
        let authURL = URL(fileURLWithPath: "/virtual/.codex/auth.json")
        let meta = FileMetadata(size: UInt64(rolloutData.count), mtimeNanos: 1_795_718_100_000_000_000, inode: 21, isRegularFile: true, isDataless: false)

        // 1. Missing auth.json with a valid rollout still on disk -> .notConnected
        let missingAuthResult = await ChatGPTUsageProvider(
            fileReader: StubLocalFileReader(
                files: [rolloutURL.path: rolloutData],
                discovered: [DiscoveredLocalFile(url: rolloutURL, relativePath: "2026/11/26/rollout-2026-11-26.jsonl", metadata: meta)]
            ),
            disableStore: InMemoryProviderDisableStore(),
            sessionsDirectory: sessionsDir,
            authFileURL: authURL,
            clock: { Self.referenceNow },
            timeZone: utc
        ).fetchResult()
        XCTAssertEqual(missingAuthResult.snapshot.connectionState, .notConnected)
        XCTAssertTrue(missingAuthResult.snapshot.limits.isEmpty)

        // 2. Expired auth.json JWT with a valid rollout still on disk -> .expired
        let expiredJWT = makeSyntheticJWT(expEpochSeconds: Int(referenceNow.addingTimeInterval(-600).timeIntervalSince1970))
        let expiredAuth = Data("{\"tokens\":{\"access_token\":\"\(expiredJWT)\"},\"plan_type\":\"plus\"}".utf8)
        let expiredAuthResult = await ChatGPTUsageProvider(
            fileReader: StubLocalFileReader(
                files: [
                    authURL.path: expiredAuth,
                    rolloutURL.path: rolloutData
                ],
                discovered: [DiscoveredLocalFile(url: rolloutURL, relativePath: "2026/11/26/rollout-2026-11-26.jsonl", metadata: meta)]
            ),
            disableStore: InMemoryProviderDisableStore(),
            sessionsDirectory: sessionsDir,
            authFileURL: authURL,
            clock: { Self.referenceNow },
            timeZone: utc
        ).fetchResult()
        XCTAssertEqual(expiredAuthResult.snapshot.connectionState, .expired)
        XCTAssertTrue(expiredAuthResult.snapshot.limits.isEmpty)
    }

    // MARK: - Round 2 Defect 5: Gemini Production Unsupported + Strict REQUESTS & 0...1 Validation

    func testGeminiProductionUnsupportedAndStrictQuotaBucketValidation() async {
        let credsURL = URL(fileURLWithPath: "/virtual/.gemini/oauth_creds.json")
        let futureMs = Int64(referenceNow.addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        let validCreds = Data("{\"access_token\":\"fixture-gemini-token-prod\",\"expiry_date\":\(futureMs)}".utf8)
        let neverHTTP = StubHTTPTransport { _, _ in
            XCTFail("Production Gemini provider must not make unverified HTTP calls")
            return HTTPResponseData(statusCode: 500, body: Data())
        }

        // 1. Default production path: missing login -> .notConnected
        let missingProd = await GeminiUsageProvider(
            fileReader: StubLocalFileReader(),
            httpTransport: neverHTTP,
            disableStore: InMemoryProviderDisableStore(),
            oauthCredsURL: credsURL,
            clock: { Self.referenceNow },
            timeZone: utc
        ).fetchResult()
        XCTAssertEqual(missingProd.snapshot.connectionState, .notConnected)

        // 2. Default production path: detected login -> labelled .unsupported (zero HTTP)
        let detectedProd = await GeminiUsageProvider(
            fileReader: StubLocalFileReader(files: [credsURL.path: validCreds]),
            httpTransport: neverHTTP,
            disableStore: InMemoryProviderDisableStore(),
            oauthCredsURL: credsURL,
            clock: { Self.referenceNow },
            timeZone: utc
        ).fetchResult()
        XCTAssertEqual(detectedProd.snapshot.connectionState, .unsupported)
        XCTAssertTrue(detectedProd.snapshot.connectedVia.localizedCaseInsensitiveContains("Not yet supported"))
        XCTAssertTrue(neverHTTP.requests.isEmpty)

        // 3. Injectable path: non-REQUESTS buckets only (TOKENS / missing tokenType) must NOT be published as Daily requests
        let tokensOnlyBody = Data("""
        {"buckets":[{"remainingFraction":0.5,"tokenType":"TOKENS"},{"remainingFraction":0.3}]}
        """.utf8)
        let tokensOnlyResult = await GeminiUsageProvider(
            fileReader: StubLocalFileReader(files: [credsURL.path: validCreds]),
            httpTransport: StubHTTPTransport { req, _ in
                if req.url?.absoluteString.contains("loadCodeAssist") == true {
                    return HTTPResponseData(statusCode: 200, body: Data("{}".utf8))
                }
                return HTTPResponseData(statusCode: 200, body: tokensOnlyBody)
            },
            disableStore: InMemoryProviderDisableStore(),
            oauthCredsURL: credsURL,
            quotaEndpoint: GeminiUsageProvider.defaultQuotaEndpoint,
            clock: { Self.referenceNow },
            timeZone: utc
        ).fetchResult()
        XCTAssertEqual(tokensOnlyResult.snapshot.connectionState, .unsupported)
        XCTAssertTrue(tokensOnlyResult.snapshot.limits.isEmpty)

        // 4. Injectable path: negative remainingFraction (e.g. -0.25) must be rejected, NOT reported as 100% used
        let negativeFractionBody = Data("""
        {"buckets":[{"remainingFraction":-0.25,"tokenType":"REQUESTS"}]}
        """.utf8)
        let negativeResult = await GeminiUsageProvider(
            fileReader: StubLocalFileReader(files: [credsURL.path: validCreds]),
            httpTransport: StubHTTPTransport { req, _ in
                if req.url?.absoluteString.contains("loadCodeAssist") == true {
                    return HTTPResponseData(statusCode: 200, body: Data("{}".utf8))
                }
                return HTTPResponseData(statusCode: 200, body: negativeFractionBody)
            },
            disableStore: InMemoryProviderDisableStore(),
            oauthCredsURL: credsURL,
            quotaEndpoint: GeminiUsageProvider.defaultQuotaEndpoint,
            clock: { Self.referenceNow },
            timeZone: utc
        ).fetchResult()
        XCTAssertEqual(negativeResult.snapshot.connectionState, .unsupported)
        XCTAssertTrue(negativeResult.snapshot.limits.isEmpty)
        XCTAssertEqual(negativeResult.diagnostic?.warnings, ["buckets[0].remainingFraction: present but not parseable"])
    }

    // MARK: - Round 2 Defect 6: Bounded Keychain Read & Incremental Publishing on Refresh

    @MainActor
    func testBlockedKeychainReadAndSlowProviderDoNotDelayOtherProviders() async {
        final class BlockingKeychain: KeychainReading, @unchecked Sendable {
            private let gate = DispatchSemaphore(value: 0)

            func release() {
                gate.signal()
            }

            func readGenericPassword(service: String, account: String?) throws -> Data? {
                // Simulate a synchronous macOS Keychain prompt blocking off-main-actor.
                _ = gate.wait(timeout: .now() + 5.0)
                return nil
            }
        }

        final class GateableProvider: DiagnosableUsageProvider, @unchecked Sendable {
            let provider: ProviderID
            private let lock = NSLock()
            private var continuation: CheckedContinuation<ProviderFetchResult, Never>?
            private var pendingResult: ProviderFetchResult?

            init(provider: ProviderID) {
                self.provider = provider
            }

            func fetchResult() async -> ProviderFetchResult {
                await withCheckedContinuation { cont in
                    lock.lock()
                    if let result = pendingResult {
                        pendingResult = nil
                        lock.unlock()
                        cont.resume(returning: result)
                    } else {
                        continuation = cont
                        lock.unlock()
                    }
                }
            }

            func resolve(with result: ProviderFetchResult) {
                lock.lock()
                if let cont = continuation {
                    continuation = nil
                    lock.unlock()
                    cont.resume(returning: result)
                } else {
                    pendingResult = result
                    lock.unlock()
                }
            }

            func signIn() async throws -> ProviderSnapshot {
                await fetchResult().snapshot
            }

            func signOut() async throws -> ProviderSnapshot {
                ProviderSnapshot(provider: provider, plan: "", connectionState: .notConnected, limits: [], connectedVia: "Not connected")
            }
        }

        // Part 1: Blocking Claude Keychain read finishes within its timeout (never hangs)
        let blockingKeychain = BlockingKeychain()
        defer { blockingKeychain.release() }
        let boundedClaude = ClaudeUsageProvider(
            keychain: blockingKeychain,
            httpTransport: StubHTTPTransport { _, _ in
                XCTFail("HTTP should not be called when Keychain times out")
                return HTTPResponseData(statusCode: 500, body: Data())
            },
            disableStore: InMemoryProviderDisableStore(),
            requestTimeout: 0.15,
            clock: { Self.referenceNow },
            timeZone: utc
        )
        let start = Date()
        let keychainTimeoutResult = await boundedClaude.fetchResult()
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 2.0)
        XCTAssertEqual(keychainTimeoutResult.snapshot.connectionState, .waitingForKeychain)
        XCTAssertEqual(keychainTimeoutResult.snapshot.connectedVia, "Waiting for Keychain access")
        XCTAssertEqual(keychainTimeoutResult.snapshot.menuBarEntryState, .omitted)
        XCTAssertEqual(keychainTimeoutResult.diagnostic?.shortReason, "Waiting for Keychain access")
        XCTAssertEqual(keychainTimeoutResult.diagnostic?.isTransientError, false)

        // Part 2: In AccountsController.refreshAll(), while Claude is held pending, Cursor becomes visible immediately
        let heldClaude = GateableProvider(provider: .claude)
        let fastCursorSnapshot = DemoFixtures.snapshot(for: .cursor, scenario: .all)
        let fastCursor = ToggleableDiagnosableProvider(
            provider: .cursor,
            result: ProviderFetchResult(snapshot: fastCursorSnapshot)
        )
        let providers: [any UsageProvider] = [
            heldClaude,
            UnconfiguredUsageProvider(provider: .chatgpt),
            fastCursor,
            UnconfiguredUsageProvider(provider: .gemini),
            UnconfiguredUsageProvider(provider: .opencode)
        ]
        let initial = ProviderID.allCases.map {
            ProviderSnapshot(provider: $0, plan: "", connectionState: .notConnected, limits: [], connectedVia: "Not connected")
        }
        let controller = AccountsController(
            isDemo: false,
            initialSnapshots: initial,
            providers: providers,
            providerRefreshTimeout: .milliseconds(400),
            clock: { Self.referenceNow }
        )

        let refreshTask = Task { await controller.refreshAll() }

        // Wait until Cursor becomes visible WITHOUT releasing heldClaude!
        for _ in 0..<200 where controller.snapshot(for: .cursor).connectionState != .connected {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(controller.snapshot(for: .cursor).connectionState, .connected)
        XCTAssertEqual(controller.snapshot(for: .cursor).fullestLimit?.percentUsed, 67)
        // Claude is still pending at this moment
        XCTAssertEqual(controller.snapshot(for: .claude).connectionState, .notConnected)

        // Let the bounded refresh timeout resolve Claude cleanly so refreshAll() exits in bounded time
        await refreshTask.value
        XCTAssertEqual(controller.snapshot(for: .claude).connectionState, .unsupported)
        XCTAssertEqual(controller.snapshot(for: .claude).connectedVia, "Request timed out")
    }

    // MARK: - Round 2 Defect 7: First-Fetch Failure Surfacing & Recoverable Unsupported Retries

    @MainActor
    func testFirstFetchTimeoutSurfacesDiagnosticAndRecoverableUnsupportedRetriesOnSchedule() async throws {
        let clock = MutableClock(referenceNow)

        // 1. First fetch times out when starting from initial "Not connected" placeholder -> surfaces diagnostic snapshot
        let failingClaude = ToggleableDiagnosableProvider(
            provider: .claude,
            result: ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: .claude,
                    plan: "",
                    connectionState: .unsupported,
                    limits: [],
                    connectedVia: "Request timed out",
                    updatedAt: referenceNow
                ),
                diagnostic: ProviderFetchDiagnostic(shortReason: "Request timed out", isTransientError: true)
            )
        )

        // 2. Codex starts with valid auth.json and NO rollout -> .unsupported; then rollout appears -> recovers on next refresh!
        let sessionsDir = URL(fileURLWithPath: "/virtual/.codex/sessions", isDirectory: true)
        let authURL = URL(fileURLWithPath: "/virtual/.codex/auth.json")
        let rolloutURL = sessionsDir.appendingPathComponent("2026/11/26/rollout-2026-11-26.jsonl")
        let validJWT = makeSyntheticJWT(expEpochSeconds: Int(referenceNow.addingTimeInterval(3600).timeIntervalSince1970))
        let validAuth = Data("{\"tokens\":{\"access_token\":\"\(validJWT)\"},\"plan_type\":\"plus\"}".utf8)
        let rolloutData = try loadLiveFixture("codex-rollout-rate-limits.jsonl")
        let meta = FileMetadata(size: UInt64(rolloutData.count), mtimeNanos: 1_795_718_100_000_000_000, inode: 30, isRegularFile: true, isDataless: false)

        final class MutableFileReader: LocalFileReader, @unchecked Sendable {
            private let lock = NSLock()
            private var files: [String: Data]
            private var discovered: [DiscoveredLocalFile]

            init(files: [String: Data], discovered: [DiscoveredLocalFile] = []) {
                self.files = files
                self.discovered = discovered
            }

            func addFile(url: URL, data: Data, discoveredFile: DiscoveredLocalFile) {
                lock.lock()
                files[url.path] = data
                discovered.append(discoveredFile)
                lock.unlock()
            }

            func readFile(at url: URL) throws -> Data? {
                lock.withLock { files[url.path] }
            }

            func discoverFiles(under root: URL, matching predicate: @Sendable (URL) -> Bool) -> [DiscoveredLocalFile] {
                let items = lock.withLock { discovered }
                return items.filter { predicate($0.url) }
            }

            func readSQLiteItems(at dbURL: URL, keys: [String]) throws -> [String: String]? {
                nil
            }
        }

        let mutableReader = MutableFileReader(files: [authURL.path: validAuth])
        let codexProvider = ChatGPTUsageProvider(
            fileReader: mutableReader,
            disableStore: InMemoryProviderDisableStore(),
            sessionsDirectory: sessionsDir,
            authFileURL: authURL,
            clock: { clock.now },
            timeZone: utc
        )

        let providers: [any UsageProvider] = [
            failingClaude,
            codexProvider,
            UnconfiguredUsageProvider(provider: .cursor),
            UnconfiguredUsageProvider(provider: .gemini),
            UnconfiguredUsageProvider(provider: .opencode)
        ]
        let initial = ProviderID.allCases.map {
            ProviderSnapshot(provider: $0, plan: "", connectionState: .notConnected, limits: [], connectedVia: "Not connected")
        }
        let controller = AccountsController(
            isDemo: false,
            initialSnapshots: initial,
            providers: providers,
            clock: { clock.now }
        )

        // First refresh: Claude surfaces "Request timed out" (not "Not connected"), Codex shows unsupported ("Run a Codex CLI session...")
        await controller.refreshAll()
        XCTAssertEqual(controller.snapshot(for: .claude).connectionState, .unsupported)
        XCTAssertEqual(controller.snapshot(for: .claude).connectedVia, "Request timed out")
        XCTAssertEqual(controller.snapshot(for: .chatgpt).connectionState, .unsupported)
        XCTAssertTrue(controller.snapshot(for: .chatgpt).connectedVia.contains("Codex CLI session"))

        // Now a Codex rollout appears on disk -> scheduled refresh MUST retry Codex and transition to .connected!
        mutableReader.addFile(
            url: rolloutURL,
            data: rolloutData,
            discoveredFile: DiscoveredLocalFile(url: rolloutURL, relativePath: "2026/11/26/rollout-2026-11-26.jsonl", metadata: meta)
        )
        await controller.refreshAll()
        XCTAssertEqual(controller.snapshot(for: .chatgpt).connectionState, .connected)
        XCTAssertEqual(controller.snapshot(for: .chatgpt).limits.map(\.percentUsed), [21, 54])

        // After Claude's backoff elapses and Claude recovers, scheduled refresh MUST retry Claude too!
        failingClaude.setResult(ProviderFetchResult(snapshot: DemoFixtures.snapshot(for: .claude, scenario: .all)))
        clock.advance(by: 61)
        await controller.refreshAll()
        XCTAssertEqual(controller.snapshot(for: .claude).connectionState, .connected)
        XCTAssertEqual(controller.snapshot(for: .claude).fullestLimit?.percentUsed, 81)
    }

    // MARK: - Round 2 Defect 9: Huge Finite JSON Numbers Rejected Safely While Other Providers Continue

    func testHugeFiniteNumbersAreRejectedWithoutCrashingWhileOtherProvidersContinue() async throws {
        // Direct formatter safety checks (must never trap)
        XCTAssertFalse(ResetTimeFormatter.isRepresentableUSD(1e20))
        XCTAssertFalse(ResetTimeFormatter.isRepresentableUSD(.infinity))
        XCTAssertFalse(ResetTimeFormatter.isRepresentableUSD(.nan))
        XCTAssertFalse(ResetTimeFormatter.isRepresentableUSD(-5))
        XCTAssertTrue(ResetTimeFormatter.isRepresentableUSD(20.0))
        XCTAssertFalse(ResetTimeFormatter.formatUSD(1e20).isEmpty)
        XCTAssertFalse(ResetTimeFormatter.formatAge(from: .distantPast, now: referenceNow).isEmpty)

        // 1. Codex rollout with window_minutes = 1e20 rejects the malformed primary window while preserving valid secondary
        let sessionsDir = URL(fileURLWithPath: "/virtual/.codex/sessions", isDirectory: true)
        let authURL = URL(fileURLWithPath: "/virtual/.codex/auth.json")
        let rolloutURL = sessionsDir.appendingPathComponent("2026/11/26/rollout-huge.jsonl")
        let validJWT = makeSyntheticJWT(expEpochSeconds: Int(referenceNow.addingTimeInterval(3600).timeIntervalSince1970))
        let validAuth = Data("{\"tokens\":{\"access_token\":\"\(validJWT)\"},\"plan_type\":\"plus\"}".utf8)
        let hugeOnlyRollout = Data("""
        {"timestamp":"2026-11-26T18:35:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":40,"window_minutes":1e20,"resets_at":1795734000},"plan_type":"plus"}}}
        """.utf8)
        let meta = FileMetadata(size: UInt64(hugeOnlyRollout.count), mtimeNanos: 1_795_718_100_000_000_000, inode: 40, isRegularFile: true, isDataless: false)
        let codexHuge = ChatGPTUsageProvider(
            fileReader: StubLocalFileReader(
                files: [authURL.path: validAuth, rolloutURL.path: hugeOnlyRollout],
                discovered: [DiscoveredLocalFile(url: rolloutURL, relativePath: "2026/11/26/rollout-huge.jsonl", metadata: meta)]
            ),
            disableStore: InMemoryProviderDisableStore(),
            sessionsDirectory: sessionsDir,
            authFileURL: authURL,
            clock: { Self.referenceNow },
            timeZone: utc
        )
        let codexResult = await codexHuge.fetchResult()
        XCTAssertEqual(codexResult.snapshot.connectionState, .unsupported)
        XCTAssertEqual(codexResult.diagnostic?.warnings, ["primary: present but not parseable"])

        // 2. Cursor with limit = 1e20 & includedSpend = 1e20 rejects those fields without trapping
        let cursorDBURL = URL(fileURLWithPath: "/virtual/cursor-huge.vscdb")
        let cursorHugeBody = Data("""
        {"billingCycleEnd":"1796774400000","planUsage":{"limit":1e20,"includedSpend":1e20}}
        """.utf8)
        let cursorHuge = CursorUsageProvider(
            fileReader: StubLocalFileReader(sqliteItemsByPath: [cursorDBURL.path: ["cursorAuth/accessToken": validJWT]]),
            httpTransport: StubHTTPTransport { _, _ in HTTPResponseData(statusCode: 200, body: cursorHugeBody) },
            disableStore: InMemoryProviderDisableStore(),
            stateDBURL: cursorDBURL,
            clock: { Self.referenceNow },
            timeZone: utc
        )
        let cursorResult = await cursorHuge.fetchResult()
        XCTAssertEqual(cursorResult.snapshot.connectionState, .unsupported)
        XCTAssertTrue(cursorResult.diagnostic?.warnings.contains("planUsage.limit: present but not parseable") == true)
        XCTAssertTrue(cursorResult.diagnostic?.warnings.contains("planUsage.includedSpend: present but not parseable") == true)

        // 3. OpenCode Go with percent = 1e20 rejects the field safely without trapping
        let openCodeAuthURL = URL(fileURLWithPath: "/virtual/.local/share/opencode/auth.json")
        let openCodeHuge = OpenCodeUsageProvider(
            fileReader: StubLocalFileReader(files: [openCodeAuthURL.path: Data("{\"opencode-go\":{\"type\":\"api\",\"key\":\"fixture-go-key\"}}".utf8)]),
            httpTransport: StubHTTPTransport { _, _ in
                HTTPResponseData(
                    statusCode: 200,
                    body: Data("""
                    {"usage":{"rolling":{"status":"ok","percent":1e20,"resetsAt":"2026-11-26T21:00:00.000Z"}}}
                    """.utf8)
                )
            },
            disableStore: InMemoryProviderDisableStore(),
            authFileURL: openCodeAuthURL,
            usageEndpoint: URL(string: "https://opencode.invalid/inference/go/v1/usage")!,
            clock: { Self.referenceNow },
            timeZone: utc
        )
        let openCodeResult = await openCodeHuge.fetchResult()
        XCTAssertEqual(openCodeResult.snapshot.connectionState, .unsupported)
        XCTAssertTrue(openCodeResult.diagnostic?.warnings.contains("usage.rolling.percent: present but not parseable") == true)

        // 4. Running all providers together: Codex rejects 1e20 while Claude continues and returns .connected
        let futureMs = Int64(referenceNow.addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        let claudeCred = Data("{\"claudeAiOauth\":{\"accessToken\":\"fixture-claude-ok\",\"expiresAt\":\(futureMs),\"subscriptionType\":\"max\"}}".utf8)
        let claudeSuccessBody = try loadLiveFixture("claude-usage-success.json")
        let claudeOK = ClaudeUsageProvider(
            keychain: StubKeychain(items: [ClaudeUsageProvider.defaultKeychainService: claudeCred]),
            httpTransport: StubHTTPTransport { _, _ in HTTPResponseData(statusCode: 200, body: claudeSuccessBody) },
            disableStore: InMemoryProviderDisableStore(),
            clock: { Self.referenceNow },
            timeZone: utc
        )
        let combinedReport = await LimitsDumper.generateReport(
            isDemo: false,
            providers: [
                claudeOK,
                codexHuge,
                cursorHuge,
                UnconfiguredUsageProvider(provider: .gemini),
                openCodeHuge
            ]
        )
        XCTAssertTrue(combinedReport.contains("claude: state=connected"))
        XCTAssertTrue(combinedReport.contains("chatgpt: state=unsupported"))
        XCTAssertTrue(combinedReport.contains("cursor: state=unsupported"))
        XCTAssertTrue(combinedReport.contains("opencode: state=unsupported"))
    }

    // MARK: - Round 3 Defect 2: Shared In-Flight Keychain Lookup & Late Consent Recovery

    func testClaudeSharedInFlightKeychainLookupDeduplicatesAndConsumesLateConsent() async throws {
        let successBody = try loadLiveFixture("claude-usage-success.json")
        let futureMs = Int64(referenceNow.addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        let validCred = Data("""
        {"claudeAiOauth":{"accessToken":"fixture-claude-late-consent","expiresAt":\(futureMs),"subscriptionType":"max","rateLimitTier":"default_claude_max_5x"}}
        """.utf8)

        final class SlowCountingKeychain: KeychainReading, @unchecked Sendable {
            private let lock = NSLock()
            private let delaySeconds: TimeInterval
            private let payload: Data
            private var _totalReads = 0
            private var _activeReads = 0
            private var _maxConcurrentReads = 0
            private let completedSemaphore = DispatchSemaphore(value: 0)

            var totalReads: Int { lock.withLock { _totalReads } }
            var maxConcurrentReads: Int { lock.withLock { _maxConcurrentReads } }

            init(delaySeconds: TimeInterval, payload: Data) {
                self.delaySeconds = delaySeconds
                self.payload = payload
            }

            func readGenericPassword(service: String, account: String?) throws -> Data? {
                lock.withLock {
                    _totalReads += 1
                    _activeReads += 1
                    _maxConcurrentReads = max(_maxConcurrentReads, _activeReads)
                }
                Thread.sleep(forTimeInterval: delaySeconds)
                lock.withLock {
                    _activeReads -= 1
                }
                completedSemaphore.signal()
                return payload
            }

            func waitForReadCompletion(timeout: TimeInterval) -> Bool {
                completedSemaphore.wait(timeout: .now() + timeout) == .success
            }
        }

        let slowKeychain = SlowCountingKeychain(delaySeconds: 0.35, payload: validCred)
        let provider = ClaudeUsageProvider(
            keychain: slowKeychain,
            httpTransport: StubHTTPTransport { _, _ in HTTPResponseData(statusCode: 200, body: successBody) },
            disableStore: InMemoryProviderDisableStore(),
            requestTimeout: 0.05,
            keychainTimeout: 0.05,
            clock: { Self.referenceNow },
            timeZone: utc
        )

        // Three successive fetches with a 50 ms deadline must NOT stack concurrent Keychain reads
        for _ in 0..<3 {
            let result = await provider.fetchResult()
            XCTAssertEqual(result.snapshot.connectionState, .waitingForKeychain)
            XCTAssertEqual(result.snapshot.connectedVia, "Waiting for Keychain access")
            XCTAssertEqual(result.snapshot.menuBarEntryState, .omitted)
        }
        XCTAssertEqual(slowKeychain.totalReads, 1)
        XCTAssertEqual(slowKeychain.maxConcurrentReads, 1)

        // Wait for the single underlying Keychain read to complete (late consent arrives)
        XCTAssertTrue(slowKeychain.waitForReadCompletion(timeout: 2.0))
        // Allow the actor completion task to store the unconsumed result in memory
        try await Task.sleep(for: .milliseconds(40))

        // Next fetch consumes the late completed result WITHOUT starting a second Keychain read!
        let recovered = await provider.fetchResult()
        XCTAssertEqual(recovered.snapshot.connectionState, .connected)
        XCTAssertEqual(recovered.snapshot.plan, "Max 5x")
        XCTAssertEqual(recovered.snapshot.fullestLimit?.percentUsed, 81)
        XCTAssertEqual(slowKeychain.totalReads, 1)
        XCTAssertEqual(slowKeychain.maxConcurrentReads, 1)
    }

    // MARK: - Round 3 Defect 3: Interactive CLI Keychain Consent Deadline & Stderr Notice

    func testCLIDumpLimitsUsesSeparateKeychainDeadlinePrintsStderrNoticeAndRecoversAfterHTTPTimeout() async throws {
        XCTAssertEqual(LimitsDumper.defaultCLIKeychainTimeout, 120.0)

        let successBody = try loadLiveFixture("claude-usage-success.json")
        let futureMs = Int64(referenceNow.addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        let validCred = Data("""
        {"claudeAiOauth":{"accessToken":"fixture-claude-cli-consent","expiresAt":\(futureMs),"subscriptionType":"max","rateLimitTier":"default_claude_max_5x"}}
        """.utf8)

        final class DelayedConsentKeychain: KeychainReading, @unchecked Sendable {
            private let delaySeconds: TimeInterval
            private let payload: Data

            init(delaySeconds: TimeInterval, payload: Data) {
                self.delaySeconds = delaySeconds
                self.payload = payload
            }

            func readGenericPassword(service: String, account: String?) throws -> Data? {
                Thread.sleep(forTimeInterval: delaySeconds)
                return payload
            }
        }

        final class StderrCapture: @unchecked Sendable {
            private let lock = NSLock()
            private var chunks: [String] = []
            func append(_ s: String) { lock.withLock { chunks.append(s) } }
            var combined: String { lock.withLock { chunks.joined() } }
        }

        // Consent arrives after 150 ms — 3x longer than the 50 ms HTTP requestTimeout, but within the 1.0 s CLI keychainTimeout.
        let delayedKeychain = DelayedConsentKeychain(delaySeconds: 0.15, payload: validCred)
        let stderrCapture = StderrCapture()
        let dumpResult = await CLIDumpDispatcher.run(
            arguments: ["OpenUsage", "--dump-limits"],
            httpTransport: StubHTTPTransport { _, timeout in
                XCTAssertEqual(timeout, 0.05, accuracy: 0.001)
                return HTTPResponseData(statusCode: 200, body: successBody)
            },
            fileReader: StubLocalFileReader(),
            keychain: delayedKeychain,
            disableStore: InMemoryProviderDisableStore(),
            requestTimeout: 0.05,
            keychainTimeout: 1.0,
            stderrWriter: { stderrCapture.append($0) },
            clock: { Self.referenceNow },
            timeZone: utc
        )

        XCTAssertNotNil(dumpResult)
        XCTAssertEqual(dumpResult?.exitCode, 0)
        XCTAssertTrue(dumpResult?.stdout.contains("claude: state=connected plan=\"Max 5x\"") == true)
        XCTAssertTrue(dumpResult?.stdout.contains("Weekly · Opus: 81%") == true)
        XCTAssertTrue(dumpResult?.stderr.localizedCaseInsensitiveContains("Keychain") == true)
        XCTAssertEqual(stderrCapture.combined, dumpResult?.stderr)
        // Exactly one line printed to stderr
        XCTAssertEqual(dumpResult?.stderr.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.isEmpty }.count, 1)

        // Same for --dump-limits-shape
        let shapeCapture = StderrCapture()
        let shapeResult = await CLIDumpDispatcher.run(
            arguments: ["OpenUsage", "--dump-limits-shape"],
            httpTransport: StubHTTPTransport { _, _ in HTTPResponseData(statusCode: 200, body: successBody) },
            fileReader: StubLocalFileReader(),
            keychain: DelayedConsentKeychain(delaySeconds: 0.15, payload: validCred),
            disableStore: InMemoryProviderDisableStore(),
            requestTimeout: 0.05,
            keychainTimeout: 1.0,
            stderrWriter: { shapeCapture.append($0) },
            clock: { Self.referenceNow },
            timeZone: utc
        )
        XCTAssertEqual(shapeResult?.exitCode, 0)
        XCTAssertTrue(shapeResult?.stdout.contains("claude: state=connected") == true)
        XCTAssertTrue(shapeResult?.stderr.localizedCaseInsensitiveContains("Keychain") == true)
        XCTAssertEqual(shapeCapture.combined, shapeResult?.stderr)

        // Demo --dump-limits must NOT emit Keychain notice and must NOT touch Keychain
        let demoDump = await CLIDumpDispatcher.run(
            arguments: ["OpenUsage", "--demo", "--dump-limits"],
            httpTransport: FailingHTTPTransport(),
            fileReader: FailingLocalFileReader(),
            keychain: FailingKeychain(),
            disableStore: FailingDisableStore(),
            urlOpener: FailingURLOpener()
        )
        XCTAssertEqual(demoDump?.exitCode, 0)
        XCTAssertEqual(demoDump?.stderr, "")
    }

    // MARK: - Round 3 Defect 4: API-Key-Only Codex Auth Must Not Resurrect Subscription Rollouts

    func testChatGPTAPIKeyOnlyAuthProducesNoSubscriptionPlanOrLimits() async throws {
        let rolloutData = try loadLiveFixture("codex-rollout-rate-limits.jsonl")
        let sessionsDir = URL(fileURLWithPath: "/virtual/.codex/sessions", isDirectory: true)
        let rolloutURL = sessionsDir.appendingPathComponent("2026/11/26/rollout-2026-11-26.jsonl")
        let authURL = URL(fileURLWithPath: "/virtual/.codex/auth.json")
        let meta = FileMetadata(size: UInt64(rolloutData.count), mtimeNanos: 1_795_718_100_000_000_000, inode: 50, isRegularFile: true, isDataless: false)

        // 1. Only OPENAI_API_KEY in auth.json alongside an old Plus rollout -> must NOT report connected / Plus / old limits
        let apiKeyOnlyAuth = Data("{\"OPENAI_API_KEY\":\"sk-fixture-api-key-only-001\"}".utf8)
        let apiKeyResult = await ChatGPTUsageProvider(
            fileReader: StubLocalFileReader(
                files: [
                    authURL.path: apiKeyOnlyAuth,
                    rolloutURL.path: rolloutData
                ],
                discovered: [DiscoveredLocalFile(url: rolloutURL, relativePath: "2026/11/26/rollout-2026-11-26.jsonl", metadata: meta)]
            ),
            disableStore: InMemoryProviderDisableStore(),
            sessionsDirectory: sessionsDir,
            authFileURL: authURL,
            clock: { Self.referenceNow },
            timeZone: utc
        ).fetchResult()

        XCTAssertNotEqual(apiKeyResult.snapshot.connectionState, .connected)
        XCTAssertEqual(apiKeyResult.snapshot.connectionState, .notConnected)
        XCTAssertEqual(apiKeyResult.snapshot.plan, "")
        XCTAssertTrue(apiKeyResult.snapshot.limits.isEmpty)
        XCTAssertEqual(apiKeyResult.snapshot.menuBarEntryState, .omitted)

        // 2. Explicit auth_mode=api_key even if stale tokens exist alongside rollout -> must NOT publish subscription rollout
        let validJWT = makeSyntheticJWT(expEpochSeconds: Int(referenceNow.addingTimeInterval(3600).timeIntervalSince1970))
        let explicitAPIKeyMode = Data("""
        {"auth_mode":"api_key","OPENAI_API_KEY":"sk-fixture-api-key-only-002","tokens":{"access_token":"\(validJWT)"},"plan_type":"plus"}
        """.utf8)
        let explicitResult = await ChatGPTUsageProvider(
            fileReader: StubLocalFileReader(
                files: [
                    authURL.path: explicitAPIKeyMode,
                    rolloutURL.path: rolloutData
                ],
                discovered: [DiscoveredLocalFile(url: rolloutURL, relativePath: "2026/11/26/rollout-2026-11-26.jsonl", metadata: meta)]
            ),
            disableStore: InMemoryProviderDisableStore(),
            sessionsDirectory: sessionsDir,
            authFileURL: authURL,
            clock: { Self.referenceNow },
            timeZone: utc
        ).fetchResult()

        XCTAssertNotEqual(explicitResult.snapshot.connectionState, .connected)
        XCTAssertEqual(explicitResult.snapshot.plan, "")
        XCTAssertTrue(explicitResult.snapshot.limits.isEmpty)
    }

    // MARK: - Round 3 Defect 5: Codex Rollout Ordering by Event Timestamp Across Candidate Files

    func testChatGPTSelectsNewestEventTimestampAcrossRolloutsEvenWhenOlderEventHasNewerMtime() async {
        let sessionsDir = URL(fileURLWithPath: "/virtual/.codex/sessions", isDirectory: true)
        let authURL = URL(fileURLWithPath: "/virtual/.codex/auth.json")
        let olderEventFile = sessionsDir.appendingPathComponent("2026/11/26/rollout-older-event-newer-mtime.jsonl")
        let newerEventFile = sessionsDir.appendingPathComponent("2026/11/26/rollout-newer-event-older-mtime.jsonl")

        let validJWT = makeSyntheticJWT(expEpochSeconds: Int(referenceNow.addingTimeInterval(3600).timeIntervalSince1970))
        let validAuth = Data("{\"tokens\":{\"access_token\":\"\(validJWT)\"},\"plan_type\":\"plus\"}".utf8)

        let olderEventData = Data("""
        {"timestamp":"2026-11-26T18:10:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":71,"window_minutes":300,"resets_at":1795731720},"plan_type":"plus"}}}
        """.utf8)
        let newerEventData = Data("""
        {"timestamp":"2026-11-26T18:35:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":23,"window_minutes":300,"resets_at":1795731720},"plan_type":"plus"}}}
        """.utf8)

        // Deliberately give the OLDER event's file the NEWER modification time
        let newerMtimeMeta = FileMetadata(size: UInt64(olderEventData.count), mtimeNanos: 1_795_720_000_000_000_000, inode: 60, isRegularFile: true, isDataless: false)
        let olderMtimeMeta = FileMetadata(size: UInt64(newerEventData.count), mtimeNanos: 1_795_718_000_000_000_000, inode: 61, isRegularFile: true, isDataless: false)

        let provider = ChatGPTUsageProvider(
            fileReader: StubLocalFileReader(
                files: [
                    authURL.path: validAuth,
                    olderEventFile.path: olderEventData,
                    newerEventFile.path: newerEventData
                ],
                discovered: [
                    DiscoveredLocalFile(url: olderEventFile, relativePath: "2026/11/26/rollout-older-event-newer-mtime.jsonl", metadata: newerMtimeMeta),
                    DiscoveredLocalFile(url: newerEventFile, relativePath: "2026/11/26/rollout-newer-event-older-mtime.jsonl", metadata: olderMtimeMeta)
                ]
            ),
            disableStore: InMemoryProviderDisableStore(),
            sessionsDirectory: sessionsDir,
            authFileURL: authURL,
            clock: { Self.referenceNow },
            timeZone: utc
        )

        let result = await provider.fetchResult()
        XCTAssertEqual(result.snapshot.connectionState, .connected)
        XCTAssertEqual(result.snapshot.limits.count, 1)
        XCTAssertEqual(result.snapshot.limits.first?.percentUsed, 23)
    }

    // MARK: - Round 3 Defect 6: Codex Window Duration Labels From Real window_minutes

    func testChatGPTLabelsWindowsFromExplicitWindowMinutesWithoutInventing5Hour() async {
        let sessionsDir = URL(fileURLWithPath: "/virtual/.codex/sessions", isDirectory: true)
        let authURL = URL(fileURLWithPath: "/virtual/.codex/auth.json")
        let rolloutURL = sessionsDir.appendingPathComponent("2026/11/26/rollout-durations.jsonl")

        let validJWT = makeSyntheticJWT(expEpochSeconds: Int(referenceNow.addingTimeInterval(3600).timeIntervalSince1970))
        let validAuth = Data("{\"tokens\":{\"access_token\":\"\(validJWT)\"},\"plan_type\":\"plus\"}".utf8)

        let customDurations = Data("""
        {"timestamp":"2026-11-26T18:35:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":34,"window_minutes":90,"resets_at":1795731720},"secondary":{"used_percent":52,"window_minutes":4320,"resets_at":1796036400},"plan_type":"plus"}}}
        """.utf8)
        let meta = FileMetadata(size: UInt64(customDurations.count), mtimeNanos: 1_795_718_100_000_000_000, inode: 70, isRegularFile: true, isDataless: false)

        let customResult = await ChatGPTUsageProvider(
            fileReader: StubLocalFileReader(
                files: [authURL.path: validAuth, rolloutURL.path: customDurations],
                discovered: [DiscoveredLocalFile(url: rolloutURL, relativePath: "2026/11/26/rollout-durations.jsonl", metadata: meta)]
            ),
            disableStore: InMemoryProviderDisableStore(),
            sessionsDirectory: sessionsDir,
            authFileURL: authURL,
            clock: { Self.referenceNow },
            timeZone: utc
        ).fetchResult()

        XCTAssertEqual(customResult.snapshot.connectionState, .connected)
        XCTAssertEqual(customResult.snapshot.limits.map(\.name), ["90-minute", "3-day"])
        XCTAssertFalse(customResult.snapshot.limits.map(\.name).contains("5-hour"))

        // Standard 300 / 10080 still map to "5-hour" / "Weekly", and 120 maps to "2-hour"
        let standardDurations = Data("""
        {"timestamp":"2026-11-26T18:35:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":12,"window_minutes":120,"resets_at":1795731720},"secondary":{"used_percent":44,"window_minutes":10080,"resets_at":1796036400},"plan_type":"plus"}}}
        """.utf8)
        let standardResult = await ChatGPTUsageProvider(
            fileReader: StubLocalFileReader(
                files: [authURL.path: validAuth, rolloutURL.path: standardDurations],
                discovered: [DiscoveredLocalFile(url: rolloutURL, relativePath: "2026/11/26/rollout-durations.jsonl", metadata: meta)]
            ),
            disableStore: InMemoryProviderDisableStore(),
            sessionsDirectory: sessionsDir,
            authFileURL: authURL,
            clock: { Self.referenceNow },
            timeZone: utc
        ).fetchResult()
        XCTAssertEqual(standardResult.snapshot.limits.map(\.name), ["2-hour", "Weekly"])
    }

    // MARK: - Round 3 Defect 7: Codex Auth File Read Error Distinct From Logout & Applies Backoff

    @MainActor
    func testChatGPTAuthReadErrorIsDistinctFromNotConnectedPreservesRedactedReasonAndAppliesBackoff() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("openusage-codex-oversize-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let authURL = tempDir.appendingPathComponent("auth.json")
        let sessionsDir = tempDir.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        // Create an existing auth file that exceeds the reader's 1024-byte limit
        let oversizedPadding = String(repeating: "a", count: 2048)
        let oversizedData = Data("{\"tokens\":{\"access_token\":\"fixture-secret-token-oversize-\(oversizedPadding)\"}}".utf8)
        try oversizedData.write(to: authURL)

        let clock = MutableClock(referenceNow)
        let boundedReader = SystemLocalFileReader(maxFileBytes: 1024)
        let codexProvider = ChatGPTUsageProvider(
            fileReader: boundedReader,
            disableStore: InMemoryProviderDisableStore(),
            sessionsDirectory: sessionsDir,
            authFileURL: authURL,
            clock: { clock.now },
            timeZone: utc
        )

        let directResult = await codexProvider.fetchResult()
        XCTAssertNotEqual(directResult.snapshot.connectionState, .notConnected)
        XCTAssertEqual(directResult.snapshot.connectionState, .unsupported)
        XCTAssertEqual(directResult.snapshot.connectedVia, LocalFileReaderError.fileTooLarge.shortReason)
        XCTAssertEqual(directResult.diagnostic?.shortReason, LocalFileReaderError.fileTooLarge.shortReason)
        XCTAssertEqual(directResult.diagnostic?.isTransientError, true)
        XCTAssertFalse(directResult.snapshot.connectedVia.contains("fixture-secret-token"))

        // Verify AccountsController applies backoff on the read failure rather than reporting logout
        let providers: [any UsageProvider] = [
            UnconfiguredUsageProvider(provider: .claude),
            codexProvider,
            UnconfiguredUsageProvider(provider: .cursor),
            UnconfiguredUsageProvider(provider: .gemini),
            UnconfiguredUsageProvider(provider: .opencode)
        ]
        let initial = ProviderID.allCases.map {
            ProviderSnapshot(provider: $0, plan: "", connectionState: .notConnected, limits: [], connectedVia: "Not connected")
        }
        let controller = AccountsController(
            isDemo: false,
            initialSnapshots: initial,
            providers: providers,
            clock: { clock.now }
        )

        await controller.refreshAll()
        XCTAssertEqual(controller.snapshot(for: .chatgpt).connectionState, .unsupported)
        XCTAssertEqual(controller.snapshot(for: .chatgpt).connectedVia, LocalFileReaderError.fileTooLarge.shortReason)
        XCTAssertEqual(controller.consecutiveFailureCount(for: .chatgpt), 1)
        XCTAssertEqual(controller.nextAllowedRefreshDate(for: .chatgpt), referenceNow.addingTimeInterval(60))
    }

    // MARK: - Round 4 Defect 1: Denied Parent-Directory Access Distinct From Logout & Applies Backoff

    @MainActor
    func testDeniedParentDirectoryAccessIsTransientErrorWithBackoffNotLoggedOut() async throws {
        try XCTSkipIf(geteuid() == 0, "Root bypasses POSIX directory permission checks")

        let outerDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-perm-denied-\(UUID().uuidString)", isDirectory: true)
        let lockedDir = outerDir.appendingPathComponent("locked", isDirectory: true)
        let sessionsDir = outerDir.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: lockedDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        defer {
            _ = chmod(lockedDir.path, 0o700)
            try? FileManager.default.removeItem(at: outerDir)
        }

        let authURL = lockedDir.appendingPathComponent("auth.json")
        let validJWT = makeSyntheticJWT(expEpochSeconds: Int(referenceNow.addingTimeInterval(3600).timeIntervalSince1970))
        let validAuth = Data("{\"tokens\":{\"access_token\":\"\(validJWT)\"},\"plan_type\":\"plus\"}".utf8)
        try validAuth.write(to: authURL)

        let dbURL = lockedDir.appendingPathComponent("state.vscdb")
        try createCursorStateDB(at: dbURL, entries: ["cursorAuth/accessToken": validJWT])

        let missingURL = outerDir.appendingPathComponent("does-not-exist.json")
        let reader = SystemLocalFileReader()
        XCTAssertNil(try reader.readFile(at: missingURL))
        XCTAssertNil(try reader.readSQLiteItems(at: outerDir.appendingPathComponent("missing.vscdb"), keys: ["cursorAuth/accessToken"]))

        // Remove all permissions (including traversal) from the parent directory
        XCTAssertEqual(chmod(lockedDir.path, 0o000), 0)

        XCTAssertThrowsError(try reader.readFile(at: authURL)) { error in
            XCTAssertEqual(error as? LocalFileReaderError, .permissionDenied)
        }
        XCTAssertThrowsError(try reader.readSQLiteItems(at: dbURL, keys: ["cursorAuth/accessToken"])) { error in
            XCTAssertEqual(error as? LocalFileReaderError, .permissionDenied)
        }

        let clock = MutableClock(referenceNow)
        let codexProvider = ChatGPTUsageProvider(
            fileReader: reader,
            disableStore: InMemoryProviderDisableStore(),
            sessionsDirectory: sessionsDir,
            authFileURL: authURL,
            clock: { clock.now },
            timeZone: utc
        )

        let directResult = await codexProvider.fetchResult()
        XCTAssertNotEqual(directResult.snapshot.connectionState, .notConnected)
        XCTAssertEqual(directResult.snapshot.connectionState, .unsupported)
        XCTAssertEqual(directResult.snapshot.connectedVia, LocalFileReaderError.permissionDenied.shortReason)
        XCTAssertEqual(directResult.diagnostic?.shortReason, LocalFileReaderError.permissionDenied.shortReason)
        XCTAssertEqual(directResult.diagnostic?.isTransientError, true)
        XCTAssertFalse(directResult.snapshot.connectedVia.contains(lockedDir.path))
        XCTAssertFalse(directResult.snapshot.connectedVia.contains(validJWT))

        // AccountsController routes denied access through backoff rather than reporting logout
        let providers: [any UsageProvider] = [
            UnconfiguredUsageProvider(provider: .claude),
            codexProvider,
            UnconfiguredUsageProvider(provider: .cursor),
            UnconfiguredUsageProvider(provider: .gemini),
            UnconfiguredUsageProvider(provider: .opencode)
        ]
        let initial = ProviderID.allCases.map {
            ProviderSnapshot(provider: $0, plan: "", connectionState: .notConnected, limits: [], connectedVia: "Not connected")
        }
        let controller = AccountsController(
            isDemo: false,
            initialSnapshots: initial,
            providers: providers,
            clock: { clock.now }
        )

        await controller.refreshAll()
        XCTAssertEqual(controller.snapshot(for: .chatgpt).connectionState, .unsupported)
        XCTAssertEqual(controller.snapshot(for: .chatgpt).connectedVia, LocalFileReaderError.permissionDenied.shortReason)
        XCTAssertEqual(controller.consecutiveFailureCount(for: .chatgpt), 1)
        XCTAssertEqual(controller.nextAllowedRefreshDate(for: .chatgpt), referenceNow.addingTimeInterval(60))
    }

    // MARK: - Round 4 Defect 2: Codex Filters Out Different Explicit limit_id Events

    func testChatGPTIgnoresNewerEventsWithDifferentExplicitLimitID() async {
        let sessionsDir = URL(fileURLWithPath: "/virtual/.codex/sessions", isDirectory: true)
        let authURL = URL(fileURLWithPath: "/virtual/.codex/auth.json")
        let rolloutA = sessionsDir.appendingPathComponent("2026/11/26/rollout-a.jsonl")
        let rolloutB = sessionsDir.appendingPathComponent("2026/11/26/rollout-b.jsonl")

        let validJWT = makeSyntheticJWT(expEpochSeconds: Int(referenceNow.addingTimeInterval(3600).timeIntervalSince1970))
        let validAuth = Data("{\"tokens\":{\"access_token\":\"\(validJWT)\"},\"plan_type\":\"plus\"}".utf8)

        // Same file: codex weekly event at 23%, followed by a newer event with a different limit_id at 92%
        let mixedFileData = Data("""
        {"timestamp":"2026-11-26T18:20:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":23,"window_minutes":10080,"resets_at":1796036400},"plan_type":"plus"}}}
        {"timestamp":"2026-11-26T18:35:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex_other","primary":{"used_percent":92,"window_minutes":10080,"resets_at":1796036400},"plan_type":"plus"}}}
        """.utf8)
        let metaA = FileMetadata(size: UInt64(mixedFileData.count), mtimeNanos: 1_795_718_100_000_000_000, inode: 80, isRegularFile: true, isDataless: false)

        // Newer file containing only a different explicit limit_id at 95%
        let otherLimitOnlyData = Data("""
        {"timestamp":"2026-11-26T18:40:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"spark_beta","primary":{"used_percent":95,"window_minutes":10080,"resets_at":1796036400},"plan_type":"plus"}}}
        """.utf8)
        let metaB = FileMetadata(size: UInt64(otherLimitOnlyData.count), mtimeNanos: 1_795_718_400_000_000_000, inode: 81, isRegularFile: true, isDataless: false)

        let result = await ChatGPTUsageProvider(
            fileReader: StubLocalFileReader(
                files: [
                    authURL.path: validAuth,
                    rolloutA.path: mixedFileData,
                    rolloutB.path: otherLimitOnlyData
                ],
                discovered: [
                    DiscoveredLocalFile(url: rolloutA, relativePath: "2026/11/26/rollout-a.jsonl", metadata: metaA),
                    DiscoveredLocalFile(url: rolloutB, relativePath: "2026/11/26/rollout-b.jsonl", metadata: metaB)
                ]
            ),
            disableStore: InMemoryProviderDisableStore(),
            sessionsDirectory: sessionsDir,
            authFileURL: authURL,
            clock: { Self.referenceNow },
            timeZone: utc
        ).fetchResult()

        XCTAssertEqual(result.snapshot.connectionState, .connected)
        XCTAssertEqual(result.snapshot.limits.map(\.name), ["Weekly"])
        XCTAssertEqual(result.snapshot.limits.map(\.percentUsed), [23])

        // Absent or null limit_id is still accepted as the subscription limit
        let nullLimitIDData = Data("""
        {"timestamp":"2026-11-26T18:25:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":null,"primary":{"used_percent":31,"window_minutes":10080,"resets_at":1796036400},"plan_type":"plus"}}}
        """.utf8)
        let nullResult = await ChatGPTUsageProvider(
            fileReader: StubLocalFileReader(
                files: [authURL.path: validAuth, rolloutA.path: nullLimitIDData],
                discovered: [DiscoveredLocalFile(url: rolloutA, relativePath: "2026/11/26/rollout-a.jsonl", metadata: metaA)]
            ),
            disableStore: InMemoryProviderDisableStore(),
            sessionsDirectory: sessionsDir,
            authFileURL: authURL,
            clock: { Self.referenceNow },
            timeZone: utc
        ).fetchResult()
        XCTAssertEqual(nullResult.snapshot.connectionState, .connected)
        XCTAssertEqual(nullResult.snapshot.limits.map(\.percentUsed), [31])

        // Rollouts with ONLY non-codex limit_id must not report connected
        let onlyOtherResult = await ChatGPTUsageProvider(
            fileReader: StubLocalFileReader(
                files: [authURL.path: validAuth, rolloutB.path: otherLimitOnlyData],
                discovered: [DiscoveredLocalFile(url: rolloutB, relativePath: "2026/11/26/rollout-b.jsonl", metadata: metaB)]
            ),
            disableStore: InMemoryProviderDisableStore(),
            sessionsDirectory: sessionsDir,
            authFileURL: authURL,
            clock: { Self.referenceNow },
            timeZone: utc
        ).fetchResult()
        XCTAssertEqual(onlyOtherResult.snapshot.connectionState, .unsupported)
        XCTAssertTrue(onlyOtherResult.snapshot.limits.isEmpty)
    }

    // MARK: - Round 4 Defect 3: Codex Duration-Neutral Label When window_minutes Is Absent

    func testChatGPTUsesDurationNeutralLabelWhenWindowMinutesIsAbsentOrNull() async {
        let sessionsDir = URL(fileURLWithPath: "/virtual/.codex/sessions", isDirectory: true)
        let authURL = URL(fileURLWithPath: "/virtual/.codex/auth.json")
        let rolloutURL = sessionsDir.appendingPathComponent("2026/11/26/rollout-no-minutes.jsonl")

        let validJWT = makeSyntheticJWT(expEpochSeconds: Int(referenceNow.addingTimeInterval(3600).timeIntervalSince1970))
        let validAuth = Data("{\"tokens\":{\"access_token\":\"\(validJWT)\"},\"plan_type\":\"plus\"}".utf8)

        // Primary has only used_percent: 92; secondary has window_minutes: null and used_percent: 47
        let missingMinutesData = Data("""
        {"timestamp":"2026-11-26T18:35:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":92},"secondary":{"used_percent":47,"window_minutes":null},"plan_type":"plus"}}}
        """.utf8)
        let meta = FileMetadata(size: UInt64(missingMinutesData.count), mtimeNanos: 1_795_718_100_000_000_000, inode: 82, isRegularFile: true, isDataless: false)

        let result = await ChatGPTUsageProvider(
            fileReader: StubLocalFileReader(
                files: [authURL.path: validAuth, rolloutURL.path: missingMinutesData],
                discovered: [DiscoveredLocalFile(url: rolloutURL, relativePath: "2026/11/26/rollout-no-minutes.jsonl", metadata: meta)]
            ),
            disableStore: InMemoryProviderDisableStore(),
            sessionsDirectory: sessionsDir,
            authFileURL: authURL,
            clock: { Self.referenceNow },
            timeZone: utc
        ).fetchResult()

        XCTAssertEqual(result.snapshot.connectionState, .connected)
        XCTAssertEqual(result.snapshot.limits.map(\.name), ["Usage window", "Usage window"])
        XCTAssertEqual(result.snapshot.limits.map(\.percentUsed), [92, 47])
        XCTAssertEqual(Set(result.snapshot.limits.map(\.id)).count, 2)
        XCTAssertFalse(result.snapshot.limits.map(\.name).contains("5-hour"))
        XCTAssertFalse(result.snapshot.limits.map(\.name).contains("Weekly"))
    }

    // MARK: - Round 4 Defect 4: Cursor Does Not Present Auto Usage as Total Included Usage

    func testCursorAutoPercentOnlyResponseLeavesTotalIncludedUsageUnavailable() async {
        let cursorDBURL = URL(fileURLWithPath: "/virtual/cursor-auto-only.vscdb")
        let validJWT = makeSyntheticJWT(expEpochSeconds: Int(referenceNow.addingTimeInterval(3600).timeIntervalSince1970))
        let reader = StubLocalFileReader(sqliteItemsByPath: [
            cursorDBURL.path: [
                "cursorAuth/accessToken": validJWT,
                "cursorAuth/stripeMembershipType": "pro"
            ]
        ])

        // 1. Response with ONLY planUsage.autoPercentUsed -> must NOT report connected or "Included usage: 12%"
        let autoOnlyBody = Data("""
        {"billingCycleEnd":"1796774400000","planUsage":{"autoPercentUsed":12}}
        """.utf8)
        let autoOnlyResult = await CursorUsageProvider(
            fileReader: reader,
            httpTransport: StubHTTPTransport { _, _ in HTTPResponseData(statusCode: 200, body: autoOnlyBody) },
            disableStore: InMemoryProviderDisableStore(),
            stateDBURL: cursorDBURL,
            clock: { Self.referenceNow },
            timeZone: utc
        ).fetchResult()
        XCTAssertEqual(autoOnlyResult.snapshot.connectionState, .unsupported)
        XCTAssertTrue(autoOnlyResult.snapshot.limits.isEmpty)
        XCTAssertEqual(autoOnlyResult.diagnostic?.httpStatus, 200)

        // 2. Response with totalPercentUsed alongside autoPercentUsed -> uses totalPercentUsed
        let totalWithAutoBody = Data("""
        {"billingCycleEnd":"1796774400000","planUsage":{"autoPercentUsed":12,"totalPercentUsed":34}}
        """.utf8)
        let totalResult = await CursorUsageProvider(
            fileReader: reader,
            httpTransport: StubHTTPTransport { _, _ in HTTPResponseData(statusCode: 200, body: totalWithAutoBody) },
            disableStore: InMemoryProviderDisableStore(),
            stateDBURL: cursorDBURL,
            clock: { Self.referenceNow },
            timeZone: utc
        ).fetchResult()
        XCTAssertEqual(totalResult.snapshot.connectionState, .connected)
        XCTAssertEqual(totalResult.snapshot.limits.map(\.name), ["Included usage"])
        XCTAssertEqual(totalResult.snapshot.limits.map(\.percentUsed), [34])
    }

    // MARK: - OpenCode Go Live Support Tests

    func testOpenCodeGoKeyPrecedenceOverZenAndThirdPartyKeys() async throws {
        let successBody = try loadLiveFixture("opencode-usage-success.json")
        let authURL = URL(fileURLWithPath: "/virtual/.local/share/opencode/auth.json")
        let pastMs = Int64(referenceNow.addingTimeInterval(-3600).timeIntervalSince1970 * 1000)

        // When opencode, zen, opencode-zen, anthropic, and opencode-go all exist, opencode-go wins!
        let combinedAuth = Data("""
        {
          "anthropic": {"type": "api", "key": "fixture-anthropic-third-party-key"},
          "opencode": {"type": "oauth", "access": "fixture-zen-expired-token", "expires": \(pastMs)},
          "zen": {"type": "api", "key": "fixture-legacy-zen-key"},
          "opencode-zen": {"type": "api", "key": "fixture-opencode-zen-key"},
          "opencode-go": {"type": "api", "key": "fixture-preferred-go-key-999"}
        }
        """.utf8)

        final class AuthHeaderCapture: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [String] = []
            func append(_ value: String) { lock.withLock { values.append(value) } }
            var headers: [String] { lock.withLock { values } }
        }

        let headerCapture = AuthHeaderCapture()
        let transport = StubHTTPTransport { req, _ in
            headerCapture.append(req.value(forHTTPHeaderField: "Authorization") ?? "")
            return HTTPResponseData(statusCode: 200, body: successBody)
        }

        let result = await OpenCodeUsageProvider(
            fileReader: StubLocalFileReader(files: [authURL.path: combinedAuth]),
            httpTransport: transport,
            disableStore: InMemoryProviderDisableStore(),
            authFileURL: authURL,
            clock: { Self.referenceNow },
            timeZone: utc
        ).fetchResult()

        XCTAssertEqual(result.snapshot.connectionState, .connected)
        XCTAssertEqual(result.snapshot.plan, "Go")
        XCTAssertEqual(result.snapshot.limits.count, 3)
        XCTAssertEqual(headerCapture.headers, ["Bearer fixture-preferred-go-key-999"])
    }

    func testOpenCodeGoRefreshOnlyCredentialsNeverCallUsageAPI() async {
        let authURL = URL(fileURLWithPath: "/virtual/.local/share/opencode/auth.json")
        let neverHTTP = StubHTTPTransport { _, _ in
            XCTFail("Refresh credentials must never be sent to the OpenCode Go usage API")
            return HTTPResponseData(statusCode: 500, body: Data())
        }

        let refreshPayloads: [(name: String, secret: String, json: String)] = [
            ("refresh", "fixture-refresh-secret-alpha", #"{"opencode-go":{"type":"oauth","refresh":"fixture-refresh-secret-alpha"}}"#),
            ("refresh_token", "fixture-refresh-secret-beta", #"{"opencode-go":{"type":"oauth","refresh_token":"fixture-refresh-secret-beta"}}"#),
            ("refreshToken", "fixture-refresh-secret-gamma", #"{"opencode-go":{"type":"oauth","access":"   ","refreshToken":"fixture-refresh-secret-gamma"}}"#)
        ]

        for entry in refreshPayloads {
            let result = await OpenCodeUsageProvider(
                fileReader: StubLocalFileReader(files: [authURL.path: Data(entry.json.utf8)]),
                httpTransport: neverHTTP,
                disableStore: InMemoryProviderDisableStore(),
                authFileURL: authURL,
                clock: { Self.referenceNow },
                timeZone: utc
            ).fetchResult(captureShape: true)

            XCTAssertEqual(result.snapshot.connectionState, .unsupported, "Failed for \(entry.name)")
            XCTAssertNotEqual(result.snapshot.connectionState, .expired)
            XCTAssertTrue(result.snapshot.limits.isEmpty)
            XCTAssertEqual(result.snapshot.menuBarEntryState, .omitted)

            let report = LimitsDumper.formatReport(results: [result], isDemo: false)
            let shapeReport = LimitsDumper.formatShapeReport(results: [result], isDemo: false)
            XCTAssertFalse(report.contains(entry.secret))
            XCTAssertFalse(shapeReport.contains(entry.secret))
        }
        XCTAssertTrue(neverHTTP.requests.isEmpty)
    }

    @MainActor
    func testOpenCodeGo401InvalidKeyVs403MissingEntitlementAndTransientErrors() async throws {
        let goAuthFixture = try loadLiveFixture("opencode-auth-go.json")
        let successBody = try loadLiveFixture("opencode-usage-success.json")
        let authURL = URL(fileURLWithPath: "/virtual/.local/share/opencode/auth.json")

        // 1. HTTP 401 -> .expired (invalid key)
        let unauthorized = await OpenCodeUsageProvider(
            fileReader: StubLocalFileReader(files: [authURL.path: goAuthFixture]),
            httpTransport: StubHTTPTransport { _, _ in HTTPResponseData(statusCode: 401, body: Data("{\"error\":\"invalid_api_key\"}".utf8)) },
            disableStore: InMemoryProviderDisableStore(),
            authFileURL: authURL,
            clock: { Self.referenceNow },
            timeZone: utc
        ).fetchResult()
        XCTAssertEqual(unauthorized.snapshot.connectionState, .expired)
        XCTAssertEqual(unauthorized.snapshot.menuBarEntryState, .dimmedPlaceholder)
        XCTAssertEqual(unauthorized.diagnostic?.httpStatus, 401)
        XCTAssertEqual(unauthorized.diagnostic?.isTransientError, false)

        // 2. HTTP 403 -> .unsupported (valid key without Go entitlement, NOT .expired!)
        let forbidden = await OpenCodeUsageProvider(
            fileReader: StubLocalFileReader(files: [authURL.path: goAuthFixture]),
            httpTransport: StubHTTPTransport { _, _ in HTTPResponseData(statusCode: 403, body: Data("{\"error\":\"go_entitlement_required\"}".utf8)) },
            disableStore: InMemoryProviderDisableStore(),
            authFileURL: authURL,
            clock: { Self.referenceNow },
            timeZone: utc
        ).fetchResult()
        XCTAssertNotEqual(forbidden.snapshot.connectionState, .expired)
        XCTAssertEqual(forbidden.snapshot.connectionState, .unsupported)
        XCTAssertEqual(forbidden.snapshot.menuBarEntryState, .omitted)
        XCTAssertTrue(forbidden.snapshot.connectedVia.localizedCaseInsensitiveContains("Go"))
        XCTAssertEqual(forbidden.diagnostic?.httpStatus, 403)
        XCTAssertEqual(forbidden.diagnostic?.isTransientError, false)

        // 3. Transient HTTP errors (429, 503) & transport errors (.timedOut, .networkUnavailable)
        for status in [429, 500, 503] {
            let transient = await OpenCodeUsageProvider(
                fileReader: StubLocalFileReader(files: [authURL.path: goAuthFixture]),
                httpTransport: StubHTTPTransport { _, _ in HTTPResponseData(statusCode: status, body: Data()) },
                disableStore: InMemoryProviderDisableStore(),
                authFileURL: authURL,
                clock: { Self.referenceNow },
                timeZone: utc
            ).fetchResult()
            XCTAssertEqual(transient.snapshot.connectionState, .unsupported)
            XCTAssertEqual(transient.diagnostic?.httpStatus, status)
            XCTAssertEqual(transient.diagnostic?.isTransientError, true)
        }

        for transportError in [LiveProviderTransportError.timedOut, .networkUnavailable] {
            let failed = await OpenCodeUsageProvider(
                fileReader: StubLocalFileReader(files: [authURL.path: goAuthFixture]),
                httpTransport: StubHTTPTransport { _, _ in throw transportError },
                disableStore: InMemoryProviderDisableStore(),
                authFileURL: authURL,
                clock: { Self.referenceNow },
                timeZone: utc
            ).fetchResult()
            XCTAssertEqual(failed.snapshot.connectionState, .unsupported)
            XCTAssertEqual(failed.snapshot.connectedVia, transportError.shortReason)
            XCTAssertEqual(failed.diagnostic?.shortReason, transportError.shortReason)
            XCTAssertEqual(failed.diagnostic?.isTransientError, true)
        }

        // 4. Transient error in AccountsController preserves previously connected Go limits and applies backoff
        final class AtomicBoolBox: @unchecked Sendable {
            private let lock = NSLock()
            private var value: Bool
            init(_ initial: Bool) { self.value = initial }
            func get() -> Bool { lock.withLock { value } }
            func set(_ next: Bool) { lock.withLock { value = next } }
        }

        let clock = MutableClock(referenceNow)
        let shouldFail = AtomicBoolBox(false)
        let flakyProvider = OpenCodeUsageProvider(
            fileReader: StubLocalFileReader(files: [authURL.path: goAuthFixture]),
            httpTransport: StubHTTPTransport { _, _ in
                if shouldFail.get() {
                    return HTTPResponseData(statusCode: 503, body: Data())
                }
                return HTTPResponseData(statusCode: 200, body: successBody)
            },
            disableStore: InMemoryProviderDisableStore(),
            authFileURL: authURL,
            clock: { clock.now },
            timeZone: utc
        )
        let providers: [any UsageProvider] = [
            UnconfiguredUsageProvider(provider: .claude),
            UnconfiguredUsageProvider(provider: .chatgpt),
            UnconfiguredUsageProvider(provider: .cursor),
            UnconfiguredUsageProvider(provider: .gemini),
            flakyProvider
        ]
        let initial = ProviderID.allCases.map {
            ProviderSnapshot(provider: $0, plan: "", connectionState: .notConnected, limits: [], connectedVia: "Not connected")
        }
        let controller = AccountsController(
            isDemo: false,
            initialSnapshots: initial,
            providers: providers,
            clock: { clock.now }
        )

        await controller.refreshAll()
        XCTAssertEqual(controller.snapshot(for: .opencode).connectionState, .connected)
        XCTAssertEqual(controller.snapshot(for: .opencode).limits.count, 3)

        shouldFail.set(true)
        await controller.refreshAll()
        XCTAssertEqual(controller.snapshot(for: .opencode).connectionState, .connected)
        XCTAssertEqual(controller.snapshot(for: .opencode).limits.count, 3)
        XCTAssertEqual(controller.consecutiveFailureCount(for: .opencode), 1)
        XCTAssertEqual(controller.nextAllowedRefreshDate(for: .opencode), referenceNow.addingTimeInterval(60))
    }

    func testOpenCodeGoStrictMeterValidationPercentsTimestampsStatusAndMalformedPayloads() async throws {
        let goAuthFixture = try loadLiveFixture("opencode-auth-go.json")
        let authURL = URL(fileURLWithPath: "/virtual/.local/share/opencode/auth.json")

        func fetch(_ json: String) async -> ProviderFetchResult {
            await OpenCodeUsageProvider(
                fileReader: StubLocalFileReader(files: [authURL.path: goAuthFixture]),
                httpTransport: StubHTTPTransport { _, _ in HTTPResponseData(statusCode: 200, body: Data(json.utf8)) },
                disableStore: InMemoryProviderDisableStore(),
                authFileURL: authURL,
                clock: { Self.referenceNow },
                timeZone: utc
            ).fetchResult()
        }

        // 1. Boundary percents (0 and 100), past resetsAt ("Resetting"), and null resetsAt ("Reset time unavailable")
        let boundaries = await fetch("""
        {
          "usage": {
            "rolling": {"status": "ok", "percent": 0, "resetsAt": null},
            "weekly": {"status": "ok", "percent": 100, "resetsAt": "2026-11-26T18:00:00.000Z"},
            "monthly": {"status": "rate-limited", "percent": 100, "resetsAt": "2026-12-10T00:00:00Z"}
          }
        }
        """)
        XCTAssertEqual(boundaries.snapshot.connectionState, .connected)
        XCTAssertEqual(boundaries.snapshot.limits.map(\.percentUsed), [0, 100, 100])
        XCTAssertEqual(boundaries.snapshot.limits[0].resetText, "Reset time unavailable")
        XCTAssertEqual(boundaries.snapshot.limits[1].resetText, "Resetting")
        XCTAssertEqual(boundaries.snapshot.limits[2].resetText, "Rate limited · Resets Dec 10")
        XCTAssertEqual(boundaries.diagnostic?.warnings, [])

        // 2. Malformed root / missing usage / speculative legacy credit response -> .unsupported
        let malformedRoots = [
            "not json at all",
            "[]",
            "{}",
            #"{"usage":null}"#,
            #"{"usage":"bad"}"#,
            #"{"usage":{}}"#,
            #"{"plan":"Zen","used_usd":8.4,"limit_usd":20.0,"resets_at":"2026-12-01T00:00:00Z"}"#
        ]
        for body in malformedRoots {
            let res = await fetch(body)
            XCTAssertEqual(res.snapshot.connectionState, .unsupported, "Expected unsupported for: \(body)")
            XCTAssertTrue(res.snapshot.limits.isEmpty)
        }

        // 3. Invalid / bool / decimal / string / out-of-range percents -> rejected with warning
        let invalidPercents = [
            "true",
            "false",
            "-1",
            "101",
            "30.5",
            "\"30\"",
            "null",
            "1e20"
        ]
        for rawPercent in invalidPercents {
            let res = await fetch("""
            {"usage":{"rolling":{"status":"ok","percent":\(rawPercent),"resetsAt":"2026-11-26T21:00:00.000Z"}}}
            """)
            XCTAssertEqual(res.snapshot.connectionState, .unsupported, "Expected rejection for percent=\(rawPercent)")
            XCTAssertTrue(res.snapshot.limits.isEmpty)
            XCTAssertTrue(res.diagnostic?.warnings.contains("usage.rolling.percent: present but not parseable") == true)
        }

        // 4. Bad timestamps (non-ISO8601, empty, numeric epoch, missing timezone, invalid calendar date) -> rejected with warning
        let invalidTimestamps = [
            "\"not-a-timestamp\"",
            "\"\"",
            "1795734000",
            "true",
            "\"2026-11-26 21:00:00Z\"",
            "\"2026-11-26T21:00:00\"",
            "\"2026-02-30T00:00:00Z\""
        ]
        for rawTS in invalidTimestamps {
            let res = await fetch("""
            {"usage":{"weekly":{"status":"ok","percent":40,"resetsAt":\(rawTS)}}}
            """)
            XCTAssertEqual(res.snapshot.connectionState, .unsupported, "Expected rejection for resetsAt=\(rawTS)")
            XCTAssertTrue(res.snapshot.limits.isEmpty)
            XCTAssertTrue(res.diagnostic?.warnings.contains("usage.weekly.resetsAt: present but not parseable") == true)
        }

        // 5. Bad status values (unknown string, wrong case, non-string, null, missing) -> rejected with warning
        let invalidStatuses = [
            "\"unknown\"",
            "\"OK\"",
            "\"\"",
            "true",
            "200",
            "null"
        ]
        for rawStatus in invalidStatuses {
            let res = await fetch("""
            {"usage":{"monthly":{"status":\(rawStatus),"percent":50,"resetsAt":"2026-12-01T00:00:00.000Z"}}}
            """)
            XCTAssertEqual(res.snapshot.connectionState, .unsupported, "Expected rejection for status=\(rawStatus)")
            XCTAssertTrue(res.snapshot.limits.isEmpty)
            XCTAssertTrue(res.diagnostic?.warnings.contains("usage.monthly.status: present but not parseable") == true)
        }
        let missingStatus = await fetch("""
        {"usage":{"monthly":{"percent":50,"resetsAt":"2026-12-01T00:00:00.000Z"}}}
        """)
        XCTAssertEqual(missingStatus.snapshot.connectionState, .unsupported)
        XCTAssertTrue(missingStatus.diagnostic?.warnings.contains("usage.monthly.status: present but not parseable") == true)

        // 6. Partial corruption: one bad meter emits warning while remaining valid meters still publish
        let partial = await fetch("""
        {
          "usage": {
            "rolling": {"status": "ok", "percent": 25, "resetsAt": "2026-11-26T21:00:00.000Z"},
            "weekly": {"status": "ok", "percent": true, "resetsAt": "2026-11-30T00:00:00.000Z"},
            "monthly": {"status": "ok", "percent": 60, "resetsAt": "2026-12-01T00:00:00.000Z"}
          }
        }
        """)
        XCTAssertEqual(partial.snapshot.connectionState, .connected)
        XCTAssertEqual(partial.snapshot.limits.map(\.name), ["5-hour", "Monthly"])
        XCTAssertEqual(partial.snapshot.limits.map(\.percentUsed), [25, 60])
        XCTAssertEqual(partial.diagnostic?.warnings, ["usage.weekly.percent: present but not parseable"])
    }

    func testOpenCodeGoDiagnosticsAndShapeRedactionNeverLeakCredentials() async {
        let authURL = URL(fileURLWithPath: "/virtual/.local/share/opencode/auth.json")
        let syntheticGoKey = ["oc", "syntheticgokey987654321"].joined(separator: "_")
        let syntheticZenKey = ["oc", "syntheticzenkey123456789"].joined(separator: "_")
        let syntheticEmail = "go.user@example.com"
        let syntheticAccountID = "acct_9988776655"

        let authData = Data("""
        {
          "opencode-go": {"type": "api", "key": "\(syntheticGoKey)"},
          "opencode": {"type": "api", "key": "\(syntheticZenKey)"}
        }
        """.utf8)

        let leakySuccessBody = Data("""
        {
          "usage": {
            "rolling": {"status": "ok", "percent": 30, "resetsAt": "2026-11-26T21:00:00.000Z"},
            "weekly": {"status": "rate-limited", "percent": 100, "resetsAt": "2026-11-30T00:00:00.000Z"},
            "monthly": {"status": "ok", "percent": 50, "resetsAt": "2026-12-01T00:00:00.000Z"}
          },
          "account": {"email": "\(syntheticEmail)", "id": "\(syntheticAccountID)", "key": "\(syntheticGoKey)"}
        }
        """.utf8)
        let leakyErrorBody = Data("""
        {"error":"Bearer \(syntheticGoKey) denied for \(syntheticEmail) (\(syntheticAccountID))"}
        """.utf8)

        let cases: [(Int, Data)] = [
            (200, leakySuccessBody),
            (401, leakyErrorBody),
            (403, leakyErrorBody),
            (500, leakyErrorBody)
        ]

        for (status, body) in cases {
            let result = await OpenCodeUsageProvider(
                fileReader: StubLocalFileReader(files: [authURL.path: authData]),
                httpTransport: StubHTTPTransport { _, _ in HTTPResponseData(statusCode: status, body: body) },
                disableStore: InMemoryProviderDisableStore(),
                authFileURL: authURL,
                clock: { Self.referenceNow },
                timeZone: utc
            ).fetchResult(captureShape: true)

            let dumpReport = LimitsDumper.formatReport(results: [result], isDemo: false)
            let shapeReport = LimitsDumper.formatShapeReport(results: [result], isDemo: false)

            for output in [dumpReport, shapeReport] {
                XCTAssertFalse(output.contains(syntheticGoKey))
                XCTAssertFalse(output.contains(syntheticZenKey))
                XCTAssertFalse(output.contains(syntheticEmail))
                XCTAssertFalse(output.contains(syntheticAccountID))
            }

            if status == 200 {
                XCTAssertTrue(shapeReport.contains("usage.rolling.status: string = ok"))
                XCTAssertTrue(shapeReport.contains("usage.rolling.percent: number = 30"))
                XCTAssertTrue(shapeReport.contains("usage.rolling.resetsAt: string = 2026-11-26T21:00:00.000Z"))
                XCTAssertTrue(shapeReport.contains("usage.weekly.status: string = rate-limited"))
                XCTAssertTrue(shapeReport.contains("usage.weekly.percent: number = 100"))
                XCTAssertTrue(shapeReport.contains("usage.monthly.percent: number = 50"))
                XCTAssertFalse(shapeReport.contains("account.email"))
            }
        }
    }

    func testOpenCodeDefaultAuthFileURLHonorsXDGDataHome() {
        let home = "/Users/fixture"

        // Unset XDG_DATA_HOME -> ~/.local/share/opencode/auth.json
        XCTAssertEqual(
            OpenCodeUsageProvider.defaultAuthFileURL(environment: [:], homeDirectory: home).path,
            "/Users/fixture/.local/share/opencode/auth.json"
        )

        // Absolute XDG_DATA_HOME -> $XDG_DATA_HOME/opencode/auth.json
        XCTAssertEqual(
            OpenCodeUsageProvider.defaultAuthFileURL(environment: ["XDG_DATA_HOME": "/custom/xdg/data"], homeDirectory: home).path,
            "/custom/xdg/data/opencode/auth.json"
        )

        // Trailing slash and surrounding whitespace handled cleanly
        XCTAssertEqual(
            OpenCodeUsageProvider.defaultAuthFileURL(environment: ["XDG_DATA_HOME": "  /custom/xdg/data/  "], homeDirectory: home).path,
            "/custom/xdg/data/opencode/auth.json"
        )

        // Empty, whitespace-only, or relative XDG_DATA_HOME -> falls back to ~/.local/share/opencode/auth.json
        for invalid in ["", "   ", "relative/data"] {
            XCTAssertEqual(
                OpenCodeUsageProvider.defaultAuthFileURL(environment: ["XDG_DATA_HOME": invalid], homeDirectory: home).path,
                "/Users/fixture/.local/share/opencode/auth.json",
                "Expected fallback for XDG_DATA_HOME=\(invalid)"
            )
        }
    }

    // MARK: - SQLite Helper

    private func createCursorStateDB(at url: URL, entries: [String: String]) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT);", nil, nil, nil), SQLITE_OK)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (key, value) in entries {
            var stmt: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO ItemTable (key, value) VALUES (?, ?);", -1, &stmt, nil), SQLITE_OK)
            defer { sqlite3_finalize(stmt) }
            key.withCString { sqlite3_bind_text(stmt, 1, $0, -1, transient) }
            value.withCString { sqlite3_bind_text(stmt, 2, $0, -1, transient) }
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
        }
    }
}
