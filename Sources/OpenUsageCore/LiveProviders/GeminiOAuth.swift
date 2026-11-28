import CryptoKit
import Darwin
import Foundation
import Security

// MARK: - Configuration & Credentials

/// Public OAuth configuration used for Google Code Assist / Gemini CLI authentication.
public struct GeminiOAuthConfiguration: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let defaultAuthorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    public static let defaultTokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    public static let defaultScopes: [String] = [
        "https://www.googleapis.com/auth/cloud-platform",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile"
    ]

    public let clientID: String
    public let clientSecret: String?
    public let scopes: [String]
    public let authorizationEndpoint: URL
    public let tokenEndpoint: URL

    public init(
        clientID: String,
        clientSecret: String?,
        scopes: [String] = GeminiOAuthConfiguration.defaultScopes,
        authorizationEndpoint: URL = GeminiOAuthConfiguration.defaultAuthorizationEndpoint,
        tokenEndpoint: URL = GeminiOAuthConfiguration.defaultTokenEndpoint
    ) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.scopes = scopes.isEmpty ? Self.defaultScopes : scopes
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
    }

    public var redactionSecrets: [String] {
        var secrets: [String] = []
        if let clientSecret, !clientSecret.isEmpty {
            secrets.append(clientSecret)
        }
        return secrets
    }

    public var description: String {
        "GeminiOAuthConfiguration(clientID: [REDACTED], hasSecret: \(clientSecret != nil), scopes: \(scopes.count))"
    }

    public var debugDescription: String { description }
}

/// OAuth token payload stored in OpenUsage's Keychain or read read-only from Gemini CLI.
public struct GeminiOAuthCredential: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let accessToken: String
    public let refreshToken: String?
    public let expiryDate: Date?
    public let tokenType: String?
    public let scope: String?

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        expiryDate: Date? = nil,
        tokenType: String? = "Bearer",
        scope: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiryDate = expiryDate
        self.tokenType = tokenType
        self.scope = scope
    }

    public var redactionSecrets: [String] {
        var secrets = [accessToken]
        if let refreshToken, !refreshToken.isEmpty {
            secrets.append(refreshToken)
        }
        return secrets
    }

    public static func decode(from data: Data) -> GeminiOAuthCredential? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = StrictJSON.string(object["access_token"]) else {
            return nil
        }
        let refreshToken = StrictJSON.string(object["refresh_token"])
        let expiry = StrictJSON.timestamp(object["expiry_date"])
            ?? StrictJSON.timestamp(object["expires_at"])
        let tokenType = StrictJSON.string(object["token_type"])
        let scope = StrictJSON.string(object["scope"])
        return GeminiOAuthCredential(
            accessToken: token,
            refreshToken: refreshToken,
            expiryDate: expiry,
            tokenType: tokenType,
            scope: scope
        )
    }

    public func encode() -> Data? {
        var payload: [String: Any] = [
            "access_token": accessToken
        ]
        if let refreshToken, !refreshToken.isEmpty {
            payload["refresh_token"] = refreshToken
        }
        if let expiryDate {
            let ms = Int64((expiryDate.timeIntervalSince1970 * 1000.0).rounded())
            payload["expiry_date"] = ms
        }
        if let tokenType, !tokenType.isEmpty {
            payload["token_type"] = tokenType
        }
        if let scope, !scope.isEmpty {
            payload["scope"] = scope
        }
        return try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    public var description: String {
        "GeminiOAuthCredential(hasRefreshToken: \(refreshToken != nil), hasExpiry: \(expiryDate != nil))"
    }

    public var debugDescription: String { description }
}

// MARK: - Safe OAuth Errors

/// Safe, secret-free errors emitted during Gemini OAuth sign-in and token refresh.
public enum GeminiOAuthError: Error, Sendable, Equatable {
    case missingOAuthConfiguration
    case browserOpenFailed
    case callbackServerFailed
    case timedOut
    case cancelled
    case authorizationDenied
    case authorizationFailed(code: String)
    case stateMismatch
    case missingAuthorizationCode
    case invalidGrant
    case invalidClient
    case tokenExchangeFailed(statusCode: Int?)
    case transientFailure(reason: String)
    case keychainStorageUnavailable
    case keychainWriteFailed(reason: String)

    public var isTransient: Bool {
        switch self {
        case .transientFailure:
            return true
        default:
            return false
        }
    }

    public var userMessage: String {
        switch self {
        case .missingOAuthConfiguration:
            return "Install Gemini CLI to sign in with Google"
        case .browserOpenFailed:
            return "Could not open browser for Google sign-in"
        case .callbackServerFailed:
            return "Could not start local OAuth callback listener"
        case .timedOut:
            return "Google sign-in timed out — try again"
        case .cancelled:
            return "Google sign-in cancelled"
        case .authorizationDenied:
            return "Google sign-in was cancelled"
        case .authorizationFailed(let code):
            return "Google sign-in failed (\(SecretRedactor.sanitize(code, maxLength: 32)))"
        case .stateMismatch:
            return "Google sign-in failed — invalid session state"
        case .missingAuthorizationCode:
            return "Google sign-in did not return an authorization code"
        case .invalidGrant:
            return "Gemini sign-in expired — click Reconnect"
        case .invalidClient:
            return "Google rejected Gemini CLI OAuth client"
        case .tokenExchangeFailed(let status):
            if let status {
                return "Google token exchange failed (HTTP \(status))"
            }
            return "Google token exchange failed"
        case .transientFailure(let reason):
            return SecretRedactor.sanitize(reason, maxLength: 100)
        case .keychainStorageUnavailable:
            return "Keychain storage unavailable for Gemini sign-in"
        case .keychainWriteFailed(let reason):
            return "Could not save Gemini login (\(SecretRedactor.sanitize(reason, maxLength: 60)))"
        }
    }
}

// MARK: - PKCE, State, and Crypto Utilities

public enum GeminiPKCE {
    public struct Pair: Sendable, Equatable {
        public let verifier: String
        public let challenge: String
        public let method: String

        public init(verifier: String, challenge: String, method: String = "S256") {
            self.verifier = verifier
            self.challenge = challenge
            self.method = method
        }
    }

    /// Generates an RFC 7636 PKCE verifier (86 base64url chars from 64 CSPRNG bytes) and S256 challenge.
    public static func generatePair() -> Pair {
        let randomData = randomBytes(count: 64)
        let verifier = base64URLEncode(randomData)
        return Pair(verifier: verifier, challenge: challenge(forVerifier: verifier), method: "S256")
    }

    /// Computes the RFC 7636 S256 code challenge (`BASE64URL(SHA256(ASCII(verifier)))`).
    public static func challenge(forVerifier verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(digest))
    }

    /// Generates a 256-bit random OAuth state token as 64 lowercase hex characters.
    public static func generateState() -> String {
        randomBytes(count: 32).map { String(format: "%02x", $0) }.joined()
    }

    /// Constant-time comparison of UTF-8 strings for OAuth `state` validation.
    public static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        let maxCount = max(a.count, b.count)
        guard maxCount > 0 else { return false }
        var diff: UInt8 = a.count == b.count ? 0 : 1
        for idx in 0..<maxCount {
            let av = idx < a.count ? a[idx] : 0
            let bv = idx < b.count ? b[idx] : 0
            diff |= (av ^ bv)
        }
        return diff == 0
    }

    /// SHA-256 hex fingerprint (used only for in-memory cache keys without storing raw tokens as keys).
    public static func sha256Hex(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: max(1, count))
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            var rng = SystemRandomNumberGenerator()
            for index in bytes.indices {
                bytes[index] = UInt8.random(in: UInt8.min...UInt8.max, using: &rng)
            }
        }
        return Data(bytes)
    }
}

