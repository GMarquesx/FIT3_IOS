import SwiftUI
import QuartzCore

// MARK: - Aparencia salva (tela "Sua Galaxy Fit3")

struct BandAppearance: Codable, Equatable {
    var bg: String = "grafite"
    var face: String = "digital"
    var accent: String = "teal"
    var strap: String = "preto"

    static let backgrounds = ["grafite", "oceano", "linhas", "pontos"]
    static let faces = ["digital", "analog", "info"]
    static let accents = ["teal", "ambar", "azul", "rosa"]
    static let straps = ["preto", "cinza", "areia", "rosa"]

    static func accentColor(_ id: String) -> Color {
        switch id {
        case "ambar": return Color(hex: 0xF5A524)
        case "azul": return Color(hex: 0x8AB4FF)
        case "rosa": return Color(hex: 0xF27BA8)
        default: return Color(hex: 0x3DD6B5)
        }
    }

    static func strapColors(_ id: String) -> (main: Color, edge: Color) {
        switch id {
        case "cinza": return (Color(hex: 0x5B6370), Color(hex: 0x3F4651))
        case "areia": return (Color(hex: 0xBFAE8E), Color(hex: 0x9C8C6E))
        case "rosa": return (Color(hex: 0xD49DAD), Color(hex: 0xB07F8E))
        default: return (Color(hex: 0x1B1F25), Color(hex: 0x0E1116))
        }
    }

    static func backgroundName(_ id: String) -> String {
        switch id {
        case "oceano": return L("Ocean")
        case "linhas": return L("Lines")
        case "pontos": return L("Dots")
        default: return L("Graphite")
        }
    }

    static func faceName(_ id: String) -> String {
        switch id {
        case "analog": return L("Analog")
        case "info": return L("Info")
        default: return L("Digital")
        }
    }

    static func accentName(_ id: String) -> String {
        switch id {
        case "ambar": return L("Amber")
        case "azul": return L("Blue")
        case "rosa": return L("Pink")
        default: return L("Aqua")
        }
    }

    static func strapName(_ id: String) -> String {
        switch id {
        case "cinza": return L("Gray")
        case "areia": return L("Sand")
        case "rosa": return L("Pink")
        default: return L("Black")
        }
    }

    static func load() -> BandAppearance {
        guard let data = UserDefaults.standard.data(forKey: "bandAppearance"),
              let value = try? JSONDecoder().decode(BandAppearance.self, from: data) else {
            return BandAppearance()
        }
        return value
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "bandAppearance")
        }
    }
}

/// Fundo do mostrador (grafite, oceano, linhas a 135 graus, pontos a cada 8 px).
struct ScreenBackground: View {
    let id: String
    let accent: Color

    var body: some View {
        switch id {
        case "oceano":
            Color(hex: 0x0E2A3B)
        case "linhas":
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(hex: 0x0B0D10)))
                // repeating-linear-gradient(135deg, fundo 0 6px, cor 6px 7px): periodo 7 px na diagonal
                let period: CGFloat = 7 * sqrt(2)
                var x: CGFloat = -size.height
                while x < size.width + size.height {
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: 0))
                    p.addLine(to: CGPoint(x: x + size.height, y: size.height))
                    ctx.stroke(p, with: .color(accent.opacity(0.22)), lineWidth: 1)
                    x += period
                }
            }
        case "pontos":
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(hex: 0x0B0D10)))
                var y: CGFloat = 4
                while y < size.height {
                    var x: CGFloat = 4
                    while x < size.width {
                        ctx.fill(Path(ellipseIn: CGRect(x: x - 1.3, y: y - 1.3, width: 2.6, height: 2.6)),
                                 with: .color(accent.opacity(0.4)))
                        x += 8
                    }
                    y += 8
                }
            }
        default:
            Color(hex: 0x0B0D10)
        }
    }
}

// MARK: - O que aparece na tela da pulseira

enum BandScreen: Equatable {
    case clock
    case message(app: String, from: String, text: String)
    case call(name: String)
}

struct BandScreenContent: View {
    let screen: BandScreen
    let appearance: BandAppearance
    let now: Date
    let elapsed: Double
    let bpm: String

