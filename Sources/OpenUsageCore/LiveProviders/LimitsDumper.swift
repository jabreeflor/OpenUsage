import Foundation

/// Output of a CLI dump command (`--dump-token-summary`, `--dump-limits`, `--dump-limits-shape`).
public struct CLIDumpResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Shared CLI dispatcher used by `OpenUsageMain` and unit tests so flag combinations
/// (including `--demo` / `OPENUSAGE_DEMO=1` with `--dump-limits-shape`) are enforced identically.
public enum CLIDumpDispatcher {
    public static func run(
        arguments: [String],
        environment: [String: String] = [:],
        providers: [any UsageProvider]? = nil,
        httpTransport: any HTTPTransport = URLSessionHTTPTransport(),
        fileReader: any LocalFileReader = SystemLocalFileReader(),
        keychain: any KeychainReading = SystemKeychainStore(),
        disableStore: any ProviderDisableStoring = UserDefaultsProviderDisableStore(),
        urlOpener: any URLOpening = NoOpURLOpener(),
        requestTimeout: TimeInterval = URLSessionHTTPTransport.defaultTimeout,
        keychainTimeout: TimeInterval = LimitsDumper.defaultCLIKeychainTimeout,
        stderrWriter: (@Sendable (String) -> Void)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        timeZone: TimeZone = .current
    ) async -> CLIDumpResult? {
        let options = LaunchOptions.parse(arguments: arguments, environment: environment)
        return await run(
            options: options,
            providers: providers,
            httpTransport: httpTransport,
            fileReader: fileReader,
            keychain: keychain,
            disableStore: disableStore,
            urlOpener: urlOpener,
            requestTimeout: requestTimeout,
            keychainTimeout: keychainTimeout,
            stderrWriter: stderrWriter,
            clock: clock,
            timeZone: timeZone
        )
    }

    public static func run(
        options: LaunchOptions,
        providers: [any UsageProvider]? = nil,
        httpTransport: any HTTPTransport = URLSessionHTTPTransport(),
        fileReader: any LocalFileReader = SystemLocalFileReader(),
        keychain: any KeychainReading = SystemKeychainStore(),
        disableStore: any ProviderDisableStoring = UserDefaultsProviderDisableStore(),
        urlOpener: any URLOpening = NoOpURLOpener(),
        requestTimeout: TimeInterval = URLSessionHTTPTransport.defaultTimeout,
        keychainTimeout: TimeInterval = LimitsDumper.defaultCLIKeychainTimeout,
        stderrWriter: (@Sendable (String) -> Void)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        timeZone: TimeZone = .current
    ) async -> CLIDumpResult? {
        // Reject `--dump-limits-shape` in demo mode BEFORE constructing any live providers.
        if options.dumpLimitsShape && options.isDemo {
            let err = "error: --dump-limits-shape cannot be combined with --demo or OPENUSAGE_DEMO=1\n"
            stderrWriter?(err)
            return CLIDumpResult(
                exitCode: 2,
                stdout: "",
                stderr: err
            )
        }

        if options.dumpTokenSummary {
            let report = await TokenSummaryDumper.generateReport(isDemo: options.isDemo)
            return CLIDumpResult(exitCode: 0, stdout: report, stderr: "")
        }

        if options.dumpLimits {
            let notice = options.isDemo ? "" : LimitsDumper.keychainPromptStderrNotice(timeout: keychainTimeout)
            if !notice.isEmpty {
                stderrWriter?(notice)
            }
            let report = await LimitsDumper.generateReport(
                isDemo: options.isDemo,
                demoScenario: options.demoScenario,
                providers: providers,
                httpTransport: httpTransport,
                fileReader: fileReader,
                keychain: keychain,
                disableStore: disableStore,
                urlOpener: urlOpener,
                requestTimeout: requestTimeout,
                keychainTimeout: keychainTimeout,
                clock: clock,
                timeZone: timeZone
            )
            return CLIDumpResult(exitCode: 0, stdout: report, stderr: notice)
        }

        if options.dumpLimitsShape {
            let notice = LimitsDumper.keychainPromptStderrNotice(timeout: keychainTimeout)
            stderrWriter?(notice)
            let report = await LimitsDumper.generateShapeReport(
                isDemo: false,
                demoScenario: options.demoScenario,
                providers: providers,
                httpTransport: httpTransport,
                fileReader: fileReader,
                keychain: keychain,
                disableStore: disableStore,
                urlOpener: urlOpener,
                requestTimeout: requestTimeout,
                keychainTimeout: keychainTimeout,
                clock: clock,
                timeZone: timeZone
            )
            return CLIDumpResult(exitCode: 0, stdout: report, stderr: notice)
        }

        return nil
    }
}

