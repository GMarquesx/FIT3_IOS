import SwiftUI

/// Tela "Apple Health" (Saude.dc.html).
struct HealthView: View {
    @ObservedObject private var band = Fit3Client.shared
    @AppStorage("hk.steps") private var steps = true
    @AppStorage("hk.sleep") private var sleep = true
    @AppStorage("hk.energy") private var energy = true
    @AppStorage("hk.heart") private var heart = true
    @AppStorage("hk.spo2") private var spo2 = true
    @AppStorage("hk.onConnect") private var onConnect = true
    @AppStorage("hk.background") private var background = false

    var body: some View {
        EloScreen(top: 56) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Apple Health").font(EloFont.grotesk(34)).tracking(-0.5).foregroundColor(EloColor.text)
                Text(L("Every sample from the band goes to the Health app, with Galaxy Fit3 as the source."))
                    .font(EloFont.inter(14)).foregroundColor(EloColor.secondary).lineSpacing(3)
            }

            HStack(spacing: 10) {
                EloIcon(paths: Icons.info, size: 20, lineWidth: 2, color: EloColor.warn)
                Text(L("Writing to Health starts once the band's history is decoded."))
                    .font(EloFont.inter(13)).foregroundColor(EloColor.text)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .card(radius: 14, fill: Color(hex: 0x1A1710), stroke: Color(hex: 0x4A3A1C))

            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(text: L("Write to Health"))
                    .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
                row(L("Steps"), L("— today"), "stepCount", $steps)
                row(L("Sleep"), L("deep, REM and light stages"), "sleepAnalysis", $sleep)
                row(L("Active energy"), L("— kcal today"), "activeEnergyBurned", $energy)
                row(L("Heart rate"), L("%d live samples today", band.bpmSamples.count), "heartRate", $heart)
                row(L("Oxygen saturation"), L("nightly readings"), "oxygenSaturation", $spo2, last: true)
            }
            .card()

            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(text: L("When to sync"))
                    .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
                simpleRow(Text(L("Whenever the band connects")), $onConnect)
                simpleRow(Text(L("In the background")) + Text(" " + L("(iOS decides when)"))
                    .font(EloFont.inter(12)).foregroundColor(EloColor.secondary), $background, last: true)
            }
            .card()

            Button(L("Sync now")) { band.sync() }
                .buttonStyle(EloButtonStyle())
        }
    }

    private func row(_ title: String, _ detail: String, _ code: String, _ value: Binding<Bool>,
                     last: Bool = false) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(EloColor.border).frame(height: 1)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(EloFont.inter(15, .medium)).foregroundColor(EloColor.text)
                    (Text(detail + " · ").foregroundColor(EloColor.secondary).font(EloFont.inter(12))
                     + Text(code).font(EloFont.mono(11)).foregroundColor(EloColor.tertiary))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                EloToggle(isOn: value)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, last ? 10 : 8)
        }
    }

    private func simpleRow(_ label: Text, _ value: Binding<Bool>, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(EloColor.border).frame(height: 1)
            HStack(spacing: 12) {
                label.font(EloFont.inter(15, .medium)).foregroundColor(EloColor.text)
                Spacer(minLength: 0)
                EloToggle(isOn: value)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, last ? 10 : 8)
        }
    }
}
