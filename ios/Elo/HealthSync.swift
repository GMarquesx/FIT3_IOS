import Foundation

/// Canal de saude 0x0A (servico "HealthService" do SAP). Formato tirado do plugin oficial
/// (com.samsung.wearable.fit3plugin, HealthDataManager / ConsolidatedSyncDataParser).
///
/// Cabecalho de 1 byte: bit7 = frameType, bit6 = 0 pedido / 1 resposta, bits0-5 = messageId.
/// Inteiros sempre little endian.
enum HealthProto {

    /// versionCode do Samsung Health que dizemos ter (a pulseira so manda dados se achar que ele existe).
    static let sHealthVersion: UInt32 = 6_305_021
    /// Versao do protocolo de saude que o plugin suporta.
    static let protocolVersion = 301

    enum MsgId {
        static let syncData = 2
        static let requestData = 3
        static let wearableMsg = 4
        static let gmCapabilityRequest = 34
        static let gmCapabilityNoti = 35
        static let shealthInstall = 49
        static let shealthUpgrade = 50
        static let shealthStore = 51
        static let largeAck = 62
        static let largeChunk = 63
    }

    struct Header {
        let frameType: Int
        let isResponse: Bool
        let msgId: Int
        init(_ b: UInt8) {
            frameType = Int(b >> 7)
            isResponse = (b & 0x40) != 0
            msgId = Int(b & 0x3F)
        }
    }

    static func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    static func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
    static func read16(_ b: [UInt8], _ i: Int) -> Int? {
        guard i + 1 < b.count else { return nil }
        return Int(b[i]) | (Int(b[i + 1]) << 8)
    }
    static func read32(_ b: [UInt8], _ i: Int) -> UInt32? {
        guard i + 3 < b.count else { return nil }
        return UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
    }

    /// Numero de sequencia: tag 0xE0 + 2 bytes, no byte 1 ou 2 da mensagem.
    static func sequence(_ msg: [UInt8]) -> Int? {
        guard msg.count >= 4 else { return nil }
        for i in 1..<3 where msg[i] == 0xE0 { return read16(msg, i + 1) }
        return nil
    }

    /// Resposta ao GM_REQUEST_CAPABILITY (0xA2): E2 <n> E0 seq E1 versao D0 02 D2 <versao S Health>.
    static func gmCapabilityResponse(to msg: [UInt8]) -> (reply: [UInt8], seq: Int?, version: Int?) {
        var out: [UInt8] = [0xE2]
        var count = 0
        var seq: Int?
        var ver: Int?
        if msg.count > 1 {
            var n = Int(msg[1])
            var i = 2
            while n > 0 && i < msg.count {
                let tag = msg[i]
                if tag == 0xE0, let v = read16(msg, i + 1) {
                    seq = v
                    out += [0xE0] + le16(v)
                    count += 1
                    i += 3
                } else if tag == 0xE1, let v = read16(msg, i + 1) {
                    let use = min(v, protocolVersion)
                    ver = use
                    out += [0xE1] + le16(use)
                    count += 1
                    i += 3
                } else {
                    i += 1
                }
                n -= 1
            }
        }
        out += [0xD0, 0x02, 0xD2] + le32(sHealthVersion)
        count += 2
        out.insert(UInt8(count), at: 1)
        return (out, seq, ver)
    }

    /// Capacidade de saude da pulseira (0xA0, msgId 32), repetida a cada ~20 s ate ser respondida.
    /// Blocos: tag + valor; tamanhos tirados de parseCapaStringToByte / parseCapabilityByte do plugin.
    struct BandCapability {
        var blocks: [UInt8: [UInt8]] = [:]   // tag -> bytes do valor (sem a tag)
        var order: [UInt8] = []
        var bluetoothName: String?
        var modelName: String?
        var modelNumber: String?
        var protocolBytes: [UInt8]?
        var wearableMessage: [UInt8]?
    }

    private static let fixedSize: [UInt8: Int] = [
        0xE0: 2, 0xA0: 1, 0xA1: 2, 0xA2: 4, 0xA6: 6, 0xA7: 2, 0xAA: 3, 0xAB: 1, 0xAC: 1, 0xAD: 2,
        0xAE: 4, 0xAF: 2, 0xB1: 1, 0xC0: 1, 0xC1: 1, 0xC2: 1,
    ]
    private static let lengthPrefixed: Set<UInt8> = [0xA3, 0xA4, 0xA5, 0xA8, 0xA9, 0xB2, 0xB3]

