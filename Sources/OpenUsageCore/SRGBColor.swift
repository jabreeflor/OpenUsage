import Foundation

public struct SRGBColor: Codable, Sendable, Equatable, Hashable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double
    public let hex: String

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1.0, hex: String) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
        self.hex = hex
    }

    public init(hex: String, alpha: Double = 1.0) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        let normalizedHex = "#" + cleaned.uppercased()
        self.init(red: r, green: g, blue: b, alpha: alpha, hex: normalizedHex)
    }
}