// MARK: - Installed Gemini CLI OAuth Config Discovery (Read-Only, No Shell Execution)

public protocol GeminiOAuthConfigProviding: Sendable {
    func loadConfiguration() -> GeminiOAuthConfiguration?
}

public struct StaticGeminiOAuthConfigProvider: GeminiOAuthConfigProviding, Sendable {
    private let configuration: GeminiOAuthConfiguration?

    public init(_ configuration: GeminiOAuthConfiguration?) {
        self.configuration = configuration
    }

    public func loadConfiguration() -> GeminiOAuthConfiguration? {
        configuration
    }
}

/// Discovers Gemini CLI's public installed-app OAuth configuration from the local Gemini CLI installation
/// (`@google/gemini-cli-core/dist/src/code_assist/oauth2.js`) using read-only file access and zero shell execution.
///
/// Note: Reusing Gemini CLI's public installed-app client means Google's browser consent screen identifies
/// **Gemini CLI** rather than a separately registered OpenUsage OAuth application.
public struct GeminiCLIOAuthConfigLoader: GeminiOAuthConfigProviding, Sendable {
    private static let maxCellarEntries = 8
    private static let oauthRelativePaths: [String] = [
        "libexec/lib/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
        "libexec/lib/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js"
    ]

    private let fileReader: any LocalFileReader
    private let explicitCandidateURLs: [URL]?
    private let discoverSystemPaths: Bool

    public init(
        fileReader: any LocalFileReader = SystemLocalFileReader(),
        candidateFileURLs: [URL]? = nil,
        discoverSystemPaths: Bool? = nil
    ) {
        self.fileReader = fileReader
        self.explicitCandidateURLs = candidateFileURLs
        // Keep test doubles strictly hermetic unless system discovery is explicitly opted in.
        self.discoverSystemPaths = discoverSystemPaths ?? (fileReader is SystemLocalFileReader)
    }

    public func loadConfiguration() -> GeminiOAuthConfiguration? {
        for url in candidateURLs() {
            guard let data = try? fileReader.readFile(at: url),
                  let text = String(data: data, encoding: .utf8),
                  let config = Self.parseOAuthConfig(from: text) else {
                continue
            }
            return config
        }
        return nil
    }

    /// Parses `OAUTH_CLIENT_ID`, `OAUTH_CLIENT_SECRET`, and optional `OAUTH_SCOPE` from Gemini CLI's `oauth2.js`.
    public static func parseOAuthConfig(from source: String) -> GeminiOAuthConfiguration? {
        guard let clientID = firstCapture(
            pattern: #"OAUTH_CLIENT_ID\s*(?::\s*string\s*)?=\s*['"]([^'"\r\n]+)['"]"#,
            in: source
        ),
              let clientSecret = firstCapture(
                pattern: #"OAUTH_CLIENT_SECRET\s*(?::\s*string\s*)?=\s*['"]([^'"\r\n]+)['"]"#,
                in: source
              ) else {
            return nil
        }

        let trimmedID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty, !trimmedSecret.isEmpty else {
            return nil
        }

        let scopes = parseScopes(from: source) ?? GeminiOAuthConfiguration.defaultScopes
        return GeminiOAuthConfiguration(
            clientID: trimmedID,
            clientSecret: trimmedSecret,
            scopes: scopes
        )
    }

    private static func parseScopes(from source: String) -> [String]? {
        guard let arrayBlock = firstCapture(
            pattern: #"OAUTH_SCOPE\s*(?::[^=]+)?=\s*\[([^\]]+)\]"#,
            in: source,
            options: [.dotMatchesLineSeparators]
        ) else {
            return nil
        }
        guard let itemRegex = try? NSRegularExpression(pattern: #"['"](https://[^'"\s]+)['"]"#) else {
            return nil
        }
        let nsRange = NSRange(arrayBlock.startIndex..<arrayBlock.endIndex, in: arrayBlock)
        let scopes = itemRegex.matches(in: arrayBlock, range: nsRange).compactMap { match -> String? in
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: arrayBlock) else {
                return nil
            }
            return String(arrayBlock[range])
        }
        return scopes.isEmpty ? nil : scopes
    }

    private static func firstCapture(
        pattern: String,
        in text: String,
        options: NSRegularExpression.Options = []
    ) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: nsRange),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    private func candidateURLs() -> [URL] {
        var candidates: [URL] = []
        var seen: Set<String> = []

        func appendUnique(_ url: URL) {
            let standardized = discoverSystemPaths ? url.resolvingSymlinksInPath() : url.standardizedFileURL
            if seen.insert(standardized.path).inserted {
                candidates.append(standardized)
            }
        }

        if let explicitCandidateURLs {
            for url in explicitCandidateURLs {
                appendUnique(url)
            }
            return candidates
        }

        let staticRoots = [
            "/opt/homebrew/opt/gemini-cli",
            "/usr/local/opt/gemini-cli"
        ]
        for root in staticRoots {
            let rootURL = URL(fileURLWithPath: root, isDirectory: true)
            for rel in Self.oauthRelativePaths {
                appendUnique(rootURL.appendingPathComponent(rel, isDirectory: false))
            }
        }

        let globalNodePaths = [
            "/opt/homebrew/lib/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
            "/usr/local/lib/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
            "/opt/homebrew/lib/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
            "/usr/local/lib/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js"
        ]
        for path in globalNodePaths {
            appendUnique(URL(fileURLWithPath: path, isDirectory: false))
        }

        guard discoverSystemPaths else {
            return candidates
        }

        for binPath in ["/opt/homebrew/bin/gemini", "/usr/local/bin/gemini"] {
            let resolved = URL(fileURLWithPath: binPath).resolvingSymlinksInPath()
            if resolved.path != binPath {
                let packageRoot = resolved
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                appendUnique(
                    packageRoot.appendingPathComponent(
                        "node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
                        isDirectory: false
                    )
                )
                appendUnique(
                    packageRoot
                        .deletingLastPathComponent()
                        .appendingPathComponent(
                            "gemini-cli-core/dist/src/code_assist/oauth2.js",
                            isDirectory: false
                        )
                )
            }
        }

        for cellarRoot in ["/opt/homebrew/Cellar/gemini-cli", "/usr/local/Cellar/gemini-cli"] {
            let cellarURL = URL(fileURLWithPath: cellarRoot, isDirectory: true)
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: cellarURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            let sorted = entries.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
            for versionDir in sorted.prefix(Self.maxCellarEntries) {
                for rel in Self.oauthRelativePaths {
                    appendUnique(versionDir.appendingPathComponent(rel, isDirectory: false))
                }
            }
        }

        return candidates
    }
}

// MARK: - Loopback HTTP OAuth Callback Server (127.0.0.1 ephemeral port)

