import Foundation

/// Live usage limit provider for Gemini Code Assist (Gemini CLI) quota.
///
/// Credential precedence:
/// 1. OpenUsage-owned OAuth credentials stored strictly in the macOS Keychain
///    (`service: dev.jabree.OpenUsage`, `account: gemini-oauth`), created by OpenUsage's browser PKCE loopback sign-in
///    reusing the installed Gemini CLI's public installed-app OAuth client configuration.
/// 2. Existing Gemini CLI credentials (`~/.gemini/oauth_creds.json`), read strictly read-only.
///
/// Expired credentials with a `refresh_token` refresh securely into OpenUsage's Keychain (for OpenUsage-owned logins)
/// or strictly in memory (for CLI logins, under a stable cache key derived from the unmodified CLI file).
/// OpenUsage never writes, modifies, or deletes `~/.gemini/oauth_creds.json`.
public struct GeminiUsageProvider: DiagnosableUsageProvider, Sendable {
    public static let defaultLoadCodeAssistEndpoint = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    public static let defaultQuotaEndpoint = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!
    public static let appKeychainService = SystemKeychainStore.openUsageService
    public static let appKeychainAccount = "gemini-oauth"
    public static let connectedSourceLabel = "Using the Gemini CLI login on this Mac"
    public static let keychainConnectedSourceLabel = "Signed in via Gemini CLI OAuth (Keychain)"
    public static let waitingForKeychainText = "Waiting for Keychain access"
    public static let defaultOAuthTimeout: TimeInterval = 180.0
    public static let defaultRefreshLeeway: TimeInterval = 60.0

    public let provider: ProviderID = .gemini

    private let keychain: (any KeychainReading)?
    private let keychainCoordinator: KeychainLookupCoordinator
    private let credentialCoordinator: GeminiCredentialCoordinator
    private let fileReader: any LocalFileReader
    private let httpTransport: any HTTPTransport
    private let disableStore: any ProviderDisableStoring
    private let urlOpener: any URLOpening
    private let keychainService: String
    private let keychainAccount: String
    private let oauthCredsURL: URL
    private let loadCodeAssistEndpoint: URL
    private let quotaEndpoint: URL?
    private let oauthConfigProvider: any GeminiOAuthConfigProviding
    private let oauthSessionStarter: any GeminiOAuthSessionStarting
    private let requestTimeout: TimeInterval
    private let keychainTimeout: TimeInterval
    private let oauthTimeout: TimeInterval
    private let clock: @Sendable () -> Date
    private let timeZone: TimeZone

