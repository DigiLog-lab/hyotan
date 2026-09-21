import SwiftUI

/// The main screen: the Codex transcript scrolls underneath a floating glass
/// panel that shows the guest's process tree and the prompt.
struct SessionView: View {
    @Environment(Machine.self) private var machine
    @State private var prompt = ""
    @State private var showsWorkspace = false
    @State private var showsSystem = false
    @FocusState private var promptFocused: Bool
    @Namespace private var glass

    private static let bottomID = "transcript-bottom"

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if machine.entries.isEmpty {
                            Text("› ")
                                .foregroundStyle(Palette.ochre)
                            + Text("ask Codex to write and run something")
                                .foregroundStyle(Palette.sub)
                        }
                        ForEach(machine.entries) { entry in
                            TranscriptRow(entry: entry)
                        }
                        Color.clear.frame(height: 1).id(Self.bottomID)
                    }
                    .font(.mono(13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollEdgeEffectStyle(.hard, for: .top)
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                .onChange(of: machine.entries) {
                    withAnimation(.smooth(duration: 0.2)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                }
                .accessibilityIdentifier("transcript")
            }
            .background(Palette.ground)
            .safeAreaInset(edge: .bottom, spacing: 0) { console }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        GourdMark(height: 22, lineWidth: 1.8)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("hyotan").font(.mono(15, weight: .bold))
                            Text(subtitle).font(.mono(10)).foregroundStyle(Palette.sub)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Workspace", systemImage: "folder") { showsWorkspace = true }
                        .accessibilityIdentifier("open-workspace")
                    Button("System", systemImage: "cpu") { showsSystem = true }
                        .accessibilityIdentifier("open-system")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showsWorkspace) { WorkspaceView() }
            .sheet(isPresented: $showsSystem) { SystemView() }
        }
        .foregroundStyle(Palette.text)
        .accessibilityIdentifier("session-screen")
    }

    private var subtitle: String {
        let alpine = machine.boot.manifest?.alpineVersion ?? ""
        return "alpine \(alpine) · aarch64"
    }

    private var console: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(spacing: 10) {
                ProcessPanel(processes: machine.processes)
                    .glassEffect(.regular, in: .rect(cornerRadius: 22))
                    .glassEffectID("processes", in: glass)

                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Text("›").font(.mono(16)).foregroundStyle(Palette.ochre)
                        TextField("Ask Codex", text: $prompt, axis: .vertical)
                            .font(.mono(14))
                            .lineLimit(1...4)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($promptFocused)
                            .submitLabel(.send)
                            .onSubmit(submit)
                            .accessibilityIdentifier("prompt-field")
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 48)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24))
                    .glassEffectID("prompt", in: glass)

                    if machine.isRunning {
                        Button(action: machine.interrupt) {
                            Image(systemName: "stop.fill").frame(width: 24, height: 32)
                        }
                        .buttonStyle(.glass)
                        .tint(Palette.red)
                        .accessibilityLabel("Stop")
                        .accessibilityIdentifier("stop-button")
                        .glassEffectID("action", in: glass)
                    } else {
                        Button(action: submit) {
                            Image(systemName: "arrow.up").fontWeight(.bold).frame(width: 24, height: 32)
                        }
                        .buttonStyle(.glassProminent)
                        .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("Send")
                        .accessibilityIdentifier("send-button")
                        .glassEffectID("action", in: glass)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 8)
        }
        .animation(.smooth, value: machine.isRunning)
    }

    private func submit() {
        machine.send(prompt)
        prompt = ""
        promptFocused = false
    }
}

/// `PID  S  CMD`, as a tree. The rows are what `ps` in the guest printed a moment ago.
struct ProcessPanel: View {
    let processes: [GuestProcess]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            row(pid: "PID", state: "S", command: "CMD", stateColor: Palette.sub, commandColor: Palette.sub)
            ForEach(processes.prefix(6)) { process in
                row(
                    pid: String(process.pid), state: process.state,
                    command: String(repeating: "  ", count: max(0, process.depth - 1)) + (process.depth > 0 ? "└ " : "") + process.command,
                    stateColor: process.state == "R" ? Palette.ochre : Palette.sub, commandColor: Palette.text
                )
            }
            if processes.count > 6 {
                Text("+\(processes.count - 6) more").foregroundStyle(Palette.sub)
            }
        }
        .font(.mono(11.5))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .animation(.smooth(duration: 0.25), value: processes)
        .accessibilityIdentifier("process-panel")
    }

    private func row(pid: String, state: String, command: String, stateColor: Color, commandColor: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(pid).foregroundStyle(Palette.sub).frame(width: 34, alignment: .leading)
            Text(state).foregroundStyle(stateColor).frame(width: 12, alignment: .leading)
            Text(command).foregroundStyle(commandColor).lineLimit(1).truncationMode(.tail)
        }
    }
}

struct TranscriptRow: View {
    let entry: TranscriptEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch entry.kind {
            case .prompt:
                (Text("› ").foregroundStyle(Palette.ochre) + Text(entry.text)).padding(.top, 8)
            case .message:
                Text("• ").foregroundStyle(Palette.sub) + Text(Self.markdown(entry.text))
            case .command:
                Text("• ").foregroundStyle(bullet)
                    + Text(entry.status == .running ? "Running " : "Ran ").foregroundStyle(Palette.sub)
                    + Text(entry.text)
                detail(lines: tail(entry.detail, limit: 8), color: { _ in entry.status == .failed ? Palette.red : Palette.sub })
            case .edit:
                Text("• ").foregroundStyle(bullet) + Text("Edited ").foregroundStyle(Palette.sub) + Text(entry.text)
                detail(lines: diffLines(entry.detail), color: { line in
                    line.hasPrefix("+") ? Palette.green : line.hasPrefix("-") ? Palette.red : Palette.sub
                })
            case .failure:
                Text("• ").foregroundStyle(Palette.red) + Text(entry.text).foregroundStyle(Palette.red)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Inline markdown only (code spans, emphasis, links); line breaks stay as written.
    private static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var parsed = try? AttributedString(markdown: text, options: options) else { return AttributedString(text) }
        for run in parsed.runs where run.link != nil {
            parsed[run.range].link = nil
            parsed[run.range].foregroundColor = Palette.ochre
        }
        return parsed
    }

    private var bullet: Color {
        switch entry.status {
        case .running: Palette.ochre
        case .succeeded: Palette.green
        case .failed: Palette.red
        }
    }

    @ViewBuilder
    private func detail(lines: [String], color: @escaping (String) -> Color) -> some View {
        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
            (Text(index == 0 ? "└ " : "  ") + Text(line))
                .foregroundStyle(color(line))
                .padding(.leading, 16)
        }
    }

    private func tail(_ text: String, limit: Int) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return lines.count > limit ? ["… \(lines.count - limit) more lines"] + lines.suffix(limit) : lines
    }

    private func diffLines(_ diff: String) -> [String] {
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { ($0.hasPrefix("+") && !$0.hasPrefix("+++")) || ($0.hasPrefix("-") && !$0.hasPrefix("---")) }
        return lines.count > 10 ? Array(lines.prefix(10)) + ["… \(lines.count - 10) more lines"] : lines
    }
}
