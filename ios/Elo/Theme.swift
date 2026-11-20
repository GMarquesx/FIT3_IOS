import SwiftUI

/// Cores e fontes do design (artifact "Elo"): mesmos hex e tamanhos em px = pt.
enum EloColor {
    static let bg = Color(hex: 0x0E1116)
    static let card = Color(hex: 0x171B22)
    static let cardAlt = Color(hex: 0x12161C)
    static let border = Color(hex: 0x232933)
    static let borderStrong = Color(hex: 0x2A313C)
    static let text = Color(hex: 0xE8ECF1)
    static let textSoft = Color(hex: 0xD9DEE5)
    static let secondary = Color(hex: 0x9AA4B2)
    static let tertiary = Color(hex: 0x8B95A3)
    static let accent = Color(hex: 0x3DD6B5)
    static let accentLight = Color(hex: 0x7BE6CF)
    static let okBg = Color(hex: 0x13241F)
    static let okBorder = Color(hex: 0x1F4A3F)
    static let warn = Color(hex: 0xF5A524)
    static let warnBg = Color(hex: 0x2A2113)
    static let warnBorder = Color(hex: 0x5A4520)
    static let danger = Color(hex: 0xFF5A6A)
    static let pink = Color(hex: 0xFF5A7A)
    static let selectedRow = Color(hex: 0x1C232D)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

/// Fontes embutidas (OFL): Inter, Space Grotesk e JetBrains Mono, sem Dynamic Type
/// para ficar igual ao design.
enum EloFont {
    static func inter(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .medium: name = "Inter-Medium"
        case .semibold: name = "Inter-SemiBold"
        case .bold, .heavy, .black: name = "Inter-Bold"
        default: name = "Inter-Regular"
        }
        return Font.custom(name, fixedSize: size)
    }

    static func grotesk(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        let name: String
        switch weight {
        case .medium: name = "SpaceGrotesk-Medium"
        case .semibold: name = "SpaceGrotesk-SemiBold"
        default: name = "SpaceGrotesk-Bold"
        }
        return Font.custom(name, fixedSize: size)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let name = weight == .medium ? "JetBrainsMono-Medium" : "JetBrainsMono-Regular"
        return Font.custom(name, fixedSize: size)
    }
}

/// Texto localizado: a chave e o proprio texto em ingles; pt-BR vem do Localizable.strings.
func L(_ key: String) -> String {
    return NSLocalizedString(key, comment: "")
}

func L(_ key: String, _ args: CVarArg...) -> String {
    return String(format: NSLocalizedString(key, comment: ""), locale: Locale.current, arguments: args)
}

var isPortuguese: Bool {
    return Bundle.main.preferredLocalizations.first?.hasPrefix("pt") == true
}

/// Cartao padrao do design: fundo #171B22, borda 1px #232933.
struct CardStyle: ViewModifier {
    var radius: CGFloat = 18
    var fill: Color = EloColor.card
    var stroke: Color = EloColor.border

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(stroke, lineWidth: 1))
    }
}

extension View {
    func card(radius: CGFloat = 18, fill: Color = EloColor.card, stroke: Color = EloColor.border) -> some View {
        modifier(CardStyle(radius: radius, fill: fill, stroke: stroke))
    }
}

/// Cabecalho de secao em maiusculas (12px, 600, cinza, tracking 0.6).
struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(EloFont.inter(12, .semibold))
            .tracking(0.6)
            .foregroundColor(EloColor.secondary)
    }
}

/// Botao grande do design (altura 50/52, raio 14).
struct EloButtonStyle: ButtonStyle {
    var filled: Bool = true
    var height: CGFloat = 50
    var fontSize: CGFloat = 16

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(EloFont.inter(fontSize, .semibold))
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .foregroundColor(filled ? EloColor.bg : EloColor.text)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(filled ? EloColor.accent : EloColor.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(filled ? Color.clear : EloColor.borderStrong, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// Interruptor no estilo do design (51x31, verde-agua quando ligado).
struct EloToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? EloColor.accent : EloColor.borderStrong)
                Circle().fill(EloColor.text).frame(width: 27, height: 27).padding(2)
            }
            .frame(width: 51, height: 31)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

/// Margens do topo do design (56 ou 48 a partir do topo de uma tela de 844 com barra de 47).
enum EloLayout {
    static func topPadding(_ designTop: CGFloat, safeTop: CGFloat) -> CGFloat {
        return max(designTop, safeTop + (designTop - 47))
    }
}
