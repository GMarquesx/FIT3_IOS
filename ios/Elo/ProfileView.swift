import UIKit
import SwiftUI

enum ProfileStore {
    /// Idade a partir de "dd/mm/aaaa" (ou "mm/dd/yyyy" em ingles).
    static var age: Int? {
        let text = UserDefaults.standard.string(forKey: "profile.birth") ?? ""
        let f = DateFormatter()
        f.dateFormat = isPortuguese ? "dd/MM/yyyy" : "MM/dd/yyyy"
        guard let date = f.date(from: text) else { return nil }
        return Calendar.current.dateComponents([.year], from: date, to: Date()).year
    }
}

/// Tela "Perfil" (Perfil.dc.html).
struct ProfileView: View {
    let onBack: () -> Void

    @AppStorage("profile.name") private var name = ""
    @AppStorage("profile.birth") private var birth = ""
    @AppStorage("stepGoal") private var stepGoal = 10000
    @AppStorage("profile.height") private var height = ""
    @AppStorage("profile.weight") private var weight = ""
    @AppStorage("profile.sex") private var sex = ""
    @AppStorage("profile.wrist") private var wrist = "esq"
    @State private var goalText = ""
    @State private var saved = true

    var body: some View {
        EloScreen(top: 48) {
            VStack(alignment: .leading, spacing: 4) {
                BackLink(title: L("Today"), action: onBack)
                Text(L("Profile")).font(EloFont.grotesk(34)).tracking(-0.5).foregroundColor(EloColor.text)
                Text(L("The band uses age, height and weight to estimate calories and distance."))
                    .font(EloFont.inter(13)).foregroundColor(EloColor.secondary).lineSpacing(2)
            }

            importCard

            field(L("Name"), L("What should we call you"), $name, .default)

            HStack(spacing: 12) {
                field(L("Birth date"), isPortuguese ? "dd/mm/aaaa" : "mm/dd/yyyy", $birth, .numbersAndPunctuation)
                field(L("Step goal"), "10000", $goalText, .numberPad)
            }
            HStack(spacing: 12) {
                field(L("Height (cm)"), "—", $height, .numberPad)
                field(L("Weight (kg)"), "—", $weight, .decimalPad)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L("Sex (for the calorie estimate)")).font(EloFont.inter(12, .medium)).foregroundColor(EloColor.secondary)
                Segmented(options: [("f", L("Female")), ("m", L("Male")), ("o", L("Other"))], selection: $sex)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Wrist you wear it on")).font(EloFont.inter(12, .medium)).foregroundColor(EloColor.secondary)
                Segmented(options: [("esq", L("Left")), ("dir", L("Right"))], selection: $wrist)
            }

            Button(saved ? L("Saved on the iPhone") : L("Save")) {
                stepGoal = Int(goalText) ?? stepGoal
                saved = true
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
            .buttonStyle(EloButtonStyle())
        }
        .onAppear {
            goalText = "\(stepGoal)"
            DispatchQueue.main.async { saved = true }
        }
        .onChange(of: name) { _, _ in saved = false }
        .onChange(of: birth) { _, _ in saved = false }
        .onChange(of: goalText) { _, _ in saved = false }
        .onChange(of: height) { _, _ in saved = false }
        .onChange(of: weight) { _, _ in saved = false }
        .onChange(of: sex) { _, _ in saved = false }
        .onChange(of: wrist) { _, _ in saved = false }
    }

    private var importCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(hex: 0x2A1A22))
                    EloIcon(paths: Icons.heart, size: 22, lineWidth: 2, color: Color(hex: 0xF27BA8))
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Import from Apple Health")).font(EloFont.inter(15, .semibold)).foregroundColor(EloColor.text)
                    Text(L("Birth date, sex, height and weight · or fill in below"))
                        .font(EloFont.inter(12)).foregroundColor(EloColor.secondary)
                }
            }
            Text(L("Coming soon"))
                .font(EloFont.inter(15, .semibold))
                .foregroundColor(EloColor.secondary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(EloColor.borderStrong, lineWidth: 1))
        }
        .padding(14)
        .card(radius: 16)
    }

    private func field(_ label: String, _ placeholder: String, _ value: Binding<String>,
                       _ keyboard: UIKeyboardType) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(EloFont.inter(12, .medium)).foregroundColor(EloColor.secondary)
            TextField("", text: value, prompt: Text(placeholder).foregroundColor(Color(hex: 0x6F7987)))
                .font(EloFont.inter(15))
                .foregroundColor(EloColor.text)
                .keyboardType(keyboard)
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 12).fill(EloColor.card))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(EloColor.borderStrong, lineWidth: 1))
        }
        .frame(maxWidth: .infinity)
    }
}

/// Controle segmentado do design (fundo #171B22, selecionado em verde-agua).
struct Segmented: View {
    let options: [(String, String)]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let active = option.0 == selection
                Button {
                    selection = option.0
                } label: {
                    Text(option.1)
                        .font(EloFont.inter(14, .semibold))
                        .foregroundColor(active ? EloColor.bg : EloColor.textSoft)
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background(RoundedRectangle(cornerRadius: 9).fill(active ? EloColor.accent : Color.clear))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 12).fill(EloColor.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(EloColor.borderStrong, lineWidth: 1))
    }
}
