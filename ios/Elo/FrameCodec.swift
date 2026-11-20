import Foundation

/// Formato de frame do canal SAP do Galaxy Fit3 (mesmo do fit3_frame.py).
///
///     LEN (2, BE) | CRC16(LEN) (2, BE) | PAYLOAD (LEN) | CRC16(PAYLOAD) (2, BE)
///     CRC16 = CRC-16/ARC (poly 0x8005 refletido, init 0, xorout 0)
///     PAYLOAD = DIR 40 CH CH CMD dados...   (DIR: 01 app->pulseira, 00 pulseira->app)
enum FrameCodec {

    static func crc16ARC(_ data: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0
        for byte in data {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                if crc & 1 != 0 {
                    crc = (crc >> 1) ^ 0xA001
                } else {
                    crc = crc >> 1
                }
            }
        }
        return crc
    }

    static func be16(_ value: UInt16) -> [UInt8] {
        return [UInt8(value >> 8), UInt8(value & 0xFF)]
    }

    static func build(_ payload: [UInt8]) -> Data {
        let len = be16(UInt16(payload.count))
        var out: [UInt8] = len
        out += be16(crc16ARC(len))
        out += payload
        out += be16(crc16ARC(payload))
        return Data(out)
    }

    /// Atalho: payload "01 40 CH CH" + dados.
    static func cmd(_ channel: UInt8, _ data: [UInt8]) -> Data {
        var payload: [UInt8] = [0x01, 0x40, channel, channel]
        payload += data
        return build(payload)
    }

    struct Frame {
        let fromBand: Bool
        let channel: UInt8
        let command: UInt8
        let data: [UInt8]
    }

    enum Kind {
        case handshake
        case ack
        case frame(Frame)
        case invalid
    }

    static func parse(_ value: Data) -> Kind {
        let b = [UInt8](value)
        if b.count >= 2 && b[0] == 0x68 && (b[1] == 0x14 || b[1] == 0x15) {
            return .handshake
        }
        guard b.count >= 6 else { return .invalid }
        let len = (Int(b[0]) << 8) | Int(b[1])
        guard b.count == len + 6 else { return .invalid }
        let hdr = (UInt16(b[2]) << 8) | UInt16(b[3])
        guard hdr == crc16ARC(Array(b[0..<2])) else { return .invalid }
        let payload = Array(b[4..<(4 + len)])
        let crc = (UInt16(b[4 + len]) << 8) | UInt16(b[5 + len])
        guard crc == crc16ARC(payload) else { return .invalid }
        if payload.count == 4 && payload[0] == 0x88 {
            return .ack
        }
        guard payload.count >= 5, payload[0] <= 1, payload[2] == payload[3] else { return .invalid }
        let frame = Frame(fromBand: payload[0] == 0,
                          channel: payload[2],
                          command: payload[4],
                          data: Array(payload[5...]))
        return .frame(frame)
    }

    static func hex(_ bytes: [UInt8]) -> String {
        return bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    static func fromHex(_ text: String) -> [UInt8] {
        return text.split(separator: " ").compactMap { UInt8($0, radix: 16) }
    }
}

/// Mensagens do protocolo que ja foram validadas pelo PC (ver PROTOCOLO.md).
enum Fit3Protocol {

    /// Handshake SAP visto no Fit3 Bridge (116 bytes, sem framing).
    static let sessionOpen: [UInt8] = FrameCodec.fromHex(
        "68 15 04 01 00 FF 03 53 41 50 5F 39 37 37 30 30 31 44 45 42 35 35 31 34 30 31 38 41 43 33 41 35 " +
        "31 32 34 42 36 32 33 34 45 31 38 01 01 F4 00 00 03 D4 69 50 68 6F 6E 65 00 00 00 00 00 00 00 00 " +
        "00 00 73 61 6D 73 75 6E 67 00 00 00 00 00 00 00 00 00 73 61 6D 73 75 6E 67 00 00 00 00 00 00 00 " +
        "00 00 02 00 00 00 08 00 00 00 08 00 00 00 03 00 00 00 00 00")