    private var accent: Color { BandAppearance.accentColor(appearance.accent) }

    var body: some View {
        let appear = min(1, elapsed / 0.3)
        ZStack {
            ScreenBackground(id: appearance.bg, accent: accent)
            switch screen {
            case .clock:
                clockFace
            case .message(let app, let from, let text):
                message(app: app, from: from, text: text)
                    .opacity(appear)
                    .offset(y: 8 * (1 - appear))
            case .call(let name):
                call(name: name)
                    .opacity(appear)
                    .offset(y: 8 * (1 - appear))
            }
        }
        .frame(width: 80, height: 136)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private var hh: String { String(format: "%02d", Calendar.current.component(.hour, from: now)) }
    private var mm: String { String(format: "%02d", Calendar.current.component(.minute, from: now)) }

    @ViewBuilder
    private var clockFace: some View {
        switch appearance.face {
        case "analog":
            VStack(spacing: 6) {
                AnalogDial(now: now, accent: accent).frame(width: 72, height: 72)
                Text(BandDates.short(now)).font(EloFont.inter(9)).foregroundColor(EloColor.secondary)
            }
        case "info":
            VStack(spacing: 0) {
                Text("\(hh):\(mm)").font(EloFont.grotesk(22)).foregroundColor(accent)
                VStack(spacing: 5) {
                    infoRow(L("bpm"), bpm)
                    infoRow(L("steps"), "—")
                    infoRow(L("SpO₂"), "—")
                    infoRow(L("kcal"), "—")
                }
                .frame(width: 56)
                .padding(.top, 8)
            }
        default:
            VStack(spacing: 0) {
                Text(BandDates.short(now)).font(EloFont.inter(9, .medium)).foregroundColor(EloColor.secondary)
                Text(hh).font(EloFont.grotesk(36)).foregroundColor(EloColor.text).frame(height: 36)
                Text(mm).font(EloFont.grotesk(36)).foregroundColor(accent).frame(height: 36)
                Text(L("%@ steps", "—")).font(EloFont.inter(8)).foregroundColor(EloColor.secondary).padding(.top, 4)
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundColor(EloColor.secondary)
            Spacer(minLength: 0)
            Text(value).fontWeight(.semibold).foregroundColor(EloColor.text)
        }
        .font(EloFont.inter(9))
    }

    private func message(app: String, from: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3).fill(Color(hex: 0x3A404A))
                    EloIcon(paths: Icons.appBubble, size: 6, lineWidth: 3, color: .white)
                }
                .frame(width: 10, height: 10)
                Text(app).font(EloFont.inter(7, .semibold)).foregroundColor(EloColor.secondary).lineLimit(1)
            }
            Text(from).font(EloFont.inter(11, .bold)).foregroundColor(EloColor.text).lineLimit(1)
            Text(text).font(EloFont.inter(10)).foregroundColor(EloColor.textSoft).lineSpacing(2).lineLimit(5)
            Spacer(minLength: 0)
            Text(L("now")).font(EloFont.inter(7)).foregroundColor(EloColor.secondary)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func call(name: String) -> some View {
        let pulse = elapsed.truncatingRemainder(dividingBy: 1.2) / 1.2
        return VStack(spacing: 4) {
            Text(L("CALL")).font(EloFont.inter(7, .semibold)).tracking(0.3).foregroundColor(EloColor.secondary)
            ZStack {
                Circle()
                    .stroke(EloColor.accent.opacity(0.55 * (1 - pulse)), lineWidth: 9 * pulse)
                    .frame(width: 30 + 9 * pulse, height: 30 + 9 * pulse)
                Circle().fill(EloColor.border).frame(width: 30, height: 30)
                Text(String(name.prefix(1))).font(EloFont.inter(13, .bold)).foregroundColor(EloColor.text)
            }
            .frame(width: 30, height: 30)
            .padding(.top, 4)
            Text(name).font(EloFont.inter(13, .bold)).foregroundColor(EloColor.text).lineLimit(1).padding(.top, 2)
            Text(L("calling…")).font(EloFont.inter(8)).foregroundColor(EloColor.accent)
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(EloColor.danger)
                    EloIcon(paths: Icons.close, size: 12, lineWidth: 2.6, color: .white)
                }
                .frame(width: 22, height: 22)
                ZStack {
                    Circle().fill(EloColor.accent)
                    EloIcon(paths: Icons.phone, size: 12, color: EloColor.bg, filled: true)
                }
                .frame(width: 22, height: 22)
            }
        }
        .padding(.top, 9)
        .padding(.horizontal, 6)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AnalogDial: View {
    let now: Date
    let accent: Color

    var body: some View {
        Canvas { ctx, size in
            let s = size.width / 80
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
            ctx.stroke(Path(ellipseIn: CGRect(x: 4 * s, y: 4 * s, width: 72 * s, height: 72 * s)),
                       with: .color(Color(hex: 0x2F343C)), lineWidth: 2 * s)
            var ticks = Path()
            ticks.move(to: pt(40, 7)); ticks.addLine(to: pt(40, 13))
            ticks.move(to: pt(73, 40)); ticks.addLine(to: pt(67, 40))
            ticks.move(to: pt(40, 73)); ticks.addLine(to: pt(40, 67))
            ticks.move(to: pt(7, 40)); ticks.addLine(to: pt(13, 40))
            ctx.stroke(ticks, with: .color(EloColor.secondary), style: StrokeStyle(lineWidth: 2.5 * s, lineCap: .round))

            let cal = Calendar.current
            let h = Double(cal.component(.hour, from: now) % 12)
            let m = Double(cal.component(.minute, from: now))
            let hourDeg = h * 30 + m * 0.5
            let minDeg = m * 6
            func hand(_ deg: Double, _ length: CGFloat) -> Path {
                let a = deg * .pi / 180
                var p = Path()
                p.move(to: pt(40, 40))
                p.addLine(to: pt(40 + length * CGFloat(sin(a)), 40 - length * CGFloat(cos(a))))
                return p
            }
            ctx.stroke(hand(hourDeg, 20), with: .color(EloColor.text), style: StrokeStyle(lineWidth: 4 * s, lineCap: .round))
            ctx.stroke(hand(minDeg, 29), with: .color(accent), style: StrokeStyle(lineWidth: 2.5 * s, lineCap: .round))
            ctx.fill(Path(ellipseIn: CGRect(x: 37 * s, y: 37 * s, width: 6 * s, height: 6 * s)), with: .color(accent))
        }
    }
}

