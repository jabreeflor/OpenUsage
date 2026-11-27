import CoreGraphics
import Foundation

/// Parses an SVG `d` path attribute string into a `CGPath` in SVG's y-down coordinate system.
/// Supports M/m, L/l, H/h, V/v, C/c, S/s, Q/q, T/t, A/a, and Z/z commands.
public enum SVGPathParser {
    public static func parse(_ d: String) -> CGPath {
        let path = CGMutablePath()
        var scanner = ScannerState(d)

        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastCubicControl: CGPoint?
        var lastQuadControl: CGPoint?
        var command: Character?

        while true {
            scanner.skipSeparators()
            if scanner.isAtEnd { break }

            if let cmd = scanner.peekCommand() {
                command = cmd
                scanner.advance()
            }

            guard let cmd = command else { break }

            switch cmd {
            case "M", "m":
                guard let x = scanner.readNumber(), let y = scanner.readNumber() else { break }
                let next = cmd == "m" ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                path.move(to: next)
                current = next
                subpathStart = next
                lastCubicControl = nil
                lastQuadControl = nil
                // Subsequent coordinate pairs are treated as implicit L/l.
                command = cmd == "m" ? "l" : "L"

            case "L", "l":
                guard let x = scanner.readNumber(), let y = scanner.readNumber() else { break }
                let next = cmd == "l" ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                path.addLine(to: next)
                current = next
                lastCubicControl = nil
                lastQuadControl = nil

            case "H", "h":
                guard let x = scanner.readNumber() else { break }
                let next = CGPoint(x: cmd == "h" ? current.x + x : x, y: current.y)
                path.addLine(to: next)
                current = next
                lastCubicControl = nil
                lastQuadControl = nil

            case "V", "v":
                guard let y = scanner.readNumber() else { break }
                let next = CGPoint(x: current.x, y: cmd == "v" ? current.y + y : y)
                path.addLine(to: next)
                current = next
                lastCubicControl = nil
                lastQuadControl = nil

            case "C", "c":
                guard let x1 = scanner.readNumber(), let y1 = scanner.readNumber(),
                      let x2 = scanner.readNumber(), let y2 = scanner.readNumber(),
                      let x = scanner.readNumber(), let y = scanner.readNumber() else { break }
                let c1 = cmd == "c" ? CGPoint(x: current.x + x1, y: current.y + y1) : CGPoint(x: x1, y: y1)
                let c2 = cmd == "c" ? CGPoint(x: current.x + x2, y: current.y + y2) : CGPoint(x: x2, y: y2)
                let end = cmd == "c" ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                path.addCurve(to: end, control1: c1, control2: c2)
                current = end
                lastCubicControl = c2
                lastQuadControl = nil

            case "S", "s":
                guard let x2 = scanner.readNumber(), let y2 = scanner.readNumber(),
                      let x = scanner.readNumber(), let y = scanner.readNumber() else { break }
                let c1: CGPoint
                if let prev = lastCubicControl {
                    c1 = CGPoint(x: 2 * current.x - prev.x, y: 2 * current.y - prev.y)
                } else {
                    c1 = current
                }
                let c2 = cmd == "s" ? CGPoint(x: current.x + x2, y: current.y + y2) : CGPoint(x: x2, y: y2)
                let end = cmd == "s" ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                path.addCurve(to: end, control1: c1, control2: c2)
                current = end
                lastCubicControl = c2
                lastQuadControl = nil

            case "Q", "q":
                guard let x1 = scanner.readNumber(), let y1 = scanner.readNumber(),
                      let x = scanner.readNumber(), let y = scanner.readNumber() else { break }
                let c = cmd == "q" ? CGPoint(x: current.x + x1, y: current.y + y1) : CGPoint(x: x1, y: y1)
                let end = cmd == "q" ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                path.addQuadCurve(to: end, control: c)
                current = end
                lastQuadControl = c
                lastCubicControl = nil

            case "T", "t":
                guard let x = scanner.readNumber(), let y = scanner.readNumber() else { break }
                let c: CGPoint
                if let prev = lastQuadControl {
                    c = CGPoint(x: 2 * current.x - prev.x, y: 2 * current.y - prev.y)
                } else {
                    c = current
                }
                let end = cmd == "t" ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                path.addQuadCurve(to: end, control: c)
                current = end
                lastQuadControl = c
                lastCubicControl = nil

            case "A", "a":
                guard let rx = scanner.readNumber(), let ry = scanner.readNumber(),
                      let xAxisRotation = scanner.readNumber(),
                      let largeArcFlag = scanner.readFlag(),
                      let sweepFlag = scanner.readFlag(),
                      let x = scanner.readNumber(), let y = scanner.readNumber() else { break }
                let end = cmd == "a" ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                addSVGArc(
                    to: path,
                    from: current,
                    to: end,
                    rx: rx,
                    ry: ry,
                    xAxisRotationDegrees: xAxisRotation,
                    largeArc: largeArcFlag,
                    sweep: sweepFlag
                )
                current = end
                lastCubicControl = nil
                lastQuadControl = nil

            case "Z", "z":
                path.closeSubpath()
                current = subpathStart
                lastCubicControl = nil
                lastQuadControl = nil
                command = nil

            default:
                break
            }
        }

        return path.copy() ?? path
    }

    /// Converts an SVG elliptical arc to cubic Bezier segments per W3C SVG 1.1 Implementation Notes F.6.5–F.6.6.
    private static func addSVGArc(
        to path: CGMutablePath,
        from p1: CGPoint,
        to p2: CGPoint,
        rx rawRx: CGFloat,
        ry rawRy: CGFloat,
        xAxisRotationDegrees: CGFloat,
        largeArc: Bool,
        sweep: Bool
    ) {
        if p1 == p2 { return }
        var rx = abs(rawRx)
        var ry = abs(rawRy)
        if rx == 0 || ry == 0 {
            path.addLine(to: p2)
            return
        }

        let phi = xAxisRotationDegrees * .pi / 180.0
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)

