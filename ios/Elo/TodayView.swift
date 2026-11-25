import SwiftUI

/// Tela "Hoje" (Main.dc.html).
struct TodayView: View {
    @ObservedObject private var band = Fit3Client.shared
    @AppStorage("stepGoal") private var stepGoal = 10000
    @State private var appearance = BandAppearance.load()
    @State private var demoStart: Date?
    @State private var idleStart = Date()

    var body: some View {
        EloScreen(top: 56) {
            header
            bandCard
            stepsCard
            metricsGrid
        }
        .onAppear { appearance = BandAppearance.load() }
    }

    // MARK: Cabecalho

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text(EloFormat.header(Date()))
                    .font(EloFont.inter(13, .medium))
                    .foregroundColor(EloColor.secondary)
                Text(L("Today"))
                    .font(EloFont.grotesk(34))
                    .tracking(-0.5)
                    .foregroundColor(EloColor.text)
            }
            Spacer()
            HStack(spacing: 8) {
                Button {
                    band.sync()
                } label: {
                    RoundIconButton(icon: Icons.sync, color: EloColor.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Sync now"))
                .contextMenu {
                    if band.connected {
                        Button(L("Disconnect"), role: .destructive) { band.disconnect() }
                    } else {
                        Button(L("Connect")) { band.connect() }
                    }
                }

                NavigationLink(value: TodayRoute.profile) {
                    RoundIconButton(icon: Icons.profile)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Profile"))
            }
        }
    }

    // MARK: Cartao com o modelo 3D

    private var statusText: String {
        if band.sessionReady {
            let pct = band.battery.map { "\($0)%" } ?? "—"
            let base = "\(pct) · \(EloFormat.relative(band.lastContact))"
            return band.isSleeping ? "🌙 " + L("Sleep mode") + " · " + base : base
        }
        if band.connecting || band.connected { return band.status }
        return L("Disconnected · tap ↻")
    }

    private var statusDot: Color {
        if band.sessionReady { return EloColor.accent }
        if band.connecting || band.connected { return EloColor.warn }
        return Color(hex: 0x5C6673)
    }

    private var bandCard: some View {
        ZStack(alignment: .bottomTrailing) {
            NavigationLink(value: TodayRoute.band) {
                TimelineView(.animation) { context in
                    cardBody(now: context.date)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Galaxy Fit3. Tap to customize."))

            Button {
                if demoStart == nil {
                    demoStart = Date()
                } else {
                    demoStart = nil
                    idleStart = Date()
                }
            } label: {
                HStack(spacing: 6) {
                    EloIcon(paths: Icons.bubble, size: 14, lineWidth: 2, color: EloColor.accent)
                    Text(demoStart == nil ? L("Message demo") : L("Pause demo"))
                        .font(EloFont.inter(12, .semibold))
                        .foregroundColor(EloColor.text)
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(Capsule().fill(EloColor.card))
                .overlay(Capsule().stroke(EloColor.borderStrong, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(10)
        }
        .frame(height: 252)
    }

    private struct Phase {
        let screen: BandScreen
        let elapsed: Double
        let tag: String?
    }

    /// Ciclo do design: relogio 4 s, Ana 5,5 s, relogio 4 s, Amor 5,5 s, relogio 4 s, ligacao da Mae 7 s.
    private func currentPhase(_ now: Date) -> Phase {
        if let live = band.liveAlert {
            let e = now.timeIntervalSince(live.date)
            switch live.screen {
            case .message(let app, _, _) where e < 5.5:
                return Phase(screen: live.screen, elapsed: e, tag: L("New message · %@", app))
            case .call(let name) where e < 7:
                return Phase(screen: live.screen, elapsed: e, tag: L("Call · %@", name))
            default:
                break
            }
        }
        guard let start = demoStart else {
            let since = max(idleStart, band.liveAlert?.date ?? .distantPast)
            return Phase(screen: .clock, elapsed: now.timeIntervalSince(since), tag: nil)
        }
        let durations: [Double] = [4, 5.5, 4, 5.5, 4, 7]
        let total = durations.reduce(0, +)
        var t = (now.timeIntervalSince(start) + 4).truncatingRemainder(dividingBy: total)
        var index = 0
        while t >= durations[index] {
            t -= durations[index]
            index += 1
        }
        switch index {
        case 1:
            return Phase(screen: .message(app: "WhatsApp", from: "Ana", text: L("Almost there!! 🏃💨 Wait for me 😄")),
                         elapsed: t, tag: L("New message · %@", "WhatsApp"))
        case 3:
            return Phase(screen: .message(app: "WhatsApp", from: L("Love ❤️"), text: L("Good morning ❤️")),
                         elapsed: t, tag: L("New message · %@", "WhatsApp"))
        case 5:
            return Phase(screen: .call(name: L("Mom")), elapsed: t, tag: L("Call · %@", L("Mom")))
        default:
            return Phase(screen: .clock, elapsed: t, tag: nil)
        }
    }

    private func motion(for phase: Phase) -> (rot: CGFloat, buzz: CGFloat) {
        func buzz(_ e: Double, _ iterations: Double) -> CGFloat {
            guard e < 0.12 * iterations else { return 0 }
            let u = e.truncatingRemainder(dividingBy: 0.12) / 0.12
            if u < 0.25 { return CGFloat(-12 * u) }
            if u < 0.75 { return CGFloat(-3 + 12 * (u - 0.25)) }
            return CGFloat(3 - 12 * (u - 0.75))
        }
        switch phase.screen {
        case .clock:
            let p = phase.elapsed.truncatingRemainder(dividingBy: 10)
            let x = p < 5 ? p / 5 : (10 - p) / 5
            return (CGFloat(-40 + 34 * cssEaseInOut(x)), 0)
        case .message:
            return (-14, buzz(phase.elapsed, 8))
        case .call:
            return (-14, buzz(phase.elapsed, 24))
        }
    }

    private func cardBody(now: Date) -> some View {
        let phase = currentPhase(now)
        let m = motion(for: phase)
        let bpmText = band.lastBpm.map { "\($0)" } ?? "—"

        return GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(EloColor.cardAlt)

                BandShadow(width: 150, height: 18)
                    .position(x: geo.size.width / 2, y: geo.size.height - 22 - 9)

                BandModel3D(size: geo.size, appearance: appearance, rotY: m.rot, buzzX: m.buzz,
                            modelScale: 0.94, detailed: false, screen: phase.screen, now: now,
                            elapsed: phase.elapsed, bpm: bpmText)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Galaxy Fit3").font(EloFont.inter(16, .semibold)).foregroundColor(EloColor.text)
                    HStack(spacing: 6) {
                        Circle().fill(statusDot).frame(width: 7, height: 7)
                        Text(statusText).font(EloFont.inter(12)).foregroundColor(EloColor.secondary).lineLimit(1)
                    }
                }
                .padding(.leading, 14)
                .padding(.top, 12)

                if let tag = phase.tag {
                    let appear = min(1, phase.elapsed / 0.25)
                    Text(tag)
                        .font(EloFont.inter(11, .semibold))
                        .foregroundColor(EloColor.accent)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 8).fill(EloColor.okBg))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(EloColor.okBorder, lineWidth: 1))
                        .opacity(appear)
                        .offset(y: 8 * (1 - appear))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 12)
                        .padding(.top, 12)
                }

                HStack(spacing: 2) {
                    Text(L("Tap to customize")).font(EloFont.inter(12)).foregroundColor(EloColor.secondary)
                    EloIcon(paths: Icons.chevronRight, size: 14, lineWidth: 2.2, color: EloColor.secondary)
                }
                .padding(.leading, 14)
                .padding(.bottom, 14)
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(EloColor.border, lineWidth: 1))
        }
    }

    // MARK: Passos

    private var goal: Int { band.stepGoal ?? stepGoal }

    private var stepsDetail: String {
        guard band.stepsToday != nil else { return L("Not synced from the band yet") }
        var parts: [String] = []
        if let d = band.distanceToday, d > 0 {
            parts.append(d >= 1000 ? String(format: "%.1f km", d / 1000) : String(format: "%.0f m", d))
        }
        parts.append(L("synced %@", EloFormat.relative(band.lastHealthSync)))
        return parts.joined(separator: " · ")
    }

    private var stepsCard: some View {
        let steps = band.stepsToday
        let progress = min(1, Double(steps ?? 0) / Double(max(goal, 1)))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(steps.map { EloFormat.number($0) } ?? "—").font(EloFont.grotesk(24)).foregroundColor(EloColor.text)
                    Text(L("steps")).font(EloFont.inter(13)).foregroundColor(EloColor.secondary)
                }
                Spacer()
                Text(L("goal %@", EloFormat.number(goal)))
                    .font(EloFont.inter(12)).foregroundColor(EloColor.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(EloColor.border)
                    Capsule().fill(EloColor.accent).frame(width: geo.size.width * progress)
                }
            }
            .frame(height: 8)
            Text(stepsDetail)
                .font(EloFont.inter(12)).foregroundColor(EloColor.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .card()
    }

    // MARK: Grade de metricas

    private var metricsGrid: some View {
        let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        return LazyVGrid(columns: columns, spacing: 12) {
            MetricCard(icon: Icons.moon, tint: Color(hex: 0xA78BFA), tintBg: Color(hex: 0x231C3A),
                       title: L("Sleep"), value: "—", unit: nil, detail: L("Waiting for sync"))
            MetricCard(icon: Icons.flame, tint: Color(hex: 0xFF8A3D), tintBg: Color(hex: 0x33200F),
                       title: L("Calories"), value: band.caloriesToday.map { EloFormat.number(Int($0.rounded())) } ?? "—",
                       unit: band.caloriesToday == nil ? nil : L("kcal"),
                       detail: band.caloriesToday == nil ? L("Waiting for sync") : L("from steps today"))
            heartCard
            MetricCard(icon: Icons.oxygen, tint: Color(hex: 0x5AB8FF), tintBg: Color(hex: 0x132A3D),
                       title: L("Oxygen"), value: "—", unit: L("% SpO₂"), detail: L("Waiting for sync"))
        }
    }

    private var heartDetail: String {
        if band.measuringHR { return L("Measuring… keep the band on") }
        if band.lastBpmDate != nil { return L("Tap to measure · %@", EloFormat.relative(band.lastBpmDate)) }
        return L("Tap to measure")
    }

    private var heartCard: some View {
        let value = band.lastBpm.map { "\($0)" } ?? "—"
        return Button {
            band.measureHeartRate(seconds: 30)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                MetricHeader(icon: Icons.heart, tint: EloColor.pink, tintBg: Color(hex: 0x361720), title: L("Heart rate"))
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value).font(EloFont.grotesk(26)).foregroundColor(EloColor.text)
                    Text(L("bpm")).font(EloFont.inter(13)).foregroundColor(EloColor.secondary)
                    if band.measuringHR {
                        Circle().fill(EloColor.pink).frame(width: 7, height: 7)
                    }
                }
                Sparkline(values: band.bpmSamples).frame(width: 140, height: 22)
                Text(heartDetail)
                    .font(EloFont.inter(12)).foregroundColor(EloColor.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .card()
        }
        .buttonStyle(.plain)
        .disabled(!band.sessionReady)
    }
}

