import Foundation
import OSLog

private let machineLog = Logger(subsystem: "com.digiloglab.hyotan", category: "machine")

/// One line of the Codex transcript, built from app-server notifications.
struct TranscriptEntry: Identifiable, Equatable {
    enum Kind: Equatable {
        case prompt
        case message
        case command
        case edit
        case failure
    }

    enum Status: Equatable {
        case running
        case succeeded
        case failed
    }

    let id: String
    var kind: Kind
    var text: String
    /// Command output or a diff, shown indented under the entry.
    var detail: String = ""
    var status: Status = .succeeded
}

/// One guest process, as `ps` inside the guest reports it.
struct GuestProcess: Identifiable, Equatable {
    let pid: Int
    let parent: Int
    let state: String
    let command: String
    var depth: Int = 0
    var id: Int { pid }
}

/// One file under `/workspace`.
struct WorkspaceFile: Identifiable, Equatable {
    let path: String
    let size: Int
    var id: String { path }
}

/// The whole demo: boots the guest, keeps one `codex app-server` alive, signs in,
/// runs turns, and mirrors what happens inside the guest for the views.
@Observable
@MainActor
final class Machine {
    enum Phase: Equatable {
        case booting
        case signIn
        case session
    }

    enum StepState: Equatable {
        case pending
        case running
        case done
        case failed(String)
    }

    let boot: HyotanBoot
    private let session: CodexAppServerSession
    private let account: CodexAccountRuntime

    private(set) var phase: Phase = .booting
    private(set) var codexStep: StepState = .pending
    private(set) var entries: [TranscriptEntry] = []
    private(set) var processes: [GuestProcess] = []
    private(set) var files: [WorkspaceFile] = []
    private(set) var isRunning = false
    private(set) var login: CodexLoginStart?
    private(set) var loginError: String?
    private(set) var snapshot: CodexAccountSnapshot?
    private(set) var systemReport: [(command: String, output: String)] = []

    private var threadID: String?
    private var turnID: String?
    private var started = false
    private var processPoll: Task<Void, Never>?
    private var loginTask: Task<Void, Never>?

    static let guestWorkspace = "/workspace"