        let dx2 = (p1.x - p2.x) / 2.0
        let dy2 = (p1.y - p2.y) / 2.0

        let x1p = cosPhi * dx2 + sinPhi * dy2
        let y1p = -sinPhi * dx2 + cosPhi * dy2

        // Ensure radii are large enough
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1.0 {
            let scale = sqrt(lambda)
            rx *= scale
            ry *= scale
        }

        let rx2 = rx * rx
        let ry2 = ry * ry
        let x1p2 = x1p * x1p
        let y1p2 = y1p * y1p

        let num = max(0, rx2 * ry2 - rx2 * y1p2 - ry2 * x1p2)
        let den = rx2 * y1p2 + ry2 * x1p2
        let factor = (largeArc == sweep ? -1.0 : 1.0) * (den > 0 ? sqrt(num / den) : 0)

        let cxp = factor * (rx * y1p / ry)
        let cyp = factor * (-ry * x1p / rx)

        let cx = cosPhi * cxp - sinPhi * cyp + (p1.x + p2.x) / 2.0
        let cy = sinPhi * cxp + cosPhi * cyp + (p1.y + p2.y) / 2.0

        func vectorAngle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let mag = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
            let clamped = max(-1.0, min(1.0, mag > 0 ? dot / mag : 1.0))
            let angle = acos(clamped)
            return (ux * vy - uy * vx) < 0 ? -angle : angle
        }

        let ux = (x1p - cxp) / rx
        let uy = (y1p - cyp) / ry
        let vx = (-x1p - cxp) / rx
        let vy = (-y1p - cyp) / ry

        let theta1 = vectorAngle(1, 0, ux, uy)
        var dTheta = vectorAngle(ux, uy, vx, vy)

        if !sweep && dTheta > 0 {
            dTheta -= 2.0 * .pi
        } else if sweep && dTheta < 0 {
            dTheta += 2.0 * .pi
        }

        let segments = max(1, Int(ceil(abs(dTheta) / (.pi / 2.0))))
        let delta = dTheta / CGFloat(segments)
        let alpha = (4.0 / 3.0) * tan(delta / 4.0)

        var angle = theta1
        for _ in 0..<segments {
            let nextAngle = angle + delta
            let cos1 = cos(angle), sin1 = sin(angle)
            let cos2 = cos(nextAngle), sin2 = sin(nextAngle)

            let e1x = cos1 - alpha * sin1
            let e1y = sin1 + alpha * cos1
            let e2x = cos2 + alpha * sin2
            let e2y = sin2 - alpha * cos2

            func mapUnit(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                let sx = x * rx
                let sy = y * ry
                return CGPoint(
                    x: cosPhi * sx - sinPhi * sy + cx,
                    y: sinPhi * sx + cosPhi * sy + cy
                )
            }

            let c1 = mapUnit(e1x, e1y)
            let c2 = mapUnit(e2x, e2y)
            let endPt = mapUnit(cos2, sin2)
            path.addCurve(to: endPt, control1: c1, control2: c2)
            angle = nextAngle
        }
    }

    private struct ScannerState {
        private let chars: [Character]
        private var index: Int = 0

        init(_ string: String) {
            self.chars = Array(string)
        }

        var isAtEnd: Bool { index >= chars.count }

        mutating func advance() {
            if index < chars.count { index += 1 }
        }

        mutating func skipSeparators() {
            while index < chars.count {
                let c = chars[index]
                if c == " " || c == "\t" || c == "\n" || c == "\r" || c == "," {
                    index += 1
                } else {
                    break
                }
            }
        }

        func peekCommand() -> Character? {
            guard index < chars.count else { return nil }
            let c = chars[index]
            switch c {
            case "M", "m", "L", "l", "H", "h", "V", "v",
                 "C", "c", "S", "s", "Q", "q", "T", "t",
                 "A", "a", "Z", "z":
                return c
            default:
                return nil
            }
        }

        mutating func readFlag() -> Bool? {
            skipSeparators()
            guard index < chars.count else { return nil }
            let c = chars[index]
            if c == "0" {
                index += 1
                return false
            } else if c == "1" {
                index += 1
                return true
            }
            return nil
        }

        mutating func readNumber() -> CGFloat? {
            skipSeparators()
            guard index < chars.count else { return nil }

            let start = index
            if chars[index] == "+" || chars[index] == "-" {
                index += 1
            }

            var hasDigits = false
            while index < chars.count, chars[index].isASCII, chars[index].isNumber {
                hasDigits = true
                index += 1
            }

            if index < chars.count, chars[index] == "." {
                index += 1
                while index < chars.count, chars[index].isASCII, chars[index].isNumber {
                    hasDigits = true
                    index += 1
                }
            }

            guard hasDigits else {
                index = start
                return nil
            }

            if index < chars.count, chars[index] == "e" || chars[index] == "E" {
                let expStart = index
                index += 1
                if index < chars.count, chars[index] == "+" || chars[index] == "-" {
                    index += 1
                }
                var hasExpDigits = false
                while index < chars.count, chars[index].isASCII, chars[index].isNumber {
                    hasExpDigits = true
                    index += 1
                }
                if !hasExpDigits {
                    index = expStart
                }
            }

            let token = String(chars[start..<index])
            guard let value = Double(token) else {
                index = start
                return nil
            }
            return CGFloat(value)
        }
    }
}
