import SwiftUI

struct ContentView: View {
    @StateObject private var band = Fit3Client()
    @State private var sender = "Amor ❤️"
    @State private var message = "Bom dia ❤️"
    @State private var appName = "WhatsApp"

    private let bg = Color(red: 0.055, green: 0.067, blue: 0.086)
    private let card = Color(red: 0.090, green: 0.106, blue: 0.133)
    private let accent = Color(red: 0.239, green: 0.839, blue: 0.710)

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    metrics
                    actions
                    notificationCard
                    console
                }
                .padding(20)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Elo")
                .font(.system(size: 34, weight: .bold))
            HStack(spacing: 6) {
                Circle()
                    .fill(band.sessionReady ? accent : Color.orange)
                    .frame(width: 8, height: 8)
                Text(band.status)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var metrics: some View {
        HStack(spacing: 12) {
            metric(title: "Bateria", value: band.battery.map { "\($0)%" } ?? "--")
            metric(title: band.hrContact ? "Batimentos" : "Batimentos (sem contato)",
                   value: band.bpm.map { "\($0) bpm" } ?? "--")
        }
    }

    private func metric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundColor(.secondary)
            Text(value).font(.system(size: 26, weight: .bold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(card)
        .cornerRadius(16)
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button(band.connected ? "Desconectar" : "Conectar") {
                if band.connected {
                    band.disconnect()
                } else {
                    band.connect()
                }
            }
            .buttonStyle(FilledButton(color: accent, textColor: .black))

            Button("Vibrar") { band.vibrate() }
                .buttonStyle(FilledButton(color: card))
                .disabled(!band.sessionReady)
        }
    }

    private var notificationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Notificação de teste").font(.headline)
            TextField("De", text: $sender).textFieldStyle(.roundedBorder)
            TextField("Mensagem", text: $message).textFieldStyle(.roundedBorder)
            TextField("App", text: $appName).textFieldStyle(.roundedBorder)
            Button("Enviar para a pulseira") {
                band.sendNotification(from: sender, text: message, app: appName)
            }
            .buttonStyle(FilledButton(color: accent, textColor: .black))
            .disabled(!band.sessionReady)
        }
        .padding(14)
        .background(card)
        .cornerRadius(16)
    }

    private var console: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Console").font(.headline)
            ForEach(Array(band.lines.suffix(80).enumerated()), id: \.offset) { item in
                Text(item.element)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .background(Color.black.opacity(0.4))
        .cornerRadius(16)
    }
}

struct FilledButton: ButtonStyle {
    let color: Color
    var textColor: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(color.opacity(configuration.isPressed ? 0.7 : 1))
            .foregroundColor(textColor)
            .cornerRadius(14)
    }
}
