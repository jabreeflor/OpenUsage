import Foundation

/// Live usage limit provider for Claude using the existing Claude Code OAuth credentials in the macOS Keychain
/// (`service: "Claude Code-credentials"`) and Anthropic's OAuth usage endpoint.
/// Never writes, rotates, or deletes Claude Code's Keychain item.
public struct ClaudeUsageProvider: DiagnosableUsageProvider, Sendable {
    public static let defaultKeychainService = "Claude Code-credentials"
    public static let defaultUsageEndpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let loginPageURL = URL(string: "https://claude.ai")!
    public static let connectedSourceLabel = "Using the Claude Code login on this Mac"
    public static let waitingForKeychainText = "Waiting for Keychain access"

    public let provider: ProviderID = .claude

    private let keychain: any KeychainReading
    private let keychainCoordinator: KeychainLookupCoordinator
    private let httpTransport: any HTTPTransport
    private let disableStore: any ProviderDisableStoring
    private let urlOpener: any URLOpening
    private let keychainService: String
    private let usageEndpoint: URL
    private let requestTimeout: TimeInterval
    private let keychainTimeout: TimeInterval
    private let clock: @Sendable () -> Date
    private let timeZone: TimeZone

    public init(
        keychain: any KeychainReading = SystemKeychainStore(),
        keychainCoordinator: KeychainLookupCoordinator? = nil,
        httpTransport: any HTTPTransport = URLSessionHTTPTransport(),
        disableStore: any ProviderDisableStoring = UserDefaultsProviderDisableStore(),
        urlOpener: any URLOpening = NoOpURLOpener(),
        keychainService: String = ClaudeUsageProvider.defaultKeychainService,
        usageEndpoint: URL = ClaudeUsageProvider.defaultUsageEndpoint,
        requestTimeout: TimeInterval = URLSessionHTTPTransport.defaultTimeout,
        keychainTimeout: TimeInterval? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        timeZone: TimeZone = .current
    ) {
        self.keychain = keychain
        self.keychainCoordinator = keychainCoordinator ?? KeychainCoordinatorRegistry.shared.coordinator(for: keychain)
        self.httpTransport = httpTransport
        self.disableStore = disableStore
        self.urlOpener = urlOpener
        self.keychainService = keychainService
        self.usageEndpoint = usageEndpoint
        self.requestTimeout = requestTimeout
        self.keychainTimeout = keychainTimeout ?? requestTimeout
        self.clock = clock
        self.timeZone = timeZone
    }

    public func fetchResult() async -> ProviderFetchResult {
        await fetchResult(captureShape: false)
    }

