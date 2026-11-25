import CoreBluetooth
import Foundation
import UIKit

/// Um frame que passou pelo canal SAP (para a tela Console).
struct ConsoleFrame: Identifiable, Codable {
    let id: Int
    let time: Date
    let dir: String        // "TX" ou "RX"
    let length: Int
    let label: String
    let hex: String
    let error: Bool
    var full: String? = nil
}

/// Notificacao ja enviada a pulseira (lista "Na pulseira agora").
struct SentNotification: Identifiable, Codable, Equatable {
    var id = UUID()
    let from: String
    let app: String
    let text: String
    let date: Date
    var held: Bool? = nil
}

/// Idioma da pulseira (id do canal 0B).
struct BandLanguage: Identifiable {
    let id: UInt8
    let name: String
}

/// Widget (tile) da pulseira (lista do canal 0x0F, servico WidgetsService): id e posicao (0xFF = fora).
struct BandWidget: Identifiable, Equatable {
    let id: UInt8
    let slot: UInt8
}

/// Evento para o modelo 3D mostrar (mensagem ou ligacao real).
struct LiveAlert: Equatable {
    let screen: BandScreen
    let date: Date
}

/// Cliente BLE da Galaxy Fit3. Unico para o app inteiro e para os Atalhos.
final class Fit3Client: NSObject, ObservableObject {

    static let shared = Fit3Client()

    @Published var status: String = L("Disconnected")
    @Published var connected = false
    @Published var connecting = false
    @Published var sessionReady = false
    @Published var battery: Int?
    @Published var bpm: Int?
    @Published var hrContact = false
    @Published var bpmSamples: [Int] = []
    @Published var restingBpm: Int?
    @Published var lastContact: Date?
    @Published var lines: [String] = []
    @Published var frames: [ConsoleFrame] = []
    @Published var frameCount = 0
    @Published var mtu: Int?
    @Published var rssi: Int?
    @Published var recording = false
    @Published var capture: [ConsoleFrame] = []
    @Published var history: [SentNotification] = []
    @Published var liveAlert: LiveAlert?
    @Published var measuringHR = false
    @Published var lastBpm: Int?
    @Published var lastBpmDate: Date?
    @Published var widgets: [BandWidget] = []
    @Published var bandFaces: [BandFace] = []
    @Published var currentFaceId: Int?
    @Published var maxFaces: Int?
    @Published var stepsToday: Int?
    @Published var stepGoal: Int?
    @Published var caloriesToday: Double?
    @Published var distanceToday: Double?
    @Published var lastHealthSync: Date?
    @Published var lastSpO2: Int?
    @Published var activeKcalToday: Double?
    @Published var lastSpO2Date: Date?
    @Published var heartHistory: [HeartSample] = []
    @Published var healthHandshake = false
    @Published var healthLog: [String] = []

    static let sapService = CBUUID(string: "1A1A")
    static let sapNotifyUUID = CBUUID(string: "797AE4E9-2E58-4FE8-B48D-B5C79599FB9B")
    static let sapWriteUUID = CBUUID(string: "63E30BAD-4206-4596-839F-E47CBF7A4B5D")
    static let hrService = CBUUID(string: "180D")
    static let hrMeasUUID = CBUUID(string: "2A37")

    /// Idiomas que a pulseira aceita no canal 0B (ver PROTOCOLO.md).
    static let languages: [BandLanguage] = [
        BandLanguage(id: 13, name: "English"),
        BandLanguage(id: 14, name: "Español"),
        BandLanguage(id: 55, name: "Português (Portugal)"),
    ]

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var sapNotify: CBCharacteristic?
    private var sapWrite: CBCharacteristic?
    private var hrMeas: CBCharacteristic?
    private var queue: [(String, Data)] = []
    private var writing = false
    private var wantConnection = false
    private var userDisconnected = false
    private var nextFrameId = 0
    private var notificationCounter = Int(Date().timeIntervalSince1970) % 100000
    private var rssiTimer: Timer?
    private var rxBuffer: [UInt8] = []
    private var liveHR: [Int] = []
    private var liveHRStart: Date?
    private var rxBufferDate = Date.distantPast
    private var largeData = LargeDataAssembler()
    private var healthSeq = 0
    private var lastBuzz: Date = .distantPast
    private var lastHRMeasure: Date = .distantPast
    private var hrStopWork: DispatchWorkItem?
    private var hrHolds = 0
    private var inForeground = true

    // MARK: Modo sono (sem vibracao; opcionalmente segura os avisos)

