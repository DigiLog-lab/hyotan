import Foundation
import OSLog

private let sessionLog = Logger(subsystem: "com.digiloglab.hyotan", category: "codex-app-server")

typealias JSONObject = [String: Any]

nonisolated enum CodexAppServerError: Error, LocalizedError, Sendable {
    case notRunning
    case rpc(code: Int?, message: String)
    case timeout(String)
    case closed(String)
    case malformed(String)
    case interrupted
    case turnFailed(String)

    var errorDescription: String? {
        switch self {
        case .notRunning: "Codex is not running"
        case .rpc(_, let message): message
        case .timeout(let method): "Codex did not respond (\(method))"
        case .closed(let detail): "Codex exited (\(detail))"
        case .malformed(let detail): "Could not read the Codex response (\(detail))"
        case .interrupted: "Interrupted"
        case .turnFailed(let detail): detail
        }
    }
}

/// Thread-safe handle around the Objective-C guest process.
nonisolated final class GuestProcessHandle: @unchecked Sendable {
    private let process: HyotanProcess
    init(_ process: HyotanProcess) { self.process = process }
    var pid: Int32 { Int32(process.pid) }
    func writeLine(_ line: String) { process.writeLine(line) }
    func closeInput() { process.closeInput() }
    func terminate() { process.terminate() }
}

