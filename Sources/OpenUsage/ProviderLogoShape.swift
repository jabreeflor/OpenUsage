import CoreGraphics
import OpenUsageCore
import SwiftUI

struct ProviderLogoShape: Shape {
    let provider: ProviderID

    func path(in rect: CGRect) -> Path {
        let raw = provider.logoCGPath()
        let scaleX = rect.width / 24.0
        let scaleY = rect.height / 24.0
        let scale = min(scaleX, scaleY)
        let offsetX = rect.minX + (rect.width - 24.0 * scale) / 2.0
        let offsetY = rect.minY + (rect.height - 24.0 * scale) / 2.0

        var transform = CGAffineTransform(translationX: offsetX, y: offsetY)
            .scaledBy(x: scale, y: scale)
        guard let scaled = raw.copy(using: &transform) else {
            return Path()
        }
        return Path(scaled)
    }
}
