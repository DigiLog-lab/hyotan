import Foundation
import OSLog

private let bootLog = Logger(subsystem: "com.digiloglab.hyotan", category: "hyotan")

/// Boots the embedded Linux runtime (hyotan) once per process: expands the
/// bundled rootfs on first launch or after a version bump, mounts it as `/`,
/// binds the host workspace directory at `/workspace`, and starts guest
/// processes with the Codex environment.
///
/// `HyotanRuntime` delivers every callback on the main queue, so this type
/// lives on the main actor; actors that consume process output hop from here.
@Observable
@MainActor
final class HyotanBoot {
    enum State: Equatable {
        case idle
        case installing(Double)
        case booting
        case ready
        case failed(String)

        var isReady: Bool { self == .ready }
    }

    private(set) var state: State = .idle
    private(set) var manifest: RootfsManifest?
    private(set) var installDuration: TimeInterval?
    private(set) var bootDuration: TimeInterval?
    let hyotanVersion = HyotanRuntime.version()

    private let runtime = HyotanRuntime()
    private var startTask: Task<Void, Never>?

    /// `Application Support/hyotan/` — rootfs versions and the bound workspace.
    /// Excluded from backups: the rootfs is reproducible and workspaces are disposable.
    nonisolated static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("hyotan", isDirectory: true)
    }()

    nonisolated static let workspaceRoot = root.appendingPathComponent("workspace", isDirectory: true)

    nonisolated static func rootfsDirectory(version: Int) -> URL {
        root.appendingPathComponent("rootfs-v\(version)", isDirectory: true)
    }

    /// Guest environment for every process.
    static let guestEnvironment: [String] = [
        "HOME=/root",
        "CODEX_HOME=/root/.codex",
        "PATH=/usr/local/bin:/root/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        "TMPDIR=/tmp",
        "LANG=C.UTF-8",
        "TERM=dumb",
        "NO_COLOR=1",
        "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt",
        "PYTHONDONTWRITEBYTECODE=1",
        "TOKIO_WORKER_THREADS=2",
        "RAYON_NUM_THREADS=2",
        // No remote-control enrollment inside the guest (another background task at startup).
        "CODEX_INTERNAL_APP_SERVER_REMOTE_CONTROL_DISABLED=1",
    ]

    init() {
        runtime.environment = Self.guestEnvironment
    }

    /// Idempotent. Safe to call from several places; later callers await the same boot.
    func start() async {
        if let startTask {
            await startTask.value
            return
        }
        let task = Task { await performStart() }
        startTask = task
        await task.value
    }

    private func performStart() async {
        do {
            let manifest = try RootfsManifest.bundled()
            self.manifest = manifest
            let destination = Self.rootfsDirectory(version: manifest.version)
            try FileManager.default.createDirectory(at: Self.workspaceRoot, withIntermediateDirectories: true)
            Self.excludeFromBackup(Self.root)
            if !RootfsInstaller.isInstalled(at: destination, manifest: manifest) {
                state = .installing(0)
                let archive = try manifest.archiveURL()
                let started = Date()
                let previous = Self.previousRootfsDirectories(excluding: manifest.version)
                try await Task.detached(priority: .userInitiated) {
                    try RootfsInstaller.install(manifest: manifest, archive: archive, destination: destination) { progress in
                        Task { @MainActor in self.state = .installing(progress.fraction) }
                    }
                    Self.migrateCodexHome(from: previous, to: destination)
                    for directory in previous {
                        try? FileManager.default.removeItem(at: directory)
                    }
                }.value
                installDuration = Date().timeIntervalSince(started)
                bootLog.info("rootfs v\(manifest.version) installed in \(self.installDuration ?? 0, privacy: .public)s")
            }
            state = .booting
            let bootStarted = Date()
            try await boot(root: destination)
            bootDuration = Date().timeIntervalSince(bootStarted)
            state = .ready
            bootLog.info("guest booted in \(self.bootDuration ?? 0, privacy: .public)s (hyotan \(self.hyotanVersion, privacy: .public))")
        } catch {
            bootLog.error("boot failed: \(String(describing: error), privacy: .public)")
            state = .failed(error.localizedDescription)
        }
    }

    private func boot(root: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            runtime.bootRoot(root.path, workspace: Self.workspaceRoot.path) { error in
                if let error {
                    continuation.resume(throwing: HyotanBootError.bootFailed(error))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Start a guest process. Output lines and exit arrive on the main actor.
    func run(
        _ executable: String,
        arguments: [String],
        started: @escaping @MainActor (Int32) -> Void,
        output: @escaping @MainActor (String, Bool) -> Void,
        exited: @escaping @MainActor (Int32) -> Void
    ) -> HyotanProcess {
        runtime.run(executable, arguments: arguments, started: { pid in
            started(pid)
        }, output: { line, isError in
            output(line, isError)
        }, exited: { code in
            exited(code)
        })
    }

    /// Run a short command to completion and collect its output (diagnostics).
    func capture(_ executable: String, arguments: [String], timeout: Duration = .seconds(60)) async -> (code: Int32, stdout: [String], stderr: [String]) {
        await withCheckedContinuation { continuation in
            var out: [String] = []
            var err: [String] = []
            var finished = false
            let process = run(executable, arguments: arguments, started: { _ in }, output: { line, isError in
                if isError { err.append(line) } else { out.append(line) }
            }, exited: { code in
                guard !finished else { return }
                finished = true
                continuation.resume(returning: (code, out, err))
            })
            process.closeInput()
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                guard !finished else { return }
                finished = true
                process.terminate()
                continuation.resume(returning: (124, out, err + ["timeout"]))
            }
        }
    }

    // MARK: - Housekeeping

    nonisolated private static func previousRootfsDirectories(excluding version: Int) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { url in
            let name = url.lastPathComponent
            return name.hasPrefix("rootfs-v") && !name.hasSuffix(".installing") && name != "rootfs-v\(version)"
        }
    }

    /// Keep the ChatGPT login (`/root/.codex`) across rootfs upgrades.
    nonisolated private static func migrateCodexHome(from previous: [URL], to destination: URL) {
        let target = destination.appendingPathComponent("data/root/.codex", isDirectory: true)
        for old in previous.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            let source = old.appendingPathComponent("data/root/.codex", isDirectory: true)
            let auth = source.appendingPathComponent("auth.json")
            guard FileManager.default.fileExists(atPath: auth.path) else { continue }
            let targetAuth = target.appendingPathComponent("auth.json")
            try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: targetAuth)
            if (try? FileManager.default.copyItem(at: auth, to: targetAuth)) != nil {
                // The meta.db knows the path after a rebuild-on-mount; a fresh file is fine.
                bootLog.info("migrated Codex auth from \(old.lastPathComponent, privacy: .public)")
                return
            }
        }
    }

    nonisolated private static func excludeFromBackup(_ url: URL) {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }
}

nonisolated enum HyotanBootError: Error, LocalizedError {
    case bootFailed(String)

    var errorDescription: String? {
        switch self {
        case .bootFailed(let detail): "Could not boot the guest (\(detail))"
        }
    }
}
