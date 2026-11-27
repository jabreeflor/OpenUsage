import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import OpenUsageCore
import UniformTypeIdentifiers

enum MenuBarRenderStyle {
    /// Transparent background sized for macOS `MenuBarExtra` label (`isTemplate = false`).
    case liveMenuBar
    /// Dark macOS menu bar strip (`#1D2026`, 28 pt tall), unhighlighted bare label for offscreen snapshots.
    case snapshotStrip
}

enum MenuBarLabelRenderer {
    private static let logoSize: CGFloat = 11.0
    private static let logoTextGap: CGFloat = 3.0
    private static let itemGap: CGFloat = 9.0
    private static let liveHeight: CGFloat = 22.0
    private static let liveHorizontalPadding: CGFloat = 2.0

    private static let stripHeight: CGFloat = 28.0
    private static let stripHorizontalPadding: CGFloat = 12.0

    private struct RenderItem {
        let provider: ProviderID?
        let logoColor: CGColor
        let text: String
        let textColor: CGColor
    }

    static func renderMenuBarImage(
        snapshots: [ProviderSnapshot],
        yellowFrom: Int,
        redFrom: Int,
        scale: CGFloat = 2.0
    ) -> NSImage {
        guard let result = renderCGImage(
            snapshots: snapshots,
            yellowFrom: yellowFrom,
            redFrom: redFrom,
            style: .liveMenuBar,
            scale: scale
        ) else {
            let fallback = NSImage(size: NSSize(width: 24, height: liveHeight))
            fallback.isTemplate = false
            return fallback
        }
        let image = NSImage(cgImage: result.cgImage, size: result.pointSize)
        image.isTemplate = false
        return image
    }

    static func writeSnapshotPNG(
        to url: URL,
        snapshots: [ProviderSnapshot],
        yellowFrom: Int = DepletionColor.defaultYellowThreshold,
        redFrom: Int = DepletionColor.defaultRedThreshold,
        scale: CGFloat = 2.0
    ) throws {
        guard let result = renderCGImage(
            snapshots: snapshots,
            yellowFrom: yellowFrom,
            redFrom: redFrom,
            style: .snapshotStrip,
            scale: scale
        ) else {
            throw NSError(
                domain: "dev.jabree.OpenUsage.Snapshot",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to render menu bar image"]
            )
        }

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(
                domain: "dev.jabree.OpenUsage.Snapshot",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create PNG destination at \(url.path)"]
            )
        }