    public init(
        keychain: (any KeychainReading)? = nil,
        keychainCoordinator: KeychainLookupCoordinator? = nil,
        credentialCoordinator: GeminiCredentialCoordinator = GeminiCredentialCoordinator(),
        fileReader: any LocalFileReader = SystemLocalFileReader(),
        httpTransport: any HTTPTransport = URLSessionHTTPTransport(),
        disableStore: any ProviderDisableStoring = UserDefaultsProviderDisableStore(),
        urlOpener: any URLOpening = NoOpURLOpener(),
        keychainService: String = GeminiUsageProvider.appKeychainService,
        keychainAccount: String = GeminiUsageProvider.appKeychainAccount,
        oauthCredsURL: URL = GeminiUsageProvider.defaultOAuthCredsURL(),
        loadCodeAssistEndpoint: URL = GeminiUsageProvider.defaultLoadCodeAssistEndpoint,
        quotaEndpoint: URL? = GeminiUsageProvider.defaultQuotaEndpoint,
        oauthConfigProvider: (any GeminiOAuthConfigProviding)? = nil,
        oauthSessionStarter: any GeminiOAuthSessionStarting = LoopbackGeminiOAuthSessionStarter(),
        requestTimeout: TimeInterval = URLSessionHTTPTransport.defaultTimeout,
        keychainTimeout: TimeInterval? = nil,
        oauthTimeout: TimeInterval = GeminiUsageProvider.defaultOAuthTimeout,
        clock: @escaping @Sendable () -> Date = { Date() },
        timeZone: TimeZone = .current
    ) {
        let resolvedKeychain: (any KeychainReading)?
        if let keychain {
            resolvedKeychain = keychain
        } else if fileReader is SystemLocalFileReader {
            resolvedKeychain = SystemKeychainStore()
        } else {
            // Keep tests injecting a fake fileReader isolated from the host macOS Keychain.
            resolvedKeychain = nil
        }
        self.keychain = resolvedKeychain
        if let keychainCoordinator {
            self.keychainCoordinator = keychainCoordinator
        } else if let resolvedKeychain {
            self.keychainCoordinator = KeychainCoordinatorRegistry.shared.coordinator(for: resolvedKeychain)
        } else {
            self.keychainCoordinator = KeychainLookupCoordinator()
        }
        self.credentialCoordinator = credentialCoordinator
        self.fileReader = fileReader
        self.httpTransport = httpTransport
        self.disableStore = disableStore
        self.urlOpener = urlOpener
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount
        self.oauthCredsURL = oauthCredsURL
        self.loadCodeAssistEndpoint = loadCodeAssistEndpoint
        self.quotaEndpoint = quotaEndpoint
        self.oauthConfigProvider = oauthConfigProvider ?? GeminiCLIOAuthConfigLoader(fileReader: fileReader)
        self.oauthSessionStarter = oauthSessionStarter
        self.requestTimeout = requestTimeout
        self.keychainTimeout = keychainTimeout ?? requestTimeout
        self.oauthTimeout = oauthTimeout
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
        let (isDisabled, fetchGeneration) = await credentialCoordinator.beginFetch(disableStore: disableStore)
        if isDisabled {
            return ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: provider,
                    plan: "",
                    connectionState: .notConnected,
                    limits: [],
                    connectedVia: "Not connected",
                    updatedAt: clock()
                )
            )
        }
        return await fetchResult(captureShape: captureShape, fetchGeneration: fetchGeneration)
    }

    private func fetchResult(captureShape: Bool, fetchGeneration: UInt64) async -> ProviderFetchResult {
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

        let resolution = await resolveCredential(now: now, captureShape: captureShape)
        let resolved: ResolvedCredential
        switch resolution {
        case .found(let found):
            resolved = found
        case .terminal(let result):
            return result
        }

        // If quotaEndpoint was explicitly disabled (nil), stay honestly `.unsupported` with zero network calls.
        guard let quotaEndpoint else {
            let localShapes = captureShape
                ? [JSONShapeFormatter.format(
                    data: resolved.rawData,
                    source: resolved.source.shapeSourceName,
                    secrets: resolved.credential.redactionSecrets,
                    provider: provider
                )]
                : []
            return ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: provider,
                    plan: "",
                    connectionState: .unsupported,
                    limits: [],
                    connectedVia: "Not yet supported — Gemini login detected on this Mac",
                    updatedAt: now,
                    canSignOut: true
                ),
                diagnostic: ProviderFetchDiagnostic(shortReason: "Gemini quota API is not configured"),
                payloadShapes: localShapes
            )
        }

        // Stable cache key derived from the unmodified source credential (survives CLI refresh-token rotation).
        let stableCacheKey = stableCacheKey(for: resolved)

        let tokenPreparation = await prepareAccessToken(
            for: resolved,
            stableCacheKey: stableCacheKey,
            fetchGeneration: fetchGeneration,
            now: now
        )
        let activeCredential: GeminiOAuthCredential
        let activeBaseVersion: UInt64
        let alreadyRefreshed: Bool
        switch tokenPreparation {
        case .ready(let cred, let baseVersion, let refreshed):
            activeCredential = cred
            activeBaseVersion = baseVersion
            alreadyRefreshed = refreshed
        case .terminal(let result):
            return result
        }

        // Query loadCodeAssist + retrieveUserQuota, retrying once after token refresh ONLY on HTTP 401.
        let firstAttempt = await fetchQuota(
            credential: activeCredential,
            source: resolved.source,
            quotaEndpoint: quotaEndpoint,
            now: now,
            captureShape: captureShape
        )

        if firstAttempt.diagnostic?.httpStatus == 401,
           !alreadyRefreshed,
           let refreshToken = activeCredential.refreshToken {
            if let stableCacheKey {
                await credentialCoordinator.invalidateCachedCredentialIfMatching(
                    forKey: stableCacheKey,
                    expectedGeneration: fetchGeneration,
                    matchingAccessToken: activeCredential.accessToken
                )
            }

            switch await performTokenRefresh(
                refreshToken: refreshToken,
                source: resolved.source,
                stableCacheKey: stableCacheKey ?? cacheKey(for: resolved.source, seedRefreshToken: refreshToken),
                expectedBaseVersion: activeBaseVersion,
                fetchGeneration: fetchGeneration,
                now: now
            ) {
            case .refreshed(let refreshedCred):
                let retryResult = await fetchQuota(
                    credential: refreshedCred,
                    source: resolved.source,
                    quotaEndpoint: quotaEndpoint,
                    now: now,
                    captureShape: captureShape
                )
                guard await credentialCoordinator.currentGeneration() == fetchGeneration else {
                    return staleFetchResult(now: clock())
                }
                return retryResult
            case .stale:
                return staleFetchResult(now: clock())
            case .keychainWriteFailed(let reason):
                return resultForKeychainPersistFailure(reason, now: now, payloadShapes: firstAttempt.payloadShapes)
            case .failure(let oauthError):
                return resultForRefreshFailure(oauthError, source: resolved.source, now: now, payloadShapes: firstAttempt.payloadShapes)
            }
        }

        guard await credentialCoordinator.currentGeneration() == fetchGeneration else {
            return staleFetchResult(now: clock())
        }
        return firstAttempt
    }

    public func signIn() async throws -> ProviderSnapshot {
        try Task.checkCancellation()
        // Own sign-in enablement & generation advance atomically in GeminiCredentialCoordinator
        // so an earlier sign-out can never override this sign-in.
        let signInGeneration = await credentialCoordinator.beginSignIn(disableStore: disableStore)
        await keychainCoordinator.clearCachedResult(forService: keychainService, account: keychainAccount)

        let initial = await fetchResult(captureShape: false, fetchGeneration: signInGeneration)
        guard await credentialCoordinator.currentGeneration() == signInGeneration else {
            throw CancellationError()
        }
        guard quotaEndpoint != nil else {
            return initial.snapshot
        }

        switch initial.snapshot.connectionState {
        case .connected, .waitingForKeychain:
            return initial.snapshot
        case .unsupported:
            // If valid/authenticated credentials already exist and failed on quota/setup/permission/transient error,
            // return the retried result rather than forcing another OAuth consent loop.
            if initial.snapshot.canSignOut || initial.diagnostic?.isTransientError == true {
                return initial.snapshot
            }
        case .notConnected, .expired, .connecting:
            break
        }

        let failureState: ConnectionState = (initial.snapshot.connectionState == .expired) ? .expired : .notConnected
        let preservedPlan = initial.snapshot.plan

        guard let writableKeychain = keychain as? any KeychainStoring else {
            return ProviderSnapshot(
                provider: provider,
                plan: preservedPlan,
                connectionState: failureState,
                limits: [],
                connectedVia: GeminiOAuthError.keychainStorageUnavailable.userMessage,
                updatedAt: clock()
            )
        }

        guard let config = oauthConfigProvider.loadConfiguration() else {
            return ProviderSnapshot(
                provider: provider,
                plan: preservedPlan,
                connectionState: failureState,
                limits: [],
                connectedVia: GeminiOAuthError.missingOAuthConfiguration.userMessage,
                updatedAt: clock()
            )
        }

        guard await credentialCoordinator.currentGeneration() == signInGeneration else {
            throw CancellationError()
        }

        let listener: any GeminiOAuthCallbackListening
        do {
            listener = try oauthSessionStarter.startLoopbackListener()
        } catch let error as GeminiOAuthError {
            return ProviderSnapshot(
                provider: provider,
                plan: preservedPlan,
                connectionState: failureState,
                limits: [],
                connectedVia: error.userMessage,
                updatedAt: clock()
            )
        } catch {
            return ProviderSnapshot(
                provider: provider,
                plan: preservedPlan,
                connectionState: failureState,
                limits: [],
                connectedVia: GeminiOAuthError.callbackServerFailed.userMessage,
                updatedAt: clock()
            )
        }
        defer { listener.stop() }

        let pkce = GeminiPKCE.generatePair()
        let state = GeminiPKCE.generateState()
        guard let authURL = GeminiOAuthClient.buildAuthorizationURL(
            configuration: config,
            redirectURI: listener.redirectURI,
            state: state,
            codeChallenge: pkce.challenge
        ) else {
            return ProviderSnapshot(
                provider: provider,
                plan: preservedPlan,
                connectionState: failureState,
                limits: [],
                connectedVia: GeminiOAuthError.callbackServerFailed.userMessage,
                updatedAt: clock()
            )
        }

        try Task.checkCancellation()

        guard urlOpener.open(authURL) else {
            listener.stop()
            return ProviderSnapshot(
                provider: provider,
                plan: preservedPlan,
                connectionState: failureState,
                limits: [],
                connectedVia: GeminiOAuthError.browserOpenFailed.userMessage,
                updatedAt: clock()
            )
        }

        let authorizationCode: String
        do {
            authorizationCode = try await listener.waitForAuthorizationCode(
                expectedState: state,
                timeout: oauthTimeout
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GeminiOAuthError {
            return ProviderSnapshot(
                provider: provider,
                plan: preservedPlan,
                connectionState: failureState,
                limits: [],
                connectedVia: error.userMessage,
                updatedAt: clock()
            )
        } catch {
            return ProviderSnapshot(
                provider: provider,
                plan: preservedPlan,
                connectionState: failureState,
                limits: [],
                connectedVia: GeminiOAuthError.callbackServerFailed.userMessage,
                updatedAt: clock()
            )
        }

        try Task.checkCancellation()

        let credential: GeminiOAuthCredential
        do {
            credential = try await GeminiOAuthClient.exchangeAuthorizationCode(
                code: authorizationCode,
                codeVerifier: pkce.verifier,
                redirectURI: listener.redirectURI,
                configuration: config,
                httpTransport: httpTransport,
                timeout: requestTimeout,
                now: clock()
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GeminiOAuthError {
            return ProviderSnapshot(
                provider: provider,
                plan: preservedPlan,
                connectionState: failureState,
                limits: [],
                connectedVia: error.userMessage,
                updatedAt: clock()
            )
        } catch {
            return ProviderSnapshot(
                provider: provider,
                plan: preservedPlan,
                connectionState: failureState,
                limits: [],
                connectedVia: GeminiOAuthError.tokenExchangeFailed(statusCode: nil).userMessage,
                updatedAt: clock()
            )
        }

        do {
            let status = try await credentialCoordinator.commitSignInCredential(
                credential,
                expectedGeneration: signInGeneration,
                keychain: writableKeychain,
                service: keychainService,
                account: keychainAccount,
                keychainCoordinator: keychainCoordinator,
                disableStore: disableStore
            )
            guard status == .committed else {
                throw CancellationError()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GeminiOAuthError {
            return ProviderSnapshot(
                provider: provider,
                plan: preservedPlan,
                connectionState: failureState,
                limits: [],
                connectedVia: error.userMessage,
                updatedAt: clock()
            )
        } catch {
            return ProviderSnapshot(
                provider: provider,
                plan: preservedPlan,
                connectionState: failureState,
                limits: [],
                connectedVia: GeminiOAuthError.keychainWriteFailed(reason: "Keychain write failed").userMessage,
                updatedAt: clock()
            )
        }

        let postSignIn = await fetchResult(captureShape: false, fetchGeneration: signInGeneration)
        guard await credentialCoordinator.currentGeneration() == signInGeneration else {
            throw CancellationError()
        }
        return postSignIn.snapshot
    }

    public func signOut() async throws -> ProviderSnapshot {
        let outcome = await credentialCoordinator.signOut(
            keychain: keychain,
            service: keychainService,
            account: keychainAccount,
            keychainCoordinator: keychainCoordinator,
            disableStore: disableStore
        )

        switch outcome {
        case .succeeded:
            return ProviderSnapshot(
                provider: provider,
                plan: "",
                connectionState: .notConnected,
                limits: [],
                connectedVia: "Not connected",
                updatedAt: clock()
            )
        case .keychainDeleteFailed(let reason):
            return ProviderSnapshot(
                provider: provider,
                plan: "",
                connectionState: .unsupported,
                limits: [],
                connectedVia: "Could not remove Gemini login from Keychain (\(SecretRedactor.sanitize(reason, maxLength: 60)))",
                updatedAt: clock(),
                canSignOut: true
            )
        }
    }

    // MARK: - Credential Resolution & Refresh

    private enum CredentialSource: Sendable {
        case appKeychain
        case cliFile

        var connectedSourceLabel: String {
            switch self {
            case .appKeychain: return GeminiUsageProvider.keychainConnectedSourceLabel
            case .cliFile: return GeminiUsageProvider.connectedSourceLabel
            }
        }

        var expiredMessage: String {
            switch self {
            case .appKeychain: return "Gemini sign-in expired — click Reconnect"
            case .cliFile: return "Gemini CLI login expired — click Reconnect"
            }
        }

        var shapeSourceName: String {
            switch self {
            case .appKeychain: return "local:keychain"
            case .cliFile: return "local:oauth_creds.json"
            }
        }
    }

    private struct ResolvedCredential {
        let source: CredentialSource
        let credential: GeminiOAuthCredential
        let rawData: Data
    }

    private enum CredentialResolution {
        case found(ResolvedCredential)
        case terminal(ProviderFetchResult)
    }

    private func resolveCredential(now: Date, captureShape: Bool) async -> CredentialResolution {
        var keychainFailure: ProviderFetchResult?

        // 1. Prefer OpenUsage-owned Keychain credential when available.
        if let keychain {
            do {
                let outcome = try await keychainCoordinator.readGenericPassword(
                    using: keychain,
                    service: keychainService,
                    account: keychainAccount,
                    timeout: keychainTimeout
                )
                switch outcome {
                case .pending:
                    let shapes = captureShape
                        ? [ProviderPayloadShape(source: "local:keychain", lines: ["(\(Self.waitingForKeychainText))"])]
                        : []
                    return .terminal(
                        ProviderFetchResult(
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
                    )

                case .completed(.success(let data?)):
                    guard let cred = GeminiOAuthCredential.decode(from: data) else {
                        let shapes = captureShape
                            ? [JSONShapeFormatter.format(data: data, source: "local:keychain", provider: provider)]
                            : []
                        return .terminal(
                            ProviderFetchResult(
                                snapshot: ProviderSnapshot(
                                    provider: provider,
                                    plan: "",
                                    connectionState: .unsupported,
                                    limits: [],
                                    connectedVia: "Unexpected Gemini Keychain credential format",
                                    updatedAt: now
                                ),
                                diagnostic: ProviderFetchDiagnostic(shortReason: "Unexpected Gemini Keychain credential format"),
                                payloadShapes: shapes
                            )
                        )
                    }
                    return .found(ResolvedCredential(source: .appKeychain, credential: cred, rawData: data))

                case .completed(.success(nil)):
                    break

                case .completed(.failure(let error as KeychainStoreError)):
                    let shapes = captureShape
                        ? [ProviderPayloadShape(source: "local:keychain", lines: ["(read failed: \(error.shortDescription))"])]
                        : []
                    keychainFailure = ProviderFetchResult(
                        snapshot: ProviderSnapshot(
                            provider: provider,
                            plan: "",
                            connectionState: .unsupported,
                            limits: [],
                            connectedVia: error.shortDescription,
                            updatedAt: now
                        ),
                        diagnostic: ProviderFetchDiagnostic(shortReason: error.shortDescription, isTransientError: true),
                        payloadShapes: shapes
                    )

                case .completed(.failure):
                    let shapes = captureShape
                        ? [ProviderPayloadShape(source: "local:keychain", lines: ["(read failed: Keychain read failed)"])]
                        : []
                    keychainFailure = ProviderFetchResult(
                        snapshot: ProviderSnapshot(
                            provider: provider,
                            plan: "",
                            connectionState: .unsupported,
                            limits: [],
                            connectedVia: "Keychain read failed",
                            updatedAt: now
                        ),
                        diagnostic: ProviderFetchDiagnostic(shortReason: "Keychain read failed", isTransientError: true),
                        payloadShapes: shapes
                    )
                }
            } catch is CancellationError {
                return .terminal(
                    ProviderFetchResult(
                        snapshot: ProviderSnapshot(
                            provider: provider,
                            plan: "",
                            connectionState: .waitingForKeychain,
                            limits: [],
                            connectedVia: Self.waitingForKeychainText,
                            updatedAt: now
                        ),
                        diagnostic: ProviderFetchDiagnostic(shortReason: "Request cancelled", isTransientError: true)
                    )
                )
            } catch {
                keychainFailure = ProviderFetchResult(
                    snapshot: ProviderSnapshot(
                        provider: provider,
                        plan: "",
                        connectionState: .unsupported,
                        limits: [],
                        connectedVia: "Keychain read failed",
                        updatedAt: now
                    ),
                    diagnostic: ProviderFetchDiagnostic(shortReason: "Keychain read failed", isTransientError: true)
                )
            }
        }

        // 2. Fallback read-only reuse of existing Gemini CLI credential (`~/.gemini/oauth_creds.json`).
        let credsData: Data?
        do {
            credsData = try fileReader.readFile(at: oauthCredsURL)
        } catch let error as LocalFileReaderError {
            return .terminal(
                ProviderFetchResult(
                    snapshot: ProviderSnapshot(
                        provider: provider,
                        plan: "",
                        connectionState: .unsupported,
                        limits: [],
                        connectedVia: error.shortReason,
                        updatedAt: now
                    ),
                    diagnostic: ProviderFetchDiagnostic(shortReason: error.shortReason, isTransientError: true)
                )
            )
        } catch {
            return .terminal(
                ProviderFetchResult(
                    snapshot: ProviderSnapshot(
                        provider: provider,
                        plan: "",
                        connectionState: .unsupported,
                        limits: [],
                        connectedVia: "Unable to read Gemini CLI credentials",
                        updatedAt: now
                    ),
                    diagnostic: ProviderFetchDiagnostic(shortReason: "Unable to read Gemini CLI credentials", isTransientError: true)
                )
            )
        }

        guard let credsData else {
            if let keychainFailure {
                return .terminal(keychainFailure)
            }
            return .terminal(
                ProviderFetchResult(
                    snapshot: ProviderSnapshot(
                        provider: provider,
                        plan: "",
                        connectionState: .notConnected,
                        limits: [],
                        connectedVia: "Not connected",
                        updatedAt: now
                    )
                )
            )
        }

        guard let cliCreds = GeminiOAuthCredential.decode(from: credsData) else {
            let shapes = captureShape
                ? [JSONShapeFormatter.format(data: credsData, source: "local:oauth_creds.json", provider: provider)]
                : []
            return .terminal(
                ProviderFetchResult(
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
            )
        }

        return .found(ResolvedCredential(source: .cliFile, credential: cliCreds, rawData: credsData))
    }

    private enum TokenPreparation {
        case ready(GeminiOAuthCredential, baseVersion: UInt64, refreshed: Bool)
        case terminal(ProviderFetchResult)
    }

    private enum RefreshOutcome {
        case refreshed(GeminiOAuthCredential)
        case stale
        case keychainWriteFailed(reason: String)
        case failure(GeminiOAuthError)
    }

    private func prepareAccessToken(
        for resolved: ResolvedCredential,
        stableCacheKey: String?,
        fetchGeneration: UInt64,
        now: Date
    ) async -> TokenPreparation {
        let baseCred = resolved.credential
        let refreshThreshold = now.addingTimeInterval(Self.defaultRefreshLeeway)

        // Reuse any fresher in-memory refreshed credential stored under the unmodified source's stable key.
        var candidate = baseCred
        var baseVersion: UInt64 = 0
        if let stableCacheKey,
           let cachedEntry = await credentialCoordinator.cachedEntry(forKey: stableCacheKey),
           isFresher(cachedEntry.credential, than: candidate) {
            baseVersion = cachedEntry.version
            if resolved.source == .appKeychain && cachedEntry.needsKeychainPersist {
                // Retry persisting a rotated/refreshed Keychain grant before claiming durable success.
                switch await credentialCoordinator.flushPendingKeychainPersist(
                    forKey: stableCacheKey,
                    expectedGeneration: fetchGeneration,
                    keychain: keychain,
                    service: keychainService,
                    account: keychainAccount,
                    keychainCoordinator: keychainCoordinator,
                    disableStore: disableStore
                ) {
                case .committed(let persisted):
                    candidate = persisted
                case .stale:
                    return .terminal(staleFetchResult(now: clock()))
                case .keychainWriteFailed(let reason):
                    return .terminal(resultForKeychainPersistFailure(reason, now: now, payloadShapes: []))
                case .oauthError(let error):
                    return .terminal(resultForRefreshFailure(error, source: resolved.source, now: now, payloadShapes: []))
                }
            } else {
                candidate = cachedEntry.credential
            }
        }

        guard let expiry = candidate.expiryDate else {
            return .ready(candidate, baseVersion: baseVersion, refreshed: false)
        }

        if expiry > refreshThreshold {
            return .ready(candidate, baseVersion: baseVersion, refreshed: false)
        }

        let isHardExpired = (expiry <= now)

        guard let refreshToken = candidate.refreshToken else {
            if isHardExpired {
                return .terminal(
                    ProviderFetchResult(
                        snapshot: ProviderSnapshot(
                            provider: provider,
                            plan: "",
                            connectionState: .expired,
                            limits: [],
                            connectedVia: resolved.source.expiredMessage,
                            updatedAt: now
                        ),
                        diagnostic: ProviderFetchDiagnostic(shortReason: "OAuth token expired")
                    )
                )
            }
            return .ready(candidate, baseVersion: baseVersion, refreshed: false)
        }

        let effectiveCacheKey = stableCacheKey ?? cacheKey(for: resolved.source, seedRefreshToken: refreshToken)
        switch await performTokenRefresh(
            refreshToken: refreshToken,
            source: resolved.source,
            stableCacheKey: effectiveCacheKey,
            expectedBaseVersion: baseVersion,
            fetchGeneration: fetchGeneration,
            now: now
        ) {
        case .refreshed(let refreshed):
            return .ready(refreshed, baseVersion: baseVersion, refreshed: true)
        case .stale:
            return .terminal(staleFetchResult(now: clock()))
        case .keychainWriteFailed(let reason):
            return .terminal(resultForKeychainPersistFailure(reason, now: now, payloadShapes: []))
        case .failure(let oauthError):
            if !isHardExpired {
                // Proactive refresh failed while the current access token is still valid — continue using it.
                return .ready(candidate, baseVersion: baseVersion, refreshed: false)
            }
            return .terminal(resultForRefreshFailure(oauthError, source: resolved.source, now: now, payloadShapes: []))
        }
    }

    private func performTokenRefresh(
        refreshToken: String,
        source: CredentialSource,
        stableCacheKey: String,
        expectedBaseVersion: UInt64,
        fetchGeneration: UInt64,
        now: Date
    ) async -> RefreshOutcome {
        guard let config = oauthConfigProvider.loadConfiguration() else {
            return .failure(.missingOAuthConfiguration)
        }

        let httpTransport = self.httpTransport
        let requestTimeout = self.requestTimeout
        let freshAfter = now.addingTimeInterval(Self.defaultRefreshLeeway)

        let outcome = await credentialCoordinator.refreshOrJoin(
            stableCacheKey: stableCacheKey,
            expectedGeneration: fetchGeneration,
            expectedBaseVersion: expectedBaseVersion,
            inputRefreshToken: refreshToken,
            persistToKeychain: (source == .appKeychain),
            keychain: keychain,
            service: keychainService,
            account: keychainAccount,
            keychainCoordinator: keychainCoordinator,
            disableStore: disableStore,
            freshAfter: freshAfter,
            operation: { sentRefreshToken in
                try await GeminiOAuthClient.refreshAccessToken(
                    refreshToken: sentRefreshToken,
                    configuration: config,
                    httpTransport: httpTransport,
                    timeout: requestTimeout,
                    now: now
                )
            }
        )

        switch outcome {
        case .committed(let chosenCredential):
            return .refreshed(chosenCredential)
        case .stale:
            return .stale
        case .keychainWriteFailed(let reason):
            return .keychainWriteFailed(reason: reason)
        case .oauthError(let error):
            return .failure(error)
        }
    }

    private func resultForKeychainPersistFailure(
        _ reason: String,
        now: Date,
        payloadShapes: [ProviderPayloadShape]
    ) -> ProviderFetchResult {
        let message = "Could not save refreshed Gemini login to Keychain (\(SecretRedactor.sanitize(reason, maxLength: 60)))"
        return ProviderFetchResult(
            snapshot: ProviderSnapshot(
                provider: provider,
                plan: "",
                connectionState: .unsupported,
                limits: [],
                connectedVia: message,
                updatedAt: now,
                canSignOut: true
            ),
            diagnostic: ProviderFetchDiagnostic(
                shortReason: message,
                isTransientError: true
            ),
            payloadShapes: payloadShapes
        )
    }

    private func staleFetchResult(now: Date) -> ProviderFetchResult {
        ProviderFetchResult(
            snapshot: ProviderSnapshot(
                provider: provider,
                plan: "",
                connectionState: .notConnected,
                limits: [],
                connectedVia: "Not connected",
                updatedAt: now
            ),
            diagnostic: ProviderFetchDiagnostic(shortReason: "Session changed during refresh", isTransientError: true)
        )
    }

    private func resultForRefreshFailure(
        _ error: GeminiOAuthError,
        source: CredentialSource,
        now: Date,
        payloadShapes: [ProviderPayloadShape]
    ) -> ProviderFetchResult {
        switch error {
        case .transientFailure(let reason):
            return ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: provider,
                    plan: "",
                    connectionState: .unsupported,
                    limits: [],
                    connectedVia: reason,
                    updatedAt: now,
                    canSignOut: true
                ),
                diagnostic: ProviderFetchDiagnostic(shortReason: reason, isTransientError: true),
                payloadShapes: payloadShapes
            )

        case .invalidClient:
            return ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: provider,
                    plan: "",
                    connectionState: .expired,
                    limits: [],
                    connectedVia: error.userMessage,
                    updatedAt: now
                ),
                diagnostic: ProviderFetchDiagnostic(shortReason: error.userMessage),
                payloadShapes: payloadShapes
            )

        case .missingOAuthConfiguration:
            return ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: provider,
                    plan: "",
                    connectionState: .expired,
                    limits: [],
                    connectedVia: source.expiredMessage,
                    updatedAt: now
                ),
                diagnostic: ProviderFetchDiagnostic(shortReason: "OAuth token expired"),
                payloadShapes: payloadShapes
            )

        default:
            return ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: provider,
                    plan: "",
                    connectionState: .expired,
                    limits: [],
                    connectedVia: source.expiredMessage,
                    updatedAt: now
                ),
                diagnostic: ProviderFetchDiagnostic(shortReason: "OAuth token refresh failed"),
                payloadShapes: payloadShapes
            )
        }
    }

    private func stableCacheKey(for resolved: ResolvedCredential) -> String? {
        switch resolved.source {
        case .appKeychain:
            return "keychain:\(keychainService):\(keychainAccount)"
        case .cliFile:
            guard let seedRefresh = resolved.credential.refreshToken else { return nil }
            return cacheKey(for: .cliFile, seedRefreshToken: seedRefresh)
        }
    }

    private func cacheKey(for source: CredentialSource, seedRefreshToken: String) -> String {
        let prefix = (source == .appKeychain) ? "keychain" : "cli"
        return "\(prefix):\(GeminiPKCE.sha256Hex(seedRefreshToken))"
    }

    private func isFresher(_ candidate: GeminiOAuthCredential, than baseline: GeminiOAuthCredential) -> Bool {
        switch (candidate.expiryDate, baseline.expiryDate) {
        case (let lhs?, let rhs?):
            return lhs > rhs
        case (.some, .none):
            return true
        default:
            return false
        }
    }

    // MARK: - Code Assist Quota Fetch

    private func fetchQuota(
        credential: GeminiOAuthCredential,
        source: CredentialSource,
        quotaEndpoint: URL,
        now: Date,
        captureShape: Bool
    ) async -> ProviderFetchResult {
        let secrets = credential.redactionSecrets
        var capturedShapes: [ProviderPayloadShape] = []

        // Step 1: loadCodeAssist for project ID, tier name, and onboarding/eligibility status.
        // Per official Gemini CLI (`config.ts`), never call retrieveUserQuota without a verified projectId.
        let codeAssistInfo: LoadCodeAssistInfo
        do {
            var loadRequest = URLRequest(url: loadCodeAssistEndpoint)
            loadRequest.httpMethod = "POST"
            loadRequest.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
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

            switch loadResponse.statusCode {
            case 200:
                guard let parsed = parseLoadCodeAssist(loadResponse.body, secrets: secrets) else {
                    return ProviderFetchResult(
                        snapshot: ProviderSnapshot(
                            provider: provider,
                            plan: "",
                            connectionState: .unsupported,
                            limits: [],
                            connectedVia: "Unexpected Gemini Code Assist response format",
                            updatedAt: now,
                            canSignOut: true
                        ),
                        diagnostic: ProviderFetchDiagnostic(
                            httpStatus: 200,
                            shortReason: "Unexpected Gemini Code Assist response format"
                        ),
                        payloadShapes: capturedShapes
                    )
                }
                codeAssistInfo = parsed

            case 401:
                return ProviderFetchResult(
                    snapshot: ProviderSnapshot(
                        provider: provider,
                        plan: "",
                        connectionState: .expired,
                        limits: [],
                        connectedVia: source.expiredMessage,
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
                        connectedVia: "Google account lacks Gemini Code Assist permission (HTTP 403)",
                        updatedAt: now,
                        canSignOut: true
                    ),
                    diagnostic: ProviderFetchDiagnostic(
                        httpStatus: 403,
                        shortReason: "HTTP 403"
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
                        connectedVia: "Gemini Code Assist temporarily unavailable (HTTP \(loadResponse.statusCode))",
                        updatedAt: now,
                        canSignOut: true
                    ),
                    diagnostic: ProviderFetchDiagnostic(
                        httpStatus: loadResponse.statusCode,
                        shortReason: "HTTP \(loadResponse.statusCode)",
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
                        connectedVia: "Gemini Code Assist request failed (HTTP \(loadResponse.statusCode))",
                        updatedAt: now,
                        canSignOut: true
                    ),
                    diagnostic: ProviderFetchDiagnostic(
                        httpStatus: loadResponse.statusCode,
                        shortReason: "HTTP \(loadResponse.statusCode)"
                    ),
                    payloadShapes: capturedShapes
                )
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
                    updatedAt: now,
                    canSignOut: true
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
                    updatedAt: now,
                    canSignOut: true
                ),
                diagnostic: ProviderFetchDiagnostic(
                    shortReason: "Network request failed",
                    isTransientError: true
                ),
                payloadShapes: capturedShapes
            )
        }

        // Guard projectId before calling retrieveUserQuota (matching official Gemini CLI behavior).
        guard let projectID = codeAssistInfo.project else {
            let reason = missingProjectMessage(from: codeAssistInfo)
            return ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: provider,
                    plan: codeAssistInfo.plan,
                    connectionState: .unsupported,
                    limits: [],
                    connectedVia: reason,
                    updatedAt: now,
                    canSignOut: true
                ),
                diagnostic: ProviderFetchDiagnostic(
                    httpStatus: 200,
                    shortReason: reason
                ),
                payloadShapes: capturedShapes
            )
        }

        // Step 2: retrieveUserQuota
        var quotaRequest = URLRequest(url: quotaEndpoint)
        quotaRequest.httpMethod = "POST"
        quotaRequest.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        quotaRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        quotaRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        quotaRequest.httpBody = (try? JSONSerialization.data(withJSONObject: ["project": projectID])) ?? Data("{}".utf8)

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
                    plan: codeAssistInfo.plan,
                    connectionState: .unsupported,
                    limits: [],
                    connectedVia: error.shortReason,
                    updatedAt: now,
                    canSignOut: true
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
                    plan: codeAssistInfo.plan,
                    connectionState: .unsupported,
                    limits: [],
                    connectedVia: "Network request failed",
                    updatedAt: now,
                    canSignOut: true
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
                let message = "Unexpected Gemini quota response format"
                return ProviderFetchResult(
                    snapshot: ProviderSnapshot(
                        provider: provider,
                        plan: codeAssistInfo.plan,
                        connectionState: .unsupported,
                        limits: [],
                        connectedVia: message,
                        updatedAt: now,
                        canSignOut: true
                    ),
                    diagnostic: ProviderFetchDiagnostic(
                        httpStatus: 200,
                        shortReason: message,
                        warnings: parsed?.warnings ?? []
                    ),
                    payloadShapes: capturedShapes
                )
            }
            return ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: provider,
                    plan: codeAssistInfo.plan,
                    connectionState: .connected,
                    limits: parsed.limits,
                    connectedVia: source.connectedSourceLabel,
                    updatedAt: now,
                    canSignOut: true
                ),
                diagnostic: ProviderFetchDiagnostic(httpStatus: 200, warnings: parsed.warnings),
                payloadShapes: capturedShapes
            )

        case 401:
            return ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: provider,
                    plan: codeAssistInfo.plan,
                    connectionState: .expired,
                    limits: [],
                    connectedVia: source.expiredMessage,
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
                    plan: codeAssistInfo.plan,
                    connectionState: .unsupported,
                    limits: [],
                    connectedVia: "Google account lacks Gemini quota permission (HTTP 403)",
                    updatedAt: now,
                    canSignOut: true
                ),
                diagnostic: ProviderFetchDiagnostic(
                    httpStatus: 403,
                    shortReason: "HTTP 403"
                ),
                payloadShapes: capturedShapes
            )

        case 429, 500...599:
            return ProviderFetchResult(
                snapshot: ProviderSnapshot(
                    provider: provider,
                    plan: codeAssistInfo.plan,
                    connectionState: .unsupported,
                    limits: [],
                    connectedVia: "Gemini quota temporarily unavailable (HTTP \(quotaResponse.statusCode))",
                    updatedAt: now,
                    canSignOut: true
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
                    plan: codeAssistInfo.plan,
                    connectionState: .unsupported,
                    limits: [],
                    connectedVia: "Gemini quota endpoint unsupported (HTTP \(quotaResponse.statusCode))",
                    updatedAt: now,
                    canSignOut: true
                ),
                diagnostic: ProviderFetchDiagnostic(
                    httpStatus: quotaResponse.statusCode,
                    shortReason: "HTTP \(quotaResponse.statusCode)"
                ),
                payloadShapes: capturedShapes
            )
        }
    }

    // MARK: - Parsing

    private struct LoadCodeAssistInfo {
        let project: String?
        let plan: String
        let hasCurrentTier: Bool
        let ineligibleReasonCode: String?
    }

    private func parseLoadCodeAssist(_ data: Data, secrets: [String]) -> LoadCodeAssistInfo? {
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

        var ineligibleReasonCode: String?
        if let ineligible = object["ineligibleTiers"] as? [[String: Any]] {
            for tier in ineligible {
                if let code = StrictJSON.string(tier["reasonCode"]) {
                    ineligibleReasonCode = code
                    if code == "VALIDATION_REQUIRED" {
                        break
                    }
                }
            }
        }

        return LoadCodeAssistInfo(
            project: project,
            plan: SecretRedactor.sanitize(plan, secrets: secrets, maxLength: 40),
            hasCurrentTier: currentTier != nil,
            ineligibleReasonCode: ineligibleReasonCode
        )
    }

    private func missingProjectMessage(from info: LoadCodeAssistInfo) -> String {
        if info.ineligibleReasonCode == "VALIDATION_REQUIRED" {
            return "Verify your Google account in Gemini CLI"
        }
        if info.ineligibleReasonCode != nil {
            return "Account ineligible for Gemini Code Assist"
        }
        if !info.hasCurrentTier {
            return "Run Gemini CLI once to finish Code Assist setup"
        }
        return "Gemini Code Assist project missing — finish setup in Gemini CLI"
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

    private static let recognizedGeminiModelRegex = try! NSRegularExpression(
        pattern: #"^gemini-[0-9]+(?:\.[0-9]+)?-[a-z0-9][a-z0-9._-]{0,31}$"#
    )

    private static func recognizedGeminiModelID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        guard recognizedGeminiModelRegex.firstMatch(in: normalized, range: range) != nil else {
            return nil
        }
        return normalized
    }

    private struct QuotaBucket {
        let remainingFraction: Double
        let resetTime: Date?
        let tokenType: String?
        let modelID: String?
    }

    private struct ParsedQuota {
        let limits: [UsageLimit]
        let warnings: [String]
    }

    private func parseQuotaResponse(_ data: Data, now: Date) -> ParsedQuota? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let rawBucketsValue = object["buckets"], !(rawBucketsValue is NSNull) else {
            return ParsedQuota(limits: [], warnings: [])
        }
        guard let rawBuckets = rawBucketsValue as? [Any] else {
            return ParsedQuota(limits: [], warnings: ["buckets: present but not parseable"])
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
            let modelID = Self.recognizedGeminiModelID(StrictJSON.string(entry["modelId"]))
            parsed.append(QuotaBucket(remainingFraction: remaining, resetTime: resetTime, tokenType: tokenType, modelID: modelID))
        }

        guard !parsed.isEmpty else {
            return ParsedQuota(limits: [], warnings: warnings)
        }

        // Accept explicit REQUESTS buckets OR documented per-model buckets when tokenType is absent.
        // Strictly reject explicitly non-request units (such as TOKENS) and untyped buckets without a recognized modelId.
        let eligibleBuckets = parsed.filter { bucket in
            if let tokenType = bucket.tokenType {
                return tokenType.uppercased() == "REQUESTS"
            }
            return bucket.modelID != nil
        }

        guard let fullest = eligibleBuckets.min(by: { $0.remainingFraction < $1.remainingFraction }) else {
            warnings.append("buckets: no REQUESTS or recognized Gemini model quota bucket found")
            return ParsedQuota(limits: [], warnings: warnings)
        }

        let percentUsed = Int(min(100.0, max(0.0, (1.0 - fullest.remainingFraction) * 100.0)).rounded())
        let resetText = ResetTimeFormatter.formatResetText(resetsAt: fullest.resetTime, now: now, timeZone: timeZone)

        let limitName: String
        if fullest.tokenType == nil, let modelID = fullest.modelID {
            limitName = "Daily requests · \(modelID)"
        } else {
            limitName = "Daily requests"
        }

        return ParsedQuota(
            limits: [
                UsageLimit(
                    id: "gemini-daily",
                    name: limitName,
                    shortName: "Daily requests",
                    percentUsed: percentUsed,
                    resetText: resetText,
                    resetsAt: fullest.resetTime
                )
            ],
            warnings: warnings
        )
    }
}
