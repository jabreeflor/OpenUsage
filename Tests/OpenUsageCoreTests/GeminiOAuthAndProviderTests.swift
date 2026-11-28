import Darwin
import Foundation
import XCTest
@testable import OpenUsageCore

// MARK: - Isolated Test Doubles

private final class GeminiTestHTTPTransport: HTTPTransport, @unchecked Sendable {
    struct RecordedRequest: Sendable {
        let url: URL?
        let method: String
        let headers: [String: String]
        let bodyString: String
        let timeout: TimeInterval
    }

    typealias Handler = @Sendable (URLRequest, TimeInterval) async throws -> HTTPResponseData

    private let lock = NSLock()
    private let handler: Handler
    private var _requests: [RecordedRequest] = []

    var requests: [RecordedRequest] {
        lock.withLock { _requests }
    }

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func send(_ request: URLRequest, timeout: TimeInterval) async throws -> HTTPResponseData {
        let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let recorded = RecordedRequest(
            url: request.url,
            method: request.httpMethod ?? "GET",
            headers: request.allHTTPHeaderFields ?? [:],
            bodyString: body,
            timeout: timeout
        )
        lock.withLock { _requests.append(recorded) }
        return try await handler(request, timeout)
    }
}

private final class InMemoryGeminiKeychain: KeychainStoring, @unchecked Sendable {
    private struct Key: Hashable {
        let service: String
        let account: String?
    }

    private let lock = NSLock()
    private var storage: [Key: Data] = [:]
    private var readError: Error?
    private var writeError: Error?
    private var deleteError: Error?
    private var onDelete: (@Sendable () -> Void)?
    private var _writeCount = 0
    private var _deleteCount = 0

    var writeCount: Int { lock.withLock { _writeCount } }
    var deleteCount: Int { lock.withLock { _deleteCount } }

    init(
        initial: [(service: String, account: String?, data: Data)] = [],
        readError: Error? = nil,
        writeError: Error? = nil,
        deleteError: Error? = nil,
        onDelete: (@Sendable () -> Void)? = nil
    ) {
        for item in initial {
            storage[Key(service: item.service, account: item.account)] = item.data
        }
        self.readError = readError
        self.writeError = writeError
        self.deleteError = deleteError
        self.onDelete = onDelete
    }

    func setOnDelete(_ handler: (@Sendable () -> Void)?) {
        lock.withLock { onDelete = handler }
    }

    func setWriteError(_ error: Error?) {
        lock.withLock { writeError = error }
    }

    func setDeleteError(_ error: Error?) {
        lock.withLock { deleteError = error }
    }

    func readGenericPassword(service: String, account: String?) throws -> Data? {
        try lock.withLock {
            if let readError { throw readError }
            if let exact = storage[Key(service: service, account: account)] {
                return exact
            }
            if account == nil {
                return storage.first(where: { $0.key.service == service })?.value
            }
            return nil
        }
    }

    func writeGenericPassword(_ data: Data, service: String, account: String) throws {
        try lock.withLock {
            if let writeError { throw writeError }
            _writeCount += 1
            storage[Key(service: service, account: account)] = data
        }
    }

    func deleteGenericPassword(service: String, account: String) throws {
        let hook: (@Sendable () -> Void)? = try lock.withLock {
            _deleteCount += 1
            if let deleteError { throw deleteError }
            storage.removeValue(forKey: Key(service: service, account: account))
            return onDelete
        }
        hook?()
    }

    func storedData(service: String, account: String) -> Data? {
        lock.withLock { storage[Key(service: service, account: account)] }
    }
}

private final class ReadOnlyGeminiKeychain: KeychainReading, @unchecked Sendable {
    private let existingData: Data?

    init(existingData: Data? = nil) {
        self.existingData = existingData
    }

    func readGenericPassword(service: String, account: String?) throws -> Data? {
        existingData
    }
}

private final class GeminiTestFileReader: LocalFileReader, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data]
    private var _readPaths: [String] = []

    var readPaths: [String] { lock.withLock { _readPaths } }

    init(files: [String: Data] = [:]) {
        self.files = files
    }

    func readFile(at url: URL) throws -> Data? {
        lock.withLock {
            _readPaths.append(url.path)
            return files[url.path]
        }
    }

    func discoverFiles(under root: URL, matching predicate: @Sendable (URL) -> Bool) -> [DiscoveredLocalFile] {
        []
    }

    func readSQLiteItems(at dbURL: URL, keys: [String]) throws -> [String: String]? {
        nil
    }
}

private final class InterceptingURLOpener: URLOpening, @unchecked Sendable {
    private let lock = NSLock()
    private let result: Bool
    private let onOpen: (@Sendable (URL) -> Void)?
    private var _openedURLs: [URL] = []

    var openedURLs: [URL] { lock.withLock { _openedURLs } }

    init(result: Bool = true, onOpen: (@Sendable (URL) -> Void)? = nil) {
        self.result = result
        self.onOpen = onOpen
    }

    @discardableResult
    func open(_ url: URL) -> Bool {
        lock.withLock { _openedURLs.append(url) }
        onOpen?(url)
        return result
    }
}

private final class FakeOAuthCallbackListener: GeminiOAuthCallbackListening, @unchecked Sendable {
    let redirectURI: URL
    private let lock = NSLock()
    private var _stopped = false
    private var _expectedState: String?
    private let behavior: @Sendable (String, TimeInterval) async throws -> String

    var stopped: Bool { lock.withLock { _stopped } }
    var expectedState: String? { lock.withLock { _expectedState } }

    init(
        redirectURI: URL = URL(string: "http://127.0.0.1:43210/oauth2callback")!,
        behavior: @escaping @Sendable (String, TimeInterval) async throws -> String
    ) {
        self.redirectURI = redirectURI
        self.behavior = behavior
    }

    func waitForAuthorizationCode(expectedState: String, timeout: TimeInterval) async throws -> String {
        lock.withLock { _expectedState = expectedState }
        return try await behavior(expectedState, timeout)
    }

    func stop() {
        lock.withLock { _stopped = true }
    }
}

private struct FakeOAuthSessionStarter: GeminiOAuthSessionStarting, Sendable {
    let factory: @Sendable () throws -> any GeminiOAuthCallbackListening

    func startLoopbackListener() throws -> any GeminiOAuthCallbackListening {
        try factory()
    }
}

private final class TestMutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date

    init(_ date: Date) {
        self._now = date
    }

    var now: Date { lock.withLock { _now } }

    func advance(by seconds: TimeInterval) {
        lock.withLock { _now = _now.addingTimeInterval(seconds) }
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Error>] = []

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { cont in
            entryWaiters.append(cont)
        }
    }

    func enterAndWait() async throws {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters { waiter.resume() }

        if isOpen { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                if isOpen {
                    cont.resume()
                } else {
                    openWaiters.append(cont)
                }
            }
        } onCancel: {
            Task { await self.cancelAll() }
        }
    }

    func open() {
        isOpen = true
        let waiters = openWaiters
        openWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func cancelAll() {
        let waiters = openWaiters
        openWaiters.removeAll()
        for waiter in waiters { waiter.resume(throwing: CancellationError()) }
    }
}

// MARK: - Helpers

private func sendRawLoopbackHTTP(
    port: UInt16,
    chunks: [String],
    interChunkDelayMs: UInt64 = 0
) async throws -> String {
    try await Task.detached(priority: .userInitiated) {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(.EIO)
        }
        defer { _ = Darwin.close(fd) }

        var timeout = timeval(tv_sec: 4, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)

        let connectRC = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddrPtr in
                Darwin.connect(fd, sockAddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectRC == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED)
        }

        for (index, chunk) in chunks.enumerated() {
            if interChunkDelayMs > 0 && index > 0 {
                try await Task.sleep(for: .milliseconds(interChunkDelayMs))
            }
            let payload = Data(chunk.utf8)
            payload.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var sent = 0
                while sent < raw.count {
                    let n = Darwin.send(fd, base.advanced(by: sent), raw.count - sent, 0)
                    if n <= 0 { break }
                    sent += n
                }
            }
        }

        var response = Data()
        var buf = [UInt8](repeating: 0, count: 2048)
        while true {
            let n = Darwin.recv(fd, &buf, buf.count, 0)
            if n > 0 {
                response.append(buf, count: n)
            } else {
                break
            }
        }
        return String(data: response, encoding: .utf8) ?? ""
    }.value
}

private func sendRawLoopbackHTTP(port: UInt16, rawRequest: String) async throws -> String {
    try await sendRawLoopbackHTTP(port: port, chunks: [rawRequest], interChunkDelayMs: 0)
}

private func loadGeminiLiveFixture(_ filename: String) throws -> Data {
    let bundle = Bundle(for: GeminiOAuthAndProviderTests.self)
    if let url = bundle.url(forResource: filename, withExtension: nil, subdirectory: "Fixtures/live-providers") {
        return try Data(contentsOf: url)
    }
    let fallback = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/live-providers/\(filename)")
    return try Data(contentsOf: fallback)
}

// MARK: - Tests

final class GeminiOAuthAndProviderTests: XCTestCase {
    private static let referenceNow = LogTimestampParser.parseISO8601("2026-11-28T09:00:00Z")!
    private static let utc = TimeZone(secondsFromGMT: 0)!
    private static let testConfig = GeminiOAuthConfiguration(
        clientID: "fixture-client-id.apps.googleusercontent.com",
        clientSecret: "fixture-synthetic-client-secret-0001"
    )

    private static let loadCodeAssistFixture = Data("""
    {
      "cloudaicompanionProject": "fixture-gca-project-1",
      "currentTier": { "id": "standard-tier", "name": "Google AI Pro" }
    }
    """.utf8)

    private static let quotaSuccessFixture = Data("""
    {
      "buckets": [
        { "remainingFraction": 0.90, "resetTime": "2026-11-29T05:00:00Z", "modelId": "gemini-2.5-flash", "tokenType": "REQUESTS" },
        { "remainingFraction": 0.65, "resetTime": "2026-11-29T05:00:00Z", "modelId": "gemini-2.5-pro", "tokenType": "REQUESTS" }
      ]
    }
    """.utf8)

