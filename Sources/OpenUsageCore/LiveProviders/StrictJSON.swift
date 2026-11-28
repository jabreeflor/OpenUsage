import CoreFoundation
import Foundation

/// Strict JSON value parsing helpers shared by live usage providers.
internal enum StrictJSON {
    static func string(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Parses a finite `Double` from a JSON number, strictly rejecting booleans and strings.
    static func double(_ raw: Any?) -> Double? {
        guard let raw, !(raw is NSNull) else { return nil }
        if type(of: raw) == Bool.self { return nil }
        if CFGetTypeID(raw as AnyObject) == CFBooleanGetTypeID() { return nil }
        if raw is String { return nil }
        if let num = raw as? NSNumber {
            if CFGetTypeID(num) == CFBooleanGetTypeID() { return nil }
            let val = num.doubleValue
            return val.isFinite ? val : nil
        }
        return nil
    }

    /// Parses a finite `Double` from either a JSON number or numeric string (used for int64 timestamps encoded as strings).
    static func numericOrStringDouble(_ raw: Any?) -> Double? {
        if let d = double(raw) {
            return d
        }
        if let s = string(raw), let d = Double(s), d.isFinite {
            return d
        }
        return nil
    }

    /// Safely converts a finite non-negative `Double` to an `Int` within `0...maxValue` after rounding,
    /// returning `nil` without trapping when the value is non-finite or outside representable integer bounds.
    static func roundedNonNegativeInt(_ value: Double, maxValue: Int = Int.max) -> Int? {
        guard value.isFinite, value >= 0 else { return nil }
        let rounded = value.rounded()
        guard let converted = Int(exactly: rounded), converted >= 0, converted <= maxValue else {
            return nil
        }
        return converted
    }

    /// Parses a timestamp from ISO 8601 string, numeric Unix epoch (seconds or ms), or numeric string Unix epoch.
    static func timestamp(_ raw: Any?) -> Date? {
        if let parsed = LogTimestampParser.parseJSONTimestamp(raw) {
            return parsed
        }
        if let s = string(raw), let num = Double(s), num.isFinite {
            return LogTimestampParser.parseEpoch(num)
        }
        return nil
    }
}
