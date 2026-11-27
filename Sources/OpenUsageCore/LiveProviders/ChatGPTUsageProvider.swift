import Foundation

/// Live usage limit provider for ChatGPT / Codex CLI.
/// Prefers local `rate_limits` from the most recent `~/.codex/sessions/**/rollout-*.jsonl` `token_count` events
/// (no network needed) and inspects `~/.codex/auth.json` for local sign-in presence/expiry.
/// Never writes or modifies `~/.codex/auth.json` or rollout logs.
public struct ChatGPTUsageProvider: DiagnosableUsageProvider, Sendable {
    public static let loginPageURL = URL(string: "https://chatgpt.com")!
    public static let freshSourceLabel = "Using Codex CLI session data on this Mac"
    public static let staleThresholdSeconds: TimeInterval = 15 * 60
    private static let maxRolloutFilesToScan = 20
    private static let rateLimitsNeedle = Array("\"rate_limits\"".utf8)

    public let provider: ProviderID = .chatgpt

    private let fileReader: any LocalFileReader
    private let disableStore: any ProviderDisableStoring
    private let urlOpener: any URLOpening
    private let sessionsDirectory: URL
    private let authFileURL: URL
    private let clock: @Sendable () -> Date
    private let timeZone: TimeZone

    public init(
        fileReader: any LocalFileReader = SystemLocalFileReader(),
        disableStore: any ProviderDisableStoring = UserDefaultsProviderDisableStore(),
        urlOpener: any URLOpening = NoOpURLOpener(),
        sessionsDirectory: URL = ChatGPTUsageProvider.defaultSessionsDirectory(),
        authFileURL: URL = ChatGPTUsageProvider.defaultAuthFileURL(),
        clock: @escaping @Sendable () -> Date = { Date() },
        timeZone: TimeZone = .current
    ) {
        self.fileReader = fileReader
        self.disableStore = disableStore
        self.urlOpener = urlOpener
        self.sessionsDirectory = sessionsDirectory
        self.authFileURL = authFileURL
        self.clock = clock
        self.timeZone = timeZone
    }

