import Foundation

/// Live usage limit provider for OpenCode (`~/.local/share/opencode/auth.json`, respecting `XDG_DATA_HOME`).
/// Uses the documented OpenCode Go usage endpoint (`GET https://opencode.ai/inference/go/v1/usage`) with
/// the local `opencode-go` credential to report 5-hour rolling, weekly, and monthly meters.
/// Legacy Zen-only logins (`opencode`, `opencode-zen`, `zen`) are detected as `.unsupported` without
/// making network requests; unrelated third-party provider keys are ignored.
public struct OpenCodeUsageProvider: DiagnosableUsageProvider, Sendable {
    public static let defaultUsageEndpoint = URL(string: "https://opencode.ai/inference/go/v1/usage")!
    public static let loginPageURL = URL(string: "https://opencode.ai")!
    public static let connectedSourceLabel = "Using the OpenCode Go login on this Mac"

    public let provider: ProviderID = .opencode

    private let fileReader: any LocalFileReader
    private let httpTransport: any HTTPTransport
    private let disableStore: any ProviderDisableStoring
    private let urlOpener: any URLOpening
    private let authFileURL: URL
    private let usageEndpoint: URL
    private let requestTimeout: TimeInterval
    private let clock: @Sendable () -> Date
    private let timeZone: TimeZone

    public init(
        fileReader: any LocalFileReader = SystemLocalFileReader(),
        httpTransport: any HTTPTransport = URLSessionHTTPTransport(),
        disableStore: any ProviderDisableStoring = UserDefaultsProviderDisableStore(),
        urlOpener: any URLOpening = NoOpURLOpener(),
        authFileURL: URL = OpenCodeUsageProvider.defaultAuthFileURL(),
        usageEndpoint: URL = OpenCodeUsageProvider.defaultUsageEndpoint,
        requestTimeout: TimeInterval = URLSessionHTTPTransport.defaultTimeout,
        clock: @escaping @Sendable () -> Date = { Date() },
        timeZone: TimeZone = .current
    ) {
        self.fileReader = fileReader
        self.httpTransport = httpTransport
        self.disableStore = disableStore
        self.urlOpener = urlOpener
        self.authFileURL = authFileURL
        self.usageEndpoint = usageEndpoint
        self.requestTimeout = requestTimeout
        self.clock = clock
        self.timeZone = timeZone
    }

