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

    private var pythonPath: String {
        appSupportDir.appendingPathComponent("venv/bin/python3").path
    }

    var isRunning: Bool { process?.isRunning ?? false }

    init(appSupportDir: URL) {
        self.appSupportDir = appSupportDir
    }

    func start() {
        intentionalStop = false
        launchProcess()
    }

    func stop() {
        intentionalStop = true
        killProcess()
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
            proc.terminate()
            // Give it 3 seconds, then force kill
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak proc] in
                if let p = proc, p.isRunning {
                    kill(p.processIdentifier, SIGKILL)
                }
            }
        }
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        outputPipe = nil
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