public protocol GeminiOAuthCallbackListening: Sendable {
    var redirectURI: URL { get }
    func waitForAuthorizationCode(expectedState: String, timeout: TimeInterval) async throws -> String
    func stop()
}

public protocol GeminiOAuthSessionStarting: Sendable {
    func startLoopbackListener() throws -> any GeminiOAuthCallbackListening
}

public struct LoopbackGeminiOAuthSessionStarter: GeminiOAuthSessionStarting, Sendable {
    public init() {}

    public func startLoopbackListener() throws -> any GeminiOAuthCallbackListening {
        try LoopbackOAuthCallbackServer()
    }
}

/// Ephemeral IPv4 loopback (`127.0.0.1:0`) HTTP server that captures a single Google OAuth authorization callback,
/// validates `state` in constant time before handling `error` or `code`, ignores unrelated/wrong-state/stray requests
/// while continuing to wait for the legitimate callback, handles non-blocking Darwin `accept()` sockets with bounded
/// `poll()` I/O for delayed or fragmented headers, and enforces bounded timeouts and cooperative task cancellation.
public final class LoopbackOAuthCallbackServer: GeminiOAuthCallbackListening, @unchecked Sendable {
    public static let defaultCallbackPath = "/oauth2callback"
    public static let defaultClientIOTimeout: TimeInterval = 3.0
    private static let maxRequestBytes = 16 * 1024
    private static let maxConcurrentClients = 8
    private static let pollSliceMilliseconds: Int32 = 100

    /// Honest pre-exchange acknowledgment shown before token exchange and Keychain persistence run.
    private static let acknowledgmentHTML = """
    <!doctype html>
    <html lang="en"><head><meta charset="utf-8"><title>OpenUsage</title>
    <style>body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;background:#17191e;color:#f4f4f5;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}main{text-align:center;max-width:420px;padding:24px}h1{font-size:18px;margin:0 0 8px}p{font-size:13px;color:#a1a1aa;margin:0}</style>
    </head><body><main><h1>Authorization received</h1><p>Return to OpenUsage to finish connecting Gemini CLI quota. You can close this browser tab.</p></main></body></html>
    """

    private static let failureHTML = """
    <!doctype html>
    <html lang="en"><head><meta charset="utf-8"><title>OpenUsage</title>
    <style>body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;background:#17191e;color:#f4f4f5;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}main{text-align:center;max-width:420px;padding:24px}h1{font-size:18px;margin:0 0 8px}p{font-size:13px;color:#a1a1aa;margin:0}</style>
    </head><body><main><h1>Sign-in did not complete</h1><p>Return to OpenUsage and try again. You can close this browser tab.</p></main></body></html>
    """

    private static let allowedOAuthErrorCodes: Set<String> = [
        "access_denied",
        "invalid_request",
        "unauthorized_client",
        "unsupported_response_type",
        "invalid_scope",
        "server_error",
        "temporarily_unavailable",
        "interaction_required",
        "login_required",
        "account_selection_required",
        "consent_required"
    ]

    public let port: UInt16
    public let redirectURI: URL

    private let callbackPath: String
    private let maxStrayRequests: Int
    private let clientIOTimeout: TimeInterval
    private let acceptQueue = DispatchQueue(label: "dev.jabree.OpenUsage.gemini-oauth-loopback.accept", qos: .userInitiated)
    private let clientQueue = DispatchQueue(label: "dev.jabree.OpenUsage.gemini-oauth-loopback.clients", qos: .userInitiated, attributes: .concurrent)
    private let lock = NSLock()

    private var listeningFD: Int32
    private var readSource: DispatchSourceRead?
    private var timeoutItem: DispatchWorkItem?
    private var expectedState: String?
    private var continuation: CheckedContinuation<String, Error>?
    private var completedResult: Result<String, Error>?
    private var strayRequestCount = 0
    private var activeClientCount = 0
    private var stopped = false

    public init(
        callbackPath: String = LoopbackOAuthCallbackServer.defaultCallbackPath,
        maxStrayRequests: Int = 32,
        clientIOTimeout: TimeInterval = LoopbackOAuthCallbackServer.defaultClientIOTimeout
    ) throws {
        self.callbackPath = callbackPath
        self.maxStrayRequests = max(1, maxStrayRequests)
        self.clientIOTimeout = max(0.2, min(15.0, clientIOTimeout))

        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw GeminiOAuthError.callbackServerFailed
        }

