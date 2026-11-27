import Foundation

/// Stub `TokenLogSource` for Cursor: Cursor does not store local token logs on disk.
/// Milestone 6 may replace or augment this with account-backed usage data.
public struct CursorTokenLogSource: IncrementalTokenLogSource, Sendable {
    public let provider: ProviderID = .cursor
    public let toolSource: LocalToolSource = .cursor
    public let sourceLabel: String = "from your Cursor account"

    public init() {}

    public var watchDirectories: [URL] {
        []
    }

    public func refresh(state: inout SourceCacheState, calendar: Calendar) throws -> [TokenBucket] {
        []
    }
}
