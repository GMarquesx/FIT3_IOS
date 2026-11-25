import Foundation
import MediaPlayer
import AVFoundation

/// Controle de musica pela pulseira (servico "music", canal SAP 0x09), usando o app Musica (Apple Music).
///
/// Formato do plugin oficial (SMediaMessageContracts): byte0 = formato(0x80) | resposta(0x40) | msgId;
/// formato 1 traz o numero de parametros no byte 1. Texto = id + tamanho (1 byte) + UTF-8. Inteiros LE.
///
/// Pulseira -> celular: 01 quer atualizacoes, 02 metadados, 03 estado, 04 botao (01 tecla, 02 acao),
/// 05 capacidade, 06 volume, 07 controle de volume, 08 info do app, 09 fila.
/// Celular -> pulseira: 17 metadados, 18 estado, 20 capacidade, 21 volume, 22 info do app, 23 resposta do 01, 32 fila.
final class MusicBridge: NSObject, ObservableObject {

    static let shared = MusicBridge()

    static let appId = "com.apple.Music"
    static let appTitle = "Apple Music"
    static let maxVolume: Int32 = 15

    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var playing = false
    @Published private(set) var bandListening = false
    @Published private(set) var lastCommand: String?

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "music.enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "music.enabled"); objectWillChange.send() }
    }

    private let player = MPMusicPlayerController.systemMusicPlayer
    private var observing = false
    private var lastKey: (key: UInt8, at: Date)?
    private var lastSentSignature = ""

    /// Envia uma mensagem no canal 0x09 (definido pelo Fit3Client).
    var send: ((String, [UInt8]) -> Void)?

    // MARK: Permissao e observadores

    func requestAccess() {
        if MPMediaLibrary.authorizationStatus() == .notDetermined {
            MPMediaLibrary.requestAuthorization { _ in
                DispatchQueue.main.async { self.refresh(push: true) }
            }
        }
    }

    func startObserving() {
        guard !observing else { return }
        observing = true
        player.beginGeneratingPlaybackNotifications()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(changed),
                       name: .MPMusicPlayerControllerNowPlayingItemDidChange, object: player)
        nc.addObserver(self, selector: #selector(changed),
                       name: .MPMusicPlayerControllerPlaybackStateDidChange, object: player)
        refresh(push: false)
    }

    @objc private func changed() {
        DispatchQueue.main.async { self.refresh(push: true) }
    }

    /// Le o que esta tocando; se mudou e a pulseira pediu atualizacoes, manda.
    func refresh(push: Bool) {
        let item = player.nowPlayingItem
        title = item?.title ?? ""
        artist = item?.artist ?? item?.albumArtist ?? ""
        playing = player.playbackState == .playing
        let sig = "\(title)|\(artist)|\(playing)"
        if push && bandListening && enabled && sig != lastSentSignature {
            lastSentSignature = sig
            sendMetadata()
            sendState()
        }
    }

    func bandDisconnected() {
        bandListening = false
        lastSentSignature = ""
    }

    // MARK: Mensagens recebidas

    /// Trata uma mensagem do canal 0x09 e devolve o rotulo para o console.
    func handle(_ msg: [UInt8]) -> String {
        guard let first = msg.first else { return "09" }
        let id = first & 0x3F
        guard enabled else { return String(format: "09/%02X", first) }
        switch id {
        case 1:
            let wanted = param(msg, 1) ?? 1
            bandListening = wanted != 0
            out(L("Music: updates"), [0x40 | 23, 0x01, 0x01, UInt8(wanted == 0 ? 0 : 1)])
            if bandListening {
                startObserving()
                refresh(push: false)
                lastSentSignature = "\(title)|\(artist)|\(playing)"
                sendMetadata()
                sendState()
            }
            return L("Music: band wants updates (%d)", Int(wanted))
        case 2:
            refresh(push: false)
            sendMetadata()
            return L("Music: metadata request")
        case 3:
            refresh(push: false)
            sendState()
            return L("Music: state request")
        case 4:
            let key = param(msg, 1) ?? 0
            let action = param(msg, 2) ?? 0
            press(key: key, action: action)
            return L("Music: button %@", keyName(key) + (action == 2 ? " ↓" : " ↑"))
        case 5:
            out(L("Music: capability"), [0x40 | 20, 0x02, 0x01] + le32(MusicBridge.maxVolume) + [0x02] + le32(10))
            return L("Music: capability request")
        case 6:
            sendVolume()
            return L("Music: volume request")
        case 7:
            let action = param(msg, 1) ?? 0
            lastCommand = "volume \(action)"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.sendVolume() }
            return L("Music: volume control (%d)", Int(action))
        case 8:
            let appId = Array(MusicBridge.appId.utf8)
            let title = Array(MusicBridge.appTitle.utf8)
            out(L("Music: app info"), [0x80 | 0x40 | 22, 0x03, 0x01, UInt8(appId.count)] + appId
                + [0x02, UInt8(title.count)] + title + [0x03, 0x00])
            return L("Music: app info request")
        case 9:
            let appId = Array(MusicBridge.appId.utf8)
            out(L("Music: queue"), [0x80 | 0x40 | 32, 0x03, 0x01, UInt8(appId.count)] + appId + [0x02, 0x00, 0x03] + le32(0))
            return L("Music: queue request")
        default:
            return String(format: "09/%02X", first)
        }
    }

    // MARK: Botoes

    /// Tecla: 1 parar, 2 play/pause, 3 anterior, 4 proxima. Acao: 2 apertou, 1 soltou.
    /// O plugin repassa as duas; aqui age na primeira e ignora a repeticao da mesma tecla.
    private func press(key: UInt8, action: UInt8) {
        if let last = lastKey, last.key == key, Date().timeIntervalSince(last.at) < 0.8 { return }
        lastKey = (key, Date())
        DispatchQueue.main.async {
            switch key {
            case 1: self.player.stop()
            case 2:
                if self.player.playbackState == .playing { self.player.pause() } else { self.player.play() }
            case 3: self.player.skipToPreviousItem()
            case 4: self.player.skipToNextItem()
            default: return
            }
            self.lastCommand = self.keyName(key)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.refresh(push: false)
                self.lastSentSignature = "\(self.title)|\(self.artist)|\(self.playing)"
                self.sendMetadata()
                self.sendState()
            }
        }
    }

    private func keyName(_ key: UInt8) -> String {
        switch key {
        case 1: return "stop"
        case 2: return "play/pause"
        case 3: return "previous"
        case 4: return "next"
        default: return "\(key)"
        }
    }

    // MARK: Mensagens enviadas

    private func sendMetadata() {
        let item = player.nowPlayingItem
        let durationMs = Int64(((item?.playbackDuration ?? 0) * 1000).rounded())
        out(L("Music: now playing"),
            [0x80 | 0x40 | 17, 0x05, 0x01] + le64(durationMs)
            + text(0x02, title) + text(0x03, artist) + text(0x04, "") + text(0x05, MusicBridge.appId))
    }

    private func sendState() {
        let positionMs = Int64((player.currentPlaybackTime.isFinite ? player.currentPlaybackTime : 0) * 1000)
        let state: UInt8 = player.playbackState == .playing ? 3 : 2
        out(L("Music: state"),
            [0x80 | 0x40 | 18, 0x04, 0x01, state, 0x02] + le64(positionMs) + [0x04] + le64(0)
            + text(0x03, MusicBridge.appId))
    }

    private func sendVolume() {
        let vol = Int32((AVAudioSession.sharedInstance().outputVolume * Float(MusicBridge.maxVolume)).rounded())
        out(L("Music: volume"), [0x40 | 21, 0x02, 0x01] + le32(vol) + [0x02, 0x01])
    }

    private func out(_ label: String, _ msg: [UInt8]) {
        send?(label, msg)
    }

    // MARK: Bytes

    /// Valor de 1 byte do parametro `id` (procura id e pega o byte seguinte).
    private func param(_ msg: [UInt8], _ id: UInt8) -> UInt8? {
        var i = (msg.first ?? 0) & 0x80 != 0 ? 2 : 1
        while i + 1 < msg.count {
            if msg[i] == id { return msg[i + 1] }
            i += 2
        }
        return nil
    }

    /// Ate 99 caracteres (como o plugin) e no maximo 255 bytes.
    private func text(_ id: UInt8, _ s: String) -> [UInt8] {
        var str = String(s.prefix(99))
        while str.utf8.count > 255 { str.removeLast() }
        let b = Array(str.utf8)
        return [id, UInt8(b.count)] + b
    }

    private func le32(_ v: Int32) -> [UInt8] {
        let u = UInt32(bitPattern: v)
        return (0..<4).map { UInt8((u >> (8 * $0)) & 0xFF) }
    }

    private func le64(_ v: Int64) -> [UInt8] {
        let u = UInt64(bitPattern: v)
        return (0..<8).map { UInt8((u >> (8 * UInt64($0))) & 0xFF) }
    }
}
