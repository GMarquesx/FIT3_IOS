import SwiftUI

/// Tela "Sua Galaxy Fit3" (Pulseira.dc.html): modelo 3D girando com o dedo e personalizacao.
struct BandCustomizeView: View {
    let onBack: () -> Void

    @ObservedObject private var band = Fit3Client.shared
    @State private var current = BandAppearance.load()
    @State private var applied = BandAppearance.load()
    @State private var rot: CGFloat = -26
    @State private var dragStart: CGFloat?

    private var dirty: Bool { current != applied }
    private var accent: Color { BandAppearance.accentColor(current.accent) }

    var body: some View {
        EloScreen(top: 48, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                BackLink(title: L("Today"), action: onBack)
                Text(L("Your Galaxy Fit3")).font(EloFont.grotesk(30)).tracking(-0.5).foregroundColor(EloColor.text)
            }
            viewer
            backgrounds
            Segmented(options: BandAppearance.faces.map { ($0, BandAppearance.faceName($0)) },
                      selection: $current.face)
            VStack(spacing: 4) {
                swatchRow(L("Accent"), BandAppearance.accents, selected: current.accent, ring: true) { id in
                    current.accent = id
                } color: { BandAppearance.accentColor($0) }
                swatchRow(L("Strap"), BandAppearance.straps, selected: current.strap, ring: true, bordered: true) { id in
                    current.strap = id
                } color: { BandAppearance.strapColors($0).main }
            }
            Button(dirty ? L("Apply") : L("Applied")) {
                if dirty {
                    applied = current
                    current.save()
                }
            }
            .buttonStyle(EloButtonStyle(filled: dirty))
        }
    }

    private var viewer: some View {
        GeometryReader { geo in
            TimelineView(.periodic(from: .now, by: 15)) { context in
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 20, style: .continuous).fill(EloColor.cardAlt)

                    BandShadow(width: 150, height: 20)
                        .position(x: geo.size.width / 2, y: geo.size.height - 26 - 10)

                    BandModel3D(size: geo.size, appearance: current, rotY: rot, detailed: true,
                                screen: .clock, now: context.date,
                                bpm: band.hrContact ? band.bpm.map { "\($0)" } ?? "—" : "—")

                    Text(dirty ? L("Preview · not applied")
                               : L("Applied · %@ · %@", BandAppearance.backgroundName(applied.bg),
                                   BandAppearance.faceName(applied.face)))
                        .font(EloFont.inter(11, .semibold))
                        .foregroundColor(dirty ? EloColor.warn : EloColor.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(dirty ? Color(hex: 0x2A2113) : EloColor.bg.opacity(0.85)))
                        .padding(12)

                    Text(L("Drag to rotate"))
                        .font(EloFont.inter(11))
                        .foregroundColor(EloColor.tertiary)
                        .padding(12)
                        .frame(maxHeight: .infinity, alignment: .bottom)

                    HStack(spacing: 6) {
                        Button { withAnimation(.easeOut(duration: 0.25)) { rot -= 45 } } label: {
                            RoundIconButton(icon: Icons.rotateLeft)
                        }
                        .accessibilityLabel(L("Rotate left"))
                        Button { withAnimation(.easeOut(duration: 0.25)) { rot += 45 } } label: {
                            RoundIconButton(icon: Icons.rotateRight)
                        }
                        .accessibilityLabel(L("Rotate right"))
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(EloColor.border, lineWidth: 1))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if dragStart == nil { dragStart = rot }
                            rot = (dragStart ?? rot) + value.translation.width * 0.7
                        }
                        .onEnded { _ in dragStart = nil }
                )
            }
        }
        .frame(height: 272)
        .accessibilityLabel(L("3D model of the band with the watch face preview. Drag to rotate."))
    }

    private var backgrounds: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Background")).font(EloFont.inter(12, .medium)).foregroundColor(EloColor.secondary)
            HStack(spacing: 8) {
                ForEach(BandAppearance.backgrounds, id: \.self) { id in
                    let active = id == current.bg
                    Button {
                        current.bg = id
                    } label: {
                        ZStack(alignment: .bottom) {
                            ScreenBackground(id: id, accent: accent)
                            Text(BandAppearance.backgroundName(id))
                                .font(EloFont.inter(11, .semibold))
                                .foregroundColor(EloColor.text)
                                .padding(.bottom, 5)
                        }
                        .frame(maxWidth: .infinity, minHeight: 56, maxHeight: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .stroke(active ? accent : EloColor.borderStrong, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(active ? .isSelected : [])
                }
            }
        }
    }

    private func swatchRow(_ title: String, _ ids: [String], selected: String, ring: Bool, bordered: Bool = false,
                           pick: @escaping (String) -> Void, color: @escaping (String) -> Color) -> some View {
        HStack {
            Text(title).font(EloFont.inter(12, .medium)).foregroundColor(EloColor.secondary)
            Spacer()
            HStack(spacing: 4) {
                ForEach(ids, id: \.self) { id in
                    Button {
                        pick(id)
                    } label: {
                        ZStack {
                            Circle().stroke(id == selected ? EloColor.text : Color.clear, lineWidth: 2)
                            Circle().fill(color(id)).frame(width: 28, height: 28)
                                .overlay(Circle().stroke(bordered ? Color(hex: 0x3A404A) : Color.clear, lineWidth: 1))
                        }
                        .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(id == selected ? .isSelected : [])
                }
            }
        }
    }
}
