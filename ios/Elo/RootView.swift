import SwiftUI

enum EloTab: Int, CaseIterable {
    case today, health, workout, alerts, console

    var title: String {
        switch self {
        case .today: return L("Today")
        case .health: return L("Health")
        case .workout: return L("Workout")
        case .alerts: return L("Alerts")
        case .console: return L("Console")
        }
    }

    var icon: [String] {
        switch self {
        case .today: return Icons.today
        case .health: return Icons.heart
        case .workout: return Icons.workout
        case .alerts: return Icons.bell
        case .console: return Icons.console
        }
    }
}

enum TodayRoute: Hashable {
    case profile
    case band
}

struct RootView: View {
    @ObservedObject private var band = Fit3Client.shared
    @State private var tab: EloTab = .today
    @State private var todayPath = NavigationPath()

    var body: some View {
        ZStack(alignment: .bottom) {
            EloColor.bg.ignoresSafeArea()

            Group {
                switch tab {
                case .today:
                    NavigationStack(path: $todayPath) {
                        TodayView()
                            .navigationDestination(for: TodayRoute.self) { route in
                                switch route {
                                case .profile: ProfileView(onBack: { popToday() })
                                case .band: BandCustomizeView(onBack: { popToday() })
                                }
                            }
                    }
                case .health:
                    HealthView()
                case .workout:
                    WorkoutView()
                case .alerts:
                    AlertsView()
                case .console:
                    ConsoleView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            BottomNav(tab: tab) { picked in
                if picked == .today && tab == .today {
                    todayPath = NavigationPath()
                }
                tab = picked
            }
        }
        .preferredColorScheme(.dark)
        .tint(EloColor.accent)
        .onAppear {
            band.connect()
        }
    }

    private func popToday() {
        if !todayPath.isEmpty {
            todayPath.removeLast()
        }
    }
}

/// Barra inferior do design: 84 px, fundo #12161C, borda superior, 5 itens.
struct BottomNav: View {
    let tab: EloTab
    let onPick: (EloTab) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(EloColor.border).frame(height: 1)
            HStack(spacing: 0) {
                ForEach(EloTab.allCases, id: \.rawValue) { item in
                    let active = item == tab
                    Button {
                        onPick(item)
                    } label: {
                        VStack(spacing: 3) {
                            EloIcon(paths: item.icon, size: 24, lineWidth: 1.8,
                                    color: active ? EloColor.accent : EloColor.tertiary)
                            Text(item.title)
                                .font(EloFont.inter(11, active ? .semibold : .medium))
                                .foregroundColor(active ? EloColor.accent : EloColor.tertiary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(active ? .isSelected : [])
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .frame(height: 84)
        .background(EloColor.cardAlt)
        .ignoresSafeArea(edges: .bottom)
    }
}

/// Link "‹ Hoje" das telas internas.
struct BackLink: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                EloIcon(paths: Icons.chevronLeft, size: 18, lineWidth: 2.2, color: EloColor.accent)
                Text(title).font(EloFont.inter(15, .medium)).foregroundColor(EloColor.accent)
            }
            .frame(minHeight: 32)
        }
        .buttonStyle(.plain)
    }
}

/// Botao redondo de 44 px do cabecalho.
struct RoundIconButton: View {
    let icon: [String]
    var color: Color = EloColor.text

    var body: some View {
        ZStack {
            Circle().fill(EloColor.card)
            Circle().stroke(EloColor.borderStrong, lineWidth: 1)
            EloIcon(paths: icon, size: 20, lineWidth: 2, color: color)
        }
        .frame(width: 44, height: 44)
    }
}

/// Moldura das telas: rolagem, margens do design e espaco para a barra inferior.
struct EloScreen<Content: View>: View {
    var top: CGFloat = 56
    var spacing: CGFloat = 12
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: spacing) {
                content()
            }
            .padding(.top, top - 47)
            .padding(.horizontal, 20)
            .padding(.bottom, 100)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(EloColor.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }
}

enum EloFormat {
    static func number(_ value: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func relative(_ date: Date?) -> String {
        guard let date = date else { return "—" }
        if Date().timeIntervalSince(date) < 45 { return L("just now") }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    /// "Quinta, 19 de novembro" / "Thursday, November 19".
    static func header(_ date: Date) -> String {
        let f = DateFormatter()
        if isPortuguese {
            f.locale = Locale(identifier: "pt_BR")
            f.dateFormat = "EEEE, d 'de' MMMM"
            var s = f.string(from: date).replacingOccurrences(of: "-feira", with: "")
            s = s.prefix(1).uppercased() + s.dropFirst()
            return s
        }
        f.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
        return f.string(from: date)
    }

    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        return f.string(from: date)
    }
}
