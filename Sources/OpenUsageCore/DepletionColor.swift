import Foundation

public enum DepletionLevel: String, Codable, Sendable, Equatable, Hashable {
    case green
    case yellow
    case red

    public var hex: String {
        switch self {
        case .green: "#4ADE80"
        case .yellow: "#FACC15"
        case .red: "#F87171"
        }
    }

    public var rgb: SRGBColor {
        SRGBColor(hex: hex)
    }
}

public enum DepletionColor {
    public static let defaultYellowThreshold: Int = 50
    public static let defaultRedThreshold: Int = 80

    public static let greenHex = "#4ADE80"
    public static let yellowHex = "#FACC15"
    public static let redHex = "#F87171"

    /// Pure function mapping usage percent and thresholds to a depletion level.
    /// - Green below `yellow`
    /// - Yellow from `yellow` up to (but excluding) `red`
    /// - Red from `red` upward
    public static func level(
        percent: Int,
        yellow: Int = defaultYellowThreshold,
        red: Int = defaultRedThreshold
    ) -> DepletionLevel {
        if percent >= red {
            return .red
        }
        if percent >= yellow {
            return .yellow
        }
        return .green
    }

    public static func hex(for level: DepletionLevel) -> String {
        level.hex
    }

    public static func rgb(for level: DepletionLevel) -> SRGBColor {
        level.rgb
    }

    public static func rgb(
        percent: Int,
        yellow: Int = defaultYellowThreshold,
        red: Int = defaultRedThreshold
    ) -> SRGBColor {
        level(percent: percent, yellow: yellow, red: red).rgb
    }
}