    static func parseBandCapability(_ msg: [UInt8]) -> BandCapability {
        var c = BandCapability()
        var i = 2
        var n = msg.count > 1 ? Int(msg[1]) : 0
        while n > 0 && i < msg.count {
            n -= 1
            let tag = msg[i]
            i += 1
            var value: [UInt8]
            if let size = fixedSize[tag] {
                guard i + size <= msg.count else { break }
                value = Array(msg[i..<(i + size)])
                i += size
            } else if lengthPrefixed.contains(tag) {
                guard i < msg.count else { break }
                let len = Int(msg[i])
                guard i + 1 + len <= msg.count else { break }
                value = Array(msg[i..<(i + 1 + len)])   // mantem o byte de tamanho
                i += 1 + len
            } else {
                break
            }
            c.blocks[tag] = value
            c.order.append(tag)
        }
        func text(_ tag: UInt8) -> String? {
            guard let v = c.blocks[tag], v.count > 1 else { return nil }
            return String(decoding: v.dropFirst(), as: UTF8.self)
        }
        c.bluetoothName = text(0xA3)
        c.modelName = text(0xA4)
        c.modelNumber = text(0xA5)
        c.protocolBytes = c.blocks[0xA1]
        // C3 (mensagem do relogio) fica no fim: procura "C2 00 C3" e pega os 10 bytes seguintes.
        if msg.count > 13 {
            for k in stride(from: msg.count - 13, through: 2, by: -1)
            where msg[k] == 0xC2 && msg[k + 2] == 0xC3 {
                c.wearableMessage = Array(msg[(k + 3)..<(k + 13)])
                break
            }
        }
        return c
    }

    /// Resposta como o Samsung Health daria: E0 <n> A1 versao, C0 02 (resposta), C1 00 (de: shealth),
    /// A0 01 (sincroniza), C2 02 (para: relogio), A2 versao do S Health, e repete os blocos de
    /// recursos (A9), binning (AE), protocolo (AF), endereco (B1) e mensagem (C3) que a pulseira mandou.
    static func capabilityResponse(to cap: BandCapability) -> [UInt8] {
        var out: [UInt8] = [0xE0]
        var count = 0
        func add(_ tag: UInt8, _ value: [UInt8]) {
            out.append(tag)
            out += value
            count += 1
        }
        add(0xA1, cap.protocolBytes ?? [0x04, 0x33])
        add(0xC0, [0x02])
        add(0xC1, [0x00])
        add(0xA0, [0x01])
        add(0xC2, [0x02])
        add(0xA2, le32(sHealthVersion))
        for tag: UInt8 in [0xA9, 0xAE, 0xAF, 0xB1] {
            if let v = cap.blocks[tag] { add(tag, v) }
        }
        if let w = cap.wearableMessage { add(0xC3, w) }
        out.insert(UInt8(count), at: 1)
        return out
    }

    /// Pedido de capacidade de saude, mandado logo depois da resposta acima.
    static let healthCapabilityRequest: [UInt8] = [0x34]

    /// Confirmacao do SYNC_DATA: 42 02 E0 seq 04 02 01 <resultado> (01 = SUCCESS, 09 = VALIDATION_ERROR).
    static func syncAck(seq: Int, ok: Bool) -> [UInt8] {
        [0x42, 0x02, 0xE0] + le16(seq) + [0x04, 0x02, 0x01, UInt8(ok ? 0x01 : 0x09)]
    }

    /// Pedido de dados (REQUEST_DATA), como o Samsung Health faz ao abrir: 03 E0 seq.
    static func requestData(seq: Int) -> [UInt8] {
        [0x03, 0xE0] + le16(seq)
    }

    /// ACK/NACK de dados grandes: 3E (08|flag) <chunk 4 bytes>.
    static func largeAck(chunks: Int, ok: Bool) -> [UInt8] {
        [0x3E, UInt8(ok ? 0x09 : 0x08)] + le32(UInt32(chunks))
    }
}

/// Juntador de mensagens grandes (msgId 63). Byte1: bits0-1 = 0 primeira, 1 meio, 2 ultima.
struct LargeDataAssembler {
    private var chunks: [[UInt8]] = []

    enum Result {
        case waiting
        case complete(message: [UInt8], ack: [UInt8])
        case failed(nack: [UInt8])
    }