    public static func defaultSessionsDirectory() -> URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    public static func defaultAuthFileURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".codex/auth.json", isDirectory: false)
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

        // 1. Establish current local ChatGPT subscription login from `~/.codex/auth.json` BEFORE publishing cached rollout limits.
        let (authStatus, authShape) = inspectAuthFile(now: now, captureShape: captureShape)
        let baseShapes = authShape.map { [$0] } ?? []
        let authPlan: String
        switch authStatus {
        case .missing:
            return ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: provider,
                    plan: "",
                    connectionState: .notConnected,
                    limits: [],
                    connectedVia: "Not connected",
                    updatedAt: now
                ),
                payloadShapes: baseShapes
            )

        case .readFailed(let reason, let isTransient):
            let cleanReason = SecretRedactor.sanitize(reason, maxLength: 120)
            let failureShapes = captureShape
                ? [ProviderPayloadShape(source: "local:auth.json", lines: ["(read failed: \(cleanReason))"])]
                : []
            return ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: provider,
                    plan: "",
                    connectionState: .unsupported,
                    limits: [],
                    connectedVia: cleanReason,
                    updatedAt: now
                ),
                diagnostic: ProviderFetchDiagnostic(
                    shortReason: cleanReason,
                    isTransientError: isTransient
                ),
                payloadShapes: failureShapes
            )

        case .apiKeyOnly:
            return ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: provider,
                    plan: "",
                    connectionState: .notConnected,
                    limits: [],
                    connectedVia: "Codex CLI is using an API key — sign in with ChatGPT for subscription limits",
                    updatedAt: now
                ),
                diagnostic: ProviderFetchDiagnostic(
                    shortReason: "API key auth has no ChatGPT subscription limits"
                ),
                payloadShapes: baseShapes
            )

        case .expired(let plan):
            return ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: provider,
                    plan: plan,
                    connectionState: .expired,
                    limits: [],
                    connectedVia: "Codex CLI login expired — reconnect in Codex CLI",
                    updatedAt: now
                ),
                diagnostic: ProviderFetchDiagnostic(shortReason: "Codex auth token expired"),
                payloadShapes: baseShapes
            )

        case .malformed:
            return ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: provider,
                    plan: "",
                    connectionState: .unsupported,
                    limits: [],
                    connectedVia: "Unexpected Codex auth file format",
                    updatedAt: now
                ),
                diagnostic: ProviderFetchDiagnostic(shortReason: "Unexpected Codex auth file format"),
                payloadShapes: baseShapes
            )

        case .validSubscription(let plan):
            authPlan = plan
        }

        // 2. With a valid local login confirmed, read the latest rollout `rate_limits` (no network required).
        let rolloutOutcome = readLatestRolloutRateLimits(now: now, captureShape: captureShape)
        switch rolloutOutcome {
        case .found(let record, let shape):
            let age = max(0, now.timeIntervalSince(record.eventDate))
            let connectedVia: String
            if age >= Self.staleThresholdSeconds {
                let ageText = ResetTimeFormatter.formatAge(from: record.eventDate, now: now)
                connectedVia = "Using Codex CLI session data (\(ageText))"
            } else {
                connectedVia = Self.freshSourceLabel
            }
            let effectivePlan = record.plan != "Codex" ? record.plan : authPlan
            let diagnostic = record.warnings.isEmpty ? nil : ProviderFetchDiagnostic(warnings: record.warnings)
            let combinedShapes = baseShapes + (shape.map { [$0] } ?? [])
            return ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: provider,
                    plan: effectivePlan,
                    connectionState: .connected,
                    limits: record.limits,
                    connectedVia: connectedVia,
                    updatedAt: record.eventDate
                ),
                diagnostic: diagnostic,
                payloadShapes: combinedShapes
            )

        case .malformedOnly(let warnings, let shape):
            let combinedShapes = baseShapes + (shape.map { [$0] } ?? [])
            return ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: provider,
                    plan: authPlan,
                    connectionState: .unsupported,
                    limits: [],
                    connectedVia: "Unexpected Codex rate limit format",
                    updatedAt: now
                ),
                diagnostic: ProviderFetchDiagnostic(
                    shortReason: "Unexpected Codex rate limit format",
                    warnings: warnings
                ),
                payloadShapes: combinedShapes
            )

        case .none:
            return ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: provider,
                    plan: authPlan,
                    connectionState: .unsupported,
                    limits: [],
                    connectedVia: "Run a Codex CLI session to capture rate limits",
                    updatedAt: now
                ),
                diagnostic: ProviderFetchDiagnostic(
                    shortReason: "Codex login found; no session rate_limits yet"
                ),
                payloadShapes: baseShapes
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
                connectedVia: "Reconnect in Codex CLI, then click Reconnect",
                updatedAt: clock()
            )
        case .notConnected, .connecting:
            _ = urlOpener.open(Self.loginPageURL)
            return ProviderSnapshot(
                provider: provider,
                plan: "",
                connectionState: .notConnected,
                limits: [],
                connectedVia: "Sign in with Codex CLI, then click Sign in",
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

    // MARK: - Rollout Scanning

    private struct RolloutRateLimitRecord {
        let eventDate: Date
        let plan: String
        let limits: [UsageLimit]
        let warnings: [String]
    }

    private enum RolloutScanOutcome {
        case found(RolloutRateLimitRecord, ProviderPayloadShape?)
        case malformedOnly([String], ProviderPayloadShape?)
        case none
    }

    private func readLatestRolloutRateLimits(now: Date, captureShape: Bool) -> RolloutScanOutcome {
        let files = fileReader.discoverFiles(under: sessionsDirectory) { url in
            let name = url.lastPathComponent
            return name.hasPrefix("rollout-") && url.pathExtension.lowercased() == "jsonl"
        }
        guard !files.isEmpty else { return .none }

        let newestFirst = files.sorted { lhs, rhs in
            if lhs.metadata.mtimeNanos != rhs.metadata.mtimeNanos {
                return lhs.metadata.mtimeNanos > rhs.metadata.mtimeNanos
            }
            return lhs.relativePath > rhs.relativePath
        }

        var bestRecord: RolloutRateLimitRecord?
        var bestShape: ProviderPayloadShape?
        var sawMalformedRateLimits = false
        var malformedWarnings: [String] = []
        var malformedShape: ProviderPayloadShape?

        for file in newestFirst.prefix(Self.maxRolloutFilesToScan) {
            guard let data = try? fileReader.readFile(at: file.url), !data.isEmpty else {
                continue
            }
            guard StreamingLineReader.dataContainsASCII(data, needle: Self.rateLimitsNeedle) else {
                continue
            }

            var bestInFile: RolloutRateLimitRecord?
            var bestShapeInFile: ProviderPayloadShape?

            let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
            for lineSlice in lines {
                let lineData = Data(lineSlice)
                guard StreamingLineReader.dataContainsASCII(lineData, needle: Self.rateLimitsNeedle),
                      let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      (object["type"] as? String) == "event_msg",
                      let payload = object["payload"] as? [String: Any],
                      (payload["type"] as? String) == "token_count" else {
                    continue
                }

                let rawRateLimits = payload["rate_limits"]
                    ?? (payload["info"] as? [String: Any])?["rate_limits"]
                guard let rawRateLimits, !(rawRateLimits is NSNull) else {
                    continue
                }
                guard let rateLimits = rawRateLimits as? [String: Any] else {
                    sawMalformedRateLimits = true
                    malformedWarnings = ["rate_limits: present but not parseable"]
                    if captureShape {
                        malformedShape = JSONShapeFormatter.format(
                            jsonObject: rawRateLimits,
                            source: "local:rollout.rate_limits",
                            provider: provider
                        )
                    }
                    continue
                }

                guard Self.isSubscriptionRateLimits(rateLimits) else {
                    continue
                }

                let fallbackDate = Date(timeIntervalSince1970: Double(file.metadata.mtimeNanos) / 1_000_000_000.0)
                let eventDate = StrictJSON.timestamp(object["timestamp"]) ?? fallbackDate

                let (parsed, warnings) = parseRateLimitsObject(rateLimits, eventDate: eventDate, now: now)
                if let parsed {
                    if let currentFileBest = bestInFile {
                        if parsed.eventDate >= currentFileBest.eventDate {
                            bestInFile = parsed
                            if captureShape {
                                bestShapeInFile = JSONShapeFormatter.format(
                                    jsonObject: rateLimits,
                                    source: "local:rollout.rate_limits",
                                    provider: provider
                                )
                            }
                        }
                    } else {
                        bestInFile = parsed
                        if captureShape {
                            bestShapeInFile = JSONShapeFormatter.format(
                                jsonObject: rateLimits,
                                source: "local:rollout.rate_limits",
                                provider: provider
                            )
                        }
                    }
                } else {
                    sawMalformedRateLimits = true
                    if !warnings.isEmpty {
                        malformedWarnings = warnings
                    }
                    if captureShape {
                        malformedShape = JSONShapeFormatter.format(
                            jsonObject: rateLimits,
                            source: "local:rollout.rate_limits",
                            provider: provider
                        )
                    }
                }
            }

            // Compare event timestamps across the entire bounded candidate set so an older event
            // in a file with a newer mtime never beats a genuinely newer event in another rollout.
            if let candidate = bestInFile {
                if let currentBest = bestRecord {
                    if candidate.eventDate > currentBest.eventDate {
                        bestRecord = candidate
                        bestShape = bestShapeInFile
                    }
                } else {
                    bestRecord = candidate
                    bestShape = bestShapeInFile
                }
            }
        }

        if let bestRecord {
            return .found(bestRecord, bestShape)
        }
        return sawMalformedRateLimits ? .malformedOnly(malformedWarnings, malformedShape) : .none
    }

    private static let unknownWindowLabel = "Usage window"

    /// Subscription limit events either omit `limit_id`, set it to `null`, or set it to `"codex"`.
    /// Events with any other explicit `limit_id` belong to a separate limit and must not overwrite the subscription limit.
    private static func isSubscriptionRateLimits(_ dict: [String: Any]) -> Bool {
        guard let rawLimitID = dict["limit_id"], !(rawLimitID is NSNull) else {
            return true
        }
        guard let limitID = StrictJSON.string(rawLimitID) else {
            return false
        }
        return limitID.lowercased() == "codex"
    }

    private func parseRateLimitsObject(
        _ dict: [String: Any],
        eventDate: Date,
        now: Date
    ) -> (record: RolloutRateLimitRecord?, warnings: [String]) {
        var limits: [UsageLimit] = []
        var warnings: [String] = []

        if let rawPrimary = dict["primary"], !(rawPrimary is NSNull) {
            if let primary = rawPrimary as? [String: Any],
               let limit = parseWindow(
                   primary,
                   id: "chatgpt-primary",
                   eventDate: eventDate,
                   now: now
               ) {
                limits.append(limit)
            } else {
                warnings.append("primary: present but not parseable")
            }
        }

        if let rawSecondary = dict["secondary"], !(rawSecondary is NSNull) {
            if let secondary = rawSecondary as? [String: Any],
               let limit = parseWindow(
                   secondary,
                   id: "chatgpt-secondary",
                   eventDate: eventDate,
                   now: now
               ) {
                limits.append(limit)
            } else {
                warnings.append("secondary: present but not parseable")
            }
        }

        guard !limits.isEmpty else { return (nil, warnings) }
        let plan = Self.formatPlan(StrictJSON.string(dict["plan_type"]))
        return (RolloutRateLimitRecord(eventDate: eventDate, plan: plan, limits: limits, warnings: warnings), warnings)
    }

    private func parseWindow(
        _ window: [String: Any],
        id: String,
        eventDate: Date,
        now: Date
    ) -> UsageLimit? {
        guard let usedPercent = StrictJSON.double(window["used_percent"]),
              usedPercent >= 0 else {
            return nil
        }

        let name: String
        if let rawWindowMinutes = window["window_minutes"], !(rawWindowMinutes is NSNull) {
            guard let mins = StrictJSON.double(rawWindowMinutes),
                  mins > 0,
                  let roundedMins = StrictJSON.roundedNonNegativeInt(mins, maxValue: 5_256_000),
                  roundedMins > 0 else {
                return nil
            }
            name = Self.formatWindowDuration(minutes: roundedMins)
        } else {
            name = Self.unknownWindowLabel
        }

        var resetsAt = StrictJSON.timestamp(window["resets_at"])
        if resetsAt == nil,
           let resetsIn = StrictJSON.double(window["resets_in_seconds"]),
           resetsIn >= 0,
           resetsIn <= 366 * 24 * 3600 * 10 {
            resetsAt = eventDate.addingTimeInterval(resetsIn)
        }

        let resetText = ResetTimeFormatter.formatResetText(resetsAt: resetsAt, now: now, timeZone: timeZone)
        let clampedPercent = Int(min(100.0, max(0.0, usedPercent)).rounded())

        return UsageLimit(
            id: id,
            name: name,
            shortName: name,
            percentUsed: clampedPercent,
            resetText: resetText,
            resetsAt: resetsAt
        )
    }

    private static func formatWindowDuration(minutes: Int) -> String {
        if minutes == 300 {
            return "5-hour"
        }
        if minutes == 10080 {
            return "Weekly"
        }
        if minutes >= 1440 && minutes % 1440 == 0 {
            return "\(minutes / 1440)-day"
        }
        if minutes >= 60 && minutes % 60 == 0 {
            return "\(minutes / 60)-hour"
        }
        return "\(minutes)-minute"
    }

    // MARK: - Auth File Inspection

    private enum AuthFileStatus {
        case missing
        case readFailed(reason: String, isTransient: Bool)
        case apiKeyOnly
        case validSubscription(plan: String)
        case expired(plan: String)
        case malformed
    }

    private func inspectAuthFile(now: Date, captureShape: Bool) -> (AuthFileStatus, ProviderPayloadShape?) {
        let data: Data?
        do {
            data = try fileReader.readFile(at: authFileURL)
        } catch let error as LocalFileReaderError {
            return (.readFailed(reason: error.shortReason, isTransient: true), nil)
        } catch {
            return (.readFailed(reason: "Unable to read Codex credentials", isTransient: true), nil)
        }

        guard let data else {
            return (.missing, nil)
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let shape = captureShape
                ? JSONShapeFormatter.format(data: data, source: "local:auth.json", provider: provider)
                : nil
            return (.malformed, shape)
        }

        var secrets: [String] = []
        if let tokens = object["tokens"] as? [String: Any] {
            for key in ["access_token", "refresh_token", "id_token"] {
                if let value = StrictJSON.string(tokens[key]) {
                    secrets.append(value)
                }
            }
        }
        if let apiKey = StrictJSON.string(object["OPENAI_API_KEY"]) {
            secrets.append(apiKey)
        }
        let shape = captureShape
            ? JSONShapeFormatter.format(data: data, source: "local:auth.json", secrets: secrets, provider: provider)
            : nil

        let authMode = StrictJSON.string(object["auth_mode"])?.lowercased()
        let isExplicitAPIKeyMode = (authMode == "api_key" || authMode == "apikey")

        let plan = Self.formatPlan(StrictJSON.string(object["plan_type"]))
        if !isExplicitAPIKeyMode,
           let tokens = object["tokens"] as? [String: Any],
           let accessToken = StrictJSON.string(tokens["access_token"]) {
            if let exp = JWTExpiryInspector.expirationDate(fromJWT: accessToken), exp <= now {
                return (.expired(plan: plan), shape)
            }
            return (.validSubscription(plan: plan), shape)
        }

        if StrictJSON.string(object["OPENAI_API_KEY"]) != nil || isExplicitAPIKeyMode {
            return (.apiKeyOnly, shape)
        }

        return (.missing, shape)
    }

    private static func formatPlan(_ rawPlan: String?) -> String {
        guard let rawPlan, !rawPlan.isEmpty else { return "Codex" }
        switch rawPlan.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "plus": return "Plus · Codex"
        case "pro": return "Pro · Codex"
        case "team": return "Team · Codex"
        case "enterprise": return "Enterprise · Codex"
        case "free": return "Free · Codex"
        case "edu": return "Edu · Codex"
        case "go": return "Go · Codex"
        default: return "Codex"
        }
    }
}