        let flags = fcntl(fd, F_GETFL, 0)
        if flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0 {
            _ = Darwin.close(fd)
            throw GeminiOAuthError.callbackServerFailed
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // OS-assigned ephemeral port
        addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddrPtr in
                Darwin.bind(fd, sockAddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            _ = Darwin.close(fd)
            throw GeminiOAuthError.callbackServerFailed
        }

        guard Darwin.listen(fd, 8) == 0 else {
            _ = Darwin.close(fd)
            throw GeminiOAuthError.callbackServerFailed
        }

        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let sockNameResult = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddrPtr in
                Darwin.getsockname(fd, sockAddrPtr, &addrLen)
            }
        }
        guard sockNameResult == 0 else {
            _ = Darwin.close(fd)
            throw GeminiOAuthError.callbackServerFailed
        }

        let assignedPort = UInt16(bigEndian: boundAddr.sin_port)
        guard assignedPort > 0,
              let uri = URL(string: "http://127.0.0.1:\(assignedPort)\(callbackPath)") else {
            _ = Darwin.close(fd)
            throw GeminiOAuthError.callbackServerFailed
        }

        self.listeningFD = fd
        self.port = assignedPort
        self.redirectURI = uri
    }

    deinit {
        stop()
    }

    public func waitForAuthorizationCode(expectedState: String, timeout: TimeInterval) async throws -> String {
        try Task.checkCancellation()
        let effectiveTimeout = timeout.isFinite ? min(600.0, max(0.05, timeout)) : 180.0

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result = completedResult {
                    lock.unlock()
                    continuation.resume(with: result)
                    return
                }
                if stopped || listeningFD < 0 {
                    lock.unlock()
                    continuation.resume(throwing: GeminiOAuthError.cancelled)
                    return
                }
                if Task.isCancelled {
                    lock.unlock()
                    finish(with: .failure(CancellationError()))
                    continuation.resume(throwing: CancellationError())
                    return
                }

                self.expectedState = expectedState
                self.continuation = continuation

                let fd = self.listeningFD
                self.listeningFD = -1 // Ownership transfers to DispatchSource cancel handler.
                let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
                source.setEventHandler { [weak self] in
                    self?.acceptPendingConnections(listeningFD: fd)
                }
                source.setCancelHandler {
                    _ = Darwin.close(fd)
                }
                self.readSource = source

                let timer = DispatchWorkItem { [weak self] in
                    self?.finish(with: .failure(GeminiOAuthError.timedOut))
                }
                self.timeoutItem = timer
                lock.unlock()

                source.resume()
                acceptQueue.asyncAfter(deadline: .now() + effectiveTimeout, execute: timer)
            }
        } onCancel: {
            self.finish(with: .failure(CancellationError()))
        }
    }

    public func stop() {
        finish(with: .failure(CancellationError()))
    }

    private func isFinishedOrStopped() -> Bool {
        lock.withLock { stopped || completedResult != nil }
    }

    private func acceptPendingConnections(listeningFD fd: Int32) {
        while true {
            guard !isFinishedOrStopped() else { return }

            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddrPtr in
                    Darwin.accept(fd, sockAddrPtr, &clientLen)
                }
            }

            if clientFD < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                }
                return
            }

            let admitted: Bool = lock.withLock {
                guard !stopped, completedResult == nil, activeClientCount < Self.maxConcurrentClients else {
                    return false
                }
                activeClientCount += 1
                return true
            }

            guard admitted else {
                _ = Darwin.close(clientFD)
                continue
            }

            // Handle each accepted socket on a bounded concurrent queue so slow/stray clients
            // never block subsequent accepts or the session timeout timer on acceptQueue.
            clientQueue.async { [weak self] in
                guard let self else {
                    _ = Darwin.close(clientFD)
                    return
                }
                defer {
                    self.lock.withLock { self.activeClientCount = max(0, self.activeClientCount - 1) }
                }
                self.handleClient(fd: clientFD)
            }
        }
    }

    private func handleClient(fd clientFD: Int32) {
        defer { _ = Darwin.close(clientFD) }

        var noSigPipe: Int32 = 1
        _ = setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        // Ensure non-blocking mode explicitly so poll()-driven bounded I/O works consistently on Darwin.
        let currentFlags = fcntl(clientFD, F_GETFL, 0)
        if currentFlags >= 0 && (currentFlags & O_NONBLOCK) == 0 {
            _ = fcntl(clientFD, F_SETFL, currentFlags | O_NONBLOCK)
        }

        let deadlineNanos = Self.monotonicUptimeNanos() &+ UInt64(clientIOTimeout * 1_000_000_000)

        guard let requestData = readHTTPRequestHeaders(from: clientFD, deadlineNanos: deadlineNanos),
              let requestLine = parseRequestLine(from: requestData) else {
            if !isFinishedOrStopped() {
                writeHTTPResponse(fd: clientFD, status: "400 Bad Request", body: Self.failureHTML, deadlineNanos: deadlineNanos)
                recordStrayRequest()
            }
            return
        }

        guard requestLine.method == "GET" else {
            writeHTTPResponse(fd: clientFD, status: "405 Method Not Allowed", body: Self.failureHTML, deadlineNanos: deadlineNanos)
            recordStrayRequest()
            return
        }

        guard let components = URLComponents(string: "http://127.0.0.1\(requestLine.target)") else {
            writeHTTPResponse(fd: clientFD, status: "400 Bad Request", body: Self.failureHTML, deadlineNanos: deadlineNanos)
            recordStrayRequest()
            return
        }

        guard components.path == callbackPath else {
            writeHTTPResponse(
                fd: clientFD,
                status: "404 Not Found",
                body: "Not found",
                contentType: "text/plain; charset=utf-8",
                deadlineNanos: deadlineNanos
            )
            recordStrayRequest()
            return
        }

        let queryItems = components.queryItems ?? []
        func queryValue(_ name: String) -> String? {
            queryItems.first(where: { $0.name == name })?.value
        }

        // Validate state FIRST before processing either `error` or `code`.
        // An unrelated or wrong-state request must NOT terminate an active sign-in session.
        let stateExpected = lock.withLock { self.expectedState }
        guard let stateExpected,
              let receivedState = queryValue("state"),
              GeminiPKCE.constantTimeEqual(receivedState, stateExpected) else {
            writeHTTPResponse(fd: clientFD, status: "400 Bad Request", body: Self.failureHTML, deadlineNanos: deadlineNanos)
            recordStrayRequest()
            return
        }

        if let rawError = queryValue("error"), !rawError.isEmpty {
            writeHTTPResponse(fd: clientFD, status: "200 OK", body: Self.failureHTML, deadlineNanos: deadlineNanos)
            let normalized = rawError.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized == "access_denied" {
                finish(with: .failure(GeminiOAuthError.authorizationDenied))
            } else {
                let safeCode = Self.allowedOAuthErrorCodes.contains(normalized) ? normalized : "oauth_error"
                finish(with: .failure(GeminiOAuthError.authorizationFailed(code: safeCode)))
            }
            return
        }

        guard let code = queryValue("code")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !code.isEmpty else {
            writeHTTPResponse(fd: clientFD, status: "400 Bad Request", body: Self.failureHTML, deadlineNanos: deadlineNanos)
            finish(with: .failure(GeminiOAuthError.missingAuthorizationCode))
            return
        }

        writeHTTPResponse(fd: clientFD, status: "200 OK", body: Self.acknowledgmentHTML, deadlineNanos: deadlineNanos)
        finish(with: .success(code))
    }

    private func recordStrayRequest() {
        let exceeded: Bool = lock.withLock {
            strayRequestCount += 1
            return strayRequestCount >= maxStrayRequests
        }
        if exceeded {
            finish(with: .failure(GeminiOAuthError.callbackServerFailed))
        }
    }

    /// Reads complete HTTP request headers (`\r\n\r\n`) from a non-blocking socket using bounded `poll()` waits
    /// so delayed or fragmented browser TCP writes are reassembled cleanly up to `deadlineNanos` and `maxRequestBytes`.
    private func readHTTPRequestHeaders(from clientFD: Int32, deadlineNanos: UInt64) -> Data? {
        var buffer = Data()
        buffer.reserveCapacity(1024)
        var chunk = [UInt8](repeating: 0, count: 2048)
        let headerTerminator = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n

        while buffer.count < Self.maxRequestBytes {
            if isFinishedOrStopped() {
                return nil
            }
            let nowNanos = Self.monotonicUptimeNanos()
            if nowNanos >= deadlineNanos {
                return nil
            }
            let remainingMs = Int32(min(UInt64(Self.pollSliceMilliseconds), (deadlineNanos - nowNanos) / 1_000_000 + 1))

            var pfd = pollfd(fd: clientFD, events: Int16(POLLIN), revents: 0)
            let pollRC = Darwin.poll(&pfd, 1, remainingMs)
            if pollRC == 0 {
                continue
            }
            if pollRC < 0 {
                if errno == EINTR { continue }
                return nil
            }

            if (pfd.revents & Int16(POLLERR | POLLNVAL)) != 0 {
                return nil
            }

            let remainingCapacity = Self.maxRequestBytes - buffer.count
            let bytesRead = Darwin.recv(clientFD, &chunk, min(chunk.count, remainingCapacity), 0)
            if bytesRead > 0 {
                buffer.append(chunk, count: bytesRead)
                if buffer.range(of: headerTerminator) != nil {
                    return buffer
                }
            } else if bytesRead == 0 {
                // Peer closed before completing `\r\n\r\n`.
                return buffer.range(of: headerTerminator) != nil ? buffer : nil
            } else {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                    continue
                }
                return nil
            }
        }
        return buffer.range(of: headerTerminator) != nil ? buffer : nil
    }

    private func parseRequestLine(from data: Data) -> (method: String, target: String)? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              let firstLine = text.split(separator: "\n", maxSplits: 1).first else {
            return nil
        }
        let cleaned = firstLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r "))
        let parts = cleaned.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let target = String(parts[1])
        guard target.hasPrefix("/") else { return nil }
        return (method, target)
    }

    private func writeHTTPResponse(
        fd clientFD: Int32,
        status: String,
        body: String,
        contentType: String = "text/html; charset=utf-8",
        deadlineNanos: UInt64
    ) {
        let bodyData = Data(body.utf8)
        let header = "HTTP/1.1 \(status)\r\n" +
            "Content-Type: \(contentType)\r\n" +
            "Content-Length: \(bodyData.count)\r\n" +
            "Cache-Control: no-store\r\n" +
            "Connection: close\r\n\r\n"
        var responseData = Data(header.utf8)
        responseData.append(bodyData)

        let writeDeadline = max(deadlineNanos, Self.monotonicUptimeNanos() &+ 1_000_000_000)

        responseData.withUnsafeBytes { rawBuffer in
            guard let basePtr = rawBuffer.baseAddress else { return }
            var totalSent = 0
            while totalSent < rawBuffer.count {
                let nowNanos = Self.monotonicUptimeNanos()
                if nowNanos >= writeDeadline {
                    break
                }
                let sent = Darwin.send(clientFD, basePtr.advanced(by: totalSent), rawBuffer.count - totalSent, 0)
                if sent > 0 {
                    totalSent += sent
                } else if sent < 0 && errno == EINTR {
                    continue
                } else if sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    let remainingMs = Int32(min(UInt64(Self.pollSliceMilliseconds), (writeDeadline - nowNanos) / 1_000_000 + 1))
                    var pfd = pollfd(fd: clientFD, events: Int16(POLLOUT), revents: 0)
                    let rc = Darwin.poll(&pfd, 1, remainingMs)
                    if rc < 0 && errno != EINTR { break }
                } else {
                    break
                }
            }
        }
    }

    private static func monotonicUptimeNanos() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    private func finish(with result: Result<String, Error>) {
        var contToResume: CheckedContinuation<String, Error>?
        var sourceToCancel: DispatchSourceRead?
        var timerToCancel: DispatchWorkItem?
        var fdToClose: Int32 = -1

        lock.lock()
        if completedResult == nil {
            completedResult = result
        }
        stopped = true
        contToResume = continuation
        continuation = nil
        sourceToCancel = readSource
        readSource = nil
        timerToCancel = timeoutItem
        timeoutItem = nil
        fdToClose = listeningFD
        listeningFD = -1
        lock.unlock()

        timerToCancel?.cancel()
        if let sourceToCancel {
            sourceToCancel.cancel()
        } else if fdToClose >= 0 {
            _ = Darwin.close(fdToClose)
        }

        contToResume?.resume(with: result)
    }
}