enum BandDates {
    /// "qui 19" / "Thu 19" (como no mostrador do design).
    static func short(_ date: Date) -> String {
        let cal = Calendar.current
        let day = cal.component(.day, from: date)
        if isPortuguese {
            let names = ["dom", "seg", "ter", "qua", "qui", "sex", "sáb"]
            return "\(names[cal.component(.weekday, from: date) - 1]) \(day)"
        }
        let f = DateFormatter()
        f.dateFormat = "EEE d"
        return f.string(from: date)
    }
}

// MARK: - Matriz 4x4 (vetor-coluna, igual ao CSS transform)

struct M4 {
    var m: [CGFloat]   // coluna-maior: m[col*4 + linha]

    static let identity = M4(m: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])

    subscript(r: Int, c: Int) -> CGFloat {
        get { m[c * 4 + r] }
        set { m[c * 4 + r] = newValue }
    }

    static func * (a: M4, b: M4) -> M4 {
        var out = M4(m: Array(repeating: 0, count: 16))
        for r in 0..<4 {
            for c in 0..<4 {
                var s: CGFloat = 0
                for k in 0..<4 { s += a[r, k] * b[k, c] }
                out[r, c] = s
            }
        }
        return out
    }

    static func translate(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat = 0) -> M4 {
        var t = M4.identity
        t[0, 3] = x
        t[1, 3] = y
        t[2, 3] = z
        return t
    }

    static func rotateX(_ deg: CGFloat) -> M4 {
        let a = deg * .pi / 180
        var t = M4.identity
        t[1, 1] = cos(a); t[1, 2] = -sin(a)
        t[2, 1] = sin(a); t[2, 2] = cos(a)
        return t
    }

    static func rotateY(_ deg: CGFloat) -> M4 {
        let a = deg * .pi / 180
        var t = M4.identity
        t[0, 0] = cos(a); t[0, 2] = sin(a)
        t[2, 0] = -sin(a); t[2, 2] = cos(a)
        return t
    }

    static func scale2D(_ s: CGFloat) -> M4 {
        var t = M4.identity
        t[0, 0] = s
        t[1, 1] = s
        return t
    }

    static func perspective(_ d: CGFloat) -> M4 {
        var t = M4.identity
        t[3, 2] = -1 / d
        return t
    }

    func apply(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        return (self[0, 0] * x + self[0, 1] * y + self[0, 2] * z + self[0, 3],
                self[1, 0] * x + self[1, 1] * y + self[1, 2] * z + self[1, 3],
                self[2, 0] * x + self[2, 1] * y + self[2, 2] * z + self[2, 3],
                self[3, 0] * x + self[3, 1] * y + self[3, 2] * z + self[3, 3])
    }

    var caTransform: CATransform3D {
        return CATransform3D(m11: self[0, 0], m12: self[1, 0], m13: self[2, 0], m14: self[3, 0],
                             m21: self[0, 1], m22: self[1, 1], m23: self[2, 1], m24: self[3, 1],
                             m31: self[0, 2], m32: self[1, 2], m33: self[2, 2], m34: self[3, 2],
                             m41: self[0, 3], m42: self[1, 3], m43: self[2, 3], m44: self[3, 3])
    }
}

