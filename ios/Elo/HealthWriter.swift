import Foundation
import HealthKit

/// Grava no app Saude (Apple Health) o que vem da pulseira.
///
/// Cada amostra leva um HKMetadataKeySyncIdentifier: regravar a mesma amostra (ou o total do dia com
/// uma versao maior) substitui a anterior em vez de duplicar. Por isso da para regravar sem medo
/// quando uma tentativa falha (ex.: iPhone bloqueado).
final class HealthWriter: ObservableObject {

    static let shared = HealthWriter()

    let store = HKHealthStore()
    @Published private(set) var lastWrite: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var requested = UserDefaults.standard.bool(forKey: "hk.requested")
    @Published private(set) var savedCount = UserDefaults.standard.integer(forKey: "hk.savedCount")

    var available: Bool { HKHealthStore.isHealthDataAvailable() }

    /// Interruptor geral (tela Apple Health).
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "hk.enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "hk.enabled"); objectWillChange.send() }
    }

    private func on(_ key: String) -> Bool {
        enabled && (UserDefaults.standard.object(forKey: key) as? Bool ?? true)
    }

    static let device = HKDevice(name: "Galaxy Fit3", manufacturer: "Samsung", model: "SM-R390",
                                 hardwareVersion: nil, firmwareVersion: nil, softwareVersion: nil,
                                 localIdentifier: nil, udiDeviceIdentifier: nil)

    private static let ids: [HKQuantityTypeIdentifier] = [
        .stepCount, .distanceWalkingRunning, .activeEnergyBurned, .heartRate, .oxygenSaturation,
    ]

    private var shareTypes: Set<HKSampleType> {
        Set(HealthWriter.ids.compactMap { HKObjectType.quantityType(forIdentifier: $0) })
    }

    // MARK: Permissao

    func requestAccess(_ done: ((Bool) -> Void)? = nil) {
        guard available else { done?(false); return }
        store.requestAuthorization(toShare: shareTypes, read: []) { [weak self] ok, error in
            DispatchQueue.main.async {
                UserDefaults.standard.set(true, forKey: "hk.requested")
                self?.requested = true
                if let error = error { self?.lastError = error.localizedDescription }
                done?(ok)
            }
        }
    }

    func canWrite(_ id: HKQuantityTypeIdentifier) -> Bool {
        guard available, let t = HKObjectType.quantityType(forIdentifier: id) else { return false }
        return store.authorizationStatus(for: t) == .sharingAuthorized
    }

    var allowedCount: Int { HealthWriter.ids.filter { canWrite($0) }.count }

    // MARK: Amostras

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func sample(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit, _ value: Double,
                        start: Date, end: Date, syncId: String, version: Int) -> HKQuantitySample? {
        guard let type = HKObjectType.quantityType(forIdentifier: id), canWrite(id) else { return nil }
        let meta: [String: Any] = [
            HKMetadataKeySyncIdentifier: syncId,
            HKMetadataKeySyncVersion: version,
            HKMetadataKeyWasUserEntered: false,
        ]
        return HKQuantitySample(type: type, quantity: HKQuantity(unit: unit, doubleValue: value),
                                start: start, end: max(start, end), device: HealthWriter.device, metadata: meta)
    }

    /// Totais de hoje (um registro por dia, substituido a cada sincronizacao).
    func writeDayTotals(steps: Int?, distanceMeters: Double?, activeKcal: Double?, until end: Date = Date()) {
        let start = Calendar.current.startOfDay(for: end)
        let day = HealthWriter.dayFmt.string(from: end)
        let version = Int(Date().timeIntervalSince1970)
        var list: [HKQuantitySample] = []
        if on("hk.steps"), let v = steps, v > 0,
           let s = sample(.stepCount, .count(), Double(v), start: start, end: end,
                          syncId: "elo.steps.\(day)", version: version) { list.append(s) }
        if on("hk.steps"), let v = distanceMeters, v > 0,
           let s = sample(.distanceWalkingRunning, .meter(), v, start: start, end: end,
                          syncId: "elo.distance.\(day)", version: version) { list.append(s) }
        if on("hk.energy"), let v = activeKcal, v > 0,
           let s = sample(.activeEnergyBurned, .kilocalorie(), v, start: start, end: end,
                          syncId: "elo.energy.\(day)", version: version) { list.append(s) }
        save(list)
    }

    /// Batimentos da pulseira (pontos do historico ou media de uma medicao ao vivo).
    func writeHeart(_ samples: [(start: Date, end: Date, bpm: Int)], tag: String = "hr") {
        guard on("hk.heart") else { return }
        let unit = HKUnit.count().unitDivided(by: .minute())
        let list = samples.filter { $0.bpm > 0 }.compactMap {
            sample(.heartRate, unit, Double($0.bpm), start: $0.start, end: $0.end,
                   syncId: "elo.\(tag).\(Int($0.start.timeIntervalSince1970))", version: 1)
        }
        save(list)
    }

    func writeSpO2(_ samples: [SpO2Sample]) {
        guard on("hk.spo2") else { return }
        let list = samples.filter { $0.value > 0 && $0.value <= 100 }.compactMap {
            sample(.oxygenSaturation, .percent(), Double($0.value) / 100, start: $0.time, end: $0.time,
                   syncId: "elo.spo2.\(Int($0.time.timeIntervalSince1970))", version: 1)
        }
        save(list)
    }

    private func save(_ list: [HKQuantitySample]) {
        guard !list.isEmpty else { return }
        store.save(list) { [weak self] ok, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if ok {
                    self.lastWrite = Date()
                    self.lastError = nil
                    self.savedCount += list.count
                    UserDefaults.standard.set(self.savedCount, forKey: "hk.savedCount")
                } else {
                    self.lastError = error?.localizedDescription ?? "?"
                }
            }
        }
    }
}
