import SwiftUI

struct RootView: View {
    @Environment(Machine.self) private var machine

    var body: some View {
        ZStack {
            Palette.ground.ignoresSafeArea()
            switch machine.phase {
            case .booting:
                BootView()
            case .signIn:
                SignInView()
            case .session:
                SessionView()
            }
        }
        .animation(.smooth, value: machine.phase)
    }
}
