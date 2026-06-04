import Foundation

final class VenvManager {
    let appSupportDir: URL
    var pythonPath: URL { appSupportDir.appendingPathComponent("venv/bin/python3") }
    private var venvDir: URL { appSupportDir.appendingPathComponent("venv") }

    init(appSupportDir: URL) {
        self.appSupportDir = appSupportDir
    }

    var venvExists: Bool {
        FileManager.default.fileExists(atPath: pythonPath.path)
    }

    func deleteVenv() {
        try? FileManager.default.removeItem(at: venvDir)
    }

    var venvSize: String {
        guard venvExists else { return "" }
        let size = directorySize(url: venvDir)
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    private func directorySize(url: URL) -> UInt64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += UInt64(size)
            }
        }
        return total
    }

    /// Creates a virtual environment and installs rembg[cli].
    func createVenvAndInstall(progress: @escaping (String) -> Void) async throws {
        // Ensure app support directory exists
        try FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)

        // Find system Python
        let systemPython = findSystemPython()
        guard let systemPython else {
            throw VenvError.noPython
        }

        // Create venv
        progress("Creating virtual environment...")
        try await runProcess(executable: systemPython, arguments: ["-m", "venv", venvDir.path])

        // Install rembg
        let pipPath = appSupportDir.appendingPathComponent("venv/bin/pip").path
        progress("Installing rembg (this may take a few minutes)...")
        try await runProcess(executable: URL(fileURLWithPath: pipPath), arguments: [
            "install", "rembg[cpu,cli]"
        ])

        progress("Setup complete")
    }

    /// Upgrades rembg to the latest version.
    func upgradeRembg(progress: @escaping (String) -> Void) async throws {
        guard venvExists else { throw VenvError.noVenv }

        let pipPath = appSupportDir.appendingPathComponent("venv/bin/pip").path
        progress("Upgrading rembg...")
        try await runProcess(executable: URL(fileURLWithPath: pipPath), arguments: [
            "install", "--upgrade", "rembg[cpu,cli]"
        ])

        progress("Upgrade complete")
    }

    private func findSystemPython() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    private func runProcess(executable: URL, arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = ProcessInfo.processInfo.environment

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    continuation.resume(throwing: VenvError.processFailure(
                        executable.lastPathComponent,
                        proc.terminationStatus,
                        output
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

enum VenvError: LocalizedError {
    case noPython
    case noVenv
    case processFailure(String, Int32, String)

    var errorDescription: String? {
        switch self {
        case .noPython:
            return "Python 3 not found. Install Xcode Command Line Tools: xcode-select --install"
        case .noVenv:
            return "Virtual environment not found. Run Setup first."
        case .processFailure(let cmd, let code, let output):
            let trimmed = output.suffix(500)
            return "\(cmd) exited with code \(code): \(trimmed)"
        }
    }
}
