import Foundation

public enum TokenFormatter {
    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    /// Formats token counts compactly to match the OpenUsage UI (`1.84M`, `800K`, `42.3M`, `950`).
    public static func formatTokens(_ count: Int) -> String {
        let clamped = max(0, count)
        if clamped < 1_000 {
            return "\(clamped)"
        }

        if clamped < 1_000_000 {
            let roundedK = Int((Double(clamped) / 1_000.0).rounded())
            if roundedK >= 1_000 {
                return "1.00M"
            }
            return "\(roundedK)K"
        }

        if clamped < 1_000_000_000 {
            let millions = Double(clamped) / 1_000_000.0
            if millions >= 999.95 {
                return "1.00B"
            }
            if millions >= 9.995 {
                return String(format: "%.1fM", locale: posixLocale, millions)
            }
            return String(format: "%.2fM", locale: posixLocale, millions)
        }

        let billions = Double(clamped) / 1_000_000_000.0
        if billions >= 9.995 {
            return String(format: "%.1fB", locale: posixLocale, billions)
        }
        return String(format: "%.2fB", locale: posixLocale, billions)
    }

    /// Formats integer counts with US comma grouping (`412`, `1,500`, `12,345`).
    public static func formatCount(_ count: Int) -> String {
        let clamped = max(0, count)
        let digits = String(clamped)
        guard digits.count > 3 else { return digits }

        var result = ""
        result.reserveCapacity(digits.count + digits.count / 3)
        let total = digits.count
        for (index, ch) in digits.enumerated() {
            if index > 0 && (total - index) % 3 == 0 {
                result.append(",")
            }
            result.append(ch)
        }
        return result
    }

    /// Formats a relative timestamp label for the dropdown header (`updated 1 min ago`).
    public static func updatedAgoText(from updatedAt: Date?, now: Date = Date()) -> String {
        guard let updatedAt else {
            return "not updated yet"
        }
        let elapsed = max(0, now.timeIntervalSince(updatedAt))
        let minutes = Int(elapsed / 60.0)
        if minutes < 1 {
            return "updated just now"
        }
        if minutes < 60 {
            return "updated \(minutes) min ago"
        }
        let hours = minutes / 60
        return hours == 1 ? "updated 1 hr ago" : "updated \(hours) hrs ago"
    }
}
