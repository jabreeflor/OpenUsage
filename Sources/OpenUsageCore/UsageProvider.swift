import Foundation

public protocol UsageProvider: Sendable {
    var provider: ProviderID { get }
    func fetchSnapshot() async throws -> ProviderSnapshot
    func signIn() async throws -> ProviderSnapshot
    func signOut() async throws -> ProviderSnapshot
}

public extension UsageProvider {
    func signIn() async throws -> ProviderSnapshot {
        ProviderSnapshot(
            provider: provider,
            plan: "",
            connectionState: .unsupported,
            limits: [],
            connectedVia: "Sign-in is not yet supported"
        )
    }

    func signOut() async throws -> ProviderSnapshot {
        ProviderSnapshot(
            provider: provider,
            plan: "",
            connectionState: .notConnected,
            limits: [],
            connectedVia: "Not connected"
        )
    }
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

    public func signIn() async throws -> ProviderSnapshot {
        ProviderSnapshot(
            provider: provider,
            plan: "",
            connectionState: .unsupported,
            limits: [],
            connectedVia: "Sign-in is not yet supported"
        )
    }
}
