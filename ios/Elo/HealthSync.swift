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

/// O que deu para ler de um SYNC_DATA.
struct HealthSyncResult {
    var seq: Int?
    var types: [UInt8] = []
    var steps: [StepRecord] = []
    var days: [DaySummary] = []
    var stoppedAt: UInt8?
}

/// Leitor do SYNC_DATA. So conhece alguns tipos; ao achar um tipo de tamanho desconhecido para,
/// mas os bytes crus ficam no log para decodificar depois.
enum HealthSyncParser {

    static let typeNames: [UInt8: String] = [
        0x04: "MSG_INFO", 0x05: "DEVICE_INFO", 0x07: "PEDO_STEP_COUNT", 0x08: "PEDO_EVENT",
        0x09: "PEDO_RECOMMENDATION", 0x0A: "HEART_RATE", 0x0B: "USER_PROFILE", 0x0C: "EXERCISE_AUTO",
        0x10: "SLEEP", 0x11: "SLEEP_STAGE", 0x12: "SLEEP_DATA", 0x13: "STRESS", 0x17: "CALORIES_BURNED",
        0x18: "DELETED_DATA", 0x40: "WEARABLE_SETTING", 0x70: "OXYGEN_SATURATION",
        0x7C: "ACTIVE_CALORIES_GOAL", 0x7D: "ACTIVITY_DAILY_GOAL", 0x7E: "ACTIVITY_DAY_SUMMARY",
        0x7F: "CALORIES_BURNED_DETAILS", 0x80: "EXERCISE", 0x89: "SLEEP_COMBINED", 0x8A: "SLEEP_GOAL",
        0x8B: "SLEEP_RAW_DATA", 0xE0: "SEQUENCE_NUMBER",
    ]

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
            case 0x70...0xBF:
                // Tipos novos: [continua 0/1][tamanho 4 bytes][corpo], repetido.
                guard let next = parseSized(msg, pos, type: type, into: &r) else { r.stoppedAt = type; return r }
                pos = next
            default:
                r.stoppedAt = type
                return r
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
            if type == 0x7E {
                r.days.append(parseDaySummary(Array(b[bodyStart..<(bodyStart + len)])))
            }
            pos = bodyStart + len
            if more == 0 { return pos }
        }
        return nil
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