    // MARK: - PKCE, State, and Config Discovery

    func testPKCEChallengeMatchesRFC7636VectorAndStateConstantTimeComparison() {
        let rfcVerifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let expectedChallenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        XCTAssertEqual(GeminiPKCE.challenge(forVerifier: rfcVerifier), expectedChallenge)

        let pair1 = GeminiPKCE.generatePair()
        let pair2 = GeminiPKCE.generatePair()
        XCTAssertEqual(pair1.method, "S256")
        XCTAssertGreaterThanOrEqual(pair1.verifier.count, 43)
        XCTAssertLessThanOrEqual(pair1.verifier.count, 128)
        XCTAssertEqual(pair1.challenge, GeminiPKCE.challenge(forVerifier: pair1.verifier))
        XCTAssertNotEqual(pair1.verifier, pair2.verifier)

        let state1 = GeminiPKCE.generateState()
        let state2 = GeminiPKCE.generateState()
        XCTAssertEqual(state1.count, 64)
        XCTAssertNotEqual(state1, state2)
        XCTAssertTrue(GeminiPKCE.constantTimeEqual(state1, state1))
        XCTAssertFalse(GeminiPKCE.constantTimeEqual(state1, state2))
        XCTAssertFalse(GeminiPKCE.constantTimeEqual(state1, state1 + "0"))
        XCTAssertFalse(GeminiPKCE.constantTimeEqual("", ""))
    }

    func testGeminiCLIOAuthConfigLoaderParsesOfficialFormatAndHandlesMissingOrMalformed() {
        let sampleJS = """
        const OAUTH_CLIENT_ID = '123456-sample.apps.googleusercontent.com';
        const OAUTH_CLIENT_SECRET = 'fixture-secret-value-abc123';
        const OAUTH_SCOPE = [
            'https://www.googleapis.com/auth/cloud-platform',
            'https://www.googleapis.com/auth/userinfo.email',
            'https://www.googleapis.com/auth/userinfo.profile',
        ];
        """
        let virtualURL = URL(fileURLWithPath: "/virtual/gemini-cli/oauth2.js")
        let reader = GeminiTestFileReader(files: [virtualURL.path: Data(sampleJS.utf8)])
        let loader = GeminiCLIOAuthConfigLoader(fileReader: reader, candidateFileURLs: [virtualURL])

        let loaded = loader.loadConfiguration()
        XCTAssertEqual(loaded?.clientID, "123456-sample.apps.googleusercontent.com")
        XCTAssertEqual(loaded?.clientSecret, "fixture-secret-value-abc123")
        XCTAssertEqual(loaded?.scopes, GeminiOAuthConfiguration.defaultScopes)
        XCTAssertFalse(String(describing: loaded).contains("fixture-secret-value-abc123"))

        let emptyLoader = GeminiCLIOAuthConfigLoader(
            fileReader: GeminiTestFileReader(),
            candidateFileURLs: [virtualURL]
        )
        XCTAssertNil(emptyLoader.loadConfiguration())

        let malformedURL = URL(fileURLWithPath: "/virtual/gemini-cli/malformed.js")
        let malformedLoader = GeminiCLIOAuthConfigLoader(
            fileReader: GeminiTestFileReader(files: [malformedURL.path: Data("const OAUTH_CLIENT_ID = 'only-id';".utf8)]),
            candidateFileURLs: [malformedURL]
        )
        XCTAssertNil(malformedLoader.loadConfiguration())
    }

    // MARK: - Defect 1, 2, 3: Loopback Callback Server State Validation, Honest Copy, Fragmented/Delayed Headers

