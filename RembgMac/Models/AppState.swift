import Foundation
import SwiftUI

enum ServerStatus: Equatable {
    case stopped
    case starting
    case downloadingModel
    case running
    case unhealthy
    case settingUp(String)  // progress message
    case updating(String)
}

@MainActor
final class AppState: ObservableObject {
    @Published var status: ServerStatus = .stopped
    @Published var requestCount: Int {
        didSet { persistRequestCount() }
    }
    @Published var startTime: Date?
    @Published var recentLogs: [String] = []
    @Published var venvExists: Bool = false

    let processManager: RembgProcessManager
    let venvManager: VenvManager
    let healthChecker: HealthChecker
    let proxyServer: ProxyServer

    private let maxLogLines = 500
    private var requestCountWriteBuffer = 0

    var statusColor: Color {
        switch status {
        case .running: return .green
        case .starting, .downloadingModel, .settingUp, .updating: return .orange
        case .unhealthy: return .yellow
        case .stopped: return .red
        }
    }

    var statusText: String {
        switch status {
        case .running: return "rembg running on :7000"
        case .starting: return "Starting rembg..."
        case .downloadingModel: return "Downloading model..."
        case .settingUp(let msg): return msg.isEmpty ? "Setting up..." : msg
        case .updating(let msg): return msg.isEmpty ? "Updating..." : msg
        case .unhealthy: return "rembg unhealthy"
        case .stopped: return "rembg stopped"
        }
    }

    var uptimeText: String {
        guard let start = startTime else { return "" }
        let elapsed = Date().timeIntervalSince(start)
        let hours = Int(elapsed) / 3600
        let minutes = (Int(elapsed) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("RembgMac", isDirectory: true)

        self.requestCount = UserDefaults.standard.integer(forKey: "requestCount")
        self.venvManager = VenvManager(appSupportDir: appSupport)
        self.processManager = RembgProcessManager(appSupportDir: appSupport)
        self.healthChecker = HealthChecker()
        self.proxyServer = ProxyServer()

        self.venvExists = venvManager.venvExists

        processManager.onLog = { [weak self] line in
            Task { @MainActor in
                self?.appendLog(line)
            }
        }

        processManager.onStatusChange = { [weak self] newStatus in
            Task { @MainActor in
                self?.status = newStatus
                if case .running = newStatus {
                    if self?.startTime == nil {
                        self?.startTime = Date()
                    }
                }
                if case .stopped = newStatus {
                    self?.startTime = nil
                }
            }
        }

        processManager.onRequestCounted = { [weak self] in
            Task { @MainActor in
                self?.requestCount += 1
            }
        }

        proxyServer.getStatus = { [weak self] in
            self?.status ?? .stopped
        }
        proxyServer.getRequestCount = { [weak self] in
            self?.requestCount ?? 0
        }
        proxyServer.onRequestCompleted = { [weak self] in
            Task { @MainActor in
                self?.requestCount += 1
            }
        }
        proxyServer.onLog = { [weak self] line in
            Task { @MainActor in
                self?.appendLog(line)
            }
        }

        // Auto-start server if venv is ready
        if venvExists {
            Task { @MainActor [weak self] in
                self?.startServer()
            }
        }
    }

    func startServer() {
        guard venvExists else { return }
        status = .starting
        startTime = nil
        proxyServer.start()
        processManager.start()
        healthChecker.startChecking { [weak self] healthy in
            Task { @MainActor in
                guard let self else { return }
                switch self.status {
                case .stopped: return  // user stopped it
                case .running where !healthy:
                    self.status = .unhealthy
                case _ where healthy:
                    if case .running = self.status { return }
                    self.status = .running
                    if self.startTime == nil { self.startTime = Date() }
                default:
                    break
                }
            }
        }
    }

    func stopServer() {
        healthChecker.stop()
        processManager.stop()
        proxyServer.stop()
        status = .stopped
        startTime = nil
    }

    func resetVenv() async {
        stopServer()
        appendLog("[reset] Deleting virtual environment...")
        venvManager.deleteVenv()
        venvExists = false
        appendLog("[reset] Done — click Setup to reinstall")
    }

    func runSetup() async {
        status = .settingUp("Creating virtual environment...")
        do {
            try await venvManager.createVenvAndInstall { [weak self] progress in
                Task { @MainActor in
                    self?.status = .settingUp(progress)
                    self?.appendLog("[setup] \(progress)")
                }
            }
            venvExists = true
            appendLog("[setup] Setup complete")
            startServer()
        } catch {
            appendLog("[setup] Failed: \(error.localizedDescription)")
            status = .stopped
        }
    }

    func runUpgrade() async {
        let wasRunning = processManager.isRunning
        if wasRunning { stopServer() }

        status = .updating("Upgrading rembg...")
        do {
            try await venvManager.upgradeRembg { [weak self] progress in
                Task { @MainActor in
                    self?.status = .updating(progress)
                    self?.appendLog("[update] \(progress)")
                }
            }
            appendLog("[update] Upgrade complete")
            if wasRunning { startServer() } else { status = .stopped }
        } catch {
            appendLog("[update] Failed: \(error.localizedDescription)")
            status = .stopped
        }
    }

    private func appendLog(_ line: String) {
        let timestamped = "[\(Self.logDateFormatter.string(from: Date()))] \(line)"
        recentLogs.append(timestamped)
        if recentLogs.count > maxLogLines {
            recentLogs.removeFirst(recentLogs.count - maxLogLines)
        }
    }

    private func persistRequestCount() {
        requestCountWriteBuffer += 1
        if requestCountWriteBuffer >= 10 {
            requestCountWriteBuffer = 0
            UserDefaults.standard.set(requestCount, forKey: "requestCount")
        }
    }

    func flushRequestCount() {
        UserDefaults.standard.set(requestCount, forKey: "requestCount")
    }

    private static let logDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
