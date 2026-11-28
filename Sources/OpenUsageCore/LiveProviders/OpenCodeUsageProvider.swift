import Foundation

/// Live usage limit provider for OpenCode (`~/.local/share/opencode/auth.json`).
/// Detects local OpenCode credentials; because OpenCode does not expose a verified credit/subscription usage endpoint,
/// default live runs honestly report `.unsupported` when a local login is present (and `.notConnected` when absent).
/// Supports an injected `usageEndpoint` + `HTTPTransport` for fixture-based tests and future verified API support.
public struct OpenCodeUsageProvider: DiagnosableUsageProvider, Sendable {
    public static let loginPageURL = URL(string: "https://opencode.ai")!
    public static let connectedSourceLabel = "Using the OpenCode login on this Mac"

    public let provider: ProviderID = .opencode

    private let fileReader: any LocalFileReader
    private let httpTransport: any HTTPTransport
    private let disableStore: any ProviderDisableStoring
    private let urlOpener: any URLOpening
    private let authFileURL: URL
    private let usageEndpoint: URL?
    private let requestTimeout: TimeInterval
    private let clock: @Sendable () -> Date
    private let timeZone: TimeZone

    public init(
        fileReader: any LocalFileReader = SystemLocalFileReader(),
        httpTransport: any HTTPTransport = URLSessionHTTPTransport(),
        disableStore: any ProviderDisableStoring = UserDefaultsProviderDisableStore(),
        urlOpener: any URLOpening = NoOpURLOpener(),
        authFileURL: URL = OpenCodeUsageProvider.defaultAuthFileURL(),
        usageEndpoint: URL? = nil,
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

    public static func defaultAuthFileURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
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
        case .missing:
            let shapes = captureShape
                ? [JSONShapeFormatter.format(data: authData, source: "local:auth.json", provider: provider)]
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

        case .malformed:
            let shapes = captureShape
                ? [JSONShapeFormatter.format(data: authData, source: "local:auth.json", provider: provider)]
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

        case .present(let token, let expiresAt):
            let secrets = [token]
            var capturedShapes = captureShape
                ? [JSONShapeFormatter.format(data: authData, source: "local:auth.json", secrets: secrets, provider: provider)]
                : []

            if let expiresAt, expiresAt <= now {
                return ProviderFetchResult(
                    snapshot: ProviderSnapshot(
                        provider: provider,
                        plan: "",
                        connectionState: .expired,
                        limits: [],
                        connectedVia: "OpenCode login expired — reconnect in OpenCode",
                        updatedAt: now
                    ),
                    diagnostic: ProviderFetchDiagnostic(shortReason: "OpenCode OAuth token expired"),
                    payloadShapes: capturedShapes
                )
            }

            // No verified public credit/usage endpoint in live mode -> honest .unsupported state.
            guard let usageEndpoint else {
                return ProviderFetchResult(
                    snapshot: ProviderSnapshot(
                        provider: provider,
                        plan: "",
                        connectionState: .unsupported,
                        limits: [],
                        connectedVia: "Not yet supported — OpenCode login detected on this Mac",
                        updatedAt: now
                    ),
                    diagnostic: ProviderFetchDiagnostic(shortReason: "OpenCode credit API is not yet supported"),
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
                let parsed = parseUsageResponse(response.body, now: now, secrets: secrets)
                guard let limit = parsed.limit else {
                    return ProviderFetchResult(
                        snapshot: ProviderSnapshot(
                            provider: provider,
                            plan: "",
                            connectionState: .unsupported,
                            limits: [],
                            connectedVia: "Unexpected OpenCode usage response format",
                            updatedAt: now
                        ),
                        diagnostic: ProviderFetchDiagnostic(
                            httpStatus: 200,
                            shortReason: "Unexpected OpenCode usage response format",
                            warnings: parsed.warnings
                        ),
                        payloadShapes: capturedShapes
                    )
                }
                return ProviderFetchResult(
                    snapshot: ProviderSnapshot(
                        provider: provider,
                        plan: parsed.plan,
                        connectionState: .connected,
                        limits: [limit],
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
                        plan: "",
                        connectionState: .expired,
                        limits: [],
                        connectedVia: "OpenCode login expired — reconnect in OpenCode",
                        updatedAt: now
                    ),
                    diagnostic: ProviderFetchDiagnostic(
                        httpStatus: response.statusCode,
                        shortReason: "HTTP \(response.statusCode)"
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
                        connectedVia: "OpenCode usage temporarily unavailable (HTTP \(response.statusCode))",
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
                        connectedVia: "OpenCode usage endpoint unsupported (HTTP \(response.statusCode))",
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
                plan: "",
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

    // MARK: - Parsing

    private enum AuthParseResult {
        case missing
        case malformed
        case present(token: String, expiresAt: Date?)
    }

    private static let recognizedSubscriptionKeys = ["opencode", "opencode-go", "opencode-zen", "zen"]

    private func parseAuthFile(_ data: Data) -> AuthParseResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .malformed
        }

        var sawMalformedRecognized = false
        for key in Self.recognizedSubscriptionKeys {
            guard let rawEntry = root[key], !(rawEntry is NSNull) else { continue }
            guard let entry = rawEntry as? [String: Any] else {
                sawMalformedRecognized = true
                continue
            }

            if let apiKey = StrictJSON.string(entry["key"])
                ?? StrictJSON.string(entry["api_key"])
                ?? StrictJSON.string(entry["apiKey"]) {
                return .present(token: apiKey, expiresAt: nil)
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
                return .present(token: access, expiresAt: expires)
            }

            if let refresh = StrictJSON.string(entry["refresh"])
                ?? StrictJSON.string(entry["refresh_token"])
                ?? StrictJSON.string(entry["refreshToken"]) {
                return .present(token: refresh, expiresAt: nil)
            }
        }

        return sawMalformedRecognized ? .malformed : .missing
    }

    private func parseUsageResponse(
        _ data: Data,
        now: Date,
        secrets: [String]
    ) -> (plan: String, limit: UsageLimit?, warnings: [String]) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ("", nil, [])
        }

        var warnings: [String] = []
        let parsedUsedUSD: Double?
        if let rawUsed = object["used_usd"], !(rawUsed is NSNull) {
            if let value = StrictJSON.double(rawUsed),
               value >= 0,
               ResetTimeFormatter.isRepresentableUSD(value) {
                parsedUsedUSD = value
            } else {
                parsedUsedUSD = nil
                warnings.append("used_usd: present but not parseable")
            }
        } else {
            parsedUsedUSD = nil
        }

        let parsedLimitUSD: Double?
        if let rawLimit = object["limit_usd"], !(rawLimit is NSNull) {
            if let value = StrictJSON.double(rawLimit),
               value > 0,
               ResetTimeFormatter.isRepresentableUSD(value) {
                parsedLimitUSD = value
            } else {
                parsedLimitUSD = nil
                warnings.append("limit_usd: present but not parseable")
            }
        } else {
            parsedLimitUSD = nil
        }

        guard let usedUSD = parsedUsedUSD, let limitUSD = parsedLimitUSD else {
            return ("", nil, warnings)
        }

        let plan = SecretRedactor.sanitize(
            Self.formatPlan(StrictJSON.string(object["plan"])),
            secrets: secrets,
            maxLength: 30
        )
        let resetsAt = StrictJSON.timestamp(object["resets_at"])
        let percent = Int(min(100.0, max(0.0, (usedUSD / limitUSD) * 100.0)).rounded())
        let usedText = ResetTimeFormatter.formatUSD(usedUSD)
        let limitText = ResetTimeFormatter.formatUSD(limitUSD)
        let detail: String
        if let suffix = ResetTimeFormatter.formatBillingReset(resetsAt: resetsAt, now: now, timeZone: timeZone) {
            detail = "\(usedText) of \(limitText) · \(suffix)"
        } else {
            detail = "\(usedText) of \(limitText) this month"
        }

        let limit = UsageLimit(
            id: "opencode-credit",
            name: "Credit used",
            shortName: "Credit used",
            percentUsed: percent,
            resetText: detail,
            resetsAt: resetsAt
        )
        return (plan, limit, warnings)
    }

    private static func formatPlan(_ rawPlan: String?) -> String {
        guard let rawPlan = StrictJSON.string(rawPlan) else { return "" }
        switch rawPlan.lowercased() {
        case "zen", "opencode-zen": return "Zen"
        case "go", "opencode-go": return "Go"
        case "pro": return "Pro"
        case "team": return "Team"
        case "enterprise": return "Enterprise"
        case "free": return "Free"
        default: return ""
        }
    }
}