    func testLoopbackServerIgnoresWrongStateErrorAndCodeThenAcceptsLegitimateCallbackWithHonestCopy() async throws {
        let server = try LoopbackOAuthCallbackServer()
        defer { server.stop() }

        XCTAssertEqual(server.redirectURI.scheme, "http")
        XCTAssertEqual(server.redirectURI.host, "127.0.0.1")
        XCTAssertEqual(server.redirectURI.path, "/oauth2callback")

        let expectedState = GeminiPKCE.generateState()
        let waitTask = Task {
            try await server.waitForAuthorizationCode(expectedState: expectedState, timeout: 5.0)
        }
        try await Task.sleep(for: .milliseconds(30))

        // 1. Stray favicon returns 404 and keeps session alive
        let faviconResponse = try await sendRawLoopbackHTTP(
            port: server.port,
            rawRequest: "GET /favicon.ico HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        )
        XCTAssertTrue(faviconResponse.hasPrefix("HTTP/1.1 404"))

        // 2. Non-GET returns 405 and keeps session alive
        let postResponse = try await sendRawLoopbackHTTP(
            port: server.port,
            rawRequest: "POST /oauth2callback?code=ignored&state=\(expectedState) HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 0\r\n\r\n"
        )
        XCTAssertTrue(postResponse.hasPrefix("HTTP/1.1 405"))

        // 3. Defect 1: Spoofed OAuth error WITHOUT valid state is rejected (400) and does NOT abort the session!
        let spoofedErrorResp = try await sendRawLoopbackHTTP(
            port: server.port,
            rawRequest: "GET /oauth2callback?error=access_denied&state=wrong-state-1 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        )
        XCTAssertTrue(spoofedErrorResp.hasPrefix("HTTP/1.1 400"))

        // 4. Defect 1: Spoofed code with mismatched state is rejected (400) and does NOT abort the session!
        let spoofedCodeResp = try await sendRawLoopbackHTTP(
            port: server.port,
            rawRequest: "GET /oauth2callback?code=attacker-code&state=wrong-state-2 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        )
        XCTAssertTrue(spoofedCodeResp.hasPrefix("HTTP/1.1 400"))

        // 5. Legitimate callback with matching state succeeds and uses honest pre-exchange copy (Defect 2)
        let validResponse = try await sendRawLoopbackHTTP(
            port: server.port,
            rawRequest: "GET /oauth2callback?state=\(expectedState)&code=fixture-legit-code-888 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        )
        XCTAssertTrue(validResponse.hasPrefix("HTTP/1.1 200"))
        XCTAssertTrue(validResponse.contains("Authorization received"))
        XCTAssertTrue(validResponse.contains("Return to OpenUsage"))
        XCTAssertFalse(validResponse.contains("Signed in to OpenUsage"))
        XCTAssertFalse(validResponse.contains("fixture-legit-code-888"))

        let code = try await waitTask.value
        XCTAssertEqual(code, "fixture-legit-code-888")
    }

    func testLoopbackServerHandlesDelayedAndFragmentedHeadersAcrossTCPChunks() async throws {
        // Defect 3 regression: Darwin accept() inherits O_NONBLOCK. Split headers across delayed TCP segments.
        let server = try LoopbackOAuthCallbackServer()
        defer { server.stop() }

        let expectedState = GeminiPKCE.generateState()
        let waitTask = Task {
            try await server.waitForAuthorizationCode(expectedState: expectedState, timeout: 5.0)
        }
        try await Task.sleep(for: .milliseconds(30))

        // Send initial TCP connect + delayed/fragmented request line and headers
        let chunks = [
            "GET /oauth2",
            "callback?state=\(expectedState.prefix(20))",
            "\(expectedState.dropFirst(20))&code=fixture-fragmented-code",
            " HTTP/1.1\r\n",
            "Host: 127.0.0.1\r\nUser-Agent: TestBrowser/1.0\r\n",
            "\r\n"
        ]
        let response = try await sendRawLoopbackHTTP(
            port: server.port,
            chunks: chunks,
            interChunkDelayMs: 45
        )
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200"))
        XCTAssertTrue(response.contains("Authorization received"))

        let code = try await waitTask.value
        XCTAssertEqual(code, "fixture-fragmented-code")
    }

    func testLoopbackServerProcessesValidStateErrorAndMissingCodeAndBoundsTimeoutCancellation() async throws {
        // 1. Valid state + error=access_denied -> authorizationDenied
        do {
            let server = try LoopbackOAuthCallbackServer()
            defer { server.stop() }
            let state = GeminiPKCE.generateState()
            let task = Task { try await server.waitForAuthorizationCode(expectedState: state, timeout: 5.0) }
            try await Task.sleep(for: .milliseconds(25))

            let response = try await sendRawLoopbackHTTP(
                port: server.port,
                rawRequest: "GET /oauth2callback?state=\(state)&error=access_denied&error_description=User+denied HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
            )
            XCTAssertTrue(response.hasPrefix("HTTP/1.1 200"))
            XCTAssertFalse(response.contains("User denied"))

            do {
                _ = try await task.value
                XCTFail("Expected authorizationDenied error")
            } catch let error as GeminiOAuthError {
                XCTAssertEqual(error, .authorizationDenied)
            }
        }

        // 2. Valid state + missing code -> missingAuthorizationCode
        do {
            let server = try LoopbackOAuthCallbackServer()
            defer { server.stop() }
            let state = GeminiPKCE.generateState()
            let task = Task { try await server.waitForAuthorizationCode(expectedState: state, timeout: 5.0) }
            try await Task.sleep(for: .milliseconds(25))

            let response = try await sendRawLoopbackHTTP(
                port: server.port,
                rawRequest: "GET /oauth2callback?state=\(state) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
            )
            XCTAssertTrue(response.hasPrefix("HTTP/1.1 400"))

            do {
                _ = try await task.value
                XCTFail("Expected missingAuthorizationCode error")
            } catch let error as GeminiOAuthError {
                XCTAssertEqual(error, .missingAuthorizationCode)
            }
        }

        // 3. Timeout
        do {
            let server = try LoopbackOAuthCallbackServer()
            defer { server.stop() }
            do {
                _ = try await server.waitForAuthorizationCode(expectedState: "timeout-state", timeout: 0.12)
                XCTFail("Expected timedOut error")
            } catch let error as GeminiOAuthError {
                XCTAssertEqual(error, .timedOut)
            }
        }

        // 4. Task cancellation shuts down listener promptly
        do {
            let server = try LoopbackOAuthCallbackServer()
            let task = Task {
                try await server.waitForAuthorizationCode(expectedState: "cancel-state", timeout: 30.0)
            }
            try await Task.sleep(for: .milliseconds(30))
            task.cancel()
            do {
                _ = try await task.value
                XCTFail("Expected CancellationError")
            } catch is CancellationError {
                // Expected
            }
        }
    }

    // MARK: - Token Exchange, Refresh, and Error Paths

    func testTokenExchangeAndRefreshSendPKCEFormParametersAndHandleErrorsSafely() async throws {
        let secretValue = "fixture-super-secret-refresh-token-999"
        let transport = GeminiTestHTTPTransport { request, _ in
            let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if body.contains("grant_type=authorization_code") {
                return HTTPResponseData(
                    statusCode: 200,
                    body: Data("""
                    {"access_token":"fixture-access-exchanged","refresh_token":"\(secretValue)","expires_in":3600,"token_type":"Bearer","scope":"cloud-platform"}
                    """.utf8)
                )
            }
            if body.contains("grant_type=refresh_token") {
                return HTTPResponseData(
                    statusCode: 200,
                    body: Data("""
                    {"access_token":"fixture-access-refreshed","expires_in":1800,"token_type":"Bearer"}
                    """.utf8)
                )
            }
            return HTTPResponseData(statusCode: 400, body: Data("{\"error\":\"invalid_request\"}".utf8))
        }

        let redirectURI = URL(string: "http://127.0.0.1:54321/oauth2callback")!
        let exchanged = try await GeminiOAuthClient.exchangeAuthorizationCode(
            code: "code+with/special=chars",
            codeVerifier: "verifier-123",
            redirectURI: redirectURI,
            configuration: Self.testConfig,
            httpTransport: transport,
            timeout: 5.0,
            now: Self.referenceNow
        )

        XCTAssertEqual(exchanged.accessToken, "fixture-access-exchanged")
        XCTAssertEqual(exchanged.refreshToken, secretValue)
        XCTAssertEqual(exchanged.expiryDate, Self.referenceNow.addingTimeInterval(3600))
        let exchangeReq = transport.requests[0]
        XCTAssertEqual(exchangeReq.headers["Content-Type"], "application/x-www-form-urlencoded")
        XCTAssertTrue(exchangeReq.bodyString.contains("code=code%2Bwith%2Fspecial%3Dchars"))
        XCTAssertTrue(exchangeReq.bodyString.contains("code_verifier=verifier-123"))
        XCTAssertTrue(exchangeReq.bodyString.contains("grant_type=authorization_code"))
        XCTAssertTrue(exchangeReq.bodyString.contains("client_secret=fixture-synthetic-client-secret-0001"))

        let refreshed = try await GeminiOAuthClient.refreshAccessToken(
            refreshToken: secretValue,
            configuration: Self.testConfig,
            httpTransport: transport,
            timeout: 5.0,
            now: Self.referenceNow
        )
        XCTAssertEqual(refreshed.accessToken, "fixture-access-refreshed")
        XCTAssertEqual(refreshed.refreshToken, secretValue)

        let invalidGrantTransport = GeminiTestHTTPTransport { _, _ in
            HTTPResponseData(
                statusCode: 400,
                body: Data("{\"error\":\"invalid_grant\",\"error_description\":\"Token \(secretValue) expired\"}".utf8)
            )
        }
        do {
            _ = try await GeminiOAuthClient.refreshAccessToken(
                refreshToken: secretValue,
                configuration: Self.testConfig,
                httpTransport: invalidGrantTransport,
                timeout: 5.0,
                now: Self.referenceNow
            )
            XCTFail("Expected invalidGrant error")
        } catch let error as GeminiOAuthError {
            XCTAssertEqual(error, .invalidGrant)
            XCTAssertFalse(error.userMessage.contains(secretValue))
        }
    }

    // MARK: - Defect 4: Stalled Refresh -> Sign-Out Race, Sign-In Cancel -> No Write, Late Keychain Read, Sign-Out Deletion Error

    func testStalledBackgroundRefreshDoesNotResurrectKeychainOrCacheAfterSignOut() async throws {
        let pastMs = Int64(Self.referenceNow.addingTimeInterval(-600).timeIntervalSince1970 * 1000)
        let expiredKeychainData = Data("""
        {"access_token":"fixture-old-access","refresh_token":"fixture-old-refresh","expiry_date":\(pastMs)}
        """.utf8)
        let keychain = InMemoryGeminiKeychain(initial: [
            (GeminiUsageProvider.appKeychainService, GeminiUsageProvider.appKeychainAccount, expiredKeychainData)
        ])
        let disableStore = InMemoryProviderDisableStore()
        let refreshGate = AsyncGate()

        let transport = GeminiTestHTTPTransport { req, _ in
            let url = req.url?.absoluteString ?? ""
            if url.contains("oauth2.googleapis.com/token") {
                try await refreshGate.enterAndWait()
                return HTTPResponseData(
                    statusCode: 200,
                    body: Data("{\"access_token\":\"fixture-stale-refreshed\",\"refresh_token\":\"fixture-stale-refresh-2\",\"expires_in\":3600}".utf8)
                )
            }
            XCTFail("Stale refresh must not proceed to quota API after sign-out")
            return HTTPResponseData(statusCode: 500, body: Data())
        }

        let coordinator = GeminiCredentialCoordinator()
        let provider = GeminiUsageProvider(
            keychain: keychain,
            credentialCoordinator: coordinator,
            fileReader: GeminiTestFileReader(),
            httpTransport: transport,
            disableStore: disableStore,
            urlOpener: InterceptingURLOpener(),
            oauthCredsURL: URL(fileURLWithPath: "/virtual/.gemini/oauth_creds.json"),
            oauthConfigProvider: StaticGeminiOAuthConfigProvider(Self.testConfig),
            clock: { Self.referenceNow },
            timeZone: Self.utc
        )

        // Start a background fetch that stalls mid-refresh over HTTP.
        let fetchTask = Task { await provider.fetchResult() }
        await refreshGate.waitUntilEntered()

        // Sign out MUST complete immediately without blocking on the stalled refresh HTTP call.
        let signedOut = try await provider.signOut()
        XCTAssertEqual(signedOut.connectionState, .notConnected)
        XCTAssertTrue(disableStore.isDisabled(.gemini))
        XCTAssertEqual(keychain.deleteCount, 1)
        XCTAssertNil(keychain.storedData(service: GeminiUsageProvider.appKeychainService, account: GeminiUsageProvider.appKeychainAccount))

        // Release the stalled refresh HTTP response — it MUST discard its tokens without recreating Keychain or cache!
        await refreshGate.open()
        let staleResult = await fetchTask.value
        XCTAssertEqual(staleResult.snapshot.connectionState, .notConnected)
        XCTAssertEqual(keychain.writeCount, 0)
        XCTAssertNil(keychain.storedData(service: GeminiUsageProvider.appKeychainService, account: GeminiUsageProvider.appKeychainAccount))
    }

    func testCancelledSignInDuringTokenExchangeWritesNothingToKeychain() async throws {
        let keychain = InMemoryGeminiKeychain()
        let disableStore = InMemoryProviderDisableStore()
        let exchangeGate = AsyncGate()

        let transport = GeminiTestHTTPTransport { req, _ in
            let url = req.url?.absoluteString ?? ""
            if url.contains("oauth2.googleapis.com/token") {
                try await exchangeGate.enterAndWait()
                return HTTPResponseData(
                    statusCode: 200,
                    body: Data("{\"access_token\":\"fixture-cancelled-access\",\"refresh_token\":\"fixture-cancelled-refresh\",\"expires_in\":3600}".utf8)
                )
            }
            return HTTPResponseData(statusCode: 200, body: Self.loadCodeAssistFixture)
        }

        let listener = FakeOAuthCallbackListener { _, _ in "fixture-code-for-cancel" }
        let provider = GeminiUsageProvider(
            keychain: keychain,
            fileReader: GeminiTestFileReader(),
            httpTransport: transport,
            disableStore: disableStore,
            urlOpener: InterceptingURLOpener(),
            oauthCredsURL: URL(fileURLWithPath: "/virtual/.gemini/oauth_creds.json"),
            oauthConfigProvider: StaticGeminiOAuthConfigProvider(Self.testConfig),
            oauthSessionStarter: FakeOAuthSessionStarter { listener },
            clock: { Self.referenceNow },
            timeZone: Self.utc
        )

        let signInTask = Task { try await provider.signIn() }
        await exchangeGate.waitUntilEntered()
        signInTask.cancel()
        await exchangeGate.open()

        do {
            _ = try await signInTask.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected
        }

        XCTAssertEqual(keychain.writeCount, 0)
        XCTAssertNil(keychain.storedData(service: GeminiUsageProvider.appKeychainService, account: GeminiUsageProvider.appKeychainAccount))
        XCTAssertTrue(listener.stopped)
    }

    func testKeychainCoordinatorInvalidatesLateInFlightReadAfterClearCachedResult() async throws {
        final class SlowKeychain: KeychainReading, @unchecked Sendable {
            private let started = DispatchSemaphore(value: 0)
            private let releaseGate = DispatchSemaphore(value: 0)
            private let lock = NSLock()
            private var callCount = 0

            func waitUntilStarted() { _ = started.wait(timeout: .now() + 2.0) }
            func release() { releaseGate.signal() }

            func readGenericPassword(service: String, account: String?) throws -> Data? {
                let index = lock.withLock { () -> Int in
                    callCount += 1
                    return callCount
                }
                if index == 1 {
                    started.signal()
                    _ = releaseGate.wait(timeout: .now() + 2.0)
                    return Data("stale-pre-signout-bytes".utf8)
                }
                return nil
            }
        }

        let slowKeychain = SlowKeychain()
        let coordinator = KeychainLookupCoordinator()

        // First read times out (.pending), leaving background read in-flight.
        let pending = try await coordinator.readGenericPassword(
            using: slowKeychain,
            service: GeminiUsageProvider.appKeychainService,
            account: GeminiUsageProvider.appKeychainAccount,
            timeout: 0.05
        )
        guard case .pending = pending else {
            return XCTFail("Expected pending outcome")
        }
        slowKeychain.waitUntilStarted()

        // Sign-out invalidates the key BEFORE the slow read finishes.
        await coordinator.clearCachedResult(
            forService: GeminiUsageProvider.appKeychainService,
            account: GeminiUsageProvider.appKeychainAccount
        )

        // Release the slow read; its late pre-signout bytes MUST be discarded, NOT cached!
        slowKeychain.release()
        try await Task.sleep(for: .milliseconds(60))

        let nextOutcome = try await coordinator.readGenericPassword(
            using: slowKeychain,
            service: GeminiUsageProvider.appKeychainService,
            account: GeminiUsageProvider.appKeychainAccount,
            timeout: 1.0
        )
        guard case .completed(.success(let data)) = nextOutcome else {
            return XCTFail("Expected fresh completed lookup")
        }
        XCTAssertNil(data, "Late pre-signout Keychain read must not repopulate unconsumed cache")
    }

    func testSignOutSurfacesKeychainDeleteFailureAndAllowsRetry() async throws {
        let futureMs = Int64(Self.referenceNow.addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        let keychainData = Data("{\"access_token\":\"fixture-kc-access\",\"expiry_date\":\(futureMs)}".utf8)
        let keychain = InMemoryGeminiKeychain(
            initial: [(GeminiUsageProvider.appKeychainService, GeminiUsageProvider.appKeychainAccount, keychainData)],
            deleteError: KeychainStoreError.osStatus(-25293)
        )
        let disableStore = InMemoryProviderDisableStore()

        let provider = GeminiUsageProvider(
            keychain: keychain,
            fileReader: GeminiTestFileReader(),
            httpTransport: GeminiTestHTTPTransport { _, _ in HTTPResponseData(statusCode: 500, body: Data()) },
            disableStore: disableStore,
            urlOpener: InterceptingURLOpener(),
            oauthCredsURL: URL(fileURLWithPath: "/virtual/.gemini/oauth_creds.json"),
            oauthConfigProvider: StaticGeminiOAuthConfigProvider(Self.testConfig),
            clock: { Self.referenceNow },
            timeZone: Self.utc
        )

        // 1. Failing Keychain delete surfaces failure with canSignOut=true and does NOT disable provider silently.
        let failedSignOut = try await provider.signOut()
        XCTAssertEqual(failedSignOut.connectionState, .unsupported)
        XCTAssertTrue(failedSignOut.canSignOut)
        XCTAssertTrue(failedSignOut.connectedVia.contains("Could not remove Gemini login from Keychain"))
        XCTAssertFalse(disableStore.isDisabled(.gemini))
        XCTAssertNotNil(keychain.storedData(service: GeminiUsageProvider.appKeychainService, account: GeminiUsageProvider.appKeychainAccount))

        // 2. Retry sign-out once Keychain succeeds -> removes credential and transitions to .notConnected.
        keychain.setDeleteError(nil)
        let retrySignOut = try await provider.signOut()
        XCTAssertEqual(retrySignOut.connectionState, .notConnected)
        XCTAssertFalse(retrySignOut.canSignOut)
        XCTAssertTrue(disableStore.isDisabled(.gemini))
        XCTAssertNil(keychain.storedData(service: GeminiUsageProvider.appKeychainService, account: GeminiUsageProvider.appKeychainAccount))
    }

    // MARK: - Defect 5 & 8: LoadCodeAssist Guard (403/503/Missing Project), No Quota Call, No Forced Consent Loop

    func testLoadCodeAssist403_503_MalformedAndMissingProjectNeverCallQuotaAndNeverForceConsentLoop() async throws {
        let futureMs = Int64(Self.referenceNow.addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        let keychainData = Data("{\"access_token\":\"fixture-valid-token\",\"expiry_date\":\(futureMs)}".utf8)
        let credsURL = URL(fileURLWithPath: "/virtual/.gemini/oauth_creds.json")

        // 1. loadCodeAssist 403 -> permission error (NOT .expired), ZERO retrieveUserQuota calls, canSignOut=true, signIn retries without browser!
        do {
            let opener = InterceptingURLOpener()
            let transport = GeminiTestHTTPTransport { req, _ in
                XCTAssertTrue(req.url?.absoluteString.contains("loadCodeAssist") == true, "Must not call retrieveUserQuota after loadCodeAssist 403")
                return HTTPResponseData(statusCode: 403, body: Data("{\"error\":{\"status\":\"PERMISSION_DENIED\"}}".utf8))
            }
            let provider = GeminiUsageProvider(
                keychain: InMemoryGeminiKeychain(initial: [(GeminiUsageProvider.appKeychainService, GeminiUsageProvider.appKeychainAccount, keychainData)]),
                fileReader: GeminiTestFileReader(),
                httpTransport: transport,
                disableStore: InMemoryProviderDisableStore(),
                urlOpener: opener,
                oauthCredsURL: credsURL,
                oauthConfigProvider: StaticGeminiOAuthConfigProvider(Self.testConfig),
                clock: { Self.referenceNow },
                timeZone: Self.utc
            )

            let fetched = await provider.fetchResult()
            XCTAssertEqual(fetched.snapshot.connectionState, .unsupported)
            XCTAssertTrue(fetched.snapshot.canSignOut)
            XCTAssertEqual(fetched.diagnostic?.httpStatus, 403)
            XCTAssertEqual(fetched.diagnostic?.isTransientError, false)
            XCTAssertTrue(fetched.snapshot.connectedVia.contains("permission"))
            XCTAssertEqual(transport.requests.count, 1)

            // Defect 8: Clicking Retry / signIn retries quota/loadCodeAssist with existing valid Keychain login and NEVER opens browser consent!
            let retried = try await provider.signIn()
            XCTAssertEqual(retried.connectionState, .unsupported)
            XCTAssertTrue(retried.canSignOut)
            XCTAssertTrue(opener.openedURLs.isEmpty)
            XCTAssertEqual(transport.requests.count, 2)
        }

        // 2. loadCodeAssist 503 -> preserves transient 503 failure, ZERO retrieveUserQuota calls (never misreports "Run Gemini CLI once")
        do {
            let transport = GeminiTestHTTPTransport { req, _ in
                XCTAssertTrue(req.url?.absoluteString.contains("loadCodeAssist") == true, "Must not call retrieveUserQuota after loadCodeAssist 503")
                return HTTPResponseData(statusCode: 503, body: Data("service unavailable".utf8))
            }
            let provider = GeminiUsageProvider(
                fileReader: GeminiTestFileReader(files: [credsURL.path: keychainData]),
                httpTransport: transport,
                disableStore: InMemoryProviderDisableStore(),
                oauthCredsURL: credsURL,
                clock: { Self.referenceNow },
                timeZone: Self.utc
            )
            let fetched = await provider.fetchResult()
            XCTAssertEqual(fetched.snapshot.connectionState, .unsupported)
            XCTAssertEqual(fetched.diagnostic?.httpStatus, 503)
            XCTAssertEqual(fetched.diagnostic?.isTransientError, true)
            XCTAssertTrue(fetched.snapshot.connectedVia.contains("503"))
            XCTAssertFalse(fetched.snapshot.connectedVia.contains("Run Gemini CLI once"))
            XCTAssertEqual(transport.requests.count, 1)
        }

        // 3. loadCodeAssist 200 missing cloudaicompanionProject -> stops BEFORE retrieveUserQuota with actionable setup message,
        //    canSignOut=true, and signIn() retries without looping through browser consent!
        do {
            let opener = InterceptingURLOpener()
            let transport = GeminiTestHTTPTransport { req, _ in
                XCTAssertTrue(req.url?.absoluteString.contains("loadCodeAssist") == true, "Must not call retrieveUserQuota when projectId is absent")
                return HTTPResponseData(statusCode: 200, body: Data("{\"allowedTiers\":[{\"id\":\"free-tier\"}]}".utf8))
            }
            let provider = GeminiUsageProvider(
                keychain: InMemoryGeminiKeychain(initial: [(GeminiUsageProvider.appKeychainService, GeminiUsageProvider.appKeychainAccount, keychainData)]),
                fileReader: GeminiTestFileReader(),
                httpTransport: transport,
                disableStore: InMemoryProviderDisableStore(),
                urlOpener: opener,
                oauthCredsURL: credsURL,
                oauthConfigProvider: StaticGeminiOAuthConfigProvider(Self.testConfig),
                clock: { Self.referenceNow },
                timeZone: Self.utc
            )

            let fetched = await provider.fetchResult()
            XCTAssertEqual(fetched.snapshot.connectionState, .unsupported)
            XCTAssertTrue(fetched.snapshot.canSignOut)
            XCTAssertEqual(fetched.snapshot.connectedVia, "Run Gemini CLI once to finish Code Assist setup")
            XCTAssertEqual(transport.requests.count, 1)

            // Retry via signIn does NOT open browser consent
            let retried = try await provider.signIn()
            XCTAssertEqual(retried.connectionState, .unsupported)
            XCTAssertTrue(retried.canSignOut)
            XCTAssertTrue(opener.openedURLs.isEmpty)
            XCTAssertEqual(transport.requests.count, 2)
        }

        // 4. loadCodeAssist 200 with VALIDATION_REQUIRED and no project -> actionable verify message, ZERO retrieveUserQuota calls
        do {
            let transport = GeminiTestHTTPTransport { req, _ in
                XCTAssertTrue(req.url?.absoluteString.contains("loadCodeAssist") == true)
                return HTTPResponseData(
                    statusCode: 200,
                    body: Data("{\"ineligibleTiers\":[{\"reasonCode\":\"VALIDATION_REQUIRED\",\"tierId\":\"free-tier\"}]}".utf8)
                )
            }
            let fetched = await GeminiUsageProvider(
                fileReader: GeminiTestFileReader(files: [credsURL.path: keychainData]),
                httpTransport: transport,
                disableStore: InMemoryProviderDisableStore(),
                oauthCredsURL: credsURL,
                clock: { Self.referenceNow },
                timeZone: Self.utc
            ).fetchResult()
            XCTAssertEqual(fetched.snapshot.connectionState, .unsupported)
            XCTAssertEqual(fetched.snapshot.connectedVia, "Verify your Google account in Gemini CLI")
            XCTAssertEqual(transport.requests.count, 1)
        }

        // 5. retrieveUserQuota 403 -> permission error (NOT .expired)
        do {
            let transport = GeminiTestHTTPTransport { req, _ in
                if req.url?.absoluteString.contains("loadCodeAssist") == true {
                    return HTTPResponseData(statusCode: 200, body: Self.loadCodeAssistFixture)
                }
                return HTTPResponseData(statusCode: 403, body: Data("{\"error\":{\"status\":\"PERMISSION_DENIED\"}}".utf8))
            }
            let fetched = await GeminiUsageProvider(
                fileReader: GeminiTestFileReader(files: [credsURL.path: keychainData]),
                httpTransport: transport,
                disableStore: InMemoryProviderDisableStore(),
                oauthCredsURL: credsURL,
                clock: { Self.referenceNow },
                timeZone: Self.utc
            ).fetchResult()
            XCTAssertEqual(fetched.snapshot.connectionState, .unsupported)
            XCTAssertTrue(fetched.snapshot.canSignOut)
            XCTAssertEqual(fetched.diagnostic?.httpStatus, 403)
            XCTAssertTrue(fetched.snapshot.connectedVia.contains("permission"))
        }
    }

    // MARK: - Defect 6: Optional tokenType Per-Model Quota Buckets Fixture

    func testQuotaParserAcceptsRecognizedModelBucketsWithoutTokenTypeAndStillRejectsTokensUnits() async throws {
        let modelBucketsFixture = try loadGeminiLiveFixture("gemini-quota-model-buckets.json")
        let futureMs = Int64(Self.referenceNow.addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        let credsData = Data("{\"access_token\":\"fixture-valid-token\",\"expiry_date\":\(futureMs)}".utf8)
        let credsURL = URL(fileURLWithPath: "/virtual/.gemini/oauth_creds.json")

        let transport = GeminiTestHTTPTransport { req, _ in
            if req.url?.absoluteString.contains("loadCodeAssist") == true {
                return HTTPResponseData(statusCode: 200, body: Self.loadCodeAssistFixture)
            }
            return HTTPResponseData(statusCode: 200, body: modelBucketsFixture)
        }

        let result = await GeminiUsageProvider(
            fileReader: GeminiTestFileReader(files: [credsURL.path: credsData]),
            httpTransport: transport,
            disableStore: InMemoryProviderDisableStore(),
            oauthCredsURL: credsURL,
            clock: { Self.referenceNow },
            timeZone: Self.utc
        ).fetchResult()

        // Fixture has TOKENS bucket at 0.10 (must be REJECTED), gemini-2.5-flash at 0.85, gemini-2.5-pro at 0.35 -> 65% used!
        XCTAssertEqual(result.snapshot.connectionState, .connected)
        XCTAssertEqual(result.snapshot.limits.count, 1)
        XCTAssertEqual(result.snapshot.limits.first?.percentUsed, 65)
        XCTAssertEqual(result.snapshot.limits.first?.name, "Daily requests · gemini-2.5-pro")
        XCTAssertEqual(result.snapshot.limits.first?.shortName, "Daily requests")

        // Unrecognized/arbitrary modelId with absent tokenType must still be rejected (no untrusted string echoing)
        let untrustedBody = Data("""
        {"buckets":[{"remainingFraction":0.25,"modelId":"secret-opaque-account-id"}]}
        """.utf8)
        let untrustedResult = await GeminiUsageProvider(
            fileReader: GeminiTestFileReader(files: [credsURL.path: credsData]),
            httpTransport: GeminiTestHTTPTransport { req, _ in
                if req.url?.absoluteString.contains("loadCodeAssist") == true {
                    return HTTPResponseData(statusCode: 200, body: Self.loadCodeAssistFixture)
                }
                return HTTPResponseData(statusCode: 200, body: untrustedBody)
            },
            disableStore: InMemoryProviderDisableStore(),
            oauthCredsURL: credsURL,
            clock: { Self.referenceNow },
            timeZone: Self.utc
        ).fetchResult()
        XCTAssertEqual(untrustedResult.snapshot.connectionState, .unsupported)
        XCTAssertTrue(untrustedResult.snapshot.limits.isEmpty)
    }

    // MARK: - Defect 7: Rotated CLI Refresh Token Across Multiple Refresh Cycles

    func testRotatedCLIRefreshTokenSurvivesTwoSuccessiveRefreshCyclesUnderStableCacheKey() async throws {
        let clock = TestMutableClock(Self.referenceNow)
        let pastMs = Int64(Self.referenceNow.addingTimeInterval(-600).timeIntervalSince1970 * 1000)
        // Unmodified CLI file stays fixed with R1 forever (read-only!)
        let cliFileData = Data("""
        {"access_token":"fixture-cli-a0-expired","refresh_token":"fixture-r1","expiry_date":\(pastMs)}
        """.utf8)
        let credsURL = URL(fileURLWithPath: "/virtual/.gemini/oauth_creds.json")
        let fileReader = GeminiTestFileReader(files: [credsURL.path: cliFileData])
        let keychain = InMemoryGeminiKeychain()

        let transport = GeminiTestHTTPTransport { req, _ in
            let url = req.url?.absoluteString ?? ""
            let body = req.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if url.contains("oauth2.googleapis.com/token") {
                if body.contains("refresh_token=fixture-r1") {
                    // Cycle 1: R1 -> (A1, rotated R2, expires in 3600s)
                    return HTTPResponseData(
                        statusCode: 200,
                        body: Data("{\"access_token\":\"fixture-a1\",\"refresh_token\":\"fixture-r2\",\"expires_in\":3600}".utf8)
                    )
                }
                if body.contains("refresh_token=fixture-r2") {
                    // Cycle 2: R2 -> (A2, rotated R3, expires in 3600s)
                    return HTTPResponseData(
                        statusCode: 200,
                        body: Data("{\"access_token\":\"fixture-a2\",\"refresh_token\":\"fixture-r3\",\"expires_in\":3600}".utf8)
                    )
                }
                XCTFail("Unexpected refresh token sent: \(body)")
                return HTTPResponseData(statusCode: 400, body: Data("{\"error\":\"invalid_grant\"}".utf8))
            }
            if url.contains("loadCodeAssist") {
                return HTTPResponseData(statusCode: 200, body: Self.loadCodeAssistFixture)
            }
            return HTTPResponseData(statusCode: 200, body: Self.quotaSuccessFixture)
        }

        let provider = GeminiUsageProvider(
            keychain: keychain,
            fileReader: fileReader,
            httpTransport: transport,
            disableStore: InMemoryProviderDisableStore(),
            urlOpener: InterceptingURLOpener(),
            oauthCredsURL: credsURL,
            oauthConfigProvider: StaticGeminiOAuthConfigProvider(Self.testConfig),
            clock: { clock.now },
            timeZone: Self.utc
        )

        // Cycle 1: CLI file A0 is expired -> refreshes using R1 -> gets A1 + R2
        let cycle1 = await provider.fetchResult()
        XCTAssertEqual(cycle1.snapshot.connectionState, .connected)
        XCTAssertEqual(transport.requests.last?.headers["Authorization"], "Bearer fixture-a1")

        // Advance clock past A1 expiry (3700s)
        clock.advance(by: 3700)

        // Cycle 2: A1 expired -> refreshes using rotated R2 -> gets A2 + R3 and updates stable cli:sha256(R1) cache entry!
        let cycle2 = await provider.fetchResult()
        XCTAssertEqual(cycle2.snapshot.connectionState, .connected)
        XCTAssertEqual(transport.requests.last?.headers["Authorization"], "Bearer fixture-a2")

        // Cycle 3 (5 minutes later, while A2 is still valid): MUST reuse cached A2 with ZERO new /token requests (never retries R1 or R2)!
        clock.advance(by: 300)
        let tokenRequestsBeforeCycle3 = transport.requests.filter { $0.url?.absoluteString.contains("/token") == true }.count
        XCTAssertEqual(tokenRequestsBeforeCycle3, 2)

        let cycle3 = await provider.fetchResult()
        XCTAssertEqual(cycle3.snapshot.connectionState, .connected)
        XCTAssertEqual(transport.requests.last?.headers["Authorization"], "Bearer fixture-a2")
        let tokenRequestsAfterCycle3 = transport.requests.filter { $0.url?.absoluteString.contains("/token") == true }.count
        XCTAssertEqual(tokenRequestsAfterCycle3, 2)

        // Never wrote to Keychain or modified CLI file
        XCTAssertEqual(keychain.writeCount, 0)
        XCTAssertEqual(try fileReader.readFile(at: credsURL), cliFileData)
    }

    // MARK: - Full Interactive Sign-In (Real Loopback + PKCE + Keychain + Quota)

    func testGeminiSignInCompletesRealLoopbackOAuthSavesToKeychainAndFetchesQuota() async throws {
        let keychain = InMemoryGeminiKeychain()
        let fileReader = GeminiTestFileReader()
        let disableStore = InMemoryProviderDisableStore()
        let credsURL = URL(fileURLWithPath: "/virtual/.gemini/oauth_creds.json")

        let transport = GeminiTestHTTPTransport { request, _ in
            let url = request.url?.absoluteString ?? ""
            if url.contains("oauth2.googleapis.com/token") {
                return HTTPResponseData(
                    statusCode: 200,
                    body: Data("""
                    {"access_token":"fixture-new-keychain-access","refresh_token":"fixture-new-refresh","expires_in":3600,"token_type":"Bearer"}
                    """.utf8)
                )
            }
            if url.contains("loadCodeAssist") {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-new-keychain-access")
                return HTTPResponseData(statusCode: 200, body: Self.loadCodeAssistFixture)
            }
            if url.contains("retrieveUserQuota") {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-new-keychain-access")
                return HTTPResponseData(statusCode: 200, body: Self.quotaSuccessFixture)
            }
            return HTTPResponseData(statusCode: 404, body: Data())
        }

        let opener = InterceptingURLOpener { authURL in
            guard let components = URLComponents(url: authURL, resolvingAgainstBaseURL: false),
                  let items = components.queryItems,
                  let redirectRaw = items.first(where: { $0.name == "redirect_uri" })?.value,
                  let redirectURL = URL(string: redirectRaw),
                  let port = redirectURL.port,
                  let state = items.first(where: { $0.name == "state" })?.value else {
                XCTFail("Authorization URL missing expected OAuth parameters")
                return
            }
            XCTAssertEqual(components.host, "accounts.google.com")
            XCTAssertEqual(items.first(where: { $0.name == "code_challenge_method" })?.value, "S256")
            XCTAssertNotNil(items.first(where: { $0.name == "code_challenge" })?.value)
            XCTAssertEqual(items.first(where: { $0.name == "access_type" })?.value, "offline")
            XCTAssertEqual(items.first(where: { $0.name == "prompt" })?.value, "consent")

            Task {
                try? await Task.sleep(for: .milliseconds(30))
                _ = try? await sendRawLoopbackHTTP(
                    port: UInt16(port),
                    rawRequest: "GET /oauth2callback?state=\(state)&code=fixture-browser-code HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
                )
            }
        }

        let provider = GeminiUsageProvider(
            keychain: keychain,
            fileReader: fileReader,
            httpTransport: transport,
            disableStore: disableStore,
            urlOpener: opener,
            oauthCredsURL: credsURL,
            oauthConfigProvider: StaticGeminiOAuthConfigProvider(Self.testConfig),
            oauthTimeout: 5.0,
            clock: { Self.referenceNow },
            timeZone: Self.utc
        )

        let before = await provider.fetchResult()
        XCTAssertEqual(before.snapshot.connectionState, .notConnected)
        XCTAssertTrue(opener.openedURLs.isEmpty)

        let signedIn = try await provider.signIn()
        XCTAssertEqual(signedIn.connectionState, .connected)
        XCTAssertEqual(signedIn.plan, "Google AI Pro")
        XCTAssertEqual(signedIn.connectedVia, GeminiUsageProvider.keychainConnectedSourceLabel)
        XCTAssertEqual(signedIn.limits.first?.percentUsed, 35)
        XCTAssertEqual(opener.openedURLs.count, 1)
        XCTAssertEqual(opener.openedURLs.first?.host, "accounts.google.com")

        XCTAssertEqual(keychain.writeCount, 1)
        let savedRaw = keychain.storedData(
            service: GeminiUsageProvider.appKeychainService,
            account: GeminiUsageProvider.appKeychainAccount
        )
        let savedCred = savedRaw.flatMap { GeminiOAuthCredential.decode(from: $0) }
        XCTAssertEqual(savedCred?.accessToken, "fixture-new-keychain-access")
        XCTAssertEqual(savedCred?.refreshToken, "fixture-new-refresh")
    }

    // MARK: - Sign-In Failure Paths

    func testGeminiSignInHandlesMissingConfigBrowserFailureAndKeychainErrors() async throws {
        let credsURL = URL(fileURLWithPath: "/virtual/.gemini/oauth_creds.json")
        let neverHTTP = GeminiTestHTTPTransport { _, _ in
            XCTFail("Should not make HTTP requests on early sign-in failure")
            return HTTPResponseData(statusCode: 500, body: Data())
        }

        let opener1 = InterceptingURLOpener()
        let missingConfigProvider = GeminiUsageProvider(
            keychain: InMemoryGeminiKeychain(),
            fileReader: GeminiTestFileReader(),
            httpTransport: neverHTTP,
            disableStore: InMemoryProviderDisableStore(),
            urlOpener: opener1,
            oauthCredsURL: credsURL,
            oauthConfigProvider: StaticGeminiOAuthConfigProvider(nil),
            clock: { Self.referenceNow },
            timeZone: Self.utc
        )
        let missingConfigSnap = try await missingConfigProvider.signIn()
        XCTAssertEqual(missingConfigSnap.connectionState, .notConnected)
        XCTAssertTrue(missingConfigSnap.connectedVia.contains("Install Gemini CLI"))
        XCTAssertTrue(opener1.openedURLs.isEmpty)

        let listener2 = FakeOAuthCallbackListener { _, _ in
            XCTFail("Should not wait for callback when browser fails to open")
            return "unused"
        }
        let browserFailProvider = GeminiUsageProvider(
            keychain: InMemoryGeminiKeychain(),
            fileReader: GeminiTestFileReader(),
            httpTransport: neverHTTP,
            disableStore: InMemoryProviderDisableStore(),
            urlOpener: InterceptingURLOpener(result: false),
            oauthCredsURL: credsURL,
            oauthConfigProvider: StaticGeminiOAuthConfigProvider(Self.testConfig),
            oauthSessionStarter: FakeOAuthSessionStarter { listener2 },
            clock: { Self.referenceNow },
            timeZone: Self.utc
        )
        let browserFailSnap = try await browserFailProvider.signIn()
        XCTAssertEqual(browserFailSnap.connectionState, .notConnected)
        XCTAssertTrue(browserFailSnap.connectedVia.contains("Could not open browser"))
        XCTAssertTrue(listener2.stopped)

        let readOnlyKeychainProvider = GeminiUsageProvider(
            keychain: ReadOnlyGeminiKeychain(),
            fileReader: GeminiTestFileReader(),
            httpTransport: neverHTTP,
            disableStore: InMemoryProviderDisableStore(),
            urlOpener: InterceptingURLOpener(),
            oauthCredsURL: credsURL,
            oauthConfigProvider: StaticGeminiOAuthConfigProvider(Self.testConfig),
            clock: { Self.referenceNow },
            timeZone: Self.utc
        )
        let roSnap = try await readOnlyKeychainProvider.signIn()
        XCTAssertEqual(roSnap.connectionState, .notConnected)
        XCTAssertTrue(roSnap.connectedVia.contains("Keychain storage unavailable"))

        let failingWriteKeychain = InMemoryGeminiKeychain(writeError: KeychainStoreError.osStatus(-25293))
        let listener4 = FakeOAuthCallbackListener { _, _ in "fixture-code-kc-fail" }
        let exchangeTransport = GeminiTestHTTPTransport { _, _ in
            HTTPResponseData(
                statusCode: 200,
                body: Data("{\"access_token\":\"secret-never-shown\",\"refresh_token\":\"secret-refresh-never-shown\",\"expires_in\":3600}".utf8)
            )
        }
        let kcFailProvider = GeminiUsageProvider(
            keychain: failingWriteKeychain,
            fileReader: GeminiTestFileReader(),
            httpTransport: exchangeTransport,
            disableStore: InMemoryProviderDisableStore(),
            urlOpener: InterceptingURLOpener(),
            oauthCredsURL: credsURL,
            oauthConfigProvider: StaticGeminiOAuthConfigProvider(Self.testConfig),
            oauthSessionStarter: FakeOAuthSessionStarter { listener4 },
            clock: { Self.referenceNow },
            timeZone: Self.utc
        )
        let kcFailSnap = try await kcFailProvider.signIn()
        XCTAssertEqual(kcFailSnap.connectionState, .notConnected)
        XCTAssertTrue(kcFailSnap.connectedVia.contains("Could not save Gemini login"))
        XCTAssertFalse(kcFailSnap.connectedVia.contains("secret-never-shown"))
        XCTAssertFalse(kcFailSnap.connectedVia.contains("secret-refresh-never-shown"))
    }

    // MARK: - Credential Precedence, Refresh, Sign-Out, and Default Registry Wiring

    func testCredentialPrecedencePrefersKeychainOverCLIAndSignOutNeverDeletesCLICredentials() async throws {
        let futureMs = Int64(Self.referenceNow.addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        let keychainData = Data("{\"access_token\":\"fixture-keychain-token\",\"expiry_date\":\(futureMs)}".utf8)
        let cliData = Data("{\"access_token\":\"fixture-cli-token\",\"expiry_date\":\(futureMs)}".utf8)
        let credsURL = URL(fileURLWithPath: "/virtual/.gemini/oauth_creds.json")

        let keychain = InMemoryGeminiKeychain(initial: [
            (GeminiUsageProvider.appKeychainService, GeminiUsageProvider.appKeychainAccount, keychainData)
        ])
        let fileReader = GeminiTestFileReader(files: [credsURL.path: cliData])
        let disableStore = InMemoryProviderDisableStore()
        let transport = GeminiTestHTTPTransport { req, _ in
            if req.url?.absoluteString.contains("loadCodeAssist") == true {
                return HTTPResponseData(statusCode: 200, body: Self.loadCodeAssistFixture)
            }
            return HTTPResponseData(statusCode: 200, body: Self.quotaSuccessFixture)
        }

        let provider = GeminiUsageProvider(
            keychain: keychain,
            fileReader: fileReader,
            httpTransport: transport,
            disableStore: disableStore,
            urlOpener: InterceptingURLOpener(),
            oauthCredsURL: credsURL,
            oauthConfigProvider: StaticGeminiOAuthConfigProvider(Self.testConfig),
            clock: { Self.referenceNow },
            timeZone: Self.utc
        )

        let first = await provider.fetchResult()
        XCTAssertEqual(first.snapshot.connectionState, .connected)
        XCTAssertEqual(first.snapshot.connectedVia, GeminiUsageProvider.keychainConnectedSourceLabel)
        XCTAssertEqual(transport.requests.first?.headers["Authorization"], "Bearer fixture-keychain-token")

        let signedOut = try await provider.signOut()
        XCTAssertEqual(signedOut.connectionState, .notConnected)
        XCTAssertTrue(disableStore.isDisabled(.gemini))
        XCTAssertEqual(keychain.deleteCount, 1)
        XCTAssertNil(keychain.storedData(service: GeminiUsageProvider.appKeychainService, account: GeminiUsageProvider.appKeychainAccount))
        XCTAssertEqual(try fileReader.readFile(at: credsURL), cliData)

        let reqsBefore = transport.requests.count
        let whileDisabled = await provider.fetchResult()
        XCTAssertEqual(whileDisabled.snapshot.connectionState, .notConnected)
        XCTAssertEqual(transport.requests.count, reqsBefore)

        let opener = InterceptingURLOpener()
        let reconnectedProvider = GeminiUsageProvider(
            keychain: keychain,
            fileReader: fileReader,
            httpTransport: transport,
            disableStore: disableStore,
            urlOpener: opener,
            oauthCredsURL: credsURL,
            oauthConfigProvider: StaticGeminiOAuthConfigProvider(Self.testConfig),
            clock: { Self.referenceNow },
            timeZone: Self.utc
        )
        let reconnected = try await reconnectedProvider.signIn()
        XCTAssertEqual(reconnected.connectionState, .connected)
        XCTAssertEqual(reconnected.connectedVia, GeminiUsageProvider.connectedSourceLabel)
        XCTAssertTrue(opener.openedURLs.isEmpty)
        XCTAssertEqual(transport.requests.last?.headers["Authorization"], "Bearer fixture-cli-token")
    }

    func testKeychain401TriggersSingleRefreshPersistsToKeychainAndRetriesQuota() async throws {
        let futureMs = Int64(Self.referenceNow.addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        let initialKeychainData = Data("""
        {"access_token":"fixture-revoked-access","refresh_token":"fixture-kc-refresh-002","expiry_date":\(futureMs)}
        """.utf8)
        let keychain = InMemoryGeminiKeychain(initial: [
            (GeminiUsageProvider.appKeychainService, GeminiUsageProvider.appKeychainAccount, initialKeychainData)
        ])

        let transport = GeminiTestHTTPTransport { req, _ in
            let url = req.url?.absoluteString ?? ""
            if url.contains("oauth2.googleapis.com/token") {
                return HTTPResponseData(
                    statusCode: 200,
                    body: Data("{\"access_token\":\"fixture-rotated-access\",\"expires_in\":3600,\"token_type\":\"Bearer\"}".utf8)
                )
            }
            if req.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-revoked-access" {
                return HTTPResponseData(statusCode: 401, body: Data("{\"error\":\"unauthorized\"}".utf8))
            }
            if url.contains("loadCodeAssist") {
                return HTTPResponseData(statusCode: 200, body: Self.loadCodeAssistFixture)
            }
            return HTTPResponseData(statusCode: 200, body: Self.quotaSuccessFixture)
        }

        let provider = GeminiUsageProvider(
            keychain: keychain,
            fileReader: GeminiTestFileReader(),
            httpTransport: transport,
            disableStore: InMemoryProviderDisableStore(),
            urlOpener: InterceptingURLOpener(),
            oauthCredsURL: URL(fileURLWithPath: "/virtual/.gemini/oauth_creds.json"),
            oauthConfigProvider: StaticGeminiOAuthConfigProvider(Self.testConfig),
            clock: { Self.referenceNow },
            timeZone: Self.utc
        )

        let result = await provider.fetchResult()
        XCTAssertEqual(result.snapshot.connectionState, .connected)
        XCTAssertEqual(result.snapshot.connectedVia, GeminiUsageProvider.keychainConnectedSourceLabel)
        XCTAssertEqual(keychain.writeCount, 1)
        let updated = keychain.storedData(
            service: GeminiUsageProvider.appKeychainService,
            account: GeminiUsageProvider.appKeychainAccount
        ).flatMap { GeminiOAuthCredential.decode(from: $0) }
        XCTAssertEqual(updated?.accessToken, "fixture-rotated-access")
        XCTAssertEqual(updated?.refreshToken, "fixture-kc-refresh-002")
    }

    func testDefaultLiveRegistryWiresGeminiToKeychainAndLiveQuotaEndpoint() async throws {
        let futureMs = Int64(Self.referenceNow.addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        let keychainData = Data("{\"access_token\":\"fixture-registry-kc-token\",\"expiry_date\":\(futureMs)}".utf8)
        let keychain = InMemoryGeminiKeychain(initial: [
            (GeminiUsageProvider.appKeychainService, GeminiUsageProvider.appKeychainAccount, keychainData)
        ])
        let transport = GeminiTestHTTPTransport { req, _ in
            let url = req.url?.absoluteString ?? ""
            if url == GeminiUsageProvider.defaultLoadCodeAssistEndpoint.absoluteString {
                return HTTPResponseData(statusCode: 200, body: Self.loadCodeAssistFixture)
            }
            if url == GeminiUsageProvider.defaultQuotaEndpoint.absoluteString {
                return HTTPResponseData(statusCode: 200, body: Self.quotaSuccessFixture)
            }
            return HTTPResponseData(statusCode: 404, body: Data())
        }

        let providers = UsageProviderRegistry.makeProviders(
            isDemo: false,
            httpTransport: transport,
            fileReader: GeminiTestFileReader(),
            keychain: keychain,
            disableStore: InMemoryProviderDisableStore(),
            urlOpener: InterceptingURLOpener(),
            clock: { Self.referenceNow },
            timeZone: Self.utc
        )

        guard let gemini = providers.first(where: { $0.provider == .gemini }) as? GeminiUsageProvider else {
            return XCTFail("Expected GeminiUsageProvider in live registry")
        }

        let result = await gemini.fetchResult()
        XCTAssertEqual(result.snapshot.connectionState, .connected)
        XCTAssertEqual(result.snapshot.plan, "Google AI Pro")
        XCTAssertEqual(result.snapshot.connectedVia, GeminiUsageProvider.keychainConnectedSourceLabel)
        XCTAssertEqual(result.snapshot.limits.first?.percentUsed, 35)
        XCTAssertEqual(
            transport.requests.compactMap { $0.url?.absoluteString },
            [
                GeminiUsageProvider.defaultLoadCodeAssistEndpoint.absoluteString,
                GeminiUsageProvider.defaultQuotaEndpoint.absoluteString
            ]
        )
    }

    // MARK: - Round 3 Regressions: Refresh Coalescing/CAS, Rotated Persist Failure, Atomic Sign-Out/Sign-In Ordering

    func testConcurrentRefreshesCoalesceIntoSingleTokenRequestAndShareChosenCredential() async throws {
        let pastMs = Int64(Self.referenceNow.addingTimeInterval(-600).timeIntervalSince1970 * 1000)
        let expiredKeychainData = Data("""
        {"access_token":"fixture-kc-a0","refresh_token":"fixture-kc-r1","expiry_date":\(pastMs)}
        """.utf8)
        let keychain = InMemoryGeminiKeychain(initial: [
            (GeminiUsageProvider.appKeychainService, GeminiUsageProvider.appKeychainAccount, expiredKeychainData)
        ])
        let refreshGate = AsyncGate()

        let transport = GeminiTestHTTPTransport { req, _ in
            let url = req.url?.absoluteString ?? ""
            if url.contains("oauth2.googleapis.com/token") {
                try await refreshGate.enterAndWait()
                return HTTPResponseData(
                    statusCode: 200,
                    body: Data("{\"access_token\":\"fixture-coalesced-a1\",\"refresh_token\":\"fixture-coalesced-r2\",\"expires_in\":3600}".utf8)
                )
            }
            if url.contains("loadCodeAssist") {
                XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-coalesced-a1")
                return HTTPResponseData(statusCode: 200, body: Self.loadCodeAssistFixture)
            }
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-coalesced-a1")
            return HTTPResponseData(statusCode: 200, body: Self.quotaSuccessFixture)
        }

        let provider = GeminiUsageProvider(
            keychain: keychain,
            fileReader: GeminiTestFileReader(),
            httpTransport: transport,
            disableStore: InMemoryProviderDisableStore(),
            urlOpener: InterceptingURLOpener(),
            oauthCredsURL: URL(fileURLWithPath: "/virtual/.gemini/oauth_creds.json"),
            oauthConfigProvider: StaticGeminiOAuthConfigProvider(Self.testConfig),
            clock: { Self.referenceNow },
            timeZone: Self.utc
        )

        let task1 = Task { await provider.fetchResult() }
        await refreshGate.waitUntilEntered()
        let task2 = Task { await provider.fetchResult() }
        try await Task.sleep(for: .milliseconds(30))
        await refreshGate.open()

        let (result1, result2) = await (task1.value, task2.value)
        XCTAssertEqual(result1.snapshot.connectionState, .connected)
        XCTAssertEqual(result2.snapshot.connectionState, .connected)

        // Single-flight coalescing: exactly ONE /token request and ONE Keychain write!
        let tokenRequests = transport.requests.filter { $0.url?.absoluteString.contains("/token") == true }
        XCTAssertEqual(tokenRequests.count, 1)
        XCTAssertEqual(keychain.writeCount, 1)
        let saved = keychain.storedData(
            service: GeminiUsageProvider.appKeychainService,
            account: GeminiUsageProvider.appKeychainAccount
        ).flatMap { GeminiOAuthCredential.decode(from: $0) }
        XCTAssertEqual(saved?.accessToken, "fixture-coalesced-a1")
        XCTAssertEqual(saved?.refreshToken, "fixture-coalesced-r2")
    }

    func testConcurrentCommitRefreshedCredentialCASUsesSameWinnerAcrossCacheKeychainAndReturnValue() async {
        let coordinator = GeminiCredentialCoordinator()
        let keychain = InMemoryGeminiKeychain()
        let kcCoordinator = KeychainLookupCoordinator()
        let disableStore = InMemoryProviderDisableStore()
        let stableKey = "keychain:\(GeminiUsageProvider.appKeychainService):\(GeminiUsageProvider.appKeychainAccount)"
        let gen = await coordinator.currentGeneration()

        let fresherWinner = GeminiOAuthCredential(
            accessToken: "fixture-winner-access",
            refreshToken: "fixture-winner-refresh",
            expiryDate: Self.referenceNow.addingTimeInterval(7200)
        )
        let slowerLoser = GeminiOAuthCredential(
            accessToken: "fixture-loser-access",
            refreshToken: "fixture-loser-refresh",
            expiryDate: Self.referenceNow.addingTimeInterval(1800)
        )

        // 1. Fresher credential commits first
        let outcome1 = await coordinator.commitRefreshedCredential(
            fresherWinner,
            expectedBaseVersion: 0,
            persistToKeychain: true,
            stableCacheKey: stableKey,
            expectedGeneration: gen,
            keychain: keychain,
            service: GeminiUsageProvider.appKeychainService,
            account: GeminiUsageProvider.appKeychainAccount,
            keychainCoordinator: kcCoordinator,
            disableStore: disableStore
        )
        XCTAssertEqual(outcome1, .committed(fresherWinner))
        XCTAssertEqual(keychain.writeCount, 1)

        // 2. Slower older credential commits with same baseVersion=0 -> MUST keep winner for cache, Keychain, AND return value!
        let outcome2 = await coordinator.commitRefreshedCredential(
            slowerLoser,
            expectedBaseVersion: 0,
            persistToKeychain: true,
            stableCacheKey: stableKey,
            expectedGeneration: gen,
            keychain: keychain,
            service: GeminiUsageProvider.appKeychainService,
            account: GeminiUsageProvider.appKeychainAccount,
            keychainCoordinator: kcCoordinator,
            disableStore: disableStore
        )
        XCTAssertEqual(outcome2, .committed(fresherWinner))
        XCTAssertEqual(keychain.writeCount, 1, "Losing refresh must never overwrite Keychain")
        let cached = await coordinator.cachedCredential(forKey: stableKey)
        XCTAssertEqual(cached, fresherWinner)
        let stored = keychain.storedData(
            service: GeminiUsageProvider.appKeychainService,
            account: GeminiUsageProvider.appKeychainAccount
        ).flatMap { GeminiOAuthCredential.decode(from: $0) }
        XCTAssertEqual(stored?.accessToken, "fixture-winner-access")
        XCTAssertEqual(stored?.refreshToken, "fixture-winner-refresh")
    }

    func testStaleInvalidGrantOr401CannotClearConcurrentlyRotatedCLICacheEntry() async {
        let coordinator = GeminiCredentialCoordinator()
        let kcCoordinator = KeychainLookupCoordinator()
        let disableStore = InMemoryProviderDisableStore()
        let stableKey = "cli:\(GeminiPKCE.sha256Hex("fixture-r1"))"
        let gen = await coordinator.currentGeneration()

        let rotatedCred = GeminiOAuthCredential(
            accessToken: "fixture-a2",
            refreshToken: "fixture-r2",
            expiryDate: Self.referenceNow.addingTimeInterval(3600)
        )
        let committed = await coordinator.commitRefreshedCredential(
            rotatedCred,
            expectedBaseVersion: 0,
            persistToKeychain: false,
            stableCacheKey: stableKey,
            expectedGeneration: gen,
            keychain: nil,
            service: GeminiUsageProvider.appKeychainService,
            account: GeminiUsageProvider.appKeychainAccount,
            keychainCoordinator: kcCoordinator,
            disableStore: disableStore
        )
        XCTAssertEqual(committed, .committed(rotatedCred))

        // Stale invalid_grant for old R1 must NOT clear rotated R2
        await coordinator.invalidateCachedCredentialIfMatching(
            forKey: stableKey,
            expectedGeneration: gen,
            matchingRefreshToken: "fixture-r1"
        )
        let afterStaleRefreshClear = await coordinator.cachedCredential(forKey: stableKey)
        XCTAssertEqual(afterStaleRefreshClear, rotatedCred)

        // Stale 401 for old A1 must NOT clear newer A2
        await coordinator.invalidateCachedCredentialIfMatching(
            forKey: stableKey,
            expectedGeneration: gen,
            matchingAccessToken: "fixture-a1"
        )
        let afterStaleAccessClear = await coordinator.cachedCredential(forKey: stableKey)
        XCTAssertEqual(afterStaleAccessClear, rotatedCred)

        // Matching R2 DOES clear it
        await coordinator.invalidateCachedCredentialIfMatching(
            forKey: stableKey,
            expectedGeneration: gen,
            matchingRefreshToken: "fixture-r2"
        )
        let afterMatchingClear = await coordinator.cachedCredential(forKey: stableKey)
        XCTAssertNil(afterMatchingClear)
    }

    func testKeychainWriteFailureOnRotatedRefreshSurfacesErrorAndFlushesOnRetry() async {
        let pastMs = Int64(Self.referenceNow.addingTimeInterval(-600).timeIntervalSince1970 * 1000)
        let expiredKeychainData = Data("""
        {"access_token":"fixture-kc-a0","refresh_token":"fixture-kc-r1","expiry_date":\(pastMs)}
        """.utf8)
        let keychain = InMemoryGeminiKeychain(
            initial: [(GeminiUsageProvider.appKeychainService, GeminiUsageProvider.appKeychainAccount, expiredKeychainData)],
            writeError: KeychainStoreError.osStatus(-25293)
        )

        let transport = GeminiTestHTTPTransport { req, _ in
            let url = req.url?.absoluteString ?? ""
            if url.contains("oauth2.googleapis.com/token") {
                return HTTPResponseData(
                    statusCode: 200,
                    body: Data("{\"access_token\":\"fixture-rotated-a1\",\"refresh_token\":\"fixture-rotated-r2\",\"expires_in\":3600}".utf8)
                )
            }
            if url.contains("loadCodeAssist") {
                XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-rotated-a1")
                return HTTPResponseData(statusCode: 200, body: Self.loadCodeAssistFixture)
            }
            return HTTPResponseData(statusCode: 200, body: Self.quotaSuccessFixture)
        }

        let provider = GeminiUsageProvider(
            keychain: keychain,
            fileReader: GeminiTestFileReader(),
            httpTransport: transport,
            disableStore: InMemoryProviderDisableStore(),
            urlOpener: InterceptingURLOpener(),
            oauthCredsURL: URL(fileURLWithPath: "/virtual/.gemini/oauth_creds.json"),
            oauthConfigProvider: StaticGeminiOAuthConfigProvider(Self.testConfig),
            clock: { Self.referenceNow },
            timeZone: Self.utc
        )

        // 1. Keychain write fails during rotated refresh -> MUST surface persistence error, NOT claim durable .connected!
        let failedPersist = await provider.fetchResult()
        XCTAssertEqual(failedPersist.snapshot.connectionState, .unsupported)
        XCTAssertTrue(failedPersist.snapshot.canSignOut)
        XCTAssertEqual(failedPersist.diagnostic?.isTransientError, true)
        XCTAssertTrue(failedPersist.snapshot.connectedVia.contains("Could not save refreshed Gemini login to Keychain"))
        XCTAssertEqual(transport.requests.count, 1, "Must not claim quota success when rotated refresh token failed to persist")

        // 2. Keychain unlocks -> retry flushes preserved rotated grant to Keychain without re-sending old R1!
        keychain.setWriteError(nil)
        let recovered = await provider.fetchResult()
        XCTAssertEqual(recovered.snapshot.connectionState, .connected)
        XCTAssertEqual(keychain.writeCount, 1)
        let tokenRequests = transport.requests.filter { $0.url?.absoluteString.contains("/token") == true }
        XCTAssertEqual(tokenRequests.count, 1, "Retry must flush preserved rotated token without repeating /token")
        let persisted = keychain.storedData(
            service: GeminiUsageProvider.appKeychainService,
            account: GeminiUsageProvider.appKeychainAccount
        ).flatMap { GeminiOAuthCredential.decode(from: $0) }
        XCTAssertEqual(persisted?.accessToken, "fixture-rotated-a1")
        XCTAssertEqual(persisted?.refreshToken, "fixture-rotated-r2")
    }

    func testRapidSignOutFollowedBySignInNeverAllowsOldSignOutToDisableNewerSignIn() async throws {
        let futureMs = Int64(Self.referenceNow.addingTimeInterval(3600).timeIntervalSince1970 * 1000)
        let cliData = Data("{\"access_token\":\"fixture-cli-reattach\",\"expiry_date\":\(futureMs)}".utf8)
        let keychainData = Data("{\"access_token\":\"fixture-kc-old\",\"expiry_date\":\(futureMs)}".utf8)
        let credsURL = URL(fileURLWithPath: "/virtual/.gemini/oauth_creds.json")

        let keychain = InMemoryGeminiKeychain(initial: [
            (GeminiUsageProvider.appKeychainService, GeminiUsageProvider.appKeychainAccount, keychainData)
        ])
        let disableStore = InMemoryProviderDisableStore()
        let transport = GeminiTestHTTPTransport { req, _ in
            if req.url?.absoluteString.contains("loadCodeAssist") == true {
                return HTTPResponseData(statusCode: 200, body: Self.loadCodeAssistFixture)
            }
            return HTTPResponseData(statusCode: 200, body: Self.quotaSuccessFixture)
        }

        let provider = GeminiUsageProvider(
            keychain: keychain,
            fileReader: GeminiTestFileReader(files: [credsURL.path: cliData]),
            httpTransport: transport,
            disableStore: disableStore,
            urlOpener: InterceptingURLOpener(),
            oauthCredsURL: credsURL,
            oauthConfigProvider: StaticGeminiOAuthConfigProvider(Self.testConfig),
            clock: { Self.referenceNow },
            timeZone: Self.utc
        )

        // Deterministically trigger signIn the exact instant signOut deletes Keychain (before signOut suspends
        // to invalidate KeychainLookupCoordinator). Because signOut completes generation bump + delete + disable
        // in one non-suspending actor turn and signIn enables in the same coordinator, signIn must always win!
        final class TaskBox: @unchecked Sendable {
            private let lock = NSLock()
            private var _task: Task<ProviderSnapshot, Error>?
            func set(_ task: Task<ProviderSnapshot, Error>) { lock.withLock { _task = task } }
            func get() -> Task<ProviderSnapshot, Error>? { lock.withLock { _task } }
        }
        let signInBox = TaskBox()
        keychain.setOnDelete {
            signInBox.set(Task { try await provider.signIn() })
        }

        let signOutSnap = try await provider.signOut()
        guard let signInTask = signInBox.get() else {
            return XCTFail("Expected signIn task to be spawned during signOut")
        }
        let signInSnap = try await signInTask.value

        XCTAssertEqual(signOutSnap.connectionState, .notConnected)
        XCTAssertEqual(signInSnap.connectionState, .connected)
        XCTAssertFalse(disableStore.isDisabled(.gemini), "Older signOut must never leave provider disabled after newer signIn")
        XCTAssertNil(keychain.storedData(service: GeminiUsageProvider.appKeychainService, account: GeminiUsageProvider.appKeychainAccount))
    }
}
