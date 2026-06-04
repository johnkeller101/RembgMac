import Foundation

/// Lightweight HTTP server on port 7000 that proxies to rembg on port 7001.
/// Returns 503 when the model is downloading, and exposes /status.
final class ProxyServer: @unchecked Sendable {
    private var listener: Any?  // NWListener stored as Any to avoid import issues
    private let rembgPort = 7001
    private let listenPort: UInt16 = 7100
    private var serverSocket: Int32 = -1
    private var isListening = false
    private let queue = DispatchQueue(label: "com.rembgmac.proxy", attributes: .concurrent)
    private var activeRequests = 0
    private let maxConcurrentRequests = 2
    private let requestLock = NSLock()

    var getStatus: (() -> ServerStatus)?
    var getRequestCount: (() -> Int)?
    var onRequestCompleted: (() -> Void)?
    var onLog: ((String) -> Void)?

    func start() {
        stop()
        onLog?("[proxy] Starting proxy on :\(listenPort)...")

        queue.async { [weak self] in
            self?.startInternal()
        }
    }

    private func startInternal() {
        serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            onLog?("[proxy] Failed to create socket")
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
            onLog?("[proxy] Failed to bind to port \(listenPort): \(String(cString: strerror(errno)))")
            close(serverSocket)
            serverSocket = -1
            return
        }

        guard listen(serverSocket, 128) == 0 else {
            onLog?("[proxy] Failed to listen: \(String(cString: strerror(errno)))")
            close(serverSocket)
            serverSocket = -1
            return
        }

        isListening = true
        onLog?("[proxy] Listening on :\(listenPort), forwarding to rembg on :\(rembgPort)")

