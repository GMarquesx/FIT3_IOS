import UIKit
import SwiftUI

/// Tela "Avisos" (Avisos.dc.html): o que foi para a pulseira, respostas rapidas e ligacoes.
struct AlertsView: View {
    @ObservedObject private var band = Fit3Client.shared
    @AppStorage("callBuzz") private var callBuzz = true
    @AppStorage("quickReplies") private var repliesRaw = ""
    @State private var selected: UUID?
    @State private var sent: String?
    @State private var showSetup = false
    @AppStorage("setupSeen") private var setupSeen = false
    @State private var editing = false
    @State private var draft = ""

    private var replies: [String] {
        let list = repliesRaw.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        return list.isEmpty ? [L("Ok!"), L("On my way"), L("Call you later"), L("I'm driving")] : list
    }

    private var current: SentNotification? {
        band.history.first { $0.id == selected } ?? band.history.first
    }

    var body: some View {
        EloScreen(top: 56) {
            HStack(alignment: .bottom) {
                Text(L("Alerts")).font(EloFont.grotesk(34)).tracking(-0.5).foregroundColor(EloColor.text)
                Spacer()
                Text(L("Experimental"))
                    .font(EloFont.inter(12, .semibold))
                    .foregroundColor(EloColor.warn)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(EloColor.warnBg))
                    .overlay(Capsule().stroke(EloColor.warnBorder, lineWidth: 1))
            }

            Button { showSetup = true } label: {
                HStack(alignment: .top, spacing: 10) {
                    EloIcon(paths: Icons.info, size: 20, lineWidth: 2, color: EloColor.warn).padding(.top, 1)
                    (Text(L("On iOS 27, the Shortcuts automation "))
                     + Text(L("“When I get a notification from an app”")).font(EloFont.inter(13, .bold)).foregroundColor(EloColor.text)
                     + Text(L(" forwards each alert (WhatsApp, Messages…) to Elo, which sends it to the band.")))
                        .font(EloFont.inter(13))
                        .foregroundColor(EloColor.textSoft)
                        .lineSpacing(3)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .card(radius: 16, fill: Color(hex: 0x1A1710), stroke: Color(hex: 0x4A3A1C))
            }
            .buttonStyle(.plain)

            onBandSection
            repliesSection

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Vibrate on messages")).font(EloFont.inter(15, .medium)).foregroundColor(EloColor.text)
                        Text(L("A short buzz when an alert arrives")).font(EloFont.inter(12)).foregroundColor(EloColor.secondary)
                    }
                    Spacer(minLength: 0)
                    EloToggle(isOn: Binding(get: { band.vibrateOnArrival }, set: { band.vibrateOnArrival = $0 }))
                }
                if band.vibrateOnArrival {
                    Text(L("Wait between buzzes")).font(EloFont.inter(12, .medium)).foregroundColor(EloColor.secondary)
                    Segmented(options: [("0", L("None")), ("15", "15 s"), ("30", "30 s"), ("60", "1 min"), ("300", "5 min")],
                              selection: Binding(get: { "\(band.vibrationCooldown)" },
                                                 set: { band.vibrationCooldown = Int($0) ?? 30 }))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .card(radius: 16)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Vibrate on calls")).font(EloFont.inter(15, .medium)).foregroundColor(EloColor.text)
                    Text(L("Via the incoming call automation")).font(EloFont.inter(12)).foregroundColor(EloColor.secondary)
                }
                Spacer(minLength: 0)
                EloToggle(isOn: $callBuzz)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .card(radius: 16)
        }
        .sheet(isPresented: $showSetup) { ShortcutSetupSheet() }
        .onAppear {
            if !setupSeen {
                setupSeen = true
                showSetup = true
            }
        }
        .alert(L("Quick replies"), isPresented: $editing) {
            TextField(L("One per line"), text: $draft, axis: .vertical)
            Button(L("Save")) { repliesRaw = draft }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("Separate the replies with a new line."))
        }
    }

    private var onBandSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(text: L("On the band now"))
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
            if band.history.isEmpty {
                Rectangle().fill(EloColor.border).frame(height: 1)
                Text(L("Nothing sent yet. Alerts from Shortcuts and tests show up here."))
                    .font(EloFont.inter(13)).foregroundColor(EloColor.tertiary)
                    .padding(.horizontal, 16).padding(.vertical, 14)
            }
            ForEach(Array(band.history.prefix(6))) { item in
                let active = item.id == current?.id
                Button {
                    selected = item.id
                    sent = nil
                } label: {
                    VStack(spacing: 0) {
                        Rectangle().fill(EloColor.border).frame(height: 1)
                        HStack(spacing: 12) {
                            ZStack {
                                Circle().fill(EloColor.border)
                                Text(String(item.from.prefix(1)))
                                    .font(EloFont.inter(14, .semibold)).foregroundColor(EloColor.accent)
                            }
                            .frame(width: 36, height: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(item.from).font(EloFont.inter(14, .semibold)).foregroundColor(EloColor.text)
                                        .lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text("\(item.app) · \(timeLabel(item.date))")
                                        .font(EloFont.inter(12)).foregroundColor(EloColor.secondary).lineLimit(1)
                                }
                                Text(item.text).font(EloFont.inter(13)).foregroundColor(Color(hex: 0xB4BCC8)).lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(active ? EloColor.selectedRow : EloColor.card)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .card()
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func timeLabel(_ date: Date) -> String {
        Date().timeIntervalSince(date) < 60 ? L("now") : EloFormat.time(date)
    }

    private var canReply: Bool {
        guard let app = current?.app.lowercased() else { return false }
        return app.contains("whatsapp") || app.contains("mensagens") || app.contains("messages")
            || app.contains("telegram")
    }

    private var repliesSection: some View {
        let who = current?.from ?? "—"
        let status: String
        if current == nil {
            status = L("tap a reply · sent via Shortcuts")
        } else if !canReply {
            status = L("%@ doesn't accept replies", current?.app ?? "")
        } else if let s = sent {
            status = L("sending “%@” to %@ via Shortcuts…", s, who)
        } else {
            status = L("tap a reply · sent via Shortcuts")
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle(text: L("Reply to %@", who))
                Spacer()
                Button(L("Edit")) {
                    draft = replies.joined(separator: "\n")
                    editing = true
                }
                .font(EloFont.inter(13, .semibold))
                .foregroundColor(EloColor.accent)
            }
            FlowLayout(spacing: 8) {
                ForEach(replies, id: \.self) { label in
                    let on = sent == label && canReply
                    Button {
                        guard canReply, let item = current else { return }
                        sent = label
                        runReplyShortcut(to: item, text: label)
                    } label: {
                        Text(label)
                            .font(EloFont.inter(14, .medium))
                            .foregroundColor(on ? EloColor.bg : (canReply ? EloColor.text : Color(hex: 0x5C6673)))
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .background(Capsule().fill(on ? EloColor.accent : EloColor.selectedRow))
                            .overlay(Capsule().stroke(on ? EloColor.accent : EloColor.borderStrong, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(status)
                .font(EloFont.mono(11))
                .foregroundColor(sent != nil && canReply ? EloColor.accent : EloColor.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .card()
    }

    /// Roda o atalho "Elo Reply" do usuario com o texto "contato|resposta|app".
    private func runReplyShortcut(to item: SentNotification, text: String) {
        let payload = "\(item.from)|\(text)|\(item.app)"
        var comps = URLComponents(string: "shortcuts://run-shortcut")
        comps?.queryItems = [
            URLQueryItem(name: "name", value: "Elo Reply"),
            URLQueryItem(name: "input", value: "text"),
            URLQueryItem(name: "text", value: payload),
        ]
        if let url = comps?.url {
            UIApplication.shared.open(url)
        }
    }
}

/// Quebra os botoes em linhas (flex-wrap do design).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Passo a passo da automacao do Atalhos, no estilo "ja direciona certinho".
struct ShortcutSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var band = Fit3Client.shared
    @AppStorage("automationLink") private var automationLink = ""
    @State private var testSent = false
    @State private var editingLink = false
    @State private var linkDraft = ""

    private var hasLink: Bool { URL(string: automationLink)?.scheme?.hasPrefix("http") == true }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Text(L("Notifications")).font(EloFont.inter(17, .semibold)).foregroundColor(EloColor.text)
                Spacer()
            }
            .overlay(alignment: .trailing) {
                Button(L("Done")) { dismiss() }
                    .font(EloFont.inter(16, .semibold))
                    .foregroundColor(EloColor.accent)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    VStack(spacing: 6) {
                        Text(L("See your notifications on your band"))
                            .font(EloFont.grotesk(24)).foregroundColor(EloColor.text)
                            .multilineTextAlignment(.center)
                        Text(L("For when your phone is out of reach."))
                            .font(EloFont.inter(14)).foregroundColor(EloColor.secondary)
                    }
                    .padding(.bottom, 6)

                    step(1, L("Add the automation"),
                         hasLink ? L("Shortcuts opens with everything ready. Tap “Add Automation”.")
                                 : L("Build it once in Shortcuts (Elo action “Send to Galaxy Fit3” + Notification trigger), then paste its iCloud link below.")) {
                        Button(hasLink ? L("Add to Shortcuts") : L("Paste iCloud link")) {
                            if hasLink, let url = URL(string: automationLink) {
                                UIApplication.shared.open(url)
                            } else {
                                linkDraft = UIPasteboard.general.string ?? ""
                                editingLink = true
                            }
                        }
                        .buttonStyle(EloButtonStyle(height: 48, fontSize: 15))
                    }

                    step(2, L("Turn it on"),
                         L("iOS adds it turned off. In Shortcuts › Automation, open it, turn it on and choose “Run Immediately”.")) {
                        Button(L("Open Shortcuts")) {
                            if let url = URL(string: "shortcuts://") { UIApplication.shared.open(url) }
                        }
                        .buttonStyle(EloButtonStyle(filled: false, height: 48, fontSize: 15))
                    }

                    step(3, L("Choose your apps"),
                         L("In “When I get a notification from”, tap + next to Messages and add WhatsApp, Telegram or any app you like.")) {
                        HStack(spacing: 10) {
                            EloIcon(paths: Icons.bell, size: 18, lineWidth: 2, color: EloColor.danger)
                            Text(L("Messages"))
                                .font(EloFont.inter(14, .semibold)).foregroundColor(EloColor.text)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Capsule().fill(EloColor.border))
                            ZStack {
                                Circle().fill(EloColor.accent)
                                Text("+").font(EloFont.inter(18, .bold)).foregroundColor(EloColor.bg)
                            }
                            .frame(width: 30, height: 30)
                            Text("WhatsApp, Telegram…").font(EloFont.inter(13)).foregroundColor(EloColor.secondary)
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 12).fill(EloColor.bg))
                    }

                    step(4, L("Show the message"),
                         L("In Settings › Notifications › Show Previews, choose “Always”. In WhatsApp, also turn on Settings › Notifications › Show Preview. Otherwise your band will only say “Message”.")) {
                        EmptyView()
                    }

                    step(5, L("Try it"), L("Your band will vibrate with a test alert.")) {
                        Button(testSent ? L("Sent! Check your band") : L("Send a test to the band")) {
                            band.sendNotification(from: "Elo", text: L("Notifications are working 🎉"), app: "Elo")
                            testSent = true
                        }
                        .buttonStyle(EloButtonStyle(filled: !testSent, height: 48, fontSize: 15))
                        .disabled(!band.sessionReady)
                        if !band.sessionReady {
                            Text(L("Connect the band first (↻ on Today)."))
                                .font(EloFont.inter(12)).foregroundColor(EloColor.warn)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        note(Icons.console, L("Keep Elo running in the background."))
                        note(Icons.bubble, L("Emojis work: the band shows them in color 😄"))
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card(radius: 16)

                    if hasLink {
                        Button(L("Change automation link")) {
                            linkDraft = automationLink
                            editingLink = true
                        }
                        .font(EloFont.inter(13, .semibold))
                        .foregroundColor(EloColor.tertiary)
                        .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            }
        }
        .background(EloColor.bg.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
        .alert(L("Automation link"), isPresented: $editingLink) {
            TextField("https://www.icloud.com/shortcuts/…", text: $linkDraft)
            Button(L("Save")) { automationLink = linkDraft.trimmingCharacters(in: .whitespacesAndNewlines) }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("In Shortcuts, share your shortcut with the Notification trigger and choose Copy iCloud Link."))
        }
    }

    private func step<Extra: View>(_ n: Int, _ title: String, _ text: String,
                                   @ViewBuilder extra: () -> Extra) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(n)")
                .font(EloFont.grotesk(18))
                .foregroundColor(EloColor.bg)
                .frame(width: 36, height: 36)
                .background(Circle().fill(EloColor.accent))
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(EloFont.inter(17, .semibold)).foregroundColor(EloColor.text)
                Text(text).font(EloFont.inter(14)).foregroundColor(EloColor.secondary)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                extra()
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .card(radius: 18)
    }

    private func note(_ icon: [String], _ text: String) -> some View {
        HStack(spacing: 10) {
            EloIcon(paths: icon, size: 18, lineWidth: 2, color: EloColor.accent)
            Text(text).font(EloFont.inter(13)).foregroundColor(EloColor.secondary)
        }
    }
}
