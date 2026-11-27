import Foundation

public struct TokenBucket: Identifiable, Codable, Sendable, Equatable, Hashable {
    public let id: String
    /// ISO calendar day string (`YYYY-MM-DD`).
    public let dayKey: String
    /// Hour of day (`0...23`).
    public let hour: Int
    public let provider: ProviderID
    public let model: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheTokens: Int
    public let requests: Int

    public var totalTokens: Int {
        inputTokens + outputTokens + cacheTokens
    }

    public init(
        dayKey: String,
        hour: Int,
        provider: ProviderID,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheTokens: Int,
        requests: Int
    ) {
        let clampedHour = min(23, max(0, hour))
        self.id = "\(dayKey)#\(clampedHour)#\(provider.rawValue)#\(model)"
        self.dayKey = dayKey
        self.hour = clampedHour
        self.provider = provider
        self.model = model
        self.inputTokens = max(0, inputTokens)
        self.outputTokens = max(0, outputTokens)
        self.cacheTokens = max(0, cacheTokens)
        self.requests = max(0, requests)
    }
}

public struct TokenSummary: Codable, Sendable, Equatable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheTokens: Int
    public let requests: Int

    public var totalTokens: Int {
        inputTokens + outputTokens + cacheTokens
    }

    public init(inputTokens: Int = 0, outputTokens: Int = 0, cacheTokens: Int = 0, requests: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheTokens = cacheTokens
        self.requests = requests
    }

    public static func aggregate(_ buckets: [TokenBucket]) -> TokenSummary {
        var input = 0
        var output = 0
        var cache = 0
        var req = 0
        for bucket in buckets {
            input += bucket.inputTokens
            output += bucket.outputTokens
            cache += bucket.cacheTokens
            req += bucket.requests
        }
        return TokenSummary(inputTokens: input, outputTokens: output, cacheTokens: cache, requests: req)
    }
}

public protocol TokenLogSource: Sendable {
    var provider: ProviderID { get }
    func loadBuckets() async throws -> [TokenBucket]
}

public struct ModelShare: Identifiable, Codable, Sendable, Equatable, Hashable {
    public var id: String { model }

    public let model: String
    public let sharePercent: Int
    public let tokens: Int

    public init(model: String, sharePercent: Int, tokens: Int) {
        self.model = model
        self.sharePercent = min(100, max(0, sharePercent))
        self.tokens = max(0, tokens)
    }
}

public struct ProviderTodayUsage: Identifiable, Codable, Sendable, Equatable {
    public var id: ProviderID { provider }

    public let provider: ProviderID
    public let totalTokens: Int
    public let requests: Int
    public let models: [ModelShare]

    public init(
        provider: ProviderID,
        totalTokens: Int,
        requests: Int,
        models: [ModelShare]
    ) {
        self.provider = provider
        self.totalTokens = max(0, totalTokens)
        self.requests = max(0, requests)
        self.models = models
    }
}

public struct TodayUsageSummary: Codable, Sendable, Equatable {
    public let totalTokens: Int
    public let totalRequests: Int
    public let hourlySparkline: [Int]
    public let byProvider: [ProviderID: ProviderTodayUsage]

    public static let empty = TodayUsageSummary(
        totalTokens: 0,
        totalRequests: 0,
        hourlySparkline: Array(repeating: 0, count: 12),
        byProvider: [:]
    )

    public init(
        totalTokens: Int,
        totalRequests: Int,
        hourlySparkline: [Int],
        byProvider: [ProviderID: ProviderTodayUsage]
    ) {
        self.totalTokens = max(0, totalTokens)
        self.totalRequests = max(0, totalRequests)
        self.hourlySparkline = hourlySparkline.map { max(0, $0) }
        self.byProvider = byProvider
    }

    public func usage(for provider: ProviderID) -> ProviderTodayUsage {
        byProvider[provider] ?? ProviderTodayUsage(
            provider: provider,
            totalTokens: 0,
            requests: 0,
            models: []
        )
    }
}
