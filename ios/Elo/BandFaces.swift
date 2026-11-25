import Foundation

/// Mostrador instalado (servico "WatchfaceSerevice", canal SAP 0x06).
struct BandFace: Identifiable, Equatable, Codable {
    var id: Int
    var samplerId: UInt8 = 0
    var name: String = ""
    var version: String = ""
    var isCurrent = false
    var isEditable = false
    var position: Int?
}

/// Mensagens do canal 0x06. Byte0 = tipo (0x40 = resposta) | comando (6 bits); depois pares
/// parametro + valor (1 byte), ou parametro + tamanho + bytes para textos.
enum BandFaceProto {

    enum Command: UInt8 {
        case getAllInfo = 0, getList = 1, getCurrent = 2, setCurrent = 3, install = 4, delete = 5
        case getEditInfo = 6, setEditInfo = 7, cancelEdit = 8, getOrder = 9, setOrder = 10
        case addImages = 11, deleteImages = 12, getImages = 14
    }

    enum Param {
        static let currentId: UInt8 = 0
        static let maxCount: UInt8 = 1
        static let count: UInt8 = 2
        static let list: UInt8 = 3
        static let wfId: UInt8 = 4
        static let version: UInt8 = 5
        static let name: UInt8 = 6
        static let description: UInt8 = 7
        static let styleId: UInt8 = 8
        static let positionIndex: UInt8 = 9
        static let styleIndex: UInt8 = 10
        static let isCurrent: UInt8 = 11
        static let isEditable: UInt8 = 12
        static let widgetIndex: UInt8 = 17
        static let background: UInt8 = 19
        static let numParams: UInt8 = 24
        static let samplerId: UInt8 = 29
    }

    static let getAllInfo: [UInt8] = [Command.getAllInfo.rawValue]
    static let getCurrent: [UInt8] = [Command.getCurrent.rawValue]

    static func setCurrent(id: Int, sampler: UInt8) -> [UInt8] {
        [Command.setCurrent.rawValue, Param.wfId, UInt8(id & 0xFF), Param.samplerId, sampler]
    }

    struct AllInfo {
        var currentId: Int?
        var maxCount: Int?
        var faces: [BandFace] = []
    }

    /// Resposta do GET_ALL_INFO: 40 00 <atual> 01 <max> 02 <qtd> 03 <qtd lista> {18 n params...}.
    static func parseAllInfo(_ msg: [UInt8]) -> AllInfo {
        var info = AllInfo()
        guard msg.count >= 9 else { return info }
        if msg[1] == Param.currentId { info.currentId = Int(msg[2]) }
        if msg[3] == Param.maxCount { info.maxCount = Int(msg[4]) }
        guard msg[7] == Param.list else { return info }
        let size = Int(msg[8])
        var i = 9
        for _ in 0..<size {
            guard i + 1 < msg.count, msg[i] == Param.numParams else { break }
            var n = Int(msg[i + 1])
            i += 2
            var face = BandFace(id: -1)
            while n > 0 && i < msg.count {
                n -= 1
                let p = msg[i]
                i += 1
                switch p {
                case Param.version, Param.name, Param.description, Param.background:
                    guard i < msg.count else { break }
                    let len = Int(msg[i])
                    let end = min(msg.count, i + 1 + len)
                    let text = String(decoding: msg[(i + 1)..<end], as: UTF8.self)
                    if p == Param.name { face.name = text }
                    if p == Param.version { face.version = text }
                    i = end
                case Param.widgetIndex:
                    guard i < msg.count else { break }
                    i += 1 + Int(msg[i])
                default:
                    guard i < msg.count else { break }
                    let v = msg[i]
                    i += 1
                    switch p {
                    case Param.wfId: face.id = Int(v)
                    case Param.styleId: face.samplerId = v
                    case Param.isCurrent: face.isCurrent = v == 1
                    case Param.isEditable: face.isEditable = v == 1
                    case Param.positionIndex: face.position = Int(v)
                    default: break
                    }
                }
            }
            if face.id >= 0 { info.faces.append(face) }
        }
        if let cur = info.currentId {
            for k in info.faces.indices where info.faces[k].id == cur { info.faces[k].isCurrent = true }
        }
        return info
    }

    /// Resposta do SET/GET_CURRENT: 4x 04 <id> 1D <sampler>.
    static func parseCurrent(_ msg: [UInt8]) -> Int? {
        guard msg.count >= 3, msg[1] == Param.wfId else { return nil }
        return Int(msg[2])
    }
}
