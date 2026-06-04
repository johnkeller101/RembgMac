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

        // Use python3 -m pip (not the pip binary) to avoid path mismatch issues
        progress("Upgrading pip...")
        try await runProcess(executable: pythonPath, arguments: [
            "-m", "pip", "install", "--upgrade", "pip"
        ])
        progress("Installing rembg (this may take a few minutes)...")
        try await runProcess(executable: pythonPath, arguments: [
            "-m", "pip", "install", "--force-reinstall", "rembg[cpu,cli]"
        ])
        // Verify the module is actually importable
        progress("Verifying installation...")
        try await runProcess(executable: pythonPath, arguments: [
            "-c", "import rembg; print('rembg', rembg.__version__, 'OK')"
        ])

        // Write the server wrapper script that patches ONNX memory arena
        writeServerScript()

        progress("Setup complete")
    }

    /// Writes rembg_server.py to the app support directory.
    /// This wrapper patches ONNX Runtime to disable CPU memory arena (fixes rembg#752).
    func writeServerScript() {
        let script = """
        \"\"\"
        rembg server wrapper — disables ONNX Runtime CPU memory arena.
        Fixes: https://github.com/danielgatis/rembg/issues/752
        \"\"\"
        import onnxruntime as ort

        _orig_init = ort.InferenceSession.__init__

        def _patched_init(self, *args, **kwargs):
            opts = ort.SessionOptions()
            opts.enable_cpu_mem_arena = False
            opts.enable_mem_pattern = False

            if len(args) > 1 and args[1] is not None:
                args[1].enable_cpu_mem_arena = False
                args[1].enable_mem_pattern = False
            elif "sess_options" in kwargs and kwargs["sess_options"] is not None:
                kwargs["sess_options"].enable_cpu_mem_arena = False
                kwargs["sess_options"].enable_mem_pattern = False
            else:
                kwargs["sess_options"] = opts

            _orig_init(self, *args, **kwargs)

        ort.InferenceSession.__init__ = _patched_init

        import sys
        sys.argv = ["rembg", "s", "--host", "0.0.0.0", "--port", "7100", "--log_level", "info"]
        from rembg.cli import main
        main()
        """

        let scriptPath = appSupportDir.appendingPathComponent("rembg_server.py")
        try? script.write(to: scriptPath, atomically: true, encoding: .utf8)
    }

    var serverScriptPath: URL {
        appSupportDir.appendingPathComponent("rembg_server.py")
    }

    var serverScriptExists: Bool {
        FileManager.default.fileExists(atPath: serverScriptPath.path)
    }

    /// Upgrades rembg to the latest version.
    func upgradeRembg(progress: @escaping (String) -> Void) async throws {
        guard venvExists else { throw VenvError.noVenv }

        progress("Upgrading rembg...")
        try await runProcess(executable: pythonPath, arguments: [
            "-m", "pip", "install", "--upgrade", "--force-reinstall", "rembg[cpu,cli]"
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
