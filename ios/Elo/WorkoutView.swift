import CoreLocation
import SwiftUI

/// Corrida com o GPS do iPhone: tempo, distancia, ritmo e percurso.
final class WorkoutTracker: NSObject, ObservableObject, CLLocationManagerDelegate {

    enum RunState { case idle, running, paused }

    @Published var state: RunState = .idle
    @Published var distance: Double = 0          // metros
    @Published var route: [CLLocationCoordinate2D] = []
    @Published var accuracy: Double?
    @Published var denied = false

    private let manager = CLLocationManager()
    private var lastLocation: CLLocation?
    private var startDate: Date?
    private var accumulated: TimeInterval = 0

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .fitness
        manager.distanceFilter = 3
    }

    func elapsed(at now: Date = Date()) -> TimeInterval {
        if let s = startDate { return accumulated + now.timeIntervalSince(s) }
        return accumulated
    }

    func start() {
        distance = 0
        route = []
        accumulated = 0
        lastLocation = nil
        startDate = Date()
        state = .running
        manager.requestWhenInUseAuthorization()
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
    }

    func togglePause() {
        switch state {
        case .running:
            accumulated = elapsed()
            startDate = nil
            state = .paused
            manager.stopUpdatingLocation()
        case .paused:
            startDate = Date()
            lastLocation = nil
            state = .running
            manager.startUpdatingLocation()
        case .idle:
            break
        }
    }

    func finish() {
        accumulated = elapsed()
        startDate = nil
        state = .idle
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        denied = manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard state == .running else { return }
        for loc in locations where loc.horizontalAccuracy >= 0 && loc.horizontalAccuracy < 30 {
            accuracy = loc.horizontalAccuracy
            if let last = lastLocation {
                distance += loc.distance(from: last)
            }
            lastLocation = loc
            route.append(loc.coordinate)
        }
    }
}

/// Tela "Corrida" (Treino.dc.html).
struct WorkoutView: View {
    @ObservedObject private var band = Fit3Client.shared
    @StateObject private var tracker = WorkoutTracker()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            EloScreen(top: 56) {
                header
                map
                metrics(now: context.date)
                mirror(now: context.date)
                buttons
            }
        }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Outdoor workout")).font(EloFont.inter(13, .medium)).foregroundColor(EloColor.secondary)
                Text(L("Run")).font(EloFont.grotesk(34)).tracking(-0.5).foregroundColor(EloColor.text)
            }
            Spacer()
            switch tracker.state {
            case .running:
                pill(L("iPhone GPS"), dot: true, fg: EloColor.accent, bg: EloColor.okBg, border: EloColor.okBorder)
            case .paused:
                pill(L("Paused"), dot: false, fg: EloColor.warn, bg: EloColor.warnBg, border: EloColor.warnBorder)
            case .idle:
                EmptyView()
            }
        }
    }

    private func pill(_ text: String, dot: Bool, fg: Color, bg: Color, border: Color) -> some View {
        HStack(spacing: 6) {
            if dot { Circle().fill(fg).frame(width: 8, height: 8) }
            Text(text).font(EloFont.inter(12, .semibold)).foregroundColor(fg)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(bg))
        .overlay(Capsule().stroke(border, lineWidth: 1))
    }

    private var map: some View {
        ZStack(alignment: .topLeading) {
            RouteMap(route: tracker.route)
            Text(tracker.accuracy.map { L("Accuracy ±%d m", Int($0.rounded())) } ?? L("Waiting for GPS"))
                .font(EloFont.inter(11))
                .foregroundColor(EloColor.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 8).fill(EloColor.bg.opacity(0.85)))
                .padding(12)
        }
        .frame(height: 212)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(EloColor.border, lineWidth: 1))
    }

    private func timeText(_ t: TimeInterval) -> String {
        let s = Int(t)
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    private func paceText(_ t: TimeInterval) -> String {
        guard tracker.distance > 50 else { return "—" }
        let secPerKm = t / (tracker.distance / 1000)
        let m = Int(secPerKm) / 60
        let s = Int(secPerKm) % 60
        return String(format: "%d′%02d″", m, s)
    }

    private var kmText: String {
        let f = NumberFormatter()
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: tracker.distance / 1000)) ?? "0.00"
    }

    private var zoneTitle: String {
        guard let bpm = band.bpm, band.hrContact, bpm > 0 else { return L("Heart rate") }
        let age = ProfileStore.age ?? 30
        let maxHr = Double(220 - age)
        let pct = Double(bpm) / maxHr
        let zone = pct < 0.6 ? 1 : pct < 0.7 ? 2 : pct < 0.8 ? 3 : pct < 0.9 ? 4 : 5
        return L("Heart rate · zone %d", zone)
    }

    private func metrics(now: Date) -> some View {
        let t = tracker.elapsed(at: now)
        let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        return LazyVGrid(columns: columns, spacing: 12) {
            metric(L("Time"), timeText(t), nil)
            metric(L("Distance"), kmText, "km")
            metric(L("Pace"), paceText(t), "/km")
            metric(zoneTitle, band.hrContact ? band.bpm.map { "\($0)" } ?? "—" : "—", "bpm")
        }
    }

    private func metric(_ title: String, _ value: String, _ unit: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(EloFont.inter(12)).foregroundColor(EloColor.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(EloFont.grotesk(28)).foregroundColor(EloColor.text)
                if let unit = unit {
                    Text(unit).font(EloFont.inter(15, .medium)).foregroundColor(EloColor.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 16)
    }

    private func mirror(now: Date) -> some View {
        let t = tracker.elapsed(at: now)
        return HStack(spacing: 16) {
            VStack(spacing: 2) {
                Text(kmText).font(EloFont.grotesk(18)).foregroundColor(EloColor.text)
                Text("km").font(EloFont.inter(9)).foregroundColor(EloColor.secondary)
                Text(paceText(t)).font(EloFont.grotesk(12, .semibold)).foregroundColor(EloColor.accent)
                Text(L("%@ bpm", band.hrContact ? band.bpm.map { "\($0)" } ?? "—" : "—"))
                    .font(EloFont.inter(10)).foregroundColor(EloColor.text)
            }
            .frame(width: 64, height: 104)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(hex: 0x05070A)))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(EloColor.borderStrong, lineWidth: 2))

            VStack(alignment: .leading, spacing: 4) {
                Text(L("Mirroring on the band")).font(EloFont.inter(15, .semibold)).foregroundColor(EloColor.text)
                Text(L("Distance, pace and time from the iPhone GPS to the Fit3 every 5 s."))
                    .font(EloFont.inter(13)).foregroundColor(EloColor.secondary).lineSpacing(2)
                Text(L("coming soon · workout channel not decoded yet"))
                    .font(EloFont.mono(11)).foregroundColor(EloColor.warn)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .card()
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            Button(tracker.state == .paused ? L("Resume") : L("Pause")) { tracker.togglePause() }
                .buttonStyle(EloButtonStyle(filled: false, height: 52))
                .disabled(tracker.state == .idle)
                .opacity(tracker.state == .idle ? 0.5 : 1)
            Button(tracker.state == .idle ? L("Start") : L("Finish")) {
                if tracker.state == .idle {
                    tracker.start()
                    band.holdHeartRate(true)
                } else {
                    tracker.finish()
                    band.holdHeartRate(false)
                }
            }
            .buttonStyle(EloButtonStyle(filled: true, height: 52))
        }
    }
}

