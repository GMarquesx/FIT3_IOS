import SwiftUI

/// Leitor minimo de "d" de SVG (M L H V C S Q T A Z, absolutos e relativos) para desenhar
/// os icones do design exatamente como no artifact.
enum SVGPath {

    static func parse(_ d: String) -> Path {
        var path = Path()
        let tokens = tokenize(d)
        var i = 0
        var cmd: Character = "M"
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastControl: CGPoint?
        var lastCmd: Character = " "

        func number() -> CGFloat {
            guard i < tokens.count, case .number(let v) = tokens[i] else { return 0 }
            i += 1
            return v
        }

        func hasNumber() -> Bool {
            guard i < tokens.count, case .number = tokens[i] else { return false }
            return true
        }

        while i < tokens.count {
            if case .command(let c) = tokens[i] {
                cmd = c
                i += 1
            }
            let rel = cmd.isLowercase
            let base = rel ? current : .zero
            switch cmd {
            case "M", "m":
                let p = CGPoint(x: base.x + number(), y: base.y + number())
                path.move(to: p)
                current = p
                start = p
                lastControl = nil
                cmd = rel ? "l" : "L"
                lastCmd = "M"
                continue
            case "L", "l":
                let p = CGPoint(x: base.x + number(), y: base.y + number())
                path.addLine(to: p)
                current = p
                lastControl = nil
            case "H", "h":
                let x = (rel ? current.x : 0) + number()
                current = CGPoint(x: x, y: current.y)
                path.addLine(to: current)
                lastControl = nil
            case "V", "v":
                let y = (rel ? current.y : 0) + number()
                current = CGPoint(x: current.x, y: y)
                path.addLine(to: current)
                lastControl = nil
            case "C", "c":
                let c1 = CGPoint(x: base.x + number(), y: base.y + number())
                let c2 = CGPoint(x: base.x + number(), y: base.y + number())
                let p = CGPoint(x: base.x + number(), y: base.y + number())
                path.addCurve(to: p, control1: c1, control2: c2)
                lastControl = c2
                current = p
            case "S", "s":
                var c1 = current
                if let lc = lastControl, "CcSs".contains(lastCmd) {
                    c1 = CGPoint(x: 2 * current.x - lc.x, y: 2 * current.y - lc.y)
                }
                let c2 = CGPoint(x: base.x + number(), y: base.y + number())
                let p = CGPoint(x: base.x + number(), y: base.y + number())
                path.addCurve(to: p, control1: c1, control2: c2)
                lastControl = c2
                current = p
            case "Q", "q":
                let c = CGPoint(x: base.x + number(), y: base.y + number())
                let p = CGPoint(x: base.x + number(), y: base.y + number())
                path.addQuadCurve(to: p, control: c)
                lastControl = c
                current = p
            case "T", "t":
                var c = current
                if let lc = lastControl, "QqTt".contains(lastCmd) {
                    c = CGPoint(x: 2 * current.x - lc.x, y: 2 * current.y - lc.y)
                }
                let p = CGPoint(x: base.x + number(), y: base.y + number())
                path.addQuadCurve(to: p, control: c)
                lastControl = c
                current = p
            case "A", "a":
                let rx = number()
                let ry = number()
                let rot = number()
                let large = number() != 0
                let sweep = number() != 0
                let p = CGPoint(x: base.x + number(), y: base.y + number())
                addArc(to: &path, from: current, to: p, rx: rx, ry: ry, rotation: rot,
                       largeArc: large, sweep: sweep)
                current = p
                lastControl = nil
            case "Z", "z":
                path.closeSubpath()
                current = start
                lastControl = nil
                lastCmd = cmd
                continue
            default:
                i += 1
                continue
            }
            lastCmd = cmd
        }
        return path
    }

    private enum Token {
        case command(Character)
        case number(CGFloat)
    }

    private static func tokenize(_ d: String) -> [Token] {
        var out: [Token] = []
        let chars = Array(d)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isLetter && c != "e" && c != "E" {
                out.append(.command(c))
                i += 1
            } else if c == "-" || c == "+" || c == "." || c.isNumber {
                var s = String(c)
                var seenDot = c == "."
                var seenExp = false
                i += 1
                while i < chars.count {
                    let n = chars[i]
                    if n.isNumber {
                        s.append(n)
                    } else if n == "." && !seenDot && !seenExp {
                        seenDot = true
                        s.append(n)
                    } else if (n == "e" || n == "E") && !seenExp {
                        seenExp = true
                        s.append(n)
                    } else if (n == "-" || n == "+") && (s.last == "e" || s.last == "E") {
                        s.append(n)
                    } else {
                        break
                    }
                    i += 1
                }
                out.append(.number(CGFloat(Double(s) ?? 0)))
            } else {
                i += 1
            }
        }
        return out
    }

    /// Arco eliptico do SVG convertido para curvas de Bezier (algoritmo da especificacao SVG, F.6).
    private static func addArc(to path: inout Path, from p0: CGPoint, to p1: CGPoint,
                               rx rxIn: CGFloat, ry ryIn: CGFloat, rotation: CGFloat,
                               largeArc: Bool, sweep: Bool) {
        var rx = abs(rxIn)
        var ry = abs(ryIn)
        if rx == 0 || ry == 0 || p0 == p1 {
            path.addLine(to: p1)
            return
        }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2
        let dy = (p0.y - p1.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy

        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let s = sqrt(lambda)
            rx *= s
            ry *= s
        }
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coef = sqrt(max(0, num / den))
        if largeArc == sweep { coef = -coef }
        let cxp = coef * (rx * y1p / ry)
        let cyp = coef * -(ry * x1p / rx)
        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let len = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
            var a = acos(max(-1, min(1, dot / len)))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }

        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var dTheta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && dTheta > 0 { dTheta -= 2 * .pi }
        if sweep && dTheta < 0 { dTheta += 2 * .pi }

        let segments = Int(ceil(abs(dTheta) / (.pi / 2)))
        let delta = dTheta / CGFloat(segments)
        let t = 4.0 / 3.0 * tan(delta / 4)

        func point(_ a: CGFloat) -> CGPoint {
            let x = rx * cos(a)
            let y = ry * sin(a)
            return CGPoint(x: cx + cosPhi * x - sinPhi * y, y: cy + sinPhi * x + cosPhi * y)
        }
        func derivative(_ a: CGFloat) -> CGPoint {
            let x = -rx * sin(a)
            let y = ry * cos(a)
            return CGPoint(x: cosPhi * x - sinPhi * y, y: sinPhi * x + cosPhi * y)
        }

        var a = theta1
        for _ in 0..<segments {
            let b = a + delta
            let pa = point(a)
            let pb = point(b)
            let da = derivative(a)
            let db = derivative(b)
            let c1 = CGPoint(x: pa.x + t * da.x, y: pa.y + t * da.y)
            let c2 = CGPoint(x: pb.x - t * db.x, y: pb.y - t * db.y)
            path.addCurve(to: pb, control1: c1, control2: c2)
            a = b
        }
    }

    /// Circulo como caminho SVG (para icones que usam <circle>).
    static func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> String {
        return "M\(cx - r) \(cy) a\(r) \(r) 0 1 0 \(2 * r) 0 a\(r) \(r) 0 1 0 \(-2 * r) 0 z"
    }
}

