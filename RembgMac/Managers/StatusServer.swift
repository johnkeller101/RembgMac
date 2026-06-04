import Foundation

/// Lightweight HTTP server on port 7101 that serves JSON status only.
/// No proxying, no large data, no forwarding — just status responses.
final class StatusServer: @unchecked Sendable {
    private let listenPort: UInt16 = 7101
    private var serverSocket: Int32 = -1
    private var isListening = false
    private let queue = DispatchQueue(label: "com.rembgmac.status", attributes: .concurrent)

    var getStatus: (() -> ServerStatus)?
    var getRequestCount: (() -> Int)?
    var onLog: ((String) -> Void)?

    func start() {
        stop()
        onLog?("[status] Starting status server on :\(listenPort)...")
        queue.async { [weak self] in
            self?.startInternal()
        }
    }

    private func startInternal() {
        serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            onLog?("[status] Failed to create socket")
            return
        }

        var yes: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = listenPort.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(serverSocket, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            onLog?("[status] Failed to bind to port \(listenPort): \(String(cString: strerror(errno)))")
            close(serverSocket)
            serverSocket = -1
            return
        }

        guard listen(serverSocket, 32) == 0 else {
            onLog?("[status] Failed to listen: \(String(cString: strerror(errno)))")
            close(serverSocket)
            serverSocket = -1
            return
        }

        isListening = true
        onLog?("[status] Listening on :\(listenPort)")

        // Accept loop
        while isListening {
            var clientAddr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientSocket = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    accept(serverSocket, sockPtr, &addrLen)
                }
            }

            guard clientSocket >= 0 else {
                if isListening { continue }
                break
            }

            queue.async { [weak self] in
                self?.handleConnection(clientSocket)
            }
        }
    }

    func stop() {
        isListening = false
        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
    }

    private func handleConnection(_ clientSocket: Int32) {
        defer { close(clientSocket) }

        // Read just enough to know it's an HTTP request (we don't need the body)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
        defer { buffer.deallocate() }

        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(clientSocket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let bytesRead = recv(clientSocket, buffer, 1024, 0)
        guard bytesRead > 0 else { return }

        // Build status JSON
        let status = getStatus?() ?? .stopped
        let count = getRequestCount?() ?? 0
        let statusStr: String
        let ready: Bool
        switch status {
        case .running:
            statusStr = "ready"
            ready = true
        case .downloadingModel:
            statusStr = "downloading_model"
            ready = false
        case .starting:
            statusStr = "starting"
            ready = false
        case .unhealthy:
            statusStr = "unhealthy"
            ready = false
        default:
            statusStr = "stopped"
            ready = false
        }

        let json = "{\"status\":\"\(statusStr)\",\"ready\":\(ready),\"requests_processed\":\(count)}"
        let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(json.utf8.count)\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n\(json)"

        response.withCString { ptr in
            _ = send(clientSocket, ptr, strlen(ptr), 0)
        }
    }
}
