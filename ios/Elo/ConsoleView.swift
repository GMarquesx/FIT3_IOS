import UIKit
import SwiftUI

/// Tela "Console" (Console.dc.html): frames do canal SAP ao vivo + ferramentas de teste.
struct ConsoleView: View {
    @ObservedObject private var band = Fit3Client.shared
    @State private var filter = "all"
    @State private var sender = L("Love ❤️")
    @State private var message = L("Good morning ❤️")
    @State private var appName = "WhatsApp"
    @State private var exportFile: ExportFile?

    private var shown: [ConsoleFrame] {
        let list = band.frames.reversed()
        switch filter {
        case "TX": return list.filter { $0.dir == "TX" }
        case "RX": return list.filter { $0.dir == "RX" }
        case "err": return list.filter { $0.error }
        default: return Array(list)
        }
    }

    private let filterOptions = ["all", "TX", "RX", "err"]

    private func filterTitle(_ key: String) -> String {
        switch key {
        case "all": return L("All")
        case "err": return L("Errors")
        default: return key
        }
    }

    private let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        EloScreen(top: 56) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("service 0x1A1A · SAP channel")).font(EloFont.mono(12)).foregroundColor(EloColor.accent)
                Text(L("Console")).font(EloFont.grotesk(34)).tracking(-0.5).foregroundColor(EloColor.text)
            }

            HStack(spacing: 8) {
                stat("MTU", band.mtu.map { "\($0)" } ?? "—")
                stat("RSSI", band.rssi.map { "\($0 < 0 ? "−" : "")\(abs($0)) dBm" } ?? "—")
                stat(L("Frames"), EloFormat.number(band.frameCount))
            }

            HStack(spacing: 8) {
                ForEach(filterOptions, id: \.self) { key in
                    let active = key == filter
                    Button { filter = key } label: {
                        Text(filterTitle(key))
                            .font(EloFont.inter(14, .semibold))
                            .foregroundColor(active ? EloColor.bg : EloColor.text)
                            .padding(.horizontal, 16)
                            .frame(minHeight: 44)
                            .background(Capsule().fill(active ? EloColor.accent : EloColor.card))
                            .overlay(Capsule().stroke(active ? EloColor.accent : EloColor.borderStrong, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(active ? .isSelected : [])
                }
            }

            frameList

            HStack(spacing: 12) {
                Button(L("Export .jsonl")) { exportFile = ExportFile(url: band.exportJSONL()) }
                    .buttonStyle(EloButtonStyle(filled: false, height: 52, fontSize: 15))
                Button { band.toggleRecording() } label: {
                    HStack(spacing: 8) {
                        if band.recording {
                            RoundedRectangle(cornerRadius: 2).fill(EloColor.bg).frame(width: 10, height: 10)
                        } else {
                            Circle().fill(EloColor.bg).frame(width: 10, height: 10)
                        }
                        Text(band.recording ? L("Stop (%d)", band.capture.count) : L("Record capture"))
                    }
                }
                .buttonStyle(EloButtonStyle(filled: true, height: 52, fontSize: 15))
            }

            tools
        }
        .sheet(item: $exportFile) { file in
            ShareSheet(items: [file.url])
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(EloFont.inter(11)).foregroundColor(EloColor.secondary)
            Text(value).font(EloFont.mono(17, .medium)).foregroundColor(EloColor.text).lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 14)
    }

    private var frameList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if shown.isEmpty {
                    Text(L("No frames in this filter."))
                        .font(EloFont.inter(13)).foregroundColor(EloColor.tertiary)
                        .padding(.vertical, 24)
                }
                ForEach(shown) { fr in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(stamp.string(from: fr.time)).foregroundColor(EloColor.tertiary)
                            Text(fr.error ? "RX" : fr.dir)
                                .foregroundColor(fr.error ? EloColor.warn : (fr.dir == "TX" ? EloColor.accent : Color(hex: 0x8AB4FF)))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 6)
                                    .fill(fr.error ? Color(hex: 0x3A2A10) : (fr.dir == "TX" ? EloColor.okBg : Color(hex: 0x16213A))))
                            Text("\(fr.length) B").foregroundColor(EloColor.tertiary)
                            Spacer(minLength: 4)
                            Text(fr.label)
                                .font(EloFont.inter(12, .medium))
                                .foregroundColor(fr.error ? EloColor.warn : EloColor.textSoft)
                                .lineLimit(1)
                        }
                        .font(EloFont.mono(11, .medium))
                        Text(fr.hex)
                            .font(EloFont.mono(12))
                            .foregroundColor(Color(hex: 0xC9D1DB))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(Rectangle().fill(Color(hex: 0x1A1F27)).frame(height: 1), alignment: .bottom)
                }
            }
        }
        .frame(height: 352)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(hex: 0x0A0D11)))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(EloColor.border, lineWidth: 1))
    }

    // MARK: Ferramentas (abaixo do design, para testes)

    private var tools: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: L("Tools"))
            HStack(spacing: 12) {
                Button(band.connected ? L("Disconnect") : L("Connect")) {
                    band.connected ? band.disconnect() : band.connect()
                }
                .buttonStyle(EloButtonStyle(filled: !band.connected, height: 48, fontSize: 15))
                Button(L("Vibrate")) { band.vibrate() }
                    .buttonStyle(EloButtonStyle(filled: false, height: 48, fontSize: 15))
                    .disabled(!band.sessionReady)
            }
            Text(band.status).font(EloFont.mono(11)).foregroundColor(EloColor.tertiary)

            VStack(alignment: .leading, spacing: 8) {
                Text(L("Test notification")).font(EloFont.inter(15, .semibold)).foregroundColor(EloColor.text)
                toolField(L("From"), $sender)
                toolField(L("Message"), $message)
                toolField("App", $appName)
                Button(L("Send to the band")) {
                    band.sendNotification(from: sender, text: message, app: appName)
                }
                .buttonStyle(EloButtonStyle(height: 48, fontSize: 15))
                .disabled(!band.sessionReady)
            }
            .padding(14)
            .card(radius: 16)

            VStack(alignment: .leading, spacing: 8) {
                Text(L("Band language")).font(EloFont.inter(15, .semibold)).foregroundColor(EloColor.text)
                Text(L("Sent every time the band connects. Switching takes a few seconds on the band."))
                    .font(EloFont.inter(12)).foregroundColor(EloColor.secondary)
                ForEach(Fit3Client.languages) { lang in
                    let active = band.bandLanguage == lang.id
                    Button {
                        band.setLanguage(lang.id)
                        band.objectWillChange.send()
                    } label: {
                        HStack {
                            Text(lang.name).font(EloFont.inter(15, .medium)).foregroundColor(EloColor.text)
                            Spacer()
                            Text("id \(lang.id)").font(EloFont.mono(11)).foregroundColor(EloColor.tertiary)
                            if active {
                                Circle().fill(EloColor.accent).frame(width: 10, height: 10)
                            }
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!band.sessionReady)
                }
            }
            .padding(14)
            .card(radius: 16)

            FaceLabView()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L("Health sync")).font(EloFont.inter(15, .semibold)).foregroundColor(EloColor.text)
                    Spacer()
                    Text(band.healthHandshake ? L("Linked") : L("Waiting"))
                        .font(EloFont.inter(11, .semibold))
                        .foregroundColor(band.healthHandshake ? EloColor.accent : EloColor.warn)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(band.healthHandshake ? EloColor.accent.opacity(0.12) : EloColor.warnBg))
                }
                Text(L("Elo answers the band's health handshake (channel 0x0A) the way the official plugin does, confirms each data sync and reads steps from it. Unknown parts stay in the capture for decoding."))
                    .font(EloFont.inter(12)).foregroundColor(EloColor.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(L("Answer health handshake")).font(EloFont.inter(14, .medium)).foregroundColor(EloColor.text)
                    Spacer()
                    EloToggle(isOn: Binding(get: { band.healthSyncEnabled }, set: { band.healthSyncEnabled = $0 }))
                }
                Button(L("Request health data")) {
                    if !band.recording { band.toggleRecording() }
                    band.requestHealthData()
                }
                .buttonStyle(EloButtonStyle(height: 48, fontSize: 15))
                .disabled(!band.sessionReady)
                ForEach(Array(band.healthLog.prefix(8).enumerated()), id: \.offset) { item in
                    Text(item.element).font(EloFont.mono(10)).foregroundColor(EloColor.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
            .card(radius: 16)

            VStack(alignment: .leading, spacing: 4) {
                Text(L("Log")).font(EloFont.inter(15, .semibold)).foregroundColor(EloColor.text)
                ForEach(Array(band.lines.suffix(60).enumerated()), id: \.offset) { item in
                    Text(item.element)
                        .font(EloFont.mono(10))
                        .foregroundColor(EloColor.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(hex: 0x0A0D11)))

            Button(L("Forget band (pair again)"), role: .destructive) { band.forgetBand() }
                .font(EloFont.inter(14, .semibold))
                .foregroundColor(EloColor.danger)
        }
        .padding(.top, 8)
    }

    private func toolField(_ label: String, _ value: Binding<String>) -> some View {
        TextField(label, text: value)
            .font(EloFont.inter(15))
            .foregroundColor(EloColor.text)
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 12).fill(EloColor.bg))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(EloColor.borderStrong, lineWidth: 1))
    }
}

struct ExportFile: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