    mutating func feed(_ msg: [UInt8]) -> Result {
        guard msg.count >= 6, let number = HealthProto.read32(msg, 2) else { return .waiting }
        let flag = msg[1] & 0x03
        let body = Array(msg[6...])
        switch flag {
        case 0:
            chunks = [body]
            return .waiting
        case 1:
            if chunks.count == Int(number) {
                chunks.append(body)
                return .waiting
            }
            chunks = []
            return .failed(nack: HealthProto.largeAck(chunks: Int(number), ok: false))
        default:
            if chunks.count == Int(number) && !chunks.isEmpty {
                chunks.append(body)
                let full = chunks.flatMap { $0 }
                let ack = HealthProto.largeAck(chunks: chunks.count, ok: true)
                chunks = []
                return .complete(message: full, ack: ack)
            }
            chunks = []
            return .failed(nack: HealthProto.largeAck(chunks: Int(number), ok: false))
        }
    }

    mutating func reset() { chunks = [] }
}

/// Um registro de passos (tipo 7, PEDO_STEP_COUNT).
struct StepRecord: Codable, Equatable {
    var start: Date?
    var end: Date?
    var steps: Int = 0
    var distance: Float?
    var calories: Float?
}

/// Resumo do dia (tipo 126, ACTIVITY_DAY_SUMMARY).
struct DaySummary: Codable, Equatable {
    var day: Date?
    var steps: Int?
    var calories: Float?
    var distance: Float?
    var goal: Int?
    var activeSeconds: Int?
}

/// Frequencia cardiaca (tipo 0x0A): media do intervalo ou ponto do "binning" de 1 minuto.
struct HeartSample: Codable, Equatable {
    var time: Date
    var bpm: Int
    var min: Int?
    var max: Int?
}

/// Oxigenio no sangue (tipo 0x70).
struct SpO2Sample: Codable, Equatable {
    var time: Date
    var value: Int
    var min: Int?
    var max: Int?
    var heartRate: Int?
}

/// Calorias do dia (tipo 0x17, CALORIES_BURNED).
struct CalorieDay: Codable, Equatable {
    var day: Date?
    var active: Float?
    var rest: Float?
}

/// O que deu para ler de um SYNC_DATA.
struct HealthSyncResult {
    var seq: Int?
    var types: [UInt8] = []
    var steps: [StepRecord] = []
    var days: [DaySummary] = []
    var heart: [HeartSample] = []
    var spo2: [SpO2Sample] = []
    var calories: [CalorieDay] = []
    var stoppedAt: UInt8?
}

/// Leitor do SYNC_DATA. So conhece alguns tipos; ao achar um tipo de tamanho desconhecido para,
/// mas os bytes crus ficam no log para decodificar depois.
enum HealthSyncParser {

    static let typeNames: [UInt8: String] = [
        0x04: "MSG_INFO", 0x05: "DEVICE_INFO", 0x07: "PEDO_STEP_COUNT", 0x08: "PEDO_EVENT",
        0x09: "PEDO_RECOMMENDATION", 0x0A: "HEART_RATE", 0x0B: "USER_PROFILE", 0x0C: "EXERCISE_AUTO",
        0x10: "SLEEP", 0x11: "SLEEP_STAGE", 0x12: "SLEEP_DATA", 0x13: "STRESS", 0x17: "CALORIES_BURNED",
        0x18: "DELETED_DATA", 0x1B: "EXERCISE_MANUAL", 0x1C: "HEIGHT", 0x1D: "WEIGHT", 0x40: "WEARABLE_SETTING", 0x70: "OXYGEN_SATURATION",
        0x7C: "ACTIVE_CALORIES_GOAL", 0x7D: "ACTIVITY_DAILY_GOAL", 0x7E: "ACTIVITY_DAY_SUMMARY",
        0x7F: "CALORIES_BURNED_DETAILS", 0x80: "EXERCISE", 0x89: "SLEEP_COMBINED", 0x8A: "SLEEP_GOAL",
        0x8B: "SLEEP_RAW_DATA", 0xE0: "SEQUENCE_NUMBER",
    ]

    /// Tipos com numero fixo de campos (FrameFieldCount do plugin): [continua]{tag valor} x N.
    static let fieldCountTypes: [UInt8: Int] = [
        0x08: 6, 0x09: 5, 0x0E: 6, 0x0F: 7, 0x11: 8, 0x15: 6, 0x16: 6, 0x17: 7, 0x18: 3, 0x1C: 4, 0x1D: 4,
        0x7C: 5, 0x7D: 5, 0x8A: 8, 0x8C: 8, 0x8D: 7, 0x94: 6, 0x9D: 5, 0x9E: 5, 0x9F: 5, 0xA1: 5,
    ]

