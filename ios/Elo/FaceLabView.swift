import SwiftUI

/// Mostradores instalados na pulseira (canal 0x06): lista e troca do mostrador atual.
struct FaceLabView: View {
    @ObservedObject private var band = Fit3Client.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("Watch faces")).font(EloFont.inter(15, .semibold)).foregroundColor(EloColor.text)
                Spacer()
                Button {
                    band.requestFaces()
                } label: {
                    Text(L("Refresh")).font(EloFont.inter(12, .semibold)).foregroundColor(EloColor.accent)
                }
                .disabled(!band.sessionReady)
            }
            Text(L("Tap a face to show it on the band."))
                .font(EloFont.inter(12)).foregroundColor(EloColor.secondary)

            if band.bandFaces.isEmpty {
                Text(band.sessionReady ? L("No list yet. Tap Refresh.") : L("Connect the band to load its faces."))
                    .font(EloFont.inter(13)).foregroundColor(EloColor.tertiary)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(band.bandFaces) { face in
                        let current = band.currentFaceId == face.id
                        Button {
                            band.setFace(face)
                        } label: {
                            VStack(spacing: 3) {
                                Text(face.name.isEmpty ? L("Face %d", face.id) : face.name)
                                    .font(EloFont.inter(12, .semibold))
                                    .lineLimit(2).multilineTextAlignment(.center)
                                Text(String(format: "#%d", face.id) + (face.isEditable ? " · ✎" : ""))
                                    .font(EloFont.mono(10))
                                    .foregroundColor(current ? EloColor.bg.opacity(0.7) : EloColor.secondary)
                            }
                            .foregroundColor(current ? EloColor.bg : EloColor.text)
                            .padding(.horizontal, 6)
                            .frame(maxWidth: .infinity, minHeight: 58)
                            .background(RoundedRectangle(cornerRadius: 12).fill(current ? EloColor.accent : EloColor.bg))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(EloColor.borderStrong, lineWidth: current ? 0 : 1))
                        }
                        .buttonStyle(.plain)
                        .disabled(!band.sessionReady)
                    }
                }
                if let max = band.maxFaces {
                    Text(L("%d of %d installed", band.bandFaces.count, max))
                        .font(EloFont.inter(11)).foregroundColor(EloColor.tertiary)
                }
            }
        }
        .padding(14)
        .card(radius: 16)
    }
}
