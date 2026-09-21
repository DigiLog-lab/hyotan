import SwiftUI

struct SystemView: View {
    @Environment(Machine.self) private var machine
    @Environment(\.dismiss) private var dismiss
    @State private var shellLine = ""
    @State private var shellLog: [(command: String, output: String)] = []
    @State private var shellBusy = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    terminal
                    HStack(spacing: 10) {
                        Text("#").font(.mono(15)).foregroundStyle(Palette.green)
                        TextField("run a command in the guest", text: $shellLine)
                            .font(.mono(14))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.go)
                            .onSubmit(runShell)
                            .accessibilityIdentifier("shell-field")
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 48)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))

                    VStack(spacing: 0) {
                        row("Runtime", "hyotan \(machine.boot.hyotanVersion)", mono: true)
                        row("Based on", "iSH (ish-arm64)")
                        row("License", "GPLv3 + LICENSE.IOS")
                        Link(destination: URL(string: "https://github.com/DigiLog-lab/hyotan")!) {
                            row("Source", "DigiLog-lab/hyotan", mono: true, valueColor: Palette.ochre)
                        }
                        if let snapshot = machine.snapshot, snapshot.status != .disconnected {
                            row("ChatGPT", snapshot.planType ?? "connected")
                        }
                    }

                    if machine.snapshot != nil {
                        Button("Sign out", role: .destructive) {
                            Task { await machine.signOut(); dismiss() }
                        }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("sign-out")
                    }
                }
                .padding(20)
            }
            .background(Palette.ground)
            .foregroundStyle(Palette.text)
            .navigationTitle("system")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Run again", systemImage: "arrow.clockwise") { Task { await machine.refreshSystemReport() } }
                }
            }
            .task { if machine.systemReport.isEmpty { await machine.refreshSystemReport() } }
        }
        .accessibilityIdentifier("system-screen")
    }

    private var terminal: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array((machine.systemReport + shellLog).enumerated()), id: \.offset) { _, item in
                Text("hyotan:~# ").foregroundStyle(Palette.green) + Text(item.command)
                Text(item.output).foregroundStyle(Palette.sub)
            }
            if shellBusy { ProgressView().controlSize(.small) }
        }
        .font(.mono(12))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Palette.well, in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.line))
        .accessibilityIdentifier("system-terminal")
    }

    private func row(_ key: String, _ value: String, mono: Bool = false, valueColor: Color = Palette.text) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(key).foregroundStyle(Palette.sub)
                Spacer()
                Text(value).font(mono ? .mono(13) : .subheadline).foregroundStyle(valueColor)
            }
            .font(.subheadline)
            .frame(minHeight: 48)
            Divider().overlay(Palette.line)
        }
    }

    private func runShell() {
        let line = shellLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !shellBusy else { return }
        shellLine = ""
        shellBusy = true
        Task {
            let output = await machine.runShell(line)
            shellLog.append((command: line, output: output))
            shellBusy = false
        }
    }
}
