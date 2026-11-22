import AppIntents
import Foundation

struct BandUnavailableError: Error, CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource {
        "Couldn't reach the Galaxy Fit3. Check that it is nearby and Bluetooth is on."
    }
}

/// "Enviar para a Galaxy Fit3": usado na automacao "Ao receber notificacao" do Atalhos (iOS 27).
struct SendToBandIntent: AppIntent {
    static var title: LocalizedStringResource = "Send to Galaxy Fit3"
    static var description = IntentDescription("Shows a notification on the Galaxy Fit3 band.")

    @Parameter(title: "From")
    var sender: String

    @Parameter(title: "Message")
    var message: String

    @Parameter(title: "App", default: "Elo")
    var app: String

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$message) from \(\.$sender) to the band") {
            \.$app
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let client = Fit3Client.shared
        guard await client.ensureReady(timeout: 25) else { throw BandUnavailableError() }
        let from = sender
        let text = message
        let appName = app.isEmpty ? "Elo" : app
        await MainActor.run {
            client.sendNotification(from: from, text: text, app: appName)
        }
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        return .result(dialog: "Sent to the band")
    }
}

/// "Vibrar a pulseira" (achar pulseira por 3 s).
struct VibrateBandIntent: AppIntent {
    static var title: LocalizedStringResource = "Find my Galaxy Fit3"
    static var description = IntentDescription("Makes the band vibrate for a few seconds.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let client = Fit3Client.shared
        guard await client.ensureReady(timeout: 25) else { throw BandUnavailableError() }
        await MainActor.run { client.vibrate() }
        try? await Task.sleep(nanoseconds: 3_600_000_000)
        return .result(dialog: "The band is vibrating")
    }
}

/// "Ligacao na pulseira": aviso de chamada (vibra junto se "Vibrar em ligacoes" estiver ligado).
struct CallAlertIntent: AppIntent {
    static var title: LocalizedStringResource = "Show call on Galaxy Fit3"
    static var description = IntentDescription("Shows an incoming call alert on the band.")

    @Parameter(title: "Caller")
    var caller: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let client = Fit3Client.shared
        guard await client.ensureReady(timeout: 25) else { throw BandUnavailableError() }
        let name = caller
        let buzz = UserDefaults.standard.object(forKey: "callBuzz") as? Bool ?? true
        await MainActor.run { client.sendCall(from: name, buzz: buzz) }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        return .result(dialog: "Call shown on the band")
    }
}

/// "Bateria da pulseira": devolve o % para usar em outros atalhos.
struct BandBatteryIntent: AppIntent {
    static var title: LocalizedStringResource = "Galaxy Fit3 battery"
    static var description = IntentDescription("Returns the band's battery level.")

    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let client = Fit3Client.shared
        guard await client.ensureReady(timeout: 25) else { throw BandUnavailableError() }
        var level = await MainActor.run { client.battery }
        if level == nil {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            level = await MainActor.run { client.battery }
        }
        let value = level ?? 0
        return .result(value: value, dialog: "Battery: \(value) percent")
    }
}

/// "Modo sono do Elo": liga/desliga (para usar com o Foco Sono do iPhone).
struct SleepModeIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Elo sleep mode"
    static var description = IntentDescription("Stops the band from vibrating while you sleep.")

    @Parameter(title: "Sleep mode", default: true)
    var on: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Turn Elo sleep mode \(\.$on)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let value = on
        await MainActor.run { Fit3Client.shared.sleepManual = value }
        return .result(dialog: value ? "Sleep mode on" : "Sleep mode off")
    }
}

/// Alterna o modo sono (para a Siri e a Central de Controle).
struct ToggleSleepModeIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Elo sleep mode"

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let now = await MainActor.run { () -> Bool in
            Fit3Client.shared.sleepManual.toggle()
            return Fit3Client.shared.sleepManual
        }
        return .result(dialog: now ? "Sleep mode on" : "Sleep mode off")
    }
}

struct EloShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: VibrateBandIntent(),
                    phrases: ["Find my band with \(.applicationName)",
                              "Vibrate my band with \(.applicationName)"],
                    shortTitle: "Find band",
                    systemImageName: "dot.radiowaves.left.and.right")
        AppShortcut(intent: BandBatteryIntent(),
                    phrases: ["Band battery in \(.applicationName)"],
                    shortTitle: "Band battery",
                    systemImageName: "battery.75percent")
        AppShortcut(intent: ToggleSleepModeIntent(),
                    phrases: ["Toggle sleep mode in \(.applicationName)"],
                    shortTitle: "Sleep mode",
                    systemImageName: "moon.zzz")
        AppShortcut(intent: SendToBandIntent(),
                    phrases: ["Send to my band with \(.applicationName)"],
                    shortTitle: "Send to band",
                    systemImageName: "bell.badge")
    }
}
