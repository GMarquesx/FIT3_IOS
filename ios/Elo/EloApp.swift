import SwiftUI

@main
struct EloApp: App {
    init() {
        // Cria o cliente cedo: o iOS pode reabrir o app em segundo plano para eventos da pulseira.
        _ = Fit3Client.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
