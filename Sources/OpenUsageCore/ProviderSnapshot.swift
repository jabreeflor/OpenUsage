import Foundation

public enum ConnectionState: String, Codable, Sendable, Equatable, Hashable {
    case connected
    case expired
    case notConnected
    case connecting
    case waitingForKeychain
    case unsupported
}

public enum MenuBarEntryState: Sendable, Equatable {
    case connected(percent: Int)
    case dimmedPlaceholder
    case omitted
}

public struct ProviderSnapshot: Identifiable, Codable, Sendable, Equatable {
    public var id: ProviderID { provider }

    public let provider: ProviderID
    public let plan: String
    public let connectionState: ConnectionState
    public let limits: [UsageLimit]
    public let connectedVia: String
    public let updatedAt: Date
    public let showMenuBarPlaceholderWhileConnecting: Bool
    /// Indicates that an authenticated session or stored credential exists even when limits are currently unavailable,
    /// allowing the user to disconnect (Sign out) from Accounts.
    public let canSignOut: Bool

    public init(
        provider: ProviderID,
        plan: String,
        connectionState: ConnectionState,
        limits: [UsageLimit],
        connectedVia: String,
        updatedAt: Date = Date(),
        showMenuBarPlaceholderWhileConnecting: Bool = false,
        canSignOut: Bool = false
    ) {
        self.provider = provider
        self.plan = plan
        self.connectionState = connectionState
        self.limits = limits
        self.connectedVia = connectedVia
        self.updatedAt = updatedAt
        self.showMenuBarPlaceholderWhileConnecting = showMenuBarPlaceholderWhileConnecting
        self.canSignOut = canSignOut
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case plan
        case connectionState
        case limits
        case connectedVia
        case updatedAt
        case showMenuBarPlaceholderWhileConnecting
        case canSignOut
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.provider = try container.decode(ProviderID.self, forKey: .provider)
        self.plan = try container.decode(String.self, forKey: .plan)
        self.connectionState = try container.decode(ConnectionState.self, forKey: .connectionState)
        self.limits = try container.decode([UsageLimit].self, forKey: .limits)
        self.connectedVia = try container.decode(String.self, forKey: .connectedVia)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.showMenuBarPlaceholderWhileConnecting = try container.decodeIfPresent(Bool.self, forKey: .showMenuBarPlaceholderWhileConnecting) ?? false
        self.canSignOut = try container.decodeIfPresent(Bool.self, forKey: .canSignOut) ?? false
    }

    /// Returns the limit with the highest percent used. Ties break to the first occurrence.
    public var fullestLimit: UsageLimit? {
        guard var best = limits.first else { return nil }
        for limit in limits.dropFirst() where limit.percentUsed > best.percentUsed {
            best = limit
        }
        return best
    }

    public var menuBarEntryState: MenuBarEntryState {
        switch connectionState {
        case .connected:
            if let fullest = fullestLimit {
                return .connected(percent: fullest.percentUsed)
            }
            return .dimmedPlaceholder
        case .expired:
            return .dimmedPlaceholder
        case .connecting:
            return showMenuBarPlaceholderWhileConnecting ? .dimmedPlaceholder : .omitted
        case .notConnected, .unsupported, .waitingForKeychain:
            return .omitted
        }
    }
}