    /// Tipos com tamanho em bytes antes de cada registro.
    static let sizedTypes: Set<UInt8> = [0x0A, 0x0C, 0x0D, 0x10, 0x12, 0x13, 0x14, 0x1B]

    static func name(_ t: UInt8) -> String {
        typeNames[t] ?? String(format: "0x%02X", t)
    }

    static func date(_ secs: UInt32) -> Date? {
        guard secs != 0 else { return nil }
        let s = Double(secs)
        return Date(timeIntervalSince1970: s > 1e11 ? s / 1000 : s)
    }

    static func float(_ v: UInt32) -> Float { Float(bitPattern: v) }

    /// `isRequestData` = resposta de REQUEST_DATA (sem byte de contagem, 3 parametros fixos).
    static func parse(_ msg: [UInt8], isRequestData: Bool = false) -> HealthSyncResult {
        var r = HealthSyncResult()
        r.seq = HealthProto.sequence(msg)
        guard msg.count > 2 else { return r }
        var pos = isRequestData ? 1 : 2
        var remaining = isRequestData ? 3 : Int(msg[1])
        while remaining > 0 && pos < msg.count {
            remaining -= 1
            let type = msg[pos]
            pos += 1
            r.types.append(type)
            switch type {
            case 0xE0:
                pos += 2
            case 0x04, 0x05:
                guard pos < msg.count else { return r }
                pos += 1 + Int(msg[pos])
            case 0x07:
                guard let next = parseSteps(msg, pos, into: &r) else { r.stoppedAt = type; return r }
                pos = next
            default:
                if let fields = fieldCountTypes[type] {
                    guard let next = parseFieldList(msg, pos, type: type, fields: fields, into: &r) else {
                        r.stoppedAt = type; return r
                    }
                    pos = next
                } else if sizedTypes.contains(type) || (0x70...0xA6).contains(type) {
                    // [continua 0/1][tamanho 4 bytes][corpo], repetido.
                    guard let next = parseSized(msg, pos, type: type, into: &r) else { r.stoppedAt = type; return r }
                    pos = next
                } else {
                    r.stoppedAt = type
                    return r
                }
            }
        }
        return r
    }

    /// Lista de registros de 12 campos: [continua][tag valor]x12.
    private static func parseSteps(_ b: [UInt8], _ start: Int, into r: inout HealthSyncResult) -> Int? {
        var pos = start
        while pos < b.count {
            let more = b[pos]
            pos += 1
            var rec = StepRecord()
            for _ in 0..<12 {
                guard pos < b.count else { return nil }
                let tag = b[pos]
                pos += 1
                switch tag {
                case 117:
                    pos += 16
                case 23:
                    pos += 1
                case 1, 2, 3, 5, 16, 17, 18, 19, 20, 21, 22, 151:
                    guard let v = HealthProto.read32(b, pos) else { return nil }
                    switch tag {
                    case 1: rec.start = date(v)
                    case 2: rec.end = date(v)
                    case 16: rec.steps = Int(Int32(bitPattern: v))
                    case 17: rec.distance = float(v)
                    case 19: rec.calories = float(v)
                    default: break
                    }
                    pos += 4
                default:
                    return nil
                }
            }
            if pos > b.count { return nil }
            r.steps.append(rec)
            if more == 0 { return pos }
        }
        return nil
    }

    private static func parseSized(_ b: [UInt8], _ start: Int, type: UInt8, into r: inout HealthSyncResult) -> Int? {
        var pos = start
        while pos < b.count {
            let more = b[pos]
            guard let len32 = HealthProto.read32(b, pos + 1) else { return nil }
            let len = Int(len32)
            let bodyStart = pos + 5
            guard len >= 0, bodyStart + len <= b.count else { return nil }
            let body = Array(b[bodyStart..<(bodyStart + len)])
            switch type {
            case 0x7E: r.days.append(parseDaySummary(body))
            case 0x0A: r.heart += parseHeart(body)
            case 0x70: if let s = parseSpO2(body) { r.spo2.append(s) }
            default: break
            }
            pos = bodyStart + len
            if more == 0 { return pos }
        }
        return nil
    }

