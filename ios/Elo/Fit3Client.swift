import CoreBluetooth
import Foundation

/// Cliente BLE da Galaxy Fit3: procura, conecta, pareia (o iOS mostra o codigo),
/// abre a sessao SAP e expoe os comandos ja validados no PC.
final class Fit3Client: NSObject, ObservableObject {

    @Published var status: String = "Desconectado"
    @Published var connected: Bool = false
    @Published var sessionReady: Bool = false
    @Published var battery: Int?
    @Published var bpm: Int?
    @Published var hrContact: Bool = false
    @Published var lines: [String] = []

    static let sapService = CBUUID(string: "1A1A")
    static let sapNotifyUUID = CBUUID(string: "797AE4E9-2E58-4FE8-B48D-B5C79599FB9B")
    static let sapWriteUUID = CBUUID(string: "63E30BAD-4206-4596-839F-E47CBF7A4B5D")
    static let hrService = CBUUID(string: "180D")
    static let hrMeasUUID = CBUUID(string: "2A37")

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var sapNotify: CBCharacteristic?
    private var sapWrite: CBCharacteristic?
    private var hrMeas: CBCharacteristic?
    private var queue: [(String, Data)] = []
    private var writing = false
    private var notificationCounter = Int(Date().timeIntervalSince1970) % 100000

    private let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - Acoes da interface

    func connect() {
        guard central.state == .poweredOn else {
            log("Bluetooth do iPhone nao esta ligado")
            return
        }
        status = "Procurando a pulseira..."
        log("procurando dispositivos com 'Fit3' no nome")
        central.scanForPeripherals(withServices: nil, options: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self = self, self.peripheral == nil else { return }
            self.central.stopScan()
            self.status = "Nao encontrei a pulseira"
            self.log("busca encerrada sem encontrar")
        }
    }

    func disconnect() {
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
    }

    func vibrate() {
        send("achar pulseira: vibrar", Fit3Protocol.findOn)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.send("achar pulseira: parar", Fit3Protocol.findOff)
        }
    }

    func sendNotification(from sender: String, text: String, app: String) {
        notificationCounter += 1
        let frame = Fit3Protocol.notification(from: sender, text: text, app: app, id: notificationCounter)
        send("notificacao de \(sender)", frame)
    }

    func setLanguage(_ id: UInt8) {
        send("idioma id \(id)", Fit3Protocol.language(id))
    }

    // MARK: - Fila de escrita (uma de cada vez, como no PC)

    private func send(_ label: String, _ data: Data) {
        queue.append((label, data))
        pump()
    }

    private func pump() {
        guard !writing, !queue.isEmpty, let p = peripheral, let w = sapWrite else { return }
        let item = queue.removeFirst()
        writing = true
        log("TX \(item.0) (\(item.1.count) B)")
        p.writeValue(item.1, for: w, type: .withResponse)
    }

    private func startSession() {
        status = "Abrindo sessao..."
        for item in Fit3Protocol.sessionSequence() {
            queue.append(item)
        }
        pump()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self = self, self.connected else { return }
            self.sessionReady = true
            self.status = "Pronta"
            if let hr = self.hrMeas, let p = self.peripheral {
                p.setNotifyValue(true, for: hr)
            }
        }
    }

    // MARK: - Recebido da pulseira

    private func handleRX(_ value: Data) {
        switch FrameCodec.parse(value) {
        case .handshake:
            log("RX handshake SAP (\(value.count) B)")
        case .ack:
            break
        case .invalid:
            log("RX ?? \(FrameCodec.hex([UInt8](value.prefix(24))))")
        case .frame(let f):
            let ch = String(format: "%02X", f.channel)
            let cm = String(format: "%02X", f.command)
            log("RX canal \(ch) cmd \(cm) \(FrameCodec.hex(Array(f.data.prefix(16))))")
            if f.channel == 0x01 && f.command == 0x43 && f.data.count >= 2 {
                battery = Int(f.data[1])
            }
            if f.channel == 0x0B && (f.command == 0x42 || f.command == 0x02) && f.data.count >= 4 {
                battery = Int(f.data[3])
            }
        }
    }

    private func log(_ text: String) {
        lines.append("\(clock.string(from: Date()))  \(text)")
        if lines.count > 400 {
            lines.removeFirst(lines.count - 400)
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension Fit3Client: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: log("Bluetooth pronto")
        case .poweredOff: log("Bluetooth desligado")
        case .unauthorized: log("Sem permissao de Bluetooth (Ajustes > Elo)")
        default: log("Bluetooth estado \(central.state.rawValue)")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? advName ?? ""
        guard name.lowercased().contains("fit3") else { return }
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        status = "Conectando..."
        log("achei \(name) (RSSI \(RSSI))")
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connected = true
        status = "Conectada, lendo servicos..."
        log("conectado")
        peripheral.discoverServices([Fit3Client.sapService, Fit3Client.hrService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        status = "Falha ao conectar"
        log("falha ao conectar: \(error?.localizedDescription ?? "-")")
        self.peripheral = nil
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connected = false
        sessionReady = false
        writing = false
        queue.removeAll()
        sapNotify = nil
        sapWrite = nil
        hrMeas = nil
        self.peripheral = nil
        status = "Desconectado"
        log("desconectou: \(error?.localizedDescription ?? "normal")")
    }
}

// MARK: - CBPeripheralDelegate

extension Fit3Client: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            log("erro nos servicos: \(error.localizedDescription)")
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
                status = "Pareando (confirme o codigo)..."
                log("canal SAP encontrado; ativando notify (o iOS deve pedir o pareamento)")
                peripheral.setNotifyValue(true, for: ch)
            } else if ch.uuid == Fit3Client.sapWriteUUID {
                sapWrite = ch
            } else if ch.uuid == Fit3Client.hrMeasUUID {
                hrMeas = ch
                if sessionReady {
                    peripheral.setNotifyValue(true, for: ch)
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error = error {
            log("notify \(characteristic.uuid) falhou: \(error.localizedDescription)")
            return
        }
        if characteristic.uuid == Fit3Client.sapNotifyUUID && characteristic.isNotifying {
            log("SAP notify ativo (pareado)")
            startSession()
        } else if characteristic.uuid == Fit3Client.hrMeasUUID {
            log("batimentos: inscrito no 2A37")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            log("escrita falhou: \(error.localizedDescription)")
        }
        writing = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.pump()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value else { return }
        if characteristic.uuid == Fit3Client.hrMeasUUID {
            if let hr = Fit3Protocol.heartRate(value) {
                bpm = hr.bpm
                hrContact = hr.contact
            }
            return
        }
        handleRX(value)
    }
}