    init() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let boot = HyotanBoot()
        self.boot = boot
        session = CodexAppServerSession(clientVersion: version, launcher: CodexAppServerSession.guestLauncher(boot: boot))
        account = CodexAccountRuntime(session: session)
    }

    // MARK: - Boot

    func start() async {
        guard !started else { return }
        started = true
        await boot.start()
        guard boot.state.isReady else { return }
        #if DEBUG && targetEnvironment(simulator)
        await seedDebugCodexAuth()
        #endif
        codexStep = .running
        do {
            await session.setTap { [weak self] method, params in
                Task { @MainActor in self?.receive(method: method, params: params) }
            }
            try await session.start()
            codexStep = .done
            let snapshot = try await account.readAccount()
            self.snapshot = snapshot
            phase = snapshot.status == .disconnected ? .signIn : .session
            #if DEBUG && targetEnvironment(simulator)
            // Simulator-only aid: run one prompt without the keyboard (`HYOTAN_DEBUG_PROMPT`).
            if phase == .session, let prompt = ProcessInfo.processInfo.environment["HYOTAN_DEBUG_PROMPT"] { send(prompt) }
            #endif
        } catch {
            codexStep = .failed(error.localizedDescription)
        }
        startProcessPolling()
    }

    #if DEBUG && targetEnvironment(simulator)
    /// Simulator-only aid: `HYOTAN_DEBUG_CODEX_AUTH_FILE=<host path>` copies an existing Codex
    /// `auth.json` into the guest so turns can run without a browser login. Never compiled for devices.
    private func seedDebugCodexAuth() async {
        guard let path = ProcessInfo.processInfo.environment["HYOTAN_DEBUG_CODEX_AUTH_FILE"], !path.isEmpty else { return }
        let staged = HyotanBoot.workspaceRoot.appendingPathComponent(".debug-auth.json")
        try? FileManager.default.removeItem(at: staged)
        guard (try? FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: staged)) != nil else { return }
        _ = await boot.capture("/bin/sh", arguments: [
            "-c", "mkdir -p /root/.codex && cp /workspace/.debug-auth.json /root/.codex/auth.json && chmod 600 /root/.codex/auth.json",
        ])
        try? FileManager.default.removeItem(at: staged)
    }
    #endif

    // MARK: - Sign in

    func beginLogin() {
        guard loginTask == nil else { return }
        loginError = nil
        loginTask = Task {
            defer { loginTask = nil }
            do {
                let start = try await account.startDeviceLogin()
                login = start
                try await account.waitForLoginCompleted(loginID: start.loginID)
                snapshot = try await account.readAccount()
                login = nil
                phase = .session
            } catch {
                login = nil
                loginError = error.localizedDescription
            }
        }
    }

    func signOut() async {
        try? await account.logout()
        snapshot = nil
        threadID = nil
        entries = []
        phase = .signIn
    }

    // MARK: - Turns

    func send(_ prompt: String) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        isRunning = true
        entries.append(TranscriptEntry(id: UUID().uuidString, kind: .prompt, text: text))
        Task {
            do {
                try await runTurn(text)
            } catch {
                finishTurn(failure: error.localizedDescription)
            }
        }
    }

    private func runTurn(_ text: String) async throws {
        if threadID == nil {
            let response = try await session.request("thread/start", params: [
                "cwd": Self.guestWorkspace, "approvalPolicy": "never", "sandbox": "danger-full-access",
                "ephemeral": true, "serviceName": "hyotan",
            ])
            threadID = (response["thread"] as? JSONObject)?["id"] as? String
        }
        guard let threadID else { throw CodexAppServerError.malformed("thread/start returned no thread id") }
        let response = try await session.request("turn/start", params: [
            "threadId": threadID, "cwd": Self.guestWorkspace, "approvalPolicy": "never",
            "sandboxPolicy": ["type": "dangerFullAccess"],
            "input": [["type": "text", "text": text]],
        ])
        turnID = (response["turn"] as? JSONObject)?["id"] as? String
    }

    func interrupt() {
        guard isRunning, let threadID, let turnID else { return }
        Task {
            _ = try? await session.request("turn/interrupt", params: ["threadId": threadID, "turnId": turnID], timeout: .seconds(10))
        }
    }

    private func finishTurn(failure: String?) {
        if let failure {
            entries.append(TranscriptEntry(id: UUID().uuidString, kind: .failure, text: failure, status: .failed))
        }
        for index in entries.indices where entries[index].status == .running {
            entries[index].status = .failed
        }
        isRunning = false
        turnID = nil
        Task { await refreshFiles() }
    }

    // MARK: - Notifications

    private func receive(method: String, params: JSONObject) {
        switch method {
        case "item/started":
            upsert(item: params["item"] as? JSONObject ?? [:], completed: false)
        case "item/completed":
            upsert(item: params["item"] as? JSONObject ?? [:], completed: true)
        case "item/agentMessage/delta":
            append(delta: params, kind: .message, toDetail: false)
        case "item/commandExecution/outputDelta":
            append(delta: params, kind: .command, toDetail: true)
        case "turn/completed":
            let turn = params["turn"] as? JSONObject ?? [:]
            let status = turn["status"] as? String ?? ""
            if status == "completed" || status == "interrupted" {
                finishTurn(failure: status == "interrupted" ? "Interrupted" : nil)
            } else {
                let detail = (turn["error"] as? JSONObject)?["message"] as? String ?? "Turn \(status)"
                finishTurn(failure: detail)
            }
        case "error":
            let detail = (params["error"] as? JSONObject)?["message"] as? String
            if let detail, params["willRetry"] as? Bool != true { machineLog.error("codex error: \(detail, privacy: .public)") }
        default:
            break
        }
    }

    private func upsert(item: JSONObject, completed: Bool) {
        guard let id = item["id"] as? String, let type = item["type"] as? String else { return }
        var entry: TranscriptEntry
        switch type {
        case "agentMessage":
            let text = item["text"] as? String ?? ""
            entry = TranscriptEntry(id: id, kind: .message, text: text)
            if text.isEmpty, let existing = entries.first(where: { $0.id == id }) { entry.text = existing.text }
        case "commandExecution":
            entry = TranscriptEntry(id: id, kind: .command, text: Self.displayCommand(item["command"]))
            let output = item["aggregatedOutput"] as? String ?? ""
            entry.detail = output.isEmpty ? (entries.first(where: { $0.id == id })?.detail ?? "") : output
            if completed {
                let code = (item["exitCode"] as? NSNumber)?.intValue
                entry.status = (code ?? 0) == 0 && (item["status"] as? String) != "failed" ? .succeeded : .failed
            } else {
                entry.status = .running
            }
        case "fileChange":
            let changes = item["changes"] as? [JSONObject] ?? []
            let paths = changes.compactMap { ($0["path"] as? String).map(Self.displayPath) }
            entry = TranscriptEntry(id: id, kind: .edit, text: paths.joined(separator: ", "))
            entry.detail = changes.map(Self.displayDiff).joined(separator: "\n")
            entry.status = completed ? ((item["status"] as? String) == "failed" ? .failed : .succeeded) : .running
        default:
            return
        }
        if entry.kind == .message, entry.text.isEmpty, !completed { return }
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
    }

    private func append(delta params: JSONObject, kind: TranscriptEntry.Kind, toDetail: Bool) {
        guard let id = params["itemId"] as? String, let delta = params["delta"] as? String, !delta.isEmpty else { return }
        if let index = entries.firstIndex(where: { $0.id == id }) {
            if toDetail { entries[index].detail += delta } else { entries[index].text += delta }
        } else if !toDetail {
            entries.append(TranscriptEntry(id: id, kind: kind, text: delta, status: .running))
        }
    }

    /// Codex wraps every command in a login shell; show what the agent meant to run.
    nonisolated static func displayCommand(_ raw: Any?) -> String {
        var text: String
        if let parts = raw as? [String] {
            text = parts.count >= 3 && ["-lc", "-c"].contains(parts[1]) ? parts[2...].joined(separator: " ") : parts.joined(separator: " ")
        } else {
            text = raw as? String ?? ""
        }
        for prefix in ["/bin/sh -lc ", "/bin/sh -c ", "sh -lc ", "sh -c ", "/bin/bash -lc ", "bash -lc ", "/bin/ash -lc "] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
            if text.count >= 2, let quote = text.first, quote == "'" || quote == "\"", text.last == quote {
                text = String(text.dropFirst().dropLast())
            }
            break
        }
        return text
    }

    /// A new file arrives as its plain content; show it as added lines like any other diff.
    nonisolated static func displayDiff(_ change: JSONObject) -> String {
        let diff = change["diff"] as? String ?? change["content"] as? String ?? ""
        let kind = (change["kind"] as? JSONObject)?["type"] as? String ?? change["kind"] as? String ?? ""
        guard kind == "add", !diff.hasPrefix("@@"), !diff.hasPrefix("---") else { return diff }
        return diff.split(separator: "\n", omittingEmptySubsequences: false).map { "+" + $0 }.joined(separator: "\n")
    }

    nonisolated static func displayPath(_ path: String) -> String {
        path.hasPrefix(guestWorkspace + "/") ? String(path.dropFirst(guestWorkspace.count + 1)) : path
    }

    // MARK: - Processes

    private func startProcessPolling() {
        processPoll?.cancel()
        processPoll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshProcesses()
                try? await Task.sleep(for: .milliseconds(self?.isRunning == true ? 700 : 2500))
            }
        }
    }

    private func refreshProcesses() async {
        let result = await boot.capture("/bin/ps", arguments: ["-o", "pid,ppid,stat,args"], timeout: .seconds(10))
        guard result.code == 0 else { return }
        let parsed = Self.parseProcesses(result.stdout)
        if parsed != processes { processes = parsed }
    }

    /// Parses busybox `ps -o pid,ppid,stat,args` into a process tree. The guest lists every
    /// thread as its own row (`{tokio-rt-worker} …`); those are folded into their process, and
    /// the `ps` probe itself is dropped.
    nonisolated static func parseProcesses(_ lines: [String]) -> [GuestProcess] {
        var rows: [GuestProcess] = []
        var threadParent: [Int: Int] = [:]
        for line in lines.dropFirst() {
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count >= 3, let pid = Int(fields[0]), let parent = Int(fields[1]) else { continue }
            let command = fields.count == 4 ? fields[3].trimmingCharacters(in: .whitespaces) : ""
            if command.hasPrefix("{") {
                threadParent[pid] = parent
                continue
            }
            if command.hasPrefix("/bin/ps ") || command.hasPrefix("ps ") { continue }
            rows.append(GuestProcess(pid: pid, parent: parent, state: String(fields[2].prefix(1)), command: displayProcess(command, pid: pid)))
        }
        func owner(_ pid: Int) -> Int {
            var current = pid
            for _ in 0..<64 {
                guard let next = threadParent[current] else { break }
                current = next
            }
            return current
        }
        let all = rows.map { GuestProcess(pid: $0.pid, parent: owner($0.parent), state: $0.state, command: $0.command) }
        let known = Set(all.map(\.pid))
        var ordered: [GuestProcess] = []
        func visit(_ parent: Int?, depth: Int) {
            for process in all.sorted(by: { $0.pid < $1.pid }) {
                let isRoot = !known.contains(process.parent) || process.parent == process.pid
                guard parent == nil ? isRoot : (!isRoot && process.parent == parent) else { continue }
                var placed = process
                placed.depth = depth
                ordered.append(placed)
                if depth < 6 { visit(process.pid, depth: depth + 1) }
            }
        }
        visit(nil, depth: 0)
        return ordered
    }

    /// `/usr/local/bin/codex -c features.x=false app-server` → `codex app-server`.
    nonisolated static func displayProcess(_ command: String, pid: Int) -> String {
        var words = command.split(separator: " ").map(String.init)
        guard let first = words.first, first != "[]" else { return pid == 1 ? "init" : command }
        words[0] = (first as NSString).lastPathComponent
        var kept: [String] = []
        var index = 0
        while index < words.count {
            if words[index] == "-c", index + 1 < words.count, words[index + 1].contains("="), !words[index + 1].contains(" ") , words[0] == "codex" {
                index += 2
                continue
            }
            kept.append(words[index])
            index += 1
        }
        return kept.joined(separator: " ")
    }

    // MARK: - Workspace

    func refreshFiles() async {
        let root = HyotanBoot.workspaceRoot
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        var found: [WorkspaceFile] = []
        if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            for case let url as URL in walker {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                let relative = String(url.path.dropFirst(root.path.count + 1))
                if relative.hasPrefix("__pycache__") || relative.contains("/__pycache__/") { continue }
                found.append(WorkspaceFile(path: relative, size: values.fileSize ?? 0))
                if found.count >= 200 { break }
            }
        }
        files = found.sorted { $0.path < $1.path }
    }

    func contents(of file: WorkspaceFile) -> String {
        let url = HyotanBoot.workspaceRoot.appendingPathComponent(file.path)
        guard let data = try? Data(contentsOf: url), data.count <= 200_000, let text = String(data: data, encoding: .utf8) else {
            return "(binary or too large to show)"
        }
        return text
    }

    // MARK: - System

    static let systemCommands = ["uname -sm", "cat /etc/alpine-release", "codex --version", "python3 --version"]

    func refreshSystemReport() async {
        var report: [(String, String)] = []
        for command in Self.systemCommands {
            let result = await boot.capture("/bin/sh", arguments: ["-c", command], timeout: .seconds(30))
            let output = (result.stdout + (result.code == 0 ? [] : result.stderr)).joined(separator: "\n")
            report.append((command, output.isEmpty ? "exit \(result.code)" : output))
            systemReport = report.map { (command: $0.0, output: $0.1) }
        }
    }

    /// Runs one line in the guest's shell, for the System screen's prompt.
    func runShell(_ line: String) async -> String {
        let result = await boot.capture("/bin/sh", arguments: ["-c", "cd /workspace && " + line], timeout: .seconds(60))
        let output = (result.stdout + result.stderr).joined(separator: "\n")
        return output.isEmpty && result.code != 0 ? "exit \(result.code)" : output
    }
}