    static let timezoneFrame: [UInt8] = FrameCodec.fromHex(
        "00 27 1A 40 01 40 08 08 4C 27 01 09 01 30 2A 28 1A 68 6F 72 61 20 65 73 74 C3 A1 6E 64 61 72 20 " +
        "64 65 20 42 72 61 73 69 6C 69 61 F3 29")

    static let configFrame: [UInt8] = FrameCodec.fromHex(
        "00 42 31 80 01 40 0A 0A A1 0B A1 04 33 C0 01 C1 00 C2 02 A2 3B E7 6A 00 B1 01 AE 01 04 03 00 AC 03 " +
        "AD 02 01 C3 01 01 03 01 02 05 03 04 10 27 B3 15 03 0D 01 70 17 02 0A 00 03 08 00 0C E9 03 0A FC 03 " +
        "01 01 01 00 A2 89")

    static func timeSync(_ date: Date = Date()) -> Data {
        let ts = Array(String(Int(date.timeIntervalSince1970)).utf8)
        var data: [UInt8] = [0x83, 0x01, 0x53, 0x00, 0x02, 0x00, 0x03, UInt8(ts.count)]
        data += ts
        data += [0x04, 0x01, 0x30, 0x2A, 0x05, 0x00]
        return FrameCodec.cmd(0x01, data)
    }

    /// Sequencia de abertura de sessao, na ordem que funcionou no PC.
    static func sessionSequence() -> [(String, Data)] {
        return [
            (L("Open SAP session"), Data(sessionOpen)),
            ("Setup 1", FrameCodec.build(FrameCodec.fromHex("01 40 01 01 01 04 02 05 00 0E"))),
            ("Setup 2", FrameCodec.build(FrameCodec.fromHex("01 40 01 01 02 01 01"))),
            (L("Sync time"), timeSync()),
            (L("Time zone"), Data(timezoneFrame)),
            (L("Settings"), Data(configFrame)),
            (L("Request: battery"), FrameCodec.cmd(0x0B, [0x02])),
            ("07/0D", FrameCodec.cmd(0x07, [0x0D])),
            ("07/0E", FrameCodec.cmd(0x07, [0x0E])),
            (L("Finish setup"), FrameCodec.build(FrameCodec.fromHex("01 40 01 01 84 01"))),
        ]
    }

    static let findOn = FrameCodec.cmd(0x1F, [0x0D])
    static let findOff = FrameCodec.cmd(0x1F, [0x0F])

    static func language(_ id: UInt8) -> Data {
        return FrameCodec.cmd(0x0B, [0x01, 0x04, id, 0x00])
    }

    /// Notificacao no formato do canal 07 / cmd 80.
    static func notification(from sender: String, text: String, app: String, id: Int) -> Data {
        let nid = Array(String(format: "%05d", id % 100000).utf8)
        let title = Array(sender.utf8.prefix(60))
        let body = Array(text.utf8.prefix(400))
        let appName = Array(app.utf8.prefix(40))

        var ms = UInt64(Date().timeIntervalSince1970 * 1000)
        var tsBytes: [UInt8] = []
        for _ in 0..<8 {
            tsBytes.append(UInt8(ms & 0xFF))
            ms >>= 8
        }

        var data: [UInt8] = [0x80, 0x0B, 0x00, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x06, 0x05]
        data += nid
        data += [0x02]
        data += tsBytes
        data += [0x03, UInt8(title.count)]
        data += title
        data += [0x04, UInt8(body.count & 0xFF), UInt8(body.count >> 8)]
        data += body
        data += [0x0E, UInt8(appName.count)]
        data += appName
        data += [0x0F, 0x01, 0x10, 0x00, 0x09, 0x0E]
        data += Array("APP_ICON_".utf8)
        data += nid
        data += [0x13, 0x01]
        return FrameCodec.cmd(0x07, data)
    }

    /// Leitura do perfil padrao de frequencia cardiaca (0x2A37).
    static func heartRate(_ value: Data) -> (bpm: Int, contact: Bool)? {
        let b = [UInt8](value)
        guard b.count >= 2 else { return nil }
        let flags = b[0]
        let bpm: Int
        if flags & 0x01 != 0 && b.count >= 3 {
            bpm = Int(b[1]) | (Int(b[2]) << 8)
        } else {
            bpm = Int(b[1])
        }
        return (bpm, flags & 0x02 != 0)
    }
}