    var sleepManual: Bool {
        get { UserDefaults.standard.bool(forKey: "sleepManual") }
        set { UserDefaults.standard.set(newValue, forKey: "sleepManual"); objectWillChange.send() }
    }
    var sleepScheduled: Bool {
        get { UserDefaults.standard.bool(forKey: "sleepScheduled") }
        set { UserDefaults.standard.set(newValue, forKey: "sleepScheduled"); objectWillChange.send() }
    }
    /// Minutos desde a meia-noite.
    var sleepStart: Int {
        get { UserDefaults.standard.object(forKey: "sleepStart") as? Int ?? 23 * 60 }
        set { UserDefaults.standard.set(newValue, forKey: "sleepStart"); objectWillChange.send() }
    }
    var sleepEnd: Int {
        get { UserDefaults.standard.object(forKey: "sleepEnd") as? Int ?? 7 * 60 }
        set { UserDefaults.standard.set(newValue, forKey: "sleepEnd"); objectWillChange.send() }
    }
    var sleepHoldAlerts: Bool {
        get { UserDefaults.standard.bool(forKey: "sleepHoldAlerts") }
        set { UserDefaults.standard.set(newValue, forKey: "sleepHoldAlerts"); objectWillChange.send() }
    }

    var isSleeping: Bool {
        if sleepManual { return true }
        guard sleepScheduled else { return false }
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let now = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        if sleepStart == sleepEnd { return false }
        if sleepStart < sleepEnd { return now >= sleepStart && now < sleepEnd }
        return now >= sleepStart || now < sleepEnd
    }

    /// Intervalo da medicao automatica de batimentos, em minutos (0 = so quando pedir).
    var hrInterval: Int {
        get { UserDefaults.standard.object(forKey: "hrInterval") as? Int ?? 30 }
        set { UserDefaults.standard.set(newValue, forKey: "hrInterval"); objectWillChange.send() }
    }

