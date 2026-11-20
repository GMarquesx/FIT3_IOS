import SwiftUI

/// Laboratorio para descobrir o comando que troca o mostrador (canal 0x0F).
struct FaceLabView: View {
    @ObservedObject private var band = Fit3Client.shared
    @State private var selected: UInt8?
    @State private var attempt = 0
    @State private var sent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("Watch faces")).font(EloFont.inter(15, .semibold)).foregroundColor(EloColor.text)
                Spacer()
                Text(L("Experimental"))
                    .font(EloFont.inter(11, .semibold)).foregroundColor(EloColor.warn)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(EloColor.warnBg))
            }
            Text(L("The band sends this list when it connects (channel 0x0F). Pick a face that is NOT the current one, send each attempt and tell me if the band changed."))
                .font(EloFont.inter(12)).foregroundColor(EloColor.secondary).fixedSize(horizontal: false, vertical: true)

            if band.watchFaces.isEmpty {
                Text(L("No list yet. Disconnect and connect again to receive it."))
                    .font(EloFont.inter(13)).foregroundColor(EloColor.tertiary)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                    ForEach(band.watchFaces) { face in
                        let active = selected == face.id
                        Button {
                            selected = face.id
                            attempt = 0
                            sent = false
                        } label: {
                            VStack(spacing: 2) {
                                Text(String(format: "%02X", face.id)).font(EloFont.mono(15, .medium))
                                Text(face.slot == 0xFF ? L("off") : "#\(face.slot)").font(EloFont.inter(10))
                                    .foregroundColor(active ? EloColor.bg : EloColor.secondary)
                            }
                            .foregroundColor(active ? EloColor.bg : EloColor.text)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(RoundedRectangle(cornerRadius: 10).fill(active ? EloColor.accent : EloColor.bg))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(face.slot == 0xFF ? EloColor.border : EloColor.borderStrong, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let id = selected {
                let attempts = band.faceAttempts(for: id)
                let label = attempt < attempts.count ? attempts[attempt].0 : "—"
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Face %@ · attempt %d of %d", String(format: "%02X", id), min(attempt + 1, attempts.count), attempts.count))
                        .font(EloFont.inter(13, .semibold)).foregroundColor(EloColor.text)
                    Text(label).font(EloFont.mono(12)).foregroundColor(EloColor.accent)
                    if attempt < attempts.count {
                        if !sent {
                            Button(L("Send attempt")) {
                                band.tryFace(id, attempt: attempt)
                                sent = true
                            }
                            .buttonStyle(EloButtonStyle(height: 44, fontSize: 15))
                            .disabled(!band.sessionReady)
                        } else {
                            HStack(spacing: 10) {
                                Button(L("It changed!")) {
                                    band.noteFaceResult(String(format: "face %02X CHANGED with try %d (", id, attempt + 1) + label + ")")
                                    sent = false
                                }
                                .buttonStyle(EloButtonStyle(height: 44, fontSize: 15))
                                Button(L("Nothing · next")) {
                                    band.noteFaceResult(String(format: "face %02X no change with try %d (", id, attempt + 1) + label + ")")
                                    attempt += 1
                                    sent = false
                                }
                                .buttonStyle(EloButtonStyle(filled: false, height: 44, fontSize: 15))
                            }
                        }
                    } else {
                        Text(L("No attempt worked. Export the .jsonl and send it to me."))
                            .font(EloFont.inter(12)).foregroundColor(EloColor.warn)
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(EloColor.bg))
            }

            ForEach(Array(band.faceLabLog.prefix(8).enumerated()), id: \.offset) { item in
                Text(item.element).font(EloFont.mono(10)).foregroundColor(EloColor.secondary)
            }
        }
        .padding(14)
        .card(radius: 16)
    }
}
