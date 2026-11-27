import Foundation

public struct UsageLimit: Identifiable, Codable, Sendable, Equatable, Hashable {
    public let id: String
    public let name: String
    public let shortName: String
    public let percentUsed: Int
    public let resetText: String
    public let resetsAt: Date?

    public init(
        id: String? = nil,
        name: String,
        shortName: String? = nil,
        percentUsed: Int,
        resetText: String,
        resetsAt: Date? = nil
    ) {
        self.id = id ?? name
        self.name = name
        self.shortName = shortName ?? name.replacingOccurrences(of: "Weekly · ", with: "Wk · ")
        self.percentUsed = min(100, max(0, percentUsed))
        self.resetText = resetText
        self.resetsAt = resetsAt
    }
}
