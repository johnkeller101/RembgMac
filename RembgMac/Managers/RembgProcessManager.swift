import Foundation

final class RembgProcessManager: @unchecked Sendable {
    private let appSupportDir: URL
    private var process: Process?
    private var outputPipe: Pipe?
    private var restartCount = 0
    private var lastStartTime: Date?
    private var intentionalStop = false
    private let maxBackoff: TimeInterval = 60

    var onLog: ((String) -> Void)?
    var onStatusChange: ((ServerStatus) -> Void)?
    var onRequestCounted: (() -> Void)?
    var onDependencyError: (() -> Void)?

    private var pythonPath: String {
        appSupportDir.appendingPathComponent("venv/bin/python3").path
    }

    private var pidFilePath: String {
        appSupportDir.appendingPathComponent("rembg.pid").path
    }

    var isRunning: Bool { process?.isRunning ?? false }

    init(appSupportDir: URL) {
        self.appSupportDir = appSupportDir
        // Kill any stale process from a previous app session (off main thread)
        DispatchQueue.global().async { [weak self] in
            self?.killStalePidFile()
        }
    }

    deinit {
        killProcess()
    }

    func start() {
        intentionalStop = false
        DispatchQueue.global().async { [weak self] in
            self?.launchProcess()
        }
    }

    func stop() {
        intentionalStop = true
        // Kill synchronously but quickly — terminate sends SIGTERM immediately
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        // Clean up PID file and force-kill in background if needed
        let pid = process?.processIdentifier
        process = nil
        outputPipe = nil
        try? FileManager.default.removeItem(atPath: pidFilePath)
        if let pid {
            DispatchQueue.global().async {
                usleep(500_000)
                kill(pid, SIGKILL) // Ensure it's dead
            }
        }
        onStatusChange?(.stopped)
    }

    private func launchProcess() {
        killProcess()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = ["-m", "rembg.cli", "s", "--host", "127.0.0.1", "--port", "7001", "--log_level", "info"]
        proc.environment = ProcessInfo.processInfo.environment

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            guard let output = String(data: data, encoding: .utf8) else { return }

            for line in output.components(separatedBy: .newlines) where !line.isEmpty {
                self?.handleLogLine(line)
            }
        }

        proc.terminationHandler = { [weak self] proc in
            guard let self, !self.intentionalStop else { return }
            self.onLog?("Process exited with code \(proc.terminationStatus)")
            self.onStatusChange?(.stopped)
            self.scheduleRestart()
        }

        do {
            try proc.run()
            self.process = proc
            self.outputPipe = pipe
            self.lastStartTime = Date()
            // Write PID so we can clean up stale processes on next launch
            try? String(proc.processIdentifier).write(toFile: pidFilePath, atomically: true, encoding: .utf8)
            onStatusChange?(.starting)
            onLog?("Started rembg server (PID \(proc.processIdentifier))")
        } catch {
            onLog?("Failed to start: \(error.localizedDescription)")
            onStatusChange?(.stopped)
            scheduleRestart()
        }
    }

    private func killProcess() {
        if let proc = process, proc.isRunning {
            let pid = proc.processIdentifier
            proc.terminate()
            // Wait up to 2 seconds for graceful exit
            for _ in 0..<20 {
                if !proc.isRunning { break }
                usleep(100_000)
            }
            // Force kill if still alive
            if proc.isRunning {
                kill(pid, SIGKILL)
                proc.waitUntilExit()
            }
        }
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        outputPipe = nil
        try? FileManager.default.removeItem(atPath: pidFilePath)
    }

    /// On app launch, kill any rembg process left over from a previous session.
    private func killStalePidFile() {
        guard let pidStr = try? String(contentsOfFile: pidFilePath, encoding: .utf8),
              let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0 else { return }

        // Check if this PID is actually a python/rembg process (not some unrelated process that reused the PID)
        if kill(pid, 0) == 0 {
            onLog?("Killing stale rembg process from previous session (PID \(pid))")
            kill(pid, SIGTERM)
            usleep(500_000)
            if kill(pid, 0) == 0 {
                kill(pid, SIGKILL)
            }
        }
        try? FileManager.default.removeItem(atPath: pidFilePath)
    }

    private func handleLogLine(_ line: String) {
        onLog?(line)

        let lower = line.lowercased()

        // Detect model downloading
        if lower.contains("downloading") || lower.contains("download") {
            onStatusChange?(.downloadingModel)
        }

        // Detect server ready
        if lower.contains("uvicorn running on") || lower.contains("application startup complete") {
            onStatusChange?(.running)
            restartCount = 0  // Stable start, reset backoff
        }

        // Detect dependency errors (missing onnxruntime, CLI deps, etc.)
        if lower.contains("dependencies are not installed") ||
           lower.contains("no onnxruntime backend found") ||
           lower.contains("no module named") {
            onDependencyError?()
        }

        // Count successful requests
        if lower.contains("post") && lower.contains("/api/remove") && lower.contains("200") {
            onRequestCounted?()
        }
    }

    private func scheduleRestart() {
        // Reset backoff if server was stable for >5 minutes
        if let start = lastStartTime, Date().timeIntervalSince(start) > 300 {
            restartCount = 0
        }

        let delay = min(pow(2.0, Double(restartCount)), maxBackoff)
        restartCount += 1

        onLog?("Restarting in \(Int(delay))s (attempt \(restartCount))...")

        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.intentionalStop else { return }
            self.launchProcess()
        }
    }

}