/// JSON-RPC over the stdio of one `codex app-server` guest process
/// (port of `_StdioSession` in `codex_app_server.py`). One resident process per
/// app; `initialize` is sent once per process, and a process that exits is
/// restarted by the next request.
actor CodexAppServerSession {
    /// `codex app-server` with the background work that spawns child processes turned off.
    /// Under hyotan a child spawned from the multi-threaded app-server can corrupt the
    /// parent (observed as exit 139 at thread start); the shell snapshot runs a login shell on
    /// every thread start and is not needed because turns pass the environment explicitly.
    nonisolated static let appServerArguments = ["-c", "features.shell_snapshot=false", "app-server"]

    typealias Notification = (method: String, params: JSONObject)

    /// Starts the guest process and returns the handle. Injected so the session
    /// can be driven by the real runtime or by tests.
    typealias Launcher = @Sendable (
        _ onLine: @escaping @Sendable (String, Bool) -> Void,
        _ onExit: @escaping @Sendable (Int32) -> Void
    ) async throws -> GuestProcessHandle

    private let launcher: Launcher
    private let clientVersion: String
    private var process: GuestProcessHandle?
    private var initialized = false
    private var starting: Task<Void, Error>?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONObject, Error>] = [:]
    private var waiters: [Waiter] = []
    private var backlog: [Notification] = []
    private var stderrTail: [String] = []
    /// Recent request methods, for diagnosing a guest crash.
    private var lastMethods: [String] = []
    private var deltaCount = 0
    private(set) var generation = 0
    /// Every notification, in arrival order, before waiters and the backlog see it.
    /// The demo renders its transcript from this.
    private var tap: (@Sendable (String, JSONObject) -> Void)?
    func setTap(_ tap: (@Sendable (String, JSONObject) -> Void)?) { self.tap = tap }

    /// Approval requests from the server are answered by policy (approvalPolicy is `never`).
    var serverRequestHandler: (@Sendable (String, JSONObject) -> JSONObject?)?

    static let backlogLimit = 500
    static let defaultTimeout: Duration = .seconds(180)

    private struct Waiter {
        let id: UUID
        let methods: Set<String>
        let predicate: @Sendable (JSONObject) -> Bool
        let continuation: CheckedContinuation<Notification, Error>
    }

    init(clientVersion: String, launcher: @escaping Launcher) {
        self.clientVersion = clientVersion
        self.launcher = launcher
    }

    var isRunning: Bool { process != nil && initialized }

    // MARK: - Lifecycle

    func start() async throws {
        if process != nil, initialized { return }
        if let starting {
            try await starting.value
            return
        }
        let task = Task { try await self.launch() }
        starting = task
        defer { starting = nil }
        try await task.value
    }

    private func launch() async throws {
        generation += 1
        let generation = generation
        let handle = try await launcher({ [weak self] line, isError in
            guard let self else { return }
            Task { await self.receive(line: line, isError: isError, generation: generation) }
        }, { [weak self] code in
            guard let self else { return }
            Task { await self.processExited(code: code, generation: generation) }
        })
        process = handle
        initialized = false
        do {
            _ = try await request("initialize", params: [
                "clientInfo": ["name": "hyotan_demo", "title": "Hyotan", "version": clientVersion],
                "capabilities": ["experimentalApi": false],
            ], timeout: Self.defaultTimeout, allowUninitialized: true)
            try notify("initialized", params: [:])
            initialized = true
        } catch {
            handle.terminate()
            process = nil
            throw error
        }
    }

    func close() {
        process?.closeInput()
        process?.terminate()
        process = nil
        initialized = false
        fail(all: CodexAppServerError.closed("closed"))
    }

    private func processExited(code: Int32, generation: Int) {
        guard generation == self.generation else { return }
        sessionLog.error("codex app-server exited (\(code)) after \(self.lastMethods.joined(separator: ","), privacy: .public)")
        for line in stderrTail.suffix(20) { sessionLog.error("stderr: \(line, privacy: .public)") }
        #if DEBUG
        let report = (["exit \(code) after \(lastMethods.joined(separator: ","))"] + stderrTail).joined(separator: "\n")
        try? report.write(to: HyotanBoot.root.appendingPathComponent("last-app-server-exit.txt"), atomically: true, encoding: .utf8)
        #endif
        process = nil
        initialized = false
        fail(all: CodexAppServerError.closed("exit \(code)"))
    }

    private func fail(all error: Error) {
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: error) }
        let outstanding = waiters
        waiters.removeAll()
        for waiter in outstanding { waiter.continuation.resume(throwing: error) }
        backlog.removeAll()
    }

    // MARK: - Requests

    func request(_ method: String, params: JSONObject, timeout: Duration = CodexAppServerSession.defaultTimeout) async throws -> JSONObject {
        try await request(method, params: params, timeout: timeout, allowUninitialized: false)
    }

    private func request(_ method: String, params: JSONObject, timeout: Duration, allowUninitialized: Bool) async throws -> JSONObject {
        if !allowUninitialized { try await start() }
        guard let process else { throw CodexAppServerError.notRunning }
        let id = nextID
        nextID += 1
        let line = try Self.encode(["id": id, "method": method, "params": params])
        lastMethods.append(method)
        if lastMethods.count > 8 { lastMethods.removeFirst(lastMethods.count - 8) }
        sessionLog.debug("→ \(method, privacy: .public) #\(id)")
        let timeoutTask = Task { [weak self] in
            try await Task.sleep(for: timeout)
            await self?.timeOut(id: id, method: method)
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            process.writeLine(line)
        }
    }

    private func timeOut(id: Int, method: String) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: CodexAppServerError.timeout(method))
    }

    func notify(_ method: String, params: JSONObject) throws {
        guard let process else { throw CodexAppServerError.notRunning }
        process.writeLine(try Self.encode(["method": method, "params": params]))
    }

    private func respond(id: Any, result: JSONObject?, error: JSONObject?) {
        guard let process else { return }
        var envelope: JSONObject = ["id": id]
        if let result { envelope["result"] = result }
        if let error { envelope["error"] = error }
        if let line = try? Self.encode(envelope) { process.writeLine(line) }
    }

    // MARK: - Notifications

    /// Wait for the first notification whose method is in `methods` and whose
    /// params satisfy `predicate`, checking the bounded backlog first.
    func waitForNotification(
        methods: Set<String>,
        timeout: Duration = CodexAppServerSession.defaultTimeout,
        predicate: @escaping @Sendable (JSONObject) -> Bool = { _ in true }
    ) async throws -> Notification {
        try await start()
        if let index = backlog.firstIndex(where: { methods.contains($0.method) && predicate($0.params) }) {
            return backlog.remove(at: index)
        }
        let id = UUID()
        let timeoutTask = Task { [weak self] in
            try await Task.sleep(for: timeout)
            await self?.timeOutWaiter(id: id, methods: methods)
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(Waiter(id: id, methods: methods, predicate: predicate, continuation: continuation))
        }
    }

    private func timeOutWaiter(id: UUID, methods: Set<String>) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CodexAppServerError.timeout(methods.sorted().joined(separator: ",")))
    }

    /// Drop buffered notifications for a thread once its turn is over.
    func discardBacklog(where predicate: (Notification) -> Bool) {
        backlog.removeAll(where: predicate)
    }

    private func receive(line: String, isError: Bool, generation: Int) {
        guard generation == self.generation else { return }
        if isError {
            stderrTail.append(line)
            if stderrTail.count > 40 { stderrTail.removeFirst(stderrTail.count - 40) }
            return
        }
        guard let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? JSONObject
        else {
            sessionLog.debug("non-JSON line from app-server ignored")
            return
        }
        let method = message["method"] as? String
        let params = message["params"] as? JSONObject ?? [:]
        if let method, let id = message["id"], !(id is NSNull) {
            // Server → client request (approvals, user input). approvalPolicy is never,
            // so answer by policy without involving the user.
            if let reply = serverRequestHandler?(method, params) {
                respond(id: id, result: reply, error: nil)
            } else {
                respond(id: id, result: nil, error: ["code": -32601, "message": "unsupported server request \(method)"])
            }
            return
        }
        if let method {
            handleNotification(method: method, params: params)
            return
        }
        guard let rawID = message["id"] else { return }
        let id = (rawID as? Int) ?? Int((rawID as? NSNumber)?.intValue ?? -1)
        guard let continuation = pending.removeValue(forKey: id) else { return }
        if let error = message["error"] as? JSONObject {
            let text = error["message"] as? String ?? String(describing: error)
            continuation.resume(throwing: CodexAppServerError.rpc(code: error["code"] as? Int, message: text))
        } else {
            continuation.resume(returning: message["result"] as? JSONObject ?? [:])
        }
    }

    private func handleNotification(method: String, params: JSONObject) {
        tap?(method, params)
        if method.hasSuffix("/delta") || method.contains("Delta") {
            deltaCount += 1
            if deltaCount % 200 == 0 { sessionLog.debug("← \(self.deltaCount, privacy: .public) deltas (\(method, privacy: .public))") }
        } else {
            let itemObject = params["item"] as? JSONObject
            var item = itemObject?["type"] as? String
            if item == "commandExecution", let itemObject {
                let command = String(describing: itemObject["command"] ?? "")
                let output = String(describing: itemObject["aggregatedOutput"] ?? "").prefix(400)
                item = "commandExecution status=\(itemObject["status"] ?? "") exit=\(itemObject["exitCode"] ?? "") cmd=\(command.prefix(200)) out=\(output)"
            }
            let detail = item ?? ((params["error"] as? JSONObject)?["message"] as? String).map { String($0.prefix(300)) } ?? ""
            sessionLog.debug("← \(method, privacy: .public) \(detail, privacy: .public)")
        }
        if let index = waiters.firstIndex(where: { $0.methods.contains(method) && $0.predicate(params) }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(returning: (method, params))
            return
        }
        backlog.append((method, params))
        if backlog.count > Self.backlogLimit {
            backlog.removeFirst(backlog.count - Self.backlogLimit)
        }
    }

    var recentStderr: [String] { stderrTail }

    // MARK: - Encoding

    nonisolated static func encode(_ object: JSONObject) throws -> String {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw CodexAppServerError.malformed("request is not JSON")
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        guard let text = String(data: data, encoding: .utf8) else { throw CodexAppServerError.malformed("utf8") }
        return text
    }
}

extension CodexAppServerSession {
    /// The production launcher: `/usr/local/bin/codex app-server` inside the guest.
    @MainActor
    static func guestLauncher(boot: HyotanBoot) -> Launcher {
        { onLine, onExit in
            await boot.start()
            guard await boot.state.isReady else { throw CodexAppServerError.notRunning }
            // stdin is only wired once the guest process has started; a line written
            // before `started` is dropped by the runtime, so wait for it here.
            return try await withCheckedThrowingContinuation { continuation in
                Task { @MainActor in
                    var resumed = false
                    var handle: GuestProcessHandle?
                    let process = boot.run("/usr/local/bin/codex", arguments: CodexAppServerSession.appServerArguments, started: { pid in
                        sessionLog.info("codex app-server started pid \(pid)")
                        guard !resumed, let handle else { return }
                        resumed = true
                        continuation.resume(returning: handle)
                    }, output: { line, isError in
                        onLine(line, isError)
                    }, exited: { code in
                        if !resumed {
                            resumed = true
                            continuation.resume(throwing: CodexAppServerError.closed("exit \(code) before start"))
                        }
                        onExit(code)
                    })
                    handle = GuestProcessHandle(process)
                }
            }
        }
    }
}