/// Icone de traco do design (viewBox 24x24).
struct EloIcon: View {
    let paths: [String]
    var size: CGFloat = 24
    var lineWidth: CGFloat = 2
    var color: Color = EloColor.text
    var fillOpacity: Double = 0
    var filled: Bool = false

    var body: some View {
        Canvas { ctx, canvasSize in
            let scale = canvasSize.width / 24
            let transform = CGAffineTransform(scaleX: scale, y: scale)
            for d in paths {
                let p = SVGPath.parse(d).applying(transform)
                if filled {
                    ctx.fill(p, with: .color(color))
                    continue
                }
                if fillOpacity > 0 {
                    ctx.fill(p, with: .color(color.opacity(fillOpacity)))
                }
                ctx.stroke(p, with: .color(color),
                           style: StrokeStyle(lineWidth: lineWidth * scale, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Caminhos dos icones usados no artifact.
enum Icons {
    static let sync = ["M20 12a8 8 0 0 1-14.3 4.9", "M4 12a8 8 0 0 1 14.3-4.9", "M18 3v4.5h-4.5", "M6 21v-4.5h4.5"]
    static let profile = [SVGPath.circle(12, 8, 4), "M4.5 20a7.5 7.5 0 0 1 15 0"]
    static let chevronRight = ["M9 5l7 7-7 7"]
    static let chevronLeft = ["M15 5l-7 7 7 7"]
    static let bubble = ["M4 20l1.8-4.6A8 8 0 1 1 9 19.6z"]
    static let appBubble = ["M5 18l1.5-4A7 7 0 1 1 10 18.5z"]
    static let moon = ["M20 14.5A8 8 0 1 1 9.5 4a6.5 6.5 0 0 0 10.5 10.5z"]
    static let flame = ["M12 3c1 3.5 5 5.5 5 10a5 5 0 0 1-10 0c0-2.2 1-3.6 2-4.5 0 1.8 1 3 2 3 0-3.5-.5-5.5 1-8.5z"]
    static let heart = ["M12 20s-7-4.4-7-10a4 4 0 0 1 7-2.6A4 4 0 0 1 19 10c0 5.6-7 10-7 10z"]
    static let oxygen = [SVGPath.circle(9, 14, 5), SVGPath.circle(17, 7, 3)]
    static let today = ["M3 12h4l3 7 4-14 3 7h4"]
    static let workout = ["M12 21s-6-5.3-6-11a6 6 0 0 1 12 0c0 5.7-6 11-6 11z", SVGPath.circle(12, 10, 2.2)]
    static let bell = ["M6 16v-5a6 6 0 0 1 12 0v5l1.5 2h-15z", "M10 20.5a2 2 0 0 0 4 0"]
    static let console = ["M5 4h14a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2z",
                          "M7 9l3 3-3 3", "M13 15h4"]
    static let rotateLeft = ["M4 12a8 8 0 1 0 2.3-5.7", "M4 4v4.5h4.5"]
    static let rotateRight = ["M20 12a8 8 0 1 1-2.3-5.7", "M20 4v4.5h-4.5"]
    static let shield = ["M12 3l7 3v6c0 4.5-3 7.5-7 9-4-1.5-7-4.5-7-9V6z", "M9 12l2 2 4-4"]
    static let info = [SVGPath.circle(12, 12, 9), "M12 8v5", "M12 16.5v.01"]
    static let close = ["M6 6l12 12M18 6L6 18"]
    static let phone = ["M6.6 10.8a15.2 15.2 0 0 0 6.6 6.6l2.2-2.2a1 1 0 0 1 1-.25 11.4 11.4 0 0 0 3.6.57 1 1 0 0 1 1 1V20a1 1 0 0 1-1 1A17 17 0 0 1 3 4a1 1 0 0 1 1-1h3.5a1 1 0 0 1 1 1c0 1.25.2 2.45.57 3.6a1 1 0 0 1-.25 1z"]
}
