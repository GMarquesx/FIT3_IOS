import AppIntents
import Foundation

/// Plano B para o app Saude quando o assinador tira o entitlement do HealthKit:
/// o atalho "Elo → Saude" pega estes valores e grava com a acao "Registrar Amostra de Saude" do Atalhos.
///
/// Passos, energia e distancia devolvem so o que entrou desde a ultima execucao (para nao duplicar);
/// batimento e SpO2 devolvem a leitura nova, ou 0 quando nao ha nada novo.
enum HealthExport {
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static var today: String { dayFmt.string(from: Date()) }

    /// Diferenca entre o total de hoje e o que ja foi exportado hoje; marca como exportado.
    static func delta(_ key: String, total: Double?) -> Double {
        guard let total = total, total > 0 else { return 0 }
        let k = "hkExport.\(key).\(today)"
        let done = UserDefaults.standard.double(forKey: k)
        let d = total - done
        guard d > 0 else { return 0 }
        UserDefaults.standard.set(total, forKey: k)
        return d
    }

    /// Valor novo desde a ultima exportacao (pela data da leitura).
    static func fresh(_ key: String, value: Int?, at date: Date?) -> Int {
        guard let v = value, let t = date else { return 0 }
        let k = "hkExport.\(key).last"
        let last = UserDefaults.standard.double(forKey: k)
        guard t.timeIntervalSince1970 > last + 1 else { return 0 }
        UserDefaults.standard.set(t.timeIntervalSince1970, forKey: k)
        return v
    }
}

struct NewStepsIntent: AppIntent {
    static var title: LocalizedStringResource = "New steps for Health"
    static var description = IntentDescription("Steps counted by the Galaxy Fit3 since the last time this ran. Use with Log Health Sample.")

    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        let total = await MainActor.run { Fit3Client.shared.stepsToday }
        return .result(value: Int(HealthExport.delta("steps", total: total.map(Double.init))))
    }
}

struct NewDistanceIntent: AppIntent {
    static var title: LocalizedStringResource = "New distance for Health"
    static var description = IntentDescription("Walking and running distance in kilometers since the last time this ran.")

    func perform() async throws -> some IntentResult & ReturnsValue<Double> {
        let meters = await MainActor.run { Fit3Client.shared.distanceToday }
        let d = HealthExport.delta("distance", total: meters) / 1000
        return .result(value: (d * 1000).rounded() / 1000)
    }
}

struct NewActiveEnergyIntent: AppIntent {
    static var title: LocalizedStringResource = "New active energy for Health"
    static var description = IntentDescription("Active kilocalories since the last time this ran.")

    func perform() async throws -> some IntentResult & ReturnsValue<Double> {
        let kcal = await MainActor.run { Fit3Client.shared.activeKcalToday }
        return .result(value: HealthExport.delta("energy", total: kcal).rounded())
    }
}

struct NewHeartRateIntent: AppIntent {
    static var title: LocalizedStringResource = "New heart rate for Health"
    static var description = IntentDescription("The latest heart rate from the band, or 0 if there is no new reading.")

    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        let (bpm, at) = await MainActor.run { (Fit3Client.shared.lastBpm, Fit3Client.shared.lastBpmDate) }
        return .result(value: HealthExport.fresh("heart", value: bpm, at: at))
    }
}

struct NewOxygenIntent: AppIntent {
    static var title: LocalizedStringResource = "New blood oxygen for Health"
    static var description = IntentDescription("The latest SpO2 percentage from the band, or 0 if there is no new reading.")

    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        let (v, at) = await MainActor.run { (Fit3Client.shared.lastSpO2, Fit3Client.shared.lastSpO2Date) }
        return .result(value: HealthExport.fresh("spo2", value: v, at: at))
    }
}
