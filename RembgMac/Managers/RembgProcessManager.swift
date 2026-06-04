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
        proc.arguments = ["-m", "rembg.cli", "s", "--host", "0.0.0.0", "--port", "7000", "--log_level", "info"]
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

            // Send warm-up request after a delay to trigger model download
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.sendWarmupRequest()
            }
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

    private func sendWarmupRequest() {
        guard isRunning else { return }

        // Create a tiny 1x1 red PNG to trigger model download
        let tinyPNG = createTinyPNG()

        var request = URLRequest(url: URL(string: "http://localhost:7000/api/remove")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300  // Model download can take a while

        let boundary = "----WarmupBoundary"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"warmup.png\"\r\nContent-Type: image/png\r\n\r\n".data(using: .utf8)!)
        body.append(tinyPNG)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        onLog?("Sending warm-up request to trigger model download...")
        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            if let error {
                self?.onLog?("Warm-up request failed: \(error.localizedDescription)")
            } else if let http = response as? HTTPURLResponse {
                self?.onLog?("Warm-up complete (HTTP \(http.statusCode))")
            }
        }.resume()
    }

    /// Creates a minimal valid 1x1 red PNG.
    private func createTinyPNG() -> Data {
        // Minimal 1x1 red PNG (67 bytes)
        let bytes: [UInt8] = [
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR chunk
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
            0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, // IDAT chunk
            0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
            0x00, 0x00, 0x02, 0x00, 0x01, 0xE2, 0x21, 0xBC,
            0x33, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, // IEND chunk
            0x44, 0xAE, 0x42, 0x60, 0x82
        ]
        return Data(bytes)
    }
}
