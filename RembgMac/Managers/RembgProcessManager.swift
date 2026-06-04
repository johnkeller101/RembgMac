import Foundation

final class RembgProcessManager: @unchecked Sendable {
    private let appSupportDir: URL
    private var process: Process?
    private var outputPipe: Pipe?
    private var restartCount = 0
    private var lastStableStart: Date?
    private var intentionalStop = false
    private let maxBackoff: TimeInterval = 60
    private let launchQueue = DispatchQueue(label: "com.rembgmac.process")

    var onLog: ((String) -> Void)?
    var onStatusChange: ((ServerStatus) -> Void)?
    var onRequestCounted: (() -> Void)?
    var onDependencyError: (() -> Void)?

    private var pythonPath: String {
        appSupportDir.appendingPathComponent("venv/bin/python3").path
    }

    private var rembgBinPath: String {
        appSupportDir.appendingPathComponent("venv/bin/rembg").path
    }

    private var pidFilePath: String {
        appSupportDir.appendingPathComponent("rembg.pid").path
    }

    var isRunning: Bool { process?.isRunning ?? false }
    var currentPid: Int32? { process?.isRunning == true ? process?.processIdentifier : nil }

    init(appSupportDir: URL) {
        self.appSupportDir = appSupportDir
    }

    deinit {
        forceKillProcess()
    }

    func start() {
        intentionalStop = false
        launchQueue.async { [weak self] in
            self?.cleanupAndLaunch()
        }
    }

    func stop() {
        intentionalStop = true
        forceKillProcess()
        onStatusChange?(.stopped)
    }

    // MARK: - Launch

    private func cleanupAndLaunch() {
        // 1. Kill any tracked process
        forceKillProcess()

        // 2. Kill any stale process from a previous app session
        killStalePidFile()

        // 3. Run diagnostics (results logged inline)
        runDiagnostics()

        // 4. Decide how to invoke rembg: prefer the bin script, fall back to -m
        let (executable, args) = buildCommand()

        log("[launch] \(executable) \(args.joined(separator: " "))")

        // 5. Launch
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        // Give the process a clean environment with just PATH
        var env = ProcessInfo.processInfo.environment
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["BROWSER"] = "/usr/bin/true"  // Redirect browser open to no-op
        env["GRADIO_ANALYTICS_ENABLED"] = "False"
        proc.environment = env

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let output = String(data: data, encoding: .utf8) else { return }
            for line in output.components(separatedBy: .newlines) where !line.isEmpty {
                self?.handleLogLine(line)
            }
        }

        proc.terminationHandler = { [weak self] proc in
            guard let self, !self.intentionalStop else { return }
            self.log("Process exited with code \(proc.terminationStatus) (\(proc.terminationReason == .exit ? "exit" : "signal"))")
            self.onStatusChange?(.stopped)
            self.scheduleRestart()
        }