// MARK: - Modelo 3D (mesmas pecas e transformacoes CSS do artifact)

struct BandModel3D: View {
    let size: CGSize          // caixa com perspective: 760px
    var appearance: BandAppearance
    var rotY: CGFloat
    var buzzX: CGFloat = 0
    var modelScale: CGFloat = 1
    var detailed: Bool = false
    var screen: BandScreen = .clock
    var now: Date = Date()
    var elapsed: Double = 1
    var bpm: String = "—"

    private struct Face: Identifiable {
        let id: Int
        let w: CGFloat
        let h: CGFloat
        let ml: CGFloat
        let mt: CGFloat
        let ox: CGFloat
        let oy: CGFloat
        let transform: M4
        let content: AnyView
    }

    private struct PlacedFace: Identifiable {
        let face: Face
        let matrix: M4
        let depth: CGFloat
        var id: Int { face.id }
    }

    var body: some View {
        let faces = buildFaces()
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let parent = M4.scale2D(modelScale) * M4.rotateX(-14) * M4.rotateY(rotY) * M4.translate(buzzX, 0)
        let screenMatrix = M4.translate(center.x, center.y) * M4.perspective(760)

        let placed: [PlacedFace] = faces.map { f in
            let local = M4.translate(f.ml + f.ox * f.w, f.mt + f.oy * f.h)
                * f.transform
                * M4.translate(-f.ox * f.w, -f.oy * f.h)
            let world = parent * local
            let depth = world.apply(f.w / 2, f.h / 2, 0).2
            return PlacedFace(face: f, matrix: screenMatrix * world, depth: depth)
        }

        return ZStack(alignment: .topLeading) {
            ForEach(placed) { item in
                item.face.content
                    .frame(width: item.face.w, height: item.face.h)
                    .projectionEffect(ProjectionTransform(item.matrix.caTransform))
                    .zIndex(Double(item.depth))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    private func buildFaces() -> [Face] {
        let strap = BandAppearance.strapColors(appearance.strap)
        let accent = BandAppearance.accentColor(appearance.accent)
        var list: [Face] = []

        list.append(Face(id: 0, w: 70, h: 112, ml: -35, mt: -186, ox: 0.5, oy: 1, transform: M4.rotateX(34),
                         content: AnyView(UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 4,
                                                                 bottomTrailingRadius: 4, topTrailingRadius: 14)
                            .fill(strap.main))))

        list.append(Face(id: 1, w: 70, h: 124, ml: -35, mt: 74, ox: 0.5, oy: 0, transform: M4.rotateX(-34),
                         content: AnyView(ZStack(alignment: .bottom) {
                            UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 14,
                                                   bottomTrailingRadius: 14, topTrailingRadius: 4)
                                .fill(strap.main)
                            if detailed {
                                VStack(spacing: 7) {
                                    ForEach(0..<4, id: \.self) { _ in
                                        Circle().fill(strap.edge).frame(width: 6, height: 6)
                                    }
                                }
                                .padding(.bottom, 14)
                            }
                         })))

        list.append(Face(id: 2, w: 22, h: 148, ml: -11, mt: -74, ox: 0.5, oy: 0.5,
                         transform: M4.rotateY(90) * M4.translate(0, 0, 46),
                         content: AnyView(ZStack(alignment: .topLeading) {
                            RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0x2A2F37))
                            if detailed {
                                RoundedRectangle(cornerRadius: 3).fill(Color(hex: 0x3A404A))
                                    .frame(width: 6, height: 26)
                                    .offset(x: 8, y: 46)
                            }
                         })))

