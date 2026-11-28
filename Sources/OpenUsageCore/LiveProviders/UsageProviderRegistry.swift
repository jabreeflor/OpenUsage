import Foundation

/// Central factory that builds either fixture-only demo providers (zero Keychain, file, or network access)
/// or live `UsageProvider` implementations with injectable transports.
public enum UsageProviderRegistry {
    public static func makeProviders(
        isDemo: Bool,
        demoScenario: DemoScenario = .all,
        httpTransport: any HTTPTransport = URLSessionHTTPTransport(),
        fileReader: any LocalFileReader = SystemLocalFileReader(),
        keychain: any KeychainReading = SystemKeychainStore(),
        disableStore: any ProviderDisableStoring = UserDefaultsProviderDisableStore(),
        urlOpener: any URLOpening = NoOpURLOpener(),
        requestTimeout: TimeInterval = URLSessionHTTPTransport.defaultTimeout,
        keychainTimeout: TimeInterval? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        timeZone: TimeZone = .current
    ) -> [any UsageProvider] {
        if isDemo {
            // Demo mode is strictly fixture-only and never touches Keychain, local files, UserDefaults, or network.
            return DemoFixtures.providers(for: demoScenario)
        }

        return [
            ClaudeUsageProvider(
                keychain: keychain,
                httpTransport: httpTransport,
                disableStore: disableStore,
                urlOpener: urlOpener,
                requestTimeout: requestTimeout,
                keychainTimeout: keychainTimeout,
                clock: clock,
                timeZone: timeZone
            ),
            ChatGPTUsageProvider(
                fileReader: fileReader,
                disableStore: disableStore,
                urlOpener: urlOpener,
                clock: clock,
                timeZone: timeZone
            ),
            CursorUsageProvider(
                fileReader: fileReader,
                httpTransport: httpTransport,
                disableStore: disableStore,
                urlOpener: urlOpener,
                requestTimeout: requestTimeout,
                clock: clock,
                timeZone: timeZone
            ),
            GeminiUsageProvider(
                keychain: keychain,
                fileReader: fileReader,
                httpTransport: httpTransport,
                disableStore: disableStore,
                urlOpener: urlOpener,
                quotaEndpoint: GeminiUsageProvider.defaultQuotaEndpoint,
                requestTimeout: requestTimeout,
                keychainTimeout: keychainTimeout,
                clock: clock,
                timeZone: timeZone
            ),
            OpenCodeUsageProvider(
                fileReader: fileReader,
                httpTransport: httpTransport,
                disableStore: disableStore,
                urlOpener: urlOpener,
                requestTimeout: requestTimeout,
                clock: clock,
                timeZone: timeZone
            )
        ]
    }
}
