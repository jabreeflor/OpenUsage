import Foundation

/// Refresh scheduling policy for usage snapshots:
/// - Every 60 s while the dropdown popover is open.
/// - Every 5 min (300 s) otherwise.
public enum RefreshPolicy {
    public static let openDropdownInterval: TimeInterval = 60
    public static let backgroundInterval: TimeInterval = 300

    public static func interval(isDropdownOpen: Bool) -> TimeInterval {
        isDropdownOpen ? openDropdownInterval : backgroundInterval
    }

    public static func nextRefreshDate(
        from lastRefresh: Date?,
        isDropdownOpen: Bool,
        now: Date = Date()
    ) -> Date {
        guard let lastRefresh else {
            return now
        }
        let target = lastRefresh.addingTimeInterval(interval(isDropdownOpen: isDropdownOpen))
        return max(now, target)
    }

    public static func delayUntilNextRefresh(
        from lastRefresh: Date?,
        isDropdownOpen: Bool,
        now: Date = Date()
    ) -> TimeInterval {
        let next = nextRefreshDate(from: lastRefresh, isDropdownOpen: isDropdownOpen, now: now)
        return max(0, next.timeIntervalSince(now))
    }

    public static func shouldRefresh(
        lastRefresh: Date?,
        isDropdownOpen: Bool,
        now: Date = Date()
    ) -> Bool {
        guard let lastRefresh else {
            return true
        }
        return now.timeIntervalSince(lastRefresh) >= interval(isDropdownOpen: isDropdownOpen)
    }
}