        list.append(Face(id: 3, w: 22, h: 148, ml: -11, mt: -74, ox: 0.5, oy: 0.5,
                         transform: M4.rotateY(-90) * M4.translate(0, 0, 46),
                         content: AnyView(RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0x22262D)))))

        list.append(Face(id: 4, w: 92, h: 22, ml: -46, mt: -11, ox: 0.5, oy: 0.5,
                         transform: M4.rotateX(90) * M4.translate(0, 0, 74),
                         content: AnyView(RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0x30353E)))))

        list.append(Face(id: 5, w: 92, h: 22, ml: -46, mt: -11, ox: 0.5, oy: 0.5,
                         transform: M4.rotateX(-90) * M4.translate(0, 0, 74),
                         content: AnyView(RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0x1B1F25)))))

        list.append(Face(id: 6, w: 92, h: 148, ml: -46, mt: -74, ox: 0.5, oy: 0.5,
                         transform: M4.rotateY(180) * M4.translate(0, 0, 11),
                         content: AnyView(ZStack {
                            RoundedRectangle(cornerRadius: 20).fill(Color(hex: 0x1F232A))
                            if detailed {
                                ZStack {
                                    Circle().fill(EloColor.bg)
                                    Circle().stroke(Color(hex: 0x2F343C), lineWidth: 2)
                                    HStack(spacing: 6) {
                                        Circle().fill(EloColor.accent).frame(width: 5, height: 5)
                                        Circle().fill(EloColor.accent).frame(width: 5, height: 5)
                                    }
                                }
                                .frame(width: 40, height: 40)
                            }
                         })))

        list.append(Face(id: 7, w: 92, h: 148, ml: -46, mt: -74, ox: 0.5, oy: 0.5,
                         transform: M4.translate(0, 0, 11),
                         content: AnyView(ZStack {
                            RoundedRectangle(cornerRadius: 20).fill(Color(hex: 0x08090C))
                            RoundedRectangle(cornerRadius: 20).strokeBorder(Color(hex: 0x2F343C), lineWidth: 1)
                            BandScreenContent(screen: screen, appearance: appearance, now: now,
                                              elapsed: elapsed, bpm: bpm)
                         })))
        _ = accent
        return list
    }
}

/// Sombra eliptica embaixo do modelo.
struct BandShadow: View {
    var width: CGFloat = 150
    var height: CGFloat = 18

    var body: some View {
        Ellipse()
            .fill(Color.black.opacity(0.5))
            .frame(width: width, height: height)
            .blur(radius: 7)
    }
}

/// Curva ease-in-out do CSS (cubic-bezier(.42, 0, .58, 1)).
func cssEaseInOut(_ t: Double) -> Double {
    let x = max(0, min(1, t))
    var lo = 0.0
    var hi = 1.0
    var u = x
    for _ in 0..<20 {
        u = (lo + hi) / 2
        let bx = 3 * (1 - u) * (1 - u) * u * 0.42 + 3 * (1 - u) * u * u * 0.58 + u * u * u
        if bx < x { lo = u } else { hi = u }
    }
    return 3 * (1 - u) * u * u + u * u * u
}
