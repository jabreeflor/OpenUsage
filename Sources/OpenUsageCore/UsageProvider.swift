import Foundation

public protocol UsageProvider: Sendable {
    var provider: ProviderID { get }
    func fetchSnapshot() async throws -> ProviderSnapshot
}

/// Honest empty provider used outside demo mode before live providers are wired up.
public struct UnconfiguredUsageProvider: UsageProvider, Sendable {
    public let provider: ProviderID

    public init(provider: ProviderID) {
        self.provider = provider
    }

    public func fetchSnapshot() async throws -> ProviderSnapshot {
        ProviderSnapshot(
            provider: provider,
            plan: "",
            connectionState: .notConnected,
            limits: [],
            connectedVia: "Not connected"
        )
    }
}