    /// Vibra rapidinho quando chega uma notificacao (a pulseira nao vibra sozinha com o 07/80).
    var vibrateOnArrival: Bool {
        get { UserDefaults.standard.object(forKey: "vibrateOnArrival") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "vibrateOnArrival"); objectWillChange.send() }
    }

    /// Intervalo minimo entre vibracoes, em segundos (grupos nao vibram a cada mensagem).
    var vibrationCooldown: Int {
        get { UserDefaults.standard.object(forKey: "vibrationCooldown") as? Int ?? 30 }
        set { UserDefaults.standard.set(newValue, forKey: "vibrationCooldown"); objectWillChange.send() }
    }

    /// Responde o handshake de saude (0A/A2) como o plugin oficial e confirma os SYNC_DATA.
    var healthSyncEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "healthSyncEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "healthSyncEnabled"); objectWillChange.send() }
    }

    private let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var bandLanguage: UInt8 {
        get {
            let v = UserDefaults.standard.integer(forKey: "bandLanguage")
            return v == 0 ? 13 : UInt8(v)
        }
        set {
            UserDefaults.standard.set(Int(newValue), forKey: "bandLanguage")
        }
    }

    private var savedPeripheralId: UUID? {
        get { UserDefaults.standard.string(forKey: "bandPeripheral").flatMap(UUID.init(uuidString:)) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: "bandPeripheral") }
    }

    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: "sentHistory"),
           let list = try? JSONDecoder().decode([SentNotification].self, from: data) {
            history = list
        }
        loadTodayActivity()
        MusicBridge.shared.send = { [weak self] label, msg in
            self?.send(label, FrameCodec.cmd(0x09, msg))
        }
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: "elo.central"])
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.inForeground = false
            self?.rssiTimer?.invalidate()
            self?.rssiTimer = nil
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.inForeground = true
            if self?.sessionReady == true { self?.startRSSI() }
        }
    }

    // MARK: - Batimentos sob demanda (economiza bateria da pulseira e do iPhone)

    /// Liga o 2A37 por alguns segundos e desliga sozinho.
    func measureHeartRate(seconds: Double = 30) {
        guard sessionReady, let hr = hrMeas, let p = peripheral else { return }
        lastHRMeasure = Date()
        measuringHR = true
        p.setNotifyValue(true, for: hr)
        hrStopWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.stopHeartRate() }
        hrStopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        log("heart rate: measuring for \(Int(seconds)) s")
    }

    /// Mantem o batimento ao vivo enquanto alguem precisar (ex.: corrida).
    func holdHeartRate(_ on: Bool) {
        hrHolds = max(0, hrHolds + (on ? 1 : -1))
        if hrHolds > 0 {
            hrStopWork?.cancel()
            guard sessionReady, let hr = hrMeas, let p = peripheral else { return }
            measuringHR = true
            p.setNotifyValue(true, for: hr)
        } else {
            stopHeartRate()
        }
    }

    /// Media da medicao ao vivo (ou de cada minuto, numa corrida) vai para o app Saude.
    private func flushLiveHeart() {
        defer { liveHR = []; liveHRStart = nil }
        guard let start = liveHRStart, liveHR.count >= 3 else { return }
        let avg = Int((Double(liveHR.reduce(0, +)) / Double(liveHR.count)).rounded())
        HealthWriter.shared.writeHeart([(start: start, end: Date(), bpm: avg)], tag: "hrlive")
    }

    private func stopHeartRate() {
        flushLiveHeart()
        guard hrHolds == 0 else { return }
        if let hr = hrMeas, let p = peripheral, p.state == .connected {
            p.setNotifyValue(false, for: hr)
        }
        measuringHR = false
        hrContact = false
    }

    private func maybePeriodicHeartRate() {
        guard hrInterval > 0, !measuringHR, sessionReady else { return }
        if Date().timeIntervalSince(lastHRMeasure) >= Double(hrInterval * 60) {
            measureHeartRate(seconds: 30)
        }
    }

    // MARK: - Acoes

    /// Conecta direto pelo identificador salvo; se nao tiver, procura por "Fit3" no nome.
    func connect() {
        wantConnection = true
        userDisconnected = false
        guard central.state == .poweredOn else {
            log("waiting for Bluetooth")
            return
        }
        if peripheral != nil && (connected || connecting) { return }
        connecting = true

        if let id = savedPeripheralId,
           let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            attach(known)
            status = L("Connecting…")
            log("reconnecting to saved band")
            central.connect(known, options: nil)
            return
        }
        if let already = central.retrieveConnectedPeripherals(withServices: [Fit3Client.sapService]).first {
            attach(already)
            status = L("Connecting…")
            central.connect(already, options: nil)
            return
        }
        status = L("Looking for the band…")
        log("scanning for devices with 'Fit3' in the name")
        central.scanForPeripherals(withServices: nil, options: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self = self, self.peripheral == nil else { return }
            self.central.stopScan()
            self.connecting = false
            self.status = L("Band not found")
            self.log("scan ended without finding the band")
        }
    }

    func disconnect() {
        wantConnection = false
        userDisconnected = true
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
    }

    /// Esquece a pulseira salva (para parear de novo do zero).
    func forgetBand() {
        disconnect()
        savedPeripheralId = nil
    }

    /// Para os Atalhos: garante sessao aberta antes de mandar algo.
    func ensureReady(timeout: TimeInterval) async -> Bool {
        await MainActor.run {
            if !self.sessionReady { self.connect() }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let ready = await MainActor.run { self.sessionReady }
            if ready { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    func sync() {
        guard sessionReady else {
            connect()
            return
        }
        send(L("Sync time"), Fit3Protocol.timeSync())
        send(L("Request: battery"), FrameCodec.cmd(0x0B, [0x02]))
        if healthHandshake { requestHealthData() }
    }

    func vibrate() {
        send(L("Find band: vibrate"), Fit3Protocol.findOn)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.send(L("Find band: stop"), Fit3Protocol.findOff)
        }
    }

    func sendNotification(from sender: String, text: String, app: String) {
        notificationCounter += 1
        let frame = Fit3Protocol.notification(from: sender, text: text, app: app, id: notificationCounter)
        let label = L("Notification from %@", sender)
        let sleeping = isSleeping
        if sleeping && sleepHoldAlerts {
            // Modo sono segurando avisos: nao vai para a pulseira, so fica na lista.
            log("sleep mode: held alert from \(sender)")
            remember(SentNotification(from: sender, app: app, text: text, date: Date(), held: true))
            return
        }
        if vibrateOnArrival && !sleeping && Date().timeIntervalSince(lastBuzz) >= Double(vibrationCooldown) {
            // Vibra antes (achar pulseira por ~0,7 s) e manda a notificacao por cima.
            lastBuzz = Date()
            send(L("Buzz"), Fit3Protocol.findOn)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                self?.send(L("Buzz: stop"), Fit3Protocol.findOff)
                self?.send(label, frame)
            }
        } else {
            send(label, frame)
        }
        remember(SentNotification(from: sender, app: app, text: text, date: Date()))
        liveAlert = LiveAlert(screen: .message(app: app, from: sender, text: text), date: Date())
    }

    private func remember(_ item: SentNotification) {
        history.insert(item, at: 0)
        if history.count > 30 { history.removeLast(history.count - 30) }
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: "sentHistory")
        }
    }

    func sendCall(from caller: String, buzz: Bool) {
        notificationCounter += 1
        let frame = Fit3Protocol.notification(from: caller, text: L("Calling…"), app: L("Phone"),
                                              id: notificationCounter)
        if isSleeping && sleepHoldAlerts { return }
        send(L("Call from %@", caller), frame)
        if buzz && !isSleeping { vibrate() }
        liveAlert = LiveAlert(screen: .call(name: caller), date: Date())
    }

    func setLanguage(_ id: UInt8) {
        bandLanguage = id
        send(L("Band language (id %d)", Int(id)), Fit3Protocol.language(id))
    }

    // MARK: - Saude (canal 0x0A): handshake, dados grandes e SYNC_DATA

    /// Trata uma mensagem do canal de saude e devolve o rotulo para o console.
    private func handleHealth(_ msg: [UInt8]) -> String {
        guard let first = msg.first else { return "0A" }
        let h = HealthProto.Header(first)
        switch h.msgId {
        case HealthProto.MsgId.largeChunk:
            switch largeData.feed(msg) {
            case .waiting:
                return L("Health data (part)")
            case .complete(let full, let ack):
                sendHealth("Large data ACK", ack)
                let inner = processHealthMessage(full)
                return L("Health data complete · %@", inner)
            case .failed(let nack):
                sendHealth("Large data NACK", nack)
                healthNote("large data out of order, sent NACK")
                return L("Health data (out of order)")
            }
        case HealthProto.MsgId.largeAck:
            return (msg.count > 1 && msg[1] & 0x03 == 1) ? "Large data ACK" : "Large data NACK"
        default:
            return processHealthMessage(msg)
        }
    }

    private func processHealthMessage(_ msg: [UInt8]) -> String {
        guard let first = msg.first else { return "0A" }
        let h = HealthProto.Header(first)
        switch (h.isResponse, h.msgId) {
        case (false, HealthProto.MsgId.gmCapabilityRequest):
            guard healthSyncEnabled else { return L("Health handshake (ignored)") }
            let r = HealthProto.gmCapabilityResponse(to: msg)
            if let seq = r.seq { healthSeq = seq }
            sendHealth(L("Health handshake reply"), r.reply)
            if !healthHandshake {
                healthHandshake = true
                healthNote("handshake: seq \(r.seq ?? -1), protocol \(r.version ?? -1)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.sendHealth(L("Health capability request"), HealthProto.healthCapabilityRequest)
                }
            }
            return L("Health handshake")
        case (_, HealthProto.MsgId.syncData), (true, HealthProto.MsgId.requestData):
            let isRequestData = h.msgId == HealthProto.MsgId.requestData
            let result = HealthSyncParser.parse(msg, isRequestData: isRequestData)
            if let seq = result.seq {
                healthSeq = max(healthSeq, seq)
                if !isRequestData && healthSyncEnabled {
                    sendHealth(L("Sync ACK"), HealthProto.syncAck(seq: seq, ok: true))
                }
            }
            applySync(result)
            let names = result.types.map { HealthSyncParser.name($0) }.joined(separator: ", ")
            healthNote("sync \(msg.count) B: \(names)" + (result.stoppedAt.map { " · stopped at " + HealthSyncParser.name($0) } ?? ""))
            return L("Health sync (%d B)", msg.count)
        case (true, HealthProto.MsgId.gmCapabilityNoti):
            return L("Health capability OK")
        case (_, 32), (_, 33):
            healthNote("band capability \(msg.count) B")
            return L("Band health capability")
        case (_, HealthProto.MsgId.wearableMsg):
            healthNote("wearable message \(msg.count) B")
            return L("Health message")
        case (_, HealthProto.MsgId.shealthInstall), (_, HealthProto.MsgId.shealthUpgrade), (_, HealthProto.MsgId.shealthStore):
            healthNote("band asks for Samsung Health (msg \(h.msgId))")
            return L("Band asks for Samsung Health")
        default:
            return String(format: "0A/%02X", first)
        }
    }

    /// Pede os dados de saude agora (REQUEST_DATA), como o Samsung Health faz ao abrir.
    func requestHealthData() {
        guard sessionReady else { return }
        healthSeq += 1
        sendHealth(L("Request health data"), HealthProto.requestData(seq: healthSeq))
    }

    private func sendHealth(_ label: String, _ msg: [UInt8]) {
        send(label, FrameCodec.cmd(0x0A, msg))
    }

    private func healthNote(_ text: String) {
        healthLog.insert("\(clock.string(from: Date()))  \(text)", at: 0)
        if healthLog.count > 40 { healthLog.removeLast(healthLog.count - 40) }
        log("health: \(text)")
    }

    private func applySync(_ r: HealthSyncResult) {
        let cal = Calendar.current
        var changed = false
        if let day = r.days.last(where: { $0.day.map { cal.isDateInToday($0) } ?? false }) ?? (r.days.count == 1 ? r.days.first : nil) {
            if let v = day.steps { stepsToday = v; changed = true }
            if let v = day.goal, v > 0 { stepGoal = v }
            if let v = day.calories { caloriesToday = Double(v); activeKcalToday = Double(v) }
            if let v = day.distance { distanceToday = Double(v) }
        } else {
            let today = r.steps.filter { $0.start.map { cal.isDateInToday($0) } ?? false }
            if !today.isEmpty {
                // Registros por intervalo: guarda por horario de inicio (reenvio nao conta duas vezes).
                var buckets = stepBuckets
                for rec in today {
                    guard let start = rec.start else { continue }
                    buckets[String(Int(start.timeIntervalSince1970))] = [Double(max(rec.steps, 0)),
                                                                         Double(rec.calories ?? 0),
                                                                         Double(rec.distance ?? 0)]
                }
                stepBuckets = buckets
                stepsToday = Int(buckets.values.reduce(0) { $0 + $1[0] })
                let kcal = buckets.values.reduce(0) { $0 + $1[1] }
                if kcal > 0 { caloriesToday = kcal }
                let dist = buckets.values.reduce(0) { $0 + $1[2] }
                if dist > 0 { distanceToday = dist }
                changed = true
            }
        }
        if r.days.isEmpty, let c = r.calories.last(where: { $0.day.map { cal.isDateInToday($0) } ?? false }) {
            let total = Double((c.active ?? 0) + (c.rest ?? 0))
            if total > 0 { caloriesToday = total; changed = true }
            if let a = c.active, a > 0 { activeKcalToday = Double(a) }
        }
        if !r.heart.isEmpty {
            var all = heartHistory + r.heart
            all.sort { $0.time < $1.time }
            var seen = Set<Int>()
            all = all.filter { seen.insert(Int($0.time.timeIntervalSince1970)).inserted }
            let dayAgo = Date().addingTimeInterval(-86400)
            heartHistory = Array(all.filter { $0.time > dayAgo }.suffix(500))
            if let latest = heartHistory.last, latest.time > (lastBpmDate ?? .distantPast) {
                lastBpm = latest.bpm
                lastBpmDate = latest.time
            }
            healthNote("heart rate: \(r.heart.count) points, latest \(heartHistory.last?.bpm ?? 0) bpm")
            changed = true
        }
        if let s = r.spo2.max(by: { $0.time < $1.time }), s.time > (lastSpO2Date ?? .distantPast) {
            lastSpO2 = s.value
            lastSpO2Date = s.time
            healthNote("SpO2: \(s.value)%")
            changed = true
        }
        if !r.steps.isEmpty || !r.days.isEmpty || changed {
            lastHealthSync = Date()
            saveTodayActivity()
            let hk = HealthWriter.shared
            hk.writeDayTotals(steps: stepsToday, distanceMeters: distanceToday, activeKcal: activeKcalToday)
            hk.writeHeart(r.heart.map { (start: $0.time, end: $0.time, bpm: $0.bpm) })
            hk.writeSpO2(r.spo2)
        }
    }

    private static let dayKey: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Registros de passos de hoje: inicio (s) -> [passos, kcal, distancia].
    private var stepBuckets: [String: [Double]] {
        get {
            let key = "stepRecords." + Fit3Client.dayKey.string(from: Date())
            return UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]] ?? [:]
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "stepRecords." + Fit3Client.dayKey.string(from: Date()))
        }
    }

    private func saveTodayActivity() {
        let key = "activity." + Fit3Client.dayKey.string(from: Date())
        var d: [String: Double] = [:]
        if let v = stepsToday { d["steps"] = Double(v) }
        if let v = stepGoal { d["goal"] = Double(v) }
        if let v = caloriesToday { d["kcal"] = v }
        if let v = distanceToday { d["dist"] = v }
        if let v = activeKcalToday { d["active"] = v }
        if let v = lastHealthSync { d["sync"] = v.timeIntervalSince1970 }
        UserDefaults.standard.set(d, forKey: key)
        if let v = lastSpO2, let t = lastSpO2Date {
            UserDefaults.standard.set(["value": Double(v), "time": t.timeIntervalSince1970], forKey: "lastSpO2")
        }
        if let data = try? JSONEncoder().encode(heartHistory) {
            UserDefaults.standard.set(data, forKey: "heartHistory")
        }
    }

    func loadTodayActivity() {
        let key = "activity." + Fit3Client.dayKey.string(from: Date())
        let d = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        stepsToday = d["steps"].map { Int($0) }
        stepGoal = d["goal"].map { Int($0) } ?? stepGoal
        caloriesToday = d["kcal"]
        distanceToday = d["dist"]
        activeKcalToday = d["active"]
        lastHealthSync = d["sync"].map { Date(timeIntervalSince1970: $0) }
        if let o = UserDefaults.standard.dictionary(forKey: "lastSpO2") as? [String: Double],
           let v = o["value"], let t = o["time"] {
            lastSpO2 = Int(v)
            lastSpO2Date = Date(timeIntervalSince1970: t)
        }
        if let data = UserDefaults.standard.data(forKey: "heartHistory"),
           let list = try? JSONDecoder().decode([HeartSample].self, from: data) {
            heartHistory = list.filter { $0.time > Date().addingTimeInterval(-86400) }
        }
    }

    // MARK: - Widgets (canal 0x0F, WidgetsService)

    /// Ordem que a pulseira tinha antes dos testes (log de 19/11).
    static let defaultWidgetOrder: [UInt8] = [0x17, 0x15, 0x1C, 0x02, 0x08, 0x06, 0x19, 0x18]

    func requestWidgets() {
        guard sessionReady else { return }
        send(L("Request widgets"), FrameCodec.cmd(0x0F, [0x00]))
    }

    /// SET_WIDGET_INFO: 01 01 <n> {03 <id> 02 <posicao>} em ordem de id (como o plugin manda).
    func setWidgets(_ list: [BandWidget]) {
        guard sessionReady, !list.isEmpty else { return }
        var out: [UInt8] = [0x01, 0x01, UInt8(list.count)]
        for w in list.sorted(by: { $0.id < $1.id }) { out += [0x03, w.id, 0x02, w.slot] }
        send(L("Save widgets"), FrameCodec.cmd(0x0F, out))
        widgets = list
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.requestWidgets() }
    }

    func widgetName(_ id: UInt8) -> String {
        if let n = UserDefaults.standard.string(forKey: "widgetName.\(id)"), !n.isEmpty { return n }
        return L("Widget %@", String(format: "%02X", id))
    }

    func renameWidget(_ id: UInt8, _ name: String) {
        UserDefaults.standard.set(name, forKey: "widgetName.\(id)")
        objectWillChange.send()
    }

    // MARK: - Mostradores (canal 0x06, WatchfaceSerevice)

    private func handleFaces(_ msg: [UInt8]) -> String {
        guard let first = msg.first else { return "06" }
        let cmd = first & 0x3F
        switch cmd {
        case BandFaceProto.Command.getAllInfo.rawValue:
            let info = BandFaceProto.parseAllInfo(msg)
            if !info.faces.isEmpty { bandFaces = info.faces }
            currentFaceId = info.currentId ?? bandFaces.first(where: { $0.isCurrent })?.id
            maxFaces = info.maxCount
            return L("Watch faces (%d)", info.faces.count)
        case BandFaceProto.Command.setCurrent.rawValue, BandFaceProto.Command.getCurrent.rawValue:
            if let id = BandFaceProto.parseCurrent(msg) {
                currentFaceId = id
                for k in bandFaces.indices { bandFaces[k].isCurrent = bandFaces[k].id == id }
                return L("Current watch face %d", id)
            }
            return L("Watch face changed")
        default:
            return String(format: "06/%02X", first)
        }
    }

    func requestFaces() {
        guard sessionReady else { return }
        send(L("Request watch faces"), FrameCodec.cmd(0x06, BandFaceProto.getAllInfo))
    }

    func setFace(_ face: BandFace) {
        guard sessionReady else { return }
        send(L("Use watch face %d", face.id), FrameCodec.cmd(0x06, BandFaceProto.setCurrent(id: face.id, sampler: face.samplerId)))
    }


    func toggleRecording() {
        if recording {
            recording = false
        } else {
            capture.removeAll()
            recording = true
        }
    }

    /// Arquivo .jsonl com a captura (ou com tudo, se nada foi gravado).
    func exportJSONL() -> URL {
        let source = capture.isEmpty ? frames : capture
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        var text = ""
        for f in source {
            if let d = try? enc.encode(f), let s = String(data: d, encoding: .utf8) {
                text += s + "\n"
            }
        }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("elo-capture-\(f.string(from: Date())).jsonl")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Fila de escrita (uma de cada vez)

    private func send(_ label: String, _ data: Data) {
        queue.append((label, data))
        pump()
    }

    private func pump() {
        guard !writing, !queue.isEmpty, let p = peripheral, let w = sapWrite else { return }
        let item = queue.removeFirst()
        writing = true
        log("TX \(item.0) (\(item.1.count) B)")
        addFrame(dir: "TX", data: item.1, label: item.0, error: false)
        p.writeValue(item.1, for: w, type: .withResponse)
    }

    private func startSession() {
        status = L("Opening session…")
        for item in Fit3Protocol.sessionSequence() {
            queue.append(item)
        }
        // A config vinda do Fit3 Bridge deixa a pulseira em espanhol: corrige para o idioma escolhido.
        queue.append((L("Band language (id %d)", Int(bandLanguage)), Fit3Protocol.language(bandLanguage)))
        pump()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self = self, self.connected else { return }
            self.sessionReady = true
            self.connecting = false
            self.status = L("Ready")
            self.lastContact = Date()
            if self.hrHolds > 0 {
                self.holdHeartRate(true)
                self.hrHolds -= 1
            } else {
                self.measureHeartRate(seconds: 20)
            }
            if let p = self.peripheral {
                self.mtu = p.maximumWriteValueLength(for: .withoutResponse) + 3
            }
            self.startRSSI()
            self.requestFaces()
        }
    }

    private func startRSSI() {
        rssiTimer?.invalidate()
        guard inForeground else { return }
        peripheral?.readRSSI()
        rssiTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.peripheral?.readRSSI()
        }
    }

    private func attach(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
    }

    // MARK: - Recebido da pulseira

    /// Junta frames SAP que chegam quebrados em varias notificacoes (dados de saude sao grandes).
    private func ingestSAP(_ value: Data) {
        let b = [UInt8](value)
        if !rxBuffer.isEmpty && Date().timeIntervalSince(rxBufferDate) > 3 {
            rxBuffer.removeAll()
        }
        if rxBuffer.isEmpty && b.count >= 2 && b[0] == 0x68 && (b[1] == 0x14 || b[1] == 0x15) {
            handleRX(value)
            return
        }
        rxBuffer += b
        rxBufferDate = Date()
        while rxBuffer.count >= 6 {
            let len = (Int(rxBuffer[0]) << 8) | Int(rxBuffer[1])
            let hdr = (UInt16(rxBuffer[2]) << 8) | UInt16(rxBuffer[3])
            guard hdr == FrameCodec.crc16ARC(Array(rxBuffer[0..<2])) else {
                handleRX(Data(rxBuffer))
                rxBuffer.removeAll()
                return
            }
            let total = len + 6
            guard rxBuffer.count >= total else { return }
            let frame = Array(rxBuffer[0..<total])
            rxBuffer.removeFirst(total)
            handleRX(Data(frame))
        }
    }

    private func handleRX(_ value: Data) {
        lastContact = Date()
        maybePeriodicHeartRate()
        switch FrameCodec.parse(value) {
        case .handshake:
            log("RX SAP handshake (\(value.count) B)")
            addFrame(dir: "RX", data: value, label: L("Session ACK"), error: false)
        case .ack:
            addFrame(dir: "RX", data: value, label: "ACK", error: false)
        case .invalid:
            log("RX ?? \(FrameCodec.hex([UInt8](value.prefix(24))))")
            addFrame(dir: "RX", data: value, label: L("Invalid CRC"), error: true)
        case .frame(let f):
            let ch = String(format: "%02X", f.channel)
            let cm = String(format: "%02X", f.command)
            log("RX ch \(ch) cmd \(cm) \(FrameCodec.hex(Array(f.data.prefix(16))))")
            var label = "\(ch)/\(cm)"
            if f.channel == 0x01 && f.command == 0x43 && f.data.count >= 2 {
                battery = Int(f.data[1])
                label = L("Battery %d%%", Int(f.data[1]))
            } else if f.channel == 0x0B && (f.command == 0x42 || f.command == 0x02) && f.data.count >= 4 {
                battery = Int(f.data[3])
                label = L("Battery %d%%", Int(f.data[3]))
            } else if f.channel == 0x0B && f.command == 0x41 {
                label = L("Language confirmed")
            } else if f.channel == 0x01 && f.command == 0x41 {
                label = L("Device info")
            } else if f.channel == 0x1F {
                label = L("Find band")
            } else if f.channel == 0x0F && f.data.count >= 2 && f.data[0] == 0x01 {
                var list: [BandWidget] = []
                var i = 2
                while i + 3 < f.data.count && f.data[i] == 0x03 && f.data[i + 2] == 0x02 {
                    list.append(BandWidget(id: f.data[i + 1], slot: f.data[i + 3]))
                    i += 4
                }
                if !list.isEmpty { widgets = list }
                label = L("Widgets (%d)", list.count)
            } else if f.channel == 0x0A {
                label = handleHealth([f.command] + f.data)
            } else if f.channel == 0x06 {
                label = handleFaces([f.command] + f.data)
            } else if f.channel == 0x09 {
                label = MusicBridge.shared.handle([f.command] + f.data)
            } else if f.channel == 0x18 {
                label = L("Apps list")
            }
            addFrame(dir: "RX", data: value, label: label, error: false)
        }
    }

    private func addFrame(dir: String, data: Data, label: String, error: Bool) {
        nextFrameId += 1
        frameCount += 1
        let bytes = [UInt8](data)
        var hex = FrameCodec.hex(Array(bytes.prefix(28)))
        if bytes.count > 28 { hex += " …" }
        let frame = ConsoleFrame(id: nextFrameId, time: Date(), dir: dir, length: bytes.count,
                                 label: label, hex: hex, error: error, full: FrameCodec.hex(bytes))
        frames.append(frame)
        if frames.count > 600 { frames.removeFirst(frames.count - 600) }
        if recording { capture.append(frame) }
    }

    private func log(_ text: String) {
        lines.append("\(clock.string(from: Date()))  \(text)")
        if lines.count > 400 {
            lines.removeFirst(lines.count - 400)
        }
    }

    private func resetLink() {
        hrStopWork?.cancel()
        MusicBridge.shared.bandDisconnected()
        rxBuffer.removeAll()
        largeData.reset()
        healthHandshake = false
        measuringHR = false
        hrContact = false
        connected = false
        sessionReady = false
        writing = false
        queue.removeAll()
        sapNotify = nil
        sapWrite = nil
        hrMeas = nil
        rssiTimer?.invalidate()
        rssiTimer = nil
    }
}