    public static func defaultAuthFileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory()
    ) -> URL {
        if let rawXDG = environment["XDG_DATA_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawXDG.isEmpty,
           rawXDG.hasPrefix("/") {
            return URL(fileURLWithPath: rawXDG, isDirectory: true)
                .appendingPathComponent("opencode/auth.json", isDirectory: false)
        }
        return URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent(".local/share/opencode/auth.json", isDirectory: false)
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

        let authData: Data?
        do {
            authData = try fileReader.readFile(at: authFileURL)
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
                    connectedVia: "Unable to read OpenCode credentials",
                    updatedAt: now
                ),
                diagnostic: ProviderFetchDiagnostic(
                    shortReason: "Unable to read OpenCode credentials",
                    isTransientError: true
                )
            )
        }

        guard let authData else {
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

        let parsedAuth = parseAuthFile(authData)
        switch parsedAuth {
        case .missing(let secrets):
            let shapes = captureShape
                ? [JSONShapeFormatter.format(data: authData, source: "local:auth.json", secrets: secrets, provider: provider)]
                : []
            return ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: provider,
                    plan: "",
                    connectionState: .notConnected,
                    limits: [],
                    connectedVia: "Not connected",
                    updatedAt: now
                ),
                payloadShapes: shapes
            )

        case .malformed(let secrets):
            let shapes = captureShape
                ? [JSONShapeFormatter.format(data: authData, source: "local:auth.json", secrets: secrets, provider: provider)]
                : []
            return ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: provider,
                    plan: "",
                    connectionState: .unsupported,
                    limits: [],
                    connectedVia: "Unexpected OpenCode auth file format",
                    updatedAt: now
                ),
                diagnostic: ProviderFetchDiagnostic(shortReason: "Unexpected OpenCode auth file format"),
                payloadShapes: shapes
            )

        case .refreshOnly(let secrets):
            let shapes = captureShape
                ? [JSONShapeFormatter.format(data: authData, source: "local:auth.json", secrets: secrets, provider: provider)]
                : []
            return ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: provider,
                    plan: "Go",
                    connectionState: .unsupported,
                    limits: [],
                    connectedVia: "OpenCode Go credentials missing API key or access token",
                    updatedAt: now
                ),
                diagnostic: ProviderFetchDiagnostic(shortReason: "OpenCode Go refresh-only credentials cannot query usage"),
                payloadShapes: shapes
            )

        case .legacyZen(let secrets):
            let shapes = captureShape
                ? [JSONShapeFormatter.format(data: authData, source: "local:auth.json", secrets: secrets, provider: provider)]
                : []
            return ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: provider,
                    plan: "",
                    connectionState: .unsupported,
                    limits: [],
                    connectedVia: "Not yet supported — OpenCode Zen login detected on this Mac",
                    updatedAt: now
                ),
                diagnostic: ProviderFetchDiagnostic(shortReason: "OpenCode Zen usage limits are not yet supported"),
                payloadShapes: shapes
            )

        case .goCredential(let token, let expiresAt, let secrets):
            var capturedShapes = captureShape
                ? [JSONShapeFormatter.format(data: authData, source: "local:auth.json", secrets: secrets, provider: provider)]
                : []

            if let expiresAt, expiresAt <= now {
                return ProviderFetchResult(
                    snapshot: ProviderSnapshot(
                        provider: provider,
                        plan: "Go",
                        connectionState: .expired,
                        limits: [],
                        connectedVia: "OpenCode Go login expired — reconnect in OpenCode",
                        updatedAt: now
                    ),
                    diagnostic: ProviderFetchDiagnostic(shortReason: "OpenCode Go OAuth token expired"),
                    payloadShapes: capturedShapes
                )
            }

            var request = URLRequest(url: usageEndpoint)
            request.httpMethod = "GET"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let response: HTTPResponseData
            do {
                response = try await httpTransport.send(request, timeout: requestTimeout)
            } catch let error as LiveProviderTransportError {
                if captureShape {
                    capturedShapes.append(
                        ProviderPayloadShape(source: "http:usage", httpStatus: nil, lines: ["(request failed: \(error.shortReason))"])
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
                        ProviderPayloadShape(source: "http:usage", httpStatus: nil, lines: ["(request failed: Network request failed)"])
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

            if captureShape {
                capturedShapes.append(
                    JSONShapeFormatter.format(
                        data: response.body,
                        source: "http:usage",
                        httpStatus: response.statusCode,
                        secrets: secrets,
                        provider: provider
                    )
                )
            }

            switch response.statusCode {
            case 200:
                let parsed = parseGoUsageResponse(response.body, now: now)
                guard !parsed.limits.isEmpty else {
                    return ProviderFetchResult(
                        snapshot: ProviderSnapshot(
                            provider: provider,
                            plan: "",
                            connectionState: .unsupported,
                            limits: [],
                            connectedVia: "Unexpected OpenCode Go usage response format",
                            updatedAt: now
                        ),
                        diagnostic: ProviderFetchDiagnostic(
                            httpStatus: 200,
                            shortReason: "Unexpected OpenCode Go usage response format",
                            warnings: parsed.warnings
                        ),
                        payloadShapes: capturedShapes
                    )
                }
                return ProviderFetchResult(
                    snapshot: ProviderSnapshot(
                        provider: provider,
                        plan: "Go",
                        connectionState: .connected,
                        limits: parsed.limits,
                        connectedVia: Self.connectedSourceLabel,
                        updatedAt: now
                    ),
                    diagnostic: ProviderFetchDiagnostic(httpStatus: 200, warnings: parsed.warnings),
                    payloadShapes: capturedShapes
                )

            case 401:
                return ProviderFetchResult(
                    snapshot: ProviderSnapshot(
                        provider: provider,
                        plan: "Go",
                        connectionState: .expired,
                        limits: [],
                        connectedVia: "OpenCode Go API key invalid — reconnect in OpenCode",
                        updatedAt: now
                    ),
                    diagnostic: ProviderFetchDiagnostic(
                        httpStatus: 401,
                        shortReason: "HTTP 401"
                    ),
                    payloadShapes: capturedShapes
                )

            case 403:
                return ProviderFetchResult(
                    snapshot: ProviderSnapshot(
                        provider: provider,
                        plan: "",
                        connectionState: .unsupported,
                        limits: [],
                        connectedVia: "OpenCode Go subscription required for this API key",
                        updatedAt: now
                    ),
                    diagnostic: ProviderFetchDiagnostic(
                        httpStatus: 403,
                        shortReason: "HTTP 403 — OpenCode Go entitlement required"
                    ),
                    payloadShapes: capturedShapes
                )

            case 429, 500...599:
                return ProviderFetchResult(
                    snapshot: ProviderSnapshot(
                        provider: provider,
                        plan: "",
                        connectionState: .unsupported,
                        limits: [],
                        connectedVia: "OpenCode Go usage temporarily unavailable (HTTP \(response.statusCode))",
                        updatedAt: now
                    ),
                    diagnostic: ProviderFetchDiagnostic(
                        httpStatus: response.statusCode,
                        shortReason: "HTTP \(response.statusCode)",
                        isTransientError: true
                    ),
                    payloadShapes: capturedShapes
                )

            default:
                return ProviderFetchResult(
                    snapshot: ProviderSnapshot(
                        provider: provider,
                        plan: "",
                        connectionState: .unsupported,
                        limits: [],
                        connectedVia: "OpenCode Go usage endpoint unsupported (HTTP \(response.statusCode))",
                        updatedAt: now
                    ),
                    diagnostic: ProviderFetchDiagnostic(
                        httpStatus: response.statusCode,
                        shortReason: "HTTP \(response.statusCode)"
                    ),
                    payloadShapes: capturedShapes
                )
            }
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
                connectedVia: "Reconnect in OpenCode, then click Reconnect",
                updatedAt: clock()
            )
        case .notConnected, .connecting:
            _ = urlOpener.open(Self.loginPageURL)
            return ProviderSnapshot(
                provider: provider,
                plan: "",
                connectionState: .notConnected,
                limits: [],
                connectedVia: "Sign in with OpenCode, then click Sign in",
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

    // MARK: - Auth Parsing

    private enum AuthParseResult {
        case missing(secrets: [String])
        case malformed(secrets: [String])
        case refreshOnly(secrets: [String])
        case legacyZen(secrets: [String])
        case goCredential(token: String, expiresAt: Date?, secrets: [String])
    }

    private static let goSubscriptionKey = "opencode-go"
    private static let legacyZenKeys = ["opencode", "opencode-zen", "zen"]
    private static let credentialFieldKeys = [
        "key", "api_key", "apiKey",
        "access", "access_token", "accessToken", "token",
        "refresh", "refresh_token", "refreshToken"
    ]

    private func parseAuthFile(_ data: Data) -> AuthParseResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .malformed(secrets: [])
        }

        let allSecrets = Self.collectSecrets(from: root)
        var sawMalformedRecognized = false
        var sawRefreshOnlyGo = false

        // 1. Prefer `opencode-go` over legacy `opencode` / `opencode-zen` / `zen` entries.
        if let rawGoEntry = root[Self.goSubscriptionKey], !(rawGoEntry is NSNull) {
            if let entry = rawGoEntry as? [String: Any] {
                if let apiKey = StrictJSON.string(entry["key"])
                    ?? StrictJSON.string(entry["api_key"])
                    ?? StrictJSON.string(entry["apiKey"]) {
                    return .goCredential(token: apiKey, expiresAt: nil, secrets: allSecrets)
                }

                if let access = StrictJSON.string(entry["access"])
                    ?? StrictJSON.string(entry["access_token"])
                    ?? StrictJSON.string(entry["accessToken"])
                    ?? StrictJSON.string(entry["token"]) {
                    let expires = StrictJSON.timestamp(entry["expires"])
                        ?? StrictJSON.timestamp(entry["expires_at"])
                        ?? StrictJSON.timestamp(entry["expiresAt"])
                        ?? StrictJSON.timestamp(entry["expiry_date"])
                        ?? JWTExpiryInspector.expirationDate(fromJWT: access)
                    return .goCredential(token: access, expiresAt: expires, secrets: allSecrets)
                }

                // Never send refresh credentials to the usage API.
                if StrictJSON.string(entry["refresh"]) != nil
                    || StrictJSON.string(entry["refresh_token"]) != nil
                    || StrictJSON.string(entry["refreshToken"]) != nil {
                    sawRefreshOnlyGo = true
                } else if Self.hasNonStringCredentialField(in: entry) {
                    sawMalformedRecognized = true
                }
            } else {
                sawMalformedRecognized = true
            }
        }

        if sawRefreshOnlyGo {
            return .refreshOnly(secrets: allSecrets)
        }

        // 2. Detect legacy Zen entries (`opencode`, `opencode-zen`, `zen`) as unsupported without making HTTP calls.
        for key in Self.legacyZenKeys {
            guard let rawEntry = root[key], !(rawEntry is NSNull) else { continue }
            guard let entry = rawEntry as? [String: Any] else {
                sawMalformedRecognized = true
                continue
            }

            if Self.hasAnyCredentialString(in: entry) {
                return .legacyZen(secrets: allSecrets)
            }
            if Self.hasNonStringCredentialField(in: entry) {
                sawMalformedRecognized = true
            }
        }

        return sawMalformedRecognized
            ? .malformed(secrets: allSecrets)
            : .missing(secrets: allSecrets)
    }

    private static func collectSecrets(from root: [String: Any]) -> [String] {
        var secrets: [String] = []
        for value in root.values {
            guard let entry = value as? [String: Any] else { continue }
            for field in credentialFieldKeys {
                if let secret = StrictJSON.string(entry[field]) {
                    secrets.append(secret)
                }
            }
        }
        return secrets
    }

    private static func hasAnyCredentialString(in entry: [String: Any]) -> Bool {
        for field in credentialFieldKeys {
            if StrictJSON.string(entry[field]) != nil {
                return true
            }
        }
        return false
    }

    private static func hasNonStringCredentialField(in entry: [String: Any]) -> Bool {
        for field in credentialFieldKeys {
            if let raw = entry[field], !(raw is NSNull), !(raw is String) {
                return true
            }
        }
        return false
    }

    // MARK: - Go Usage Response Parsing

    private struct MeterSpec {
        let jsonKey: String
        let limitID: String
        let name: String
        let shortName: String
    }

    private static let goMeterSpecs: [MeterSpec] = [
        MeterSpec(jsonKey: "rolling", limitID: "opencode-rolling", name: "5-hour", shortName: "5-hour"),
        MeterSpec(jsonKey: "weekly", limitID: "opencode-weekly", name: "Weekly", shortName: "Weekly"),
        MeterSpec(jsonKey: "monthly", limitID: "opencode-monthly", name: "Monthly", shortName: "Monthly")
    ]

    private enum GoMeterStatus: String {
        case ok = "ok"
        case rateLimited = "rate-limited"
    }

    private func parseGoUsageResponse(
        _ data: Data,
        now: Date
    ) -> (limits: [UsageLimit], warnings: [String]) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ([], [])
        }

        var warnings: [String] = []
        guard let rawUsage = root["usage"], !(rawUsage is NSNull) else {
            return ([], [])
        }
        guard let usage = rawUsage as? [String: Any] else {
            warnings.append("usage: present but not parseable")
            return ([], warnings)
        }

        var limits: [UsageLimit] = []
        for spec in Self.goMeterSpecs {
            guard let rawMeter = usage[spec.jsonKey], !(rawMeter is NSNull) else {
                continue
            }
            guard let meter = rawMeter as? [String: Any] else {
                warnings.append("usage.\(spec.jsonKey): present but not parseable")
                continue
            }

            if let limit = parseGoMeter(meter, spec: spec, now: now, warnings: &warnings) {
                limits.append(limit)
            }
        }

        return (limits, warnings)
    }

    private func parseGoMeter(
        _ meter: [String: Any],
        spec: MeterSpec,
        now: Date,
        warnings: inout [String]
    ) -> UsageLimit? {
        let prefix = "usage.\(spec.jsonKey)"
        var isValid = true

        // 1. Validate status: strictly "ok" or "rate-limited".
        let parsedStatus: GoMeterStatus?
        if let rawStatus = meter["status"] as? String,
           let status = GoMeterStatus(rawValue: rawStatus) {
            parsedStatus = status
        } else {
            parsedStatus = nil
            isValid = false
            warnings.append("\(prefix).status: present but not parseable")
        }

        // 2. Validate percent: strictly integer 0...100 (rejects booleans, strings, decimals, out-of-range).
        let parsedPercent: Int?
        if let percent = StrictJSON.integer(meter["percent"]), (0...100).contains(percent) {
            parsedPercent = percent
        } else {
            parsedPercent = nil
            isValid = false
            warnings.append("\(prefix).percent: present but not parseable")
        }

        // 3. Validate resetsAt: ISO-8601 string when present and non-null.
        let parsedResetsAt: Date?
        if let rawResetsAt = meter["resetsAt"], !(rawResetsAt is NSNull) {
            if let date = StrictJSON.iso8601Timestamp(rawResetsAt) {
                parsedResetsAt = date
            } else {
                parsedResetsAt = nil
                isValid = false
                warnings.append("\(prefix).resetsAt: present but not parseable")
            }
        } else {
            parsedResetsAt = nil
        }

        guard isValid, let status = parsedStatus, let percent = parsedPercent else {
            return nil
        }

        let baseResetText = ResetTimeFormatter.formatResetText(resetsAt: parsedResetsAt, now: now, timeZone: timeZone)
        let resetText: String
        switch status {
        case .ok:
            resetText = baseResetText
        case .rateLimited:
            resetText = "Rate limited · \(baseResetText)"
        }

        return UsageLimit(
            id: spec.limitID,
            name: spec.name,
            shortName: spec.shortName,
            percentUsed: percent,
            resetText: resetText,
            resetsAt: parsedResetsAt
        )
    }
}
