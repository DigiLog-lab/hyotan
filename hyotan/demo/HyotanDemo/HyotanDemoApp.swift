import SwiftUI

@main
struct HyotanDemoApp: App {
    @State private var machine = Machine()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(machine)
                .preferredColorScheme(.dark)
                .tint(Palette.ochre)
                .task { await machine.start() }
        }
    }
}
