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