/// Mapa estilizado do design com o percurso real por cima.
struct RouteMap: View {
    let route: [CLLocationCoordinate2D]

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(hex: 0x141922)))
            let sx = size.width / 350
            let sy = size.height / 212
            var streets = Path()
            streets.move(to: CGPoint(x: 0, y: 60 * sy)); streets.addLine(to: CGPoint(x: size.width, y: 40 * sy))
            streets.move(to: CGPoint(x: 0, y: 150 * sy)); streets.addLine(to: CGPoint(x: size.width, y: 170 * sy))
            streets.move(to: CGPoint(x: 90 * sx, y: 0)); streets.addLine(to: CGPoint(x: 110 * sx, y: size.height))
            streets.move(to: CGPoint(x: 250 * sx, y: 0)); streets.addLine(to: CGPoint(x: 230 * sx, y: size.height))
            ctx.stroke(streets, with: .color(Color(hex: 0x1C222C)), lineWidth: 10)

            guard route.count >= 2 else { return }
            let lats = route.map { $0.latitude }
            let lons = route.map { $0.longitude }
            guard let minLat = lats.min(), let maxLat = lats.max(),
                  let minLon = lons.min(), let maxLon = lons.max() else { return }
            let midLat = (minLat + maxLat) / 2
            let kx = cos(midLat * .pi / 180)
            let w = max((maxLon - minLon) * kx, 1e-6)
            let h = max(maxLat - minLat, 1e-6)
            let pad: CGFloat = 30
            let scale = min((size.width - 2 * pad) / CGFloat(w), (size.height - 2 * pad) / CGFloat(h))
            let ox = (size.width - CGFloat(w) * scale) / 2
            let oy = (size.height - CGFloat(h) * scale) / 2
            func pt(_ c: CLLocationCoordinate2D) -> CGPoint {
                CGPoint(x: ox + CGFloat((c.longitude - minLon) * kx) * scale,
                        y: oy + CGFloat(maxLat - c.latitude) * scale)
            }
            var path = Path()
            path.move(to: pt(route[0]))
            for c in route.dropFirst() { path.addLine(to: pt(c)) }
            ctx.stroke(path, with: .color(EloColor.accent), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))

            let s = pt(route[0])
            ctx.fill(Path(ellipseIn: CGRect(x: s.x - 6, y: s.y - 6, width: 12, height: 12)), with: .color(EloColor.bg))
            ctx.stroke(Path(ellipseIn: CGRect(x: s.x - 6, y: s.y - 6, width: 12, height: 12)), with: .color(EloColor.secondary), lineWidth: 2)
            let e = pt(route[route.count - 1])
            ctx.fill(Path(ellipseIn: CGRect(x: e.x - 14, y: e.y - 14, width: 28, height: 28)), with: .color(EloColor.accent.opacity(0.2)))
            ctx.fill(Path(ellipseIn: CGRect(x: e.x - 7, y: e.y - 7, width: 14, height: 14)), with: .color(EloColor.accent))
            ctx.stroke(Path(ellipseIn: CGRect(x: e.x - 7, y: e.y - 7, width: 14, height: 14)), with: .color(EloColor.bg), lineWidth: 2)
        }
    }
}
