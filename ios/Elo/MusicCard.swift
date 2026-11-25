import SwiftUI
import MediaPlayer

/// Cartao "Musica na pulseira": o que esta tocando no Apple Music e o estado da ponte.
struct MusicCard: View {
    @ObservedObject private var music = MusicBridge.shared
    @State private var status = MPMediaLibrary.authorizationStatus()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Music on the band")).font(EloFont.inter(15, .medium)).foregroundColor(EloColor.text)
                    Text(L("Song, play/pause and skip from the band's music screen"))
                        .font(EloFont.inter(12)).foregroundColor(EloColor.secondary)
                }
                Spacer(minLength: 0)
                EloToggle(isOn: Binding(get: { music.enabled }, set: { music.enabled = $0 }))
            }

            if status != .authorized {
                Button(L("Allow Apple Music access")) {
                    MPMediaLibrary.requestAuthorization { s in
                        DispatchQueue.main.async {
                            status = s
                            music.refresh(push: true)
                        }
                    }
                }
                .buttonStyle(EloButtonStyle(filled: false, height: 42, fontSize: 14))
            }

            HStack(spacing: 10) {
                Image(systemName: music.playing ? "play.fill" : "pause.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(music.playing ? EloColor.accent : EloColor.secondary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(EloColor.bg))
                VStack(alignment: .leading, spacing: 1) {
                    Text(music.title.isEmpty ? L("Nothing playing") : music.title)
                        .font(EloFont.inter(14, .medium)).foregroundColor(EloColor.text).lineLimit(1)
                    Text(music.bandListening ? L("Band music screen connected") + (music.artist.isEmpty ? "" : " · " + music.artist)
                                             : L("Open the music widget on the band"))
                        .font(EloFont.inter(12)).foregroundColor(EloColor.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            Text(L("Works with the Music app (Apple Music). iOS doesn't let other apps control Spotify or YouTube Music."))
                .font(EloFont.inter(11)).foregroundColor(EloColor.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .card(radius: 16)
        .onAppear {
            status = MPMediaLibrary.authorizationStatus()
            music.startObserving()
        }
    }
}
