import SwiftUI

/// Widgets da pulseira (canal 0x0F): liga/desliga, reordena e grava.
struct WidgetsView: View {
    @ObservedObject private var band = Fit3Client.shared
    @State private var draft: [BandWidget] = []
    @State private var renaming: BandWidget?
    @State private var newName = ""

    private var active: [BandWidget] { draft.filter { $0.slot != 0xFF }.sorted { $0.slot < $1.slot } }
    private var hidden: [BandWidget] { draft.filter { $0.slot == 0xFF }.sorted { $0.id < $1.id } }
    private var dirty: Bool { Set(draft.map { "\($0.id):\($0.slot)" }) != Set(band.widgets.map { "\($0.id):\($0.slot)" }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("Widgets")).font(EloFont.inter(15, .semibold)).foregroundColor(EloColor.text)
                Spacer()
                Button { band.requestWidgets() } label: {
                    Text(L("Refresh")).font(EloFont.inter(12, .semibold)).foregroundColor(EloColor.accent)
                }
                .disabled(!band.sessionReady)
            }
            Text(L("Choose which widgets show when you swipe on the band, and in what order. Long-press a widget to name it."))
                .font(EloFont.inter(12)).foregroundColor(EloColor.secondary).fixedSize(horizontal: false, vertical: true)

            if draft.isEmpty {
                Text(band.sessionReady ? L("No list yet. Tap Refresh.") : L("Connect the band to load its widgets."))
                    .font(EloFont.inter(13)).foregroundColor(EloColor.tertiary)
            } else {
                Text(L("On the band (%d)", active.count)).font(EloFont.inter(12, .semibold)).foregroundColor(EloColor.secondary)
                ForEach(Array(active.enumerated()), id: \.element.id) { index, w in
                    row(w, position: index + 1, isFirst: index == 0, isLast: index == active.count - 1)
                }
                if !hidden.isEmpty {
                    Text(L("Hidden (%d)", hidden.count)).font(EloFont.inter(12, .semibold)).foregroundColor(EloColor.secondary)
                        .padding(.top, 4)
                    ForEach(hidden) { w in row(w, position: nil, isFirst: true, isLast: true) }
                }
                HStack(spacing: 10) {
                    Button(L("Restore default")) { restoreDefault() }
                        .buttonStyle(EloButtonStyle(filled: false, height: 44, fontSize: 14))
                    Button(L("Save to band")) { band.setWidgets(draft) }
                        .buttonStyle(EloButtonStyle(height: 44, fontSize: 14))
                        .disabled(!band.sessionReady || !dirty)
                }
                .padding(.top, 4)
            }
        }
        .padding(14)
        .card(radius: 16)
        .onAppear { draft = band.widgets }
        .onChange(of: band.widgets) { _, list in draft = list }
        .alert(L("Name this widget"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(L("Name"), text: $newName)
            Button(L("Save")) {
                if let w = renaming { band.renameWidget(w.id, newName) }
                renaming = nil
            }
            Button(L("Cancel"), role: .cancel) { renaming = nil }
        }
    }

    private func row(_ w: BandWidget, position: Int?, isFirst: Bool, isLast: Bool) -> some View {
        HStack(spacing: 10) {
            Text(position.map { "\($0)" } ?? "–")
                .font(EloFont.mono(12)).foregroundColor(EloColor.tertiary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(band.widgetName(w.id)).font(EloFont.inter(14, .medium)).foregroundColor(EloColor.text)
                Text(String(format: "id %02X", w.id)).font(EloFont.mono(10)).foregroundColor(EloColor.tertiary)
            }
            Spacer()
            if position != nil {
                arrow("chevron.up", disabled: isFirst) { move(w, by: -1) }
                arrow("chevron.down", disabled: isLast) { move(w, by: 1) }
            }
            EloToggle(isOn: Binding(get: { w.slot != 0xFF }, set: { setVisible(w, $0) }))
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onLongPressGesture {
            newName = band.widgetName(w.id)
            renaming = w
        }
    }

    private func arrow(_ symbol: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(disabled ? EloColor.tertiary.opacity(0.4) : EloColor.secondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(EloColor.bg))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    /// Renumera os visiveis 1..n na ordem dada.
    private func apply(order: [UInt8]) {
        draft = draft.map { w in
            if let i = order.firstIndex(of: w.id) { return BandWidget(id: w.id, slot: UInt8(i + 1)) }
            return BandWidget(id: w.id, slot: 0xFF)
        }
    }

    private func move(_ w: BandWidget, by delta: Int) {
        var order = active.map { $0.id }
        guard let i = order.firstIndex(of: w.id) else { return }
        let j = i + delta
        guard j >= 0, j < order.count else { return }
        order.swapAt(i, j)
        apply(order: order)
    }

    private func setVisible(_ w: BandWidget, _ on: Bool) {
        var order = active.map { $0.id }
        if on {
            if !order.contains(w.id) { order.append(w.id) }
        } else {
            order.removeAll { $0 == w.id }
        }
        apply(order: order)
    }

    private func restoreDefault() {
        let ids = Set(draft.map { $0.id })
        apply(order: Fit3Client.defaultWidgetOrder.filter { ids.contains($0) })
    }
}