// MARK: - Google OAuth HTTP Client

public enum GeminiOAuthClient {
    private static let formUnreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static let allowedTokenErrorCodes: Set<String> = [
        "invalid_grant",
        "invalid_client",
        "unauthorized_client",
        "invalid_request",
        "unsupported_grant_type",
        "invalid_scope",
        "access_denied"
    ]

    /// Constructs the Google OAuth 2.0 browser authorization URL with PKCE S256 and state.
    public static func buildAuthorizationURL(
        configuration: GeminiOAuthConfiguration,
        redirectURI: URL,
        state: String,
        codeChallenge: String
    ) -> URL? {
        guard var components = URLComponents(url: configuration.authorizationEndpoint, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let params: [(String, String)] = [
            ("client_id", configuration.clientID),
            ("redirect_uri", redirectURI.absoluteString),
            ("response_type", "code"),
            ("scope", configuration.scopes.joined(separator: " ")),
            ("access_type", "offline"),
            ("prompt", "consent"),
            ("state", state),
            ("code_challenge", codeChallenge),
            ("code_challenge_method", "S256")
        ]
        components.percentEncodedQuery = percentEncodedForm(params)
        return components.url
    }

    /// Exchanges an authorization code + PKCE verifier at Google's token endpoint.
    public static func exchangeAuthorizationCode(
        code: String,
        codeVerifier: String,
        redirectURI: URL,
        configuration: GeminiOAuthConfiguration,
        httpTransport: any HTTPTransport,
        timeout: TimeInterval,
        now: Date
    ) async throws -> GeminiOAuthCredential {
        var params: [(String, String)] = [
            ("client_id", configuration.clientID),
            ("code", code),
            ("code_verifier", codeVerifier),
            ("grant_type", "authorization_code"),
            ("redirect_uri", redirectURI.absoluteString)
        ]
        if let secret = configuration.clientSecret, !secret.isEmpty {
            params.append(("client_secret", secret))
        }
        return try await sendTokenRequest(
            params: params,
            existingRefreshToken: nil,
            configuration: configuration,
            httpTransport: httpTransport,
            timeout: timeout,
            now: now
        )
    }

    /// Refreshes an expired access token using a refresh token at Google's token endpoint.
    public static func refreshAccessToken(
        refreshToken: String,
        configuration: GeminiOAuthConfiguration,
        httpTransport: any HTTPTransport,
        timeout: TimeInterval,
        now: Date
    ) async throws -> GeminiOAuthCredential {
        var params: [(String, String)] = [
            ("client_id", configuration.clientID),
            ("refresh_token", refreshToken),
            ("grant_type", "refresh_token")
        ]
        if let secret = configuration.clientSecret, !secret.isEmpty {
            params.append(("client_secret", secret))
        }
        return try await sendTokenRequest(
            params: params,
            existingRefreshToken: refreshToken,
            configuration: configuration,
            httpTransport: httpTransport,
            timeout: timeout,
            now: now
        )
    }

    public static func percentEncodedForm(_ pairs: [(String, String)]) -> String {
        pairs.map { key, value in
            "\(encodeFormComponent(key))=\(encodeFormComponent(value))"
        }.joined(separator: "&")
    }

    private static func encodeFormComponent(_ raw: String) -> String {
        raw.addingPercentEncoding(withAllowedCharacters: formUnreserved) ?? ""
    }

    private static func sendTokenRequest(
        params: [(String, String)],
        existingRefreshToken: String?,
        configuration: GeminiOAuthConfiguration,
        httpTransport: any HTTPTransport,
        timeout: TimeInterval,
        now: Date
    ) async throws -> GeminiOAuthCredential {
        var request = URLRequest(url: configuration.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(percentEncodedForm(params).utf8)

        let response: HTTPResponseData
        do {
            response = try await httpTransport.send(request, timeout: timeout)
        } catch let error as LiveProviderTransportError {
            if error == .cancelled {
                throw CancellationError()
            }
            throw GeminiOAuthError.transientFailure(reason: error.shortReason)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GeminiOAuthError.transientFailure(reason: "Network request failed")
        }

        switch response.statusCode {
        case 200:
            guard let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
                  let accessToken = StrictJSON.string(object["access_token"]) else {
                throw GeminiOAuthError.tokenExchangeFailed(statusCode: 200)
            }
            let returnedRefresh = StrictJSON.string(object["refresh_token"])
            let tokenType = StrictJSON.string(object["token_type"]) ?? "Bearer"
            let scope = StrictJSON.string(object["scope"])
            let expiryDate: Date?
            if let expiresIn = StrictJSON.double(object["expires_in"]), expiresIn > 0, expiresIn < 365 * 24 * 3600 {
                expiryDate = now.addingTimeInterval(expiresIn)
            } else {
                expiryDate = StrictJSON.timestamp(object["expiry_date"]) ?? StrictJSON.timestamp(object["expires_at"])
            }
            return GeminiOAuthCredential(
                accessToken: accessToken,
                refreshToken: returnedRefresh ?? existingRefreshToken,
                expiryDate: expiryDate,
                tokenType: tokenType,
                scope: scope
            )

        case 400, 401, 403:
            if let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
               let rawError = StrictJSON.string(object["error"])?.lowercased() {
                if rawError == "invalid_grant" {
                    throw GeminiOAuthError.invalidGrant
                }
                if rawError == "invalid_client" || rawError == "unauthorized_client" {
                    throw GeminiOAuthError.invalidClient
                }
                if allowedTokenErrorCodes.contains(rawError) {
                    throw GeminiOAuthError.authorizationFailed(code: rawError)
                }
            }
            if response.statusCode == 401 {
                throw GeminiOAuthError.invalidGrant
            }
            throw GeminiOAuthError.tokenExchangeFailed(statusCode: response.statusCode)

        case 429, 500...599:
            throw GeminiOAuthError.transientFailure(reason: "Google OAuth temporarily unavailable (HTTP \(response.statusCode))")

        default:
            throw GeminiOAuthError.tokenExchangeFailed(statusCode: response.statusCode)
        }
    }
}

// MARK: - Serialized Per-Session Credential Coordinator

/// Serializes all Gemini credential state mutations (enablement/disablement, in-memory refreshed token cache,
/// single-flight refresh coalescing, Keychain writes/deletes, and Keychain lookup cache invalidation) against a
/// monotonic per-session generation so stalled refreshes, concurrent completions, stale `invalid_grant` errors,
/// cancelled sign-ins, rapid sign-out/sign-in transitions, or late Keychain reads can never corrupt state.
public actor GeminiCredentialCoordinator {
    public struct CachedEntry: Sendable, Equatable {
        public let version: UInt64
        public let credential: GeminiOAuthCredential
        public let needsKeychainPersist: Bool

        public init(version: UInt64, credential: GeminiOAuthCredential, needsKeychainPersist: Bool) {
            self.version = version
            self.credential = credential
            self.needsKeychainPersist = needsKeychainPersist
        }
    }

    public enum CommitStatus: Sendable, Equatable {
        case committed
        case stale
    }

    public enum RefreshCommitOutcome: Sendable, Equatable {
        case committed(GeminiOAuthCredential)
        case stale
        case keychainWriteFailed(reason: String)
        case oauthError(GeminiOAuthError)
    }

    public enum SignOutOutcome: Sendable, Equatable {
        case succeeded
        case keychainDeleteFailed(reason: String)
    }

    private struct InFlightRefreshKey: Hashable, Sendable {
        let stableCacheKey: String
        let generation: UInt64
    }

    private struct InFlightRefresh {
        let id: UUID
        let task: Task<RefreshCommitOutcome, Never>
    }

    private var generation: UInt64 = 0
    private var cacheVersionCounter: UInt64 = 0
    private var refreshedTokens: [String: CachedEntry] = [:]
    private var inFlightRefreshes: [InFlightRefreshKey: InFlightRefresh] = [:]

    public init() {}

    public func currentGeneration() -> UInt64 {
        generation
    }

    /// Reads the provider's disabled flag and current session generation in one atomic actor turn.
    public func beginFetch(disableStore: any ProviderDisableStoring) -> (isDisabled: Bool, generation: UInt64) {
        (disableStore.isDisabled(.gemini), generation)
    }

    /// Enables the provider and advances the session generation in one non-suspending actor turn so
    /// an earlier `signOut()` can never overwrite a subsequent `signIn()` and earlier background refreshes become stale.
    public func beginSignIn(disableStore: any ProviderDisableStoring) -> UInt64 {
        generation &+= 1
        cancelAllInFlightRefreshes()
        disableStore.setDisabled(false, for: .gemini)
        return generation
    }

    public func cachedEntry(forKey key: String) -> CachedEntry? {
        refreshedTokens[key]
    }

    public func cachedCredential(forKey key: String) -> GeminiOAuthCredential? {
        refreshedTokens[key]?.credential
    }

    /// Removes a cached entry ONLY when `expectedGeneration` matches AND the cached entry still holds
    /// the specified `matchingRefreshToken` / `matchingAccessToken`, preventing stale failures from
    /// clearing a concurrently rotated or refreshed credential.
    public func invalidateCachedCredentialIfMatching(
        forKey key: String,
        expectedGeneration: UInt64,
        matchingRefreshToken: String? = nil,
        matchingAccessToken: String? = nil
    ) {
        guard generation == expectedGeneration, let entry = refreshedTokens[key] else { return }
        if let matchingRefreshToken, entry.credential.refreshToken != matchingRefreshToken {
            return
        }
        if let matchingAccessToken, entry.credential.accessToken != matchingAccessToken {
            return
        }
        refreshedTokens.removeValue(forKey: key)
    }

    /// Attempts to flush a previously rotated/refreshed Keychain credential that failed to persist earlier.
    /// Executes the Keychain write and state update in one non-suspending turn before invalidating Keychain caches.
    public func flushPendingKeychainPersist(
        forKey key: String,
        expectedGeneration: UInt64,
        keychain: (any KeychainReading)?,
        service: String,
        account: String,
        keychainCoordinator: KeychainLookupCoordinator,
        disableStore: any ProviderDisableStoring
    ) async -> RefreshCommitOutcome {
        let outcome: RefreshCommitOutcome
        let shouldInvalidateCache: Bool

        guard !Task.isCancelled, generation == expectedGeneration, !disableStore.isDisabled(.gemini) else {
            return .stale
        }
        guard var entry = refreshedTokens[key] else {
            return .stale
        }
        guard entry.needsKeychainPersist else {
            return .committed(entry.credential)
        }

        switch persistCredentialToKeychain(
            entry.credential,
            keychain: keychain,
            service: service,
            account: account
        ) {
        case .success:
            entry = CachedEntry(version: entry.version, credential: entry.credential, needsKeychainPersist: false)
            refreshedTokens[key] = entry
            outcome = .committed(entry.credential)
            shouldInvalidateCache = true
        case .failure(let reason):
            outcome = .keychainWriteFailed(reason: reason)
            shouldInvalidateCache = false
        }

        if shouldInvalidateCache && generation == expectedGeneration {
            await keychainCoordinator.clearCachedResult(forService: service, account: account)
        }
        return outcome
    }

    /// Commits an interactively exchanged credential to OpenUsage's Keychain in one non-suspending turn
    /// ONLY if the session generation is still current, the task is not cancelled, and the provider is enabled.
    public func commitSignInCredential(
        _ credential: GeminiOAuthCredential,
        expectedGeneration: UInt64,
        keychain: any KeychainStoring,
        service: String,
        account: String,
        keychainCoordinator: KeychainLookupCoordinator,
        disableStore: any ProviderDisableStoring
    ) async throws -> CommitStatus {
        try Task.checkCancellation()
        guard generation == expectedGeneration, !disableStore.isDisabled(.gemini) else {
            return .stale
        }
        guard let encoded = credential.encode() else {
            throw GeminiOAuthError.keychainWriteFailed(reason: "encoding failed")
        }
        do {
            try keychain.writeGenericPassword(encoded, service: service, account: account)
        } catch let error as KeychainStoreError {
            throw GeminiOAuthError.keychainWriteFailed(reason: error.shortDescription)
        } catch {
            throw GeminiOAuthError.keychainWriteFailed(reason: "Keychain write failed")
        }
        refreshedTokens.removeAll()
        cancelAllInFlightRefreshes()

        if generation == expectedGeneration {
            await keychainCoordinator.clearCachedResult(forService: service, account: account)
        }
        return .committed
    }

    /// Coalesces concurrent token refreshes for the same `(stableCacheKey, expectedGeneration)` so rotating
    /// refresh tokens are not raced concurrently, while running network I/O outside the actor so `signOut()`
    /// is never blocked.
    public func refreshOrJoin(
        stableCacheKey: String,
        expectedGeneration: UInt64,
        expectedBaseVersion: UInt64,
        inputRefreshToken: String,
        persistToKeychain: Bool,
        keychain: (any KeychainReading)?,
        service: String,
        account: String,
        keychainCoordinator: KeychainLookupCoordinator,
        disableStore: any ProviderDisableStoring,
        freshAfter: Date,
        operation: @escaping @Sendable (_ refreshToken: String) async throws -> GeminiOAuthCredential
    ) async -> RefreshCommitOutcome {
        guard !Task.isCancelled,
              generation == expectedGeneration,
              !disableStore.isDisabled(.gemini) else {
            return .stale
        }

        // If another refresh already committed a newer, still-fresh credential since our snapshot, reuse it!
        if let existing = refreshedTokens[stableCacheKey],
           existing.version > expectedBaseVersion {
            let isFresh = existing.credential.expiryDate.map { $0 > freshAfter } ?? true
            if isFresh {
                if persistToKeychain && existing.needsKeychainPersist {
                    return await flushPendingKeychainPersist(
                        forKey: stableCacheKey,
                        expectedGeneration: expectedGeneration,
                        keychain: keychain,
                        service: service,
                        account: account,
                        keychainCoordinator: keychainCoordinator,
                        disableStore: disableStore
                    )
                }
                return .committed(existing.credential)
            }
        }

        let key = InFlightRefreshKey(stableCacheKey: stableCacheKey, generation: expectedGeneration)
        let sharedTask: Task<RefreshCommitOutcome, Never>

        if let existingFlight = inFlightRefreshes[key] {
            sharedTask = existingFlight.task
        } else {
            let refreshID = UUID()
            let currentEntry = refreshedTokens[stableCacheKey]
            let sentRefreshToken = currentEntry?.credential.refreshToken ?? inputRefreshToken
            let capturedBaseVersion = currentEntry?.version ?? expectedBaseVersion

            let task = Task<RefreshCommitOutcome, Never> { [weak self] in
                do {
                    // Run network request outside the actor so signOut/beginSignIn never block.
                    let refreshed = try await operation(sentRefreshToken)
                    guard let self else { return .stale }
                    return await self.finishInFlightRefreshSuccess(
                        id: refreshID,
                        key: key,
                        refreshed: refreshed,
                        expectedBaseVersion: capturedBaseVersion,
                        persistToKeychain: persistToKeychain,
                        keychain: keychain,
                        service: service,
                        account: account,
                        keychainCoordinator: keychainCoordinator,
                        disableStore: disableStore
                    )
                } catch is CancellationError {
                    guard let self else { return .stale }
                    return await self.finishInFlightRefreshFailure(
                        id: refreshID,
                        key: key,
                        error: nil,
                        sentRefreshToken: sentRefreshToken
                    )
                } catch let error as GeminiOAuthError {
                    guard let self else { return .stale }
                    return await self.finishInFlightRefreshFailure(
                        id: refreshID,
                        key: key,
                        error: error,
                        sentRefreshToken: sentRefreshToken
                    )
                } catch {
                    guard let self else { return .stale }
                    return await self.finishInFlightRefreshFailure(
                        id: refreshID,
                        key: key,
                        error: .transientFailure(reason: "Network request failed"),
                        sentRefreshToken: sentRefreshToken
                    )
                }
            }
            inFlightRefreshes[key] = InFlightRefresh(id: refreshID, task: task)
            sharedTask = task
        }

        return await awaitCoalescedTask(sharedTask)
    }

    /// Commits a refreshed credential using compare-and-swap on `(expectedGeneration, expectedBaseVersion)`
    /// and expiry freshness. Cache, Keychain persistence, and the returned credential always agree on the
    /// single winning credential, and Keychain persistence failures are surfaced rather than swallowed.
    public func commitRefreshedCredential(
        _ credential: GeminiOAuthCredential,
        expectedBaseVersion: UInt64 = 0,
        persistToKeychain: Bool,
        stableCacheKey: String,
        expectedGeneration: UInt64,
        keychain: (any KeychainReading)?,
        service: String,
        account: String,
        keychainCoordinator: KeychainLookupCoordinator,
        disableStore: any ProviderDisableStoring
    ) async -> RefreshCommitOutcome {
        let (outcome, shouldInvalidateCache) = commitRefreshedCredentialSync(
            credential,
            expectedBaseVersion: expectedBaseVersion,
            persistToKeychain: persistToKeychain,
            stableCacheKey: stableCacheKey,
            expectedGeneration: expectedGeneration,
            keychain: keychain,
            service: service,
            account: account,
            disableStore: disableStore
        )

        if shouldInvalidateCache && generation == expectedGeneration {
            await keychainCoordinator.clearCachedResult(forService: service, account: account)
        }
        return outcome
    }

    /// Performs generation bump, in-flight refresh cancellation, cache clearing, Keychain deletion,
    /// and provider disablement in ONE non-suspending atomic actor turn, then invalidates Keychain lookup
    /// caches afterward. Surfaces Keychain deletion failures without disabling the provider so retry works.
    public func signOut(
        keychain: (any KeychainReading)?,
        service: String,
        account: String,
        keychainCoordinator: KeychainLookupCoordinator,
        disableStore: any ProviderDisableStoring
    ) async -> SignOutOutcome {
        // --- Non-suspending atomic mutation turn ---
        generation &+= 1
        let signOutGeneration = generation
        cancelAllInFlightRefreshes()
        refreshedTokens.removeAll()

        let outcome: SignOutOutcome
        if let writableKeychain = keychain as? any KeychainStoring {
            do {
                try writableKeychain.deleteGenericPassword(service: service, account: account)
                disableStore.setDisabled(true, for: .gemini)
                outcome = .succeeded
            } catch let error as KeychainStoreError {
                outcome = .keychainDeleteFailed(reason: error.shortDescription)
            } catch {
                outcome = .keychainDeleteFailed(reason: "Keychain delete failed")
            }
        } else if let readOnlyKeychain = keychain {
            if let existing = (try? readOnlyKeychain.readGenericPassword(service: service, account: account)) ?? nil, !existing.isEmpty {
                outcome = .keychainDeleteFailed(reason: "Keychain storage unavailable")
            } else {
                disableStore.setDisabled(true, for: .gemini)
                outcome = .succeeded
            }
        } else {
            disableStore.setDisabled(true, for: .gemini)
            outcome = .succeeded
        }
        // --- End non-suspending atomic mutation turn ---

        // Only invalidate KeychainLookupCoordinator if a newer signIn hasn't already superseded this signOut.
        if generation == signOutGeneration {
            await keychainCoordinator.clearCachedResult(forService: service, account: account)
        }
        return outcome
    }

    // MARK: - Private Coordinator Helpers

    private func finishInFlightRefreshSuccess(
        id: UUID,
        key: InFlightRefreshKey,
        refreshed: GeminiOAuthCredential,
        expectedBaseVersion: UInt64,
        persistToKeychain: Bool,
        keychain: (any KeychainReading)?,
        service: String,
        account: String,
        keychainCoordinator: KeychainLookupCoordinator,
        disableStore: any ProviderDisableStoring
    ) async -> RefreshCommitOutcome {
        if inFlightRefreshes[key]?.id == id {
            inFlightRefreshes.removeValue(forKey: key)
        }
        return await commitRefreshedCredential(
            refreshed,
            expectedBaseVersion: expectedBaseVersion,
            persistToKeychain: persistToKeychain,
            stableCacheKey: key.stableCacheKey,
            expectedGeneration: key.generation,
            keychain: keychain,
            service: service,
            account: account,
            keychainCoordinator: keychainCoordinator,
            disableStore: disableStore
        )
    }

    private func finishInFlightRefreshFailure(
        id: UUID,
        key: InFlightRefreshKey,
        error: GeminiOAuthError?,
        sentRefreshToken: String
    ) -> RefreshCommitOutcome {
        if inFlightRefreshes[key]?.id == id {
            inFlightRefreshes.removeValue(forKey: key)
        }
        guard generation == key.generation else {
            return .stale
        }
        guard let error else {
            return .stale
        }
        if error == .invalidGrant {
            if let existing = refreshedTokens[key.stableCacheKey] {
                if existing.credential.refreshToken != sentRefreshToken {
                    // A concurrent refresh already rotated to a newer refresh token — never clear it!
                    return .committed(existing.credential)
                }
                refreshedTokens.removeValue(forKey: key.stableCacheKey)
            }
        }
        return .oauthError(error)
    }

    private func commitRefreshedCredentialSync(
        _ credential: GeminiOAuthCredential,
        expectedBaseVersion: UInt64,
        persistToKeychain: Bool,
        stableCacheKey: String,
        expectedGeneration: UInt64,
        keychain: (any KeychainReading)?,
        service: String,
        account: String,
        disableStore: any ProviderDisableStoring
    ) -> (outcome: RefreshCommitOutcome, shouldInvalidateCache: Bool) {
        guard !Task.isCancelled,
              generation == expectedGeneration,
              !disableStore.isDisabled(.gemini) else {
            return (.stale, false)
        }

        // CAS against any concurrently committed winner: if an existing cached entry is newer/fresher,
        // keep that winner for cache, Keychain, and quota fetch (never write the losing token to Keychain).
        if let existing = refreshedTokens[stableCacheKey],
           shouldKeepExistingWinner(existing: existing, candidate: credential, expectedBaseVersion: expectedBaseVersion) {
            if persistToKeychain && existing.needsKeychainPersist {
                switch persistCredentialToKeychain(
                    existing.credential,
                    keychain: keychain,
                    service: service,
                    account: account
                ) {
                case .success:
                    refreshedTokens[stableCacheKey] = CachedEntry(
                        version: existing.version,
                        credential: existing.credential,
                        needsKeychainPersist: false
                    )
                    return (.committed(existing.credential), true)
                case .failure(let reason):
                    return (.keychainWriteFailed(reason: reason), false)
                }
            }
            return (.committed(existing.credential), false)
        }

        cacheVersionCounter &+= 1
        let nextVersion = cacheVersionCounter

        if persistToKeychain {
            switch persistCredentialToKeychain(
                credential,
                keychain: keychain,
                service: service,
                account: account
            ) {
            case .success:
                refreshedTokens[stableCacheKey] = CachedEntry(
                    version: nextVersion,
                    credential: credential,
                    needsKeychainPersist: false
                )
                return (.committed(credential), true)
            case .failure(let reason):
                // Retain the rotated/refreshed credential in memory marked pending persistence so a retry
                // once Keychain unlocks can persist it, while surfacing the persistence failure honestly.
                refreshedTokens[stableCacheKey] = CachedEntry(
                    version: nextVersion,
                    credential: credential,
                    needsKeychainPersist: true
                )
                return (.keychainWriteFailed(reason: reason), false)
            }
        }

        refreshedTokens[stableCacheKey] = CachedEntry(
            version: nextVersion,
            credential: credential,
            needsKeychainPersist: false
        )
        return (.committed(credential), false)
    }

    private func shouldKeepExistingWinner(
        existing: CachedEntry,
        candidate: GeminiOAuthCredential,
        expectedBaseVersion: UInt64
    ) -> Bool {
        if let existingExpiry = existing.credential.expiryDate,
           let candidateExpiry = candidate.expiryDate {
            if existingExpiry > candidateExpiry {
                return true
            }
            if existingExpiry == candidateExpiry && existing.version > expectedBaseVersion {
                return true
            }
            return false
        }
        return existing.version > expectedBaseVersion && existing.credential.expiryDate != nil && candidate.expiryDate == nil
    }

    private enum KeychainPersistResult {
        case success
        case failure(String)
    }

    private func persistCredentialToKeychain(
        _ credential: GeminiOAuthCredential,
        keychain: (any KeychainReading)?,
        service: String,
        account: String
    ) -> KeychainPersistResult {
        guard let writableKeychain = keychain as? any KeychainStoring else {
            return .failure("Keychain storage unavailable")
        }
        guard let encoded = credential.encode() else {
            return .failure("encoding failed")
        }
        do {
            try writableKeychain.writeGenericPassword(encoded, service: service, account: account)
            return .success
        } catch let error as KeychainStoreError {
            return .failure(error.shortDescription)
        } catch {
            return .failure("Keychain write failed")
        }
    }

    private func cancelAllInFlightRefreshes() {
        let flights = inFlightRefreshes.values
        inFlightRefreshes.removeAll()
        for flight in flights {
            flight.task.cancel()
        }
    }

    private nonisolated func awaitCoalescedTask(
        _ task: Task<RefreshCommitOutcome, Never>
    ) async -> RefreshCommitOutcome {
        final class WaitBox: @unchecked Sendable {
            private let lock = NSLock()
            private var continuation: CheckedContinuation<RefreshCommitOutcome, Never>?
            private var resolved = false

            func install(_ cont: CheckedContinuation<RefreshCommitOutcome, Never>) -> Bool {
                lock.lock()
                defer { lock.unlock() }
                if resolved { return false }
                continuation = cont
                return true
            }

            func resolve(_ outcome: RefreshCommitOutcome) {
                lock.lock()
                guard !resolved else {
                    lock.unlock()
                    return
                }
                resolved = true
                let cont = continuation
                continuation = nil
                lock.unlock()
                cont?.resume(returning: outcome)
            }
        }

        let box = WaitBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: .stale)
                    return
                }
                if box.install(continuation) {
                    Task {
                        let outcome = await task.value
                        box.resolve(outcome)
                    }
                } else {
                    continuation.resume(returning: .stale)
                }
            }
        } onCancel: {
            box.resolve(.stale)
        }
    }
}