        do {
            try proc.run()
            self.process = proc
            self.outputPipe = pipe
            self.lastStableStart = Date()
            writePidFile(proc.processIdentifier)
            onStatusChange?(.starting)
            log("Started rembg server (PID \(proc.processIdentifier))")
        } catch {
            log("[launch] Failed to start: \(error.localizedDescription)")
            onStatusChange?(.stopped)
            scheduleRestart()
        }
    }

    /// Decide how to invoke rembg. Prefer the venv bin script if it exists.
    private func buildCommand() -> (String, [String]) {
        // Check if the rembg binary exists in the venv (installed via [cli] extra)
        if FileManager.default.fileExists(atPath: rembgBinPath) {
            return (rembgBinPath, ["s", "--host", "127.0.0.1", "--port", "7001", "--log_level", "info"])
        }
        // Fall back to python -m
        return (pythonPath, ["-m", "rembg.cli", "s", "--host", "127.0.0.1", "--port", "7001", "--log_level", "info"])
    }

    // MARK: - Process lifecycle

    private func forceKillProcess() {
        guard let proc = process else {
            outputPipe?.fileHandleForReading.readabilityHandler = nil
            outputPipe = nil
            return
        }

        let pid = proc.processIdentifier
        outputPipe?.fileHandleForReading.readabilityHandler = nil

        if proc.isRunning {
            // Kill the entire process group to catch ONNX worker threads
            kill(-pid, SIGTERM)
            proc.terminate()
            for _ in 0..<5 {
                if !proc.isRunning { break }
                usleep(100_000)
            }
            if proc.isRunning {
                kill(-pid, SIGKILL)
                kill(pid, SIGKILL)
            }
        }

        process = nil
        outputPipe = nil
        removePidFile()
    }

    private func killStalePidFile() {
        guard let pidStr = try? String(contentsOfFile: pidFilePath, encoding: .utf8),
              let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0 else { return }

        if kill(pid, 0) == 0 {
            log("[cleanup] Killing stale rembg (PID \(pid)) from previous session")
            kill(-pid, SIGKILL) // Kill process group
            kill(pid, SIGKILL)  // Kill process directly
            usleep(300_000)
        }
        removePidFile()
    }

    private func writePidFile(_ pid: Int32) {
        try? "\(pid)".write(toFile: pidFilePath, atomically: true, encoding: .utf8)
    }

    private func removePidFile() {
        try? FileManager.default.removeItem(atPath: pidFilePath)
    }

    // MARK: - Diagnostics

    /// Run diagnostic checks and log results. Runs synchronously on launch queue.
    private func runDiagnostics() {
        log("[diag] Python: \(pythonPath) (exists: \(FileManager.default.fileExists(atPath: pythonPath)))")
        log("[diag] rembg bin: \(rembgBinPath) (exists: \(FileManager.default.fileExists(atPath: rembgBinPath)))")

        // Python version
        if let output = runQuickCommand(pythonPath, args: ["--version"]) {
            log("[diag] \(output)")
        }

        // rembg help — what subcommands exist?
        if FileManager.default.fileExists(atPath: rembgBinPath) {
            if let output = runQuickCommand(rembgBinPath, args: ["--help"]) {
                log("[diag] rembg --help:\n\(output)")
            }
        } else if let output = runQuickCommand(pythonPath, args: ["-m", "rembg.cli", "--help"]) {
            log("[diag] rembg.cli --help:\n\(output)")
        }

        // Relevant pip packages
        if let output = runQuickCommand(pythonPath, args: ["-m", "pip", "list", "--format=columns"]) {
            let relevant = output.components(separatedBy: "\n")
                .filter { l in
                    let low = l.lowercased()
                    return low.contains("rembg") || low.contains("onnx") || low.contains("uvicorn") || low.contains("fastapi")
                }
            if relevant.isEmpty {
                log("[diag] pip: NO rembg/onnx/uvicorn/fastapi packages found!")
            } else {
                log("[diag] pip packages:\n\(relevant.joined(separator: "\n"))")
            }
        }
    }

    /// Run a quick command and return its combined stdout+stderr. Returns nil on failure.
    private func runQuickCommand(_ executable: String, args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        p.environment = ProcessInfo.processInfo.environment
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return "FAILED: \(error.localizedDescription)"
        }
    }

    // MARK: - Log handling

    private func handleLogLine(_ line: String) {
        log(line)

        let lower = line.lowercased()

        // Detect model downloading
        if lower.contains("downloading") && !lower.contains("pip") {
            onStatusChange?(.downloadingModel)
        }

        // Detect server ready
        if lower.contains("uvicorn running on") || lower.contains("application startup complete") {
            onStatusChange?(.running)
            restartCount = 0
        }

        // Detect dependency errors — but NOT from our own diagnostics
        if (lower.contains("dependencies are not installed") ||
            lower.contains("no onnxruntime backend found") ||
            lower.contains("no module named 'onnxruntime'")) {
            onDependencyError?()
        }

        // Count successful requests
        if lower.contains("post") && lower.contains("/api/remove") && lower.contains("200") {
            onRequestCounted?()
        }
    }

    private func log(_ message: String) {
        onLog?(message)
    }

    // MARK: - Restart

    private func scheduleRestart() {
        guard !intentionalStop else { return }

        // Reset backoff if server was stable for >5 minutes
        if let start = lastStableStart, Date().timeIntervalSince(start) > 300 {
            restartCount = 0
        }

        let delay = min(pow(2.0, Double(restartCount)), maxBackoff)
        restartCount += 1

        log("Restarting in \(Int(delay))s (attempt \(restartCount))...")

        launchQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.intentionalStop else { return }
            self.cleanupAndLaunch()
        }
    }
}
