import SwiftUI

struct BootView: View {
    @Environment(Machine.self) private var machine

    private struct Step: Identifiable {
        let id: String
        let state: Machine.StepState
        let tail: String
    }

    private var steps: [Step] {
        let manifest = machine.boot.manifest
        let unpack: Machine.StepState
        let guest: Machine.StepState
        switch machine.boot.state {
        case .idle: (unpack, guest) = (.pending, .pending)
        case .installing: (unpack, guest) = (.running, .pending)
        case .booting: (unpack, guest) = (.done, .running)
        case .ready: (unpack, guest) = (.done, .done)
        case .failed(let detail): (unpack, guest) = (.failed(detail), .pending)
        }
        return [
            Step(id: "unpack rootfs", state: unpack, tail: manifest.map { "alpine \($0.alpineVersion)" } ?? ""),
            Step(id: "boot guest", state: guest, tail: "fakefs"),
            Step(id: "start codex app-server", state: machine.codexStep, tail: manifest?.codexVersion ?? ""),
        ]
    }

    private var progress: Double {
        switch machine.boot.state {
        case .idle: 0
        case .installing(let fraction): fraction * 0.8
        case .booting: 0.85
        case .ready: machine.codexStep == .done ? 1 : 0.92
        case .failed: 0
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GourdMark(height: 96, lineWidth: 3.5)
            Text("hyotan")
                .font(.mono(30, weight: .bold))
                .padding(.top, 22)
            Text(machine.boot.hyotanVersion)
                .font(.mono(12))
                .foregroundStyle(Palette.sub)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 12) {
                ForEach(steps) { step in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(mark(step.state))
                            .foregroundStyle(color(step.state))
                            .frame(width: 38, alignment: .leading)
                        Text(step.id)
                        Spacer(minLength: 8)
                        Text(step.tail).foregroundStyle(Palette.sub)
                    }
                    if case .failed(let detail) = step.state {
                        Text(detail).foregroundStyle(Palette.red).padding(.leading, 48)
                    }
                }
            }
            .font(.mono(13))
            .padding(.top, 56)

            ProgressView(value: progress)
                .tint(Palette.ochre)
                .padding(.top, 20)
                .accessibilityLabel("Boot progress")

            Spacer()
            Text("GPLv3 · github.com/DigiLog-lab/hyotan")
                .font(.mono(12))
                .foregroundStyle(Palette.sub)
        }
        .foregroundStyle(Palette.text)
        .padding(.horizontal, 32)
        .padding(.top, 96)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("boot-screen")
    }

    private func mark(_ state: Machine.StepState) -> String {
        switch state {
        case .pending: "[  ]"
        case .running: "[..]"
        case .done: "[ok]"
        case .failed: "[!!]"
        }
    }

    private func color(_ state: Machine.StepState) -> Color {
        switch state {
        case .pending: Palette.sub
        case .running: Palette.ochre
        case .done: Palette.green
        case .failed: Palette.red
        }
    }
}
