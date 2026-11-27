import Foundation

/// Live usage limit provider for Gemini using the Gemini CLI Google OAuth login (`~/.gemini/oauth_creds.json`)
/// and Google's Code Assist quota endpoints (`loadCodeAssist` + `retrieveUserQuota`).
/// Never writes or refreshes `~/.gemini/oauth_creds.json`.
public struct GeminiUsageProvider: DiagnosableUsageProvider, Sendable {
    public static let defaultLoadCodeAssistEndpoint = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    public static let defaultQuotaEndpoint = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!
    public static let loginPageURL = URL(string: "https://gemini.google.com")!
    public static let connectedSourceLabel = "Using the Gemini CLI login on this Mac"

    public let provider: ProviderID = .gemini

    private let fileReader: any LocalFileReader
    private let httpTransport: any HTTPTransport
    private let disableStore: any ProviderDisableStoring
    private let urlOpener: any URLOpening
    private let oauthCredsURL: URL
    private let loadCodeAssistEndpoint: URL
    private let quotaEndpoint: URL?
    private let requestTimeout: TimeInterval
    private let clock: @Sendable () -> Date
    private let timeZone: TimeZone

    public init(
        fileReader: any LocalFileReader = SystemLocalFileReader(),
        httpTransport: any HTTPTransport = URLSessionHTTPTransport(),
        disableStore: any ProviderDisableStoring = UserDefaultsProviderDisableStore(),
        urlOpener: any URLOpening = NoOpURLOpener(),
        oauthCredsURL: URL = GeminiUsageProvider.defaultOAuthCredsURL(),
        loadCodeAssistEndpoint: URL = GeminiUsageProvider.defaultLoadCodeAssistEndpoint,
        quotaEndpoint: URL? = nil,
        requestTimeout: TimeInterval = URLSessionHTTPTransport.defaultTimeout,
        clock: @escaping @Sendable () -> Date = { Date() },
        timeZone: TimeZone = .current
    ) {
        self.fileReader = fileReader
        self.httpTransport = httpTransport
        self.disableStore = disableStore
        self.urlOpener = urlOpener
        self.oauthCredsURL = oauthCredsURL
        self.loadCodeAssistEndpoint = loadCodeAssistEndpoint
        self.quotaEndpoint = quotaEndpoint
        self.requestTimeout = requestTimeout
        self.clock = clock
        self.timeZone = timeZone
    }

