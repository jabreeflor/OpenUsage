import Foundation

/// Live usage limit provider for Cursor.
/// Reads Cursor's signed-in session token read-only from `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`
/// and queries Cursor's current-period usage endpoint.
/// Never reads email keys and never modifies Cursor's SQLite database.
public struct CursorUsageProvider: DiagnosableUsageProvider, Sendable {
    public static let defaultUsageEndpoint = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!
    public static let loginPageURL = URL(string: "https://cursor.com/dashboard")!
    public static let connectedSourceLabel = "Using the Cursor app session on this Mac"

    private static let tokenKey = "cursorAuth/accessToken"
    private static let membershipKey = "cursorAuth/stripeMembershipType"
    private static let subscriptionStatusKey = "cursorAuth/stripeSubscriptionStatus"

    public let provider: ProviderID = .cursor

    private let fileReader: any LocalFileReader
    private let httpTransport: any HTTPTransport
    private let disableStore: any ProviderDisableStoring
    private let urlOpener: any URLOpening
    private let stateDBURL: URL
    private let usageEndpoint: URL
    private let requestTimeout: TimeInterval
    private let clock: @Sendable () -> Date
    private let timeZone: TimeZone

    public init(
        fileReader: any LocalFileReader = SystemLocalFileReader(),
        httpTransport: any HTTPTransport = URLSessionHTTPTransport(),
        disableStore: any ProviderDisableStoring = UserDefaultsProviderDisableStore(),
        urlOpener: any URLOpening = NoOpURLOpener(),
        stateDBURL: URL = CursorUsageProvider.defaultStateDBURL(),
        usageEndpoint: URL = CursorUsageProvider.defaultUsageEndpoint,
        requestTimeout: TimeInterval = URLSessionHTTPTransport.defaultTimeout,
        clock: @escaping @Sendable () -> Date = { Date() },
        timeZone: TimeZone = .current
    ) {
        self.fileReader = fileReader
        self.httpTransport = httpTransport
        self.disableStore = disableStore
        self.urlOpener = urlOpener
        self.stateDBURL = stateDBURL
        self.usageEndpoint = usageEndpoint
        self.requestTimeout = requestTimeout
        self.clock = clock
        self.timeZone = timeZone
    }

    public static func defaultStateDBURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb", isDirectory: false)
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