struct MetricHeader: View {
    let icon: [String]
    let tint: Color
    let tintBg: Color
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tintBg)
                EloIcon(paths: icon, size: 17, lineWidth: 2, color: tint, fillOpacity: 0.25)
            }
            .frame(width: 28, height: 28)
            Text(title).font(EloFont.inter(13, .medium)).foregroundColor(EloColor.secondary)
        }
    }
}

struct MetricCard: View {
    let icon: [String]
    let tint: Color
    let tintBg: Color
    let title: String
    let value: String
    let unit: String?
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MetricHeader(icon: icon, tint: tint, tintBg: tintBg, title: title)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(EloFont.grotesk(26)).foregroundColor(EloColor.text)
                if let unit = unit {
                    Text(unit).font(EloFont.inter(13)).foregroundColor(EloColor.secondary)
                }
            }
            Text(detail).font(EloFont.inter(12)).foregroundColor(EloColor.secondary)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }
}

/// Linha de frequencia cardiaca (ultimas amostras ao vivo).
struct Sparkline: View {
    let values: [Int]

    var body: some View {
        Canvas { ctx, size in
            let points = Array(values.suffix(24))
            guard points.count >= 2, let lo = points.min(), let hi = points.max() else { return }
            let span = max(1, Double(hi - lo))
            var path = Path()
            for (i, v) in points.enumerated() {
                let x = size.width * CGFloat(i) / CGFloat(points.count - 1)
                let y = size.height - 3 - (size.height - 6) * CGFloat(Double(v - lo) / span)
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            ctx.stroke(path, with: .color(EloColor.pink), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }
}