        let properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72.0 * scale,
            kCGImagePropertyDPIHeight: 72.0 * scale
        ]
        CGImageDestinationAddImage(destination, result.cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(
                domain: "dev.jabree.OpenUsage.Snapshot",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Failed to write PNG to \(url.path)"]
            )
        }
    }

    private static func buildItems(
        snapshots: [ProviderSnapshot],
        yellowFrom: Int,
        redFrom: Int
    ) -> [RenderItem] {
        var items: [RenderItem] = []
        let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let muted = Theme.textMuted.cgColor

        for snapshot in snapshots {
            switch snapshot.menuBarEntryState {
            case .connected(let percent):
                let color = DepletionColor.rgb(percent: percent, yellow: yellowFrom, red: redFrom).cgColor
                items.append(RenderItem(
                    provider: snapshot.provider,
                    logoColor: white,
                    text: "\(percent)%",
                    textColor: color
                ))
            case .dimmedPlaceholder:
                items.append(RenderItem(
                    provider: snapshot.provider,
                    logoColor: muted,
                    text: "--",
                    textColor: muted
                ))
            case .omitted:
                continue
            }
        }

        if items.isEmpty {
            // Honest empty state so the menu bar item remains visible and clickable without fake numbers.
            items.append(RenderItem(
                provider: nil,
                logoColor: muted,
                text: "--",
                textColor: muted
            ))
        }

        return items
    }

    private static func renderCGImage(
        snapshots: [ProviderSnapshot],
        yellowFrom: Int,
        redFrom: Int,
        style: MenuBarRenderStyle,
        scale: CGFloat
    ) -> (cgImage: CGImage, pointSize: CGSize)? {
        let items = buildItems(snapshots: snapshots, yellowFrom: yellowFrom, redFrom: redFrom)
        let font = Theme.monoCTFont(size: 11.0, weight: .bold)
        let capHeight = CTFontGetCapHeight(font)

        let measured: [(item: RenderItem, line: CTLine, width: CGFloat)] = items.map { item in
            let attributes: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: item.textColor
            ]
            let attr = CFAttributedStringCreate(
                kCFAllocatorDefault,
                item.text as CFString,
                attributes as CFDictionary
            )!
            let line = CTLineCreateWithAttributedString(attr)
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let typographicWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            return (item, line, ceil(typographicWidth))
        }

        var contentWidth: CGFloat = 0
        for (index, entry) in measured.enumerated() {
            if index > 0 { contentWidth += itemGap }
            contentWidth += logoSize + logoTextGap + entry.width
        }

        let pointSize: CGSize
        let contentOriginX: CGFloat
        let contentCenterY: CGFloat

        switch style {
        case .liveMenuBar:
            pointSize = CGSize(
                width: ceil(contentWidth + liveHorizontalPadding * 2),
                height: liveHeight
            )
            contentOriginX = liveHorizontalPadding
            contentCenterY = liveHeight / 2.0

        case .snapshotStrip:
            pointSize = CGSize(
                width: ceil(contentWidth + stripHorizontalPadding * 2),
                height: stripHeight
            )
            contentOriginX = stripHorizontalPadding
            contentCenterY = stripHeight / 2.0
        }

        let pixelWidth = max(1, Int(ceil(pointSize.width * scale)))
        let pixelHeight = max(1, Int(ceil(pointSize.height * scale)))

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        ctx.setAllowsFontSmoothing(true)
        ctx.setShouldSmoothFonts(true)

        // Flip to top-left (y-down) coordinate system in points so SVG paths draw upright.
        ctx.translateBy(x: 0, y: CGFloat(pixelHeight))
        ctx.scaleBy(x: scale, y: -scale)

        if style == .snapshotStrip {
            ctx.setFillColor(Theme.menuBarBackground.cgColor)
            ctx.fill(CGRect(origin: .zero, size: pointSize))
        }

        var cursorX = contentOriginX
        let baselineY = contentCenterY + capHeight / 2.0

        for (index, entry) in measured.enumerated() {
            if index > 0 { cursorX += itemGap }

            let logoOriginY = contentCenterY - logoSize / 2.0
            if let provider = entry.item.provider {
                drawProviderLogo(
                    provider,
                    in: ctx,
                    at: CGPoint(x: cursorX, y: logoOriginY),
                    size: logoSize,
                    color: entry.item.logoColor
                )
            } else {
                drawEmptyRingGlyph(
                    in: ctx,
                    at: CGPoint(x: cursorX, y: logoOriginY),
                    size: logoSize,
                    color: entry.item.logoColor
                )
            }

            cursorX += logoSize + logoTextGap

            ctx.saveGState()
            ctx.translateBy(x: cursorX, y: baselineY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textMatrix = .identity
            ctx.textPosition = .zero
            CTLineDraw(entry.line, ctx)
            ctx.restoreGState()

            cursorX += entry.width
        }

        guard let cgImage = ctx.makeImage() else { return nil }
        return (cgImage, pointSize)
    }

    private static func drawProviderLogo(
        _ provider: ProviderID,
        in ctx: CGContext,
        at origin: CGPoint,
        size: CGFloat,
        color: CGColor
    ) {
        ctx.saveGState()
        let scale = size / 24.0
        ctx.translateBy(x: origin.x, y: origin.y)
        ctx.scaleBy(x: scale, y: scale)
        ctx.addPath(provider.logoCGPath())
        ctx.setFillColor(color)
        ctx.fillPath(using: .winding)
        ctx.restoreGState()
    }

    private static func drawEmptyRingGlyph(
        in ctx: CGContext,
        at origin: CGPoint,
        size: CGFloat,
        color: CGColor
    ) {
        ctx.saveGState()
        let inset: CGFloat = 1.5
        let rect = CGRect(
            x: origin.x + inset,
            y: origin.y + inset,
            width: size - inset * 2,
            height: size - inset * 2
        )
        ctx.setStrokeColor(color)
        ctx.setLineWidth(1.6)
        ctx.strokeEllipse(in: rect)
        ctx.restoreGState()
    }
}
