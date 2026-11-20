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
}

/// Idioma da pulseira (id do canal 0B).
struct BandLanguage: Identifiable {
    let id: UInt8
    let name: String
}

/// Mostrador instalado na pulseira (lista do canal 0x0F): id e posicao no carrossel (0xFF = fora).
struct WatchFace: Identifiable, Equatable {
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
    @Published var watchFaces: [WatchFace] = []
    @Published var faceLabLog: [String] = []
    @Published var probeRunning = false
    @Published var probeIndex = 0
    @Published var probeTotal = 0

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
    private var probeItems: [DispatchWorkItem] = []
    private var lastBuzz: Date = .distantPast
    private var lastHRMeasure: Date = .distantPast
    private var hrStopWork: DispatchWorkItem?
    private var hrHolds = 0
    private var inForeground = true

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

    /// Responde o 0A/A2 periodico com eco em 0A/62 (no PC isso fez a pulseira parar de repetir).
    var autoAckA2: Bool {
        get { UserDefaults.standard.object(forKey: "autoAckA2") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoAckA2"); objectWillChange.send() }
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

    private func stopHeartRate() {
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
        if vibrateOnArrival && Date().timeIntervalSince(lastBuzz) >= Double(vibrationCooldown) {
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
        let item = SentNotification(from: sender, app: app, text: text, date: Date())
        history.insert(item, at: 0)
        if history.count > 30 { history.removeLast(history.count - 30) }
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: "sentHistory")
        }
        liveAlert = LiveAlert(screen: .message(app: app, from: sender, text: text), date: Date())
    }

    func sendCall(from caller: String, buzz: Bool) {
        notificationCounter += 1
        let frame = Fit3Protocol.notification(from: caller, text: L("Calling…"), app: L("Phone"),
                                              id: notificationCounter)
        send(L("Call from %@", caller), frame)
        if buzz { vibrate() }
        liveAlert = LiveAlert(screen: .call(name: caller), date: Date())
    }

    func setLanguage(_ id: UInt8) {
        bandLanguage = id
        send(L("Band language (id %d)", Int(id)), Fit3Protocol.language(id))
    }

    // MARK: - Sonda (procura os comandos de passos, sono etc.)

    /// Rodada 2: o canal 0x18 so respondeu a pedidos do tipo 0x80 (18/80 e 18/40 02 01 devolveram a
    /// tabela 18/C0). Aqui vao os pedidos 0x81..0x8F, com e sem o id do tipo de dado (01..0A da tabela).
    static func probeList() -> [(String, Data)] {
        var list: [(String, Data)] = []
        func add(_ ch: UInt8, _ data: [UInt8]) {
            let label = String(format: "Probe %02X/%02X", ch, data.first ?? 0)
                + (data.count > 1 ? " " + FrameCodec.hex(Array(data.dropFirst())) : "")
            list.append((label, FrameCodec.cmd(ch, data)))
        }
        for c: UInt8 in 0x81...0x8F { add(0x18, [c]) }
        for t: UInt8 in 0x01...0x0A { add(0x18, [0x81, t]) }
        for t: UInt8 in 0x01...0x0A { add(0x18, [0x82, t]) }
        for c: UInt8 in 0x81...0x86 { add(0x18, [c, 0x02, 0x01]) }
        for c: UInt8 in 0x41...0x46 { add(0x18, [c, 0x02, 0x01]) }
        return list
    }

    func startProbe() {
        guard sessionReady, !probeRunning else { return }
        let list = Fit3Client.probeList()
        probeItems.forEach { $0.cancel() }
        probeItems = []
        if !recording { toggleRecording() }
        probeRunning = true
        probeIndex = 0
        probeTotal = list.count
        log("probe: \(list.count) requests, 2.5 s apart")
        for (i, item) in list.enumerated() {
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, self.probeRunning else { return }
                self.probeIndex = i + 1
                self.send("#\(i + 1) " + item.0, item.1)
            }
            probeItems.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5 * Double(i), execute: work)
        }
        let done = DispatchWorkItem { [weak self] in
            self?.probeRunning = false
            self?.log("probe finished")
        }
        probeItems.append(done)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5 * Double(list.count) + 4, execute: done)
    }

    func stopProbe() {
        probeItems.forEach { $0.cancel() }
        probeItems = []
        probeRunning = false
        log("probe stopped")
    }

    // MARK: - Laboratorio de mostradores (canal 0x0F)

    /// "01 <n>" + n x "03 <id> 02 <posicao>" (como a pulseira manda no 0F/00).
    static func encodeFaceList(_ faces: [WatchFace]) -> [UInt8] {
        var out: [UInt8] = [0x01, UInt8(faces.count)]
        for f in faces { out += [0x03, f.id, 0x02, f.slot] }
        return out
    }

    /// Mesma lista com o mostrador escolhido na posicao 1 e os outros empurrados.
    func faceListWithFirst(_ id: UInt8) -> [WatchFace] {
        let inCarousel = watchFaces.filter { $0.slot != 0xFF && $0.id != id }.sorted { $0.slot < $1.slot }
        var ordered = [WatchFace(id: id, slot: 1)]
        for (i, f) in inCarousel.enumerated() { ordered.append(WatchFace(id: f.id, slot: UInt8(i + 2))) }
        let rest = watchFaces.filter { $0.slot == 0xFF && $0.id != id }
        return ordered + rest
    }

    /// Tentativas para "usar este mostrador"; o usuario diz qual funcionou.
    func faceAttempts(for id: UInt8) -> [(String, Data)] {
        let list = Fit3Client.encodeFaceList(faceListWithFirst(id))
        return [
            ("0F/01 03 id", FrameCodec.cmd(0x0F, [0x01, 0x03, id])),
            ("0F/01 id", FrameCodec.cmd(0x0F, [0x01, id])),
            ("0F/02 03 id", FrameCodec.cmd(0x0F, [0x02, 0x03, id])),
            ("0F/02 id", FrameCodec.cmd(0x0F, [0x02, id])),
            ("0F/03 03 id", FrameCodec.cmd(0x0F, [0x03, 0x03, id])),
            ("0F/04 03 id", FrameCodec.cmd(0x0F, [0x04, 0x03, id])),
            ("0F/81 03 id", FrameCodec.cmd(0x0F, [0x81, 0x03, id])),
            ("0F/01 + list", FrameCodec.cmd(0x0F, [0x01] + list)),
            ("0F/02 + list", FrameCodec.cmd(0x0F, [0x02] + list)),
            ("0F/40 + list", FrameCodec.cmd(0x0F, [0x40] + list)),
        ]
    }

    func tryFace(_ id: UInt8, attempt index: Int) {
        let attempts = faceAttempts(for: id)
        guard sessionReady, index < attempts.count else { return }
        if !recording { toggleRecording() }
        let a = attempts[index]
        send(String(format: "Face %02X · try %d · ", id, index + 1) + a.0, a.1)
    }

    func noteFaceResult(_ text: String) {
        faceLabLog.insert("\(clock.string(from: Date()))  \(text)", at: 0)
        log("face lab: \(text)")
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
                var list: [WatchFace] = []
                var i = 2
                while i + 3 < f.data.count && f.data[i] == 0x03 && f.data[i + 2] == 0x02 {
                    list.append(WatchFace(id: f.data[i + 1], slot: f.data[i + 3]))
                    i += 4
                }
                if !list.isEmpty { watchFaces = list }
                label = L("Watch faces (%d)", list.count)
            } else if f.channel == 0x0A && f.command == 0xA2 {
                label = "0A/A2 (keep-alive)"
                if autoAckA2 {
                    send("Ack 0A/62", FrameCodec.cmd(0x0A, [0x62] + f.data))
                }
            } else if f.channel == 0x18 {
                label = L("Health %@", "18/" + cm)
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
        if probeRunning { stopProbe() }
        hrStopWork?.cancel()
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
                    if bpmSamples.count > 120 { bpmSamples.removeFirst(bpmSamples.count - 120) }
                    restingBpm = min(restingBpm ?? hr.bpm, hr.bpm)
                }
            }
            return
        }
        handleRX(value)
    }
}