    /// Lista generica de campos: 117 = uuid (16 bytes), o resto 4 bytes.
    private static func parseFieldList(_ b: [UInt8], _ start: Int, type: UInt8, fields: Int,
                                       into r: inout HealthSyncResult) -> Int? {
        var pos = start
        while pos < b.count {
            let more = b[pos]
            pos += 1
            var cal = CalorieDay()
            for _ in 0..<fields {
                guard pos < b.count else { return nil }
                let tag = b[pos]
                pos += 1
                if tag == 117 { pos += 16; continue }
                guard let v = HealthProto.read32(b, pos) else { return nil }
                pos += 4
                if type == 0x17 {
                    switch tag {
                    case 112: cal.day = date(v)
                    case 113: cal.active = float(v)
                    case 114: cal.rest = float(v)
                    default: break
                    }
                }
            }
            if pos > b.count { return nil }
            if type == 0x17 { r.calories.append(cal) }
            if more == 0 { return pos }
        }
        return nil
    }

    /// Frequencia: 01 inicio, 02 fim, 03/05/97/99 (4B); 20 bpm, 21 min, 22 max, 23 batidas (1B);
    /// 24 binning (tamanho 4B, depois 4B por minuto: minuto, bpm, min, max); 25 tag (2B).
    private static func parseHeart(_ b: [UInt8]) -> [HeartSample] {
        var start: Date?
        var bpm: Int?
        var lo: Int?
        var hi: Int?
        var bins: [HeartSample] = []
        var i = 0
        while i < b.count {
            let tag = b[i]
            i += 1
            switch tag {
            case 32, 33, 34, 35:
                guard i < b.count else { break }
                let v = Int(b[i])
                if tag == 32 { bpm = v } else if tag == 33 { lo = v } else if tag == 34 { hi = v }
                i += 1
            case 37:
                i += 2
            case 36:
                guard let n = HealthProto.read32(b, i) else { return [] }
                i += 4
                let end = min(b.count, i + Int(n))
                var k = i
                while k + 3 < end {
                    if let s = start, b[k + 1] > 0 {
                        bins.append(HeartSample(time: s.addingTimeInterval(Double(b[k]) * 60), bpm: Int(b[k + 1]),
                                                min: Int(b[k + 2]), max: Int(b[k + 3])))
                    }
                    k += 4
                }
                i = end
            default:
                guard let v = HealthProto.read32(b, i) else { i = b.count; break }
                if tag == 1 { start = date(v) }
                i += 4
            }
        }
        if !bins.isEmpty { return bins }
        if let s = start, let v = bpm, v > 0 { return [HeartSample(time: s, bpm: v, min: lo, max: hi)] }
        return []
    }

    /// SpO2: 01 inicio (4B), 75 uuid (16B), A9 spo2, AA bpm, AB min, AC max (1B), AD (2B), AF binning.
    private static func parseSpO2(_ b: [UInt8]) -> SpO2Sample? {
        var start: Date?
        var value: Int?
        var lo: Int?
        var hi: Int?
        var hr: Int?
        var i = 0
        while i < b.count {
            let tag = b[i]
            i += 1
            switch tag {
            case 117:
                i += 16
            case 169, 170, 171, 172:
                guard i < b.count else { break }
                let v = Int(b[i])
                switch tag {
                case 169: value = v
                case 170: hr = v
                case 171: lo = v
                default: hi = v
                }
                i += 1
            case 173:
                i += 2
            case 175:
                guard let n = HealthProto.read32(b, i) else { i = b.count; break }
                i += 4 + Int(n)
            default:
                guard let v = HealthProto.read32(b, i) else { i = b.count; break }
                if tag == 1 { start = date(v) }
                i += 4
            }
        }
        guard let s = start, let v = value, v > 0 else { return nil }
        return SpO2Sample(time: s, value: v, min: lo, max: hi, heartRate: hr)
    }

    /// Campos do resumo do dia: tag + 4 bytes; 117 = uuid (16); 64/65/66 = listas com tamanho.
    private static func parseDaySummary(_ b: [UInt8]) -> DaySummary {
        var d = DaySummary()
        var i = 0
        while i < b.count {
            let tag = b[i]
            i += 1
            if tag == 117 { i += 16; continue }
            guard let v = HealthProto.read32(b, i) else { break }
            i += 4
            switch tag {
            case 44: d.day = date(v)
            case 45: d.activeSeconds = Int(v) / 1000
            case 49: d.steps = Int(Int32(bitPattern: v))
            case 50: d.calories = float(v)
            case 51: d.distance = float(v)
            case 52: d.goal = Int(Int32(bitPattern: v))
            case 64, 65, 66: i += Int(v)
            default: break
            }
        }
        return d
    }
}
