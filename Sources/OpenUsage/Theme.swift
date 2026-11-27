import AppKit
import CoreGraphics
import CoreText
import Foundation
import OpenUsageCore
import SwiftUI

extension SRGBColor {
    var swiftUIColor: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

enum Theme {
    static let background = SRGBColor(hex: "#17191E")
    static let cardBackground = SRGBColor(hex: "#1F2228")
    static let selectedBackground = SRGBColor(hex: "#262A32")
    static let divider = SRGBColor(hex: "#262A31")
    static let border = SRGBColor(hex: "#30343C")
    static let selectedBorder = SRGBColor(hex: "#52525B")
    static let sidebarSelectedBorder = SRGBColor(hex: "#3F434C")
    static let segmentedActive = SRGBColor(hex: "#3F434C")
    static let dashedBorder = SRGBColor(hex: "#3F434C")
    static let ringTrack = SRGBColor(hex: "#2A2E36")
    static let barTrack = SRGBColor(hex: "#2A2E36")
    static let sparklineBar = SRGBColor(hex: "#52525B")
    static let dimmedIcon = SRGBColor(hex: "#71717A")
    static let textPrimary = SRGBColor(hex: "#F3F4F6")
    static let textSecondary = SRGBColor(hex: "#D4D4D8")
    static let textMuted = SRGBColor(hex: "#A1A1AA")
    static let limitsHitRed = SRGBColor(hex: "#F87171")
    static let trafficClose = SRGBColor(hex: "#FF5F57")
    static let trafficMinimize = SRGBColor(hex: "#FEBC2E")
    static let trafficZoom = SRGBColor(hex: "#28C840")
    static let linkColor = SRGBColor(hex: "#93C5FD")
    static let linkHoverColor = SRGBColor(hex: "#BFDBFE")
    static let neutralButtonFill = SRGBColor(hex: "#F4F4F5")
    static let neutralButtonText = SRGBColor(hex: "#17191E")
    static let menuBarBackground = SRGBColor(hex: "#1D2026")
    static let modelShades: [SRGBColor] = [
        SRGBColor(hex: "#E4E4E7"),
        SRGBColor(hex: "#A1A1AA"),
        SRGBColor(hex: "#52525B"),
        SRGBColor(hex: "#3F3F46")
    ]

    private static let fontRegistrationLock = NSLock()
    private nonisolated(unsafe) static var didRegisterFonts = false

    /// Registers bundled JetBrains Mono `.ttf` files with CoreText in `.process` scope.
    /// Safe to call headless (before `NSApplication` startup) and idempotent across repeated calls.
    static func registerBundledFonts() {
        fontRegistrationLock.lock()
        defer { fontRegistrationLock.unlock() }
        guard !didRegisterFonts else { return }

        var fontURLs = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? []
        if fontURLs.isEmpty {
            fontURLs = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        }

        for url in fontURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var error: Unmanaged<CFError>?
            _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        }

        didRegisterFonts = true
    }

    /// Shared SwiftUI monospaced font helper for all screens (JetBrains Mono with SF Mono fallback).
    static func mono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font(monoCTFont(size: size, weight: weight))
    }

    /// Headless-safe CoreText monospaced font helper (JetBrains Mono with SF Mono fallback).
    static func monoCTFont(size: CGFloat, weight: Font.Weight = .regular) -> CTFont {
        registerBundledFonts()

        let jetBrainsName: String
        let sfMonoName: String
        switch weight {
        case .bold, .heavy, .black:
            jetBrainsName = "JetBrainsMono-Bold"
            sfMonoName = "SFMono-Bold"
        case .semibold:
            jetBrainsName = "JetBrainsMono-SemiBold"
            sfMonoName = "SFMono-Semibold"
        case .medium:
            jetBrainsName = "JetBrainsMono-Medium"
            sfMonoName = "SFMono-Medium"
        default:
            jetBrainsName = "JetBrainsMono-Regular"
            sfMonoName = "SFMono-Regular"
        }

        if let jetBrains = matchedCTFont(postScriptName: jetBrainsName, size: size) {
            return jetBrains
        }
        if let sfMono = matchedCTFont(postScriptName: sfMonoName, size: size) {
            return sfMono
        }
        if let fixedPitch = CTFontCreateUIFontForLanguage(.userFixedPitch, size, nil) {
            return fixedPitch
        }
        return CTFontCreateWithName("Menlo-Regular" as CFString, size, nil)
    }

    private static func matchedCTFont(postScriptName: String, size: CGFloat) -> CTFont? {
        let descriptor = CTFontDescriptorCreateWithNameAndSize(postScriptName as CFString, size)
        guard let matched = CTFontDescriptorCreateMatchingFontDescriptor(descriptor, nil) else {
            return nil
        }
        let font = CTFontCreateWithFontDescriptor(matched, size, nil)
        guard (CTFontCopyPostScriptName(font) as String) == postScriptName else {
            return nil
        }
        return font
    }
}