/// Runs usage providers once and prints a strictly secret-free summary for `--dump-limits`.
/// Prints ONLY: state, plan, limit names, percent used, reset text, source label, and for failures an HTTP status / short reason.
/// Never prints tokens, cookies, emails, account IDs, file paths, or raw response bodies.
public enum LimitsDumper {
    public static let defaultCLIKeychainTimeout: TimeInterval = 120.0

    public static func keychainPromptStderrNotice(timeout: TimeInterval = defaultCLIKeychainTimeout) -> String {
        let seconds = max(1, Int((timeout.isFinite ? min(3600.0, timeout) : defaultCLIKeychainTimeout).rounded()))
        return "Note: Waiting up to \(seconds)s if a macOS Keychain access prompt is shown.\n"
    }

    public static func generateReport(
        isDemo: Bool,
        demoScenario: DemoScenario = .all,
        providers: [any UsageProvider]? = nil,
        httpTransport: any HTTPTransport = URLSessionHTTPTransport(),
        fileReader: any LocalFileReader = SystemLocalFileReader(),
        keychain: any KeychainReading = SystemKeychainStore(),
        disableStore: any ProviderDisableStoring = UserDefaultsProviderDisableStore(),
        urlOpener: any URLOpening = NoOpURLOpener(),
        requestTimeout: TimeInterval = URLSessionHTTPTransport.defaultTimeout,
        keychainTimeout: TimeInterval = LimitsDumper.defaultCLIKeychainTimeout,
        clock: @escaping @Sendable () -> Date = { Date() },
        timeZone: TimeZone = .current
    ) async -> String {
        let resolvedProviders: [any UsageProvider]
        if let providers {
            resolvedProviders = providers
        } else {
            resolvedProviders = UsageProviderRegistry.makeProviders(
                isDemo: isDemo,
                demoScenario: demoScenario,
                httpTransport: httpTransport,
                fileReader: fileReader,
                keychain: keychain,
                disableStore: disableStore,
                urlOpener: urlOpener,
                requestTimeout: requestTimeout,
                keychainTimeout: keychainTimeout,
                clock: clock,
                timeZone: timeZone
            )
        }

        let byID = Dictionary(uniqueKeysWithValues: resolvedProviders.map { ($0.provider, $0) })
        var resultsByID: [ProviderID: ProviderFetchResult] = [:]

        await withTaskGroup(of: (ProviderID, ProviderFetchResult).self) { group in
            for id in ProviderID.allCases {
                guard let provider = byID[id] else { continue }
                group.addTask {
                    if let diagnosable = provider as? any DiagnosableUsageProvider {
                        return (id, await diagnosable.fetchResult())
                    }
                    do {
                        let snap = try await provider.fetchSnapshot()
                        return (id, ProviderFetchResult(snapshot: snap))
                    } catch {
                        let fallback = ProviderSnapshot(
                            provider: id,
                            plan: "",
                            connectionState: .unsupported,
                            limits: [],
                            connectedVia: "Provider fetch failed"
                        )
                        return (
                            id,
                            ProviderFetchResult(
                                snapshot: fallback,
                                diagnostic: ProviderFetchDiagnostic(
                                    shortReason: "Provider fetch failed",
                                    isTransientError: true
                                )
                            )
                        )
                    }
                }
            }

            for await (id, result) in group {
                resultsByID[id] = result
            }
        }

        let orderedResults = ProviderID.allCases.map { id in
            resultsByID[id] ?? ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: id,
                    plan: "",
                    connectionState: .notConnected,
                    limits: [],
                    connectedVia: "Not connected"
                )
            )
        }

        return formatReport(results: orderedResults, isDemo: isDemo)
    }

    /// Runs usage providers once and prints the redacted structural shape
    /// of every payload consumed by each provider's parser (`--dump-limits-shape`).
    /// When `isDemo` is `true`, only fixture providers are constructed and live transports are never touched.
    public static func generateShapeReport(
        isDemo: Bool = false,
        demoScenario: DemoScenario = .all,
        providers: [any UsageProvider]? = nil,
        httpTransport: any HTTPTransport = URLSessionHTTPTransport(),
        fileReader: any LocalFileReader = SystemLocalFileReader(),
        keychain: any KeychainReading = SystemKeychainStore(),
        disableStore: any ProviderDisableStoring = UserDefaultsProviderDisableStore(),
        urlOpener: any URLOpening = NoOpURLOpener(),
        requestTimeout: TimeInterval = URLSessionHTTPTransport.defaultTimeout,
        keychainTimeout: TimeInterval = LimitsDumper.defaultCLIKeychainTimeout,
        clock: @escaping @Sendable () -> Date = { Date() },
        timeZone: TimeZone = .current
    ) async -> String {
        let resolvedProviders: [any UsageProvider]
        if let providers {
            resolvedProviders = providers
        } else {
            resolvedProviders = UsageProviderRegistry.makeProviders(
                isDemo: isDemo,
                demoScenario: demoScenario,
                httpTransport: httpTransport,
                fileReader: fileReader,
                keychain: keychain,
                disableStore: disableStore,
                urlOpener: urlOpener,
                requestTimeout: requestTimeout,
                keychainTimeout: keychainTimeout,
                clock: clock,
                timeZone: timeZone
            )
        }

        let byID = Dictionary(uniqueKeysWithValues: resolvedProviders.map { ($0.provider, $0) })
        var resultsByID: [ProviderID: ProviderFetchResult] = [:]

        await withTaskGroup(of: (ProviderID, ProviderFetchResult).self) { group in
            for id in ProviderID.allCases {
                guard let provider = byID[id] else { continue }
                group.addTask {
                    if let diagnosable = provider as? any DiagnosableUsageProvider {
                        return (id, await diagnosable.fetchResult(captureShape: true))
                    }
                    do {
                        let snap = try await provider.fetchSnapshot()
                        return (id, ProviderFetchResult(snapshot: snap))
                    } catch {
                        let fallback = ProviderSnapshot(
                            provider: id,
                            plan: "",
                            connectionState: .unsupported,
                            limits: [],
                            connectedVia: "Provider fetch failed"
                        )
                        return (
                            id,
                            ProviderFetchResult(
                                snapshot: fallback,
                                diagnostic: ProviderFetchDiagnostic(
                                    shortReason: "Provider fetch failed",
                                    isTransientError: true
                                )
                            )
                        )
                    }
                }
            }

            for await (id, result) in group {
                resultsByID[id] = result
            }
        }

        let orderedResults = ProviderID.allCases.map { id in
            resultsByID[id] ?? ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: id,
                    plan: "",
                    connectionState: .notConnected,
                    limits: [],
                    connectedVia: "Not connected"
                )
            )
        }

        return formatShapeReport(results: orderedResults, isDemo: isDemo)
    }

    public static func formatReport(results: [ProviderFetchResult], isDemo: Bool = false) -> String {
        var lines: [String] = []
        lines.append(isDemo ? "OpenUsage limits (demo)" : "OpenUsage limits (live)")

        for result in results {
            let snap = result.snapshot
            let plan = escapeQuoted(SecretRedactor.sanitize(snap.plan, maxLength: 60))
            let source = escapeQuoted(SecretRedactor.sanitize(snap.connectedVia, maxLength: 140))

            var header = "\(snap.provider.rawValue): state=\(snap.connectionState.rawValue) plan=\"\(plan)\" source=\"\(source)\""

            if let diagnostic = result.diagnostic {
                if let status = diagnostic.httpStatus, snap.connectionState != .connected {
                    header += " status=\(status)"
                }
                if let reason = diagnostic.shortReason, !reason.isEmpty {
                    let cleanReason = escapeQuoted(SecretRedactor.sanitize(reason, maxLength: 120))
                    header += " reason=\"\(cleanReason)\""
                }
            }
            lines.append(header)

            for limit in snap.limits {
                let name = SecretRedactor.sanitize(limit.name, maxLength: 60)
                let reset = SecretRedactor.sanitize(limit.resetText, maxLength: 100)
                lines.append("  - \(name): \(limit.percentUsed)% (\(reset))")
            }

            if let warnings = result.diagnostic?.warnings {
                for warning in warnings where !warning.isEmpty {
                    let cleanWarning = SecretRedactor.sanitize(warning, maxLength: 140)
                    lines.append("  ! \(cleanWarning)")
                }
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    public static func formatShapeReport(results: [ProviderFetchResult], isDemo: Bool = false) -> String {
        var lines: [String] = []
        lines.append(isDemo ? "OpenUsage limits shape (demo)" : "OpenUsage limits shape (live)")

        for result in results {
            let snap = result.snapshot
            var header = "\(snap.provider.rawValue): state=\(snap.connectionState.rawValue)"
            if let diagnostic = result.diagnostic {
                if let status = diagnostic.httpStatus {
                    header += " status=\(status)"
                }
                if let reason = diagnostic.shortReason, !reason.isEmpty {
                    let cleanReason = escapeQuoted(SecretRedactor.sanitize(reason, maxLength: 120))
                    header += " reason=\"\(cleanReason)\""
                }
            }
            lines.append(SecretRedactor.sanitize(header, maxLength: 300))

            if result.payloadShapes.isEmpty {
                lines.append("  (no payload read)")
                continue
            }

            for shape in result.payloadShapes {
                var sourceLine = "source=\(SecretRedactor.sanitize(shape.source, maxLength: 80))"
                if let httpStatus = shape.httpStatus {
                    sourceLine += " http_status=\(httpStatus)"
                }
                lines.append("  \(SecretRedactor.sanitize(sourceLine, maxLength: 200))")
                for shapeLine in shape.lines {
                    lines.append("    \(SecretRedactor.sanitize(shapeLine, maxLength: 300))")
                }
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func escapeQuoted(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: "'")
    }
}
