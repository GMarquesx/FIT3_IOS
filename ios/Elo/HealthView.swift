import SwiftUI

/// Tela "Apple Health" (Saude.dc.html).
struct HealthView: View {
    @ObservedObject private var band = Fit3Client.shared
    @ObservedObject private var hk = HealthWriter.shared
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

            statusCard

            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(text: L("Write to Health"))
                    .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
                row(L("Steps and distance"), stepsDetail, "stepCount", $steps)
                row(L("Active energy"), energyDetail, "activeEnergyBurned", $energy)
                row(L("Heart rate"), heartDetail, "heartRate", $heart)
                row(L("Oxygen saturation"), spo2Detail, "oxygenSaturation", $spo2)
                row(L("Sleep"), L("coming soon"), "sleepAnalysis", $sleep, last: true)
                    .opacity(0.5).disabled(true)
            }
            .card()

            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(text: L("When to sync"))
                    .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
                simpleRow(Text(L("Whenever the band connects")), $onConnect)
                VStack(alignment: .leading, spacing: 8) {
                    Rectangle().fill(EloColor.border).frame(height: 1)
                    Text(L("Measure heart rate")).font(EloFont.inter(15, .medium)).foregroundColor(EloColor.text)
                        .padding(.horizontal, 16)
                    Segmented(options: [("0", L("On tap")), ("15", "15 min"), ("30", "30 min"), ("60", "1 h")],
                              selection: Binding(get: { "\(band.hrInterval)" }, set: { band.hrInterval = Int($0) ?? 30 }))
                        .padding(.horizontal, 16)
                    Text(L("Each reading keeps the sensor on for 30 s. Live during workouts."))
                        .font(EloFont.inter(12)).foregroundColor(EloColor.secondary)
                        .padding(.horizontal, 16).padding(.bottom, 8)
                }
                simpleRow(Text(L("In the background")) + Text(" " + L("(iOS decides when)"))
                    .font(EloFont.inter(12)).foregroundColor(EloColor.secondary), $background, last: true)
            }
            .card()

            Button(L("Sync now")) { band.sync() }
                .buttonStyle(EloButtonStyle())
        }
    }

    private var stepsDetail: String {
        guard let v = band.stepsToday else { return L("waiting for the band") }
        return L("%@ today", EloFormat.number(v))
    }

    private var energyDetail: String {
        guard let v = band.activeKcalToday else { return L("waiting for the band") }
        return L("%@ kcal today", EloFormat.number(Int(v.rounded())))
    }

    private var heartDetail: String {
        let n = band.heartHistory.count
        return n > 0 ? L("%d readings in 24 h", n) : L("live readings and band history")
    }

    private var spo2Detail: String {
        guard let v = band.lastSpO2 else { return L("waiting for the band") }
        return L("last %d%%", v)
    }

    /// Cartao do plano B (Atalhos), quando a assinatura nao trouxe o HealthKit.
    private var shortcutsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Save to Health with Shortcuts")).font(EloFont.inter(15, .semibold)).foregroundColor(EloColor.text)
            Text(L("Without HealthKit, Elo hands the numbers to a shortcut that saves them. Create it once:"))
                .font(EloFont.inter(12)).foregroundColor(EloColor.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(shortcutSteps.enumerated()), id: \.offset) { i, step in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(i + 1)").font(EloFont.mono(11)).foregroundColor(EloColor.accent).frame(width: 14)
                    Text(step).font(EloFont.inter(12)).foregroundColor(EloColor.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                Button(L("Open Shortcuts")) {
                    if let url = URL(string: "shortcuts://") { UIApplication.shared.open(url) }
                }
                .buttonStyle(EloButtonStyle(filled: false, height: 42, fontSize: 14))
                Button(L("Send to Health now")) {
                    if let url = URL(string: "shortcuts://run-shortcut?name=Elo%20Health") { UIApplication.shared.open(url) }
                }
                .buttonStyle(EloButtonStyle(height: 42, fontSize: 14))
            }
        }
        .padding(14)
        .card(radius: 14)
    }

    private var shortcutSteps: [String] {
        [
            L("New shortcut named \"Elo Health\"."),
            L("Add Elo's \"New steps for Health\", then \"If\" result is greater than 0 → \"Log Health Sample\" Steps with the result."),
            L("Repeat for distance (Walking + Running Distance, km), active energy (kcal), heart rate (count/min) and blood oxygen (%)."),
            L("Automation: \"When Elo is closed\" and a few times a day → run \"Elo Health\", without asking."),
        ]
    }

    @ViewBuilder private var statusCard: some View {
        if hk.profileHasHealthKit == false {
            shortcutsCard
        } else if !hk.available {
            banner(L("Apple Health isn't available on this device."), warn: true)
        } else if !hk.requested || hk.allowedCount == 0 {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("Allow Elo to write steps, heart rate, oxygen and energy to the Health app."))
                    .font(EloFont.inter(14)).foregroundColor(EloColor.text)
                    .fixedSize(horizontal: false, vertical: true)
                if hk.profileHasHealthKit == false {
                    Text(L("The installed copy of Elo was signed without HealthKit permission, so iOS won't show the request. The signer (iloader/SideStore) removed it."))
                        .font(EloFont.inter(12)).foregroundColor(EloColor.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let err = hk.lastError {
                    Text(L("Error: %@", err))
                        .font(EloFont.mono(11)).foregroundColor(EloColor.warn)
                        .fixedSize(horizontal: false, vertical: true)
                } else if hk.requested {
                    Text(L("If nothing appears, open Health → your profile → Apps → Elo and turn the categories on."))
                        .font(EloFont.inter(12)).foregroundColor(EloColor.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(L("Connect to Apple Health")) { hk.requestAccess() }
                    .buttonStyle(EloButtonStyle(height: 46, fontSize: 15))
            }
            .padding(14)
            .card(radius: 14)
        } else if let err = hk.lastError {
            banner(L("Last write failed: %@", err), warn: true)
        } else {
            banner(L("Writing %d of 5 types · %d samples saved", hk.allowedCount, hk.savedCount)
                   + (hk.lastWrite.map { " · " + EloFormat.relative($0) } ?? ""), warn: false)
        }
    }

    private func banner(_ text: String, warn: Bool) -> some View {
        HStack(spacing: 10) {
            EloIcon(paths: Icons.info, size: 20, lineWidth: 2, color: warn ? EloColor.warn : EloColor.accent)
            Text(text).font(EloFont.inter(13)).foregroundColor(EloColor.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .card(radius: 14, fill: warn ? Color(hex: 0x1A1710) : Color(hex: 0x0F1B18),
              stroke: warn ? Color(hex: 0x4A3A1C) : Color(hex: 0x1E3D35))
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