    public static func defaultOAuthCredsURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".gemini/oauth_creds.json", isDirectory: false)
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

        let credsData: Data?
        do {
            credsData = try fileReader.readFile(at: oauthCredsURL)
        } catch let error as LocalFileReaderError {
            return ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: provider,
                    plan: "",
                    connectionState: .unsupported,
                    limits: [],
                    connectedVia: error.shortReason,
                    updatedAt: now
                ),
                diagnostic: ProviderFetchDiagnostic(
                    shortReason: error.shortReason,
                    isTransientError: true
                )
            )
        } catch {
            return ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: provider,
                    plan: "",
                    connectionState: .unsupported,
                    limits: [],
                    connectedVia: "Unable to read Gemini CLI credentials",
                    updatedAt: now
                ),
                diagnostic: ProviderFetchDiagnostic(
                    shortReason: "Unable to read Gemini CLI credentials",
                    isTransientError: true
                )
            )
        }

        guard let credsData else {
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

        guard let creds = parseOAuthCreds(credsData) else {
            let shapes = captureShape
                ? [JSONShapeFormatter.format(data: credsData, source: "local:oauth_creds.json", provider: provider)]
                : []
            return ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: provider,
                    plan: "",
                    connectionState: .unsupported,
                    limits: [],
                    connectedVia: "Unexpected Gemini CLI credential format",
                    updatedAt: now
                ),
                diagnostic: ProviderFetchDiagnostic(shortReason: "Unexpected Gemini CLI credential format"),
                payloadShapes: shapes
            )
        }

        var secrets = [creds.accessToken]
        if let refreshToken = creds.refreshToken {
            secrets.append(refreshToken)
        }

        // Production default has no verified live quota endpoint -> honest `.unsupported` when a local login is detected.
        guard let quotaEndpoint else {
            let localShapes = captureShape
                ? [JSONShapeFormatter.format(data: credsData, source: "local:oauth_creds.json", secrets: secrets, provider: provider)]
                : []
            return ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: provider,
                    plan: "",
                    connectionState: .unsupported,
                    limits: [],
                    connectedVia: "Not yet supported — Gemini CLI login detected on this Mac",
                    updatedAt: now
                ),
                diagnostic: ProviderFetchDiagnostic(shortReason: "Gemini quota API is not yet verified"),
                payloadShapes: localShapes
            )
        }

        if let expiry = creds.expiryDate, expiry <= now {
            return ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: provider,
                    plan: "",
                    connectionState: .expired,
                    limits: [],
                    connectedVia: "Gemini CLI login expired — reconnect in Gemini CLI",
                    updatedAt: now
                ),
                diagnostic: ProviderFetchDiagnostic(shortReason: "OAuth token expired")
            )
        }

        var capturedShapes: [ProviderPayloadShape] = []

        // Step 1: Best-effort loadCodeAssist for project ID & tier name.
        var projectID: String?
        var plan = ""
        do {
            var loadRequest = URLRequest(url: loadCodeAssistEndpoint)
            loadRequest.httpMethod = "POST"
            loadRequest.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
            loadRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            loadRequest.setValue("application/json", forHTTPHeaderField: "Accept")
            loadRequest.httpBody = Data("{\"metadata\":{\"ideType\":\"IDE_UNSPECIFIED\",\"platform\":\"PLATFORM_UNSPECIFIED\",\"pluginType\":\"GEMINI\"}}".utf8)

            let loadResponse = try await httpTransport.send(loadRequest, timeout: requestTimeout)
            if captureShape {
                capturedShapes.append(
                    JSONShapeFormatter.format(
                        data: loadResponse.body,
                        source: "http:loadCodeAssist",
                        httpStatus: loadResponse.statusCode,
                        secrets: secrets,
                        provider: provider
                    )
                )
            }
            if loadResponse.statusCode == 401 || loadResponse.statusCode == 403 {
                return ProviderFetchResult(
                    snapshot: ProviderSnapshot(
                        provider: provider,
                        plan: "",
                        connectionState: .expired,
                        limits: [],
                        connectedVia: "Gemini CLI login expired — reconnect in Gemini CLI",
                        updatedAt: now
                    ),
                    diagnostic: ProviderFetchDiagnostic(
                        httpStatus: loadResponse.statusCode,
                        shortReason: "HTTP \(loadResponse.statusCode)"
                    ),
                    payloadShapes: capturedShapes
                )
            }
            if loadResponse.statusCode == 200,
               let parsed = parseLoadCodeAssist(loadResponse.body, secrets: secrets) {
                projectID = parsed.project
                plan = parsed.plan
            }
        } catch let error as LiveProviderTransportError {
            if captureShape {
                capturedShapes.append(
                    ProviderPayloadShape(source: "http:loadCodeAssist", httpStatus: nil, lines: ["(request failed: \(error.shortReason))"])
                )
            }
            return ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: provider,
                    plan: "",
                    connectionState: .unsupported,
                    limits: [],
                    connectedVia: error.shortReason,
                    updatedAt: now
                ),
                diagnostic: ProviderFetchDiagnostic(
                    shortReason: error.shortReason,
                    isTransientError: true
                ),
                payloadShapes: capturedShapes
            )
        } catch {
            if captureShape {
                capturedShapes.append(
                    ProviderPayloadShape(source: "http:loadCodeAssist", httpStatus: nil, lines: ["(request failed: Network request failed)"])
                )
            }
            return ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: provider,
                    plan: "",
                    connectionState: .unsupported,
                    limits: [],
                    connectedVia: "Network request failed",
                    updatedAt: now
                ),
                diagnostic: ProviderFetchDiagnostic(
                    shortReason: "Network request failed",
                    isTransientError: true
                ),
                payloadShapes: capturedShapes
            )
        }

        // Step 2: retrieveUserQuota
        var quotaRequest = URLRequest(url: quotaEndpoint)
        quotaRequest.httpMethod = "POST"
        quotaRequest.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        quotaRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        quotaRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        if let projectID, let body = try? JSONSerialization.data(withJSONObject: ["project": projectID]) {
            quotaRequest.httpBody = body
        } else {
            quotaRequest.httpBody = Data("{}".utf8)
        }

        let quotaResponse: HTTPResponseData
        do {
            quotaResponse = try await httpTransport.send(quotaRequest, timeout: requestTimeout)
        } catch let error as LiveProviderTransportError {
            if captureShape {
                capturedShapes.append(
                    ProviderPayloadShape(source: "http:retrieveUserQuota", httpStatus: nil, lines: ["(request failed: \(error.shortReason))"])
                )
            }
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
                payloadShapes: capturedShapes
            )
        } catch {
            if captureShape {
                capturedShapes.append(
                    ProviderPayloadShape(source: "http:retrieveUserQuota", httpStatus: nil, lines: ["(request failed: Network request failed)"])
                )
            }
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
                payloadShapes: capturedShapes
            )
        }

        if captureShape {
            capturedShapes.append(
                JSONShapeFormatter.format(
                    data: quotaResponse.body,
                    source: "http:retrieveUserQuota",
                    httpStatus: quotaResponse.statusCode,
                    secrets: secrets,
                    provider: provider
                )
            )
        }

        switch quotaResponse.statusCode {
        case 200:
            let parsed = parseQuotaResponse(quotaResponse.body, now: now)
            guard let parsed, !parsed.limits.isEmpty else {
                return ProviderFetchResult(
                    snapshot: ProviderSnapshot(
                        provider: provider,
                        plan: plan,
                        connectionState: .unsupported,
                        limits: [],
                        connectedVia: "Unexpected Gemini quota response format",
                        updatedAt: now
                    ),
                    diagnostic: ProviderFetchDiagnostic(
                        httpStatus: 200,
                        shortReason: "Unexpected Gemini quota response format",
                        warnings: parsed?.warnings ?? []
                    ),
                    payloadShapes: capturedShapes
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
                payloadShapes: capturedShapes
            )

        case 401, 403:
            return ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: provider,
                    plan: plan,
                    connectionState: .expired,
                    limits: [],
                    connectedVia: "Gemini CLI login expired — reconnect in Gemini CLI",
                    updatedAt: now
                ),
                diagnostic: ProviderFetchDiagnostic(
                    httpStatus: quotaResponse.statusCode,
                    shortReason: "HTTP \(quotaResponse.statusCode)"
                ),
                payloadShapes: capturedShapes
            )

        case 429, 500...599:
            return ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: provider,
                    plan: plan,
                    connectionState: .unsupported,
                    limits: [],
                    connectedVia: "Gemini quota temporarily unavailable (HTTP \(quotaResponse.statusCode))",
                    updatedAt: now
                ),
                diagnostic: ProviderFetchDiagnostic(
                    httpStatus: quotaResponse.statusCode,
                    shortReason: "HTTP \(quotaResponse.statusCode)",
                    isTransientError: true
                ),
                payloadShapes: capturedShapes
            )

        default:
            return ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: provider,
                    plan: plan,
                    connectionState: .unsupported,
                    limits: [],
                    connectedVia: "Gemini quota endpoint unsupported (HTTP \(quotaResponse.statusCode))",
                    updatedAt: now
                ),
                diagnostic: ProviderFetchDiagnostic(
                    httpStatus: quotaResponse.statusCode,
                    shortReason: "HTTP \(quotaResponse.statusCode)"
                ),
                payloadShapes: capturedShapes
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
                connectedVia: "Reconnect in Gemini CLI, then click Reconnect",
                updatedAt: clock()
            )
        case .notConnected, .connecting:
            _ = urlOpener.open(Self.loginPageURL)
            return ProviderSnapshot(
                provider: provider,
                plan: "",
                connectionState: .notConnected,
                limits: [],
                connectedVia: "Sign in with Gemini CLI, then click Sign in",
                updatedAt: clock()
            )
        }
    }

    public func signOut() async throws -> ProviderSnapshot {
        disableStore.setDisabled(true, for: provider)
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

    private struct OAuthCreds {
        let accessToken: String
        let refreshToken: String?
        let expiryDate: Date?
    }

    private func parseOAuthCreds(_ data: Data) -> OAuthCreds? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = StrictJSON.string(object["access_token"]) else {
            return nil
        }
        let refreshToken = StrictJSON.string(object["refresh_token"])
        let expiry = StrictJSON.timestamp(object["expiry_date"])
            ?? StrictJSON.timestamp(object["expires_at"])
        return OAuthCreds(accessToken: token, refreshToken: refreshToken, expiryDate: expiry)
    }

    private func parseLoadCodeAssist(_ data: Data, secrets: [String]) -> (project: String?, plan: String)? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let project = StrictJSON.string(object["cloudaicompanionProject"])
        let paidTier = object["paidTier"] as? [String: Any]
        let currentTier = object["currentTier"] as? [String: Any]
        let plan = Self.formatPlan(
            name: paidTier.flatMap { StrictJSON.string($0["name"]) } ?? currentTier.flatMap { StrictJSON.string($0["name"]) },
            tierID: paidTier.flatMap { StrictJSON.string($0["id"]) } ?? currentTier.flatMap { StrictJSON.string($0["id"]) }
        )
        return (project, SecretRedactor.sanitize(plan, secrets: secrets, maxLength: 40))
    }

    private static func formatPlan(name: String?, tierID: String?) -> String {
        for candidate in [name, tierID].compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }) {
            switch candidate {
            case "google ai pro", "standard-tier", "standard", "pro":
                return "Google AI Pro"
            case "google ai ultra", "ultra-tier", "ultra":
                return "Google AI Ultra"
            case "google one ai premium":
                return "Google One AI Premium"
            case "free-tier", "legacy-tier", "free":
                return "Free"
            case "enterprise-tier", "enterprise":
                return "Enterprise"
            default:
                continue
            }
        }
        return ""
    }

    private struct QuotaBucket {
        let remainingFraction: Double
        let resetTime: Date?
        let tokenType: String?
    }

    private func parseQuotaResponse(_ data: Data, now: Date) -> (limits: [UsageLimit], warnings: [String])? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let rawBucketsValue = object["buckets"], !(rawBucketsValue is NSNull) else {
            return ([], [])
        }
        guard let rawBuckets = rawBucketsValue as? [Any] else {
            return ([], ["buckets: present but not parseable"])
        }

        var parsed: [QuotaBucket] = []
        var warnings: [String] = []
        for (index, rawEntry) in rawBuckets.enumerated() {
            if rawEntry is NSNull {
                continue
            }
            guard let entry = rawEntry as? [String: Any] else {
                warnings.append("buckets[\(index)]: present but not parseable")
                continue
            }
            guard let remaining = StrictJSON.double(entry["remainingFraction"]),
                  remaining >= 0.0,
                  remaining <= 1.0 else {
                warnings.append("buckets[\(index)].remainingFraction: present but not parseable")
                continue
            }
            let resetTime = StrictJSON.timestamp(entry["resetTime"])
            let tokenType = StrictJSON.string(entry["tokenType"])
            parsed.append(QuotaBucket(remainingFraction: remaining, resetTime: resetTime, tokenType: tokenType))
        }

        guard !parsed.isEmpty else {
            return ([], warnings)
        }

        let requestBuckets = parsed.filter { $0.tokenType?.uppercased() == "REQUESTS" }
        guard let fullest = requestBuckets.min(by: { $0.remainingFraction < $1.remainingFraction }) else {
            warnings.append("buckets: no REQUESTS quota bucket found")
            return ([], warnings)
        }

        let percentUsed = Int(min(100.0, max(0.0, (1.0 - fullest.remainingFraction) * 100.0)).rounded())
        let resetText = ResetTimeFormatter.formatResetText(resetsAt: fullest.resetTime, now: now, timeZone: timeZone)

        return (
            [
                UsageLimit(
                    id: "gemini-daily",
                    name: "Daily requests",
                    shortName: "Daily requests",
                    percentUsed: percentUsed,
                    resetText: resetText,
                    resetsAt: fullest.resetTime
                )
            ],
            warnings
        )
    }
}