    public func fetchResult(captureShape: Bool) async -> ProviderFetchResult {
        let now = clock()
        if disableStore.isDisabled(provider) {
            return ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: provider,
                    plan: "",
                    connectionState: .notConnected,
                    limits: [],
                    connectedVia: "Not connected",
                    updatedAt: now
                )
            )
        }

        let lookupOutcome: KeychainLookupCoordinator.LookupOutcome
        do {
            lookupOutcome = try await keychainCoordinator.readGenericPassword(
                using: keychain,
                service: keychainService,
                timeout: keychainTimeout
            )
        } catch is CancellationError {
            return ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: provider,
                    plan: "",
                    connectionState: .waitingForKeychain,
                    limits: [],
                    connectedVia: Self.waitingForKeychainText,
                    updatedAt: now
                ),
                diagnostic: ProviderFetchDiagnostic(
                    shortReason: "Request cancelled",
                    isTransientError: true
                )
            )
        } catch {
            let shapes = captureShape
                ? [ProviderPayloadShape(source: "local:keychain", lines: ["(read failed: Keychain read failed)"])]
                : []
            return ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: provider,
                    plan: "",
                    connectionState: .unsupported,
                    limits: [],
                    connectedVia: "Keychain read failed",
                    updatedAt: now
                ),
                diagnostic: ProviderFetchDiagnostic(
                    shortReason: "Keychain read failed",
                    isTransientError: true
                ),
                payloadShapes: shapes
            )
        }

        let credentialData: Data?
        switch lookupOutcome {
        case .pending:
            let shapes = captureShape
                ? [ProviderPayloadShape(source: "local:keychain", lines: ["(\(Self.waitingForKeychainText))"])]
                : []
            return ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: provider,
                    plan: "",
                    connectionState: .waitingForKeychain,
                    limits: [],
                    connectedVia: Self.waitingForKeychainText,
                    updatedAt: now
                ),
                diagnostic: ProviderFetchDiagnostic(
                    shortReason: Self.waitingForKeychainText,
                    isTransientError: false
                ),
                payloadShapes: shapes
            )

        case .completed(.success(let data)):
            credentialData = data

        case .completed(.failure(let error as KeychainStoreError)):
            let shapes = captureShape
                ? [ProviderPayloadShape(source: "local:keychain", lines: ["(read failed: \(error.shortDescription))"])]
                : []
            return ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: provider,
                    plan: "",
                    connectionState: .unsupported,
                    limits: [],
                    connectedVia: error.shortDescription,
                    updatedAt: now
                ),
                diagnostic: ProviderFetchDiagnostic(
                    shortReason: error.shortDescription,
                    isTransientError: true
                ),
                payloadShapes: shapes
            )

        case .completed(.failure):
            let shapes = captureShape
                ? [ProviderPayloadShape(source: "local:keychain", lines: ["(read failed: Keychain read failed)"])]
                : []
            return ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: provider,
                    plan: "",
                    connectionState: .unsupported,
                    limits: [],
                    connectedVia: "Keychain read failed",
                    updatedAt: now
                ),
                diagnostic: ProviderFetchDiagnostic(
                    shortReason: "Keychain read failed",
                    isTransientError: true
                ),
                payloadShapes: shapes
            )
        }

        guard let credentialData else {
            return ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: provider,
                    plan: "",
                    connectionState: .notConnected,
                    limits: [],
                    connectedVia: "Not connected",
                    updatedAt: now
                )
            )
        }

        guard let parsedCred = parseCredentials(from: credentialData) else {
            let shapes = captureShape
                ? [JSONShapeFormatter.format(data: credentialData, source: "local:keychain", provider: provider)]
                : []
            return ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: provider,
                    plan: "",
                    connectionState: .unsupported,
                    limits: [],
                    connectedVia: "Unexpected Claude Code credential format",
                    updatedAt: now
                ),
                diagnostic: ProviderFetchDiagnostic(
                    shortReason: "Unexpected Claude Code credential format"
                ),
                payloadShapes: shapes
            )
        }

        var secrets = [parsedCred.accessToken]
        if let refreshToken = parsedCred.refreshToken {
            secrets.append(refreshToken)
        }
        let plan = SecretRedactor.sanitize(parsedCred.plan, secrets: secrets, maxLength: 40)

        if let expiresAt = parsedCred.expiresAt, expiresAt <= now {
            return ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: provider,
                    plan: plan,
                    connectionState: .expired,
                    limits: [],
                    connectedVia: "Claude Code login expired — reconnect in Claude Code",
                    updatedAt: now
                ),
                diagnostic: ProviderFetchDiagnostic(shortReason: "OAuth token expired")
            )
        }

        var request = URLRequest(url: usageEndpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(parsedCred.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response: HTTPResponseData
        do {
            response = try await httpTransport.send(request, timeout: requestTimeout)
        } catch let error as LiveProviderTransportError {
            let shapes = captureShape
                ? [ProviderPayloadShape(source: "http:usage", httpStatus: nil, lines: ["(request failed: \(error.shortReason))"])]
                : []
            return ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: provider,
                    plan: plan,
                    connectionState: .unsupported,
                    limits: [],
                    connectedVia: error.shortReason,
                    updatedAt: now
                ),
                diagnostic: ProviderFetchDiagnostic(
                    shortReason: error.shortReason,
                    isTransientError: true
                ),
                payloadShapes: shapes
            )
        } catch {
            let shapes = captureShape
                ? [ProviderPayloadShape(source: "http:usage", httpStatus: nil, lines: ["(request failed: Network request failed)"])]
                : []
            return ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: provider,
                    plan: plan,
                    connectionState: .unsupported,
                    limits: [],
                    connectedVia: "Network request failed",
                    updatedAt: now
                ),
                diagnostic: ProviderFetchDiagnostic(
                    shortReason: "Network request failed",
                    isTransientError: true
                ),
                payloadShapes: shapes
            )
        }

        let shapes = captureShape
            ? [JSONShapeFormatter.format(data: response.body, source: "http:usage", httpStatus: response.statusCode, secrets: secrets, provider: provider)]
            : []

        switch response.statusCode {
        case 200:
            let parsed = parseUsageResponse(response.body, now: now)
            guard let parsed, !parsed.limits.isEmpty else {
                return ProviderFetchResult(
                    snapshot: ProviderSnapshot(
                        provider: provider,
                        plan: plan,
                        connectionState: .unsupported,
                        limits: [],
                        connectedVia: "Unexpected Claude usage response format",
                        updatedAt: now
                    ),
                    diagnostic: ProviderFetchDiagnostic(
                        httpStatus: 200,
                        shortReason: "Unexpected Claude usage response format",
                        warnings: parsed?.warnings ?? []
                    ),
                    payloadShapes: shapes
                )
            }
            return ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: provider,
                    plan: plan,
                    connectionState: .connected,
                    limits: parsed.limits,
                    connectedVia: Self.connectedSourceLabel,
                    updatedAt: now
                ),
                diagnostic: ProviderFetchDiagnostic(httpStatus: 200, warnings: parsed.warnings),
                payloadShapes: shapes
            )

        case 401, 403:
            return ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: provider,
                    plan: plan,
                    connectionState: .expired,
                    limits: [],
                    connectedVia: "Claude Code login expired — reconnect in Claude Code",
                    updatedAt: now
                ),
                diagnostic: ProviderFetchDiagnostic(
                    httpStatus: response.statusCode,
                    shortReason: "HTTP \(response.statusCode)"
                ),
                payloadShapes: shapes
            )

        case 429, 500...599:
            return ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: provider,
                    plan: plan,
                    connectionState: .unsupported,
                    limits: [],
                    connectedVia: "Claude usage temporarily unavailable (HTTP \(response.statusCode))",
                    updatedAt: now
                ),
                diagnostic: ProviderFetchDiagnostic(
                    httpStatus: response.statusCode,
                    shortReason: "HTTP \(response.statusCode)",
                    isTransientError: true
                ),
                payloadShapes: shapes
            )

        default:
            return ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: provider,
                    plan: plan,
                    connectionState: .unsupported,
                    limits: [],
                    connectedVia: "Claude usage endpoint unsupported (HTTP \(response.statusCode))",
                    updatedAt: now
                ),
                diagnostic: ProviderFetchDiagnostic(
                    httpStatus: response.statusCode,
                    shortReason: "HTTP \(response.statusCode)"
                ),
                payloadShapes: shapes
            )
        }
    }

    public func signIn() async throws -> ProviderSnapshot {
        disableStore.setDisabled(false, for: provider)
        let result = await fetchResult()
        switch result.snapshot.connectionState {
        case .connected, .unsupported, .waitingForKeychain:
            return result.snapshot
        case .expired:
            _ = urlOpener.open(Self.loginPageURL)
            return ProviderSnapshot(
                provider: provider,
                plan: result.snapshot.plan,
                connectionState: .expired,
                limits: [],
                connectedVia: "Reconnect in Claude Code, then click Reconnect",
                updatedAt: clock()
            )
        case .notConnected, .connecting:
            _ = urlOpener.open(Self.loginPageURL)
            return ProviderSnapshot(
                provider: provider,
                plan: "",
                connectionState: .notConnected,
                limits: [],
                connectedVia: "Sign in with Claude Code, then click Sign in",
                updatedAt: clock()
            )
        }
    }

    public func signOut() async throws -> ProviderSnapshot {
        disableStore.setDisabled(true, for: provider)
        await keychainCoordinator.clearCachedResult(forService: keychainService)
        return ProviderSnapshot(
            provider: provider,
            plan: "",
            connectionState: .notConnected,
            limits: [],
            connectedVia: "Not connected",
            updatedAt: clock()
        )
    }

    // MARK: - Parsing

    private struct ParsedCredentials {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date?
        let plan: String
    }

    private func parseCredentials(from data: Data) -> ParsedCredentials? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let oauth = (object["claudeAiOauth"] as? [String: Any]) ?? object
        guard let token = StrictJSON.string(oauth["accessToken"])
            ?? StrictJSON.string(oauth["access_token"]) else {
            return nil
        }

        let refreshToken = StrictJSON.string(oauth["refreshToken"])
            ?? StrictJSON.string(oauth["refresh_token"])

        let expiresAt = StrictJSON.timestamp(oauth["expiresAt"])
            ?? StrictJSON.timestamp(oauth["expires_at"])
            ?? JWTExpiryInspector.expirationDate(fromJWT: token)

        let tier = StrictJSON.string(oauth["rateLimitTier"])
            ?? StrictJSON.string(oauth["rate_limit_tier"])
        let subscription = StrictJSON.string(oauth["subscriptionType"])
            ?? StrictJSON.string(oauth["subscription_type"])
        let plan = Self.formatPlan(tier: tier, subscriptionType: subscription)

        return ParsedCredentials(
            accessToken: token,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            plan: plan
        )
    }

    private static func formatPlan(tier: String?, subscriptionType: String?) -> String {
        if let tier {
            let tokens = Set(
                tier.lowercased()
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { !$0.isEmpty }
            )
            if tokens.contains("max") && tokens.contains("20x") { return "Max 20x" }
            if tokens.contains("max") && tokens.contains("5x") { return "Max 5x" }
            if tokens.contains("20x") { return "Max 20x" }
            if tokens.contains("5x") { return "Max 5x" }
            if tokens.contains("max") { return "Max" }
            if tokens.contains("pro") { return "Pro" }
            if tokens.contains("team") { return "Team" }
            if tokens.contains("enterprise") { return "Enterprise" }
            if tokens.contains("free") { return "Free" }
        }
        if let subscriptionType {
            switch subscriptionType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "max_20x", "max 20x", "max-20x": return "Max 20x"
            case "max_5x", "max 5x", "max-5x": return "Max 5x"
            case "max": return "Max"
            case "pro": return "Pro"
            case "team": return "Team"
            case "enterprise": return "Enterprise"
            case "free": return "Free"
            default: return ""
            }
        }
        return ""
    }

    private func parseUsageResponse(_ data: Data, now: Date) -> (limits: [UsageLimit], warnings: [String])? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let specs: [(key: String, id: String, name: String, shortName: String)] = [
            ("five_hour", "claude-5h", "5-hour session", "5-hour session"),
            ("seven_day", "claude-weekly-all", "Weekly · all models", "Wk · all models"),
            ("seven_day_opus", "claude-weekly-opus", "Weekly · Opus", "Wk · Opus"),
            ("seven_day_sonnet", "claude-weekly-sonnet", "Weekly · Sonnet", "Wk · Sonnet")
        ]

        var limits: [UsageLimit] = []
        var warnings: [String] = []
        for spec in specs {
            guard let rawBucket = object[spec.key], !(rawBucket is NSNull) else {
                continue
            }
            guard let bucket = rawBucket as? [String: Any],
                  let utilization = StrictJSON.double(bucket["utilization"]),
                  utilization >= 0 else {
                warnings.append("\(spec.key): present but not parseable")
                continue
            }
            let resetsAt = StrictJSON.timestamp(bucket["resets_at"])
            let resetText = ResetTimeFormatter.formatResetText(resetsAt: resetsAt, now: now, timeZone: timeZone)
            let clampedPercent = Int(min(100.0, max(0.0, utilization)).rounded())
            limits.append(
                UsageLimit(
                    id: spec.id,
                    name: spec.name,
                    shortName: spec.shortName,
                    percentUsed: clampedPercent,
                    resetText: resetText,
                    resetsAt: resetsAt
                )
            )
        }

        return (limits, warnings)
    }
}
