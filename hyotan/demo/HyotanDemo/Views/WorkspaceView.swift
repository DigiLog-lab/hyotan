import SwiftUI

struct WorkspaceView: View {
    @Environment(Machine.self) private var machine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if machine.files.isEmpty {
                    Text("empty").font(.mono(13)).foregroundStyle(Palette.sub)
                        .listRowBackground(Color.clear)
                }
                ForEach(machine.files) { file in
                    NavigationLink(value: file.id) {
                        HStack {
                            Text(file.path).font(.mono(14))
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                                .font(.mono(11)).foregroundStyle(Palette.sub)
                        }
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Palette.ground)
            .navigationTitle("/workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Reload", systemImage: "arrow.clockwise") { Task { await machine.refreshFiles() } }
                }
            }
            .navigationDestination(for: String.self) { path in
                if let file = machine.files.first(where: { $0.id == path }) {
                    FileView(file: file)
                }
            }
            .task { await machine.refreshFiles() }
        }
        .accessibilityIdentifier("workspace-screen")
    }
}

private struct FileView: View {
    @Environment(Machine.self) private var machine
    let file: WorkspaceFile

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(machine.contents(of: file))
                .font(.mono(12))
                .foregroundStyle(Palette.text)
                .textSelection(.enabled)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.well)
        .navigationTitle(file.path)
        .navigationBarTitleDisplayMode(.inline)
    }
}