        acceptLoop()
    }

    func stop() {
        isListening = false
        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
    }

    private func acceptLoop() {
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

    private func handleConnection(_ clientSocket: Int32) {
        defer { close(clientSocket) }

        // Read the request (up to 50MB for image uploads)
        var requestData = Data()
        let bufferSize = 65536
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        // Set receive timeout to 30s
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(clientSocket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        // Read headers first
        while true {
            let bytesRead = recv(clientSocket, buffer, bufferSize, 0)
            if bytesRead <= 0 { break }
            requestData.append(buffer, count: bytesRead)

            // Check if we have the full headers
            if let headerEnd = requestData.range(of: Data("\r\n\r\n".utf8)) {
                // Parse Content-Length to know how much body to expect
                let headerStr = String(data: requestData[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
                let contentLength = parseContentLength(headerStr)
                let bodyStart = headerEnd.upperBound
                let bodyReceived = requestData.count - bodyStart
                let bodyRemaining = contentLength - bodyReceived

                if bodyRemaining > 0 {
                    // Read remaining body
                    var remaining = bodyRemaining
                    while remaining > 0 {
                        let toRead = min(remaining, bufferSize)
                        let bytesRead = recv(clientSocket, buffer, toRead, 0)
                        if bytesRead <= 0 { break }
                        requestData.append(buffer, count: bytesRead)
                        remaining -= bytesRead
                    }
                }
                break
            }

            // Safety: don't read more than 50MB
            if requestData.count > 50 * 1024 * 1024 { break }
        }

        guard !requestData.isEmpty else { return }

        // Parse the request line
        guard let headerEnd = requestData.range(of: Data("\r\n\r\n".utf8)),
              let headerStr = String(data: requestData[..<headerEnd.lowerBound], encoding: .utf8),
              let firstLine = headerStr.components(separatedBy: "\r\n").first else {
            return
        }

        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return }
        let path = String(parts[1])

        // Handle /status and any non-API path
        if !path.hasPrefix("/api/") {
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
            let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(json.utf8.count)\r\n\r\n\(json)"
            _ = response.withCString { ptr in
                send(clientSocket, ptr, strlen(ptr), 0)
            }
            return
        }

        // For /api/remove — check constraints before forwarding
        if path.hasPrefix("/api/remove") {
            let status = getStatus?() ?? .stopped
            if case .downloadingModel = status {
                let json = "{\"status\":\"downloading_model\",\"message\":\"Model is being downloaded, please retry shortly\"}"
                let response = "HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nRetry-After: 30\r\nContent-Length: \(json.utf8.count)\r\n\r\n\(json)"
                _ = response.withCString { ptr in
                    send(clientSocket, ptr, strlen(ptr), 0)
                }
                return
            }

            // Limit concurrent rembg requests
            requestLock.lock()
            let current = activeRequests
            if current >= maxConcurrentRequests {
                requestLock.unlock()
                let json = "{\"error\":\"too_many_requests\",\"message\":\"Max \(maxConcurrentRequests) concurrent requests, \(current) active\"}"
                let response = "HTTP/1.1 429 Too Many Requests\r\nContent-Type: application/json\r\nRetry-After: 10\r\nContent-Length: \(json.utf8.count)\r\n\r\n\(json)"
                _ = response.withCString { ptr in
                    send(clientSocket, ptr, strlen(ptr), 0)
                }
                return
            }
            activeRequests += 1
            requestLock.unlock()
        }

        // Track whether we incremented the counter (for cleanup on all exit paths)
        let isTrackedRequest = path.hasPrefix("/api/remove")

        // Forward to rembg
        let rembgSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard rembgSocket >= 0 else {
            if isTrackedRequest { decrementActiveRequests() }
            sendError(clientSocket, code: 502, message: "Failed to connect to rembg")
            return
        }
        defer { close(rembgSocket) }

        var rembgAddr = sockaddr_in()
        rembgAddr.sin_family = sa_family_t(AF_INET)
        rembgAddr.sin_port = UInt16(rembgPort).bigEndian
        rembgAddr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connectResult = withUnsafePointer(to: &rembgAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(rembgSocket, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard connectResult == 0 else {
            if isTrackedRequest { decrementActiveRequests() }
            sendError(clientSocket, code: 502, message: "rembg not reachable")
            return
        }

        // Set timeouts on rembg socket (5 min for large images)
        var rembgTimeout = timeval(tv_sec: 300, tv_usec: 0)
        setsockopt(rembgSocket, SOL_SOCKET, SO_RCVTIMEO, &rembgTimeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(rembgSocket, SOL_SOCKET, SO_SNDTIMEO, &rembgTimeout, socklen_t(MemoryLayout<timeval>.size))

        // Send full request to rembg
        requestData.withUnsafeBytes { rawPtr in
            guard let ptr = rawPtr.baseAddress else { return }
            var sent = 0
            while sent < requestData.count {
                let n = send(rembgSocket, ptr + sent, requestData.count - sent, 0)
                if n <= 0 { break }
                sent += n
            }
        }

        // Read response from rembg and forward to client
        // Inject "Connection: close" so the Go client doesn't try to reuse this socket
        var totalResponse = 0
        var headerInjected = false
        while true {
            let bytesRead = recv(rembgSocket, buffer, bufferSize, 0)
            if bytesRead <= 0 { break }

            var dataToSend = Data(bytes: buffer, count: bytesRead)

            // Inject Connection: close into the first chunk (contains HTTP headers)
            if !headerInjected, let headerEnd = dataToSend.range(of: Data("\r\n\r\n".utf8)) {
                let closeHeader = Data("Connection: close\r\n".utf8)
                dataToSend.insert(contentsOf: closeHeader, at: headerEnd.lowerBound)
                headerInjected = true
            }

            dataToSend.withUnsafeBytes { rawPtr in
                guard let ptr = rawPtr.baseAddress else { return }
                var sent = 0
                while sent < dataToSend.count {
                    let n = send(clientSocket, ptr + sent, dataToSend.count - sent, 0)
                    if n <= 0 { break }
                    sent += n
                }
            }
            totalResponse += bytesRead
        }

        // Track completion for /api/remove requests
        if isTrackedRequest {
            decrementActiveRequests()
            if totalResponse > 0 {
                onRequestCompleted?()
            }
        }
    }

    private func parseContentLength(_ headers: String) -> Int {
        for line in headers.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                return Int(value) ?? 0
            }
        }
        return 0
    }

    // Removed killProcessOnPort — SO_REUSEADDR handles port reuse,
    // and lsof can hang on macOS causing the proxy to never start.

    private func decrementActiveRequests() {
        requestLock.lock()
        activeRequests -= 1
        requestLock.unlock()
    }

    private func sendError(_ socket: Int32, code: Int, message: String) {
        let json = "{\"error\":\"\(message)\"}"
        let statusText = code == 502 ? "Bad Gateway" : "Service Unavailable"
        let response = "HTTP/1.1 \(code) \(statusText)\r\nContent-Type: application/json\r\nContent-Length: \(json.utf8.count)\r\n\r\n\(json)"
        _ = response.withCString { ptr in
            send(socket, ptr, strlen(ptr), 0)
        }
    }
}