// MARK: - CBCentralManagerDelegate

extension Fit3Client: CBCentralManagerDelegate {

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let list = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral], let p = list.first {
            attach(p)
            wantConnection = true
            log("restored by iOS")
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            log("Bluetooth ready")
            if let p = peripheral, p.state == .connected {
                connected = true
                p.discoverServices([Fit3Client.sapService, Fit3Client.hrService])
            } else if wantConnection || savedPeripheralId != nil {
                connect()
            }
        case .poweredOff:
            log("Bluetooth off")
            resetLink()
            status = L("Bluetooth is off")
        case .unauthorized:
            log("no Bluetooth permission")
            status = L("No Bluetooth permission")
        default:
            log("Bluetooth state \(central.state.rawValue)")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? advName ?? ""
        guard name.lowercased().contains("fit3") else { return }
        central.stopScan()
        attach(peripheral)
        savedPeripheralId = peripheral.identifier
        rssi = RSSI.intValue
        status = L("Connecting…")
        log("found \(name) (RSSI \(RSSI))")
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connected = true
        savedPeripheralId = peripheral.identifier
        status = L("Connected, reading services…")
        log("connected")
        peripheral.discoverServices([Fit3Client.sapService, Fit3Client.hrService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connecting = false
        status = L("Connection failed")
        log("connection failed: \(error?.localizedDescription ?? "-")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        resetLink()
        log("disconnected: \(error?.localizedDescription ?? "normal")")
        if wantConnection && !userDisconnected {
            // O iOS fica tentando sozinho, inclusive em segundo plano.
            status = L("Reconnecting…")
            connecting = true
            central.connect(peripheral, options: nil)
        } else {
            connecting = false
            status = L("Disconnected")
        }
    }
}

// MARK: - CBPeripheralDelegate

extension Fit3Client: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            log("service error: \(error.localizedDescription)")
            return
        }
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for ch in service.characteristics ?? [] {
            if ch.uuid == Fit3Client.sapNotifyUUID {
                sapNotify = ch
                status = L("Pairing (confirm the code)…")
                log("SAP channel found; enabling notify (iOS may ask to pair)")
                peripheral.setNotifyValue(true, for: ch)
            } else if ch.uuid == Fit3Client.sapWriteUUID {
                sapWrite = ch
            } else if ch.uuid == Fit3Client.hrMeasUUID {
                hrMeas = ch
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error = error {
            log("notify \(characteristic.uuid) failed: \(error.localizedDescription)")
            return
        }
        if characteristic.uuid == Fit3Client.sapNotifyUUID && characteristic.isNotifying {
            log("SAP notify active (paired)")
            startSession()
        } else if characteristic.uuid == Fit3Client.hrMeasUUID {
            log(characteristic.isNotifying ? "heart rate: on" : "heart rate: off")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            log("write failed: \(error.localizedDescription)")
        }
        writing = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.pump()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        if error == nil { rssi = RSSI.intValue }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value else { return }
        if characteristic.uuid == Fit3Client.hrMeasUUID {
            if let hr = Fit3Protocol.heartRate(value) {
                bpm = hr.bpm
                hrContact = hr.contact
                if hr.contact && hr.bpm > 0 {
                    lastBpm = hr.bpm
                    lastBpmDate = Date()
                    bpmSamples.append(hr.bpm)
                    if liveHRStart == nil { liveHRStart = Date() }
                    liveHR.append(hr.bpm)
                    if let st = liveHRStart, Date().timeIntervalSince(st) >= 60 { flushLiveHeart() }
                    if bpmSamples.count > 120 { bpmSamples.removeFirst(bpmSamples.count - 120) }
                    restingBpm = min(restingBpm ?? hr.bpm, hr.bpm)
                }
            }
            return
        }
        ingestSAP(value)
    }
}