        let items: [String: String]?
        do {
            items = try fileReader.readSQLiteItems(
                at: stateDBURL,
                keys: [Self.tokenKey, Self.membershipKey, Self.subscriptionStatusKey]
            )
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
                    connectedVia: "Unable to read Cursor local session",
                    updatedAt: now
                ),
                diagnostic: ProviderFetchDiagnostic(
                    shortReason: "Unable to read Cursor local session",
                    isTransientError: true
                )
            )
        }

        guard let items,
              let accessToken = StrictJSON.string(items[Self.tokenKey]) else {
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

        let secrets = [accessToken]
        let plan = SecretRedactor.sanitize(
            Self.formatPlan(items[Self.membershipKey]),
            secrets: secrets,
            maxLength: 30
        )

        if let expiresAt = JWTExpiryInspector.expirationDate(fromJWT: accessToken), expiresAt <= now {
            return ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: provider,
                    plan: plan,
                    connectionState: .expired,
                    limits: [],
                    connectedVia: "Cursor login expired — reconnect in Cursor",
                    updatedAt: now
                ),
                diagnostic: ProviderFetchDiagnostic(shortReason: "Cursor session token expired")
            )
        }

        var request = URLRequest(url: usageEndpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.httpBody = Data("{}".utf8)

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
            guard let limit = parsed.limit else {
                return ProviderFetchResult(
                    snapshot: ProviderSnapshot(
                        provider: provider,
                        plan: plan,
                        connectionState: .unsupported,
                        limits: [],
                        connectedVia: "Unexpected Cursor usage response format",
                        updatedAt: now
                    ),
                    diagnostic: ProviderFetchDiagnostic(
                        httpStatus: 200,
                        shortReason: "Unexpected Cursor usage response format",
                        warnings: parsed.warnings
                    ),
                    payloadShapes: shapes
                )
            }
            return ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: provider,
                    plan: plan,
                    connectionState: .connected,
                    limits: [limit],
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
                    connectedVia: "Cursor login expired — reconnect in Cursor",
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
                    connectedVia: "Cursor usage temporarily unavailable (HTTP \(response.statusCode))",
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
                    connectedVia: "Cursor usage endpoint unsupported (HTTP \(response.statusCode))",
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
                connectedVia: "Reconnect in Cursor, then click Reconnect",
                updatedAt: clock()
            )
        case .notConnected, .connecting:
            _ = urlOpener.open(Self.loginPageURL)
            return ProviderSnapshot(
                provider: provider,
                plan: "",
                connectionState: .notConnected,
                limits: [],
                connectedVia: "Sign in in the Cursor app, then click Sign in",
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

    private func parseUsageResponse(_ data: Data, now: Date) -> (limit: UsageLimit?, warnings: [String]) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, [])
        }
        guard let rawPlanUsage = object["planUsage"], !(rawPlanUsage is NSNull) else {
            return (nil, [])
        }
        guard let planUsage = rawPlanUsage as? [String: Any] else {
            return (nil, ["planUsage: present but not parseable"])
        }

        var warnings: [String] = []
        let parsedLimitCents: Double?
        if let rawLimit = planUsage["limit"], !(rawLimit is NSNull) {
            if let value = StrictJSON.double(rawLimit),
               value > 0,
               ResetTimeFormatter.isRepresentableUSD(value / 100.0) {
                parsedLimitCents = value
            } else {
                parsedLimitCents = nil
                warnings.append("planUsage.limit: present but not parseable")
            }
        } else {
            parsedLimitCents = nil
        }

        var validatedDollarFields: [String: Double] = [:]
        for key in ["includedSpend", "totalSpend", "used"] {
            if let rawValue = planUsage[key], !(rawValue is NSNull) {
                if let value = StrictJSON.double(rawValue),
                   value >= 0,
                   ResetTimeFormatter.isRepresentableUSD(value / 100.0) {
                    validatedDollarFields[key] = value
                } else {
                    warnings.append("planUsage.\(key): present but not parseable")
                }
            }
        }
        if let rawValue = planUsage["totalPercentUsed"], !(rawValue is NSNull) {
            if let value = StrictJSON.double(rawValue), value >= 0 {
                // valid
            } else {
                warnings.append("planUsage.totalPercentUsed: present but not parseable")
            }
        }

        let billingEnd = StrictJSON.timestamp(object["billingCycleEnd"])
            ?? StrictJSON.timestamp(object["billing_cycle_end"])
        let resetSuffix = ResetTimeFormatter.formatBillingReset(resetsAt: billingEnd, now: now, timeZone: timeZone)

        // Amounts in Cursor's GetCurrentPeriodUsage planUsage are in USD cents.
        let limitCents = parsedLimitCents
        let usedCents = validatedDollarFields["includedSpend"]
            ?? validatedDollarFields["totalSpend"]
            ?? validatedDollarFields["used"]

        if let limitCents, limitCents > 0, let usedCents, usedCents >= 0 {
            let pct = Int(min(100.0, max(0.0, (usedCents / limitCents) * 100.0)).rounded())
            let usedText = ResetTimeFormatter.formatUSD(usedCents / 100.0)
            let limitText = ResetTimeFormatter.formatUSD(limitCents / 100.0)
            let detail: String
            if let resetSuffix {
                detail = "\(usedText) of \(limitText) · \(resetSuffix)"
            } else {
                detail = "\(usedText) of \(limitText)"
            }
            return (
                UsageLimit(
                    id: "cursor-included",
                    name: "Included usage",
                    shortName: "Included usage",
                    percentUsed: pct,
                    resetText: detail,
                    resetsAt: billingEnd
                ),
                warnings
            )
        }

        if let totalPct = StrictJSON.double(planUsage["totalPercentUsed"]),
           totalPct >= 0 {
            let detail: String
            if let billingEnd, billingEnd <= now {
                detail = "Resetting"
            } else if let resetSuffix {
                detail = "Included usage · \(resetSuffix)"
            } else {
                detail = "Current billing period"
            }
            let clampedPct = Int(min(100.0, max(0.0, totalPct)).rounded())
            return (
                UsageLimit(
                    id: "cursor-included",
                    name: "Included usage",
                    shortName: "Included usage",
                    percentUsed: clampedPct,
                    resetText: detail,
                    resetsAt: billingEnd
                ),
                warnings
            )
        }

        if warnings.isEmpty {
            warnings.append("planUsage: present but not parseable")
        }
        return (nil, warnings)
    }

    private static func formatPlan(_ membership: String?) -> String {
        guard let membership = StrictJSON.string(membership) else { return "" }
        switch membership.lowercased() {
        case "pro": return "Pro"
        case "pro_plus", "pro+": return "Pro+"
        case "ultra": return "Ultra"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "free", "free_trial": return "Free"
        default: return ""
        }
    }
}
